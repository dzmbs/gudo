//! Messages, grouped by the stream that carries them.
//!
//! Variant order in every enum is part of the wire format; append only.

use serde::{Deserialize, Serialize};

use crate::ids::{
    Actor, Caps, DaemonId, DeviceId, GrantId, InputSeq, OptionId, PaneId, PrincipalId, RequestId,
    ResumeToken, Roles, Seq, SessionEpoch, SessionId, SnapGen, UnixMillis,
};
use crate::layout::{LayoutOp, OpOutcome, SessionLayout, SessionSummary};
use crate::mp::{JoinInfo, MpError, MpRequest, MpResponse, Participant};
use crate::workspace::{
    AttentionUpdate, DownloadHeader, ForwardTarget, FsChange, PortInfo, UploadHeader,
    VsCodeTunnelStatus, WorkspaceRequest, WorkspaceResponse, WsError,
};

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
    /// Client → daemon, bidirectional: like [`StreamHeader::PortForward`], to a TCP port or a
    /// Unix socket on the daemon's host. Answered by [`ForwardReply`], then raw bytes; each
    /// side finishes its half when its peer closes that direction (half-close).
    Forward {
        /// Where to connect.
        target: ForwardTarget,
    },
    /// Client → daemon, bidirectional, bulk priority: write a file atomically. See
    /// [`TransferReply`].
    Upload(UploadHeader),
    /// Client → daemon, bidirectional, bulk priority: read a file. See [`TransferReply`](crate::TransferReply).
    Download(DownloadHeader),
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
    /// Asks for scrollback older than a snapshot's READY marker. The daemon answers on its
    /// `bulk` stream with one [`Bulk::HistoryPage`] (or [`Bulk::HistoryGone`]).
    ///
    /// History is served newest first, as the snapshot's records are ordered. The client starts
    /// at the length of the READY section it decoded and continues from each page's
    /// `next_offset`.
    FetchHistory {
        /// The pane.
        pane_id: PaneId,
        /// `seq` of the snapshot whose history is wanted.
        snapshot_seq: Seq,
        /// Byte offset into that snapshot where the page starts (the cursor).
        offset: u64,
        /// Upper bound on the page's uncompressed size. At least one history page record is
        /// always sent, whatever its size.
        max_bytes: u32,
    },
    /// Searches a pane's whole scrollback, answered by [`ServerCtl::SearchResult`].
    Search {
        /// Client-chosen id echoed in the result.
        req_id: u64,
        /// The pane.
        pane_id: PaneId,
        /// What to look for.
        query: SearchQuery,
        /// Matches to skip, newest first: `0` for the first page, then the previous page's
        /// [`SearchPage::next`].
        cursor: u32,
        /// Matches per page.
        limit: u32,
    },
    /// Hyperlinks, URLs and file paths on screen and in recent command output, answered by
    /// [`ServerCtl::LinksResult`].
    Links {
        /// Client-chosen id echoed in the result.
        req_id: u64,
        /// The pane.
        pane_id: PaneId,
        /// How many of the most recent finished commands' output to scan besides the screen.
        commands: u16,
    },
    /// The pane's shell-integration command history, answered by
    /// [`ServerCtl::CommandsResult`].
    Commands {
        /// Client-chosen id echoed in the result.
        req_id: u64,
        /// The pane.
        pane_id: PaneId,
    },
    /// The output of one command (OSC 133 C..D), answered by
    /// [`ServerCtl::CommandOutputResult`].
    CommandOutput {
        /// Client-chosen id echoed in the result.
        req_id: u64,
        /// The pane.
        pane_id: PaneId,
        /// The command, or `None` for the most recent finished one.
        command_id: Option<u64>,
    },
    /// A developer-workflow request (ports, editor, git, worktrees, files, attention),
    /// answered by [`ServerCtl::WorkspaceResult`].
    Workspace {
        /// Client-chosen id echoed in the result.
        req_id: u64,
        /// The request.
        req: WorkspaceRequest,
    },
    /// A multiplayer request (grants, revocation, leases, prompts, audit), answered by
    /// [`ServerCtl::MultiplayerResult`].
    Multiplayer {
        /// Client-chosen id echoed in the result.
        req_id: u64,
        /// The request.
        req: MpRequest,
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
    /// No token: the device key, proven by the QUIC handshake, is on the daemon's allowlist
    /// (a paired owner device).
    pub const DEVICE: u16 = 1;
    /// `token` is the postcard encoding of a [`GrantChain`](crate::GrantChain) and
    /// `grant_id` its leaf's id (an invite). `Hello.principal_id` must be the guest principal
    /// derived from the device key (`grants::guest_principal`).
    pub const CHAIN: u16 = 2;
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
    /// A shell-integration command started or finished in a pane of the attached session.
    CommandMark(CommandMark),
    /// A command that ran at least the daemon's threshold (default 10 s) finished while no
    /// client was showing its pane. Sent to every client, whatever session it is attached to,
    /// so it can notify.
    CommandFinishedUnseen(CommandMark),
    /// Answers [`ClientCtl::Search`].
    SearchResult {
        /// The request's id.
        req_id: u64,
        /// The pane searched.
        pane_id: PaneId,
        /// One page of matches.
        result: Result<SearchPage, RpcError>,
    },
    /// Answers [`ClientCtl::Links`].
    LinksResult {
        /// The request's id.
        req_id: u64,
        /// The pane.
        pane_id: PaneId,
        /// What was found.
        result: Result<Links, RpcError>,
    },
    /// Answers [`ClientCtl::Commands`].
    CommandsResult {
        /// The request's id.
        req_id: u64,
        /// The pane.
        pane_id: PaneId,
        /// The commands still in scrollback, oldest first.
        result: Result<CommandList, RpcError>,
    },
    /// Answers [`ClientCtl::CommandOutput`].
    CommandOutputResult {
        /// The request's id.
        req_id: u64,
        /// The pane.
        pane_id: PaneId,
        /// The output.
        result: Result<CommandOutput, RpcError>,
    },
    /// Answers [`ClientCtl::Workspace`].
    WorkspaceResult {
        /// The request's id.
        req_id: u64,
        /// The answer.
        result: Result<WorkspaceResponse, WsError>,
    },
    /// The listening ports in panes changed (the whole list; sent to every client).
    PortsChanged {
        /// Every detected port.
        ports: Vec<PortInfo>,
    },
    /// A directory this connection watches changed.
    FsChanged(FsChange),
    /// The attention feed changed (sent to every client, whatever session it is attached
    /// to).
    Attention(AttentionUpdate),
    /// The VS Code tunnel changed state: a device code to show, connected, failed (sent to
    /// every client).
    VsCodeTunnel(VsCodeTunnelStatus),
    /// Answers [`ClientCtl::Multiplayer`].
    MultiplayerResult {
        /// The request's id.
        req_id: u64,
        /// The answer.
        result: Result<MpResponse, MpError>,
    },
    /// Who this connection is: sent right after [`ServerCtl::Welcome`].
    Joined(JoinInfo),
    /// Everyone connected (sent whole whenever someone joins, leaves, renames or changes
    /// focus; per-keystroke presence comes as [`ServerCtl::Presence`]).
    Participants {
        /// One entry per connected device, within the recipient's scope.
        participants: Vec<Participant>,
    },
    /// Someone asked for the lease this connection's principal holds: answer with
    /// [`MpRequest::AnswerControl`](crate::MpRequest::AnswerControl). It moves anyway once
    /// the holder has been idle for the daemon's lease timeout.
    LeaseRequested {
        /// The pane.
        pane_id: PaneId,
        /// Who asks.
        by: Actor,
        /// Their display name.
        name: String,
    },
    /// A ctl message was refused by policy (roles or scope). Requests with an id get their
    /// error in their own answer instead.
    Forbidden {
        /// What was refused ("Subscribe", "Op", "Decide", …).
        what: String,
        /// Why, naming the role needed.
        reason: String,
    },
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
    /// A key event with everything the kitty keyboard protocol needs; supersedes
    /// [`InputPayload::Key`].
    KeyFull(FullKeyEvent),
}

/// A key event as libghostty-vt's key encoder takes it (`include/ghostty/vt/key/event.h`).
///
/// The daemon encodes it for the pane's current modes: legacy, cursor-key and keypad
/// application modes, modifyOtherKeys, or the kitty keyboard protocol flags the program pushed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FullKeyEvent {
    /// Physical key, as a Ghostty `GhosttyKey` value (US layout positions).
    pub key: u32,
    /// Modifiers held, Ghostty `GhosttyMods` layout.
    pub mods: u16,
    /// Modifiers the layout consumed to produce `text` (for example shift for `A`).
    pub consumed_mods: u16,
    /// Press, repeat or release.
    pub action: KeyAction,
    /// Text the key produced under the current layout, if any.
    pub text: Option<String>,
    /// The codepoint the key produces with no modifiers (kitty's base key), if known.
    pub unshifted_codepoint: Option<u32>,
    /// An input method is composing; nothing is sent for the key.
    pub composing: bool,
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
    /// Answers [`ClientCtl::FetchHistory`]: whole snapshot records ending after a page record
    /// or at FINISH, so a streaming decoder can apply every page in it.
    HistoryPage {
        /// The pane.
        pane_id: PaneId,
        /// The snapshot these records belong to.
        snapshot_seq: Seq,
        /// Offset of the first record in the snapshot (the request's cursor).
        offset: u64,
        /// Offset to request next.
        next_offset: u64,
        /// Size of the whole snapshot, for progress.
        total_len: u64,
        /// Length of `data` decompressed.
        raw_len: u32,
        /// History page records in `data`.
        pages: u32,
        /// The snapshot's FINISH record is included: there is no more history.
        done: bool,
        /// One zstd frame holding the records.
        #[serde(with = "crate::serde_bytes")]
        data: Vec<u8>,
    },
    /// The daemon no longer holds that snapshot (a newer one replaced it, or the daemon
    /// restarted). History is available again from the pane's next snapshot.
    HistoryGone {
        /// The pane.
        pane_id: PaneId,
        /// The snapshot asked for.
        snapshot_seq: Seq,
    },
}

// ---------------------------------------------------------------------------------------------
// Shell integration, search, links (ctl requests)
// ---------------------------------------------------------------------------------------------

/// Why a ctl request failed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RpcError {
    /// The pane does not exist or is outside the grant's scope.
    UnknownPane,
    /// The request was malformed (for example an invalid regex); the text says why.
    BadRequest(String),
    /// Nothing to answer with (no such command, no shell integration yet).
    NotFound,
    /// The daemon failed; the text says why.
    Internal(String),
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnknownPane => f.write_str("no such pane"),
            Self::BadRequest(why) => write!(f, "bad request: {why}"),
            Self::NotFound => f.write_str("not found"),
            Self::Internal(why) => write!(f, "daemon error: {why}"),
        }
    }
}

impl std::error::Error for RpcError {}

/// A command reported by shell integration (OSC 133).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandMark {
    /// The pane.
    pub pane_id: PaneId,
    /// Per-pane command number, from 1, never reused while the pane lives.
    pub command_id: u64,
    /// The command line, if the shell sent it or it could be read off the screen.
    pub command: Option<String>,
    /// Working directory when it started (OSC 7).
    pub cwd: Option<String>,
    /// When it started (OSC 133;C).
    pub started_at: UnixMillis,
    /// Output offset at which the mark's event (start, or end once finished) happened.
    pub at_seq: Seq,
    /// `None` while it runs.
    pub finished: Option<CommandEnd>,
}

/// How a command ended (OSC 133;D).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandEnd {
    /// Exit status, if the shell reported it.
    pub exit: Option<i32>,
    /// Wall time from 133;C to 133;D.
    pub duration_ms: u64,
}

/// Where a command sits on the pane's primary screen, in screen rows (row 0 is the oldest
/// retained scrollback row) at [`CommandList::at_seq`]. `None` once the row left scrollback.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandRows {
    /// Row of the prompt start.
    pub prompt: Option<u64>,
    /// Row where output started.
    pub output: Option<u64>,
    /// Row of the command end.
    pub end: Option<u64>,
}

/// One command in a [`CommandList`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandInfo {
    /// The mark.
    pub mark: CommandMark,
    /// Its rows.
    pub rows: CommandRows,
}

/// Answer to [`ClientCtl::Commands`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandList {
    /// Output offset the rows refer to.
    pub at_seq: Seq,
    /// Rows on the primary screen (scrollback and active area).
    pub total_rows: u64,
    /// Commands the daemon remembers, oldest first.
    pub commands: Vec<CommandInfo>,
}

/// Answer to [`ClientCtl::CommandOutput`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandOutput {
    /// The command.
    pub mark: CommandMark,
    /// Its output as plain text, soft-wrapped lines joined.
    pub text: String,
    /// The text was cut at the daemon's limit, or its start already left scrollback.
    pub truncated: bool,
}

/// What a [`ClientCtl::Search`] looks for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchQuery {
    /// Text or pattern.
    pub pattern: String,
    /// How `pattern` is interpreted.
    pub mode: SearchMode,
    /// Case handling.
    pub case: CaseMode,
}

/// How a search pattern is interpreted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SearchMode {
    /// Literal text.
    Plain,
    /// A regular expression (Rust `regex` syntax: no look-around or backreferences).
    Regex,
}

/// Case handling for a search.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CaseMode {
    /// Exact case.
    Sensitive,
    /// Ignore case.
    Insensitive,
    /// Ignore case unless the pattern has an uppercase letter.
    Smart,
}

/// One page of search matches, newest (bottom of the screen) first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchPage {
    /// Output offset the positions refer to.
    pub at_seq: Seq,
    /// Rows on the searched screen. `total_rows - row` is a match's distance from the bottom,
    /// which a client VT at the same `at_seq` shares even when it holds less scrollback.
    pub total_rows: u64,
    /// Matches in the whole scrollback.
    pub total: u32,
    /// This page.
    pub matches: Vec<SearchMatch>,
    /// Cursor for the next page, `None` after the last.
    pub next: Option<u32>,
}

/// One match. Matches may span soft-wrapped rows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchMatch {
    /// Screen row of the first cell (row 0 is the oldest retained scrollback row).
    pub row: u64,
    /// Column of the first cell.
    pub col: u16,
    /// Screen row of the last cell.
    pub end_row: u64,
    /// Column of the last cell (inclusive).
    pub end_col: u16,
    /// The logical line containing the match (soft wraps joined), for a result list.
    pub line: String,
}

/// Answer to [`ClientCtl::Links`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Links {
    /// The directory relative paths were resolved against.
    pub cwd: Option<String>,
    /// Unique targets: the screen first (bottom up), then command output (newest first).
    pub links: Vec<Link>,
}

/// A tappable target found in a pane.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Link {
    /// What was found.
    pub kind: LinkKind,
    /// The text as shown.
    pub text: String,
    /// The URL, or the absolute path for a file path.
    pub target: String,
    /// Line from a `path:line[:col]` suffix.
    pub line: Option<u32>,
    /// Column from a `path:line:col` suffix.
    pub column: Option<u32>,
    /// Whether a path exists on the daemon's host; `None` for URLs and hyperlinks.
    pub exists: Option<bool>,
    /// Where it was found.
    pub source: LinkSource,
}

/// Kinds of [`Link`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LinkKind {
    /// An OSC 8 hyperlink.
    Hyperlink,
    /// A URL detected in the text.
    Url,
    /// A file path detected in the text.
    Path,
}

/// Where a [`Link`] was found.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LinkSource {
    /// The visible screen.
    Screen,
    /// The output of a command.
    Command {
        /// Its id.
        command_id: u64,
    },
}
