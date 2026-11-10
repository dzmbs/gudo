//! Drawings and images: requests, live ink, blobs, and a local scene cache that stays
//! in step with the daemon.
//!
//! - Requests are `async` and return the daemon's answer or an [`ArtifactError`].
//! - Pushes go to an [`ArtifactListener`] ([`Client::set_artifact_listener`]), separate from
//!   [`ClientListener`](crate::ClientListener) so existing event handling is untouched.
//! - The client keeps a [`drawing::Scene`] for every artifact of the attached session it has
//!   seen: batches pushed by the daemon apply in version order; a gap, a new artifact, or a
//!   reconnect fetches what is missing (`Get { since }`) and reports
//!   [`ArtifactUpdate::Synced`]. [`Client::artifact_scene`] reads the cache.
//! - Excalidraw scenes are cached as [`drawing::ExScene`]s and reconciled per element with
//!   Excalidraw's rule; inline placements per pane ([`Client::placements`]) — both caught up
//!   on reconnect.
//! - Blobs (images, rendered PNGs) move on their own streams at bulk priority.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use drawing::Scene;
use proto::{
    AnchorRequest, ArtifactCreate, ArtifactError, ArtifactEvent, ArtifactId, ArtifactInfo,
    ArtifactRequest, ArtifactResponse, ArtifactScene, ArtifactSend, BlobHash, BlobHeader,
    BlobReply, CanvasPane, ClientCtl, DrawOp, ExportFormat, Exported, ImageRef, InkLive, PaneId,
    PngSource, Sent, ServerCtl, SessionId, StreamHeader,
};
use tokio::sync::{mpsc, oneshot};

use crate::{Client, Inner, TransferProgress, lock};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
/// Blob bytes between progress reports.
const CHUNK: usize = 64 * 1024;

/// Something an [`ArtifactListener`] hears.
#[derive(Debug, Clone)]
pub enum ArtifactUpdate {
    /// A push from the daemon (created, changed, info, deleted, live ink, canvas panes).
    Event(Box<ArtifactEvent>),
    /// The cached scene of an artifact was (re)fetched and is now at `version`: after a gap,
    /// a reconnect, or for an artifact first seen.
    Synced {
        artifact_id: ArtifactId,
        version: u64,
    },
}

/// Receives [`ArtifactUpdate`]s. Must return quickly; it runs on the network threads.
pub trait ArtifactListener: Send + Sync {
    /// Called once per update, in order.
    fn on_artifact(&self, update: ArtifactUpdate);
}

/// An [`ArtifactListener`] that queues updates for async Rust consumers (`gudo`, tests).
pub struct ArtifactEventQueue {
    tx: mpsc::UnboundedSender<ArtifactUpdate>,
}

impl ArtifactEventQueue {
    /// Returns the listener and the receiving end.
    pub fn channel() -> (
        Arc<dyn ArtifactListener>,
        mpsc::UnboundedReceiver<ArtifactUpdate>,
    ) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Self { tx }), rx)
    }
}

impl ArtifactListener for ArtifactEventQueue {
    fn on_artifact(&self, update: ArtifactUpdate) {
        let _ = self.tx.send(update);
    }
}

type Pending = oneshot::Sender<Result<ArtifactResponse, ArtifactError>>;

struct Cached {
    info: ArtifactInfo,
    scene: Scene,
}

#[derive(Default)]
pub(crate) struct ArtState {
    pending: Mutex<HashMap<u64, Pending>>,
    /// Internal `Get`s the cache issued.
    resync: Mutex<HashSet<u64>>,
    listener: Mutex<Option<Arc<dyn ArtifactListener>>>,
    cache: Mutex<HashMap<ArtifactId, Cached>>,
    canvases: Mutex<HashMap<SessionId, Vec<CanvasPane>>>,
    excalidraw: Mutex<HashMap<ArtifactId, drawing::ExScene>>,
    /// Inline placements by pane.
    placements: Mutex<HashMap<PaneId, std::collections::BTreeMap<u64, proto::Placement>>>,
}

impl ArtState {
    /// Whether a caller (or the catch-up after a reconnect) still waits for `req_id`.
    pub(crate) fn awaits(&self, req_id: u64) -> bool {
        lock(&self.resync).contains(&req_id)
            || lock(&self.pending)
                .get(&req_id)
                .is_some_and(|reply| !reply.is_closed())
    }

    fn notify(&self, update: ArtifactUpdate) {
        let listener = lock(&self.listener).clone();
        if let Some(listener) = listener {
            listener.on_artifact(update);
        }
    }

    /// Applies a scene answer to the cache; returns the version if it changed the cache.
    fn absorb(&self, scene: &ArtifactScene) -> Option<u64> {
        // Excalidraw scenes live in `excalidraw`: an op-log entry for one would be resynced with
        // `Get` on every reconnect and report a `Synced` before its elements are back.
        if scene.info.kind == proto::ArtifactKind::Excalidraw {
            return None;
        }
        let mut cache = lock(&self.cache);
        let entry = cache
            .entry(scene.info.artifact_id)
            .or_insert_with(|| Cached {
                info: scene.info.clone(),
                scene: Scene::new(),
            });
        entry.info = scene.info.clone();
        if let Some(elements) = &scene.elements {
            entry.scene = Scene::from_elements(scene.info.version, elements.clone());
        } else {
            for batch in &scene.batches {
                if batch.version == entry.scene.version + 1 {
                    let _ = entry.scene.apply(batch);
                }
            }
        }
        Some(entry.scene.version)
    }

    /// Handles an artifact message from `ctl`; returns it back if it is not one.
    pub(crate) fn dispatch(&self, inner: &Inner, msg: ServerCtl) -> Option<ServerCtl> {
        match msg {
            ServerCtl::ArtifactResult { req_id, result } => {
                if let Ok(ArtifactResponse::Excalidraw(scene)) = &result {
                    let version = scene.info.version;
                    let artifact_id = scene.info.artifact_id;
                    {
                        let mut scenes = lock(&self.excalidraw);
                        let cached = scenes.entry(artifact_id).or_default();
                        cached.absorb(scene.elements.clone(), version);
                        if scene.app_state.is_some() {
                            cached.app_state.clone_from(&scene.app_state);
                        }
                        for file in &scene.files {
                            cached.files.insert(file.file_id.clone(), file.clone());
                        }
                    }
                    if lock(&self.resync).remove(&req_id) {
                        self.notify(ArtifactUpdate::Synced {
                            artifact_id,
                            version,
                        });
                    }
                } else if let Ok(ArtifactResponse::Placements(list)) = &result {
                    for placement in list {
                        lock(&self.placements)
                            .entry(placement.pane_id)
                            .or_default()
                            .insert(placement.placement_id, placement.clone());
                    }
                }
                if let Ok(ArtifactResponse::Scene(scene)) = &result
                    && let Some(version) = self.absorb(scene)
                {
                    let internal = lock(&self.resync).remove(&req_id);
                    if internal {
                        self.notify(ArtifactUpdate::Synced {
                            artifact_id: scene.info.artifact_id,
                            version,
                        });
                    }
                } else {
                    lock(&self.resync).remove(&req_id);
                }
                if let Some(tx) = lock(&self.pending).remove(&req_id) {
                    let _ = tx.send(result);
                }
                None
            }
            ServerCtl::Artifact(event) => {
                self.track(inner, &event);
                self.notify(ArtifactUpdate::Event(Box::new(event)));
                None
            }
            other => Some(other),
        }
    }

    fn track(&self, inner: &Inner, event: &ArtifactEvent) {
        match event {
            ArtifactEvent::Created(info) if info.kind == proto::ArtifactKind::Excalidraw => {
                let fresh = !lock(&self.excalidraw).contains_key(&info.artifact_id);
                lock(&self.excalidraw).entry(info.artifact_id).or_default();
                if fresh && info.version > 0 {
                    self.fetch_excalidraw(inner, info.artifact_id, 0);
                }
            }
            ArtifactEvent::Created(info) => {
                let fetch = {
                    let mut cache = lock(&self.cache);
                    let fresh = !cache.contains_key(&info.artifact_id);
                    cache.entry(info.artifact_id).or_insert_with(|| Cached {
                        info: info.clone(),
                        scene: Scene::new(),
                    });
                    fresh && info.version > 0
                };
                if fetch {
                    self.fetch(inner, info.artifact_id, 0);
                }
            }
            ArtifactEvent::Changed { info, batch } => {
                let gap = {
                    let mut cache = lock(&self.cache);
                    let entry = cache.entry(info.artifact_id).or_insert_with(|| Cached {
                        info: info.clone(),
                        scene: Scene::new(),
                    });
                    entry.info = info.clone();
                    if batch.version <= entry.scene.version {
                        None
                    } else {
                        entry.scene.apply(batch).err().map(|_| entry.scene.version)
                    }
                };
                if let Some(have) = gap {
                    self.fetch(inner, info.artifact_id, have);
                }
            }
            ArtifactEvent::Info(info) => {
                if let Some(cached) = lock(&self.cache).get_mut(&info.artifact_id) {
                    cached.info = info.clone();
                }
            }
            ArtifactEvent::Deleted { artifact_id, .. } => {
                lock(&self.cache).remove(artifact_id);
                lock(&self.excalidraw).remove(artifact_id);
            }
            ArtifactEvent::Canvases {
                session_id,
                canvases,
            } => {
                lock(&self.canvases).insert(*session_id, canvases.clone());
            }
            ArtifactEvent::Ink(_) => {}
            ArtifactEvent::Excalidraw {
                artifact_id,
                version,
                elements,
                app_state,
                files,
            } => {
                let mut scenes = lock(&self.excalidraw);
                let cached = scenes.entry(*artifact_id).or_default();
                cached.absorb(elements.clone(), *version);
                if app_state.is_some() {
                    cached.app_state.clone_from(app_state);
                }
                for file in files {
                    cached.files.insert(file.file_id.clone(), file.clone());
                }
            }
            ArtifactEvent::Placed(placement) => {
                lock(&self.placements)
                    .entry(placement.pane_id)
                    .or_default()
                    .insert(placement.placement_id, placement.clone());
            }
            ArtifactEvent::Unplaced {
                pane_id,
                placement_id,
            } => {
                if let Some(by_id) = lock(&self.placements).get_mut(pane_id) {
                    by_id.remove(placement_id);
                }
            }
        }
    }

    /// Asks for everything after `since` for the cache.
    fn fetch(&self, inner: &Inner, artifact_id: ArtifactId, since: u64) {
        let req_id = inner
            .next_op
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        lock(&self.resync).insert(req_id);
        inner.send(ClientCtl::Artifact {
            req_id,
            req: ArtifactRequest::Get { artifact_id, since },
        });
    }

    fn fetch_excalidraw(&self, inner: &Inner, artifact_id: ArtifactId, since: u64) {
        let req_id = inner
            .next_op
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        lock(&self.resync).insert(req_id);
        inner.send(ClientCtl::Artifact {
            req_id,
            req: ArtifactRequest::ExcalidrawGet { artifact_id, since },
        });
    }

    /// After (re)connecting: catch every cached scene up.
    pub(crate) fn on_connected(&self, inner: &Inner) {
        let scenes: Vec<(ArtifactId, u64)> = lock(&self.excalidraw)
            .iter()
            .map(|(&artifact_id, scene)| (artifact_id, scene.revision))
            .collect();
        for (artifact_id, revision) in scenes {
            self.fetch_excalidraw(inner, artifact_id, revision);
        }
        // Placements come again with the attach; stale ones go.
        lock(&self.placements).clear();
        let wanted: Vec<(ArtifactId, u64)> = lock(&self.cache)
            .iter()
            .map(|(&artifact_id, cached)| (artifact_id, cached.scene.version))
            .collect();
        for (artifact_id, version) in wanted {
            self.fetch(inner, artifact_id, version);
        }
    }

    /// The connection dropped: requests in flight will not be answered.
    pub(crate) fn fail_pending(&self) {
        lock(&self.resync).clear();
        for (_, tx) in lock(&self.pending).drain() {
            let _ = tx.send(Err(ArtifactError::Disconnected));
        }
    }
}

fn failed(err: impl std::fmt::Display) -> ArtifactError {
    ArtifactError::Failed(err.to_string())
}

macro_rules! expect {
    ($response:expr, $pat:pat => $out:expr) => {
        match $response {
            $pat => Ok($out),
            other => Err(ArtifactError::Failed(format!(
                "unexpected answer {other:?}"
            ))),
        }
    };
}

impl Client {
    /// Sets the receiver of [`ArtifactUpdate`]s (replacing any previous one).
    pub fn set_artifact_listener(&self, listener: Arc<dyn ArtifactListener>) {
        *lock(&self.inner.art.listener) = Some(listener);
    }

    /// Sends any artifact request and waits for the answer.
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`], or [`ArtifactError::Disconnected`] if the connection
    /// dropped (or nothing came back within two minutes).
    pub async fn artifact(
        &self,
        request: ArtifactRequest,
    ) -> Result<ArtifactResponse, ArtifactError> {
        let req_id = self
            .inner
            .next_op
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        lock(&self.inner.art.pending).insert(req_id, tx);
        self.inner.send(ClientCtl::Artifact {
            req_id,
            req: request,
        });
        let inner = Arc::clone(&self.inner);
        crate::run_on(&self.handle, async move {
            match tokio::time::timeout(REQUEST_TIMEOUT, rx).await {
                Ok(Ok(result)) => result,
                _ => {
                    lock(&inner.art.pending).remove(&req_id);
                    Err(ArtifactError::Disconnected)
                }
            }
        })
        .await
        .unwrap_or(Err(ArtifactError::Disconnected))
    }

    /// A session's artifacts.
    pub async fn artifacts(
        &self,
        session_id: SessionId,
    ) -> Result<Vec<ArtifactInfo>, ArtifactError> {
        expect!(self.artifact(ArtifactRequest::List { session_id }).await?,
            ArtifactResponse::List(artifacts) => artifacts)
    }

    /// Creates a drawing or image.
    pub async fn artifact_create(
        &self,
        create: ArtifactCreate,
    ) -> Result<ArtifactInfo, ArtifactError> {
        let info = expect!(self.artifact(ArtifactRequest::Create(create)).await?,
            ArtifactResponse::Created(info) => info)?;
        if info.kind == proto::ArtifactKind::Excalidraw {
            lock(&self.inner.art.excalidraw)
                .entry(info.artifact_id)
                .or_default();
        } else if info.version > 0 {
            // Bring the cache up to the initial ops.
            let _ = self.artifact_get(info.artifact_id, 0).await;
        } else {
            lock(&self.inner.art.cache).insert(
                info.artifact_id,
                Cached {
                    info: info.clone(),
                    scene: Scene::new(),
                },
            );
        }
        Ok(info)
    }

    /// Batches after `since` (or every element); the cache is updated too.
    pub async fn artifact_get(
        &self,
        artifact_id: ArtifactId,
        since: u64,
    ) -> Result<ArtifactScene, ArtifactError> {
        expect!(self.artifact(ArtifactRequest::Get { artifact_id, since }).await?,
            ArtifactResponse::Scene(scene) => scene)
    }

    /// Commits ops as one batch; returns the new version. The batch also arrives as an
    /// [`ArtifactEvent::Changed`] push, which updates the cache.
    pub async fn artifact_apply(
        &self,
        artifact_id: ArtifactId,
        base: u64,
        ops: Vec<DrawOp>,
    ) -> Result<u64, ArtifactError> {
        expect!(self.artifact(ArtifactRequest::Apply { artifact_id, base, ops }).await?,
            ArtifactResponse::Applied { version, .. } => version)
    }

    /// Deletes an artifact (its canvas panes close).
    pub async fn artifact_delete(&self, artifact_id: ArtifactId) -> Result<(), ArtifactError> {
        expect!(self.artifact(ArtifactRequest::Delete { artifact_id }).await?,
            ArtifactResponse::Done => ())
    }

    /// Anchors a drawing to a terminal row (`None` unanchors it).
    pub async fn artifact_set_anchor(
        &self,
        artifact_id: ArtifactId,
        anchor: Option<AnchorRequest>,
    ) -> Result<ArtifactInfo, ArtifactError> {
        expect!(self.artifact(ArtifactRequest::SetAnchor { artifact_id, anchor }).await?,
            ArtifactResponse::Info(info) => info)
    }

    /// Uploads this device's PNG render of a drawing version as its preview.
    pub async fn artifact_set_preview(
        &self,
        artifact_id: ArtifactId,
        version: u64,
        png: Vec<u8>,
    ) -> Result<ArtifactInfo, ArtifactError> {
        let session = self.artifact_session(artifact_id).await?;
        let image = self.blob_upload(session, png).await?;
        expect!(self.artifact(ArtifactRequest::SetPreview { artifact_id, version, png: image.hash }).await?,
            ArtifactResponse::Info(info) => info)
    }

    /// Exports PNG (the image, or the drawing's preview / the daemon's render) or SVG;
    /// returns the bytes (downloaded when large) and the version they show.
    pub async fn artifact_export(
        &self,
        artifact_id: ArtifactId,
        version: Option<u64>,
        format: ExportFormat,
    ) -> Result<(u64, Vec<u8>), ArtifactError> {
        let Exported {
            version,
            data,
            blob,
            ..
        } = expect!(self
            .artifact(ArtifactRequest::Export { artifact_id, version, format })
            .await?, ArtifactResponse::Exported(exported) => exported)?;
        match blob {
            Some(hash) => Ok((version, self.blob_download(hash).await?.1)),
            None => Ok((version, data)),
        }
    }

    /// "Send to agent": the daemon writes the PNG on the host and pastes its path into the
    /// agent pane (no Enter), where Claude Code and Codex attach it as `[Image #N]`.
    ///
    /// `png`: this device's render (sent inline up to 1 MiB, else uploaded first), or `None`
    /// to use the artifact's own image / preview / the daemon's render. With no
    /// `artifact_id`, `png` is a bare image (a photo, a screenshot) and is kept as an image
    /// artifact.
    pub async fn send_to_agent(
        &self,
        pane_id: PaneId,
        artifact_id: Option<ArtifactId>,
        version: Option<u64>,
        png: Option<Vec<u8>>,
    ) -> Result<Sent, ArtifactError> {
        let png = match png {
            None => PngSource::Artifact,
            Some(bytes) if bytes.len() <= 1 << 20 => PngSource::Inline(bytes),
            Some(bytes) => {
                let session = match artifact_id {
                    Some(artifact_id) => self.artifact_session(artifact_id).await?,
                    None => self.session_of(pane_id)?,
                };
                PngSource::Blob(self.blob_upload(session, bytes).await?.hash)
            }
        };
        expect!(self.artifact(ArtifactRequest::Send(ArtifactSend { pane_id, artifact_id, version, png })).await?,
            ArtifactResponse::Sent(sent) => sent)
    }

    /// An Excalidraw scene (or what changed after `since`); the cache is updated too.
    pub async fn excalidraw_get(
        &self,
        artifact_id: ArtifactId,
        since: u64,
    ) -> Result<proto::ExcalidrawScene, ArtifactError> {
        expect!(self.artifact(ArtifactRequest::ExcalidrawGet { artifact_id, since }).await?,
            ArtifactResponse::Excalidraw(scene) => scene)
    }

    /// Offers changed Excalidraw elements (whole elements, as the editor's `onChange`
    /// reports them). Returns the new revision and the offered elements that lost, as the
    /// stored winners — apply those in the editor. The cache keeps the winners.
    pub async fn excalidraw_put(
        &self,
        artifact_id: ArtifactId,
        elements: Vec<proto::ExElement>,
        app_state: Option<String>,
        files: Vec<proto::ExFile>,
    ) -> Result<(u64, Vec<proto::ExElement>), ArtifactError> {
        let base = lock(&self.inner.art.excalidraw)
            .get(&artifact_id)
            .map_or(0, |scene| scene.revision);
        let offered = elements.clone();
        let (version, rejected) = expect!(self
            .artifact(ArtifactRequest::ExcalidrawPut(proto::ExcalidrawPut {
                artifact_id,
                base,
                elements,
                app_state: app_state.clone(),
                files: files.clone(),
            }))
            .await?, ArtifactResponse::ExcalidrawApplied { version, rejected, .. } => (version, rejected))?;
        let mut scenes = lock(&self.inner.art.excalidraw);
        let cached = scenes.entry(artifact_id).or_default();
        cached.absorb(offered, version);
        cached.absorb(rejected.clone(), version);
        if app_state.is_some() {
            cached.app_state = app_state;
        }
        for file in files {
            cached.files.insert(file.file_id.clone(), file);
        }
        Ok((version, rejected))
    }

    /// The cached Excalidraw scene of an artifact.
    pub fn excalidraw_scene(&self, artifact_id: ArtifactId) -> Option<drawing::ExScene> {
        lock(&self.inner.art.excalidraw).get(&artifact_id).cloned()
    }

    /// Shows an artifact inline in a terminal pane (the overlay's "done"): at `anchor`'s row,
    /// or the cursor row. `png` is this device's render (uploaded first), else the daemon
    /// uses the image, the preview, or its own render. `replace` swaps out the placement the
    /// overlay was re-opened from.
    pub async fn place(
        &self,
        request: proto::PlaceRequest,
    ) -> Result<proto::Placement, ArtifactError> {
        expect!(self.artifact(ArtifactRequest::Place(request)).await?,
            ArtifactResponse::Placed(placement) => placement)
    }

    /// Like [`place`](Self::place), uploading `png` (this device's render) first.
    pub async fn place_png(
        &self,
        mut request: proto::PlaceRequest,
        png: Vec<u8>,
    ) -> Result<proto::Placement, ArtifactError> {
        let session = self.artifact_session(request.artifact_id).await?;
        request.png = Some(self.blob_upload(session, png).await?.hash);
        self.place(request).await
    }

    /// A drawing's finished versions, newest first (none for images).
    ///
    /// # Errors
    ///
    /// [`ArtifactError::Failed`] without asking when the daemon does not offer
    /// [`DaemonFeatures::ARTIFACT_HISTORY`](proto::DaemonFeatures::ARTIFACT_HISTORY) (older
    /// daemons drop a connection that sends the request); else the daemon's error.
    pub async fn artifact_history(
        &self,
        artifact_id: ArtifactId,
    ) -> Result<Vec<proto::ArtifactVersion>, ArtifactError> {
        self.require_history()?;
        expect!(self.artifact(ArtifactRequest::History { artifact_id }).await?,
            ArtifactResponse::History(history) => history)
    }

    /// Brings a drawing back to `version` from its history, as a new version on top; open
    /// editors, caches and placements follow through the ordinary pushes. Returns the
    /// drawing now and the history entry the restore made.
    ///
    /// # Errors
    ///
    /// As [`artifact_history`](Self::artifact_history); `NotFound` for a version not in the
    /// history.
    pub async fn artifact_restore(
        &self,
        artifact_id: ArtifactId,
        version: u64,
    ) -> Result<(ArtifactInfo, proto::ArtifactVersion), ArtifactError> {
        self.require_history()?;
        expect!(self.artifact(ArtifactRequest::Restore { artifact_id, version }).await?,
            ArtifactResponse::Restored { info, version } => (info, version))
    }

    fn require_history(&self) -> Result<(), ArtifactError> {
        let offered = self.daemon_info().is_some_and(|info| {
            info.features
                .contains(proto::DaemonFeatures::ARTIFACT_HISTORY)
        });
        if offered {
            Ok(())
        } else {
            Err(ArtifactError::Failed(
                "the host's daemon keeps no drawing history; update it".into(),
            ))
        }
    }

    /// The artifact as an `.excalidraw` file (what Excalidraw opens, and what dropping it on
    /// a pane imports): an Excalidraw scene with its images embedded, or an image as a scene
    /// holding it. Ink drawings (op-log artifacts) export as PNG or SVG instead.
    ///
    /// # Errors
    ///
    /// `Invalid` for ink drawings; the daemon's error for the scene or its blobs.
    pub async fn excalidraw_file(&self, artifact_id: ArtifactId) -> Result<Vec<u8>, ArtifactError> {
        let info = self.artifact_get(artifact_id, u64::MAX).await?.info;
        let file = match (info.kind, info.image) {
            (proto::ArtifactKind::Excalidraw, _) => {
                let scene = self.excalidraw_get(artifact_id, 0).await?;
                let mut files = Vec::with_capacity(scene.files.len());
                for file in scene.files {
                    let (image, bytes) = self.blob_download(file.image.hash).await?;
                    files.push((file.file_id, image.media.mime().to_owned(), bytes));
                }
                drawing::ExcalidrawFile {
                    elements: scene.elements,
                    app_state: scene.app_state,
                    files,
                }
            }
            (proto::ArtifactKind::Image, Some(image)) => {
                let (image, bytes) = self.blob_download(image.hash).await?;
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

    /// Removes an inline placement.
    pub async fn unplace(&self, placement_id: u64) -> Result<(), ArtifactError> {
        expect!(self.artifact(ArtifactRequest::Unplace { placement_id }).await?,
            ArtifactResponse::Done => ())
    }

    /// Asks for a pane's placements (also kept in [`placements`](Self::placements)).
    pub async fn list_placements(
        &self,
        pane_id: PaneId,
    ) -> Result<Vec<proto::Placement>, ArtifactError> {
        expect!(self.artifact(ArtifactRequest::Placements { pane_id }).await?,
            ArtifactResponse::Placements(placements) => placements)
    }

    /// A pane's inline placements as last pushed, oldest first.
    pub fn placements(&self, pane_id: PaneId) -> Vec<proto::Placement> {
        lock(&self.inner.art.placements)
            .get(&pane_id)
            .map(|by_id| by_id.values().cloned().collect())
            .unwrap_or_default()
    }

    /// A file pasted or dropped onto a pane (an image, or an `.excalidraw` scene): becomes an
    /// artifact placed inline at the cursor row. Large files are uploaded first.
    pub async fn import_to_pane(
        &self,
        pane_id: PaneId,
        name: String,
        data: Vec<u8>,
    ) -> Result<proto::Placement, ArtifactError> {
        let (data, blob) = if data.len() > 1 << 20 && drawing::sniff(&data).is_some() {
            let session = self.session_of(pane_id)?;
            (
                Vec::new(),
                Some(self.blob_upload(session, data).await?.hash),
            )
        } else {
            (data, None)
        };
        expect!(self.artifact(ArtifactRequest::Import(proto::ImportRequest { pane_id, name, data, blob })).await?,
            ArtifactResponse::Placed(placement) => placement)
    }

    /// Streams points of a stroke being drawn to the session's other clients (fire and
    /// forget; send about every 16 ms, new points only).
    pub fn ink_live(&self, ink: InkLive) {
        self.inner.send(ClientCtl::InkLive(ink));
    }

    /// The cached info and scene of an artifact.
    pub fn artifact_scene(&self, artifact_id: ArtifactId) -> Option<(ArtifactInfo, Scene)> {
        lock(&self.inner.art.cache)
            .get(&artifact_id)
            .map(|cached| (cached.info.clone(), cached.scene.clone()))
    }

    /// The canvas panes of a session, as last pushed.
    pub fn canvas_panes(&self, session_id: SessionId) -> Vec<CanvasPane> {
        lock(&self.inner.art.canvases)
            .get(&session_id)
            .cloned()
            .unwrap_or_default()
    }

    async fn artifact_session(&self, artifact_id: ArtifactId) -> Result<SessionId, ArtifactError> {
        if let Some(cached) = lock(&self.inner.art.cache).get(&artifact_id) {
            return Ok(cached.info.session_id);
        }
        Ok(self
            .artifact_get(artifact_id, u64::MAX)
            .await?
            .info
            .session_id)
    }

    fn session_of(&self, _pane: PaneId) -> Result<SessionId, ArtifactError> {
        lock(&self.inner.wanted)
            .session
            .ok_or_else(|| ArtifactError::Invalid("attach to a session first".into()))
    }

    /// Stores an image (PNG or JPEG) on the host; returns its reference.
    pub async fn blob_upload(
        &self,
        session_id: SessionId,
        bytes: Vec<u8>,
    ) -> Result<ImageRef, ArtifactError> {
        self.blob_upload_with_progress(session_id, bytes, None)
            .await
    }

    /// [`blob_upload`](Self::blob_upload), reporting progress after every 64 KiB written.
    pub async fn blob_upload_with_progress(
        &self,
        session_id: SessionId,
        bytes: Vec<u8>,
        progress: Option<Arc<dyn TransferProgress>>,
    ) -> Result<ImageRef, ArtifactError> {
        let media = drawing::sniff(&bytes)
            .ok_or_else(|| ArtifactError::Invalid("not a PNG or JPEG image".into()))?
            .0;
        let inner = Arc::clone(&self.inner);
        crate::run_on(&self.handle, async move {
            let conn = connection(&inner).await?;
            let (mut send, mut recv) = conn.open_bi().await.map_err(failed)?;
            let _ = send.set_priority(1);
            let header = BlobHeader::Put {
                session_id,
                size: bytes.len() as u64,
                media,
            };
            crate::conn::send(&mut send, &StreamHeader::Blob(header))
                .await
                .map_err(failed)?;
            match crate::conn::recv::<BlobReply>(&mut recv)
                .await
                .map_err(failed)?
            {
                Some(BlobReply::Ready) => {}
                Some(BlobReply::Failed(err)) => return Err(err),
                other => return Err(failed(format!("unexpected {other:?}"))),
            }
            // QUIC flow control paces the upload.
            let total = bytes.len() as u64;
            let mut done = 0u64;
            for chunk in bytes.chunks(CHUNK) {
                send.write_all(chunk).await.map_err(failed)?;
                done += chunk.len() as u64;
                if let Some(progress) = &progress {
                    progress.on_progress(done, total);
                }
            }
            let _ = send.finish();
            match crate::conn::recv::<BlobReply>(&mut recv)
                .await
                .map_err(failed)?
            {
                Some(BlobReply::Stored(image)) => Ok(image),
                Some(BlobReply::Failed(err)) => Err(err),
                other => Err(failed(format!("unexpected {other:?}"))),
            }
        })
        .await
        .unwrap_or_else(|err| Err(failed(err)))
    }

    /// Reads an image blob from the host.
    pub async fn blob_download(
        &self,
        hash: BlobHash,
    ) -> Result<(ImageRef, Vec<u8>), ArtifactError> {
        self.blob_download_with_progress(hash, None).await
    }

    /// [`blob_download`](Self::blob_download), reporting progress after every 64 KiB read.
    pub async fn blob_download_with_progress(
        &self,
        hash: BlobHash,
        progress: Option<Arc<dyn TransferProgress>>,
    ) -> Result<(ImageRef, Vec<u8>), ArtifactError> {
        let inner = Arc::clone(&self.inner);
        crate::run_on(&self.handle, async move {
            let conn = connection(&inner).await?;
            let (mut send, mut recv) = conn.open_bi().await.map_err(failed)?;
            let _ = send.set_priority(1);
            crate::conn::send(&mut send, &StreamHeader::Blob(BlobHeader::Get { hash }))
                .await
                .map_err(failed)?;
            let _ = send.finish();
            let image = match crate::conn::recv::<BlobReply>(&mut recv)
                .await
                .map_err(failed)?
            {
                Some(BlobReply::Found(image)) => image,
                Some(BlobReply::Failed(err)) => return Err(err),
                other => return Err(failed(format!("unexpected {other:?}"))),
            };
            let mut bytes = vec![0; image.size as usize];
            let total = image.size;
            let mut done = 0u64;
            for chunk in bytes.chunks_mut(CHUNK) {
                recv.read_exact(chunk).await.map_err(failed)?;
                done += chunk.len() as u64;
                if let Some(progress) = &progress {
                    progress.on_progress(done, total);
                }
            }
            Ok((image, bytes))
        })
        .await
        .unwrap_or_else(|err| Err(failed(err)))
    }
}

async fn connection(inner: &Inner) -> Result<iroh::endpoint::Connection, ArtifactError> {
    inner
        .connection_within(crate::workspace::LINK_WAIT, crate::WhileSuspended::GiveUp)
        .await
        .ok_or(ArtifactError::Disconnected)
}
