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
        self.scene.as_ref().map_or(0, |snapshot| {
            snapshot
                .elements
                .iter()
                .map(|element| element.json.len())
                .sum::<usize>()
                + snapshot.app_state.as_ref().map_or(0, String::len)
        })
    }

    /// Blobs this checkpoint keeps alive.
    pub fn blobs(&self) -> impl Iterator<Item = &ImageRef> {
        self.meta.image.iter().chain(
            self.scene
                .iter()
                .flat_map(|snapshot| snapshot.files.iter().map(|file| &file.image)),
        )
    }
}

/// What a restore writes, for the caller to apply through the ordinary paths (so the change
/// is broadcast like any other).
pub(crate) enum RestorePlan {
    Excalidraw(ExcalidrawPut),
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
        let mut state = lock(&self.state);
        let item = state.items.get_mut(&id)?;
        if item.info.kind == ArtifactKind::Image || item.info.version == 0 {
            return None;
        }
        let version = item.info.version;
        let entry = match item.history.last_mut() {
            Some(last) if last.meta.version == version => {
                if image.is_none() || last.meta.image == image {
                    return Some(last.meta.clone());
                }
                last.meta.image = image;
                last.meta.clone()
            }
            _ => {
                let scene = item.ex.as_ref().map(|live_scene| ExSnapshot {
                    elements: live_scene
                        .with_revisions()
                        .map(|(element, _)| element)
                        .filter(|element| !element.deleted)
                        .cloned()
                        .collect(),
                    app_state: live_scene.app_state.clone(),
                    files: live_scene.files.values().cloned().collect(),
                });
                let meta = ArtifactVersion {
                    version,
                    at: UnixMillis(now_millis()),
                    by,
                    image,
                    elements: item.info.elements,
                    restored_from,
                };
                item.history.push(Checkpoint {
                    meta: meta.clone(),
                    scene,
                });
                // A drawing's history stays within four times its own size cap.
                let budget = self.limits.log_max as usize * 4;
                while item.history.len() > KEEP
                    || (item.history.len() > 1
                        && item.history.iter().map(Checkpoint::bytes).sum::<usize>() > budget)
                {
                    item.history.remove(0);
                }
                meta
            }
        };
        let (info, bytes) = (item.info.clone(), postcard::to_stdvec(&item.history));
        drop(state);
        let path = self.item_dir(&info).join("history.bin");
        if let Err(error) = bytes
            .map_err(std::io::Error::other)
            .and_then(|bytes| write_atomic(&path, &bytes))
        {
            tracing::warn!("saving {}: {error}", path.display());
        }
        Some(entry)
    }

    /// The drawing's recorded versions, newest first (none for images).
    pub fn history(&self, id: ArtifactId) -> Result<Vec<ArtifactVersion>> {
        let state = lock(&self.state);
        let item = state.items.get(&id).ok_or_else(|| not_found(id))?;
        Ok(item
            .history
            .iter()
            .rev()
            .map(|checkpoint| checkpoint.meta.clone())
            .collect())
    }

    pub fn history_entry(&self, id: ArtifactId, version: u64) -> Result<ArtifactVersion> {
        let state = lock(&self.state);
        let item = state.items.get(&id).ok_or_else(|| not_found(id))?;
        item.history
            .iter()
            .rfind(|checkpoint| checkpoint.meta.version == version)
            .map(|checkpoint| checkpoint.meta.clone())
            .ok_or_else(|| no_version(id, version))
    }

    /// What bringing back `version` writes on top of the current one.
    pub fn restore_plan(&self, id: ArtifactId, version: u64) -> Result<RestorePlan> {
        let (kind, snapshot) = {
            let state = lock(&self.state);
            let item = state.items.get(&id).ok_or_else(|| not_found(id))?;
            let checkpoint = item
                .history
                .iter()
                .rfind(|checkpoint| checkpoint.meta.version == version)
                .ok_or_else(|| no_version(id, version))?;
            (item.info.kind, checkpoint.scene.clone())
        };
        match kind {
            ArtifactKind::Image => Err(ArtifactError::Invalid("images have no versions".into())),
            ArtifactKind::Excalidraw => {
                let snapshot = snapshot.ok_or_else(|| {
                    ArtifactError::Failed(format!("version {version} kept no content"))
                })?;
                let current: HashMap<String, ExElement> = {
                    let state = lock(&self.state);
                    let live_scene = state.items.get(&id).and_then(|item| item.ex.as_ref());
                    live_scene
                        .map(|live_scene| {
                            live_scene
                                .with_revisions()
                                .map(|(element, _)| (element.id.clone(), element.clone()))
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
                    .map(|element| DrawOp::Delete { id: element.id })
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
            .filter(|item| {
                !item.info.canvas_panes.is_empty()
                    && item.info.version
                        > item
                            .history
                            .last()
                            .map_or(0, |checkpoint| checkpoint.meta.version)
                    && now.saturating_sub(item.info.updated_at.0) >= IDLE_MS
            })
            .map(|item| (item.info.artifact_id, item.info.created_by))
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
    let bump = |element: &ExElement, deleted: bool| -> Result<ExElement> {
        let mut json: Value = serde_json::from_str(&element.json)
            .map_err(|error| ArtifactError::Failed(format!("stored element: {error}")))?;
        let above = current
            .get(&element.id)
            .map_or(0, |existing| existing.version);
        json["version"] = (element.version.max(above) + 1).into();
        json["versionNonce"] = u32::from_le_bytes(random::<4>()).into();
        json["isDeleted"] = deleted.into();
        json["updated"] = now.into();
        drawing::parse_element(&json.to_string()).map_err(ArtifactError::Failed)
    };
    let kept: std::collections::HashSet<&str> =
        snapshot.iter().map(|element| element.id.as_str()).collect();
    let mut restored = snapshot
        .iter()
        .map(|element| bump(element, false))
        .collect::<Result<Vec<_>>>()?;
    for element in current.values() {
        if !element.deleted && !kept.contains(element.id.as_str()) {
            restored.push(bump(element, true)?);
        }
    }
    Ok(restored)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn element_at(id: &str, version: u64) -> ExElement {
        drawing::parse_element(&format!(
            r#"{{"id":"{id}","type":"rectangle","version":{version},"versionNonce":5,"isDeleted":false}}"#
        ))
        .unwrap()
    }

    #[test]
    fn restored_elements_win_over_the_current_ones() {
        let snapshot = [element_at("a", 2), element_at("b", 1)];
        let current: HashMap<String, ExElement> = [element_at("a", 9), element_at("c", 3)]
            .into_iter()
            .map(|element| (element.id.clone(), element))
            .collect();
        let mut restored = restore_elements(&snapshot, &current).unwrap();
        restored.sort_by(|x, y| x.id.cmp(&y.id));
        let summary: Vec<(&str, u64, bool)> = restored
            .iter()
            .map(|element| (element.id.as_str(), element.version, element.deleted))
            .collect();
        assert_eq!(
            summary,
            [("a", 10, false), ("b", 2, false), ("c", 4, true)],
            "a beats its newer self, b comes back, c (added later) is deleted"
        );
        for element in &restored {
            assert!(drawing::wins(
                element,
                current
                    .get(&element.id)
                    .unwrap_or(&element_at(&element.id, 0))
            ));
        }
    }
}
