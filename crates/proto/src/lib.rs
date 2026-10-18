//! Wire types for the client <-> daemon protocol (ALPN [`ALPN`]).
//!
//!
//! | Stream            | Direction | First frame               | Then                     |
//! |-------------------|-----------|---------------------------|--------------------------|
//! | `ctl` (bidi)      | both      | [`ClientCtl::Hello`]      | [`ClientCtl`] / [`ServerCtl`] |
//! | `input` (uni)     | c → s     | [`StreamHeader::Input`]   | [`ClientInput`]          |
//! | `pane/<id>` (uni) | s → c     | [`StreamHeader::Pane`]    | [`PaneOutput`]           |
//! | `bulk` (uni)      | either    | [`StreamHeader::Bulk`]    | [`Bulk`]                 |
//! | forward (bidi)    | both      | [`StreamHeader::PortForward`] / [`StreamHeader::Forward`] | [`ForwardReply`], then raw bytes |
//! | transfer (bidi)   | both      | [`StreamHeader::Upload`] / [`StreamHeader::Download`] | [`TransferReply`] and raw bytes |
//!
//! Every frame is `[u32 LE body length][body]`, and every body starts with the wire version
//! ([`WIRE_VERSION`]) followed by one postcard-encoded message. See [`frame`].
//!
//! # Requests and pushes
//!
//! - Layout changes are [`ClientCtl::Op`] → [`ServerCtl::OpResult`] (same `op_id`).
//! - Pane queries carry a client-chosen `req_id` echoed in the answer, which holds a
//!   `Result<_, RpcError>`: [`ClientCtl::Search`] → [`ServerCtl::SearchResult`],
//!   [`ClientCtl::Links`] → [`ServerCtl::LinksResult`], [`ClientCtl::Commands`] →
//!   [`ServerCtl::CommandsResult`], [`ClientCtl::CommandOutput`] →
//!   [`ServerCtl::CommandOutputResult`].
//! - [`ClientCtl::FetchHistory`] is answered on the daemon's `bulk` stream (opened on first
//!   use, lowest priority) by [`Bulk::HistoryPage`] or [`Bulk::HistoryGone`], keyed by
//!   `(pane, snapshot_seq, offset)`: the records after a [`PaneOutput::SnapshotZstd`]'s READY
//!   section, newest page first, ready for a streaming snapshot decoder.
//!   pushes [`ServerCtl::Artifact`], live ink [`ClientCtl::InkLive`], blobs on
//!   [`StreamHeader::Blob`] streams; see [`artifact`].
//! - Multiplayer requests (grants, revocation, leases, prompts, audit) are
//!   [`ClientCtl::Multiplayer`] → [`ServerCtl::MultiplayerResult`]; see [`mp`].
//! - Developer-workflow requests (ports, editor, git, worktrees, files, attention) are
//!   [`ClientCtl::Workspace`] → [`ServerCtl::WorkspaceResult`]; see the [`workspace`] types.
//! - Pushed without a request: [`ServerCtl::CommandMark`] (shell-integration command start and
//!   end, for the attached session) and [`ServerCtl::CommandFinishedUnseen`] (any session).
//! - Input: [`InputPayload::KeyFull`], [`InputPayload::Mouse`] and [`InputPayload::Paste`] are
//!   encoded by the daemon for the program's current modes; [`InputPayload::Bytes`] is
//!   written as is.
//!
//! # Compatibility rules
//!
//! postcard is not self-describing, so the byte layout *is* the schema:
//!
//! - Variant order is frozen. New variants are appended at the end of an enum.
//! - Fields are never added to, removed from, or reordered in an existing struct or variant.
//!   A shape change is a new variant or a new [`WIRE_VERSION`].
//! - `tests/golden.rs` pins the exact bytes of every message. A failing golden test means the
//!   wire changed: never re-bless an existing entry, add a new one instead.
//!
//! a single principal: a [`PrincipalId`] (a person) is distinct from a [`DeviceId`] (a key),
//! every client message is checked against a [`GrantId`], and input and decisions carry the
//! acting principal.

pub mod artifact;
pub mod frame;
mod ids;
mod layout;
pub mod mp;
mod msg;
mod serde_bytes;
mod ticket;
pub mod workspace;

pub use artifact::*;
pub use frame::{FrameDecoder, FrameError, MAX_FRAME_LEN, WIRE_VERSION};
pub use ids::{
    Actor, Caps, DaemonId, DeviceId, GrantId, InputSeq, OptionId, PaneId, PrincipalId, RequestId,
    ResumeToken, Roles, Seq, SessionEpoch, SessionId, SnapGen, TabId, UnixMillis,
};
pub use layout::{
    AgentKind, Axis, Direction, LayoutNode, LayoutOp, OpError, OpOutcome, PaneLaunch,
    SessionLayout, SessionSummary, TabLayout,
};
pub use mp::*;
pub use msg::*;
pub use ticket::{PairingSecret, Ticket, TicketError, TicketExtras, TicketRelays};
pub use workspace::*;

/// QUIC ALPN identifier this crate's messages are spoken under.
pub const ALPN: &[u8] = brand::ALPN;
