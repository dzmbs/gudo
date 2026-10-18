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
//! <session>/send/<id>@<v>.png    files pasted into agent panes
//! ```
//!
//! The daemon orders batches; every client applies them in version order and converges.

pub(crate) mod ex;
pub(crate) mod place;
pub(crate) mod send;

use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::{self, Write};
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
/// Longest text element.
const TEXT_MAX: usize = 16 << 10;
/// Most elements per drawing.
const ELEMENTS_MAX: usize = 20_000;

type Result<T> = std::result::Result<T, ArtifactError>;

fn failed(e: impl std::fmt::Display) -> ArtifactError {
    ArtifactError::Failed(e.to_string())
}

fn not_found(id: ArtifactId) -> ArtifactError {
    ArtifactError::NotFound(format!("artifact {id}"))
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
        };
        if let Err(e) = art.load() {
            tracing::warn!("loading artifacts: {e}");
        }
        art.gc_blobs(true);
        art
    }

    fn load(&self) -> io::Result<()> {
        let mut st = lock(&self.state);
        if let Some(bytes) = read_optional(&self.dir.join("index.bin"))? {
            let index: Index = postcard::from_bytes(&bytes).map_err(io::Error::other)?;
            st.next_id = index.next_id.max(1);
            st.canvases = index
                .canvases
                .into_iter()
                .map(|c| (c.pane_id, c.artifact_id))
                .collect();
            st.next_placement = index.next_placement.max(1);
            // Inline placements lose their rows with the terminal state.
            st.placements = index
                .placements
                .into_iter()
                .map(|mut p| {
                    if p.anchor.state == AnchorState::Live {
                        p.anchor.state = AnchorState::Detached(DetachReason::DaemonRestart);
                    }
                    (p.placement_id, p)
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
            let Ok(items) = fs::read_dir(session.path()) else {
                continue;
            };
            for item in items.flatten() {
                match load_item(&item.path()) {
                    Ok(Some(it)) => {
                        st.next_id = st.next_id.max(it.info.artifact_id.0 + 1);
                        st.total += it.log_bytes;
                        st.items.insert(it.info.artifact_id, it);
                    }
                    Ok(None) => {}
                    Err(e) => tracing::warn!("artifact {}: {e}", item.path().display()),
                }
            }
        }
        // Canvas panes whose drawing is gone are forgotten.
        let State {
            items, canvases, ..
        } = &mut *st;
        canvases.retain(|_, a| items.contains_key(a));
        for (pane, artifact) in canvases.iter() {
            if let Some(it) = items.get_mut(artifact)
                && !it.info.canvas_panes.contains(pane)
            {
                it.info.canvas_panes.push(*pane);
            }
        }
        if let Ok(blobs) = fs::read_dir(self.dir.join("blobs")) {
            st.total += blobs
                .flatten()
                .filter_map(|b| b.metadata().ok())
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
        if let Err(e) = result {
            tracing::warn!("saving {}: {e}", path.display());
        }
    }

    fn save_index(&self, st: &State) {
        let index = Index {
            next_id: st.next_id,
            next_placement: st.next_placement,
            placements: st.placements.values().cloned().collect(),
            canvases: st
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
        if let Err(e) = result {
            tracing::warn!("saving artifact index: {e}");
        }
    }

    // --- blobs ------------------------------------------------------------------------------

    pub fn blob_path(&self, hash: &BlobHash) -> PathBuf {
        self.dir.join("blobs").join(hash.to_hex())
    }

    /// Stores `bytes` (a PNG or JPEG) and returns its reference.
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
                .and_then(|f| f.set_modified(std::time::SystemTime::now()));
            return Ok(image);
        }
        self.reserve(size)?;
        write_atomic(&path, bytes).map_err(failed)?;
        Ok(image)
    }

    /// The bytes and reference of a stored blob.
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

    /// Room for `bytes` more under the store's cap.
    pub fn reserve(&self, bytes: u64) -> Result<()> {
        let mut st = lock(&self.state);
        if st.total + bytes > self.limits.total_max {
            return Err(ArtifactError::TooLarge(format!(
                "the host's artifact store is full ({} of {} bytes)",
                st.total, self.limits.total_max
            )));
        }
        st.total += bytes;
        Ok(())
    }

    /// Deletes blobs no artifact references (older than ten minutes unless `all`, so uploads
    /// waiting for their `Create` survive).
    fn gc_blobs(&self, all: bool) {
        let referenced: HashSet<String> = {
            let st = lock(&self.state);
            st.items
                .values()
                .flat_map(|it| {
                    let mut refs: Vec<String> = it
                        .info
                        .image
                        .iter()
                        .map(|i| i.hash.to_hex())
                        .chain(it.info.preview.iter().map(|p| p.image.hash.to_hex()))
                        .collect();
                    if let Some(ex) = &it.ex {
                        refs.extend(ex.files.values().map(|f| f.image.hash.to_hex()));
                    }
                    for batch in &it.log {
                        for op in &batch.ops {
                            if let DrawOp::Add(e) = op
                                && let ElementKind::Image { image, .. } = &e.kind
                            {
                                refs.push(image.hash.to_hex());
                            }
                        }
                    }
                    refs
                })
                .chain(st.placements.values().map(|p| p.image.hash.to_hex()))
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
                .and_then(|m| m.elapsed().ok())
                .is_none_or(|age| age < grace);
            if young {
                continue;
            }
            if fs::remove_file(blob.path()).is_ok() {
                freed += meta.len();
            }
        }
        let mut st = lock(&self.state);
        st.total = st.total.saturating_sub(freed);
    }

    // --- queries ----------------------------------------------------------------------------

    pub fn info(&self, id: ArtifactId) -> Option<ArtifactInfo> {
        lock(&self.state).items.get(&id).map(|it| it.info.clone())
    }

    pub fn list(&self, session: SessionId) -> Vec<ArtifactInfo> {
        lock(&self.state)
            .items
            .values()
            .filter(|it| it.info.session_id == session)
            .map(|it| it.info.clone())
            .collect()
    }

    /// Batches after `since`, or every element.
    pub fn scene(&self, id: ArtifactId, since: u64) -> Result<ArtifactScene> {
        let st = lock(&self.state);
        let it = st.items.get(&id).ok_or_else(|| not_found(id))?;
        let version = it.info.version;
        let (elements, batches) = if since > 0 && since <= version {
            (None, it.log[since as usize..].to_vec())
        } else {
            (Some(it.scene.elements().to_vec()), Vec::new())
        };
        Ok(ArtifactScene {
            info: it.info.clone(),
            elements,
            batches,
        })
    }

    /// The scene at `version` (replayed from the log), with the artifact's info.
    pub fn scene_at(&self, id: ArtifactId, version: Option<u64>) -> Result<(ArtifactInfo, Scene)> {
        let st = lock(&self.state);
        let it = st.items.get(&id).ok_or_else(|| not_found(id))?;
        if let Some(ex) = &it.ex {
            // Excalidraw keeps the latest state of each element, not its history.
            if version.is_some_and(|v| v != it.info.version) {
                return Err(ArtifactError::NotFound(format!(
                    "Excalidraw scenes keep only their current revision ({})",
                    it.info.version
                )));
            }
            return Ok((it.info.clone(), ex.to_scene()));
        }
        let version = version.unwrap_or(it.info.version);
        if version > it.info.version {
            return Err(ArtifactError::NotFound(format!(
                "version {version} of artifact {id} (it is at {})",
                it.info.version
            )));
        }
        if version == it.info.version {
            return Ok((it.info.clone(), it.scene.clone()));
        }
        let mut scene = Scene::new();
        for batch in &it.log[..version as usize] {
            let _ = scene.apply(batch);
        }
        Ok((it.info.clone(), scene))
    }

    pub fn session_count(&self, session: SessionId) -> usize {
        lock(&self.state)
            .items
            .values()
            .filter(|it| it.info.session_id == session)
            .count()
    }

    // --- changes ----------------------------------------------------------------------------

    /// Creates an artifact. The anchor is resolved by the caller (it needs the pane).
    pub fn create(
        &self,
        actor: Actor,
        req: &ArtifactCreate,
        anchor: Option<RowAnchor>,
    ) -> Result<(ArtifactInfo, Option<OpBatch>)> {
        if self.session_count(req.session_id) >= self.limits.per_session {
            return Err(ArtifactError::TooLarge(format!(
                "a session holds at most {} artifacts",
                self.limits.per_session
            )));
        }
        let image = match (req.kind, req.image) {
            (ArtifactKind::Image, Some(hash)) => Some(self.read_blob(&hash)?.0),
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
        if req.kind != ArtifactKind::Drawing && !req.ops.is_empty() {
            return Err(ArtifactError::Invalid(
                "only drawings take ops (Excalidraw scenes take ExcalidrawPut)".into(),
            ));
        }
        let now = UnixMillis(now_millis());
        let mut st = lock(&self.state);
        let id = ArtifactId(st.next_id);
        st.next_id += 1;
        let info = ArtifactInfo {
            artifact_id: id,
            session_id: req.session_id,
            kind: req.kind,
            title: req.title.clone(),
            space: req.space,
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
        st.items.insert(
            id,
            Item {
                info: info.clone(),
                scene: Scene::new(),
                log: Vec::new(),
                log_bytes: 0,
                ex: (req.kind == ArtifactKind::Excalidraw).then(drawing::ExScene::new),
                ex_dirty: false,
            },
        );
        self.save_index(&st);
        drop(st);
        if let Err(e) = fs::create_dir_all(self.item_dir(&info)) {
            tracing::warn!("artifact dir: {e}");
        }
        self.save_info(&info);
        if req.ops.is_empty() {
            return Ok((info, None));
        }
        match self.apply(id, actor, req.ops.clone()) {
            Ok((info, batch)) => Ok((info, Some(batch))),
            Err(e) => {
                let _ = self.delete(id);
                Err(e)
            }
        }
    }

    /// Commits `ops` as the next batch.
    pub fn apply(
        &self,
        id: ArtifactId,
        actor: Actor,
        ops: Vec<DrawOp>,
    ) -> Result<(ArtifactInfo, OpBatch)> {
        validate(&ops)?;
        let mut st = lock(&self.state);
        let it = st.items.get_mut(&id).ok_or_else(|| not_found(id))?;
        if it.info.kind != ArtifactKind::Drawing {
            return Err(ArtifactError::Invalid(
                "only drawings take ops (Excalidraw scenes take ExcalidrawPut)".into(),
            ));
        }
        let batch = OpBatch {
            version: it.info.version + 1,
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
        if it.log_bytes + encoded.len() as u64 + 4 > self.limits.log_max {
            return Err(ArtifactError::TooLarge(format!(
                "the drawing's history would exceed {} bytes",
                self.limits.log_max
            )));
        }
        let mut scene = it.scene.clone();
        scene.apply(&batch).map_err(|g| failed(format!("{g:?}")))?;
        if scene.elements().len() > ELEMENTS_MAX {
            return Err(ArtifactError::TooLarge(format!(
                "a drawing holds at most {ELEMENTS_MAX} elements"
            )));
        }
        let added = encoded.len() as u64 + 4;
        if st.total + added > self.limits.total_max {
            return Err(ArtifactError::TooLarge(
                "the host's artifact store is full".into(),
            ));
        }
        st.total += added;
        let it = st.items.get_mut(&id).ok_or_else(|| not_found(id))?;
        let dir = self.item_dir(&it.info);
        let mut frame = (encoded.len() as u32).to_le_bytes().to_vec();
        frame.extend_from_slice(&encoded);
        let appended = fs::create_dir_all(&dir).and_then(|()| {
            let mut f = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join("ops.log"))?;
            f.write_all(&frame)?;
            f.sync_data()
        });
        if let Err(e) = appended {
            st.total -= added;
            return Err(failed(format!("writing the drawing's log: {e}")));
        }
        let it = st.items.get_mut(&id).ok_or_else(|| not_found(id))?;
        it.scene = scene;
        it.log.push(batch.clone());
        it.log_bytes += added;
        it.info.version = batch.version;
        it.info.updated_at = batch.at;
        it.info.elements = it.scene.elements().len() as u32;
        if let Some(title) = &it.scene.title {
            it.info.title.clone_from(title);
        }
        let info = it.info.clone();
        drop(st);
        self.save_info(&info);
        Ok((info, batch))
    }

    /// Changes an artifact's info with `f` and saves it.
    pub fn update(
        &self,
        id: ArtifactId,
        f: impl FnOnce(&mut ArtifactInfo),
    ) -> Result<ArtifactInfo> {
        let info = {
            let mut st = lock(&self.state);
            let it = st.items.get_mut(&id).ok_or_else(|| not_found(id))?;
            f(&mut it.info);
            it.info.clone()
        };
        self.save_info(&info);
        Ok(info)
    }

    /// Deletes an artifact; returns its info (canvas panes included) for the caller to close
    /// them and tell clients.
    pub fn delete(&self, id: ArtifactId) -> Result<ArtifactInfo> {
        let info = {
            let mut st = lock(&self.state);
            let it = st.items.remove(&id).ok_or_else(|| not_found(id))?;
            st.total = st.total.saturating_sub(it.log_bytes);
            st.canvases.retain(|_, a| *a != id);
            self.save_index(&st);
            it.info
        };
        let _ = fs::remove_dir_all(self.item_dir(&info));
        self.gc_blobs(false);
        Ok(info)
    }

    /// Deletes every artifact of a closed session.
    pub fn delete_session(&self, session: SessionId) {
        let ids: Vec<ArtifactId> = lock(&self.state)
            .items
            .values()
            .filter(|it| it.info.session_id == session)
            .map(|it| it.info.artifact_id)
            .collect();
        for id in ids {
            let _ = self.delete(id);
        }
        let _ = fs::remove_dir_all(self.dir.join(session.0.to_string()));
    }

    // --- canvas panes -----------------------------------------------------------------------

    pub fn is_canvas(&self, pane: PaneId) -> bool {
        lock(&self.state).canvases.contains_key(&pane)
    }

    /// Shows drawing `id` in canvas pane `pane`.
    pub fn add_canvas(&self, pane: PaneId, id: ArtifactId) -> Result<ArtifactInfo> {
        {
            let mut st = lock(&self.state);
            let it = st.items.get(&id).ok_or_else(|| not_found(id))?;
            if it.info.kind == ArtifactKind::Image {
                return Err(ArtifactError::Invalid(
                    "canvas panes show drawings and Excalidraw scenes".into(),
                ));
            }
            st.canvases.insert(pane, id);
            self.save_index(&st);
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
            let mut st = lock(&self.state);
            let id = st.canvases.remove(&pane)?;
            self.save_index(&st);
            id
        };
        self.update(id, |info| info.canvas_panes.retain(|p| *p != pane))
            .ok()
    }

    pub fn canvases(&self, session: SessionId) -> Vec<CanvasPane> {
        let st = lock(&self.state);
        st.canvases
            .iter()
            .filter(|(_, a)| {
                st.items
                    .get(a)
                    .is_some_and(|it| it.info.session_id == session)
            })
            .map(|(&pane_id, &artifact_id)| CanvasPane {
                pane_id,
                artifact_id,
            })
            .collect()
    }

    // --- anchors ----------------------------------------------------------------------------

    /// Pins a drawing's anchor on its pane's terminal.
    pub fn resolve_anchor(core: &Core, key: ArtifactId, req: AnchorRequest) -> Result<RowAnchor> {
        let entry = core
            .pane(req.pane_id)
            .ok_or_else(|| ArtifactError::NotFound(format!("terminal pane {}", req.pane_id)))?;
        let (pos, command_id) = entry
            .pane
            .anchor_create(key.0, req.at_seq, req.from_bottom)
            .map_err(ArtifactError::Invalid)?;
        Ok(row_anchor(req.pane_id, pos, command_id))
    }

    /// Refreshes every live anchor; returns the artifacts whose anchor detached.
    pub fn check_anchors(&self, core: &Core) -> Vec<ArtifactInfo> {
        let live: Vec<(ArtifactId, RowAnchor)> = lock(&self.state)
            .items
            .values()
            .filter_map(|it| {
                let a = it.info.anchor?;
                (a.state == AnchorState::Live).then_some((it.info.artifact_id, a))
            })
            .collect();
        let mut detached = Vec::new();
        for (id, anchor) in live {
            let pos = match core.pane(anchor.pane_id) {
                None => Some(AnchorPos::Detached(DetachReason::PaneClosed)),
                Some(entry) => entry
                    .pane
                    .anchor_position(id.0)
                    .or(Some(AnchorPos::Detached(DetachReason::DaemonRestart))),
            };
            match pos {
                Some(AnchorPos::Detached(reason)) => {
                    if let Ok(info) = self.update(id, |info| {
                        if let Some(a) = info.anchor.as_mut() {
                            a.state = AnchorState::Detached(reason);
                        }
                    }) {
                        detached.push(info);
                    }
                }
                Some(live @ AnchorPos::Live { .. }) => {
                    // Fresh position for listings; not persisted, not pushed (clients track
                    // their own pins).
                    let mut st = lock(&self.state);
                    if let Some(a) = st.items.get_mut(&id).and_then(|it| it.info.anchor.as_mut()) {
                        let fresh = row_anchor(anchor.pane_id, live, a.command_id);
                        a.at_seq = fresh.at_seq;
                        a.from_bottom = fresh.from_bottom;
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
        for p in core.art.check_placements(&core) {
            if let Some(session) = core.session_of_pane(p.pane_id) {
                core.emit_artifact(session, proto::ArtifactEvent::Placed(p), None);
            }
        }
        core.art.flush();
    }
}

/// The wire anchor for a pane position.
fn row_anchor(pane_id: PaneId, pos: AnchorPos, command_id: Option<u64>) -> RowAnchor {
    match pos {
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
        let mut pos = 0;
        while pos + 4 <= data.len() {
            let len =
                u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap_or_default()) as usize;
            let Some(body) = data.get(pos + 4..pos + 4 + len) else {
                tracing::warn!("{}: truncated last batch dropped", dir.display());
                break;
            };
            match postcard::from_bytes::<OpBatch>(body) {
                Ok(b) => log.push(b),
                Err(e) => {
                    tracing::warn!("{}: bad batch: {e}", dir.display());
                    break;
                }
            }
            pos += 4 + len;
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
    if let Some(a) = info.anchor.as_mut()
        && a.state == AnchorState::Live
    {
        a.state = AnchorState::Detached(DetachReason::DaemonRestart);
    }
    Ok(Some(Item {
        info,
        scene,
        log,
        log_bytes,
        ex,
        ex_dirty: false,
    }))
}

fn validate(ops: &[DrawOp]) -> Result<()> {
    if ops.is_empty() {
        return Err(ArtifactError::Invalid("no ops".into()));
    }
    for op in ops {
        if let DrawOp::Add(e) = op {
            if !(e.style.width.is_finite() && e.style.width >= 0.0 && e.style.width < 10_000.0) {
                return Err(ArtifactError::Invalid("bad line width".into()));
            }
            match &e.kind {
                ElementKind::Stroke(s) => {
                    drawing::unpack(&s.points)
                        .map_err(|e| ArtifactError::Invalid(e.to_string()))?;
                }
                ElementKind::Text { text, size, .. } => {
                    if text.len() > TEXT_MAX || !size.is_finite() {
                        return Err(ArtifactError::Invalid("text too long or bad size".into()));
                    }
                }
                ElementKind::Shape { .. } | ElementKind::Image { .. } => {}
            }
        }
        if let DrawOp::SetTitle(t) = op
            && t.len() > 1024
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
                (ArtifactKind::Image, Some(img)) => format!(
                    "[image {}×{}, {}]\n",
                    img.width,
                    img.height,
                    img.media.mime()
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
            let href = |img: &ImageRef| {
                if img.size > 8 << 20 {
                    return None;
                }
                let bytes = fs::read(art.blob_path(&img.hash)).ok()?;
                Some(drawing::data_uri(img.media, &bytes))
            };
            let svg = match (info.kind, info.image) {
                (ArtifactKind::Image, Some(img)) => {
                    let mut s = Scene::new();
                    s.apply_ops(&[DrawOp::Add(proto::Element {
                        id: proto::ElementId(0),
                        z: 0,
                        style: proto::Style {
                            color: 0xff,
                            width: 0.0,
                        },
                        kind: ElementKind::Image {
                            image: img,
                            from: proto::Pt { x: 0.0, y: 0.0 },
                            to: proto::Pt {
                                x: img.width as f32,
                                y: img.height as f32,
                            },
                        },
                    })]);
                    drawing::to_svg(&s, CoordSpace::Canvas, &info.title, &href)
                }
                _ => drawing::to_svg(&scene, info.space, &info.title, &href),
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
                (Some(img), _) => img,
                (None, Some(p)) if p.version == version => p.image,
                _ => {
                    // No client render of this version: rasterise here.
                    let png = render_png(&scene, info.space);
                    let image = art.put_blob(&png)?;
                    if version == info.version {
                        let _ = art.update(id, |i| {
                            i.preview = Some(Preview { image, version });
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
    let img = drawing::rasterize(
        scene,
        space,
        drawing::RasterOptions {
            scale,
            ..drawing::RasterOptions::default()
        },
    );
    drawing::encode_png(&img)
}
