//! Drawings and images on [`DaemonClient`] (docs/DAEMON.md §7, the app contract in
//! §7.11): artifacts, op batches, live ink, export, blobs, Excalidraw scenes, inline
//! placements and send-to-agent, plus the `drawing` crate's on-device helpers (ink point
//! packing and simplification, ASCII/SVG/PNG renders of a scene).
//!
//! Requests are `async` and return the daemon's answer or an [`ArtifactError`]. Pushes go to
//! an [`ArtifactListener`]. The client keeps a cached copy of every drawing and Excalidraw
//! scene of the attached session it has seen ([`DaemonClient::artifact_scene`],
//! [`DaemonClient::excalidraw_scene`]) and every pane's placements
//! ([`DaemonClient::placements`]), caught up after reconnects.

use std::future::Future;
use std::sync::Arc;

use client_core::drawing;
use client_core::proto;

use crate::art_types::{
    ArtifactCreate, ArtifactError, ArtifactEvent, ArtifactInfo, ArtifactScene, ArtifactVersion,
    CachedExcalidraw, CachedScene, CanvasPane, CoordSpace, DrawElement, DrawOp, ExElement, ExFile,
    ExcalidrawApplied, ExcalidrawScene, ExportFormat, ExportedFile, ImageInfo, ImageRef, InkChunk,
    InkPoint, PlaceRequest, Placement, RestoredVersion, SentToAgent, blob_hash, ops_to_proto,
};
use crate::bytes::Bytes;
use crate::client::DaemonClient;
use crate::on_runtime;
use crate::workspace::{TransferProgress, progress_adapter};

/// Receives [`ArtifactEvent`]s; implemented in Swift.
///
/// Called on a runtime thread, in order, one at a time per client. Return quickly.
#[uniffi::export(foreign)]
pub trait ArtifactListener: Send + Sync {
    fn on_artifact_event(&self, event: ArtifactEvent);
}

struct ArtForward(Arc<dyn ArtifactListener>);

impl client_core::ArtifactListener for ArtForward {
    fn on_artifact(&self, update: client_core::ArtifactUpdate) {
        self.0.on_artifact_event(update.into());
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DownloadedBlob {
    pub image: ImageRef,
    pub data: Bytes,
}

impl DaemonClient {
    /// Runs a client-core artifact request on the runtime and converts its answer.
    async fn art_call<T, U, F, Fut>(&self, f: F) -> Result<U, ArtifactError>
    where
        F: FnOnce(Arc<client_core::Client>) -> Fut,
        Fut: Future<Output = Result<T, proto::ArtifactError>> + Send + 'static,
        T: Send + 'static,
        U: From<T>,
    {
        let fut = f(self.core());
        on_runtime(fut).await.map(U::from).map_err(Into::into)
    }
}

fn to_vec<T, U: From<T>>(items: Vec<T>) -> Vec<U> {
    items.into_iter().map(Into::into).collect()
}

#[uniffi::export]
impl DaemonClient {
    /// Sets the receiver of [`ArtifactEvent`]s, replacing any previous one.
    pub fn set_artifact_listener(&self, listener: Arc<dyn ArtifactListener>) {
        self.inner
            .set_artifact_listener(Arc::new(ArtForward(listener)));
    }

    /// A session's artifacts, oldest first.
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`].
    pub async fn list_artifacts(
        &self,
        session_id: u64,
    ) -> Result<Vec<ArtifactInfo>, ArtifactError> {
        let list: Vec<proto::ArtifactInfo> = self
            .art_call(|client| async move { client.artifacts(proto::SessionId(session_id)).await })
            .await?;
        Ok(to_vec(list))
    }

    /// Creates a drawing, image or Excalidraw scene.
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`]; `Invalid` for a malformed image hash.
    pub async fn artifact_create(
        &self,
        create: ArtifactCreate,
    ) -> Result<ArtifactInfo, ArtifactError> {
        let create = create.try_into()?;
        self.art_call(|client| async move { client.artifact_create(create).await })
            .await
    }

    /// A drawing's batches after `since` (or every element when it cannot continue from
    /// there; `since: 0` for the whole drawing). The cache is updated too.
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`].
    pub async fn artifact_get(
        &self,
        artifact_id: u64,
        since: u64,
    ) -> Result<ArtifactScene, ArtifactError> {
        self.art_call(|client| async move {
            client
                .artifact_get(proto::ArtifactId(artifact_id), since)
                .await
        })
        .await
    }

    /// Commits ops as one batch; returns the new version. Every client (this one too) gets
    /// it as [`ArtifactEvent::Changed`].
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`].
    pub async fn artifact_apply(
        &self,
        artifact_id: u64,
        base: u64,
        ops: Vec<DrawOp>,
    ) -> Result<u64, ArtifactError> {
        let ops = ops_to_proto(ops)?;
        self.art_call(|client| async move {
            client
                .artifact_apply(proto::ArtifactId(artifact_id), base, ops)
                .await
        })
        .await
    }

    /// Deletes an artifact (its canvas panes close).
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`].
    pub async fn artifact_delete(&self, artifact_id: u64) -> Result<(), ArtifactError> {
        self.art_call(|client| async move {
            client.artifact_delete(proto::ArtifactId(artifact_id)).await
        })
        .await
    }

    /// Anchors a drawing to a terminal row (`nil` unanchors it).
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`].
    pub async fn artifact_set_anchor(
        &self,
        artifact_id: u64,
        anchor: Option<crate::art_types::AnchorRequest>,
    ) -> Result<ArtifactInfo, ArtifactError> {
        self.art_call(|client| async move {
            client
                .artifact_set_anchor(proto::ArtifactId(artifact_id), anchor.map(Into::into))
                .await
        })
        .await
    }

    /// Uploads this device's PNG render of a drawing version as its preview.
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`] (`Invalid` when `png` is not a PNG).
    pub async fn artifact_set_preview(
        &self,
        artifact_id: u64,
        version: u64,
        png: Bytes,
    ) -> Result<ArtifactInfo, ArtifactError> {
        self.art_call(|client| async move {
            client
                .artifact_set_preview(proto::ArtifactId(artifact_id), version, png.0)
                .await
        })
        .await
    }

    /// Exports PNG (the image, the preview or the daemon's render), SVG or ASCII text at
    /// `version` (`nil` = current). Large PNGs are downloaded as blobs transparently.
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`].
    pub async fn artifact_export(
        &self,
        artifact_id: u64,
        version: Option<u64>,
        format: ExportFormat,
    ) -> Result<ExportedFile, ArtifactError> {
        let core = self.core();
        let (version, data) = on_runtime(async move {
            core.artifact_export(proto::ArtifactId(artifact_id), version, format.into())
                .await
        })
        .await?;
        Ok(ExportedFile {
            format,
            version,
            data: data.into(),
        })
    }

    /// The artifact as an `.excalidraw` file (images embedded): an Excalidraw scene, or an
    /// image as a scene holding it. Ink drawings have none (`Invalid`).
    ///
    /// # Errors
    ///
    /// `Invalid` for ink drawings; otherwise the daemon's [`ArtifactError`].
    pub async fn excalidraw_file(&self, artifact_id: u64) -> Result<Bytes, ArtifactError> {
        let core = self.core();
        let data =
            on_runtime(async move { core.excalidraw_file(proto::ArtifactId(artifact_id)).await })
                .await?;
        Ok(data.into())
    }

    /// Whether the daemon keeps drawings' finished versions
    /// ([`artifact_history`](Self::artifact_history), [`artifact_restore`](Self::artifact_restore)).
    pub fn offers_drawing_history(&self) -> bool {
        self.inner
            .daemon_info()
            .is_some_and(|i| i.features.contains(proto::DaemonFeatures::ARTIFACT_HISTORY))
    }

    /// A drawing's finished versions, newest first (none for images).
    ///
    /// # Errors
    ///
    /// `Failed` when the daemon keeps no history (see
    /// [`offers_drawing_history`](Self::offers_drawing_history)); otherwise the daemon's
    /// [`ArtifactError`].
    pub async fn artifact_history(
        &self,
        artifact_id: u64,
    ) -> Result<Vec<ArtifactVersion>, ArtifactError> {
        let list: Vec<proto::ArtifactVersion> = self
            .art_call(|client| async move {
                client
                    .artifact_history(proto::ArtifactId(artifact_id))
                    .await
            })
            .await?;
        Ok(to_vec(list))
    }

    /// Brings a drawing back to `version` from its history, as a new version on top. Open
    /// editors get it as [`ArtifactEvent::Excalidraw`], placements as `Placed` with the old
    /// render.
    ///
    /// # Errors
    ///
    /// As [`artifact_history`](Self::artifact_history); `NotFound` for a version not in it.
    pub async fn artifact_restore(
        &self,
        artifact_id: u64,
        version: u64,
    ) -> Result<RestoredVersion, ArtifactError> {
        let core = self.core();
        let (info, version) = on_runtime(async move {
            core.artifact_restore(proto::ArtifactId(artifact_id), version)
                .await
        })
        .await?;
        Ok(RestoredVersion {
            info: info.into(),
            version: version.into(),
        })
    }

    /// "Send to agent": the daemon writes the PNG on the host and pastes its path into the
    /// agent pane (never Enter). `png` is this device's render (`nil` uses the artifact's
    /// image / preview / the daemon's render); with no `artifact_id`, `png` is a bare image.
    ///
    /// # Errors
    ///
    /// [`ArtifactError::NotAgentPane`] when the pane runs no agent; otherwise the daemon's
    /// [`ArtifactError`].
    pub async fn send_to_agent(
        &self,
        pane_id: u64,
        artifact_id: Option<u64>,
        version: Option<u64>,
        png: Option<Bytes>,
    ) -> Result<SentToAgent, ArtifactError> {
        self.art_call(|client| async move {
            client
                .send_to_agent(
                    proto::PaneId(pane_id),
                    artifact_id.map(proto::ArtifactId),
                    version,
                    png.map(|p| p.0),
                )
                .await
        })
        .await
    }

    /// The cached copy of a drawing: info, version and elements in drawing order (no round
    /// trip). `nil` for an artifact not seen yet.
    pub fn artifact_scene(&self, artifact_id: u64) -> Option<CachedScene> {
        let (info, scene) = self.inner.artifact_scene(proto::ArtifactId(artifact_id))?;
        Some(CachedScene {
            info: info.into(),
            version: scene.version,
            elements: scene
                .draw_order()
                .into_iter()
                .cloned()
                .map(Into::into)
                .collect(),
        })
    }

    /// The session's canvas panes, as last pushed.
    pub fn canvas_panes(&self, session_id: u64) -> Vec<CanvasPane> {
        to_vec(self.inner.canvas_panes(proto::SessionId(session_id)))
    }

    /// Streams new points of a stroke being drawn to the session's other clients (fire and
    /// forget; about every 16 ms while the pen moves). They get [`ArtifactEvent::Ink`].
    pub fn ink_live(&self, chunk: InkChunk) {
        self.inner.ink_live(proto::InkLive {
            artifact_id: proto::ArtifactId(chunk.artifact_id),
            stroke_id: proto::ElementId(chunk.stroke_id),
            actor: proto::Actor {
                principal: proto::PrincipalId([0; 16]),
                device: proto::DeviceId([0; 32]),
            },
            chunk: chunk.chunk,
            tool: chunk.tool.into(),
            style: chunk.style.into(),
            points: proto::PackedPoints(chunk.points.0),
            done: chunk.done,
        });
    }

    /// An Excalidraw scene (`since: 0`) or the elements changed after revision `since`; the
    /// cache is updated too.
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`].
    pub async fn excalidraw_get(
        &self,
        artifact_id: u64,
        since: u64,
    ) -> Result<ExcalidrawScene, ArtifactError> {
        self.art_call(|client| async move {
            client
                .excalidraw_get(proto::ArtifactId(artifact_id), since)
                .await
        })
        .await
    }

    /// Offers changed elements (whole elements, from the editor's `onChange`), the
    /// persistent app state if it changed, and newly referenced files (uploaded first).
    /// Returns the new revision and the offered elements that lost, as the stored winners.
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`] (`Forbidden` for viewers).
    pub async fn excalidraw_put(
        &self,
        artifact_id: u64,
        elements: Vec<ExElement>,
        app_state: Option<String>,
        files: Vec<ExFile>,
    ) -> Result<ExcalidrawApplied, ArtifactError> {
        let files = files
            .into_iter()
            .map(TryInto::try_into)
            .collect::<Result<Vec<_>, _>>()?;
        let elements = to_vec(elements);
        let core = self.core();
        let (version, rejected) = on_runtime(async move {
            core.excalidraw_put(proto::ArtifactId(artifact_id), elements, app_state, files)
                .await
        })
        .await?;
        Ok(ExcalidrawApplied {
            version,
            rejected: to_vec(rejected),
        })
    }

    /// The cached copy of an Excalidraw scene (no round trip), kept reconciled with pushes.
    pub fn excalidraw_scene(&self, artifact_id: u64) -> Option<CachedExcalidraw> {
        self.inner
            .excalidraw_scene(proto::ArtifactId(artifact_id))
            .map(Into::into)
    }

    /// Shows an artifact inline in a terminal pane (the daemon renders it, or uses the
    /// image / preview).
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`].
    pub async fn place(&self, request: PlaceRequest) -> Result<Placement, ArtifactError> {
        self.art_call(|client| async move { client.place(request.into()).await })
            .await
    }

    /// Like [`place`](Self::place) with this device's PNG render (uploaded first): the
    /// overlay's "Done".
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`].
    pub async fn place_png(
        &self,
        request: PlaceRequest,
        png: Bytes,
    ) -> Result<Placement, ArtifactError> {
        self.art_call(|client| async move { client.place_png(request.into(), png.0).await })
            .await
    }

    /// Removes an inline placement.
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`].
    pub async fn unplace(&self, placement_id: u64) -> Result<(), ArtifactError> {
        self.art_call(|client| async move { client.unplace(placement_id).await })
            .await
    }

    /// Asks the daemon for a pane's placements (the cache is updated too).
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`].
    pub async fn list_placements(&self, pane_id: u64) -> Result<Vec<Placement>, ArtifactError> {
        let list: Vec<proto::Placement> = self
            .art_call(|client| async move { client.list_placements(proto::PaneId(pane_id)).await })
            .await?;
        Ok(to_vec(list))
    }

    /// A pane's inline placements as last pushed (on attach and on change), oldest first.
    pub fn placements(&self, pane_id: u64) -> Vec<Placement> {
        to_vec(self.inner.placements(proto::PaneId(pane_id)))
    }

    /// A file pasted or dropped onto a pane (an image, or an `.excalidraw` scene): becomes
    /// an artifact placed inline at the cursor row.
    ///
    /// # Errors
    ///
    /// The daemon's [`ArtifactError`].
    pub async fn import_to_pane(
        &self,
        pane_id: u64,
        name: String,
        data: Bytes,
    ) -> Result<Placement, ArtifactError> {
        self.art_call(|client| async move {
            client
                .import_to_pane(proto::PaneId(pane_id), name, data.0)
                .await
        })
        .await
    }

    /// Stores an image (PNG or JPEG) on the host for `session_id`; returns its reference
    /// (use its `hash` in `ArtifactCreate.image` or an `ExFile`). `progress` hears every
    /// 64 KiB.
    ///
    /// # Errors
    ///
    /// `Invalid` when the bytes are not a PNG or JPEG; the daemon's [`ArtifactError`].
    pub async fn blob_upload(
        &self,
        session_id: u64,
        data: Bytes,
        progress: Option<Arc<dyn TransferProgress>>,
    ) -> Result<ImageRef, ArtifactError> {
        let progress = progress_adapter(progress);
        self.art_call(|client| async move {
            client
                .blob_upload_with_progress(proto::SessionId(session_id), data.0, progress)
                .await
        })
        .await
    }

    /// Reads an image blob (by hash) from the host. `progress` hears every 64 KiB.
    ///
    /// # Errors
    ///
    /// `NotFound` for an unknown blob; `Invalid` for a malformed hash.
    pub async fn blob_download(
        &self,
        hash: String,
        progress: Option<Arc<dyn TransferProgress>>,
    ) -> Result<DownloadedBlob, ArtifactError> {
        let hash = blob_hash(&hash)?;
        let progress = progress_adapter(progress);
        let core = self.core();
        let (image, data) =
            on_runtime(async move { core.blob_download_with_progress(hash, progress).await })
                .await?;
        Ok(DownloadedBlob {
            image: image.into(),
            data: data.into(),
        })
    }
}

fn scene_of(elements: Vec<DrawElement>) -> Result<drawing::Scene, ArtifactError> {
    let elements = elements
        .into_iter()
        .map(TryInto::try_into)
        .collect::<Result<Vec<proto::Element>, _>>()?;
    Ok(drawing::Scene::from_elements(0, elements))
}

/// Packs stroke points into the wire form (`DrawElementKind.stroke(points:)`, `InkChunk.points`):
/// about 6 bytes a point, coordinates rounded to 1/32 unit.
#[uniffi::export]
pub fn pack_ink_points(points: Vec<InkPoint>) -> Bytes {
    let points: Vec<drawing::InkPoint> = to_vec(points);
    drawing::pack(&points).0.into()
}

/// Unpacks stroke points (a stroke element's or a live ink chunk's).
///
/// # Errors
///
/// `Invalid` for malformed data.
#[uniffi::export]
pub fn unpack_ink_points(packed: Bytes) -> Result<Vec<InkPoint>, ArtifactError> {
    drawing::unpack(&proto::PackedPoints(packed.0))
        .map(to_vec)
        .map_err(|e| ArtifactError::Invalid {
            message: e.to_string(),
        })
}

/// Ramer–Douglas–Peucker simplification for a committed stroke: drops points closer than
/// `epsilon` (drawing units) to the line through their neighbours, keeping pressure swells.
#[uniffi::export]
pub fn simplify_ink_points(points: Vec<InkPoint>, epsilon: f32) -> Vec<InkPoint> {
    let points: Vec<drawing::InkPoint> = to_vec(points);
    to_vec(drawing::simplify(&points, epsilon))
}

/// Renders drawing elements as box-drawing text at most `max_cols` wide (what the daemon's
/// ASCII export writes), for a terminal-only preview.
///
/// # Errors
///
/// `Invalid` for a malformed image hash in an element.
#[uniffi::export]
pub fn render_ascii(
    elements: Vec<DrawElement>,
    space: CoordSpace,
    max_cols: u32,
) -> Result<String, ArtifactError> {
    Ok(drawing::to_ascii(
        &scene_of(elements)?,
        space.into(),
        max_cols as usize,
    ))
}

/// Renders drawing elements as a standalone SVG document (image elements as placeholders).
///
/// # Errors
///
/// `Invalid` for a malformed image hash in an element.
#[uniffi::export]
pub fn render_svg(
    elements: Vec<DrawElement>,
    space: CoordSpace,
    title: String,
) -> Result<String, ArtifactError> {
    Ok(drawing::to_svg(
        &scene_of(elements)?,
        space.into(),
        &title,
        &|_| None,
    ))
}

/// Rasterises drawing elements to a PNG with the core's small CPU renderer (`scale` pixels
/// per unit, `background` `0xRRGGBBAA`, `0` = transparent). The app normally renders with
/// PencilKit / Excalidraw; this is the fallback the daemon uses.
///
/// # Errors
///
/// `Invalid` for a malformed image hash in an element.
#[uniffi::export]
pub fn render_png(
    elements: Vec<DrawElement>,
    space: CoordSpace,
    scale: f32,
    background: u32,
) -> Result<Bytes, ArtifactError> {
    let opts = drawing::RasterOptions {
        scale,
        background,
        ..drawing::RasterOptions::default()
    };
    let img = drawing::rasterize(&scene_of(elements)?, space.into(), opts);
    Ok(drawing::encode_png(&img).into())
}

/// Renders Excalidraw elements as box-drawing text (10 × 20 scene px per character, the
/// overlay's cell mapping).
#[uniffi::export]
pub fn render_excalidraw_ascii(elements: Vec<ExElement>, max_cols: u32) -> String {
    let mut scene = drawing::ExScene::new();
    scene.absorb(to_vec(elements), 1);
    drawing::to_ascii(
        &scene.to_scene(),
        proto::CoordSpace::Canvas,
        max_cols as usize,
    )
}

/// Reads an Excalidraw element's reconciliation fields (`id`, `version`, `versionNonce`,
/// `isDeleted`) from its JSON, for `excalidraw_put`.
///
/// # Errors
///
/// `Invalid` when the JSON is not an object with a string `id` and a numeric `version`.
#[uniffi::export]
pub fn excalidraw_element(json: String) -> Result<ExElement, ArtifactError> {
    drawing::parse_element(&json)
        .map(Into::into)
        .map_err(|message| ArtifactError::Invalid { message })
}

/// Whether `incoming` replaces `current` under Excalidraw's rule (higher `version`, or equal
/// with a lower `versionNonce`).
#[uniffi::export]
pub fn excalidraw_wins(incoming: ExElement, current: ExElement) -> bool {
    drawing::wins(&incoming.into(), &current.into())
}

/// Format and pixel size from an image's header; `nil` when it is not a PNG or JPEG.
#[uniffi::export]
pub fn sniff_image(data: Bytes) -> Option<ImageInfo> {
    drawing::sniff(&data).map(|(media, width, height)| ImageInfo {
        media: media.into(),
        width,
        height,
    })
}
