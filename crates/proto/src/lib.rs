//! Wire types for the client <-> daemon protocol (ALPN [`ALPN`]).
//!
//!
//! | Stream            | Direction | First frame               | Then                     |
//! |-------------------|-----------|---------------------------|--------------------------|
//! | `ctl` (bidi)      | both      | [`ClientCtl::Hello`]      | [`ClientCtl`] / [`ServerCtl`] |
//! | `input` (uni)     | c → s     | [`StreamHeader::Input`]   | [`ClientInput`]          |
//! | `pane/<id>` (uni) | s → c     | [`StreamHeader::Pane`]    | [`PaneOutput`]           |
//! | `bulk` (uni)      | either    | [`StreamHeader::Bulk`]    | [`Bulk`]                 |
//! | forward (bidi)    | both      | [`StreamHeader::PortForward`] | [`ForwardReply`], then raw bytes |
//!
//! Every frame is `[u32 LE body length][body]`, and every body starts with the wire version
//! ([`WIRE_VERSION`]) followed by one postcard-encoded message. See [`frame`].
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

pub mod frame;
mod ids;
mod layout;
mod msg;
mod serde_bytes;
mod ticket;

pub use frame::{FrameDecoder, FrameError, MAX_FRAME_LEN, WIRE_VERSION};
pub use ids::{
    Actor, Caps, DaemonId, DeviceId, GrantId, InputSeq, OptionId, PaneId, PrincipalId, RequestId,
    ResumeToken, Roles, Seq, SessionEpoch, SessionId, SnapGen, TabId, UnixMillis,
};
pub use layout::{
    AgentKind, Axis, Direction, LayoutNode, LayoutOp, OpError, OpOutcome, PaneLaunch,
    SessionLayout, SessionSummary, TabLayout,
};
pub use msg::*;
pub use ticket::{PairingSecret, Ticket, TicketError};

/// QUIC ALPN identifier this crate's messages are spoken under.
pub const ALPN: &[u8] = brand::ALPN;
