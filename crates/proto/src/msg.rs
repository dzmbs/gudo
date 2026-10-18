//! Messages, grouped by the stream that carries them.
//!
//! Variant order in every enum is part of the wire format; append only.

use serde::{Deserialize, Serialize};

use crate::ids::{
    Actor, Caps, DaemonId, DeviceId, GrantId, InputSeq, OptionId, PaneId, PrincipalId, RequestId,
    ResumeToken, Roles, Seq, SessionEpoch, SessionId, SnapGen, UnixMillis,
};
use crate::layout::{LayoutOp, OpOutcome, SessionLayout, SessionSummary};

// ---------------------------------------------------------------------------------------------
// Stream headers
// ---------------------------------------------------------------------------------------------

/// First frame on every unidirectional stream, naming what the stream carries.
///
/// The `ctl` stream needs no header: it is the first bidirectional stream, and its first frame
/// is always [`ClientCtl::Hello`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum StreamHeader {
    /// Client → daemon: [`ClientInput`] for all panes.
    Input,
    /// Daemon → client: [`PaneOutput`] for one pane. Pane messages omit the pane id because the
    /// header binds it.
    Pane {
        /// The pane this stream carries.
        pane_id: PaneId,
    },
    /// Either direction: [`Bulk`] transfers.
    Bulk,
    /// Client → daemon, on a bidirectional stream: connect to `127.0.0.1:port` on the daemon's
    /// host. The daemon answers with one [`ForwardReply`] frame; after `Connected` both
    /// directions carry raw, unframed bytes until either side finishes its half.
    PortForward {
        /// TCP port on the daemon host's loopback interface.
        port: u16,
    },
}

/// The daemon's answer on a [`StreamHeader::PortForward`] stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ForwardReply {
    /// The TCP connection is open; raw bytes follow.
    Connected,
    /// The connection failed or is not allowed; the daemon finishes the stream.
    Refused {
        /// Human-readable reason.
        reason: String,
    },
}

// ---------------------------------------------------------------------------------------------
// ctl, client → daemon
// ---------------------------------------------------------------------------------------------

/// Messages the client sends on `ctl`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ClientCtl {
    /// Opens (or resumes) the session. Idempotent, so it is safe in 0-RTT data.
    Hello(Hello),
    /// Starts receiving a pane.
    Subscribe {
        /// Pane to subscribe to.
        pane_id: PaneId,
        /// How much of the pane to stream.
        mode: SubscribeMode,
        /// Rows the client can show, so the daemon can trim a snapshot.
        rows_hint: u16,
    },
    /// Stops receiving a pane; the daemon finishes its `pane/<id>` stream.
    Unsubscribe {
        /// Pane to unsubscribe from.
        pane_id: PaneId,
    },
    /// The panes currently on screen. The daemon derives stream priorities and budgets from it.
    Visible {
        /// Every visible pane, focused one included.
        pane_ids: Vec<PaneId>,
    },
    /// The pane receiving keyboard focus, if any.
    Focus {
        /// Focused pane, or `None` when no pane has focus (for example the inbox is open).
        pane_id: Option<PaneId>,
    },
    /// The client's size for a pane. Whether the PTY follows depends on [`SizePolicy`].
    Resize {
        /// Pane being resized.
        pane_id: PaneId,
        /// New size.
        size: PaneSize,
    },
    /// Cumulative acknowledgement: everything up to `seq` has been applied. Sent at most about
    Ack {
        /// Pane being acknowledged.
        pane_id: PaneId,
        /// Output applied up to (exclusive) this offset.
        seq: Seq,
    },
    /// Answers an agent approval request. The first valid decision wins.
    Decide(Decide),
    LeaseRequest {
        /// Pane whose lease is requested.
        pane_id: PaneId,
        /// Ask the holder, or take it outright (owner only).
        kind: LeaseRequestKind,
    },
    /// Changes how a pane's PTY size is chosen.
    SetSizePolicy {
        /// Pane to change.
        pane_id: PaneId,
        /// New policy.
        policy: SizePolicy,
    },
    /// This device's presence. Reserved for multiplayer; the MVP sends `focus` and `state`.
    Presence(Presence),
    /// Liveness and RTT probe; answered by [`ServerCtl::Pong`] with the same nonce.
    Ping {
        /// Echoed back unchanged.
        nonce: u64,
    },
    /// The client is going away on purpose. Sent with its final `Ack`s.
    Bye {
        /// Why the client is leaving.
        reason: ByeReason,
    },
    /// Asks for the session list, answered by [`ServerCtl::Sessions`].
    ListSessions,
    /// Attaches this connection to a session: the daemon answers [`ServerCtl::Attached`] and
    /// the session's [`ServerCtl::LayoutChanged`], then keeps sending layout changes for it.
    /// `None` picks the most recently used session, creating one if there is none.
    Attach {
        /// The session to attach to.
        session_id: Option<SessionId>,
    },
    /// Changes the layout. Answered by [`ServerCtl::OpResult`] with the same `op_id`, after
    /// the resulting `LayoutChanged` has been sent.
    Op {
        /// Client-chosen id echoed in the result.
        op_id: u64,
        /// The change.
        op: LayoutOp,
    },
}

/// Opens a session. Always the first frame on `ctl`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hello {
    /// The device's key. Must equal the key the QUIC handshake authenticated.
    pub device_id: DeviceId,
    /// The person using the device.
    pub principal_id: PrincipalId,
    /// The capability grant this connection acts under.
    pub grant: SignedGrant,
    /// Ghostty snapshot format the client decodes. A mismatch is refused with
    /// [`RefuseReason::SnapshotFormat`] so the client can offer a daemon upgrade.
    pub snapshot_format: u32,
    /// Where the client left off in each pane it holds state for.
    pub resume: Vec<ResumePoint>,
    /// Optional client features.
    pub caps: Caps,
    /// Network class, so budgets can shrink on constrained paths.
    pub link: LinkClass,
    /// Token from the previous [`Welcome`], if any.
    pub resume_token: Option<ResumeToken>,
}

///
/// it is opaque here. `grant_id` is carried in the clear so the daemon can find a cached
/// verification without parsing the token.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedGrant {
    /// Version of the token format inside `token`: [`SignedGrant::PAIRING`] or
    /// [`SignedGrant::DEVICE`] in the MVP.
    pub v: u16,
    /// Id of the grant `token` encodes.
    pub grant_id: GrantId,
    /// The signed token.
    #[serde(with = "crate::serde_bytes")]
    pub token: Vec<u8>,
}

impl SignedGrant {
    /// `token` is a ticket's one-time [`PairingSecret`](crate::PairingSecret); on success the
    /// daemon adds the device to its allowlist for the ticket's principal.
    pub const PAIRING: u16 = 0;
    /// No token: the device key, proven by the QUIC handshake, is on the daemon's allowlist.
    pub const DEVICE: u16 = 1;
}

/// A client's resume point for one pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResumePoint {
    /// The pane.
    pub pane_id: PaneId,
    /// Output applied up to this offset.
    pub last_seq: Seq,
    /// Generation `last_seq` belongs to.
    pub snap_gen: SnapGen,
}

/// How much of a pane a subscription streams.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SubscribeMode {
    /// Snapshot, then live bytes.
    Live,
    /// One snapshot, then nothing (thumbnails).
    Snapshot,
    /// Metadata only, on `ctl`.
    Meta,
}

/// Network class the client is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LinkClass {
    /// No known constraint.
    Normal,
    /// Low Data Mode or an expensive path: smaller budgets, background panes metadata-only.
    Constrained,
}

/// Why a client said `Bye`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ByeReason {
    /// App moving to the background; expect a resume soon.
    Suspend,
    /// User closed the session.
    Quit,
}

/// How a lease request treats the current holder.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LeaseRequestKind {
    /// Transfer if the holder is idle, otherwise ask them.
    Ask,
    /// Take it now. Owner only.
    Force,
}

/// An answer to an agent approval request, signed by the deciding device.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Decide {
    /// The request being answered.
    pub request_id: RequestId,
    /// The chosen option.
    pub option_id: OptionId,
    /// Who decided. Must match the connection's principal and device.
    pub actor: Actor,
    /// Device signature over `(request_id, option_id, actor)`, for the audit log.
    #[serde(with = "crate::serde_bytes")]
    pub sig: Vec<u8>,
}

// ---------------------------------------------------------------------------------------------
// ctl, daemon → client
// ---------------------------------------------------------------------------------------------

/// Messages the daemon sends on `ctl`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ServerCtl {
    /// Accepts a `Hello`.
    Welcome(Welcome),
    /// Rejects a `Hello`; the daemon closes the connection after sending it.
    Refused {
        /// Why.
        reason: RefuseReason,
    },
    /// A pane's metadata changed (or is being listed for the first time).
    PaneMeta(PaneMeta),
    /// A pane no longer exists.
    PaneClosed {
        /// The pane.
        pane_id: PaneId,
    },
    /// The PTY facts local echo prediction depends on changed.
    EchoHint(EchoHint),
    /// Input was not applied. Input is never dropped silently. Sent on `ctl` rather than the
    /// pane stream so it arrives even when the client is not subscribed to the pane.
    InputRejected {
        /// Pane the input targeted.
        pane_id: PaneId,
        /// The rejected input.
        input_seq: InputSeq,
        /// Why.
        reason: InputRejectReason,
    },
    /// A pane's input lease changed.
    Lease(Lease),
    /// An approval request was decided (by this client or another).
    Decided(Decided),
    /// This client's decision lost: someone else decided first.
    AlreadyDecided {
        /// The request.
        request_id: RequestId,
        /// Who won.
        by: Actor,
    },
    /// Another participant's presence. Reserved for multiplayer.
    Presence(Presence),
    /// The grant this connection used was revoked. Streams close after this.
    Revoked {
        /// The revoked grant.
        grant_id: GrantId,
    },
    /// Answer to [`ClientCtl::Ping`].
    Pong {
        /// The ping's nonce.
        nonce: u64,
    },
    /// The daemon's sessions. Answers [`ClientCtl::ListSessions`] and is re-sent to every
    /// client when a session is created, renamed or closed.
    Sessions {
        /// Sessions within the grant's scope.
        sessions: Vec<SessionSummary>,
    },
    /// Answers [`ClientCtl::Attach`].
    Attached {
        /// The session this connection is now attached to.
        session_id: SessionId,
    },
    /// The attached session's layout changed (or is being sent for the first time).
    LayoutChanged(SessionLayout),
    /// Answers [`ClientCtl::Op`].
    OpResult {
        /// The client's id for the op.
        op_id: u64,
        /// What happened.
        outcome: OpOutcome,
    },
    /// versioned JSON. Kept as JSON because that schema is shared with hooks, logs and push
    /// payloads and evolves on its own version.
    AgentEvent {
        /// The pane the agent runs in.
        pane_id: PaneId,
        /// One `AgentEvent` object.
        json: String,
    },
    /// The PTY facts local echo prediction depends on, with the daemon's verdict under the
    /// corrected S6 rule and the output offset they apply from. Supersedes
    /// [`ServerCtl::EchoHint`].
    EchoHintAt(EchoHintAt),
}

/// The daemon's answer to a successful `Hello`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Welcome {
    /// The daemon's key.
    pub daemon_id: DaemonId,
    /// This daemon run.
    pub session_epoch: SessionEpoch,
    /// Roles the presented grant confers.
    pub roles: Roles,
    /// Ghostty snapshot format the daemon encodes.
    pub snapshot_format: u32,
    /// Panes within the grant's scope. Never a global list filtered by the client.
    pub panes: Vec<PaneMeta>,
    /// Token to present in the next `Hello`.
    pub resume_token: ResumeToken,
}

/// Why a `Hello` was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RefuseReason {
    /// The daemon does not speak the client's wire version.
    WireVersion {
        /// The version the daemon speaks.
        supported: u16,
    },
    /// The daemon encodes a different Ghostty snapshot format.
    SnapshotFormat {
        /// The format the daemon encodes.
        daemon: u32,
    },
    /// The grant failed verification, expired, or was used up.
    InvalidGrant,
    /// The grant was revoked.
    Revoked,
    /// `Hello.device_id` does not match the key that completed the handshake.
    DeviceMismatch,
}

/// Everything a client shows about a pane without streaming it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneMeta {
    /// The pane.
    pub pane_id: PaneId,
    /// Terminal title (OSC 0/2).
    pub title: String,
    /// Working directory (OSC 7), if known.
    pub cwd: Option<String>,
    /// Exit status once the pane's process has exited.
    pub exit: Option<i32>,
    /// Agent running in the pane, if any.
    pub agent: Option<AgentStatus>,
    /// Current PTY size.
    pub size: PaneSize,
    /// How the PTY size is chosen.
    pub size_policy: SizePolicy,
    /// Principal whose client size the PTY currently has, for the "Sized by" badge.
    pub sized_by: Option<PrincipalId>,
}

/// A terminal size.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneSize {
    /// Columns.
    pub cols: u16,
    /// Rows.
    pub rows: u16,
    /// Width of the text area in pixels, 0 if unknown.
    pub width_px: u16,
    /// Height of the text area in pixels, 0 if unknown.
    pub height_px: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SizePolicy {
    /// The lease holder's size. Default once a pane is shared.
    FollowLease,
    /// The size of the client that last sent input. Default for one principal.
    LastInput,
    /// A fixed size.
    Fixed {
        /// Columns.
        cols: u16,
        /// Rows.
        rows: u16,
    },
    /// The smallest size of all viewers (tmux).
    Smallest,
}

/// The agent in a pane.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentStatus {
    /// Agent kind, as the daemon's adapter names it (`"claude"`, `"codex"`).
    pub kind: String,
    /// What it is doing.
    pub state: AgentState,
}

/// What an agent is doing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgentState {
    /// Waiting for a prompt.
    Idle,
    /// Working.
    Running,
    /// Waiting for a human decision.
    Blocked(Blocker),
    /// Finished its task.
    Done,
}

/// An approval request an agent is blocked on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Blocker {
    /// Id to answer with [`ClientCtl::Decide`].
    pub request_id: RequestId,
    /// What the agent wants to do, for display.
    pub summary: String,
    /// The available answers.
    pub options: Vec<DecisionOption>,
}

/// One answer to an approval request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DecisionOption {
    /// Id to answer with.
    pub id: OptionId,
    /// Label for the button.
    pub label: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct EchoHint {
    /// The pane.
    pub pane_id: PaneId,
    /// The slave's `ECHO` flag. Never predict when it is off (password prompts).
    pub echo: bool,
    /// The slave's `ICANON` flag.
    pub icanon: bool,
    /// The alternate screen is active.
    pub alt_screen: bool,
    /// The cursor is at a shell prompt (OSC 133).
    pub at_prompt: bool,
}

/// [`EchoHint`] positioned in the output stream, plus the prediction verdict.
///
/// The client applies it once it has applied output up to `at_seq`, so a password prompt's
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct EchoHintAt {
    /// The raw facts.
    pub hint: EchoHint,
    /// Output offset from which they hold.
    pub at_seq: Seq,
    /// Whether the client may predict printable input.
    pub prediction: Prediction,
}

///
/// `ECHO` off alone does not mean "password": line editors (zsh ZLE, readline) and every TUI
/// run with `-echo -icanon`. The rule, first match wins:
///
/// | termios | other facts | verdict |
/// |---|---|---|
/// | `-echo icanon` | – | [`HiddenInput`](Self::HiddenInput) (never predict) |
/// | any | alternate screen | [`AltScreen`](Self::AltScreen) |
/// | `echo icanon` | – | [`Allow`](Self::Allow) |
/// | `-icanon` | at a shell prompt (OSC 133;B seen, 133;C not yet) | [`Allow`](Self::Allow) |
/// | `-icanon` | otherwise | [`RawOutsidePrompt`](Self::RawOutsidePrompt) |
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Prediction {
    /// Predicting printable characters is safe.
    Allow,
    /// Cooked mode with echo off: a password prompt. Never predict.
    HiddenInput,
    /// A full-screen program owns the screen; no prediction in v1.
    AltScreen,
    /// Raw mode outside a shell prompt (a TUI, or a raw-mode password widget).
    RawOutsidePrompt,
}

impl Prediction {
    /// Applies the rule above.
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::Prediction;
    ///
    /// // zsh at its prompt: raw, no echo, but shell integration says we are editing a line.
    /// assert_eq!(Prediction::decide(false, false, false, true), Prediction::Allow);
    /// // `sudo` asking for a password.
    /// assert_eq!(Prediction::decide(false, true, false, false), Prediction::HiddenInput);
    /// ```
    pub fn decide(echo: bool, icanon: bool, alt_screen: bool, at_prompt: bool) -> Self {
        if !echo && icanon {
            Self::HiddenInput
        } else if alt_screen {
            Self::AltScreen
        } else if icanon || at_prompt {
            Self::Allow
        } else {
            Self::RawOutsidePrompt
        }
    }
}

/// Why input was rejected.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum InputRejectReason {
    /// Someone else holds the pane's lease.
    NoLease,
    /// The grant's roles do not allow this kind of input.
    Role,
    /// The input was refused by policy (for example a Prompter escaping to a shell).
    Blocked,
    /// The pane does not exist or is outside the grant's scope.
    UnknownPane,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Lease {
    /// The pane.
    pub pane_id: PaneId,
    /// Current holder; `None` when nobody holds it.
    pub holder: Option<PrincipalId>,
    /// When the holder acquired it.
    pub since: UnixMillis,
    /// Arbitration mode.
    pub mode: LeaseMode,
}

/// Input arbitration for a pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LeaseMode {
    /// Any Driver may type; keystrokes interleave. The only mode in the MVP.
    Free,
    /// Only the holder's raw input is accepted.
    Leased,
}

/// The outcome of an approval request, broadcast to every participant who can see it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Decided {
    /// Pane whose agent asked.
    pub pane_id: PaneId,
    /// The request.
    pub request_id: RequestId,
    /// The winning answer.
    pub option_id: OptionId,
    /// Who answered.
    pub decided_by: Actor,
    /// When the daemon accepted it.
    pub at: UnixMillis,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Presence {
    /// Who.
    pub actor: Actor,
    /// Activity level.
    pub state: PresenceState,
    /// Focused pane.
    pub focus: Option<PaneId>,
    /// Typing in the agent composer.
    pub typing: bool,
    /// Rows on screen.
    pub viewport: Option<Viewport>,
    /// Cursor position, if shared.
    pub cursor: Option<CursorPos>,
}

/// Activity level of a participant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PresenceState {
    /// Interacting now.
    Active,
    /// Connected, not interacting.
    Idle,
    /// Disconnected within the grace period.
    Away,
}

/// The rows of a pane a participant has on screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Viewport {
    /// The pane.
    pub pane_id: PaneId,
    /// First visible row, counted from the top of scrollback.
    pub top_row: u32,
    /// Number of visible rows.
    pub rows: u16,
}

/// A cell position in a pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct CursorPos {
    /// The pane.
    pub pane_id: PaneId,
    /// Row within the viewport.
    pub row: u16,
    /// Column.
    pub col: u16,
}

// ---------------------------------------------------------------------------------------------
// input, client → daemon
// ---------------------------------------------------------------------------------------------

/// Messages on the `input` stream. Never sent in 0-RTT data (replayable).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ClientInput {
    /// One input event.
    Input(Input),
}

/// One input event for one pane.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Input {
    /// Target pane.
    pub pane_id: PaneId,
    /// Sequence number, echoed in `InputAck` / `InputRejected`.
    pub input_seq: InputSeq,
    /// The acting principal. The daemon rejects input whose principal differs from the
    /// connection's, so the field can be trusted downstream (audit, presence, prompt authors).
    pub principal: PrincipalId,
    /// What was typed.
    pub payload: InputPayload,
}

/// The content of an input event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum InputPayload {
    /// Raw bytes for the PTY, already encoded by the client.
    Bytes(#[serde(with = "crate::serde_bytes")] Vec<u8>),
    /// A key event the daemon encodes for the pane's current keyboard mode.
    Key(KeyEvent),
    /// Pasted text; the daemon applies bracketed paste if the pane enabled it.
    Paste(String),
    /// A mouse event the daemon encodes for the pane's mouse mode.
    Mouse(MouseEvent),
}

/// A key event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyEvent {
    /// Physical key, as a Ghostty `GhosttyKey` value.
    pub key: u32,
    /// Modifier bitmask, Ghostty `GhosttyMods` layout.
    pub mods: u16,
    /// Press, repeat or release.
    pub action: KeyAction,
    /// Text the key produced under the current layout, if any.
    pub text: Option<String>,
}

/// Kind of key event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum KeyAction {
    /// Key went down.
    Press,
    /// Auto-repeat.
    Repeat,
    /// Key went up.
    Release,
}

/// A mouse event in cell coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct MouseEvent {
    /// What happened.
    pub action: MouseAction,
    /// Which button.
    pub button: MouseButton,
    /// Column.
    pub col: u16,
    /// Row within the viewport.
    pub row: u16,
    /// Modifier bitmask, Ghostty `GhosttyMods` layout.
    pub mods: u16,
}

/// Kind of mouse event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MouseAction {
    /// Button pressed.
    Press,
    /// Button released.
    Release,
    /// Pointer moved.
    Motion,
}

/// A mouse button, wheel directions included.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MouseButton {
    /// No button (motion only).
    None,
    /// Primary.
    Left,
    /// Middle.
    Middle,
    /// Secondary.
    Right,
    /// Wheel up.
    WheelUp,
    /// Wheel down.
    WheelDown,
    /// Wheel left.
    WheelLeft,
    /// Wheel right.
    WheelRight,
}

// ---------------------------------------------------------------------------------------------
// pane/<id>, daemon → client
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum PaneOutput {
    /// Raw PTY output starting at byte offset `seq`.
    Bytes {
        /// Offset of `data[0]` in the pane's output.
        seq: Seq,
        /// The bytes.
        #[serde(with = "crate::serde_bytes")]
        data: Vec<u8>,
    },
    /// Replaces the client's terminal state. Live bytes continue from `seq`. Sent on subscribe,
    /// on resume, and after the daemon stopped sending bytes because the client fell behind.
    Snapshot {
        /// Output offset the snapshot reflects.
        seq: Seq,
        /// Generation the snapshot belongs to.
        snap_gen: SnapGen,
        /// Ghostty snapshot, READY section only.
        #[serde(with = "crate::serde_bytes")]
        data: Vec<u8>,
    },
    /// "Your input `input_seq` is reflected at or after output offset `at_seq`."
    InputAck {
        /// The input.
        input_seq: InputSeq,
        /// Output offset after which its effect is visible.
        at_seq: Seq,
    },
    /// 200 KB → 42 KB). The daemon always sends this form.
    SnapshotZstd {
        /// Output offset the snapshot reflects.
        seq: Seq,
        /// Generation the snapshot belongs to.
        snap_gen: SnapGen,
        /// Length of the decompressed snapshot, to bound the decoder's allocation.
        raw_len: u32,
        /// One zstd frame holding the Ghostty snapshot's READY section.
        #[serde(with = "crate::serde_bytes")]
        data: Vec<u8>,
    },
    /// The terminal was resized between the bytes before `seq` and the byte at `seq`. Sent
    /// in-band so every client resizes its VT at the same point in the stream as the daemon.
    Resized {
        /// Output offset of the resize.
        seq: Seq,
        /// The new size.
        size: PaneSize,
    },
}

// ---------------------------------------------------------------------------------------------
// bulk
// ---------------------------------------------------------------------------------------------

/// Messages on a `bulk` stream (lowest priority).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Bulk {
    /// Scrollback older than a snapshot's READY marker, fetched lazily on scroll-up.
    History {
        /// The pane.
        pane_id: PaneId,
        /// Generation of the snapshot this history extends.
        snap_gen: SnapGen,
        /// Ghostty snapshot history records.
        #[serde(with = "crate::serde_bytes")]
        data: Vec<u8>,
    },
}
