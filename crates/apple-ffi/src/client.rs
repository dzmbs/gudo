//! The daemon client ([`DaemonClient`]) and the event interface shared with SSH panes.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use client_core::proto::{self, OptionId, PaneId, RequestId, SessionId};
use tokio::sync::oneshot;

use crate::bytes::Bytes;
use crate::types::{
    AgentKind, AttachVia, Axis, CommandList, CommandMark, CommandOutput, EchoHint, KeyEvent,
    LayoutOp, Links, MouseEvent, OpErrorCode, OpOutcome, PaneActivity, PaneMeta, PaneSize,
    PaneSizing, ProgramReport, RpcError, SearchPage, SearchQuery, SessionLayout, SessionSummary,
    SizePolicy, TerminalColors,
};
use crate::ws_types::{ForwardInfo, ForwardTarget, WorkspaceError};
use crate::{on_runtime, runtime};

/// Errors from [`DaemonClient`].
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ClientError {
    /// The ticket could not be parsed.
    #[error("bad ticket: {message}")]
    Ticket { message: String },
    /// The device key is not 32 bytes.
    #[error("the device key must be 32 bytes")]
    Key,
    /// A local I/O error (binding a forwarded port).
    #[error("{message}")]
    Io { message: String },
}

impl From<client_core::ClientError> for ClientError {
    fn from(client_error: client_core::ClientError) -> Self {
        match client_error {
            client_core::ClientError::Ticket(client_error) => Self::Ticket {
                message: client_error.to_string(),
            },
            client_core::ClientError::Key => Self::Key,
            client_core::ClientError::Io(client_error) => Self::Io {
                message: client_error.to_string(),
            },
        }
    }
}

/// Which relays the client may use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RelayMode {
    /// n0's relays and address lookup.
    Default,
    /// Direct addresses only (tests, local-only mode).
    Disabled,
}

/// [`DaemonClient`] settings. `Debug` leaves the device key out.
#[derive(Clone, uniffi::Record)]
pub struct ClientConfig {
    /// The device's Ed25519 secret key (32 bytes, [`generate_device_key`]); keep it in the
    /// Keychain. It identifies this device to every daemon it pairs with.
    pub secret_key: Bytes,
    /// Relay usage.
    pub relay: RelayMode,
    /// Keep a libghostty-vt mirror per followed pane in Rust (for `pane_text`,
    /// `pane_snapshot`, history paging into the mirror). An app that feeds its own VT can
    /// turn it off; seq/ack and resume work either way.
    #[uniffi(default = true)]
    pub mirror_vt: bool,
    /// Receive the repository snapshot (`WorkspaceEvent.repos`); the daemon watches the
    /// panes' repositories while this client is connected.
    #[uniffi(default = true)]
    pub repo_status: bool,
}

impl std::fmt::Debug for ClientConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClientConfig")
            .field("secret_key", &"<redacted>")
            .field("relay", &self.relay)
            .field("mirror_vt", &self.mirror_vt)
            .field("repo_status", &self.repo_status)
            .finish()
    }
}

/// A fresh random 32-byte device key for [`ClientConfig::secret_key`].
#[uniffi::export]
pub fn generate_device_key() -> Bytes {
    client_core::ClientConfig::generate_key().into()
}

/// Something the UI should know about, from a daemon connection or an SSH pane.
///
/// Delivered in order, one call at a time per client or pane, on a Rust runtime thread (see
/// [`ClientEventListener`]).
#[derive(Debug, Clone, uniffi::Enum)]
pub enum ClientEvent {
    /// What the daemon said about itself, on every connection right before `connected`
    /// (or `incompatible` / `refused`); `nil` from daemons that predate it.
    DaemonInfo {
        /// The daemon's build and machine.
        info: Option<crate::upgrade::DaemonInfo>,
    },
    /// The daemon draws terminals in a format this core cannot read. Its owner is let in only
    /// to update it (`upgrade_daemon`); daemons that predate this refuse instead (`refused`
    /// follows).
    Incompatible {
        reason: String,
    },
    /// Connected (or reconnected) and authenticated; for an SSH pane, a shell is open.
    Connected {
        /// Daemon run (SSH pane: shell count); a change means resume state was invalid.
        epoch: u64,
        /// Whether this is a reconnect.
        resumed: bool,
    },
    /// The connection dropped; redialling.
    Disconnected {
        reason: String,
    },
    /// Refused (bad grant, version mismatch; SSH: auth or host key needs the user). No
    /// redial until `reconnect` (SSH: `SshSession::reconnect_now`).
    Refused {
        reason: String,
    },
    Sessions {
        sessions: Vec<SessionSummary>,
    },
    Attached {
        session_id: u64,
        /// How the daemon chose it.
        via: AttachVia,
        /// The session asked for, when it no longer exists.
        missing: Option<u64>,
    },
    /// Nothing to attach to (a guest whose session closed), or no session could be created.
    AttachFailed {
        code: OpErrorCode,
        message: String,
    },
    /// The attached session's layout.
    Layout {
        layout: SessionLayout,
    },
    PaneMeta {
        meta: PaneMeta,
    },
    PaneClosed {
        pane_id: u64,
    },
    /// What the program in a pane reports about itself (`ConnectOptions.program_status`);
    /// `None` once cleared, and for every known pane when the connection drops.
    ProgramStatus {
        pane_id: u64,
        status: Option<ProgramReport>,
    },
    /// A session's projects, after each `layout` from daemons with `projects`, on owner
    /// connections.
    Projects {
        projects: crate::types::DaemonProjects,
    },
    /// A session's floating windows, after each `layout` from daemons with `floats`.
    Floats {
        floats: crate::types::DaemonFloats,
    },
    /// A program in the pane wrote to the clipboard (OSC 52) after this device typed into it
    /// (`ConnectOptions.clipboard`): put it on this device's clipboard, local only, and say
    /// so. Programs can never read the clipboard.
    Clipboard {
        pane_id: u64,
        text: String,
    },
    /// Raw output to feed the pane's VT, continuing from the previous event.
    PaneBytes {
        pane_id: u64,
        /// Offset of `data[0]`.
        seq: u64,
        data: Bytes,
    },
    /// Replace the pane's VT with this Ghostty snapshot (READY section, decompressed).
    PaneSnapshot {
        pane_id: u64,
        /// Offset the snapshot reflects.
        seq: u64,
        data: Bytes,
    },
    /// Resize the pane's VT at this point of the stream.
    PaneResized {
        pane_id: u64,
        /// Offset of the resize.
        seq: u64,
        size: PaneSize,
    },
    /// Input `input_seq` is reflected at or after output offset `at_seq`.
    InputAck {
        pane_id: u64,
        input_seq: u64,
        /// Output offset.
        at_seq: u64,
    },
    EchoHint {
        hint: EchoHint,
    },
    /// An agent event as JSON.
    AgentEvent {
        pane_id: u64,
        json: String,
    },
    /// The result of [`DaemonClient::op`].
    OpResult {
        /// The id `op` returned.
        op_id: u64,
        outcome: OpOutcome,
    },
    /// Older scrollback (Ghostty snapshot history records) from
    /// [`DaemonClient::fetch_history`].
    PaneHistory {
        pane_id: u64,
        /// `seq` of the snapshot the records extend.
        snapshot_seq: u64,
        /// The records, decompressed.
        data: Bytes,
        /// Rows the Rust mirror gained (0 without a mirror).
        rows: u64,
        /// No older history.
        done: bool,
    },
    /// The daemon dropped the history of the pane's snapshot; fetch again after the next.
    PaneHistoryGone {
        pane_id: u64,
    },
    /// A command started or finished in the attached session.
    CommandMark {
        mark: CommandMark,
    },
    /// A long command finished while no client showed its pane.
    CommandFinishedUnseen {
        mark: CommandMark,
    },
    /// The answer to [`DaemonClient::search`]: `page` or `error`.
    SearchResult {
        /// The id `search` returned.
        req_id: u64,
        pane_id: u64,
        page: Option<SearchPage>,
        error: Option<RpcError>,
    },
    /// The answer to [`DaemonClient::links`]: `links` or `error`.
    Links {
        /// The id `links` returned.
        req_id: u64,
        pane_id: u64,
        /// What was found.
        links: Option<Links>,
        error: Option<RpcError>,
    },
    /// The answer to [`DaemonClient::commands`]: `commands` or `error`.
    Commands {
        /// The id `commands` returned.
        req_id: u64,
        pane_id: u64,
        commands: Option<CommandList>,
        error: Option<RpcError>,
    },
    /// The answer to [`DaemonClient::command_output`]: `output` or `error`.
    CommandOutput {
        /// The id `command_output` returned.
        req_id: u64,
        pane_id: u64,
        output: Option<CommandOutput>,
        error: Option<RpcError>,
    },
    PaneSizing {
        state: PaneSizing,
    },
}

fn split<T, U: From<T>>(r: Result<T, proto::RpcError>) -> (Option<U>, Option<RpcError>) {
    match r {
        Ok(value) => (Some(value.into()), None),
        Err(error) => (None, Some(error.into())),
    }
}

impl From<client_core::ClientEvent> for ClientEvent {
    fn from(client_event: client_core::ClientEvent) -> Self {
        use client_core::ClientEvent as E;
        match client_event {
            E::DaemonInfo { info } => Self::DaemonInfo {
                info: info.map(Into::into),
            },
            E::Incompatible { reason } => Self::Incompatible { reason },
            E::Connected { epoch, resumed } => Self::Connected { epoch, resumed },
            E::Disconnected { reason } => Self::Disconnected { reason },
            E::Refused { reason } => Self::Refused { reason },
            E::Sessions { sessions } => Self::Sessions {
                sessions: sessions.into_iter().map(Into::into).collect(),
            },
            E::Attached {
                session_id,
                via,
                missing,
            } => Self::Attached {
                session_id: session_id.0,
                via: via.into(),
                missing: missing.map(|s| s.0),
            },
            E::AttachFailed { code, message } => Self::AttachFailed {
                code: code.into(),
                message,
            },
            E::Layout { layout } => Self::Layout {
                layout: layout.into(),
            },
            E::PaneMeta { meta } => Self::PaneMeta { meta: meta.into() },
            E::PaneSizing { state } => Self::PaneSizing {
                state: state.into(),
            },
            E::PaneClosed { pane_id } => Self::PaneClosed { pane_id: pane_id.0 },
            E::Clipboard { pane_id, text } => Self::Clipboard {
                pane_id: pane_id.0,
                text,
            },
            E::ProgramStatus { pane_id, status } => Self::ProgramStatus {
                pane_id: pane_id.0,
                status: status.map(Into::into),
            },
            E::Projects { projects } => Self::Projects {
                projects: projects.into(),
            },
            E::Floats { floats } => Self::Floats {
                floats: floats.into(),
            },
            E::PaneBytes { pane_id, seq, data } => Self::PaneBytes {
                pane_id: pane_id.0,
                seq,
                data: data.into(),
            },
            E::PaneSnapshot { pane_id, seq, data } => Self::PaneSnapshot {
                pane_id: pane_id.0,
                seq,
                data: data.into(),
            },
            E::PaneResized { pane_id, seq, size } => Self::PaneResized {
                pane_id: pane_id.0,
                seq,
                size: size.into(),
            },
            E::InputAck {
                pane_id,
                input_seq,
                at_seq,
            } => Self::InputAck {
                pane_id: pane_id.0,
                input_seq,
                at_seq,
            },
            E::EchoHint { hint } => Self::EchoHint { hint: hint.into() },
            E::AgentEvent { pane_id, json } => Self::AgentEvent {
                pane_id: pane_id.0,
                json,
            },
            E::OpResult { op_id, outcome } => Self::OpResult {
                op_id,
                outcome: outcome.into(),
            },
            E::PaneHistory {
                pane_id,
                snapshot_seq,
                data,
                rows,
                done,
            } => Self::PaneHistory {
                pane_id: pane_id.0,
                snapshot_seq,
                data: data.into(),
                rows,
                done,
            },
            E::PaneHistoryGone { pane_id } => Self::PaneHistoryGone { pane_id: pane_id.0 },
            E::CommandMark { mark } => Self::CommandMark { mark: mark.into() },
            E::CommandFinishedUnseen { mark } => Self::CommandFinishedUnseen { mark: mark.into() },
            E::SearchResult {
                req_id,
                pane_id,
                result,
            } => {
                let (page, error) = split(result);
                Self::SearchResult {
                    req_id,
                    pane_id: pane_id.0,
                    page,
                    error,
                }
            }
            E::Links {
                req_id,
                pane_id,
                result,
            } => {
                let (links, error) = split(result);
                Self::Links {
                    req_id,
                    pane_id: pane_id.0,
                    links,
                    error,
                }
            }
            E::Commands {
                req_id,
                pane_id,
                result,
            } => {
                let (commands, error) = split(result);
                Self::Commands {
                    req_id,
                    pane_id: pane_id.0,
                    commands,
                    error,
                }
            }
            E::CommandOutput {
                req_id,
                pane_id,
                result,
            } => {
                let (output, error) = split(result);
                Self::CommandOutput {
                    req_id,
                    pane_id: pane_id.0,
                    output,
                    error,
                }
            }
        }
    }
}

/// Receives [`ClientEvent`]s; implemented in Swift.
///
/// Called on a Rust runtime thread (named `gudo-core`), never the main thread, one event
/// at a time and in order per client or pane. Return quickly: hand the event to the main
/// actor or a renderer queue and return. Blocking here stalls the connection.
#[uniffi::export(foreign)]
pub trait ClientEventListener: Send + Sync {
    fn on_event(&self, event: ClientEvent);
}

/// Adapts the Swift listener to client-core's.
pub(crate) struct Forward(pub Arc<dyn ClientEventListener>);

impl client_core::ClientListener for Forward {
    fn on_event(&self, event: client_core::ClientEvent) {
        self.0.on_event(event.into());
    }
}

/// [`Forward`] for a [`DaemonClient`], which also watches the events its `async` helpers wait
/// for: op results ([`DaemonClient::perform`]) and agent states
/// ([`DaemonClient::launch_agent_pane`]). Every event still reaches Swift.
pub(crate) struct Tap {
    listener: Arc<dyn ClientEventListener>,
    /// Op ids someone awaits. Locked around sending the op, so the answer cannot overtake
    /// the registration.
    pub(crate) ops: Mutex<HashMap<u64, oneshot::Sender<OpOutcome>>>,
    /// The last agent status per pane (`None`: the pane runs no agent).
    pub(crate) agents: Mutex<HashMap<u64, Option<proto::AgentStatus>>>,
    /// Woken on every `PaneMeta`.
    pub(crate) meta_changed: tokio::sync::Notify,
}

impl Tap {
    fn new(listener: Arc<dyn ClientEventListener>) -> Arc<Self> {
        Arc::new(Self {
            listener,
            ops: Mutex::new(HashMap::new()),
            agents: Mutex::new(HashMap::new()),
            meta_changed: tokio::sync::Notify::new(),
        })
    }
}

impl client_core::ClientListener for Tap {
    fn on_event(&self, event: client_core::ClientEvent) {
        match &event {
            client_core::ClientEvent::OpResult { op_id, outcome } => {
                if let Some(tx) = lock(&self.ops).remove(op_id) {
                    let _ = tx.send(outcome.clone().into());
                }
            }
            client_core::ClientEvent::PaneMeta { meta } => {
                lock(&self.agents).insert(meta.pane_id.0, meta.agent.clone());
                self.meta_changed.notify_waiters();
            }
            _ => {}
        }
        self.listener.on_event(event.into());
    }
}

pub(crate) fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Counters, for diagnostics and tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ClientStats {
    /// Successful connections, the first included.
    pub connections: u64,
    pub snapshots: u64,
    /// `Bytes` frames received.
    pub byte_frames: u64,
}

/// A connection to one daemon, kept up for the object's lifetime (redials with backoff,
/// resumes followed panes). Releasing the last reference disconnects.
///
/// Every method returns at once and is safe to call from the main thread: requests are
/// queued for the network task, and answers arrive as [`ClientEvent`]s.
#[derive(uniffi::Object)]
pub struct DaemonClient {
    pub(crate) inner: Arc<client_core::Client>,
    pub(crate) tap: Arc<Tap>,
}

/// Connection settings beyond [`ClientConfig`]. `Debug` leaves the relay token out.
#[derive(Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct ConnectOptions {
    /// Extra CA certificates (DER) to trust for the daemon's self-hosted relays (a private
    /// CA; docs/RELAYS.md). The usual web roots stay trusted. Which relays to use comes from
    /// the ticket (`PairTicketInfo.relays`) unless `relay_urls` names the device's own.
    #[uniffi(default = [])]
    pub relay_ca_der: Vec<Bytes>,
    /// This device's own relays (self-hosted `iroh-relay` URLs), used instead of the ticket's
    /// for every daemon. Empty: follow the ticket. `RelayMode.disabled` and a local-only
    /// daemon still mean direct only.
    #[uniffi(default = [])]
    pub relay_urls: Vec<String>,
    /// The shared token for `relay_urls` (`Authorization: Bearer`).
    #[uniffi(default = None)]
    pub relay_auth_token: Option<String>,
    /// Show native password prompts (`AskpassListener`): the daemon sends this connection
    /// the askpass prompts of panes it may drive. Off for clients that cannot show them.
    #[uniffi(default = false)]
    pub askpass: bool,
    /// Open URLs programs in a pane ask for and run agents' browser tools
    /// (`BrowserListener`).
    #[uniffi(default = false)]
    pub browser: bool,
    /// Show what any program in a pane reports about itself (`ClientEvent::ProgramStatus`).
    #[uniffi(default = false)]
    pub program_status: bool,
    /// Copy what programs write to the clipboard (OSC 52) in panes this device typed into
    /// last (`ClientEvent::Clipboard`).
    #[uniffi(default = false)]
    pub clipboard: bool,
}

impl std::fmt::Debug for ConnectOptions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        client_core::ConnectOptions::from(self.clone()).fmt(f)
    }
}

impl From<ConnectOptions> for client_core::ConnectOptions {
    fn from(connect_options: ConnectOptions) -> Self {
        Self {
            relay_ca_der: connect_options
                .relay_ca_der
                .into_iter()
                .map(Into::into)
                .collect(),
            relay_urls: connect_options.relay_urls,
            relay_auth_token: connect_options.relay_auth_token.filter(|t| !t.is_empty()),
            askpass: connect_options.askpass,
            browser: connect_options.browser,
            program_status: connect_options.program_status,
            clipboard: connect_options.clipboard,
            extra_caps: proto::Caps::EMPTY,
        }
    }
}

impl From<RelayMode> for client_core::RelayMode {
    fn from(mode: RelayMode) -> Self {
        match mode {
            RelayMode::Default => Self::Default,
            RelayMode::Disabled => Self::Disabled,
        }
    }
}

impl From<ClientConfig> for client_core::ClientConfig {
    fn from(config: ClientConfig) -> Self {
        Self {
            secret_key: config.secret_key.into(),
            relay: config.relay.into(),
            mirror_vt: config.mirror_vt,
            repo_status: config.repo_status,
        }
    }
}

impl DaemonClient {
    fn wrap(
        listener: Arc<dyn ClientEventListener>,
        start: impl FnOnce(Arc<Tap>) -> Result<client_core::Client, client_core::ClientError>,
    ) -> Result<Arc<Self>, ClientError> {
        let tap = Tap::new(listener);
        let inner = start(Arc::clone(&tap))?;
        Ok(Arc::new(Self {
            inner: Arc::new(inner),
            tap,
        }))
    }

    /// The core client, to move into a task on the runtime.
    pub(crate) fn core(&self) -> Arc<client_core::Client> {
        Arc::clone(&self.inner)
    }

    /// Sends `op` and waits (on the runtime) for its [`ClientEvent::OpResult`].
    pub(crate) async fn await_op(&self, op: proto::LayoutOp) -> Result<OpOutcome, WorkspaceError> {
        let (tx, rx) = oneshot::channel();
        let op_id = {
            // Registered before the op leaves, so the answer cannot overtake it.
            let mut ops = lock(&self.tap.ops);
            let op_id = self.inner.op(op);
            ops.insert(op_id, tx);
            op_id
        };
        let tap = Arc::clone(&self.tap);
        on_runtime(async move {
            match tokio::time::timeout(OP_TIMEOUT, rx).await {
                Ok(Ok(outcome)) => Ok(outcome),
                _ => {
                    lock(&tap.ops).remove(&op_id);
                    Err(WorkspaceError::Disconnected)
                }
            }
        })
        .await
    }
}

/// How long [`DaemonClient::perform`] waits for an op's answer.
const OP_TIMEOUT: Duration = Duration::from_secs(60);

#[uniffi::export]
impl DaemonClient {
    /// Starts connecting to the daemon named by `ticket` (`gudo://pair/…`); progress
    /// arrives as [`ClientEvent::Connected`] and friends.
    ///
    /// # Errors
    ///
    /// [`ClientError::Ticket`] for an unparsable ticket, [`ClientError::Key`] for a key that
    /// is not 32 bytes.
    #[uniffi::constructor]
    pub fn connect(
        ticket: String,
        config: ClientConfig,
        listener: Arc<dyn ClientEventListener>,
    ) -> Result<Arc<Self>, ClientError> {
        Self::connect_with(ticket, config, ConnectOptions::default(), listener)
    }

    /// [`connect`](Self::connect) with [`ConnectOptions`] (a private relay CA).
    ///
    /// # Errors
    ///
    /// As [`connect`](Self::connect).
    #[uniffi::constructor]
    pub fn connect_with(
        ticket: String,
        config: ClientConfig,
        options: ConnectOptions,
        listener: Arc<dyn ClientEventListener>,
    ) -> Result<Arc<Self>, ClientError> {
        Self::wrap(listener, |tap| {
            client_core::Client::connect_on_with(
                runtime().handle(),
                &ticket,
                config.into(),
                options.into(),
                tap,
            )
        })
    }

    /// Joins the daemon named by an invite (`gudo://join/…`, from a link or QR code) as a
    /// guest under the invite's grant; otherwise like [`connect`](Self::connect). Who this
    /// connection is arrives as `MultiplayerEvent.joined`.
    ///
    /// # Errors
    ///
    /// [`ClientError::Ticket`] for an unparsable invite, [`ClientError::Key`] for a bad key.
    #[uniffi::constructor]
    pub fn join(
        invite: String,
        config: ClientConfig,
        listener: Arc<dyn ClientEventListener>,
    ) -> Result<Arc<Self>, ClientError> {
        Self::join_with(invite, config, ConnectOptions::default(), listener)
    }

    /// [`join`](Self::join) with [`ConnectOptions`].
    ///
    /// # Errors
    ///
    /// As [`join`](Self::join).
    #[uniffi::constructor]
    pub fn join_with(
        invite: String,
        config: ClientConfig,
        options: ConnectOptions,
        listener: Arc<dyn ClientEventListener>,
    ) -> Result<Arc<Self>, ClientError> {
        Self::wrap(listener, |tap| {
            client_core::Client::join_on_with(
                runtime().handle(),
                &invite,
                config.into(),
                options.into(),
                tap,
            )
        })
    }

    /// Attaches to a session (`nil`: the most recent, created if none). Kept across
    /// reconnects.
    pub fn attach(&self, session_id: Option<u64>) {
        self.inner.attach(session_id.map(SessionId));
    }

    /// Asks for the session list ([`ClientEvent::Sessions`]).
    pub fn list_sessions(&self) {
        self.inner.list_sessions();
    }

    /// Sends a layout operation; returns the id its [`ClientEvent::OpResult`] carries.
    pub fn op(&self, op: LayoutOp) -> u64 {
        self.inner.op(op.into())
    }

    /// Starts following a pane's output. Kept across reconnects.
    pub fn subscribe(&self, pane_id: u64) {
        self.inner.subscribe(PaneId(pane_id));
    }

    pub fn unsubscribe(&self, pane_id: u64) {
        self.inner.unsubscribe(PaneId(pane_id));
    }

    /// Tells the daemon what is on screen (stream priorities and budgets).
    pub fn set_view(&self, focused: Option<u64>, visible: Vec<u64>) {
        self.inner.set_view(
            focused.map(PaneId),
            visible.into_iter().map(PaneId).collect(),
        );
    }

    /// This device's terminal theme: programs asking a pane it uses for its colors get these.
    /// Kept across reconnects.
    pub fn set_terminal_colors(&self, colors: TerminalColors) {
        self.inner.set_terminal_colors(colors.into());
    }

    /// This client's size for a pane; the PTY takes it when this client types.
    pub fn resize(&self, pane_id: u64, size: PaneSize) {
        self.inner.resize(PaneId(pane_id), size.into());
    }

    pub fn set_pane_activity(&self, pane_id: u64, activity: PaneActivity) {
        self.inner
            .set_pane_activity(PaneId(pane_id), activity.into());
    }

    pub fn claim_pane_size(&self, pane_id: u64) {
        self.inner.claim_pane_size(PaneId(pane_id));
    }

    pub fn set_size_policy(&self, pane_id: u64, policy: SizePolicy) {
        self.inner.set_size_policy(PaneId(pane_id), policy.into());
    }

    /// Sends raw input bytes (borrowed from Swift without a copy across the boundary).
    /// Queued while disconnected.
    pub fn send_input(&self, pane_id: u64, data: &[u8]) {
        self.inner.send_input(PaneId(pane_id), data.to_vec());
    }

    /// Sends encoded terminal reports without treating them as typing.
    pub fn send_generated_input(&self, pane_id: u64, data: &[u8]) {
        self.inner
            .send_generated_input(PaneId(pane_id), data.to_vec());
    }

    /// Sends a key event, encoded by the daemon for the program's keyboard modes.
    pub fn send_key(&self, pane_id: u64, key: KeyEvent) {
        self.inner.send_key(PaneId(pane_id), key.into());
    }

    /// Sends a mouse event, encoded by the daemon for the program's mouse mode.
    pub fn send_mouse(&self, pane_id: u64, event: MouseEvent) {
        self.inner.send_mouse(PaneId(pane_id), event.into());
    }

    /// Pastes text (bracketed if the program asked for it; control bytes neutralised).
    pub fn send_paste(&self, pane_id: u64, text: String) {
        self.inner.send_paste(PaneId(pane_id), text);
    }

    /// Searches a pane's scrollback; returns the id of the [`ClientEvent::SearchResult`].
    /// Pass the previous page's `next` as `cursor` for the next page.
    pub fn search(&self, pane_id: u64, query: SearchQuery, cursor: u32, limit: u32) -> u64 {
        self.inner
            .search(PaneId(pane_id), query.into(), cursor, limit)
    }

    /// Asks for links and paths on screen and in the last `commands` commands' output.
    pub fn links(&self, pane_id: u64, commands: u16) -> u64 {
        self.inner.links(PaneId(pane_id), commands)
    }

    /// Asks for a pane's shell-integration commands.
    pub fn commands(&self, pane_id: u64) -> u64 {
        self.inner.commands(PaneId(pane_id))
    }

    /// Asks for a command's output (`nil`: the last finished command).
    pub fn command_output(&self, pane_id: u64, command_id: Option<u64>) -> u64 {
        self.inner.command_output(PaneId(pane_id), command_id)
    }

    /// Fetches the next page (about `max_bytes`) of scrollback older than the pane's
    /// snapshot ([`ClientEvent::PaneHistory`]). `false` when there is nothing to fetch.
    pub fn fetch_history(&self, pane_id: u64, max_bytes: u32) -> bool {
        self.inner.fetch_history(PaneId(pane_id), max_bytes)
    }

    /// Launches a coding agent in a new pane split off `pane_id`; returns the op id.
    pub fn launch_agent(&self, pane_id: u64, agent: AgentKind, axis: Axis) -> u64 {
        self.inner
            .launch_agent(PaneId(pane_id), agent.into(), axis.into())
    }

    /// Answers an agent's approval request.
    pub fn decide(&self, request_id: u64, option_id: u32) {
        self.inner
            .decide(RequestId(request_id), OptionId(option_id));
    }

    /// What the program in a pane last reported about itself, if anything.
    pub fn program_status(&self, pane_id: u64) -> Option<ProgramReport> {
        self.inner.program_status(PaneId(pane_id)).map(Into::into)
    }

    /// Visible text of a followed pane (needs the Rust mirror).
    pub fn pane_text(&self, pane_id: u64) -> Option<String> {
        self.inner.pane_text(PaneId(pane_id))
    }

    /// Text of a followed pane including the scrollback the mirror holds.
    pub fn pane_text_all(&self, pane_id: u64) -> Option<String> {
        self.inner.pane_text_all(PaneId(pane_id))
    }

    /// Scrollback rows the mirror holds.
    pub fn pane_scrollback_rows(&self, pane_id: u64) -> Option<u64> {
        self.inner
            .pane_scrollback_rows(PaneId(pane_id))
            .map(|n| n as u64)
    }

    /// A Ghostty snapshot of the mirror, to paint before the network is up.
    pub fn pane_snapshot(&self, pane_id: u64) -> Option<Bytes> {
        self.inner.pane_snapshot(PaneId(pane_id)).map(Into::into)
    }

    /// The mirror as VT sequences that redraw the visible screen.
    pub fn pane_vt(&self, pane_id: u64) -> Option<String> {
        self.inner.pane_vt(PaneId(pane_id))
    }

    /// Output applied so far for a pane.
    pub fn pane_seq(&self, pane_id: u64) -> Option<u64> {
        self.inner.pane_seq(PaneId(pane_id))
    }

    /// Drops the connection and redials now (network change, app foregrounded).
    pub fn reconnect(&self) {
        self.inner.reconnect();
    }

    /// Changes how the daemon is reached (the app's relay settings changed): `relay` and the
    /// relay parts of `options` (`askpass` and `browser` stay as connected). Redials on a new endpoint;
    /// followed panes resume as after any reconnect.
    pub fn set_relays(&self, relay: RelayMode, options: ConnectOptions) {
        self.inner.set_relays(relay.into(), &options.into());
    }

    /// The device's network changed: a live connection moves to a working path (its streams
    /// survive); without one the client redials now.
    pub fn network_changed(&self) {
        self.inner.network_changed();
    }

    /// Checks the live connection with a ping (app foregrounded, input that got no answer);
    /// a link that does not answer in a few seconds is dropped and redialled, which arrives as
    /// `Disconnected`. Returns at once.
    pub fn probe(&self) {
        self.inner.probe();
    }

    /// Drops the connection and stays offline until [`reconnect`](Self::reconnect),
    /// keeping all resume state (app suspended).
    pub fn suspend(&self) {
        self.inner.suspend();
    }

    /// Forwards `127.0.0.1:local_port` here to `localhost:remote_port` on the daemon's
    /// host; returns the bound port (`0` picks one).
    ///
    /// # Errors
    ///
    /// [`ClientError::Io`] if the port cannot be bound.
    pub fn forward_port(&self, local_port: u16, remote_port: u16) -> Result<u16, ClientError> {
        Ok(self.inner.forward_port(local_port, remote_port)?)
    }

    /// Listens on `127.0.0.1:local_port` here (`0` picks a port) and tunnels every accepted
    /// connection, each on its own stream, to `target` on the daemon's host (a TCP port or a
    /// Unix socket). Returns the bound port. Survives reconnects; stop it with
    /// [`stop_forward`](Self::stop_forward).
    ///
    /// # Errors
    ///
    /// [`ClientError::Io`] if the port cannot be bound.
    pub fn forward(&self, local_port: u16, target: ForwardTarget) -> Result<u16, ClientError> {
        Ok(self.inner.forward(local_port, target.into())?)
    }

    /// Stops the forward on `local_port` (open connections run until they close). Returns
    /// whether there was one.
    pub fn stop_forward(&self, local_port: u16) -> bool {
        self.inner.stop_forward(local_port)
    }

    /// The running forwards (from [`forward`](Self::forward)), by local port.
    pub fn forwards(&self) -> Vec<ForwardInfo> {
        let mut all: Vec<_> = self
            .inner
            .forwards()
            .into_iter()
            .map(|(local_port, target)| ForwardInfo {
                local_port,
                target: target.into(),
            })
            .collect();
        all.sort_by_key(|forward| forward.local_port);
        all
    }

    /// Sends a layout operation and waits for its outcome (the [`ClientEvent::OpResult`]
    /// still reaches the listener).
    ///
    /// # Errors
    ///
    /// [`WorkspaceError::Disconnected`] if no answer came within a minute.
    pub async fn perform(&self, op: LayoutOp) -> Result<OpOutcome, WorkspaceError> {
        self.await_op(op.into()).await
    }
    pub fn stats(&self) -> ClientStats {
        let stats = self.inner.stats();
        ClientStats {
            connections: stats.connections,
            snapshots: stats.snapshots,
            byte_frames: stats.byte_frames,
        }
    }
}

/// Timings from [`bench_pane_bytes`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PaneBytesBench {
    pub events: u32,
    /// Nanoseconds to deliver them all through the listener: payload allocation and copy,
    /// conversion, the call into Swift and whatever the listener does.
    pub ffi_ns: u64,
    /// Nanoseconds for the same work without the listener call (allocation, copy and
    /// conversion only), to subtract.
    pub rust_ns: u64,
}

/// Diagnostics: delivers `count` synthetic `PaneBytes` events of `size` bytes each to
/// `listener` on the calling thread, the way a connection does, and times it. Measures the
/// per-event cost of the FFI boundary (docs/APPLE-FFI.md).
#[uniffi::export]
pub fn bench_pane_bytes(
    listener: Arc<dyn ClientEventListener>,
    count: u32,
    size: u32,
) -> PaneBytesBench {
    let template = vec![b'x'; size as usize];
    let event = |seq: u64| client_core::ClientEvent::PaneBytes {
        pane_id: PaneId(1),
        seq,
        data: template.clone(),
    };
    let start = Instant::now();
    for seq in 0..u64::from(count) {
        std::hint::black_box(ClientEvent::from(event(seq)));
    }
    let rust = start.elapsed();
    let forward = Forward(listener);
    let start = Instant::now();
    for seq in 0..u64::from(count) {
        client_core::ClientListener::on_event(&forward, event(seq));
    }
    let ffi = start.elapsed();
    let nanos = |d: Duration| u64::try_from(d.as_nanos()).unwrap_or(u64::MAX);
    PaneBytesBench {
        events: count,
        ffi_ns: nanos(ffi),
        rust_ns: nanos(rust),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connect_options_carry_the_devices_relays() {
        let options = ConnectOptions {
            relay_ca_der: vec![vec![0x30, 0x82].into()],
            relay_urls: vec!["https://relay.example.com".into()],
            relay_auth_token: Some("secret".into()),
            askpass: true,
            browser: true,
            program_status: true,
            clipboard: true,
        };
        let core = client_core::ConnectOptions::from(options);
        assert!(core.clipboard);
        assert_eq!(core.extra_caps, proto::Caps::EMPTY);
        assert_eq!(core.relay_ca_der, vec![vec![0x30, 0x82]]);
        assert_eq!(core.relay_urls, vec!["https://relay.example.com"]);
        assert_eq!(core.relay_auth_token.as_deref(), Some("secret"));
        assert!(core.askpass && core.browser && core.program_status);
        // An empty token field means no token.
        let core = client_core::ConnectOptions::from(ConnectOptions {
            relay_auth_token: Some(String::new()),
            ..ConnectOptions::default()
        });
        assert_eq!(core.relay_auth_token, None);
        assert!(core.relay_urls.is_empty());
    }

    #[test]
    fn debug_output_leaves_secrets_out() {
        let config = ClientConfig {
            secret_key: vec![0xAB; 32].into(),
            relay: RelayMode::Default,
            mirror_vt: true,
            repo_status: true,
        };
        assert!(!format!("{config:?}").contains("171"));
        let options = ConnectOptions {
            relay_auth_token: Some("relay-token-value".into()),
            ..ConnectOptions::default()
        };
        assert!(!format!("{options:?}").contains("relay-token-value"));
        let key = crate::ssh_api::generate_ed25519_key("test".into()).unwrap();
        let text = format!("{key:?}");
        assert!(!text.contains("PRIVATE KEY"), "private key in {text}");
        assert!(text.contains(&key.fingerprint));

        let seal = crate::notify::PushSealKey {
            secret: vec![0xAB; 32].into(),
            public_key: vec![1; 32].into(),
        };
        let offer = crate::notify::PushActionOffer {
            token: "action-token-value".into(),
            approve: "Approve".into(),
            deny: "Deny".into(),
            expires_ms: 0,
        };
        let invite = crate::mp::CreatedInvite {
            link: "gudo://join/invite-secret".into(),
            qr_payload: "GUDO://JOIN/INVITE-SECRET".into(),
            grant_id: "g".into(),
            expires_ms: None,
        };
        let pairing = crate::mp::PairingCode {
            link: "gudo://pair/pairing-secret".into(),
            qr_payload: "GUDO://PAIR/PAIRING-SECRET".into(),
            expires_ms: 0,
        };
        let editor = crate::ws_types::EditorInstance {
            kind: crate::ws_types::EditorKind::VsCode,
            folder: "/srv".into(),
            port: 1,
            token: "editor-token-value".into(),
            url_path: "/?tkn=editor-token-value".into(),
            pid: 1,
            started_at_ms: 0,
        };
        let registration = crate::ws_types::PushRegistration {
            cap: "relay-cap-value".into(),
            seal_key: vec![1; 32].into(),
            relay_url: None,
            prefs: crate::ws_types::PushPrefs {
                approvals: true,
                blocked: true,
                done: true,
                failed: true,
                commands: true,
            },
            activity_cap: Some("activity-cap-value".into()),
        };
        let text = format!("{seal:?} {offer:?} {invite:?} {pairing:?} {editor:?} {registration:?}");
        for secret in [
            "171",
            "action-token-value",
            "invite-secret",
            "INVITE-SECRET",
            "pairing-secret",
            "PAIRING-SECRET",
            "editor-token-value",
            "relay-cap-value",
            "activity-cap-value",
        ] {
            assert!(!text.contains(secret), "{secret} in {text}");
        }
    }

    #[test]
    fn program_status_reaches_swift_whole_and_cleared() {
        let report = proto::ProgramReport {
            state: proto::ProgramState::Blocked,
            kind: Some(proto::ProgramKind::Question),
            app: Some("pi".into()),
            message: Some("Which framework?".into()),
            progress: Some(40),
        };
        let event = ClientEvent::from(client_core::ClientEvent::ProgramStatus {
            pane_id: PaneId(7),
            status: Some(report),
        });
        let ClientEvent::ProgramStatus {
            pane_id: 7,
            status: Some(status),
        } = event
        else {
            panic!("{event:?}");
        };
        assert_eq!(
            status,
            ProgramReport {
                state: crate::types::ProgramState::Blocked,
                kind: Some(crate::types::ProgramKind::Question),
                app: Some("pi".into()),
                message: Some("Which framework?".into()),
                progress: Some(40),
            }
        );
        let cleared = ClientEvent::from(client_core::ClientEvent::ProgramStatus {
            pane_id: PaneId(7),
            status: None,
        });
        assert!(matches!(
            cleared,
            ClientEvent::ProgramStatus {
                pane_id: 7,
                status: None
            }
        ));
    }
}
