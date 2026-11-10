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
        for (element, revision) in disk.elements {
            scene.restore(element, revision);
        }
        scene.revision = scene.revision.max(disk.revision);
        scene.app_state = disk.app_state;
        scene.files = disk
            .files
            .into_iter()
            .map(|ex_file| (ex_file.file_id.clone(), ex_file))
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
    pub fn ex_get(&self, id: ArtifactId, since: u64) -> Result<ExcalidrawScene> {
        let state = lock(&self.state);
        let item = state.items.get(&id).ok_or_else(|| not_found(id))?;
        let scene = item
            .ex
            .as_ref()
            .ok_or_else(|| ArtifactError::Invalid("not an Excalidraw scene".into()))?;
        Ok(ExcalidrawScene {
            info: item.info.clone(),
            elements: scene.changed_since(since),
            app_state: scene.app_state.clone(),
            files: scene.files.values().cloned().collect(),
        })
    }

    /// Reconciles offered elements, app state and files.
    pub fn ex_put(&self, put: ExcalidrawPut) -> Result<Applied> {
        for element in &put.elements {
            if element.json.len() > ELEMENT_MAX || element.id.len() > 256 {
                return Err(ArtifactError::TooLarge(format!(
                    "element {:.40} is over {ELEMENT_MAX} bytes",
                    element.id
                )));
            }
            // The fields we reconcile on must be the element's own.
            let parsed = drawing::parse_element(&element.json).map_err(ArtifactError::Invalid)?;
            if parsed.id != element.id
                || parsed.version != element.version
                || parsed.version_nonce != element.version_nonce
                || parsed.deleted != element.deleted
            {
                return Err(ArtifactError::Invalid(format!(
                    "element {:.40}: fields disagree with its JSON",
                    element.id
                )));
            }
        }
        if let Some(app_state) = &put.app_state
            && (app_state.len() > 64 << 10
                || serde_json::from_str::<serde_json::Value>(app_state).is_err())
        {
            return Err(ArtifactError::Invalid(
                "app state must be JSON under 64 KiB".into(),
            ));
        }
        // Files must be stored blobs; trust our own reading of them, not the offer.
        let mut files = Vec::new();
        for offered in &put.files {
            let image = self.blob_info(&offered.image.hash)?;
            files.push(ExFile {
                file_id: offered.file_id.clone(),
                image,
            });
        }
        let mut state = lock(&self.state);
        let item = state
            .items
            .get_mut(&put.artifact_id)
            .ok_or_else(|| not_found(put.artifact_id))?;
        if item.info.kind != ArtifactKind::Excalidraw {
            return Err(ArtifactError::Invalid("not an Excalidraw scene".into()));
        }
        let scene = item.ex.get_or_insert_with(ExScene::new);
        let mut trial = scene.clone();
        let (won, lost) = trial.merge(put.elements);
        if let Some(app_state) = &put.app_state {
            trial.app_state = Some(app_state.clone());
        }
        for ex_file in &files {
            trial.files.insert(ex_file.file_id.clone(), ex_file.clone());
        }
        if trial.bytes() as u64 > self.limits.log_max {
            return Err(ArtifactError::TooLarge(format!(
                "the scene would exceed {} bytes",
                self.limits.log_max
            )));
        }
        let changed = !won.is_empty() || put.app_state.is_some() || !files.is_empty();
        if changed && trial.revision == scene.revision {
            // App state or files alone still make a new revision.
            trial.revision += 1;
        }
        *scene = trial;
        item.info.version = scene.revision;
        item.info.elements = scene.live() as u32;
        if changed {
            item.info.updated_at = UnixMillis(now_millis());
            item.ex_dirty = true;
        }
        Ok(Applied {
            info: item.info.clone(),
            won,
            lost,
            app_state: put.app_state,
            files,
        })
    }

    /// Writes every Excalidraw scene that changed (called each second and on shutdown).
    pub fn flush(&self) {
        let dirty: Vec<(ArtifactInfo, Vec<u8>)> = {
            let mut state = lock(&self.state);
            state
                .items
                .values_mut()
                .filter(|item| item.ex_dirty)
                .filter_map(|item| {
                    item.ex_dirty = false;
                    let scene = item.ex.as_ref()?;
                    let disk = Disk {
                        revision: scene.revision,
                        elements: scene
                            .with_revisions()
                            .map(|(element, revision)| (element.clone(), revision))
                            .collect(),
                        app_state: scene.app_state.clone(),
                        files: scene.files.values().cloned().collect(),
                    };
                    Some((item.info.clone(), postcard::to_stdvec(&disk).ok()?))
                })
                .collect()
        };
        for (info, bytes) in dirty {
            let dir = self.item_dir(&info);
            if let Err(error) = write_atomic(&dir.join("excalidraw.bin"), &bytes) {
                tracing::warn!("saving Excalidraw scene {}: {error}", info.artifact_id);
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
                for ex_file in scene.files {
                    let (image, bytes) = self.read_blob(&ex_file.image.hash)?;
                    files.push((ex_file.file_id, image.media.mime().to_owned(), bytes));
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
            Ok(applied) => Ok(applied.info),
            Err(error) => {
                let _ = self.delete(info.artifact_id);
                Err(error)
            }
        }
    }
}
