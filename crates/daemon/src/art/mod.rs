//! The artifact store: drawings and images per session, versioned with an op log,
//! content-addressed blobs, canvas panes, ink anchors, exports and "send to agent".
//! See `docs/DAEMON.md` §7.
//!
//! On disk, under `<state>/artifacts/`:
//!
//! ```text
//! index.bin                      next id, canvas panes (postcard)
//! blobs/<sha256 hex>             images and PNGs, shared by every session
//! <session>/<artifact>/info.bin  ArtifactInfo (postcard), rewritten atomically on change
//! <session>/<artifact>/ops.log   [u32 LE len][postcard OpBatch]…, appended per batch
//! <session>/<artifact>/excalidraw.bin  an Excalidraw scene (postcard), written each second
//!                                when it changed
//! <session>/<artifact>/history.bin     finished versions (postcard, `history.rs`)
//! <session>/send/<id>@<v>.png    files pasted into agent panes
//! ```
//!
//! The daemon orders batches; every client applies them in version order and converges.

pub(crate) mod ex;
pub(crate) mod history;
pub(crate) mod place;
pub(crate) mod pull;
pub(crate) mod send;

use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::{self, Seek, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use drawing::Scene;
use proto::{
    Actor, AnchorRequest, AnchorState, ArtifactCreate, ArtifactError, ArtifactId, ArtifactInfo,
    ArtifactKind, ArtifactScene, BlobHash, CanvasPane, CoordSpace, DetachReason, DrawOp,
    ElementKind, ExportFormat, Exported, ImageRef, OpBatch, PaneId, Preview, RowAnchor, SessionId,
    UnixMillis,
};
use serde::{Deserialize, Serialize};

use crate::anchor::AnchorPos;
use crate::config::ArtifactLimits;
use crate::core::{Core, lock};
use crate::fsutil::{read_optional, write_atomic};
use crate::identity::now_millis;

/// Inline answers (exports, PNG sources) stay under this size; larger ones go through blobs.
pub(crate) const INLINE_MAX: usize = 1 << 20;
const TEXT_MAX: usize = 16 << 10;
const ELEMENTS_MAX: usize = 20_000;

type Result<T> = std::result::Result<T, ArtifactError>;

fn failed(error: impl std::fmt::Display) -> ArtifactError {
    ArtifactError::Failed(error.to_string())
}

fn not_found(id: ArtifactId) -> ArtifactError {
    ArtifactError::NotFound(format!("artifact {id}"))
}

/// A drawing's next batch, ready to be written to its log.
struct Prepared {
    batch: OpBatch,
    encoded: Vec<u8>,
    scene: Scene,
    dir: PathBuf,
}

/// A blob arriving in pieces ([`Art::begin_blob`]); dropped unfinished, it leaves nothing.
pub(crate) struct BlobUpload {
    temp: TempFile,
    file: fs::File,
    digest: ring::digest::Context,
    size: u64,
}

impl BlobUpload {
    pub fn write(&mut self, bytes: &[u8]) -> Result<()> {
        self.digest.update(bytes);
        self.size += bytes.len() as u64;
        self.file.write_all(bytes).map_err(failed)
    }
}

/// Removed when dropped (a no-op once it was renamed into place).
struct TempFile(PathBuf);

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Index {
    next_id: u64,
    canvases: Vec<CanvasPane>,
    next_placement: u64,
    placements: Vec<proto::Placement>,
}

struct Item {
    info: ArtifactInfo,
    scene: Scene,
    log: Vec<OpBatch>,
    log_bytes: u64,
    /// Excalidraw scenes only.
    ex: Option<drawing::ExScene>,
    /// The Excalidraw scene changed since it was last written.
    ex_dirty: bool,
    /// Recorded versions, oldest first.
    history: Vec<history::Checkpoint>,
}

#[derive(Default)]
struct State {
    next_id: u64,
    items: BTreeMap<ArtifactId, Item>,
    canvases: BTreeMap<PaneId, ArtifactId>,
    next_placement: u64,
    placements: BTreeMap<u64, proto::Placement>,
    /// Anchor key of each placement made in this run.
    anchor_keys: std::collections::HashMap<u64, u64>,
    /// Bytes of blobs and op logs on disk.
    total: u64,
}

pub(crate) struct Art {
    dir: PathBuf,
    pub limits: ArtifactLimits,
    state: Mutex<State>,
    /// Held by the one batch being written to a drawing's log ([`Art::apply`]).
    log_writer: Mutex<()>,
}

impl Art {
    /// Loads the store; artifacts whose files are unreadable are skipped (and logged).
    pub fn open(state_dir: &Path, limits: ArtifactLimits) -> Self {
        let dir = state_dir.join("artifacts");
        let art = Self {
            dir,
            limits,
            state: Mutex::new(State {
                next_id: 1,
                ..State::default()
            }),
            log_writer: Mutex::new(()),
        };
        if let Err(error) = art.load() {
            tracing::warn!("loading artifacts: {error}");
        }
        art.gc_blobs(true);
        art
    }

    fn load(&self) -> io::Result<()> {
        let mut state = lock(&self.state);
        if let Some(bytes) = read_optional(&self.dir.join("index.bin"))? {
            let index: Index = postcard::from_bytes(&bytes).map_err(io::Error::other)?;
            state.next_id = index.next_id.max(1);
            state.canvases = index
                .canvases
                .into_iter()
                .map(|c| (c.pane_id, c.artifact_id))
                .collect();
            state.next_placement = index.next_placement.max(1);
            // Inline placements lose their rows with the terminal state.
            state.placements = index
                .placements
                .into_iter()
                .map(|mut placement| {
                    if placement.anchor.state == AnchorState::Live {
                        placement.anchor.state = AnchorState::Detached(DetachReason::DaemonRestart);
                    }
                    (placement.placement_id, placement)
                })
                .collect();
        }
        let Ok(sessions) = fs::read_dir(&self.dir) else {
            return Ok(());
        };
        for session in sessions.flatten() {
            if !session.path().is_dir() || session.file_name() == "blobs" {
                continue;
            }
            let Ok(item_dirs) = fs::read_dir(session.path()) else {
                continue;
            };
            for item_dir in item_dirs.flatten() {
                match load_item(&item_dir.path()) {
                    Ok(Some(item)) => {
                        state.next_id = state.next_id.max(item.info.artifact_id.0 + 1);
                        state.total += item.log_bytes;
                        state.items.insert(item.info.artifact_id, item);
                    }
                    Ok(None) => {}
                    Err(error) => tracing::warn!("artifact {}: {error}", item_dir.path().display()),
                }
            }
        }
        let State {
            items, canvases, ..
        } = &mut *state;
        canvases.retain(|_, artifact| items.contains_key(artifact));
        for (pane, artifact) in canvases.iter() {
            if let Some(item) = items.get_mut(artifact)
                && !item.info.canvas_panes.contains(pane)
            {
                item.info.canvas_panes.push(*pane);
            }
        }
        if let Ok(blobs) = fs::read_dir(self.dir.join("blobs")) {
            state.total += blobs
                .flatten()
                .filter_map(|blob| blob.metadata().ok())
                .map(|m| m.len())
                .sum::<u64>();
        }
        Ok(())
    }

    fn item_dir(&self, info: &ArtifactInfo) -> PathBuf {
        self.dir
            .join(info.session_id.0.to_string())
            .join(info.artifact_id.0.to_string())
    }

    fn save_info(&self, info: &ArtifactInfo) {
        let path = self.item_dir(info).join("info.bin");
        let result = postcard::to_stdvec(info)
            .map_err(io::Error::other)
            .and_then(|bytes| write_atomic(&path, &bytes));
        if let Err(error) = result {
            tracing::warn!("saving {}: {error}", path.display());
        }
    }

    fn save_index(&self, state: &State) {
        let index = Index {
            next_id: state.next_id,
            next_placement: state.next_placement,
            placements: state.placements.values().cloned().collect(),
            canvases: state
                .canvases
                .iter()
                .map(|(&pane_id, &artifact_id)| CanvasPane {
                    pane_id,
                    artifact_id,
                })
                .collect(),
        };
        let result = postcard::to_stdvec(&index)
            .map_err(io::Error::other)
            .and_then(|bytes| write_atomic(&self.dir.join("index.bin"), &bytes));
        if let Err(error) = result {
            tracing::warn!("saving artifact index: {error}");
        }
    }

    pub fn blob_path(&self, hash: &BlobHash) -> PathBuf {
        self.dir.join("blobs").join(hash.to_hex())
    }

    pub fn put_blob(&self, bytes: &[u8]) -> Result<ImageRef> {
        let (media, width, height) = drawing::sniff(bytes)
            .ok_or_else(|| ArtifactError::Invalid("not a PNG or JPEG image".into()))?;
        let size = bytes.len() as u64;
        if size > self.limits.blob_max {
            return Err(ArtifactError::TooLarge(format!(
                "image of {size} bytes; the limit is {}",
                self.limits.blob_max
            )));
        }
        let hash = BlobHash(grants::sha256(&[bytes]));
        let path = self.blob_path(&hash);
        let image = ImageRef {
            hash,
            media,
            size,
            width,
            height,
        };
        if path.exists() {
            // Touch it so a pending garbage collection keeps it.
            let _ = fs::File::options()
                .append(true)
                .open(&path)
                .and_then(|file| file.set_modified(std::time::SystemTime::now()));
            return Ok(image);
        }
        self.reserve(size)?;
        write_atomic(&path, bytes).map_err(failed)?;
        Ok(image)
    }

    pub fn read_blob(&self, hash: &BlobHash) -> Result<(ImageRef, Vec<u8>)> {
        let bytes = fs::read(self.blob_path(hash))
            .map_err(|_| ArtifactError::NotFound(format!("blob {}", hash.to_hex())))?;
        let (media, width, height) = drawing::sniff(&bytes)
            .ok_or_else(|| ArtifactError::Failed("stored blob is not an image".into()))?;
        Ok((
            ImageRef {
                hash: *hash,
                media,
                size: bytes.len() as u64,
                width,
                height,
            },
            bytes,
        ))
    }

    /// The blob's image facts and its file, at the start, reading only the image's headers.
    pub fn open_blob(&self, hash: &BlobHash) -> Result<(ImageRef, fs::File)> {
        let file = fs::File::open(self.blob_path(hash))
            .map_err(|_| ArtifactError::NotFound(format!("blob {}", hash.to_hex())))?;
        let size = file.metadata().map_err(failed)?.len();
        let mut reader = io::BufReader::new(file);
        let (media, width, height) = drawing::sniff_reader(&mut reader)
            .ok_or_else(|| ArtifactError::Failed("stored blob is not an image".into()))?;
        let mut file = reader.into_inner();
        file.seek(io::SeekFrom::Start(0)).map_err(failed)?;
        let image = ImageRef {
            hash: *hash,
            media,
            size,
            width,
            height,
        };
        Ok((image, file))
    }

    /// The blob's image facts, without reading it.
    pub fn blob_info(&self, hash: &BlobHash) -> Result<ImageRef> {
        self.open_blob(hash).map(|(image, _)| image)
    }

    /// Starts storing a blob that arrives in pieces, into a temporary file next to the blobs.
    pub fn begin_blob(&self) -> Result<BlobUpload> {
        let dir = self.dir.join("blobs");
        fs::create_dir_all(&dir).map_err(failed)?;
        let temp_path = dir.join(format!(
            ".upload-{}",
            crate::fsutil::hex(&crate::fsutil::random::<12>())
        ));
        let file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp_path)
            .map_err(failed)?;
        Ok(BlobUpload {
            temp: TempFile(temp_path),
            file,
            digest: ring::digest::Context::new(&ring::digest::SHA256),
            size: 0,
        })
    }

    /// Stores the blob `upload` received, unless the store holds it already.
    pub fn finish_blob(&self, upload: BlobUpload) -> Result<ImageRef> {
        let BlobUpload {
            temp,
            file,
            digest,
            size,
        } = upload;
        file.sync_all().map_err(failed)?;
        let mut reader = io::BufReader::new(fs::File::open(&temp.0).map_err(failed)?);
        let (media, width, height) = drawing::sniff_reader(&mut reader)
            .ok_or_else(|| ArtifactError::Invalid("not a PNG or JPEG image".into()))?;
        let hash = BlobHash(
            digest
                .finish()
                .as_ref()
                .try_into()
                .expect("SHA-256 is 32 bytes"),
        );
        let image = ImageRef {
            hash,
            media,
            size,
            width,
            height,
        };
        let path = self.blob_path(&hash);
        if path.exists() {
            // Touch it so a pending garbage collection keeps it.
            let _ = fs::File::options()
                .append(true)
                .open(&path)
                .and_then(|file| file.set_modified(std::time::SystemTime::now()));
            return Ok(image);
        }
        self.reserve(size)?;
        let stored = fs::rename(&temp.0, &path)
            .and_then(|()| fs::File::open(self.dir.join("blobs"))?.sync_all());
        if let Err(error) = stored {
            lock(&self.state).total -= size;
            return Err(failed(error));
        }
        Ok(image)
    }

    /// Room for `bytes` more under the store's cap.
    pub fn reserve(&self, bytes: u64) -> Result<()> {
        let mut state = lock(&self.state);
        if state.total + bytes > self.limits.total_max {
            return Err(ArtifactError::TooLarge(format!(
                "the host's artifact store is full ({} of {} bytes)",
                state.total, self.limits.total_max
            )));
        }
        state.total += bytes;
        Ok(())
    }

    /// Deletes blobs no artifact references (older than ten minutes unless `all`, so uploads
    /// waiting for their `Create` survive).
    fn gc_blobs(&self, all: bool) {
        let referenced: HashSet<String> = {
            let state = lock(&self.state);
            state
                .items
                .values()
                .flat_map(|item| {
                    let mut refs: Vec<String> = item
                        .info
                        .image
                        .iter()
                        .map(|i| i.hash.to_hex())
                        .chain(item.info.preview.iter().map(|p| p.image.hash.to_hex()))
                        .collect();
                    if let Some(ex) = &item.ex {
                        refs.extend(ex.files.values().map(|f| f.image.hash.to_hex()));
                    }
                    for checkpoint in &item.history {
                        refs.extend(checkpoint.blobs().map(|image| image.hash.to_hex()));
                    }
                    for batch in &item.log {
                        for op in &batch.ops {
                            if let DrawOp::Add(element) = op
                                && let ElementKind::Image { image, .. } = &element.kind
                            {
                                refs.push(image.hash.to_hex());
                            }
                        }
                    }
                    refs
                })
                .chain(
                    state
                        .placements
                        .values()
                        .map(|placement| placement.image.hash.to_hex()),
                )
                .collect()
        };
        let Ok(blobs) = fs::read_dir(self.dir.join("blobs")) else {
            return;
        };
        let grace = std::time::Duration::from_secs(if all { 3600 } else { 600 });
        let mut freed = 0;
        for blob in blobs.flatten() {
            let name = blob.file_name().to_string_lossy().into_owned();
            if referenced.contains(&name) {
                continue;
            }
            let Ok(meta) = blob.metadata() else { continue };
            let young = meta
                .modified()
                .ok()
                .and_then(|modified| modified.elapsed().ok())
                .is_none_or(|age| age < grace);
            if young {
                continue;
            }
            if fs::remove_file(blob.path()).is_ok() {
                freed += meta.len();
            }
        }
        let mut state = lock(&self.state);
        state.total = state.total.saturating_sub(freed);
    }

    pub fn info(&self, id: ArtifactId) -> Option<ArtifactInfo> {
        lock(&self.state)
            .items
            .get(&id)
            .map(|item| item.info.clone())
    }

    pub fn list(&self, session: SessionId) -> Vec<ArtifactInfo> {
        lock(&self.state)
            .items
            .values()
            .filter(|item| item.info.session_id == session)
            .map(|item| item.info.clone())
            .collect()
    }

    /// Batches after `since`, or every element.
    pub fn scene(&self, id: ArtifactId, since: u64) -> Result<ArtifactScene> {
        let state = lock(&self.state);
        let item = state.items.get(&id).ok_or_else(|| not_found(id))?;
        let version = item.info.version;
        let (elements, batches) = if since > 0 && since <= version {
            (None, item.log[since as usize..].to_vec())
        } else {
            (Some(item.scene.elements().to_vec()), Vec::new())
        };
        Ok(ArtifactScene {
            info: item.info.clone(),
            elements,
            batches,
        })
    }

    /// The scene at `version` (replayed from the log), with the artifact's info.
    pub fn scene_at(&self, id: ArtifactId, version: Option<u64>) -> Result<(ArtifactInfo, Scene)> {
        let state = lock(&self.state);
        let item = state.items.get(&id).ok_or_else(|| not_found(id))?;
        if let Some(ex) = &item.ex {
            // Excalidraw keeps the latest state of each element, not its history.
            if version.is_some_and(|v| v != item.info.version) {
                return Err(ArtifactError::NotFound(format!(
                    "Excalidraw scenes keep only their current revision ({})",
                    item.info.version
                )));
            }
            return Ok((item.info.clone(), ex.to_scene()));
        }
        let version = version.unwrap_or(item.info.version);
        if version > item.info.version {
            return Err(ArtifactError::NotFound(format!(
                "version {version} of artifact {id} (it is at {})",
                item.info.version
            )));
        }
        if version == item.info.version {
            return Ok((item.info.clone(), item.scene.clone()));
        }
        let mut scene = Scene::new();
        for batch in &item.log[..version as usize] {
            let _ = scene.apply(batch);
        }
        Ok((item.info.clone(), scene))
    }

    pub fn session_count(&self, session: SessionId) -> usize {
        lock(&self.state)
            .items
            .values()
            .filter(|item| item.info.session_id == session)
            .count()
    }

    /// Creates an artifact. The anchor is resolved by the caller (it needs the pane).
    pub fn create(
        &self,
        actor: Actor,
        request: &ArtifactCreate,
        anchor: Option<RowAnchor>,
    ) -> Result<(ArtifactInfo, Option<OpBatch>)> {
        if self.session_count(request.session_id) >= self.limits.per_session {
            return Err(ArtifactError::TooLarge(format!(
                "a session holds at most {} artifacts",
                self.limits.per_session
            )));
        }
        let image = match (request.kind, request.image) {
            (ArtifactKind::Image, Some(hash)) => Some(self.blob_info(&hash)?),
            (ArtifactKind::Image, None) => {
                return Err(ArtifactError::Invalid(
                    "an image artifact needs its blob".into(),
                ));
            }
            (ArtifactKind::Drawing | ArtifactKind::Excalidraw, Some(_)) => {
                return Err(ArtifactError::Invalid(
                    "place images in drawings with an Image element".into(),
                ));
            }
            (ArtifactKind::Drawing | ArtifactKind::Excalidraw, None) => None,
        };
        if request.kind != ArtifactKind::Drawing && !request.ops.is_empty() {
            return Err(ArtifactError::Invalid(
                "only drawings take ops (Excalidraw scenes take ExcalidrawPut)".into(),
            ));
        }
        let now = UnixMillis(now_millis());
        let mut state = lock(&self.state);
        let id = ArtifactId(state.next_id);
        state.next_id += 1;
        let info = ArtifactInfo {
            artifact_id: id,
            session_id: request.session_id,
            kind: request.kind,
            title: request.title.clone(),
            space: request.space,
            created_by: actor,
            created_at: now,
            updated_at: now,
            version: 0,
            elements: 0,
            image,
            preview: None,
            anchor,
            canvas_panes: Vec::new(),
        };
        state.items.insert(
            id,
            Item {
                info: info.clone(),
                scene: Scene::new(),
                log: Vec::new(),
                log_bytes: 0,
                ex: (request.kind == ArtifactKind::Excalidraw).then(drawing::ExScene::new),
                ex_dirty: false,
                history: Vec::new(),
            },
        );
        self.save_index(&state);
        drop(state);
        if let Err(error) = fs::create_dir_all(self.item_dir(&info)) {
            tracing::warn!("artifact dir: {error}");
        }
        self.save_info(&info);
        if request.ops.is_empty() {
            return Ok((info, None));
        }
        match self.apply(id, actor, request.ops.clone()) {
            Ok((info, batch)) => Ok((info, Some(batch))),
            Err(error) => {
                let _ = self.delete(id);
                Err(error)
            }
        }
    }

    /// Commits `ops` as the next batch. Blocks while another batch is written (call it off the
    /// async workers); the state lock is not held while the log is written and synced, so
    /// readers of the store never wait for the disk.
    pub fn apply(
        &self,
        id: ArtifactId,
        actor: Actor,
        ops: Vec<DrawOp>,
    ) -> Result<(ArtifactInfo, OpBatch)> {
        validate(&ops)?;
        // The single writer: nothing else changes a drawing between its batch being prepared
        // and committed.
        let _writer = lock(&self.log_writer);
        let prepared = self.prepare_batch(id, actor, ops)?;
        let mut frame = (prepared.encoded.len() as u32).to_le_bytes().to_vec();
        frame.extend_from_slice(&prepared.encoded);
        let appended = fs::create_dir_all(&prepared.dir).and_then(|()| {
            let mut log_file = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(prepared.dir.join("ops.log"))?;
            log_file.write_all(&frame)?;
            log_file.sync_data()
        });
        let added = frame.len() as u64;
        let mut state = lock(&self.state);
        let committed = appended
            .map_err(|error| failed(format!("writing the drawing's log: {error}")))
            .and_then(|()| state.items.get_mut(&id).ok_or_else(|| not_found(id)));
        let item = match committed {
            Ok(item) => item,
            Err(error) => {
                state.total -= added;
                return Err(error);
            }
        };
        let batch = prepared.batch;
        item.scene = prepared.scene;
        item.log.push(batch.clone());
        item.log_bytes += added;
        item.info.version = batch.version;
        item.info.updated_at = batch.at;
        item.info.elements = item.scene.elements().len() as u32;
        if let Some(title) = &item.scene.title {
            item.info.title.clone_from(title);
        }
        let info = item.info.clone();
        drop(state);
        self.save_info(&info);
        Ok((info, batch))
    }

    /// The next batch of drawing `id` with its new scene, checked against the caps, its bytes
    /// reserved in the store.
    fn prepare_batch(&self, id: ArtifactId, actor: Actor, ops: Vec<DrawOp>) -> Result<Prepared> {
        let mut state = lock(&self.state);
        let item = state.items.get_mut(&id).ok_or_else(|| not_found(id))?;
        if item.info.kind != ArtifactKind::Drawing {
            return Err(ArtifactError::Invalid(
                "only drawings take ops (Excalidraw scenes take ExcalidrawPut)".into(),
            ));
        }
        let batch = OpBatch {
            version: item.info.version + 1,
            actor,
            at: UnixMillis(now_millis()),
            ops,
        };
        let encoded = postcard::to_stdvec(&batch).map_err(failed)?;
        if encoded.len() as u64 > self.limits.batch_max {
            return Err(ArtifactError::TooLarge(format!(
                "a change of {} bytes; the limit is {}",
                encoded.len(),
                self.limits.batch_max
            )));
        }
        if item.log_bytes + encoded.len() as u64 + 4 > self.limits.log_max {
            return Err(ArtifactError::TooLarge(format!(
                "the drawing's history would exceed {} bytes",
                self.limits.log_max
            )));
        }
        let mut scene = item.scene.clone();
        scene
            .apply(&batch)
            .map_err(|error| failed(format!("{error:?}")))?;
        if scene.elements().len() > ELEMENTS_MAX {
            return Err(ArtifactError::TooLarge(format!(
                "a drawing holds at most {ELEMENTS_MAX} elements"
            )));
        }
        let dir = self.item_dir(&item.info);
        let added = encoded.len() as u64 + 4;
        if state.total + added > self.limits.total_max {
            return Err(ArtifactError::TooLarge(
                "the host's artifact store is full".into(),
            ));
        }
        state.total += added;
        Ok(Prepared {
            batch,
            encoded,
            scene,
            dir,
        })
    }

    /// Changes an artifact's info with `change` and saves it.
    pub fn update(
        &self,
        id: ArtifactId,
        change: impl FnOnce(&mut ArtifactInfo),
    ) -> Result<ArtifactInfo> {
        let info = {
            let mut state = lock(&self.state);
            let item = state.items.get_mut(&id).ok_or_else(|| not_found(id))?;
            change(&mut item.info);
            item.info.clone()
        };
        self.save_info(&info);
        Ok(info)
    }

    /// Deletes an artifact; returns its info (canvas panes included) for the caller to close
    /// them and tell clients.
    pub fn delete(&self, id: ArtifactId) -> Result<ArtifactInfo> {
        let info = {
            let mut state = lock(&self.state);
            let item = state.items.remove(&id).ok_or_else(|| not_found(id))?;
            state.total = state.total.saturating_sub(item.log_bytes);
            state.canvases.retain(|_, artifact| *artifact != id);
            self.save_index(&state);
            item.info
        };
        let _ = fs::remove_dir_all(self.item_dir(&info));
        self.gc_blobs(false);
        Ok(info)
    }

    pub fn delete_session(&self, session: SessionId) {
        let ids: Vec<ArtifactId> = lock(&self.state)
            .items
            .values()
            .filter(|item| item.info.session_id == session)
            .map(|item| item.info.artifact_id)
            .collect();
        for id in ids {
            let _ = self.delete(id);
        }
        let _ = fs::remove_dir_all(self.dir.join(session.0.to_string()));
    }

    pub fn is_canvas(&self, pane: PaneId) -> bool {
        lock(&self.state).canvases.contains_key(&pane)
    }

    /// Shows drawing `id` in canvas pane `pane`.
    pub fn add_canvas(&self, pane: PaneId, id: ArtifactId) -> Result<ArtifactInfo> {
        {
            let mut state = lock(&self.state);
            let item = state.items.get(&id).ok_or_else(|| not_found(id))?;
            if item.info.kind == ArtifactKind::Image {
                return Err(ArtifactError::Invalid(
                    "canvas panes show drawings and Excalidraw scenes".into(),
                ));
            }
            state.canvases.insert(pane, id);
            self.save_index(&state);
        }
        self.update(id, |info| {
            if !info.canvas_panes.contains(&pane) {
                info.canvas_panes.push(pane);
            }
        })
    }

    /// Forgets canvas pane `pane`; returns the drawing's info if it was one.
    pub fn remove_canvas(&self, pane: PaneId) -> Option<ArtifactInfo> {
        let id = {
            let mut state = lock(&self.state);
            let id = state.canvases.remove(&pane)?;
            self.save_index(&state);
            id
        };
        self.update(id, |info| info.canvas_panes.retain(|shown| *shown != pane))
            .ok()
    }

    pub fn canvases(&self, session: SessionId) -> Vec<CanvasPane> {
        let state = lock(&self.state);
        state
            .canvases
            .iter()
            .filter(|(_, artifact)| {
                state
                    .items
                    .get(artifact)
                    .is_some_and(|item| item.info.session_id == session)
            })
            .map(|(&pane_id, &artifact_id)| CanvasPane {
                pane_id,
                artifact_id,
            })
            .collect()
    }

    /// Pins a drawing's anchor on its pane's terminal.
    pub fn resolve_anchor(
        core: &Core,
        key: ArtifactId,
        request: AnchorRequest,
    ) -> Result<RowAnchor> {
        let entry = core
            .pane(request.pane_id)
            .ok_or_else(|| ArtifactError::NotFound(format!("terminal pane {}", request.pane_id)))?;
        let (position, command_id) = entry
            .pane
            .anchor_create(key.0, request.at_seq, request.from_bottom)
            .map_err(ArtifactError::Invalid)?;
        Ok(row_anchor(request.pane_id, position, command_id))
    }

    /// Refreshes every live anchor; returns the artifacts whose anchor detached.
    pub fn check_anchors(&self, core: &Core) -> Vec<ArtifactInfo> {
        let live: Vec<(ArtifactId, RowAnchor)> = lock(&self.state)
            .items
            .values()
            .filter_map(|item| {
                let anchor = item.info.anchor?;
                (anchor.state == AnchorState::Live).then_some((item.info.artifact_id, anchor))
            })
            .collect();
        let mut detached = Vec::new();
        for (id, anchor) in live {
            let position = match core.pane(anchor.pane_id) {
                None => Some(AnchorPos::Detached(DetachReason::PaneClosed)),
                Some(entry) => entry
                    .pane
                    .anchor_position(id.0)
                    .or(Some(AnchorPos::Detached(DetachReason::DaemonRestart))),
            };
            match position {
                Some(AnchorPos::Detached(reason)) => {
                    if let Ok(info) = self.update(id, |info| {
                        if let Some(stored) = info.anchor.as_mut() {
                            stored.state = AnchorState::Detached(reason);
                        }
                    }) {
                        detached.push(info);
                    }
                }
                Some(live @ AnchorPos::Live { .. }) => {
                    // Fresh position for listings; not persisted, not pushed (clients track
                    // their own pins).
                    let mut state = lock(&self.state);
                    if let Some(stored) = state
                        .items
                        .get_mut(&id)
                        .and_then(|item| item.info.anchor.as_mut())
                    {
                        let fresh = row_anchor(anchor.pane_id, live, stored.command_id);
                        stored.at_seq = fresh.at_seq;
                        stored.from_bottom = fresh.from_bottom;
                    }
                }
                None => {}
            }
        }
        detached
    }
}

/// Checks anchors every second and tells clients about the ones that lost their row.
pub(crate) async fn run(core: std::sync::Arc<Core>) {
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(1));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        for info in core.art.check_anchors(&core) {
            core.emit_artifact(info.session_id, proto::ArtifactEvent::Info(info), None);
        }
        for placement in core.art.check_placements(&core) {
            if let Some(session) = core.session_of_pane(placement.pane_id) {
                core.emit_artifact(session, proto::ArtifactEvent::Placed(placement), None);
            }
        }
        core.art.flush();
        core.art.idle_checkpoints();
    }
}

fn row_anchor(pane_id: PaneId, position: AnchorPos, command_id: Option<u64>) -> RowAnchor {
    match position {
        AnchorPos::Live {
            screen,
            at_seq,
            from_bottom,
            ..
        } => RowAnchor {
            pane_id,
            screen,
            at_seq,
            from_bottom,
            command_id,
            state: AnchorState::Live,
        },
        AnchorPos::Detached(reason) => RowAnchor {
            pane_id,
            screen: proto::AnchorScreen::Primary,
            at_seq: proto::Seq(0),
            from_bottom: 0,
            command_id,
            state: AnchorState::Detached(reason),
        },
    }
}

fn load_item(dir: &Path) -> io::Result<Option<Item>> {
    let Some(bytes) = read_optional(&dir.join("info.bin"))? else {
        return Ok(None);
    };
    let mut info: ArtifactInfo = postcard::from_bytes(&bytes).map_err(io::Error::other)?;
    let mut log = Vec::new();
    let mut log_bytes = 0;
    if let Some(data) = read_optional(&dir.join("ops.log"))? {
        let mut offset = 0;
        while offset + 4 <= data.len() {
            let len = u32::from_le_bytes(data[offset..offset + 4].try_into().unwrap_or_default())
                as usize;
            let Some(body) = data.get(offset + 4..offset + 4 + len) else {
                tracing::warn!("{}: truncated last batch dropped", dir.display());
                break;
            };
            match postcard::from_bytes::<OpBatch>(body) {
                Ok(batch) => log.push(batch),
                Err(error) => {
                    tracing::warn!("{}: bad batch: {error}", dir.display());
                    break;
                }
            }
            offset += 4 + len;
            log_bytes += 4 + len as u64;
        }
    }
    let mut scene = Scene::new();
    for batch in &log {
        if scene.apply(batch).is_err() {
            break;
        }
    }
    let ex = if info.kind == ArtifactKind::Excalidraw {
        let ex = ex::load(dir)?;
        info.version = ex.revision;
        info.elements = ex.live() as u32;
        Some(ex)
    } else {
        info.version = scene.version;
        info.elements = scene.elements().len() as u32;
        None
    };
    // Terminal state does not survive a restart, and neither do anchors' rows.
    if let Some(anchor) = info.anchor.as_mut()
        && anchor.state == AnchorState::Live
    {
        anchor.state = AnchorState::Detached(DetachReason::DaemonRestart);
    }
    Ok(Some(Item {
        info,
        scene,
        log,
        log_bytes,
        ex,
        ex_dirty: false,
        history: history::load(dir)?,
    }))
}

fn validate(ops: &[DrawOp]) -> Result<()> {
    if ops.is_empty() {
        return Err(ArtifactError::Invalid("no ops".into()));
    }
    for op in ops {
        if let DrawOp::Add(element) = op {
            let width = element.style.width;
            if !(width.is_finite() && (0.0..10_000.0).contains(&width)) {
                return Err(ArtifactError::Invalid("bad line width".into()));
            }
            match &element.kind {
                ElementKind::Stroke(stroke) => {
                    drawing::unpack(&stroke.points)
                        .map_err(|error| ArtifactError::Invalid(error.to_string()))?;
                }
                ElementKind::Text { text, size, .. } => {
                    if text.len() > TEXT_MAX || !size.is_finite() {
                        return Err(ArtifactError::Invalid("text too long or bad size".into()));
                    }
                }
                ElementKind::Shape { .. } | ElementKind::Image { .. } => {}
            }
        }
        if let DrawOp::SetTitle(title) = op
            && title.len() > 1024
        {
            return Err(ArtifactError::Invalid("title too long".into()));
        }
    }
    Ok(())
}

/// Exports a drawing or image. Small results are inline; a large PNG is stored as a blob.
pub(crate) fn export(
    art: &Art,
    id: ArtifactId,
    version: Option<u64>,
    format: ExportFormat,
) -> Result<Exported> {
    let (info, scene) = art.scene_at(id, version)?;
    let version = version.unwrap_or(info.version);
    match format {
        ExportFormat::Ascii => {
            let text = match (info.kind, info.image) {
                (ArtifactKind::Image, Some(image)) => format!(
                    "[image {}×{}, {}]\n",
                    image.width,
                    image.height,
                    image.media.mime()
                ),
                _ => drawing::to_ascii(&scene, info.space, 160),
            };
            Ok(Exported {
                format,
                version,
                data: text.into_bytes(),
                blob: None,
            })
        }
        ExportFormat::Svg => {
            let embed_href = |image: &ImageRef| {
                if image.size > 8 << 20 {
                    return None;
                }
                let bytes = fs::read(art.blob_path(&image.hash)).ok()?;
                Some(drawing::data_uri(image.media, &bytes))
            };
            let svg = match (info.kind, info.image) {
                (ArtifactKind::Image, Some(image)) => {
                    let mut image_scene = Scene::new();
                    image_scene.apply_ops(&[DrawOp::Add(proto::Element {
                        id: proto::ElementId(0),
                        z: 0,
                        style: proto::Style {
                            color: 0xff,
                            width: 0.0,
                        },
                        kind: ElementKind::Image {
                            image,
                            from: proto::Pt { x: 0.0, y: 0.0 },
                            to: proto::Pt {
                                x: image.width as f32,
                                y: image.height as f32,
                            },
                        },
                    })]);
                    drawing::to_svg(&image_scene, CoordSpace::Canvas, &info.title, &embed_href)
                }
                _ => drawing::to_svg(&scene, info.space, &info.title, &embed_href),
            };
            if svg.len() > 3 << 20 {
                return Err(ArtifactError::TooLarge("SVG over 3 MiB".into()));
            }
            Ok(Exported {
                format,
                version,
                data: svg.into_bytes(),
                blob: None,
            })
        }
        ExportFormat::Png => {
            let image = match (info.image, info.preview) {
                (Some(image), _) => image,
                (None, Some(preview)) if preview.version == version => preview.image,
                _ => {
                    let png = render_png(&scene, info.space);
                    let image = art.put_blob(&png)?;
                    if version == info.version {
                        let _ = art.update(id, |info| {
                            info.preview = Some(Preview { image, version });
                        });
                    }
                    image
                }
            };
            let (image, bytes) = art.read_blob(&image.hash)?;
            Ok(if bytes.len() <= INLINE_MAX {
                Exported {
                    format,
                    version,
                    data: bytes,
                    blob: None,
                }
            } else {
                Exported {
                    format,
                    version,
                    data: Vec::new(),
                    blob: Some(image.hash),
                }
            })
        }
    }
}

/// The daemon's own PNG of a drawing (headless fallback; text and images as outlines).
pub(crate) fn render_png(scene: &Scene, space: CoordSpace) -> Vec<u8> {
    let scale = match space {
        CoordSpace::Canvas => 2.0,
        CoordSpace::Cells => 1.0,
    };
    let raster = drawing::rasterize(
        scene,
        space,
        drawing::RasterOptions {
            scale,
            ..drawing::RasterOptions::default()
        },
    );
    drawing::encode_png(&raster)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Batches applied from many threads at once get consecutive versions, and the log on
    /// disk replays to the same drawing.
    #[test]
    fn parallel_batches_are_written_in_order() {
        let directory = tempfile::tempdir().unwrap();
        let art = Art::open(directory.path(), ArtifactLimits::default());
        let actor = Actor {
            principal: proto::PrincipalId([1; 16]),
            device: proto::DeviceId([2; 32]),
        };
        let create = ArtifactCreate {
            session_id: SessionId(1),
            kind: ArtifactKind::Drawing,
            title: String::new(),
            space: CoordSpace::Canvas,
            anchor: None,
            image: None,
            ops: Vec::new(),
        };
        let (info, _) = art.create(actor, &create, None).unwrap();
        let id = info.artifact_id;
        std::thread::scope(|scope| {
            for thread in 0..8 {
                let art = &art;
                scope.spawn(move || {
                    for batch in 0..20 {
                        let title = DrawOp::SetTitle(format!("{thread}-{batch}"));
                        art.apply(id, actor, vec![title]).unwrap();
                    }
                });
            }
        });
        let applied = art.info(id).unwrap();
        assert_eq!(applied.version, 160);
        let reopened = Art::open(directory.path(), ArtifactLimits::default());
        let loaded = reopened.info(id).unwrap();
        assert_eq!(
            (loaded.version, loaded.title),
            (applied.version, applied.title)
        );
    }
}
