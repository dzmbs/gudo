//!
//! An artifact belongs to a session. A **drawing** is an ordered op log ([`DrawOp`] batches,
//! one [`OpBatch`] per committed change, numbered by `version`) that materialises into
//! [`Element`]s; an **image** is one content-addressed blob ([`BlobHash`], SHA-256). The
//! daemon orders every batch, so clients that apply batches in version order converge.
//!
//! - Requests: [`ClientCtl::Artifact`](crate::ClientCtl::Artifact) → [`ServerCtl::ArtifactResult`](crate::ServerCtl::ArtifactResult)
//!   (same `req_id`) holding `Result<`[`ArtifactResponse`]`, `[`ArtifactError`]`>`.
//! - Pushes to clients attached to the session: [`ServerCtl::Artifact`](crate::ServerCtl::Artifact)
//!   with an [`ArtifactEvent`] (created, changed with the batch, deleted, live ink, canvases).
//! - Live ink: [`ClientCtl::InkLive`](crate::ClientCtl::InkLive), never on `input`; the daemon
//!   stamps the actor and fans it out to the session's other clients.
//! - Blobs (images, rendered PNGs) move on their own bidirectional streams
//!   ([`StreamHeader::Blob`](crate::StreamHeader::Blob)) at bulk priority, so QUIC flow
//!   control is the backpressure.
//! - A canvas pane is an ordinary [`LayoutNode::Leaf`](crate::LayoutNode::Leaf) created with
//!   [`PaneLaunch::Canvas`](crate::PaneLaunch::Canvas); which leaves are canvases arrives as
//!   [`ArtifactEvent::Canvases`]. Old clients see an empty pane instead of failing to decode the
//!   layout (a new `LayoutNode` variant would make the whole `LayoutChanged` undecodable).
//!
//! Coordinates are canvas units ([`CoordSpace::Canvas`], points) or, for ink over a terminal,
//! cells ([`CoordSpace::Cells`]: `x` in columns, `y` in rows below the anchor row, both
//! fractional), so ink stays on its text across fonts and devices.
//!
//! Same compatibility rules as the rest of the crate: append only.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::ids::{Actor, PaneId, Seq, SessionId, UnixMillis};

/// An artifact on one daemon. Never reused, stable across daemon restarts.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default, Serialize, Deserialize,
)]
pub struct ArtifactId(pub u64);

impl fmt::Display for ArtifactId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self.0, f)
    }
}

/// An element of a drawing, chosen by the client that adds it (random 64 bits, so two devices
/// never collide in practice). The daemon refuses nothing on reuse: adding an existing id
/// replaces the element (an idempotent retry).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct ElementId(pub u64);

/// SHA-256 of a blob's bytes.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct BlobHash(pub [u8; 32]);

impl BlobHash {
    /// Lowercase hex.
    pub fn to_hex(&self) -> String {
        data_encoding::HEXLOWER.encode(&self.0)
    }

    /// Parses 64 hex digits.
    pub fn from_hex(s: &str) -> Option<Self> {
        let bytes = data_encoding::HEXLOWER_PERMISSIVE
            .decode(s.as_bytes())
            .ok()?;
        Some(Self(bytes.try_into().ok()?))
    }
}

impl fmt::Debug for BlobHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "BlobHash({}…)", &self.to_hex()[..12])
    }
}

impl fmt::Display for BlobHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_hex())
    }
}

/// What an artifact holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ArtifactKind {
    /// Vector strokes, shapes, text and placed images.
    Drawing,
    /// One image (pasted, dropped, a screenshot or photo).
    Image,
    /// An Excalidraw scene (the canvas editor for finger, mouse and trackpad): elements kept
    /// as Excalidraw's own JSON, reconciled per element ([`ExElement`]).
    Excalidraw,
}

/// The coordinate space of a drawing's elements.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CoordSpace {
    /// Canvas units (points), origin top left.
    Canvas,
    /// Terminal cells: `x` in columns, `y` in rows counted from the anchor row (fractional).
    Cells,
}

/// Image encodings the daemon stores.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MediaType {
    /// PNG.
    Png,
    /// JPEG.
    Jpeg,
}

impl MediaType {
    /// File extension without the dot.
    pub fn extension(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpg",
        }
    }

    /// MIME type.
    pub fn mime(self) -> &'static str {
        match self {
            Self::Png => "image/png",
            Self::Jpeg => "image/jpeg",
        }
    }
}

/// A stored image blob.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ImageRef {
    /// Content hash.
    pub hash: BlobHash,
    /// Encoding.
    pub media: MediaType,
    /// Size in bytes.
    pub size: u64,
    /// Pixel width (from the image header).
    pub width: u32,
    /// Pixel height.
    pub height: u32,
}

// ---------------------------------------------------------------------------------------------
// Elements and ops
// ---------------------------------------------------------------------------------------------

/// Stroke points, packed (see the `drawing` crate): version byte `1`, then per point the
/// zig-zag varint deltas of `x` and `y` in 1/32 units, pressure, altitude and azimuth as one
/// byte each, and the varint milliseconds since the previous point. About 6 bytes a point.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub struct PackedPoints(#[serde(with = "crate::serde_bytes")] pub Vec<u8>);

/// The pen a stroke was drawn with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Tool {
    /// Opaque, pressure-sensitive.
    Pen,
    /// Translucent, wide, drawn under pens.
    Highlighter,
    /// Opaque, constant width.
    Marker,
}

/// Colour and line width of an element.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Style {
    /// `0xRRGGBBAA`.
    pub color: u32,
    /// Nominal line width in the drawing's units (scaled by pressure for pens).
    pub width: f32,
}

/// A freehand stroke.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Stroke {
    /// The pen.
    pub tool: Tool,
    /// The points.
    pub points: PackedPoints,
}

/// Geometric shapes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ShapeKind {
    /// Axis-aligned rectangle between the two corners.
    Rect,
    /// Ellipse inscribed in that rectangle.
    Ellipse,
    /// Straight line.
    Line,
    /// Line with an arrow head at `to`.
    Arrow,
}

/// A point in the drawing's units.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Pt {
    /// x.
    pub x: f32,
    /// y.
    pub y: f32,
}

/// What an element is.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ElementKind {
    /// Freehand ink.
    Stroke(Stroke),
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
        /// The text (newlines allowed).
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

/// One element of a drawing. Higher `z` draws on top; ties keep insertion order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Element {
    /// Its id.
    pub id: ElementId,
    /// Stacking order.
    pub z: i32,
    /// Colour and width.
    pub style: Style,
    /// What it is.
    pub kind: ElementKind,
}

/// A change to a drawing. Elements are add-wins, fields last-writer-wins, in the daemon's
/// order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum DrawOp {
    /// Adds an element (replacing one with the same id).
    Add(Element),
    /// Moves an element by `(dx, dy)`.
    Move {
        /// The element.
        id: ElementId,
        /// Offset x.
        dx: f32,
        /// Offset y.
        dy: f32,
    },
    /// Changes an element's style.
    Restyle {
        /// The element.
        id: ElementId,
        /// New style.
        style: Style,
    },
    /// Changes an element's stacking order.
    SetZ {
        /// The element.
        id: ElementId,
        /// New z.
        z: i32,
    },
    /// Removes an element (no-op if absent).
    Delete {
        /// The element.
        id: ElementId,
    },
    /// Removes every element.
    Clear,
    /// Renames the artifact.
    SetTitle(String),
}

/// One committed change: the ops of one request, in order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpBatch {
    /// The version this batch produces (the first batch makes version 1).
    pub version: u64,
    /// Who committed it.
    pub actor: Actor,
    /// When the daemon accepted it.
    pub at: UnixMillis,
    /// The ops.
    pub ops: Vec<DrawOp>,
}

// ---------------------------------------------------------------------------------------------
// Anchors
// ---------------------------------------------------------------------------------------------

/// Where on a terminal's output an anchor is asked for: the row `from_bottom` rows above the
/// bottom row of the pane's screen (scrollback included) as the client saw it after applying
/// output up to `at_seq`. The daemon accounts for rows that scrolled since `at_seq`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct AnchorRequest {
    /// The terminal pane.
    pub pane_id: PaneId,
    /// Output offset the client's screen reflected.
    pub at_seq: Seq,
    /// Rows above the bottom row (0 = the bottom row of the active area).
    pub from_bottom: u64,
}

/// Which screen an anchor's row is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum AnchorScreen {
    /// The normal screen with scrollback.
    Primary,
    /// The alternate screen of a full-screen program; dropped when the program leaves it.
    Alternate,
}

/// Why an anchor lost its row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DetachReason {
    /// The row was evicted from scrollback or erased (`clear`, `ED 3`).
    RowGone,
    /// The full-screen program left the alternate screen.
    AltScreenExited,
    /// The pane closed.
    PaneClosed,
    /// The daemon restarted (terminal state does not survive a restart).
    DaemonRestart,
}

/// Whether an anchor still has its row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum AnchorState {
    /// Glued to its row.
    Live,
    /// Lost its row; the drawing moved to the pane's loose tray.
    Detached(DetachReason),
}

/// reference on the daemon's terminal, mirrored by each client's own VT).
///
/// The row is given as `from_bottom` at `at_seq`, the same convention as search results: a
/// client whose VT has applied output up to `at_seq` finds the row `from_bottom` rows above
/// its bottom row and tracks it itself from then on (same library, same bytes, same reflow).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RowAnchor {
    /// The pane.
    pub pane_id: PaneId,
    /// Which screen.
    pub screen: AnchorScreen,
    /// Output offset the position refers to.
    pub at_seq: Seq,
    /// Rows above the bottom row at `at_seq`; meaningless once detached.
    pub from_bottom: u64,
    /// The shell-integration command (OSC 133) whose block holds the row, if any.
    pub command_id: Option<u64>,
    /// Live or detached.
    pub state: AnchorState,
}

// ---------------------------------------------------------------------------------------------
// Artifacts, requests and pushes
// ---------------------------------------------------------------------------------------------

/// Everything a client lists about an artifact.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ArtifactInfo {
    /// The artifact.
    pub artifact_id: ArtifactId,
    /// Its session.
    pub session_id: SessionId,
    /// Drawing or image.
    pub kind: ArtifactKind,
    /// Title (may be empty).
    pub title: String,
    /// Element coordinates.
    pub space: CoordSpace,
    /// Who created it.
    pub created_by: Actor,
    /// When.
    pub created_at: UnixMillis,
    /// Last change.
    pub updated_at: UnixMillis,
    /// Number of committed batches (0 for a new drawing and for images).
    pub version: u64,
    /// Elements now.
    pub elements: u32,
    /// For images: the image.
    pub image: Option<ImageRef>,
    /// The last PNG a client rendered (or the daemon made) and the version it shows.
    pub preview: Option<Preview>,
    /// For ink overlays: the anchor.
    pub anchor: Option<RowAnchor>,
    /// Canvas panes showing it.
    pub canvas_panes: Vec<PaneId>,
}

/// A rendered PNG of a drawing at one version.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Preview {
    /// The PNG.
    pub image: ImageRef,
    /// The drawing version it shows.
    pub version: u64,
}

/// Creates an artifact.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ArtifactCreate {
    /// The session it belongs to.
    pub session_id: SessionId,
    /// Drawing or image.
    pub kind: ArtifactKind,
    /// Title.
    pub title: String,
    /// Coordinate space (`Cells` for ink over a terminal).
    pub space: CoordSpace,
    /// Anchor to a terminal row (ink overlays).
    pub anchor: Option<AnchorRequest>,
    /// For images: an uploaded blob ([`StreamHeader::Blob`](crate::StreamHeader::Blob)).
    pub image: Option<BlobHash>,
    /// Initial ops, committed as version 1 if not empty.
    pub ops: Vec<DrawOp>,
}

/// Export formats.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ExportFormat {
    /// The image blob, or the drawing's preview at the asked version (passthrough).
    Png,
    /// SVG written by the daemon from the vector elements.
    Svg,
    /// Text: box-drawing glyphs for shapes and arrows (termdraw style), text as is, ink as
    /// dots. For terminals without graphics and for agents that read text.
    Ascii,
}

/// The PNG a send uses.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum PngSource {
    /// The PNG itself (small sketches; at most 1 MiB).
    Inline(#[serde(with = "crate::serde_bytes")] Vec<u8>),
    /// A blob uploaded before.
    Blob(BlobHash),
    /// The artifact's own PNG: its image, else its preview at the version, else the daemon
    /// rasterises the drawing.
    Artifact,
}

/// "Send to agent": write the PNG to a file on the host and bracketed-paste its absolute path
/// into an agent pane (never Enter), so Claude Code and Codex attach it as `[Image #N]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtifactSend {
    /// The agent pane.
    pub pane_id: PaneId,
    /// The artifact sent; `None` sends a bare image (it is kept as an image artifact).
    pub artifact_id: Option<ArtifactId>,
    /// The drawing version the PNG shows (pinned in the file name); `None` = current.
    pub version: Option<u64>,
    /// The PNG.
    pub png: PngSource,
}

/// An artifact request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ArtifactRequest {
    /// The session's artifacts → [`ArtifactResponse::List`].
    List {
        /// The session.
        session_id: SessionId,
    },
    /// → [`ArtifactResponse::Created`].
    Create(ArtifactCreate),
    /// A drawing's elements → [`ArtifactResponse::Scene`]: the batches after `since` when
    /// the client holds version `since`, else every element at the current version.
    Get {
        /// The artifact.
        artifact_id: ArtifactId,
        /// Version the client already has (0 = none).
        since: u64,
    },
    /// Commits ops as one batch → [`ArtifactResponse::Applied`]. `base` is the version the
    /// client drew on (informational; ops apply last-writer-wins on top of the current one).
    Apply {
        /// The drawing.
        artifact_id: ArtifactId,
        /// Version the client saw.
        base: u64,
        /// The ops.
        ops: Vec<DrawOp>,
    },
    /// → [`ArtifactResponse::Done`].
    Delete {
        /// The artifact.
        artifact_id: ArtifactId,
    },
    /// Anchors a drawing to a terminal row, or unanchors it → [`ArtifactResponse::Info`].
    SetAnchor {
        /// The drawing.
        artifact_id: ArtifactId,
        /// The row, or `None`.
        anchor: Option<AnchorRequest>,
    },
    /// Records a client-rendered PNG of a drawing version (an uploaded blob) →
    /// [`ArtifactResponse::Info`].
    SetPreview {
        /// The drawing.
        artifact_id: ArtifactId,
        /// The version it shows.
        version: u64,
        /// The PNG blob.
        png: BlobHash,
    },
    /// → [`ArtifactResponse::Exported`].
    Export {
        /// The artifact.
        artifact_id: ArtifactId,
        /// Version (`None` = current).
        version: Option<u64>,
        /// Format.
        format: ExportFormat,
    },
    /// → [`ArtifactResponse::Sent`].
    Send(ArtifactSend),
    /// An Excalidraw scene's elements changed after `since` (0 = all) →
    /// [`ArtifactResponse::Excalidraw`].
    ExcalidrawGet {
        /// The scene.
        artifact_id: ArtifactId,
        /// Revision the client has (0 = none).
        since: u64,
    },
    /// Offers changed Excalidraw elements → [`ArtifactResponse::ExcalidrawApplied`]. Each
    /// element is kept if its `version` is higher than the stored one, or equal with a lower
    /// `version_nonce` (Excalidraw's own reconciliation); the others come back as the stored
    /// winners.
    ExcalidrawPut(ExcalidrawPut),
    /// Shows an artifact inline in a terminal pane, glued to an output row →
    /// [`ArtifactResponse::Placed`]. Replaces `replace` (re-opened and edited in place).
    Place(PlaceRequest),
    /// Removes an inline placement → [`ArtifactResponse::Done`].
    Unplace {
        /// The placement.
        placement_id: u64,
    },
    /// A pane's inline placements → [`ArtifactResponse::Placements`].
    Placements {
        /// The pane.
        pane_id: PaneId,
    },
    /// An image (PNG, JPEG) or an `.excalidraw` file pasted or dropped onto a terminal pane:
    /// it becomes an artifact placed inline at the cursor row → [`ArtifactResponse::Placed`].
    Import(ImportRequest),
    /// The versions a drawing or Excalidraw scene was finished at (placed from the overlay,
    /// given a preview, or left alone for a while), newest first →
    /// [`ArtifactResponse::History`]. Only daemons offering
    /// [`DaemonFeatures::ARTIFACT_HISTORY`](crate::DaemonFeatures::ARTIFACT_HISTORY)
    /// understand it; older ones drop a connection that sends it.
    History {
        /// The drawing.
        artifact_id: ArtifactId,
    },
    /// Brings a drawing back to a version from its history, as a new version on top (nothing
    /// is lost: the version it replaces stays in the history) → [`ArtifactResponse::Restored`].
    /// Open editors get the change as ordinary pushes, and every placement of the drawing
    /// shows the restored render. Same feature gate as [`ArtifactRequest::History`].
    Restore {
        /// The drawing.
        artifact_id: ArtifactId,
        /// A version from its history.
        version: u64,
    },
}

/// One Excalidraw element as the editor holds it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ExElement {
    /// Excalidraw's element id.
    pub id: String,
    /// Excalidraw's `version` (bumped on every change).
    pub version: u64,
    /// Excalidraw's `versionNonce` (random per change; the lower one wins a version tie).
    pub version_nonce: u32,
    /// `isDeleted` (deleted elements stay as tombstones so peers learn of the deletion).
    pub deleted: bool,
    /// The element as JSON, verbatim.
    pub json: String,
}

/// An image the scene references: Excalidraw's `fileId` and the blob holding it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ExFile {
    /// Excalidraw's file id.
    pub file_id: String,
    /// The blob (upload it first).
    pub image: ImageRef,
}

/// Changed elements, app state and files of an Excalidraw scene.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExcalidrawPut {
    /// The scene.
    pub artifact_id: ArtifactId,
    /// Revision the client last saw (informational).
    pub base: u64,
    /// Changed elements (whole elements, not patches).
    pub elements: Vec<ExElement>,
    /// The persistent part of `appState` as JSON (background, grid), if it changed.
    pub app_state: Option<String>,
    /// Images newly referenced.
    pub files: Vec<ExFile>,
}

/// An Excalidraw scene, or what changed in it after a revision.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExcalidrawScene {
    /// The artifact; `info.version` is the scene's revision.
    pub info: ArtifactInfo,
    /// Every element (tombstones included) when `since` was 0, else those changed after it.
    pub elements: Vec<ExElement>,
    /// The persistent app state JSON.
    pub app_state: Option<String>,
    /// Every file the scene references.
    pub files: Vec<ExFile>,
}

/// Where a placement came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PlacementSource {
    /// A person finished drawing on the pane, or placed / imported an artifact.
    User,
    /// A program in the pane printed it with the kitty graphics protocol (for example
    /// `un draw show`); the daemon kept the image so it survives snapshots and resumes.
    Kitty,
}

/// An artifact shown inline in a terminal pane: a `cols × rows` cell box whose top-left cell
/// is column `col` of the anchored row. It scrolls with the output (the anchor is a tracked
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Placement {
    /// Daemon-assigned id, never reused.
    pub placement_id: u64,
    /// The pane.
    pub pane_id: PaneId,
    /// What is shown.
    pub artifact_id: ArtifactId,
    /// The artifact version shown (the image is that version's render).
    pub version: u64,
    /// The image drawn: the artifact's image, or a render of `version`.
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
    pub at: UnixMillis,
}

/// Places an artifact inline.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaceRequest {
    /// The pane.
    pub pane_id: PaneId,
    /// The artifact.
    pub artifact_id: ArtifactId,
    /// The version (`None` = current).
    pub version: Option<u64>,
    /// The row; `None` = the cursor's row now.
    pub anchor: Option<AnchorRequest>,
    /// First column.
    pub col: u16,
    /// Size in cells; `0` derives it from the image (at most the pane's width).
    pub cols: u16,
    /// Height in cells; `0` derives it from the image's aspect ratio.
    pub rows: u16,
    /// This device's render of the version (Excalidraw's hand-drawn look, ink); `None` uses
    /// the image, the preview, or the daemon's render.
    pub png: Option<BlobHash>,
    /// A placement this one replaces (the overlay was re-opened and edited).
    pub replace: Option<u64>,
}

/// A file pasted or dropped onto a pane.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportRequest {
    /// The pane.
    pub pane_id: PaneId,
    /// The file name (its extension picks the kind: `.excalidraw` / `.json` scene, else an
    /// image sniffed from its bytes).
    pub name: String,
    /// The content: inline (≤ 1 MiB) …
    #[serde(with = "crate::serde_bytes")]
    pub data: Vec<u8>,
    /// … or an uploaded blob (images only).
    pub blob: Option<BlobHash>,
}

/// One change log slice or a full scene.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ArtifactScene {
    /// The artifact now.
    pub info: ArtifactInfo,
    /// Every element at `info.version` (in drawing order), when the client must replace its
    /// state; `None` when `batches` continue the client's version.
    pub elements: Option<Vec<Element>>,
    /// Batches after the client's version, oldest first.
    pub batches: Vec<OpBatch>,
}

/// An exported file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Exported {
    /// Format.
    pub format: ExportFormat,
    /// The version it shows.
    pub version: u64,
    /// Inline content when small (≤ 1 MiB): the SVG text or PNG bytes.
    #[serde(with = "crate::serde_bytes")]
    pub data: Vec<u8>,
    /// For larger PNGs: the blob to download instead.
    pub blob: Option<BlobHash>,
}

/// One entry of a drawing's history ([`ArtifactRequest::History`]).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtifactVersion {
    /// The drawing's version (an Excalidraw scene's revision) it shows.
    pub version: u64,
    /// When it was recorded.
    pub at: UnixMillis,
    /// Who finished it.
    pub by: Actor,
    /// The render shown then (`None` for versions recorded while nobody rendered it).
    pub image: Option<ImageRef>,
    /// Live elements in it.
    pub elements: u32,
    /// This version restored an older one.
    pub restored_from: Option<u64>,
}

/// What a send did.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sent {
    /// The artifact (created for bare images).
    pub artifact_id: ArtifactId,
    /// The version pinned.
    pub version: u64,
    /// Absolute path of the PNG on the host.
    pub path: String,
    /// The exact text pasted (the path, escaped if needed).
    pub pasted: String,
    /// The pane had bracketed paste on (an agent composer); `false` means the path was typed
    /// as plain text.
    pub bracketed: bool,
}

/// Answers to [`ArtifactRequest`]s.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ArtifactResponse {
    /// Artifacts visible to the caller, oldest first.
    List(Vec<ArtifactInfo>),
    /// The new artifact.
    Created(ArtifactInfo),
    /// Elements or batches.
    Scene(ArtifactScene),
    /// The batch was committed as `version`.
    Applied {
        /// The artifact.
        artifact_id: ArtifactId,
        /// The new version.
        version: u64,
    },
    /// The artifact after the change.
    Info(ArtifactInfo),
    /// Exported content.
    Exported(Exported),
    /// Sent to the agent.
    Sent(Sent),
    /// Done.
    Done,
    /// An Excalidraw scene or its changes.
    Excalidraw(ExcalidrawScene),
    /// Elements offered by [`ArtifactRequest::ExcalidrawPut`] were reconciled.
    ExcalidrawApplied {
        /// The scene.
        artifact_id: ArtifactId,
        /// The scene's revision now.
        version: u64,
        /// Offered elements that lost, as the stored winners (apply them locally).
        rejected: Vec<ExElement>,
    },
    /// The placement made.
    Placed(Placement),
    /// A pane's placements.
    Placements(Vec<Placement>),
    /// A drawing's history, newest first.
    History(Vec<ArtifactVersion>),
    /// The drawing after a restore, and the history entry the restore made.
    Restored {
        /// The artifact now.
        info: ArtifactInfo,
        /// The new version (its `restored_from` names the version brought back).
        version: ArtifactVersion,
    },
}

/// Why an artifact request failed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ArtifactError {
    /// No such artifact, session, pane, blob or version (or outside the grant's scope).
    NotFound(String),
    /// The grant's roles do not allow it; the text names the role needed.
    Forbidden(String),
    /// Over a size cap; the text names it.
    TooLarge(String),
    /// Malformed (not a PNG, bad points, wrong kind).
    Invalid(String),
    /// "Send to agent" into a pane that runs no agent.
    NotAgentPane,
    /// Anything else.
    Failed(String),
    /// The connection dropped before the answer arrived (client side only).
    Disconnected,
}

impl fmt::Display for ArtifactError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound(what) => write!(f, "not found: {what}"),
            Self::Forbidden(why) => write!(f, "not allowed: {why}"),
            Self::TooLarge(why) => write!(f, "too large: {why}"),
            Self::Invalid(why) => write!(f, "invalid: {why}"),
            Self::NotAgentPane => f.write_str("the pane runs no agent"),
            Self::Failed(why) => f.write_str(why),
            Self::Disconnected => f.write_str("disconnected before the daemon answered"),
        }
    }
}

impl std::error::Error for ArtifactError {}

/// Points of a stroke being drawn, before it is committed. Sent about every 16 ms while the
/// pen moves; each chunk carries only the new points.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InkLive {
    /// The drawing.
    pub artifact_id: ArtifactId,
    /// The element the stroke becomes when committed.
    pub stroke_id: ElementId,
    /// Who draws (set by the daemon on fan-out; ignored from clients).
    pub actor: Actor,
    /// Chunk number within the stroke, from 0.
    pub chunk: u32,
    /// Pen and style (repeated in every chunk, so a peer joining mid-stroke can draw).
    pub tool: Tool,
    /// Style.
    pub style: Style,
    /// New points ([`PackedPoints`], deltas restart in every chunk).
    pub points: PackedPoints,
    /// The pen lifted: the stroke is committed (or cancelled) next.
    pub done: bool,
}

/// A canvas pane and the drawing it shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct CanvasPane {
    /// The pane (a leaf of the split tree).
    pub pane_id: PaneId,
    /// The drawing.
    pub artifact_id: ArtifactId,
}

/// Pushed to clients attached to the artifact's session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ArtifactEvent {
    /// A new artifact.
    Created(ArtifactInfo),
    /// A batch was committed.
    Changed {
        /// The artifact after the batch.
        info: ArtifactInfo,
        /// The batch (`batch.version == info.version`).
        batch: OpBatch,
    },
    /// Metadata changed without a batch (anchor moved or detached, preview, canvas panes).
    Info(ArtifactInfo),
    /// Deleted.
    Deleted {
        /// Its session.
        session_id: SessionId,
        /// The artifact.
        artifact_id: ArtifactId,
    },
    /// Someone else's live stroke.
    Ink(InkLive),
    /// The session's canvas panes (whole list).
    Canvases {
        /// The session.
        session_id: SessionId,
        /// Every canvas pane in it.
        canvases: Vec<CanvasPane>,
    },
    /// Excalidraw elements someone else changed (apply with the same reconciliation).
    Excalidraw {
        /// The scene.
        artifact_id: ArtifactId,
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
    Placed(Placement),
    /// An inline placement was removed.
    Unplaced {
        /// The pane.
        pane_id: PaneId,
        /// The placement.
        placement_id: u64,
    },
}

/// First frame on a [`StreamHeader::Blob`](crate::StreamHeader::Blob) stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum BlobHeader {
    /// Client → daemon: store `size` bytes for `session_id`. The daemon answers
    /// [`BlobReply::Ready`] (or `Failed`), reads exactly `size` bytes, then answers
    /// [`BlobReply::Stored`].
    Put {
        /// The session the blob is for (caps are per session).
        session_id: SessionId,
        /// Exact size.
        size: u64,
        /// Encoding (checked against the bytes).
        media: MediaType,
    },
    /// Client → daemon: read a blob. Answered [`BlobReply::Found`], then the bytes and FIN.
    Get {
        /// The blob.
        hash: BlobHash,
    },
}

/// The daemon's answers on a blob stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum BlobReply {
    /// Send the bytes.
    Ready,
    /// Stored (or already present).
    Stored(ImageRef),
    /// The blob follows.
    Found(ImageRef),
    /// Refused or failed.
    Failed(ArtifactError),
}
