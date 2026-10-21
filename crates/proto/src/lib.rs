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
//! | upgrade (bidi)    | both      | [`StreamHeader::Upgrade`] | [`UpgradeReply`] and raw bytes (owner only; see [`info`]) |
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
//! - Input-assistance requests (prompt state, atomic submit, history, completion, file search,
//!   blocked-agent options) are [`ClientCtl::Assist`] → [`ServerCtl::AssistResult`], with
//!   pushes as [`ServerCtl::Assist`]; see [`assist`].
//! - Multiplayer requests (grants, revocation, leases, prompts, audit) are
//!   [`ClientCtl::Multiplayer`] → [`ServerCtl::MultiplayerResult`]; see [`mp`].
//! - Developer-workflow requests (ports, editor, git, worktrees, files, attention) are
//!   [`ClientCtl::Workspace`] → [`ServerCtl::WorkspaceResult`]; see the [`workspace`] types.
//! - Native password prompts (askpass answers, typing a secret at a detected prompt) are
//!   [`ClientCtl::Askpass`] → [`ServerCtl::AskpassResult`], with pushes as
//!   [`ServerCtl::Askpass`], for clients with [`Caps::ASKPASS`]; see [`askpass`].
//! - Agent plan usage: [`WorkspaceRequest::UsageWatch`] → [`WorkspaceResponse::AgentUsage`],
//!   then pushes [`ServerCtl::AgentUsage`] for clients with [`Caps::AGENT_USAGE`]; see [`usage`].
//! - The git-native workspace (repositories, worktrees and branches per pane, pull requests
//!   through the host's `gh`, tasks, archive, scripts) is pushed as [`ServerCtl::Repos`] to
//!   clients with [`Caps::REPO_STATUS`], with its requests in [`WorkspaceRequest`]; see [`repo`].
//! - Approval extras (approve with edited input, "approve all like this" rules) are
//!   [`ClientCtl::Approval`] → [`ServerCtl::ApprovalResult`], with pushes as
//!   [`ServerCtl::Approval`], for clients with [`Caps::APPROVALS`]; see [`approve`].
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

pub mod approve;
pub mod artifact;
pub mod askpass;
pub mod assist;
pub mod frame;
mod ids;
pub mod info;
mod layout;
pub mod mp;
mod msg;
pub mod repo;
mod serde_bytes;
mod ticket;
pub mod usage;
pub mod workspace;

pub use approve::*;
pub use artifact::*;
pub use askpass::*;
pub use assist::*;
pub use frame::{FrameDecoder, FrameError, MAX_FRAME_LEN, WIRE_VERSION};
pub use ids::{
    Actor, Caps, DaemonFeatures, DaemonId, DeviceId, GrantId, InputSeq, OptionId, PaneId,
    PrincipalId, RequestId, ResumeToken, Roles, Seq, SessionEpoch, SessionId, SnapGen, TabId,
    UnixMillis,
};
pub use info::*;
pub use layout::{
    AgentKind, Axis, Direction, LayoutNode, LayoutOp, OpError, OpOutcome, PaneLaunch,
    SessionLayout, SessionSummary, TabLayout,
};
pub use mp::*;
pub use msg::*;
pub use repo::*;
pub use ticket::{PairingSecret, Ticket, TicketError, TicketExtras, TicketRelays};
pub use usage::*;
pub use workspace::*;

/// QUIC ALPN identifier this crate's messages are spoken under.
pub const ALPN: &[u8] = brand::ALPN;
