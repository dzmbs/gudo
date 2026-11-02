//! FFI mirrors of the drawing wire types (`proto::artifact`; docs/DAEMON.md §7).
//!
//! Same rules as [`crate::types`]: ids are `u64`, times are Unix milliseconds (`*_ms`),
//! payloads (packed ink points, PNGs, SVG text) are [`Bytes`]. Blob hashes are 64 lowercase
//! hex digits.

use client_core::proto;

use crate::bytes::Bytes;
use crate::mp::Actor;

/// Why a drawing or image request failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ArtifactError {
    /// No such artifact, session, pane, blob or version (or outside the grant's scope).
    #[error("not found: {message}")]
    NotFound { message: String },
    /// The grant's roles do not allow it; the text names the role needed.
    #[error("not allowed: {message}")]
    Forbidden { message: String },
    /// Over a size cap; the text names it.
    #[error("too large: {message}")]
    TooLarge {
        /// Which cap.
        message: String,
    },
    /// Malformed (not a PNG, bad points, wrong kind, a bad hash).
    #[error("invalid: {message}")]
    Invalid { message: String },
    /// "Send to agent" into a pane that runs no agent.
    #[error("the pane runs no agent")]
    NotAgentPane,
    #[error("{message}")]
    Failed { message: String },
    /// The connection dropped before the daemon answered.
    #[error("disconnected before the daemon answered")]
    Disconnected,
}

impl From<proto::ArtifactError> for ArtifactError {
    fn from(artifact_error: proto::ArtifactError) -> Self {
        use proto::ArtifactError as E;
        match artifact_error {
            E::NotFound(message) => Self::NotFound { message },
            E::Forbidden(message) => Self::Forbidden { message },
            E::TooLarge(message) => Self::TooLarge { message },
            E::Invalid(message) => Self::Invalid { message },
            E::NotAgentPane => Self::NotAgentPane,
            E::Failed(message) => Self::Failed { message },
            E::Disconnected => Self::Disconnected,
        }
    }
}

/// Parses a blob hash (64 hex digits).
pub(crate) fn blob_hash(hex: &str) -> Result<proto::BlobHash, ArtifactError> {
    proto::BlobHash::from_hex(hex.trim()).ok_or_else(|| ArtifactError::Invalid {
        message: format!("blob hash: expected 64 hex digits, got {hex:?}"),
    })
}

macro_rules! mirror_enum {
    ($(#[$doc:meta])* $name:ident = $p:ident { $($(#[$vdoc:meta])* $v:ident),* $(,)? }) => {
        $(#[$doc])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
        pub enum $name {
            $($(#[$vdoc])* $v,)*
        }

        impl From<proto::$p> for $name {
            fn from(value: proto::$p) -> Self {
                match value {
                    $(proto::$p::$v => Self::$v,)*
                }
            }
        }

        impl From<$name> for proto::$p {
            fn from(value: $name) -> Self {
                match value {
                    $($name::$v => Self::$v,)*
                }
            }
        }
    };
}
pub(crate) use mirror_enum;

mirror_enum! {
    /// What an artifact holds.
    ArtifactKind = ArtifactKind {
        /// Vector strokes, shapes, text and placed images.
        Drawing,
        Image,
        /// An Excalidraw scene (elements as Excalidraw's JSON).
        Excalidraw,
    }
}

mirror_enum! {
    /// The coordinate space of a drawing's elements.
    CoordSpace = CoordSpace {
        /// Canvas units (points), origin top left.
        Canvas,
        /// Terminal cells: `x` in columns, `y` in rows from the anchor row (fractional).
        Cells,
    }
}

mirror_enum! {
    /// Image encodings the daemon stores.
    MediaType = MediaType {
        Png,
        Jpeg,
    }
}

mirror_enum! {
    /// The pen a stroke was drawn with.
    InkTool = Tool {
        /// Opaque, pressure-sensitive.
        Pen,
        /// Translucent, wide, drawn under pens.
        Highlighter,
        /// Opaque, constant width.
        Marker,
    }
}

mirror_enum! {
    /// Geometric shapes.
    ShapeKind = ShapeKind {
        /// Axis-aligned rectangle between the two corners.
        Rect,
        /// Ellipse inscribed in that rectangle.
        Ellipse,
        Line,
        /// Line with an arrow head at `to`.
        Arrow,
    }
}

mirror_enum! {
    /// Which screen an anchor's row is on.
    AnchorScreen = AnchorScreen {
        /// The normal screen with scrollback.
        Primary,
        /// The alternate screen; dropped when the program leaves it.
        Alternate,
    }
}

mirror_enum! {
    /// Why an anchor lost its row.
    DetachReason = DetachReason {
        /// Evicted from scrollback or erased (`clear`).
        RowGone,
        /// The full-screen program left the alternate screen.
        AltScreenExited,
        /// The pane closed.
        PaneClosed,
        /// The daemon restarted.
        DaemonRestart,
    }
}

mirror_enum! {
    /// Export formats.
    ExportFormat = ExportFormat {
        /// The image, or the drawing's preview / the daemon's render.
        Png,
        /// SVG written by the daemon from the vector elements.
        Svg,
        /// Box-drawing text (shapes, arrows, text; ink as dots).
        Ascii,
    }
}

mirror_enum! {
    /// Where a placement came from.
    PlacementSource = PlacementSource {
        /// A person placed or imported it.
        User,
        /// Made by older daemons from kitty graphics output; no longer produced.
        Kitty,
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ImageRef {
    /// SHA-256, 64 lowercase hex digits.
    pub hash: String,
    pub media: MediaType,
    pub size: u64,
    pub width: u32,
    pub height: u32,
}

impl From<proto::ImageRef> for ImageRef {
    fn from(image_ref: proto::ImageRef) -> Self {
        Self {
            hash: image_ref.hash.to_hex(),
            media: image_ref.media.into(),
            size: image_ref.size,
            width: image_ref.width,
            height: image_ref.height,
        }
    }
}

impl TryFrom<ImageRef> for proto::ImageRef {
    type Error = ArtifactError;

    fn try_from(image_ref: ImageRef) -> Result<Self, ArtifactError> {
        Ok(Self {
            hash: blob_hash(&image_ref.hash)?,
            media: image_ref.media.into(),
            size: image_ref.size,
            width: image_ref.width,
            height: image_ref.height,
        })
    }
}

/// Colour and line width of an element.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct DrawStyle {
    /// `0xRRGGBBAA`.
    pub color: u32,
    /// Nominal line width in the drawing's units.
    pub width: f32,
}

impl From<proto::Style> for DrawStyle {
    fn from(style: proto::Style) -> Self {
        Self {
            color: style.color,
            width: style.width,
        }
    }
}

impl From<DrawStyle> for proto::Style {
    fn from(draw_style: DrawStyle) -> Self {
        Self {
            color: draw_style.color,
            width: draw_style.width,
        }
    }
}

/// A point in the drawing's units.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Pt {
    pub x: f32,
    pub y: f32,
}

impl From<proto::Pt> for Pt {
    fn from(point: proto::Pt) -> Self {
        Self {
            x: point.x,
            y: point.y,
        }
    }
}

impl From<Pt> for proto::Pt {
    fn from(point: Pt) -> Self {
        Self {
            x: point.x,
            y: point.y,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum DrawElementKind {
    /// Freehand ink; `points` are packed (`pack_ink_points`).
    Stroke {
        tool: InkTool,
        /// Packed points.
        points: Bytes,
    },
    /// A shape from `from` to `to`.
    Shape {
        shape: ShapeKind,
        /// First corner or start.
        from: Pt,
        /// Opposite corner or end.
        to: Pt,
        /// Filled (rect and ellipse).
        filled: bool,
    },
    /// A text box; `at` is the top-left of the first line.
    Text {
        at: Pt,
        text: String,
        /// Font size in the drawing's units.
        size: f32,
    },
    /// An image blob placed in `from`..`to`.
    Image {
        image: ImageRef,
        /// Top-left.
        from: Pt,
        /// Bottom-right.
        to: Pt,
    },
}

impl From<proto::ElementKind> for DrawElementKind {
    fn from(element_kind: proto::ElementKind) -> Self {
        use proto::ElementKind as K;
        match element_kind {
            K::Stroke(stroke) => Self::Stroke {
                tool: stroke.tool.into(),
                points: stroke.points.0.into(),
            },
            K::Shape {
                shape,
                from,
                to,
                filled,
            } => Self::Shape {
                shape: shape.into(),
                from: from.into(),
                to: to.into(),
                filled,
            },
            K::Text { at, text, size } => Self::Text {
                at: at.into(),
                text,
                size,
            },
            K::Image { image, from, to } => Self::Image {
                image: image.into(),
                from: from.into(),
                to: to.into(),
            },
        }
    }
}

impl TryFrom<DrawElementKind> for proto::ElementKind {
    type Error = ArtifactError;

    fn try_from(draw_element_kind: DrawElementKind) -> Result<Self, ArtifactError> {
        Ok(match draw_element_kind {
            DrawElementKind::Stroke { tool, points } => Self::Stroke(proto::Stroke {
                tool: tool.into(),
                points: proto::PackedPoints(points.0),
            }),
            DrawElementKind::Shape {
                shape,
                from,
                to,
                filled,
            } => Self::Shape {
                shape: shape.into(),
                from: from.into(),
                to: to.into(),
                filled,
            },
            DrawElementKind::Text { at, text, size } => Self::Text {
                at: at.into(),
                text,
                size,
            },
            DrawElementKind::Image { image, from, to } => Self::Image {
                image: image.try_into()?,
                from: from.into(),
                to: to.into(),
            },
        })
    }
}

/// One element of a drawing. Higher `z` draws on top; ties keep insertion order.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DrawElement {
    /// Its id, chosen by the client that adds it (random 64 bits).
    pub id: u64,
    /// Stacking order.
    pub z: i32,
    /// Colour and width.
    pub style: DrawStyle,
    pub kind: DrawElementKind,
}

impl From<proto::Element> for DrawElement {
    fn from(element: proto::Element) -> Self {
        Self {
            id: element.id.0,
            z: element.z,
            style: element.style.into(),
            kind: element.kind.into(),
        }
    }
}

impl TryFrom<DrawElement> for proto::Element {
    type Error = ArtifactError;

    fn try_from(draw_element: DrawElement) -> Result<Self, ArtifactError> {
        Ok(Self {
            id: proto::ElementId(draw_element.id),
            z: draw_element.z,
            style: draw_element.style.into(),
            kind: draw_element.kind.try_into()?,
        })
    }
}

/// A change to a drawing. Elements are add-wins, fields last-writer-wins.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum DrawOp {
    /// Adds an element (replacing one with the same id).
    Add {
        element: DrawElement,
    },
    /// Moves an element by `(dx, dy)`.
    Move {
        id: u64,
        /// Offset x.
        dx: f32,
        /// Offset y.
        dy: f32,
    },
    Restyle {
        id: u64,
        style: DrawStyle,
    },
    /// Changes an element's stacking order.
    SetZ {
        id: u64,
        z: i32,
    },
    Delete {
        id: u64,
    },
    Clear,
    SetTitle {
        title: String,
    },
}

impl From<proto::DrawOp> for DrawOp {
    fn from(draw_op: proto::DrawOp) -> Self {
        use proto::DrawOp as O;
        match draw_op {
            O::Add(element) => Self::Add {
                element: element.into(),
            },
            O::Move { id, dx, dy } => Self::Move { id: id.0, dx, dy },
            O::Restyle { id, style } => Self::Restyle {
                id: id.0,
                style: style.into(),
            },
            O::SetZ { id, z } => Self::SetZ { id: id.0, z },
            O::Delete { id } => Self::Delete { id: id.0 },
            O::Clear => Self::Clear,
            O::SetTitle(title) => Self::SetTitle { title },
        }
    }
}

impl TryFrom<DrawOp> for proto::DrawOp {
    type Error = ArtifactError;

    fn try_from(draw_op: DrawOp) -> Result<Self, ArtifactError> {
        use proto::ElementId as Id;
        Ok(match draw_op {
            DrawOp::Add { element } => Self::Add(element.try_into()?),
            DrawOp::Move { id, dx, dy } => Self::Move { id: Id(id), dx, dy },
            DrawOp::Restyle { id, style } => Self::Restyle {
                id: Id(id),
                style: style.into(),
            },
            DrawOp::SetZ { id, z } => Self::SetZ { id: Id(id), z },
            DrawOp::Delete { id } => Self::Delete { id: Id(id) },
            DrawOp::Clear => Self::Clear,
            DrawOp::SetTitle { title } => Self::SetTitle(title),
        })
    }
}

pub(crate) fn ops_to_proto(ops: Vec<DrawOp>) -> Result<Vec<proto::DrawOp>, ArtifactError> {
    ops.into_iter().map(TryInto::try_into).collect()
}

/// One committed change: the ops of one request, in order.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct OpBatch {
    /// The version this batch produces (the first batch makes version 1).
    pub version: u64,
    /// Who committed it.
    pub actor: Actor,
    /// When the daemon accepted it.
    pub at_ms: u64,
    pub ops: Vec<DrawOp>,
}

impl From<proto::OpBatch> for OpBatch {
    fn from(op_batch: proto::OpBatch) -> Self {
        Self {
            version: op_batch.version,
            actor: op_batch.actor.into(),
            at_ms: op_batch.at.0,
            ops: op_batch.ops.into_iter().map(Into::into).collect(),
        }
    }
}

/// Where on a terminal's output to anchor: the row `from_bottom` rows above the bottom row
/// of the pane's screen as the app's VT showed it after applying output up to `at_seq`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct AnchorRequest {
    /// The terminal pane.
    pub pane_id: u64,
    /// Output offset the app's screen reflected.
    pub at_seq: u64,
    /// Rows above the bottom row (0 = the bottom row of the active area).
    pub from_bottom: u64,
}

impl From<AnchorRequest> for proto::AnchorRequest {
    fn from(anchor_request: AnchorRequest) -> Self {
        Self {
            pane_id: proto::PaneId(anchor_request.pane_id),
            at_seq: proto::Seq(anchor_request.at_seq),
            from_bottom: anchor_request.from_bottom,
        }
    }
}

/// Whether an anchor still has its row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AnchorState {
    /// Glued to its row.
    Live,
    /// Lost its row; the drawing moved to the pane's loose tray.
    Detached { reason: DetachReason },
}

impl From<proto::AnchorState> for AnchorState {
    fn from(anchor_state: proto::AnchorState) -> Self {
        match anchor_state {
            proto::AnchorState::Live => Self::Live,
            proto::AnchorState::Detached(reason) => Self::Detached {
                reason: reason.into(),
            },
        }
    }
}

/// A drawing's or placement's anchor on a terminal pane. Once the app's VT has applied
/// `at_seq`, pin the row `from_bottom` rows above the bottom and track it from then on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct RowAnchor {
    pub pane_id: u64,
    /// Which screen.
    pub screen: AnchorScreen,
    /// Output offset the position refers to.
    pub at_seq: u64,
    /// Rows above the bottom row at `at_seq`; meaningless once detached.
    pub from_bottom: u64,
    /// The OSC 133 command whose block holds the row, if any.
    pub command_id: Option<u64>,
    /// Live or detached.
    pub state: AnchorState,
}

impl From<proto::RowAnchor> for RowAnchor {
    fn from(row_anchor: proto::RowAnchor) -> Self {
        Self {
            pane_id: row_anchor.pane_id.0,
            screen: row_anchor.screen.into(),
            at_seq: row_anchor.at_seq.0,
            from_bottom: row_anchor.from_bottom,
            command_id: row_anchor.command_id,
            state: row_anchor.state.into(),
        }
    }
}

/// A rendered PNG of a drawing at one version.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ArtifactPreview {
    pub image: ImageRef,
    /// The drawing version it shows.
    pub version: u64,
}

impl From<proto::Preview> for ArtifactPreview {
    fn from(preview: proto::Preview) -> Self {
        Self {
            image: preview.image.into(),
            version: preview.version,
        }
    }
}

/// Everything a client lists about an artifact.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ArtifactInfo {
    pub artifact_id: u64,
    pub session_id: u64,
    /// Drawing, image or Excalidraw scene.
    pub kind: ArtifactKind,
    /// Title (may be empty).
    pub title: String,
    /// DrawElement coordinates.
    pub space: CoordSpace,
    pub created_by: Actor,
    pub created_at_ms: u64,
    /// Last change.
    pub updated_at_ms: u64,
    /// Committed batches (a drawing) or the scene's revision (Excalidraw).
    pub version: u64,
    /// Elements now.
    pub elements: u32,
    /// For images: the image.
    pub image: Option<ImageRef>,
    /// The last PNG rendered and the version it shows.
    pub preview: Option<ArtifactPreview>,
    /// For ink overlays: the anchor.
    pub anchor: Option<RowAnchor>,
    /// Canvas panes showing it.
    pub canvas_panes: Vec<u64>,
}

/// One finished version of a drawing ([`DaemonClient::artifact_history`](crate::DaemonClient::artifact_history)).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArtifactVersion {
    /// The drawing's version (an Excalidraw scene's revision).
    pub version: u64,
    /// When it was recorded (Unix ms).
    pub at_ms: u64,
    /// Who finished it.
    pub by: Actor,
    /// The render shown then (`nil` when nobody rendered it).
    pub image: Option<ImageRef>,
    /// Live elements in it.
    pub elements: u32,
    /// This version restored an older one.
    pub restored_from: Option<u64>,
}

impl From<proto::ArtifactVersion> for ArtifactVersion {
    fn from(artifact_version: proto::ArtifactVersion) -> Self {
        Self {
            version: artifact_version.version,
            at_ms: artifact_version.at.0,
            by: artifact_version.by.into(),
            image: artifact_version.image.map(Into::into),
            elements: artifact_version.elements,
            restored_from: artifact_version.restored_from,
        }
    }
}

/// What a restore did.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RestoredVersion {
    /// The drawing now.
    pub info: ArtifactInfo,
    /// The history entry the restore made (`restored_from` names the version brought back).
    pub version: ArtifactVersion,
}

impl From<proto::ArtifactInfo> for ArtifactInfo {
    fn from(artifact_info: proto::ArtifactInfo) -> Self {
        Self {
            artifact_id: artifact_info.artifact_id.0,
            session_id: artifact_info.session_id.0,
            kind: artifact_info.kind.into(),
            title: artifact_info.title,
            space: artifact_info.space.into(),
            created_by: artifact_info.created_by.into(),
            created_at_ms: artifact_info.created_at.0,
            updated_at_ms: artifact_info.updated_at.0,
            version: artifact_info.version,
            elements: artifact_info.elements,
            image: artifact_info.image.map(Into::into),
            preview: artifact_info.preview.map(Into::into),
            anchor: artifact_info.anchor.map(Into::into),
            canvas_panes: artifact_info
                .canvas_panes
                .into_iter()
                .map(|p| p.0)
                .collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ArtifactCreate {
    /// The session it belongs to.
    pub session_id: u64,
    /// Drawing, image or Excalidraw scene.
    pub kind: ArtifactKind,
    #[uniffi(default = "")]
    pub title: String,
    /// Coordinate space (`cells` for ink over a terminal).
    pub space: CoordSpace,
    /// Anchor to a terminal row (ink overlays).
    #[uniffi(default = None)]
    pub anchor: Option<AnchorRequest>,
    /// For images: an uploaded blob's hash (`blob_upload`).
    #[uniffi(default = None)]
    pub image: Option<String>,
    /// Initial ops, committed as version 1 if not empty.
    #[uniffi(default = [])]
    pub ops: Vec<DrawOp>,
}

impl TryFrom<ArtifactCreate> for proto::ArtifactCreate {
    type Error = ArtifactError;

    fn try_from(artifact_create: ArtifactCreate) -> Result<Self, ArtifactError> {
        Ok(Self {
            session_id: proto::SessionId(artifact_create.session_id),
            kind: artifact_create.kind.into(),
            title: artifact_create.title,
            space: artifact_create.space.into(),
            anchor: artifact_create.anchor.map(Into::into),
            image: artifact_create
                .image
                .as_deref()
                .map(blob_hash)
                .transpose()?,
            ops: ops_to_proto(artifact_create.ops)?,
        })
    }
}

/// A drawing's elements, or the batches after the version asked for.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ArtifactScene {
    /// The artifact now.
    pub info: ArtifactInfo,
    /// Every element at `info.version` (drawing order) when the client must replace its
    /// state; `nil` when `batches` continue the version asked for.
    pub elements: Option<Vec<DrawElement>>,
    /// Batches after that version, oldest first.
    pub batches: Vec<OpBatch>,
}

impl From<proto::ArtifactScene> for ArtifactScene {
    fn from(artifact_scene: proto::ArtifactScene) -> Self {
        Self {
            info: artifact_scene.info.into(),
            elements: artifact_scene
                .elements
                .map(|elements| elements.into_iter().map(Into::into).collect()),
            batches: artifact_scene.batches.into_iter().map(Into::into).collect(),
        }
    }
}

/// The client's cached copy of a drawing (kept in step with pushes).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CachedScene {
    /// The artifact as last seen.
    pub info: ArtifactInfo,
    /// The version the elements are at.
    pub version: u64,
    /// The elements in drawing order (z, then insertion).
    pub elements: Vec<DrawElement>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExportedFile {
    pub format: ExportFormat,
    /// The version it shows.
    pub version: u64,
    /// PNG bytes, SVG text or ASCII text (UTF-8).
    pub data: Bytes,
}

/// What a send to an agent did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SentToAgent {
    /// The artifact (created for bare images).
    pub artifact_id: u64,
    /// The version pinned.
    pub version: u64,
    /// Absolute path of the PNG on the host.
    pub path: String,
    /// The exact text pasted.
    pub pasted: String,
    /// The pane had bracketed paste on (an agent composer).
    pub bracketed: bool,
}

impl From<proto::Sent> for SentToAgent {
    fn from(sent: proto::Sent) -> Self {
        Self {
            artifact_id: sent.artifact_id.0,
            version: sent.version,
            path: sent.path,
            pasted: sent.pasted,
            bracketed: sent.bracketed,
        }
    }
}

/// One Excalidraw element as the editor holds it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ExElement {
    /// Excalidraw's element id.
    pub id: String,
    /// Excalidraw's `version`.
    pub version: u64,
    /// Excalidraw's `versionNonce` (the lower one wins a version tie).
    pub version_nonce: u32,
    /// `isDeleted` (tombstones).
    pub deleted: bool,
    /// The element as JSON, verbatim.
    pub json: String,
}

impl From<proto::ExElement> for ExElement {
    fn from(element: proto::ExElement) -> Self {
        Self {
            id: element.id,
            version: element.version,
            version_nonce: element.version_nonce,
            deleted: element.deleted,
            json: element.json,
        }
    }
}

impl From<ExElement> for proto::ExElement {
    fn from(element: ExElement) -> Self {
        Self {
            id: element.id,
            version: element.version,
            version_nonce: element.version_nonce,
            deleted: element.deleted,
            json: element.json,
        }
    }
}

/// An image an Excalidraw scene references: Excalidraw's `fileId` and the blob.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ExFile {
    /// Excalidraw's file id.
    pub file_id: String,
    /// The blob (upload it first).
    pub image: ImageRef,
}

impl From<proto::ExFile> for ExFile {
    fn from(file: proto::ExFile) -> Self {
        Self {
            file_id: file.file_id,
            image: file.image.into(),
        }
    }
}

impl TryFrom<ExFile> for proto::ExFile {
    type Error = ArtifactError;

    fn try_from(file: ExFile) -> Result<Self, ArtifactError> {
        Ok(Self {
            file_id: file.file_id,
            image: file.image.try_into()?,
        })
    }
}

/// An Excalidraw scene, or what changed in it after a revision.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ExcalidrawScene {
    /// The artifact; `info.version` is the scene's revision.
    pub info: ArtifactInfo,
    /// Every element (tombstones included) for `since: 0`, else those changed after it.
    pub elements: Vec<ExElement>,
    /// The persistent app state JSON.
    pub app_state: Option<String>,
    /// Every file the scene references.
    pub files: Vec<ExFile>,
}

impl From<proto::ExcalidrawScene> for ExcalidrawScene {
    fn from(excalidraw_scene: proto::ExcalidrawScene) -> Self {
        Self {
            info: excalidraw_scene.info.into(),
            elements: excalidraw_scene
                .elements
                .into_iter()
                .map(Into::into)
                .collect(),
            app_state: excalidraw_scene.app_state,
            files: excalidraw_scene.files.into_iter().map(Into::into).collect(),
        }
    }
}

/// The client's cached copy of an Excalidraw scene.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CachedExcalidraw {
    /// The revision it is at.
    pub revision: u64,
    /// Every element, tombstones included.
    pub elements: Vec<ExElement>,
    /// The persistent app state JSON.
    pub app_state: Option<String>,
    /// Every file the scene references.
    pub files: Vec<ExFile>,
}

impl From<client_core::drawing::ExScene> for CachedExcalidraw {
    fn from(scene: client_core::drawing::ExScene) -> Self {
        Self {
            revision: scene.revision,
            elements: scene.changed_since(0).into_iter().map(Into::into).collect(),
            app_state: scene.app_state.clone(),
            files: scene.files.into_values().map(Into::into).collect(),
        }
    }
}

/// What `excalidraw_put` did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExcalidrawApplied {
    /// The scene's revision now.
    pub version: u64,
    /// Offered elements that lost, as the stored winners: apply them in the editor.
    pub rejected: Vec<ExElement>,
}

/// An artifact shown inline in a terminal pane: a `cols × rows` cell box whose top-left
/// cell is column `col` of the anchored row.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Placement {
    /// Daemon-assigned id, never reused.
    pub placement_id: u64,
    pub pane_id: u64,
    /// What is shown.
    pub artifact_id: u64,
    /// The artifact version shown.
    pub version: u64,
    /// The image drawn (fetch with `blob_download`, cache by hash).
    pub image: ImageRef,
    pub anchor: RowAnchor,
    /// First column.
    pub col: u16,
    /// Width in cells.
    pub cols: u16,
    /// Height in cells.
    pub rows: u16,
    /// Who placed it.
    pub source: PlacementSource,
    pub at_ms: u64,
}

impl From<proto::Placement> for Placement {
    fn from(placement: proto::Placement) -> Self {
        Self {
            placement_id: placement.placement_id,
            pane_id: placement.pane_id.0,
            artifact_id: placement.artifact_id.0,
            version: placement.version,
            image: placement.image.into(),
            anchor: placement.anchor.into(),
            col: placement.col,
            cols: placement.cols,
            rows: placement.rows,
            source: placement.source.into(),
            at_ms: placement.at.0,
        }
    }
}

/// Places an artifact inline in a pane.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlaceRequest {
    pub pane_id: u64,
    pub artifact_id: u64,
    /// The version (`nil` = current).
    #[uniffi(default = None)]
    pub version: Option<u64>,
    /// The row; `nil` = the cursor's row now.
    #[uniffi(default = None)]
    pub anchor: Option<AnchorRequest>,
    /// First column.
    #[uniffi(default = 0)]
    pub col: u16,
    /// Width in cells; `0` derives it from the image.
    #[uniffi(default = 0)]
    pub cols: u16,
    /// Height in cells; `0` derives it from the aspect ratio.
    #[uniffi(default = 0)]
    pub rows: u16,
    /// A placement this one replaces (the overlay was re-opened).
    #[uniffi(default = None)]
    pub replace: Option<u64>,
}

impl From<PlaceRequest> for proto::PlaceRequest {
    fn from(place_request: PlaceRequest) -> Self {
        Self {
            pane_id: proto::PaneId(place_request.pane_id),
            artifact_id: proto::ArtifactId(place_request.artifact_id),
            version: place_request.version,
            anchor: place_request.anchor.map(Into::into),
            col: place_request.col,
            cols: place_request.cols,
            rows: place_request.rows,
            png: None,
            replace: place_request.replace,
        }
    }
}

/// A chunk of a stroke being drawn, as sent (`ink_live`).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InkChunk {
    /// The drawing (or overlay scene).
    pub artifact_id: u64,
    /// The element the stroke becomes when committed.
    pub stroke_id: u64,
    /// Chunk number within the stroke, from 0.
    pub chunk: u32,
    pub tool: InkTool,
    pub style: DrawStyle,
    /// New points only, packed (`pack_ink_points`; deltas restart in every chunk).
    pub points: Bytes,
    /// The pen lifted: the stroke is committed (or cancelled) next.
    pub done: bool,
}

/// Someone else's live stroke chunk (`ArtifactEvent.ink`).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InkLive {
    pub artifact_id: u64,
    /// The element the stroke becomes.
    pub stroke_id: u64,
    /// Who draws.
    pub actor: Actor,
    /// Chunk number within the stroke.
    pub chunk: u32,
    pub tool: InkTool,
    pub style: DrawStyle,
    /// New points, packed.
    pub points: Bytes,
    /// The pen lifted.
    pub done: bool,
}

impl From<proto::InkLive> for InkLive {
    fn from(ink_live: proto::InkLive) -> Self {
        Self {
            artifact_id: ink_live.artifact_id.0,
            stroke_id: ink_live.stroke_id.0,
            actor: ink_live.actor.into(),
            chunk: ink_live.chunk,
            tool: ink_live.tool.into(),
            style: ink_live.style.into(),
            points: ink_live.points.0.into(),
            done: ink_live.done,
        }
    }
}

/// A canvas pane and the drawing it shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct CanvasPane {
    /// The pane (a leaf of the split tree).
    pub pane_id: u64,
    /// The drawing or scene.
    pub artifact_id: u64,
}

impl From<proto::CanvasPane> for CanvasPane {
    fn from(canvas_pane: proto::CanvasPane) -> Self {
        Self {
            pane_id: canvas_pane.pane_id.0,
            artifact_id: canvas_pane.artifact_id.0,
        }
    }
}

/// A push about the attached session's drawings and images.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ArtifactEvent {
    Created {
        info: ArtifactInfo,
    },
    /// A batch was committed (the cache already applied it).
    Changed {
        /// The artifact after the batch.
        info: ArtifactInfo,
        batch: OpBatch,
    },
    /// Metadata changed without a batch (anchor moved or detached, preview, canvas panes).
    Info {
        /// The artifact now.
        info: ArtifactInfo,
    },
    Deleted {
        session_id: u64,
        artifact_id: u64,
    },
    /// Someone else's live stroke.
    Ink {
        ink: InkLive,
    },
    /// The session's canvas panes (whole list).
    Canvases {
        session_id: u64,
        /// Every canvas pane in it.
        canvases: Vec<CanvasPane>,
    },
    /// Excalidraw elements someone else changed: `applyRemote` them.
    Excalidraw {
        artifact_id: u64,
        /// Its revision after the change.
        version: u64,
        /// The changed elements that won.
        elements: Vec<ExElement>,
        /// New app state, if it changed.
        app_state: Option<String>,
        /// Newly referenced images.
        files: Vec<ExFile>,
    },
    /// An inline placement was made, replaced or changed (its anchor detached).
    Placed {
        placement: Placement,
    },
    /// An inline placement was removed.
    Unplaced {
        pane_id: u64,
        placement_id: u64,
    },
    /// The cached scene of an artifact was (re)fetched (a gap, a reconnect, a first sight)
    /// and is now at `version`; redraw it from `artifact_scene` / `excalidraw_scene`.
    Synced {
        artifact_id: u64,
        /// Its version now.
        version: u64,
    },
}

impl From<client_core::ArtifactUpdate> for ArtifactEvent {
    fn from(artifact_update: client_core::ArtifactUpdate) -> Self {
        use proto::ArtifactEvent as E;
        let event = match artifact_update {
            client_core::ArtifactUpdate::Synced {
                artifact_id,
                version,
            } => {
                return Self::Synced {
                    artifact_id: artifact_id.0,
                    version,
                };
            }
            client_core::ArtifactUpdate::Event(event) => *event,
        };
        match event {
            E::Created(info) => Self::Created { info: info.into() },
            E::Changed { info, batch } => Self::Changed {
                info: info.into(),
                batch: batch.into(),
            },
            E::Info(info) => Self::Info { info: info.into() },
            E::Deleted {
                session_id,
                artifact_id,
            } => Self::Deleted {
                session_id: session_id.0,
                artifact_id: artifact_id.0,
            },
            E::Ink(ink) => Self::Ink { ink: ink.into() },
            E::Canvases {
                session_id,
                canvases,
            } => Self::Canvases {
                session_id: session_id.0,
                canvases: canvases.into_iter().map(Into::into).collect(),
            },
            E::Excalidraw {
                artifact_id,
                version,
                elements,
                app_state,
                files,
            } => Self::Excalidraw {
                artifact_id: artifact_id.0,
                version,
                elements: elements.into_iter().map(Into::into).collect(),
                app_state,
                files: files.into_iter().map(Into::into).collect(),
            },
            E::Placed(placement) => Self::Placed {
                placement: placement.into(),
            },
            E::Unplaced {
                pane_id,
                placement_id,
            } => Self::Unplaced {
                pane_id: pane_id.0,
                placement_id,
            },
        }
    }
}

/// One sampled pen position (for `pack_ink_points` / `simplify_ink_points`).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct InkPoint {
    /// x, in the drawing's units.
    pub x: f32,
    pub y: f32,
    /// Force, 0…1 (1 for a mouse or finger).
    #[uniffi(default = 1.0)]
    pub pressure: f32,
    /// Pen altitude in radians, 0 (flat) … π/2 (upright).
    #[uniffi(default = 1.5707964)]
    pub altitude: f32,
    /// Pen azimuth in radians, 0…2π.
    #[uniffi(default = 0.0)]
    pub azimuth: f32,
    /// Milliseconds since the stroke started.
    pub t_ms: u32,
}

impl From<client_core::drawing::InkPoint> for InkPoint {
    fn from(ink_point: client_core::drawing::InkPoint) -> Self {
        Self {
            x: ink_point.x,
            y: ink_point.y,
            pressure: ink_point.pressure,
            altitude: ink_point.altitude,
            azimuth: ink_point.azimuth,
            t_ms: ink_point.t_ms,
        }
    }
}

impl From<InkPoint> for client_core::drawing::InkPoint {
    fn from(ink_point: InkPoint) -> Self {
        Self {
            x: ink_point.x,
            y: ink_point.y,
            pressure: ink_point.pressure,
            altitude: ink_point.altitude,
            azimuth: ink_point.azimuth,
            t_ms: ink_point.t_ms,
        }
    }
}

/// Format and pixel size read from an image's header.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ImageInfo {
    /// PNG or JPEG.
    pub media: MediaType,
    pub width: u32,
    pub height: u32,
}
