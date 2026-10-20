//! Drawing history: the versions a drawing was finished at, and bringing one back.
//!
//! A version is recorded (a [`Checkpoint`]) when a drawing is placed from the overlay ("done"),
//! when a client uploads a preview, and for drawings shown in a canvas pane once they have been
//! left alone for [`IDLE_MS`]. Excalidraw scenes keep only their latest elements, so a
//! checkpoint of one holds a copy of its live elements, app state and files; an op-log
//! drawing replays its log instead. Restoring writes the old content as a new version on top,
//! so every client converges through the ordinary pushes and nothing is lost.
//!
//! On disk: `<session>/<artifact>/history.bin` (postcard, oldest first), rewritten atomically.

use std::collections::HashMap;
use std::path::Path;

use proto::{
    Actor, ArtifactError, ArtifactId, ArtifactKind, ArtifactVersion, DrawOp, ExElement, ExFile,
    ExcalidrawPut, ImageRef, UnixMillis,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Art, Result, not_found};
use crate::core::lock;
use crate::fsutil::{random, read_optional, write_atomic};
use crate::identity::now_millis;

/// Versions kept per drawing (the oldest go first).
const KEEP: usize = 100;
/// A drawing in a canvas pane gets a version once nobody has changed it for this long.
pub(crate) const IDLE_MS: u64 = 30_000;

/// One recorded version.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct Checkpoint {
    pub meta: ArtifactVersion,
    /// Excalidraw scenes: the content then.
    pub scene: Option<ExSnapshot>,
}

/// An Excalidraw scene's content at a checkpoint.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct ExSnapshot {
    /// Live elements (no tombstones).
    pub elements: Vec<ExElement>,
    pub app_state: Option<String>,
    pub files: Vec<ExFile>,
}

impl Checkpoint {
    fn bytes(&self) -> usize {
        self.scene.as_ref().map_or(0, |s| {
            s.elements.iter().map(|e| e.json.len()).sum::<usize>()
                + s.app_state.as_ref().map_or(0, String::len)
        })
    }

    /// Blobs this checkpoint keeps alive.
    pub fn blobs(&self) -> impl Iterator<Item = &ImageRef> {
        self.meta.image.iter().chain(
            self.scene
                .iter()
                .flat_map(|s| s.files.iter().map(|f| &f.image)),
        )
    }
}

/// What a restore writes, for the caller to apply through the ordinary paths (so the change
/// is broadcast like any other).
pub(crate) enum RestorePlan {
    /// Elements to put on an Excalidraw scene.
    Excalidraw(ExcalidrawPut),
    /// Ops to commit on an op-log drawing.
    Ops(Vec<DrawOp>),
}

pub(super) fn load(dir: &Path) -> std::io::Result<Vec<Checkpoint>> {
    match read_optional(&dir.join("history.bin"))? {
        Some(bytes) => postcard::from_bytes(&bytes).map_err(std::io::Error::other),
        None => Ok(Vec::new()),
    }
}

impl Art {
    /// Records the drawing's current version (`image`: the render shown for it). A second
    /// call at the same version only fills in or replaces the render. Returns the entry, or
    /// `None` for images and empty drawings.
    pub fn checkpoint(
        &self,
        id: ArtifactId,
        by: Actor,
        image: Option<ImageRef>,
        restored_from: Option<u64>,
    ) -> Option<ArtifactVersion> {
        let mut st = lock(&self.state);
        let it = st.items.get_mut(&id)?;
        if it.info.kind == ArtifactKind::Image || it.info.version == 0 {
            return None;
        }
        let version = it.info.version;
        let entry = match it.history.last_mut() {
            Some(last) if last.meta.version == version => {
                if image.is_none() || last.meta.image == image {
                    return Some(last.meta.clone());
                }
                last.meta.image = image;
                last.meta.clone()
            }
            _ => {
                let scene = it.ex.as_ref().map(|ex| ExSnapshot {
                    elements: ex
                        .with_revisions()
                        .map(|(e, _)| e)
                        .filter(|e| !e.deleted)
                        .cloned()
                        .collect(),
                    app_state: ex.app_state.clone(),
                    files: ex.files.values().cloned().collect(),
                });
                let meta = ArtifactVersion {
                    version,
                    at: UnixMillis(now_millis()),
                    by,
                    image,
                    elements: it.info.elements,
                    restored_from,
                };
                it.history.push(Checkpoint {
                    meta: meta.clone(),
                    scene,
                });
                // A drawing's history stays within four times its own size cap.
                let budget = self.limits.log_max as usize * 4;
                while it.history.len() > KEEP
                    || (it.history.len() > 1
                        && it.history.iter().map(Checkpoint::bytes).sum::<usize>() > budget)
                {
                    it.history.remove(0);
                }
                meta
            }
        };
        let (info, bytes) = (it.info.clone(), postcard::to_stdvec(&it.history));
        drop(st);
        let path = self.item_dir(&info).join("history.bin");
        if let Err(e) = bytes
            .map_err(std::io::Error::other)
            .and_then(|b| write_atomic(&path, &b))
        {
            tracing::warn!("saving {}: {e}", path.display());
        }
        Some(entry)
    }

    /// The drawing's recorded versions, newest first (none for images).
    pub fn history(&self, id: ArtifactId) -> Result<Vec<ArtifactVersion>> {
        let st = lock(&self.state);
        let it = st.items.get(&id).ok_or_else(|| not_found(id))?;
        Ok(it.history.iter().rev().map(|c| c.meta.clone()).collect())
    }

    /// The recorded entry for `version`.
    pub fn history_entry(&self, id: ArtifactId, version: u64) -> Result<ArtifactVersion> {
        let st = lock(&self.state);
        let it = st.items.get(&id).ok_or_else(|| not_found(id))?;
        it.history
            .iter()
            .rfind(|c| c.meta.version == version)
            .map(|c| c.meta.clone())
            .ok_or_else(|| no_version(id, version))
    }

    /// What bringing back `version` writes on top of the current one.
    pub fn restore_plan(&self, id: ArtifactId, version: u64) -> Result<RestorePlan> {
        let (kind, snapshot) = {
            let st = lock(&self.state);
            let it = st.items.get(&id).ok_or_else(|| not_found(id))?;
            let c = it
                .history
                .iter()
                .rfind(|c| c.meta.version == version)
                .ok_or_else(|| no_version(id, version))?;
            (it.info.kind, c.scene.clone())
        };
        match kind {
            ArtifactKind::Image => Err(ArtifactError::Invalid("images have no versions".into())),
            ArtifactKind::Excalidraw => {
                let snapshot = snapshot.ok_or_else(|| {
                    ArtifactError::Failed(format!("version {version} kept no content"))
                })?;
                let current: HashMap<String, ExElement> = {
                    let st = lock(&self.state);
                    let ex = st.items.get(&id).and_then(|it| it.ex.as_ref());
                    ex.map(|ex| {
                        ex.with_revisions()
                            .map(|(e, _)| (e.id.clone(), e.clone()))
                            .collect()
                    })
                    .unwrap_or_default()
                };
                Ok(RestorePlan::Excalidraw(ExcalidrawPut {
                    artifact_id: id,
                    base: 0,
                    elements: restore_elements(&snapshot.elements, &current)?,
                    app_state: snapshot.app_state,
                    files: snapshot.files,
                }))
            }
            ArtifactKind::Drawing => {
                let (_, now) = self.scene_at(id, None)?;
                let (_, then) = self.scene_at(id, Some(version))?;
                let ops = now
                    .elements()
                    .iter()
                    .map(|e| DrawOp::Delete { id: e.id })
                    .chain(then.elements().iter().cloned().map(DrawOp::Add))
                    .collect::<Vec<_>>();
                if ops.is_empty() {
                    return Err(ArtifactError::Invalid("nothing to restore".into()));
                }
                Ok(RestorePlan::Ops(ops))
            }
        }
    }

    /// Records a version for every canvas-pane drawing changed since its last version and
    /// left alone for [`IDLE_MS`] (called each second).
    pub fn idle_checkpoints(&self) {
        let now = now_millis();
        let due: Vec<(ArtifactId, Actor)> = lock(&self.state)
            .items
            .values()
            .filter(|it| {
                !it.info.canvas_panes.is_empty()
                    && it.info.version > it.history.last().map_or(0, |c| c.meta.version)
                    && now.saturating_sub(it.info.updated_at.0) >= IDLE_MS
            })
            .map(|it| (it.info.artifact_id, it.info.created_by))
            .collect();
        for (id, by) in due {
            self.checkpoint(id, by, None, None);
        }
    }
}

fn no_version(id: ArtifactId, version: u64) -> ArtifactError {
    ArtifactError::NotFound(format!("version {version} of artifact {id}"))
}

/// The elements that turn the scene `current` back into `snapshot`: each snapshot element at a
/// version above both its own and the current one (so it wins everywhere), and a tombstone
/// for every live element the snapshot did not have.
fn restore_elements(
    snapshot: &[ExElement],
    current: &HashMap<String, ExElement>,
) -> Result<Vec<ExElement>> {
    let now = now_millis();
    let bump = |el: &ExElement, deleted: bool| -> Result<ExElement> {
        let mut v: Value = serde_json::from_str(&el.json)
            .map_err(|e| ArtifactError::Failed(format!("stored element: {e}")))?;
        let above = current.get(&el.id).map_or(0, |c| c.version);
        v["version"] = (el.version.max(above) + 1).into();
        v["versionNonce"] = u32::from_le_bytes(random::<4>()).into();
        v["isDeleted"] = deleted.into();
        v["updated"] = now.into();
        drawing::parse_element(&v.to_string()).map_err(ArtifactError::Failed)
    };
    let kept: std::collections::HashSet<&str> = snapshot.iter().map(|e| e.id.as_str()).collect();
    let mut out = snapshot
        .iter()
        .map(|e| bump(e, false))
        .collect::<Result<Vec<_>>>()?;
    for el in current.values() {
        if !el.deleted && !kept.contains(el.id.as_str()) {
            out.push(bump(el, true)?);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn el(id: &str, version: u64) -> ExElement {
        drawing::parse_element(&format!(
            r#"{{"id":"{id}","type":"rectangle","version":{version},"versionNonce":5,"isDeleted":false}}"#
        ))
        .unwrap()
    }

    #[test]
    fn restored_elements_win_over_the_current_ones() {
        let snapshot = [el("a", 2), el("b", 1)];
        let current: HashMap<String, ExElement> = [el("a", 9), el("c", 3)]
            .into_iter()
            .map(|e| (e.id.clone(), e))
            .collect();
        let mut out = restore_elements(&snapshot, &current).unwrap();
        out.sort_by(|x, y| x.id.cmp(&y.id));
        let summary: Vec<(&str, u64, bool)> = out
            .iter()
            .map(|e| (e.id.as_str(), e.version, e.deleted))
            .collect();
        assert_eq!(
            summary,
            [("a", 10, false), ("b", 2, false), ("c", 4, true)],
            "a beats its newer self, b comes back, c (added later) is deleted"
        );
        for e in &out {
            assert!(drawing::wins(
                e,
                current.get(&e.id).unwrap_or(&el(&e.id, 0))
            ));
        }
    }
}
