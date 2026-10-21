//! Excalidraw scenes in the artifact store: per-element reconciliation (Excalidraw's own
//! `version` / `versionNonce` rule), files as blobs, persistence once a second.

use std::io;
use std::path::Path;

use drawing::ExScene;
use proto::{
    ArtifactError, ArtifactId, ArtifactInfo, ArtifactKind, ExElement, ExFile, ExcalidrawPut,
    ExcalidrawScene, UnixMillis,
};
use serde::{Deserialize, Serialize};

use super::{Art, Result, not_found};
use crate::core::lock;
use crate::fsutil::{read_optional, write_atomic};
use crate::identity::now_millis;

/// Longest element JSON (a long freehand line holds a few thousand points).
const ELEMENT_MAX: usize = 512 << 10;

#[derive(Serialize, Deserialize)]
struct Disk {
    revision: u64,
    elements: Vec<(ExElement, u64)>,
    app_state: Option<String>,
    files: Vec<ExFile>,
}

pub(super) fn load(dir: &Path) -> io::Result<ExScene> {
    let mut scene = ExScene::new();
    if let Some(bytes) = read_optional(&dir.join("excalidraw.bin"))? {
        let disk: Disk = postcard::from_bytes(&bytes).map_err(io::Error::other)?;
        for (el, rev) in disk.elements {
            scene.restore(el, rev);
        }
        scene.revision = scene.revision.max(disk.revision);
        scene.app_state = disk.app_state;
        scene.files = disk
            .files
            .into_iter()
            .map(|f| (f.file_id.clone(), f))
            .collect();
    }
    Ok(scene)
}

/// What a put changed, for the broadcast.
pub(crate) struct Applied {
    pub info: ArtifactInfo,
    pub won: Vec<ExElement>,
    pub lost: Vec<ExElement>,
    pub app_state: Option<String>,
    pub files: Vec<ExFile>,
}

impl Art {
    /// The scene, or what changed after `since`.
    pub fn ex_get(&self, id: ArtifactId, since: u64) -> Result<ExcalidrawScene> {
        let st = lock(&self.state);
        let it = st.items.get(&id).ok_or_else(|| not_found(id))?;
        let ex = it
            .ex
            .as_ref()
            .ok_or_else(|| ArtifactError::Invalid("not an Excalidraw scene".into()))?;
        Ok(ExcalidrawScene {
            info: it.info.clone(),
            elements: ex.changed_since(since),
            app_state: ex.app_state.clone(),
            files: ex.files.values().cloned().collect(),
        })
    }

    /// Reconciles offered elements, app state and files.
    pub fn ex_put(&self, put: ExcalidrawPut) -> Result<Applied> {
        for el in &put.elements {
            if el.json.len() > ELEMENT_MAX || el.id.len() > 256 {
                return Err(ArtifactError::TooLarge(format!(
                    "element {:.40} is over {ELEMENT_MAX} bytes",
                    el.id
                )));
            }
            // The fields we reconcile on must be the element's own.
            let parsed = drawing::parse_element(&el.json).map_err(ArtifactError::Invalid)?;
            if parsed.id != el.id
                || parsed.version != el.version
                || parsed.version_nonce != el.version_nonce
                || parsed.deleted != el.deleted
            {
                return Err(ArtifactError::Invalid(format!(
                    "element {:.40}: fields disagree with its JSON",
                    el.id
                )));
            }
        }
        if let Some(a) = &put.app_state
            && (a.len() > 64 << 10 || serde_json::from_str::<serde_json::Value>(a).is_err())
        {
            return Err(ArtifactError::Invalid(
                "app state must be JSON under 64 KiB".into(),
            ));
        }
        // Files must be stored blobs; trust our own reading of them, not the offer.
        let mut files = Vec::new();
        for f in &put.files {
            let (image, _) = self.read_blob(&f.image.hash)?;
            files.push(ExFile {
                file_id: f.file_id.clone(),
                image,
            });
        }
        let mut st = lock(&self.state);
        let it = st
            .items
            .get_mut(&put.artifact_id)
            .ok_or_else(|| not_found(put.artifact_id))?;
        if it.info.kind != ArtifactKind::Excalidraw {
            return Err(ArtifactError::Invalid("not an Excalidraw scene".into()));
        }
        let ex = it.ex.get_or_insert_with(ExScene::new);
        let mut trial = ex.clone();
        let (won, lost) = trial.merge(put.elements);
        if let Some(a) = &put.app_state {
            trial.app_state = Some(a.clone());
        }
        for f in &files {
            trial.files.insert(f.file_id.clone(), f.clone());
        }
        if trial.bytes() as u64 > self.limits.log_max {
            return Err(ArtifactError::TooLarge(format!(
                "the scene would exceed {} bytes",
                self.limits.log_max
            )));
        }
        let changed = !won.is_empty() || put.app_state.is_some() || !files.is_empty();
        if changed && trial.revision == ex.revision {
            // App state or files alone still make a new revision.
            trial.revision += 1;
        }
        *ex = trial;
        it.info.version = ex.revision;
        it.info.elements = ex.live() as u32;
        if changed {
            it.info.updated_at = UnixMillis(now_millis());
            it.ex_dirty = true;
        }
        Ok(Applied {
            info: it.info.clone(),
            won,
            lost,
            app_state: put.app_state,
            files,
        })
    }

    /// Writes every Excalidraw scene that changed (called each second and on shutdown).
    pub fn flush(&self) {
        let dirty: Vec<(ArtifactInfo, Vec<u8>)> = {
            let mut st = lock(&self.state);
            st.items
                .values_mut()
                .filter(|it| it.ex_dirty)
                .filter_map(|it| {
                    it.ex_dirty = false;
                    let ex = it.ex.as_ref()?;
                    let disk = Disk {
                        revision: ex.revision,
                        elements: ex.with_revisions().map(|(e, r)| (e.clone(), r)).collect(),
                        app_state: ex.app_state.clone(),
                        files: ex.files.values().cloned().collect(),
                    };
                    Some((it.info.clone(), postcard::to_stdvec(&disk).ok()?))
                })
                .collect()
        };
        for (info, bytes) in dirty {
            let dir = self.item_dir(&info);
            if let Err(e) = write_atomic(&dir.join("excalidraw.bin"), &bytes) {
                tracing::warn!("saving Excalidraw scene {}: {e}", info.artifact_id);
            }
            self.save_info(&info);
        }
    }

    /// The artifact as an `.excalidraw` file: a scene with its images embedded, or an image
    /// as a scene holding it (the same file `Client::excalidraw_file` builds).
    pub fn excalidraw_file(&self, id: ArtifactId) -> Result<Vec<u8>> {
        let info = self.info(id).ok_or_else(|| not_found(id))?;
        let file = match (info.kind, info.image) {
            (ArtifactKind::Excalidraw, _) => {
                let scene = self.ex_get(id, 0)?;
                let mut files = Vec::with_capacity(scene.files.len());
                for f in scene.files {
                    let (image, bytes) = self.read_blob(&f.image.hash)?;
                    files.push((f.file_id, image.media.mime().to_owned(), bytes));
                }
                drawing::ExcalidrawFile {
                    elements: scene.elements,
                    app_state: scene.app_state,
                    files,
                }
            }
            (ArtifactKind::Image, Some(image)) => {
                let (image, bytes) = self.read_blob(&image.hash)?;
                drawing::ExcalidrawFile::from_image(
                    &image.hash.to_hex(),
                    image.media.mime(),
                    bytes,
                    image.width,
                    image.height,
                )
            }
            _ => {
                return Err(ArtifactError::Invalid(
                    "ink drawings export as PNG or SVG".into(),
                ));
            }
        };
        Ok(file.to_json().into_bytes())
    }

    /// Creates an Excalidraw scene from a parsed `.excalidraw` file (images stored as blobs).
    pub fn ex_import(
        &self,
        actor: proto::Actor,
        session: proto::SessionId,
        name: &str,
        file: drawing::ExcalidrawFile,
    ) -> Result<ArtifactInfo> {
        let mut files = Vec::new();
        for (file_id, _mime, bytes) in &file.files {
            if let Ok(image) = self.put_blob(bytes) {
                files.push(ExFile {
                    file_id: file_id.clone(),
                    image,
                });
            }
        }
        let (info, _) = self.create(
            actor,
            &proto::ArtifactCreate {
                session_id: session,
                kind: ArtifactKind::Excalidraw,
                title: name.to_owned(),
                space: proto::CoordSpace::Canvas,
                anchor: None,
                image: None,
                ops: Vec::new(),
            },
            None,
        )?;
        let applied = self.ex_put(ExcalidrawPut {
            artifact_id: info.artifact_id,
            base: 0,
            elements: file.elements,
            app_state: file.app_state,
            files,
        });
        match applied {
            Ok(a) => Ok(a.info),
            Err(e) => {
                let _ = self.delete(info.artifact_id);
                Err(e)
            }
        }
    }
}
