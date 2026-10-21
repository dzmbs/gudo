//!
//! Same rules as [`crate::types`]: ids are `u64`, times are Unix milliseconds (`*_ms`),
//! payloads (packed ink points, PNGs, SVG text) are [`Bytes`]. Blob hashes are 64 lowercase
//! hex digits.

use client_core::proto;

use crate::bytes::Bytes;
use crate::mp::Actor;

// --- errors ---------------------------------------------------------------------------------

/// Why a drawing or image request failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum ArtifactError {
    /// No such artifact, session, pane, blob or version (or outside the grant's scope).
    #[error("not found: {message}")]
    NotFound {
        /// What.
        message: String,
    },
    /// The grant's roles do not allow it; the text names the role needed.
    #[error("not allowed: {message}")]
    Forbidden {
        /// Why.
        message: String,
    },
    /// Over a size cap; the text names it.
    #[error("too large: {message}")]
    TooLarge {
        /// Which cap.
        message: String,
    },
    /// Malformed (not a PNG, bad points, wrong kind, a bad hash).
    #[error("invalid: {message}")]
    Invalid {
        /// Why.
        message: String,
    },
    /// "Send to agent" into a pane that runs no agent.
    #[error("the pane runs no agent")]
    NotAgentPane,
    /// Anything else.
    #[error("{message}")]
    Failed {
        /// Why.
        message: String,
    },
    /// The connection dropped before the daemon answered.
    #[error("disconnected before the daemon answered")]
    Disconnected,
}

impl From<proto::ArtifactError> for ArtifactError {
    fn from(e: proto::ArtifactError) -> Self {
        use proto::ArtifactError as E;
        match e {
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

// --- small enums ----------------------------------------------------------------------------

macro_rules! mirror_enum {
    ($(#[$doc:meta])* $name:ident = $p:ident { $($(#[$vdoc:meta])* $v:ident),* $(,)? }) => {
        $(#[$doc])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
        pub enum $name {
            $($(#[$vdoc])* $v,)*
        }

        impl From<proto::$p> for $name {
            fn from(v: proto::$p) -> Self {
                match v {
                    $(proto::$p::$v => Self::$v,)*
                }
            }
        }

        impl From<$name> for proto::$p {
            fn from(v: $name) -> Self {
                match v {
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
        /// One image.
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
        /// PNG.
        Png,
        /// JPEG.
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
        /// Straight line.
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
        /// A program in the pane printed it with the kitty graphics protocol.
        Kitty,
    }
}

// --- records --------------------------------------------------------------------------------

/// A stored image blob.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ImageRef {
    /// SHA-256, 64 lowercase hex digits.
    pub hash: String,
    /// Encoding.
    pub media: MediaType,
    /// Size in bytes.
    pub size: u64,
    /// Pixel width.
    pub width: u32,
    /// Pixel height.
    pub height: u32,
}

impl From<proto::ImageRef> for ImageRef {
    fn from(i: proto::ImageRef) -> Self {
        Self {
            hash: i.hash.to_hex(),
            media: i.media.into(),
            size: i.size,
            width: i.width,
            height: i.height,
        }
    }
}

impl TryFrom<ImageRef> for proto::ImageRef {
    type Error = ArtifactError;

    fn try_from(i: ImageRef) -> Result<Self, ArtifactError> {
        Ok(Self {
            hash: blob_hash(&i.hash)?,
            media: i.media.into(),
            size: i.size,
            width: i.width,
            height: i.height,
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
    fn from(s: proto::Style) -> Self {
        Self {
            color: s.color,
            width: s.width,
        }
    }
}

impl From<DrawStyle> for proto::Style {
    fn from(s: DrawStyle) -> Self {
        Self {
            color: s.color,
            width: s.width,
        }
    }
}

/// A point in the drawing's units.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Pt {
    /// x.
    pub x: f32,
    /// y.
    pub y: f32,
}

impl From<proto::Pt> for Pt {
    fn from(p: proto::Pt) -> Self {
        Self { x: p.x, y: p.y }
    }
}

impl From<Pt> for proto::Pt {
    fn from(p: Pt) -> Self {
        Self { x: p.x, y: p.y }
    }
}

/// What an element is.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum DrawElementKind {
    /// Freehand ink; `points` are packed (`pack_ink_points`).
    Stroke {
        /// The pen.
        tool: InkTool,
        /// Packed points.
        points: Bytes,
    },
    /// A shape from `from` to `to`.
    Shape {
        /// The shape.
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
        /// Position.
        at: Pt,
        /// The text.
        text: String,
        /// Font size in the drawing's units.
        size: f32,
    },
    /// An image blob placed in `from`..`to`.
    Image {
        /// The image.
        image: ImageRef,
        /// Top-left.
        from: Pt,
        /// Bottom-right.
        to: Pt,
    },
}

impl From<proto::ElementKind> for DrawElementKind {
    fn from(k: proto::ElementKind) -> Self {
        use proto::ElementKind as K;
        match k {
            K::Stroke(s) => Self::Stroke {
                tool: s.tool.into(),
                points: s.points.0.into(),
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

    fn try_from(k: DrawElementKind) -> Result<Self, ArtifactError> {
        Ok(match k {
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
    /// What it is.
    pub kind: DrawElementKind,
}

impl From<proto::Element> for DrawElement {
    fn from(e: proto::Element) -> Self {
        Self {
            id: e.id.0,
            z: e.z,
            style: e.style.into(),
            kind: e.kind.into(),
        }
    }
}

impl TryFrom<DrawElement> for proto::Element {
    type Error = ArtifactError;

    fn try_from(e: DrawElement) -> Result<Self, ArtifactError> {
        Ok(Self {
            id: proto::ElementId(e.id),
            z: e.z,
            style: e.style.into(),
            kind: e.kind.try_into()?,
        })
    }
}

/// A change to a drawing. Elements are add-wins, fields last-writer-wins.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum DrawOp {
    /// Adds an element (replacing one with the same id).
    Add {
        /// The element.
        element: DrawElement,
    },
    /// Moves an element by `(dx, dy)`.
    Move {
        /// The element.
        id: u64,
        /// Offset x.
        dx: f32,
        /// Offset y.
        dy: f32,
    },
    /// Changes an element's style.
    Restyle {
        /// The element.
        id: u64,
        /// New style.
        style: DrawStyle,
    },
    /// Changes an element's stacking order.
    SetZ {
        /// The element.
        id: u64,
        /// New z.
        z: i32,
    },
    /// Removes an element.
    Delete {
        /// The element.
        id: u64,
    },
    /// Removes every element.
    Clear,
    /// Renames the artifact.
    SetTitle {
        /// The title.
        title: String,
    },
}

impl From<proto::DrawOp> for DrawOp {
    fn from(op: proto::DrawOp) -> Self {
        use proto::DrawOp as O;
        match op {
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

    fn try_from(op: DrawOp) -> Result<Self, ArtifactError> {
        use proto::ElementId as Id;
        Ok(match op {
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
    /// The ops.
    pub ops: Vec<DrawOp>,
}

impl From<proto::OpBatch> for OpBatch {
    fn from(b: proto::OpBatch) -> Self {
        Self {
            version: b.version,
            actor: b.actor.into(),
            at_ms: b.at.0,
            ops: b.ops.into_iter().map(Into::into).collect(),
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
    fn from(a: AnchorRequest) -> Self {
        Self {
            pane_id: proto::PaneId(a.pane_id),
            at_seq: proto::Seq(a.at_seq),
            from_bottom: a.from_bottom,
        }
    }
}

/// Whether an anchor still has its row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AnchorState {
    /// Glued to its row.
    Live,
    /// Lost its row; the drawing moved to the pane's loose tray.
    Detached {
        /// Why.
        reason: DetachReason,
    },
}

impl From<proto::AnchorState> for AnchorState {
    fn from(s: proto::AnchorState) -> Self {
        match s {
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
    /// The pane.
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
    fn from(a: proto::RowAnchor) -> Self {
        Self {
            pane_id: a.pane_id.0,
            screen: a.screen.into(),
            at_seq: a.at_seq.0,
            from_bottom: a.from_bottom,
            command_id: a.command_id,
            state: a.state.into(),
        }
    }
}

/// A rendered PNG of a drawing at one version.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct ArtifactPreview {
    /// The PNG.
    pub image: ImageRef,
    /// The drawing version it shows.
    pub version: u64,
}

impl From<proto::Preview> for ArtifactPreview {
    fn from(p: proto::Preview) -> Self {
        Self {
            image: p.image.into(),
            version: p.version,
        }
    }
}

/// Everything a client lists about an artifact.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ArtifactInfo {
    /// The artifact.
    pub artifact_id: u64,
    /// Its session.
    pub session_id: u64,
    /// Drawing, image or Excalidraw scene.
    pub kind: ArtifactKind,
    /// Title (may be empty).
    pub title: String,
    /// DrawElement coordinates.
    pub space: CoordSpace,
    /// Who created it.
    pub created_by: Actor,
    /// When.
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
    fn from(v: proto::ArtifactVersion) -> Self {
        Self {
            version: v.version,
            at_ms: v.at.0,
            by: v.by.into(),
            image: v.image.map(Into::into),
            elements: v.elements,
            restored_from: v.restored_from,
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
    fn from(i: proto::ArtifactInfo) -> Self {
        Self {
            artifact_id: i.artifact_id.0,
            session_id: i.session_id.0,
            kind: i.kind.into(),
            title: i.title,
            space: i.space.into(),
            created_by: i.created_by.into(),
            created_at_ms: i.created_at.0,
            updated_at_ms: i.updated_at.0,
            version: i.version,
            elements: i.elements,
            image: i.image.map(Into::into),
            preview: i.preview.map(Into::into),
            anchor: i.anchor.map(Into::into),
            canvas_panes: i.canvas_panes.into_iter().map(|p| p.0).collect(),
        }
    }
}

/// Creates an artifact.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ArtifactCreate {
    /// The session it belongs to.
    pub session_id: u64,
    /// Drawing, image or Excalidraw scene.
    pub kind: ArtifactKind,
    /// Title.
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

    fn try_from(c: ArtifactCreate) -> Result<Self, ArtifactError> {
        Ok(Self {
            session_id: proto::SessionId(c.session_id),
            kind: c.kind.into(),
            title: c.title,
            space: c.space.into(),
            anchor: c.anchor.map(Into::into),
            image: c.image.as_deref().map(blob_hash).transpose()?,
            ops: ops_to_proto(c.ops)?,
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
    fn from(s: proto::ArtifactScene) -> Self {
        Self {
            info: s.info.into(),
            elements: s.elements.map(|e| e.into_iter().map(Into::into).collect()),
            batches: s.batches.into_iter().map(Into::into).collect(),
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

/// Exported content.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExportedFile {
    /// Format.
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
    fn from(s: proto::Sent) -> Self {
        Self {
            artifact_id: s.artifact_id.0,
            version: s.version,
            path: s.path,
            pasted: s.pasted,
            bracketed: s.bracketed,
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
    fn from(e: proto::ExElement) -> Self {
        Self {
            id: e.id,
            version: e.version,
            version_nonce: e.version_nonce,
            deleted: e.deleted,
            json: e.json,
        }
    }
}

impl From<ExElement> for proto::ExElement {
    fn from(e: ExElement) -> Self {
        Self {
            id: e.id,
            version: e.version,
            version_nonce: e.version_nonce,
            deleted: e.deleted,
            json: e.json,
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
    fn from(f: proto::ExFile) -> Self {
        Self {
            file_id: f.file_id,
            image: f.image.into(),
        }
    }
}

impl TryFrom<ExFile> for proto::ExFile {
    type Error = ArtifactError;

    fn try_from(f: ExFile) -> Result<Self, ArtifactError> {
        Ok(Self {
            file_id: f.file_id,
            image: f.image.try_into()?,
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
    fn from(s: proto::ExcalidrawScene) -> Self {
        Self {
            info: s.info.into(),
            elements: s.elements.into_iter().map(Into::into).collect(),
            app_state: s.app_state,
            files: s.files.into_iter().map(Into::into).collect(),
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
    fn from(s: client_core::drawing::ExScene) -> Self {
        Self {
            revision: s.revision,
            elements: s.changed_since(0).into_iter().map(Into::into).collect(),
            app_state: s.app_state.clone(),
            files: s.files.into_values().map(Into::into).collect(),
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
    /// The pane.
    pub pane_id: u64,
    /// What is shown.
    pub artifact_id: u64,
    /// The artifact version shown.
    pub version: u64,
    /// The image drawn (fetch with `blob_download`, cache by hash).
    pub image: ImageRef,
    /// The row.
    pub anchor: RowAnchor,
    /// First column.
    pub col: u16,
    /// Width in cells.
    pub cols: u16,
    /// Height in cells.
    pub rows: u16,
    /// Who placed it.
    pub source: PlacementSource,
    /// When.
    pub at_ms: u64,
}

impl From<proto::Placement> for Placement {
    fn from(p: proto::Placement) -> Self {
        Self {
            placement_id: p.placement_id,
            pane_id: p.pane_id.0,
            artifact_id: p.artifact_id.0,
            version: p.version,
            image: p.image.into(),
            anchor: p.anchor.into(),
            col: p.col,
            cols: p.cols,
            rows: p.rows,
            source: p.source.into(),
            at_ms: p.at.0,
        }
    }
}

/// Places an artifact inline in a pane.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlaceRequest {
    /// The pane.
    pub pane_id: u64,
    /// The artifact.
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
    fn from(r: PlaceRequest) -> Self {
        Self {
            pane_id: proto::PaneId(r.pane_id),
            artifact_id: proto::ArtifactId(r.artifact_id),
            version: r.version,
            anchor: r.anchor.map(Into::into),
            col: r.col,
            cols: r.cols,
            rows: r.rows,
            png: None,
            replace: r.replace,
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
    /// The pen.
    pub tool: InkTool,
    /// DrawStyle.
    pub style: DrawStyle,
    /// New points only, packed (`pack_ink_points`; deltas restart in every chunk).
    pub points: Bytes,
    /// The pen lifted: the stroke is committed (or cancelled) next.
    pub done: bool,
}

/// Someone else's live stroke chunk (`ArtifactEvent.ink`).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InkLive {
    /// The drawing.
    pub artifact_id: u64,
    /// The element the stroke becomes.
    pub stroke_id: u64,
    /// Who draws.
    pub actor: Actor,
    /// Chunk number within the stroke.
    pub chunk: u32,
    /// The pen.
    pub tool: InkTool,
    /// DrawStyle.
    pub style: DrawStyle,
    /// New points, packed.
    pub points: Bytes,
    /// The pen lifted.
    pub done: bool,
}

impl From<proto::InkLive> for InkLive {
    fn from(i: proto::InkLive) -> Self {
        Self {
            artifact_id: i.artifact_id.0,
            stroke_id: i.stroke_id.0,
            actor: i.actor.into(),
            chunk: i.chunk,
            tool: i.tool.into(),
            style: i.style.into(),
            points: i.points.0.into(),
            done: i.done,
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
    fn from(c: proto::CanvasPane) -> Self {
        Self {
            pane_id: c.pane_id.0,
            artifact_id: c.artifact_id.0,
        }
    }
}

/// A push about the attached session's drawings and images.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ArtifactEvent {
    /// A new artifact.
    Created {
        /// It.
        info: ArtifactInfo,
    },
    /// A batch was committed (the cache already applied it).
    Changed {
        /// The artifact after the batch.
        info: ArtifactInfo,
        /// The batch.
        batch: OpBatch,
    },
    /// Metadata changed without a batch (anchor moved or detached, preview, canvas panes).
    Info {
        /// The artifact now.
        info: ArtifactInfo,
    },
    /// Deleted.
    Deleted {
        /// Its session.
        session_id: u64,
        /// The artifact.
        artifact_id: u64,
    },
    /// Someone else's live stroke.
    Ink {
        /// The chunk.
        ink: InkLive,
    },
    /// The session's canvas panes (whole list).
    Canvases {
        /// The session.
        session_id: u64,
        /// Every canvas pane in it.
        canvases: Vec<CanvasPane>,
    },
    /// Excalidraw elements someone else changed: `applyRemote` them.
    Excalidraw {
        /// The scene.
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
        /// It.
        placement: Placement,
    },
    /// An inline placement was removed.
    Unplaced {
        /// The pane.
        pane_id: u64,
        /// The placement.
        placement_id: u64,
    },
    /// The cached scene of an artifact was (re)fetched (a gap, a reconnect, a first sight)
    /// and is now at `version`; redraw it from `artifact_scene` / `excalidraw_scene`.
    Synced {
        /// The artifact.
        artifact_id: u64,
        /// Its version now.
        version: u64,
    },
}

impl From<client_core::ArtifactUpdate> for ArtifactEvent {
    fn from(u: client_core::ArtifactUpdate) -> Self {
        use proto::ArtifactEvent as E;
        let event = match u {
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
            E::Placed(p) => Self::Placed {
                placement: p.into(),
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

// --- on-device drawing helpers -------------------------------------------------------------

/// One sampled pen position (for `pack_ink_points` / `simplify_ink_points`).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct InkPoint {
    /// x, in the drawing's units.
    pub x: f32,
    /// y.
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
    fn from(p: client_core::drawing::InkPoint) -> Self {
        Self {
            x: p.x,
            y: p.y,
            pressure: p.pressure,
            altitude: p.altitude,
            azimuth: p.azimuth,
            t_ms: p.t_ms,
        }
    }
}

impl From<InkPoint> for client_core::drawing::InkPoint {
    fn from(p: InkPoint) -> Self {
        Self {
            x: p.x,
            y: p.y,
            pressure: p.pressure,
            altitude: p.altitude,
            azimuth: p.azimuth,
            t_ms: p.t_ms,
        }
    }
}

/// Format and pixel size read from an image's header.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ImageInfo {
    /// PNG or JPEG.
    pub media: MediaType,
    /// Pixel width.
    pub width: u32,
    /// Pixel height.
    pub height: u32,
}
