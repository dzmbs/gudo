//! Platform-neutral client core: dial a daemon by pairing ticket, attach to a session, follow
//! panes with seq/ack, resume after disconnects, forward ports.
//!
//! The API is shaped for a UniFFI binding: a [`Client`] handle
//! with synchronous, non-blocking methods taking owned values, and a [`ClientListener`]
//! callback receiving [`ClientEvent`]s on the core's own threads. No generics or lifetimes
//! cross the boundary. The client owns its tokio runtime, so it can be driven from Swift or
//! from any thread.
//!
//! Reconnection never gives up: after a drop the client redials with backoff (capped at
//! 5 s; [`Client::reconnect`] redials at once, e.g. on an iOS network change). On reconnect
//! `Hello` carries a resume point per followed pane, focused first, and the daemon continues
//! each from its ring buffer or sends a snapshot.
//!
//! Hosts without the daemon get [`SshPane`]s: a PTY over plain SSH (the [`ssh`] crate)
//! delivering the same pane events, so the app renders both alike (docs/SSH.md §4).
//!
//! # Examples
//!
//! ```no_run
//! use client_core::{Client, ClientConfig, EventQueue};
//!
//! # fn demo(ticket: &str) -> Result<(), client_core::ClientError> {
//! let (listener, mut events) = EventQueue::channel();
//! let client = Client::connect(ticket, ClientConfig::new(ClientConfig::generate_key()), listener)?;
//! client.attach(None);
//! # Ok(())
//! # }
//! ```

mod approvals;
mod artifacts;
mod askpass;
mod assist;
mod browser;
mod conn;
pub use conn::{PROBE_DEADLINE, PROBE_SLOW_DEADLINE};
mod chat_send;
pub mod knock;
mod listen;
mod mirror;
mod mp;
mod outgoing;
mod peer;
pub mod push;
mod resend;
pub mod script;
mod ssh_pane;
mod timeline_diff;
mod upgrade;
pub mod vscode;
mod workspace;

use std::collections::HashMap;
use std::net::TcpListener as StdTcpListener;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use iroh::endpoint::Connection;
use proto::{
    AgentKind, AttachVia, ClientCtl, CommandList, CommandMark, CommandOutput, Decide, EchoHintAt,
    FullKeyEvent, InputPayload, LayoutOp, Links, MouseEvent, OpError, OpOutcome, PaneId, PaneMeta,
    PaneSize, RpcError, SearchPage, SearchQuery, Seq, SessionId, SessionLayout, SessionSummary,
    Ticket,
};
use tokio::runtime::Runtime;
use tokio::sync::{Notify, mpsc, watch};

use crate::mirror::Mirror;
use crate::outgoing::Outgoing;

pub use approvals::{ApprovalEvent, ApprovalEventQueue, ApprovalListener};
pub use artifacts::{ArtifactEventQueue, ArtifactListener, ArtifactUpdate};
pub use askpass::{AskpassEvent, AskpassEventQueue, AskpassListener};
pub use assist::{AssistEvent, AssistEventQueue, AssistListener};
pub use browser::{BrowserListener, BrowserPushQueue};
pub use drawing;
pub use grants::{self, GrantSpec};
pub use mp::{MultiplayerEvent, MultiplayerEventQueue, MultiplayerListener, now_millis};
pub use peer::MIN_INTERVAL as PRESENCE_INTERVAL;
pub use proto;
pub use ssh;
pub use ssh_pane::{RESTART_MARKER, SshPane, SshPaneOptions, ssh_runtime};
pub use upgrade::{DaemonBuild, UpgradeError};
pub use workspace::{TransferProgress, WorkspaceEvent, WorkspaceEventQueue, WorkspaceListener};

/// Which relays the client's endpoint may use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RelayMode {
    /// n0's relays and address lookup.
    #[default]
    Default,
    /// Direct addresses only.
    Disabled,
}

/// Client settings. `Debug` leaves the device key out.
#[derive(Clone)]
pub struct ClientConfig {
    /// The device's Ed25519 secret key (32 bytes). Keep it in the Keychain; it identifies the
    /// device to every daemon it pairs with.
    pub secret_key: Vec<u8>,
    pub relay: RelayMode,
    /// Keep a libghostty-vt mirror of each followed pane (needed for [`Client::pane_text`]
    /// and [`Client::pane_snapshot`]). An app that feeds its own renderer's VT can turn this
    /// off; seq/ack and resume work either way.
    pub mirror_vt: bool,
    /// Ask for the repository snapshot ([`WorkspaceEvent::Repos`]): the daemon then watches
    /// the panes' repositories while this client is connected.
    pub repo_status: bool,
    /// How much the device's network can carry when the client starts; see
    /// [`Client::set_link`].
    pub link: proto::LinkClass,
}

impl std::fmt::Debug for ClientConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClientConfig")
            .field("secret_key", &"<redacted>")
            .field("relay", &self.relay)
            .field("mirror_vt", &self.mirror_vt)
            .field("repo_status", &self.repo_status)
            .field("link", &self.link)
            .finish()
    }
}

impl ClientConfig {
    /// Defaults: n0 relays, VT mirror on, no repository snapshot, a normal link.
    pub fn new(secret_key: Vec<u8>) -> Self {
        Self {
            secret_key,
            relay: RelayMode::Default,
            mirror_vt: true,
            repo_status: false,
            link: proto::LinkClass::Normal,
        }
    }

    /// A fresh random device key.
    pub fn generate_key() -> Vec<u8> {
        let mut key = vec![0; 32];
        getrandom::fill(&mut key).expect("the OS random source is available");
        key
    }
}

/// Connection settings beyond [`ClientConfig`] (kept separate so that struct stays as the
/// FFI layer builds it). `Debug` leaves the relay token out.
#[derive(Clone, Default)]
pub struct ConnectOptions {
    /// Extra CA certificates (DER) to trust for the daemon's self-hosted relays, e.g. a
    /// private CA. The usual web roots stay trusted.
    pub relay_ca_der: Vec<Vec<u8>>,
    /// This device's own relays (self-hosted `iroh-relay` URLs), used for every daemon instead
    /// of the ones its ticket names. Empty: follow the ticket. A local-only daemon
    /// (`TicketRelays::Disabled`) and [`RelayMode::Disabled`] still mean direct only.
    pub relay_urls: Vec<String>,
    /// The shared token for [`relay_urls`](Self::relay_urls) (sent as `Authorization: Bearer`).
    pub relay_auth_token: Option<String>,
    /// Show native password prompts: announce `Caps::ASKPASS`, so the daemon sends this
    /// connection the askpass prompts of panes it may drive (see [`AskpassListener`]).
    /// Leave it off in clients that cannot show them: the helper then asks on the terminal.
    pub askpass: bool,
    /// Open URLs programs in a pane ask for and run agents' browser tools: announce
    /// `Caps::BROWSER` (see [`BrowserListener`]).
    pub browser: bool,
    /// Show what any program in a pane reports about itself: announce
    /// `Caps::PROGRAM_STATUS`, so the daemon sends [`ClientEvent::ProgramStatus`].
    pub program_status: bool,
    /// Copy what programs write to the clipboard (OSC 52) in panes this device typed into
    /// last: announce `Caps::CLIPBOARD`, so the daemon sends [`ClientEvent::Clipboard`].
    pub clipboard: bool,
    /// Capabilities announced on top of the ones above, whatever the rules for guests (tests
    /// that play a client ignoring them).
    #[doc(hidden)]
    pub extra_caps: proto::Caps,
}

impl std::fmt::Debug for ConnectOptions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectOptions")
            .field("relay_ca_der", &self.relay_ca_der.len())
            .field("relay_urls", &self.relay_urls)
            .field(
                "relay_auth_token",
                &self.relay_auth_token.as_ref().map(|_| "<redacted>"),
            )
            .field("askpass", &self.askpass)
            .field("browser", &self.browser)
            .field("program_status", &self.program_status)
            .field("clipboard", &self.clipboard)
            .finish_non_exhaustive()
    }
}

/// Errors from the client API.
#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    /// The ticket could not be parsed.
    #[error("bad ticket: {0}")]
    Ticket(#[from] proto::TicketError),
    /// The secret key is not 32 bytes.
    #[error("the device key must be 32 bytes")]
    Key,
    /// A local I/O error (runtime, socket).
    #[error("{0}")]
    Io(#[from] std::io::Error),
}

/// Something the UI should know about. Delivered in order, on the core's threads.
#[derive(Debug, Clone)]
pub enum ClientEvent {
    /// What the daemon said about itself, sent on every connection right before
    /// [`ClientEvent::Connected`] (or [`ClientEvent::Incompatible`] / [`ClientEvent::Refused`]).
    /// `None` from daemons built before [`proto::DaemonInfo`] existed.
    DaemonInfo {
        /// The daemon's build and machine.
        info: Option<proto::DaemonInfo>,
    },
    /// The daemon encodes a terminal snapshot format this client cannot decode. It let this
    /// owner device in only to upgrade it ([`Client::upgrade_daemon`]); nothing else works on
    /// this connection. Daemons from before [`proto::DaemonInfo`] refuse instead
    /// ([`ClientEvent::Refused`], preceded by this event).
    Incompatible {
        reason: String,
    },
    /// Connected (or reconnected) and authenticated.
    Connected {
        /// Daemon run; a change means every pane's resume state was invalid.
        epoch: u64,
        /// Whether this is a reconnect.
        resumed: bool,
    },
    /// The connection dropped; the client is redialling.
    Disconnected {
        reason: String,
    },
    /// The daemon refused the connection (bad grant, version mismatch). The client stops
    /// redialling until [`Client::reconnect`].
    Refused {
        reason: String,
    },
    /// The session list.
    Sessions {
        sessions: Vec<SessionSummary>,
    },
    /// Attached to a session.
    Attached {
        session_id: SessionId,
        /// How the daemon chose it ([`AttachVia::Requested`] from daemons that do not say).
        via: AttachVia,
        /// The session asked for, when it no longer exists.
        missing: Option<SessionId>,
    },
    /// The daemon had nothing to attach to (a guest whose session closed) or could not create
    /// a session. Daemons without `AttachResult` report it as a failed op 0, translated here.
    AttachFailed {
        /// Machine-readable reason.
        code: OpError,
        message: String,
    },
    /// The attached session's layout.
    Layout {
        layout: SessionLayout,
    },
    /// A pane's metadata.
    PaneMeta {
        meta: PaneMeta,
    },
    /// A pane closed.
    PaneClosed {
        pane_id: PaneId,
    },
    /// What the program in a pane reports about itself (OSC 7501 or `status_set`), with
    /// [`ConnectOptions::program_status`]. `None` once cleared, and for every known pane when
    /// the connection drops. Also kept: [`Client::program_status`].
    ProgramStatus {
        pane_id: PaneId,
        status: Option<proto::ProgramReport>,
    },
    /// A session's projects, after each [`ClientEvent::Layout`] from daemons with
    /// `DaemonFeatures::PROJECTS`, when this connection has the owner role.
    Projects {
        /// The session's projects, as far as this connection sees.
        projects: proto::SessionProjects,
    },
    /// A session's floating windows, after each [`ClientEvent::Layout`] from daemons with
    /// `DaemonFeatures::FLOATS`.
    Floats {
        /// The session's floats, as far as this connection sees.
        floats: proto::SessionFloats,
    },
    /// Every command restored panes offer to run again (a reboot stopped them), from daemons
    /// with `MoreDaemonFeatures::RUN_AGAIN`, on owner devices: the whole list each time.
    /// Running one is typing it ([`Client::run_again`]).
    RunAgainOffers {
        offers: Vec<proto::RunAgainOffer>,
    },
    /// A program in the pane wrote to the clipboard (OSC 52) after this device typed into it,
    /// with [`ConnectOptions::clipboard`]. Put it on this device's clipboard, local only, and
    /// say so.
    Clipboard {
        pane_id: PaneId,
        text: String,
    },
    /// Raw output to feed the pane's VT, in order, continuing from the previous event.
    PaneBytes {
        pane_id: PaneId,
        /// Offset of `data[0]`.
        seq: u64,
        data: Vec<u8>,
    },
    /// Replace the pane's VT with this Ghostty snapshot (READY section, decompressed).
    PaneSnapshot {
        pane_id: PaneId,
        /// Offset the snapshot reflects.
        seq: u64,
        data: Vec<u8>,
    },
    /// The daemon streams this pane from where the client left off, on this connection.
    PaneStreaming {
        pane_id: PaneId,
    },
    /// Resize the pane's VT here in the stream.
    PaneResized {
        pane_id: PaneId,
        /// Offset of the resize.
        seq: u64,
        size: PaneSize,
    },
    /// Input `input_seq` is reflected at or after `at_seq`.
    InputAck {
        pane_id: PaneId,
        input_seq: u64,
        /// Output offset.
        at_seq: u64,
    },
    /// Echo prediction facts for a pane.
    EchoHint {
        hint: EchoHintAt,
    },
    /// An agent event (JSON).
    AgentEvent {
        pane_id: PaneId,
        json: String,
    },
    /// The result of [`Client::op`].
    OpResult {
        /// The id `op` returned.
        op_id: u64,
        outcome: OpOutcome,
    },
    /// Older scrollback for a pane, from [`Client::fetch_history`]: Ghostty snapshot history
    /// records continuing the pane's last snapshot (feed them to the snapshot's streaming
    /// decoder). The VT mirror, if on, has already prepended them.
    PaneHistory {
        pane_id: PaneId,
        /// `seq` of the snapshot the records extend.
        snapshot_seq: u64,
        /// The records, decompressed.
        data: Vec<u8>,
        /// Rows the mirror gained (0 without a mirror).
        rows: u64,
        /// There is no older history.
        done: bool,
    },
    /// The daemon no longer has the history of the pane's snapshot; it arrives again after
    /// the next snapshot.
    PaneHistoryGone {
        pane_id: PaneId,
    },
    /// A shell-integration command started or finished in the attached session.
    CommandMark {
        mark: CommandMark,
    },
    /// A long command finished while no client was showing its pane (any session).
    CommandFinishedUnseen {
        mark: CommandMark,
    },
    /// The answer to [`Client::search`].
    SearchResult {
        /// The id `search` returned.
        req_id: u64,
        pane_id: PaneId,
        /// One page of matches.
        result: Result<SearchPage, RpcError>,
    },
    /// The answer to [`Client::links`].
    Links {
        /// The id `links` returned.
        req_id: u64,
        pane_id: PaneId,
        /// What was found.
        result: Result<Links, RpcError>,
    },
    /// The answer to [`Client::commands`].
    Commands {
        /// The id `commands` returned.
        req_id: u64,
        pane_id: PaneId,
        result: Result<CommandList, RpcError>,
    },
    /// The answer to [`Client::command_output`].
    CommandOutput {
        /// The id `command_output` returned.
        req_id: u64,
        pane_id: PaneId,
        result: Result<CommandOutput, RpcError>,
    },
    PaneSizing {
        state: proto::PaneSizing,
    },
}

/// Receives [`ClientEvent`]s. Must return quickly; it runs on the network threads.
pub trait ClientListener: Send + Sync {
    /// Called once per event, in order.
    fn on_event(&self, event: ClientEvent);
}

/// A [`ClientListener`] that queues events for async Rust consumers (the `gudo` CLI, tests).
pub struct EventQueue {
    tx: mpsc::UnboundedSender<ClientEvent>,
}

impl EventQueue {
    /// Returns the listener and the receiving end.
    pub fn channel() -> (
        Arc<dyn ClientListener>,
        mpsc::UnboundedReceiver<ClientEvent>,
    ) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Self { tx }), rx)
    }
}

impl ClientListener for EventQueue {
    fn on_event(&self, event: ClientEvent) {
        let _ = self.tx.send(event);
    }
}

/// Counters, for diagnostics and tests.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ClientStats {
    /// Successful connections, the first included.
    pub connections: u64,
    pub snapshots: u64,
    /// `Bytes` frames received.
    pub byte_frames: u64,
}

/// What the client wants, replayed on every reconnect.
#[derive(Debug, Default)]
pub(crate) struct Wanted {
    pub session: Option<SessionId>,
    pub attach_requested: bool,
    pub subscribed: Vec<PaneId>,
    pub focus: Option<PaneId>,
    pub visible: Vec<PaneId>,
    pub sizes: HashMap<PaneId, PaneSize>,
    pub activities: HashMap<PaneId, proto::PaneActivity>,
    pub colors: Option<proto::TerminalColors>,
}

pub(crate) struct Inner {
    pub ticket: Ticket,
    /// The daemon's relays, from the ticket's extras (self-hosted, none, or the default).
    pub relays: proto::TicketRelays,
    pub options: ConnectOptions,
    pub config: ClientConfig,
    /// How to reach the daemon now: `config.relay` and the relay parts of `options` at first,
    /// replaced by [`Client::set_relays`].
    pub net: Mutex<(RelayMode, ConnectOptions)>,
    /// `net` changed: bind a new endpoint before the next dial.
    pub rebind: AtomicBool,
    pub listener: Arc<dyn ClientListener>,
    pub wanted: Mutex<Wanted>,
    pub mirrors: Mutex<HashMap<PaneId, Mirror>>,
    /// Held while one stream applies a pane's frame and hands it to the app, so a pane being
    /// followed on two streams at once still reaches the app in the order it was applied.
    pub pane_output_turns: Mutex<HashMap<PaneId, Arc<Mutex<()>>>>,
    /// The newest stream of each followed pane, to follow one again when its stream ends.
    pub(crate) pane_streams: Mutex<HashMap<PaneId, conn::NewestPaneStream>>,
    pub(crate) next_pane_stream: AtomicU64,
    pub(crate) outgoing: outgoing::OutgoingQueue,
    pub connection: Mutex<Option<Connection>>,
    pub endpoint: Mutex<Option<iroh::Endpoint>>,
    pub reconnect: Notify,
    /// Told to the daemon in each `Hello`.
    pub link: Mutex<proto::LinkClass>,
    pub skips_backoff: AtomicBool,
    pub is_dialing: AtomicBool,
    /// iroh forgets learned paths a minute after the last connection.
    pub last_direct_addresses: Mutex<Vec<std::net::SocketAddr>>,
    pub paused: Mutex<bool>,
    /// Bumped on each resume from [`Client::suspend`]: forward listeners bind again.
    pub resumed: watch::Sender<u64>,
    pub epoch: Mutex<Option<u64>>,
    pub resume_token: Mutex<Option<proto::ResumeToken>>,
    /// Input numbering across connections, and input to send again after a reconnect.
    pub(crate) input: Mutex<resend::InputLog>,
    pub paired: Mutex<bool>,
    pub next_op: AtomicU64,
    pub stats: Mutex<ClientStats>,
    /// Workspace requests in flight, pushes, forwards.
    pub ws: workspace::WsState,
    /// Multiplayer requests in flight, pushes, and the invite a guest joined with.
    pub mp: mp::MpState,
    /// Drawings and images: requests in flight, pushes, the scene cache.
    pub art: artifacts::ArtState,
    /// Input-assistance requests in flight, foreground and prompt pushes.
    pub assist: assist::AssistState,
    /// Askpass requests in flight, open and detected password prompts.
    pub askpass: askpass::AskpassState,
    /// Where browser pushes go.
    pub browser: browser::BrowserState,
    /// Approval extras in flight, open requests' extras, auto-approve rules.
    pub approvals: approvals::ApprovalState,
    /// Each pane's last program report.
    pub programs: Mutex<HashMap<PaneId, proto::ProgramReport>>,
    /// What the daemon said about itself on the last connection.
    pub daemon_info: Mutex<Option<proto::DaemonInfo>>,
    pub more_daemon_features: Mutex<proto::MoreDaemonFeatures>,
    /// The daemon's kitty image storage per pane and screen on the last connection, as it
    /// sent it (`ServerCtl::TerminalLimits`); `None` from daemons that do not.
    pub image_storage_bytes: Mutex<Option<u64>>,
    /// The last connection was for an upgrade only.
    pub incompatible: Mutex<bool>,
    /// The nonce of the last `Pong`, for [`Client::probe`].
    pub pong: watch::Sender<u64>,
    pub next_ping: AtomicU64,
}

/// How a client authenticates: as a paired device (pairing ticket) or a guest (invite).
pub(crate) enum Dial {
    Ticket(Ticket, proto::TicketRelays),
    Invite(proto::Invite),
}

/// Runs `work` on `runtime` and waits for it. Dropping the wait stops the work, so a caller
/// that gives up leaves nothing running (and holding the client) in the background.
pub(crate) async fn run_on<T: Send + 'static>(
    runtime: &tokio::runtime::Handle,
    work: impl std::future::Future<Output = T> + Send + 'static,
) -> Result<T, tokio::task::JoinError> {
    struct AbortOnDrop<T>(tokio::task::JoinHandle<T>);
    impl<T> Drop for AbortOnDrop<T> {
        fn drop(&mut self) {
            self.0.abort();
        }
    }
    let mut task = AbortOnDrop(runtime.spawn(work));
    (&mut task.0).await
}

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Inner {
    pub(crate) fn pane_output_turn(&self, pane_id: PaneId) -> Arc<Mutex<()>> {
        Arc::clone(lock(&self.pane_output_turns).entry(pane_id).or_default())
    }

    pub fn emit(&self, event: ClientEvent) {
        self.listener.on_event(event);
    }

    /// The connection, waiting up to `wait` while the client is between reconnects. `None` at
    /// once while suspended: no connection is coming.
    pub(crate) async fn connection_within(&self, wait: std::time::Duration) -> Option<Connection> {
        let waiting = async {
            loop {
                if *lock(&self.paused) {
                    return None;
                }
                if let Some(connection) = lock(&self.connection).clone() {
                    return Some(connection);
                }
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
        };
        tokio::time::timeout(wait, waiting).await.ok().flatten()
    }

    fn send(&self, ctl: ClientCtl) {
        self.queue(Outgoing::Ctl(ctl));
    }

    fn queue(&self, item: Outgoing) {
        let link = if lock(&self.connection).is_some() {
            outgoing::Link::Up
        } else {
            outgoing::Link::Down
        };
        self.outgoing
            .push(item, link, |control| self.request_is_live(control));
    }

    /// Whether anyone still waits for the answer to `control` (always, for what is not a
    /// request): a request whose caller gave up or timed out is never sent.
    pub(crate) fn request_is_live(&self, control: &ClientCtl) -> bool {
        match control {
            ClientCtl::Workspace { req_id, .. } => self.ws.awaits(*req_id),
            ClientCtl::Multiplayer { req_id, .. } => self.mp.awaits(*req_id),
            ClientCtl::Artifact { req_id, .. } => self.art.awaits(*req_id),
            ClientCtl::Assist { req_id, .. } => self.assist.awaits(*req_id),
            ClientCtl::Askpass { req_id, .. } => self.askpass.awaits(*req_id),
            ClientCtl::Approval { req_id, .. } => self.approvals.awaits(*req_id),
            _ => true,
        }
    }

    /// Whether the daemon of the current (or last) connection announced `feature`.
    pub(crate) fn daemon_has(&self, feature: proto::DaemonFeatures) -> bool {
        self.daemon_features().contains(feature)
    }

    pub(crate) fn daemon_features(&self) -> proto::DaemonFeatures {
        lock(&self.daemon_info)
            .as_ref()
            .map(|info| info.features)
            .unwrap_or_default()
    }
}

/// The most kitty image storage a client keeps per pane and screen, whatever its host sets:
/// four times the default. A pane's mirror holds this much per screen at worst, which a
/// phone with dozens of panes cannot multiply much further.
pub const MAX_IMAGE_STORAGE_BYTES: u64 = 256 << 20;

/// The kitty image storage a mirror keeps for a host that sent `host` (`None`: a daemon
/// from before `ServerCtl::TerminalLimits`, which keeps the default): the host's own, so the
/// mirror evicts exactly what the host evicts, up to [`MAX_IMAGE_STORAGE_BYTES`].
///
/// # Examples
///
/// ```
/// use client_core::{MAX_IMAGE_STORAGE_BYTES, image_storage_limit};
///
/// assert_eq!(image_storage_limit(None), 64 << 20);
/// assert_eq!(image_storage_limit(Some(128 << 20)), 128 << 20);
/// assert_eq!(image_storage_limit(Some(0)), 0);
/// assert_eq!(image_storage_limit(Some(4 << 30)), MAX_IMAGE_STORAGE_BYTES);
/// ```
pub fn image_storage_limit(host: Option<u64>) -> u64 {
    host.unwrap_or(ghostty_vt::KITTY_IMAGE_STORAGE_LIMIT)
        .min(MAX_IMAGE_STORAGE_BYTES)
}

/// A connection to one daemon. Dropping it disconnects.
pub struct Client {
    inner: Arc<Inner>,
    handle: tokio::runtime::Handle,
    /// The runtime, when the client owns it ([`connect`](Self::connect)).
    runtime: Option<Runtime>,
    /// Tasks to stop on drop when the runtime is shared ([`connect_on`](Self::connect_on)).
    tasks: Mutex<Vec<tokio::task::AbortHandle>>,
}

impl Client {
    /// Starts connecting to the daemon named by `ticket` and keeps the connection up.
    ///
    /// Returns immediately; progress arrives as [`ClientEvent::Connected`] and friends.
    ///
    /// # Errors
    ///
    /// Returns [`ClientError::Ticket`] for an unparsable ticket, [`ClientError::Key`] for a
    /// key that is not 32 bytes and [`ClientError::Io`] if the runtime cannot start.
    pub fn connect(
        ticket: &str,
        config: ClientConfig,
        listener: Arc<dyn ClientListener>,
    ) -> Result<Self, ClientError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("client-core")
            .enable_all()
            .build()?;
        let mut client = Self::connect_on(runtime.handle(), ticket, config, listener)?;
        client.runtime = Some(runtime);
        Ok(client)
    }

    /// Like [`connect`](Self::connect), but runs on `runtime` (shared with other clients,
    /// e.g. the app's one FFI runtime) instead of a runtime of its own. Dropping the client
    /// stops its tasks; the runtime keeps running.
    ///
    /// # Errors
    ///
    /// Returns [`ClientError::Ticket`] for an unparsable ticket and [`ClientError::Key`] for
    /// a key that is not 32 bytes.
    pub fn connect_on(
        runtime: &tokio::runtime::Handle,
        ticket: &str,
        config: ClientConfig,
        listener: Arc<dyn ClientListener>,
    ) -> Result<Self, ClientError> {
        Self::connect_on_with(runtime, ticket, config, ConnectOptions::default(), listener)
    }

    /// Like [`connect`](Self::connect), with [`ConnectOptions`].
    ///
    /// # Errors
    ///
    /// As [`connect`](Self::connect).
    pub fn connect_with(
        ticket: &str,
        config: ClientConfig,
        options: ConnectOptions,
        listener: Arc<dyn ClientListener>,
    ) -> Result<Self, ClientError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("client-core")
            .enable_all()
            .build()?;
        let mut client =
            Self::connect_on_with(runtime.handle(), ticket, config, options, listener)?;
        client.runtime = Some(runtime);
        Ok(client)
    }

    /// Like [`connect_on`](Self::connect_on), with [`ConnectOptions`].
    ///
    /// The ticket's relay extras ([`proto::TicketExtras`]) decide how the daemon is dialled
    /// when `config.relay` is [`RelayMode::Default`]: through the product's relays, only
    /// through the daemon's self-hosted relays, or directly (local-only daemons).
    ///
    /// # Errors
    ///
    /// As [`connect_on`](Self::connect_on).
    pub fn connect_on_with(
        runtime: &tokio::runtime::Handle,
        ticket: &str,
        config: ClientConfig,
        options: ConnectOptions,
        listener: Arc<dyn ClientListener>,
    ) -> Result<Self, ClientError> {
        let (ticket, extras) = Ticket::parse_with_extras(ticket)?;
        Self::start(
            runtime,
            Dial::Ticket(ticket, extras.relays),
            config,
            options,
            listener,
        )
    }

    pub(crate) fn start(
        runtime: &tokio::runtime::Handle,
        dial: Dial,
        config: ClientConfig,
        options: ConnectOptions,
        listener: Arc<dyn ClientListener>,
    ) -> Result<Self, ClientError> {
        if config.secret_key.len() != 32 {
            return Err(ClientError::Key);
        }
        let (ticket, relays, invite) = match dial {
            Dial::Ticket(ticket, relays) => (ticket, relays, None),
            Dial::Invite(invite) => {
                // A guest dials like a paired device; its principal comes from its key and
                // its authority from the invite's grant chain.
                let ticket = Ticket {
                    v: Ticket::VERSION,
                    daemon_id: invite.daemon_id,
                    addrs: invite.addrs.clone(),
                    relay_url: invite.relay_url.clone(),
                    principal: grants::guest_principal(device_id(&config)),
                    secret: proto::PairingSecret([0; 16]),
                    expires: proto::UnixMillis(0),
                };
                (ticket, proto::TicketRelays::default(), Some(invite))
            }
        };
        let inner = Arc::new(Inner {
            ticket,
            relays,
            net: Mutex::new((config.relay, options.clone())),
            rebind: AtomicBool::new(false),
            options,
            link: Mutex::new(config.link),
            config,
            listener,
            wanted: Mutex::new(Wanted::default()),
            mirrors: Mutex::new(HashMap::new()),
            pane_output_turns: Mutex::new(HashMap::new()),
            pane_streams: Mutex::new(HashMap::new()),
            next_pane_stream: AtomicU64::new(0),
            outgoing: outgoing::OutgoingQueue::default(),
            connection: Mutex::new(None),
            endpoint: Mutex::new(None),
            reconnect: Notify::new(),
            skips_backoff: AtomicBool::new(false),
            is_dialing: AtomicBool::new(false),
            last_direct_addresses: Mutex::new(Vec::new()),
            paused: Mutex::new(false),
            resumed: watch::Sender::new(0),
            epoch: Mutex::new(None),
            resume_token: Mutex::new(None),
            input: Mutex::default(),
            paired: Mutex::new(false),
            next_op: AtomicU64::new(1),
            stats: Mutex::new(ClientStats::default()),
            ws: workspace::WsState::default(),
            mp: mp::MpState::with_invite(invite),
            art: artifacts::ArtState::default(),
            assist: assist::AssistState::default(),
            askpass: askpass::AskpassState::default(),
            browser: browser::BrowserState::default(),
            approvals: approvals::ApprovalState::default(),
            programs: Mutex::new(HashMap::new()),
            daemon_info: Mutex::new(None),
            more_daemon_features: Mutex::new(proto::MoreDaemonFeatures::EMPTY),
            image_storage_bytes: Mutex::new(None),
            incompatible: Mutex::new(false),
            pong: watch::Sender::new(0),
            next_ping: AtomicU64::new(0),
        });
        let supervisor = runtime.spawn(conn::supervise(Arc::clone(&inner)));
        Ok(Self {
            inner,
            handle: runtime.clone(),
            runtime: None,
            tasks: Mutex::new(vec![supervisor.abort_handle()]),
        })
    }

    /// Attaches to a session (`None`: the most recent one, created if there is none). Kept
    /// across reconnects.
    pub fn attach(&self, session_id: Option<SessionId>) {
        {
            let mut wanted = lock(&self.inner.wanted);
            wanted.session = session_id;
            wanted.attach_requested = true;
        }
        self.inner.send(ClientCtl::Attach { session_id });
    }

    /// Asks for the session list.
    pub fn list_sessions(&self) {
        self.inner.send(ClientCtl::ListSessions);
    }

    /// Sends a layout operation; the result arrives as [`ClientEvent::OpResult`] with the
    /// returned id.
    pub fn op(&self, op: LayoutOp) -> u64 {
        let op_id = self.inner.next_op.fetch_add(1, Ordering::Relaxed);
        self.inner.send(ClientCtl::Op { op_id, op });
        op_id
    }

    /// Starts following a pane's output. Kept across reconnects.
    pub fn subscribe(&self, pane_id: PaneId) {
        {
            let mut wanted = lock(&self.inner.wanted);
            if !wanted.subscribed.contains(&pane_id) {
                wanted.subscribed.push(pane_id);
            }
        }
        self.inner.send(ClientCtl::Subscribe {
            pane_id,
            mode: proto::SubscribeMode::Live,
            rows_hint: 0,
        });
    }

    /// Stops following a pane and forgets its mirror.
    pub fn unsubscribe(&self, pane_id: PaneId) {
        let had_activity = {
            let mut wanted = lock(&self.inner.wanted);
            wanted
                .subscribed
                .retain(|&subscribed| subscribed != pane_id);
            wanted.activities.remove(&pane_id).is_some()
        };
        if had_activity {
            self.inner.send(ClientCtl::PaneActivity {
                pane_id,
                activity: proto::PaneActivity::Inactive,
            });
        }
        lock(&self.inner.mirrors).remove(&pane_id);
        lock(&self.inner.pane_streams).remove(&pane_id);
        self.inner.send(ClientCtl::Unsubscribe { pane_id });
    }

    /// Reports whether this device actively shows a pane. Kept across reconnects, separate
    /// from visibility; older daemons receive only the existing visibility reports.
    pub fn set_pane_activity(&self, pane_id: PaneId, activity: proto::PaneActivity) {
        if lock(&self.inner.wanted)
            .activities
            .insert(pane_id, activity)
            == Some(activity)
        {
            return;
        }
        self.inner
            .send(ClientCtl::PaneActivity { pane_id, activity });
    }

    /// Claims this active client's grid without sending terminal bytes.
    pub fn claim_pane_size(&self, pane_id: PaneId) {
        self.inner.send(ClientCtl::ClaimSize { pane_id });
    }

    /// Sets a shared pane's policy. The daemon owns it; reconnects do not replay an old choice.
    pub fn set_size_policy(&self, pane_id: PaneId, policy: proto::SizePolicy) {
        self.inner
            .send(ClientCtl::SetSizePolicy { pane_id, policy });
    }

    /// Tells the daemon what is on screen, which sets stream priorities and budgets.
    pub fn set_view(&self, focused: Option<PaneId>, visible: Vec<PaneId>) {
        {
            let mut wanted = lock(&self.inner.wanted);
            wanted.focus = focused;
            wanted.visible.clone_from(&visible);
        }
        self.inner.send(ClientCtl::Visible { pane_ids: visible });
        self.inner.send(ClientCtl::Focus { pane_id: focused });
    }

    /// This device's terminal theme, which programs asking a pane for its colors are told
    /// while this client uses the pane. Kept across reconnects; daemons without
    /// [`DaemonFeatures::TERMINAL_COLORS`](proto::DaemonFeatures::TERMINAL_COLORS) are not
    /// sent it.
    pub fn set_terminal_colors(&self, colors: proto::TerminalColors) {
        lock(&self.inner.wanted).colors = Some(colors.clone());
        // Without a connection the next one sends the wanted colors when it starts.
        if self.live_connection().is_some() {
            self.inner.send(ClientCtl::TerminalColors(colors));
        }
    }

    /// This client's size for a pane. The PTY takes it when this client types.
    pub fn resize(&self, pane_id: PaneId, size: PaneSize) {
        lock(&self.inner.wanted).sizes.insert(pane_id, size);
        self.inner.send(ClientCtl::Resize { pane_id, size });
    }

    /// Sends input to a pane. Queued while disconnected (up to 8 MiB) and delivered after
    /// reconnecting.
    /// Input larger than one frame allows is sent in 1 MiB pieces.
    pub fn send_input(&self, pane_id: PaneId, data: Vec<u8>) {
        const PIECE: usize = 1 << 20;
        if data.len() <= PIECE {
            self.send_payload(pane_id, InputPayload::Bytes(data));
            return;
        }
        for piece in data.chunks(PIECE) {
            self.send_payload(pane_id, InputPayload::Bytes(piece.to_vec()));
        }
    }

    /// Types `offer`'s command into its pane and presses Return, as the user would. A command
    /// with control characters is not typed: they would act as keys.
    pub fn run_again(&self, offer: &proto::RunAgainOffer) {
        if offer.command.is_empty() || offer.command.chars().any(char::is_control) {
            return;
        }
        self.send_input(offer.pane_id, format!("{}\r", offer.command).into_bytes());
    }

    /// Sends encoded terminal reports without claiming the pane's size. Older daemons receive
    /// ordinary bytes; the input sequence stays unchanged across reconnects.
    pub fn send_generated_input(&self, pane_id: PaneId, data: Vec<u8>) {
        const PIECE: usize = 1 << 20;
        if data.len() <= PIECE {
            self.send_payload(pane_id, InputPayload::GeneratedBytes(data));
            return;
        }
        for piece in data.chunks(PIECE) {
            self.send_payload(pane_id, InputPayload::GeneratedBytes(piece.to_vec()));
        }
    }

    /// Sends a key event; the daemon encodes it for the program's current keyboard modes
    /// (legacy, application cursor keys, modifyOtherKeys or kitty flags).
    pub fn send_key(&self, pane_id: PaneId, key: FullKeyEvent) {
        self.send_payload(pane_id, InputPayload::KeyFull(key));
    }

    /// Sends a mouse event; the daemon encodes it for the program's mouse tracking mode and
    /// format, and drops it if the program does not track the mouse.
    pub fn send_mouse(&self, pane_id: PaneId, event: MouseEvent) {
        self.send_payload(pane_id, InputPayload::Mouse(event));
    }

    /// Pastes text: bracketed if the program enabled bracketed paste, with control bytes that
    /// could end the paste early replaced. Confirming a multi-line paste is up to the caller
    /// (see `ghostty_vt::paste_is_safe`).
    ///
    /// A paste larger than one input frame allows goes as consecutive pastes of at most
    /// 1 MiB each, cut at character boundaries; the program receives the same text.
    pub fn send_paste(&self, pane_id: PaneId, text: String) {
        const PIECE: usize = 1 << 20;
        if text.len() <= PIECE {
            self.send_payload(pane_id, InputPayload::Paste(text));
            return;
        }
        let mut rest = text.as_str();
        while !rest.is_empty() {
            let mut end = rest.len().min(PIECE);
            while !rest.is_char_boundary(end) {
                end -= 1;
            }
            let (piece, tail) = rest.split_at(end);
            self.send_payload(pane_id, InputPayload::Paste(piece.to_owned()));
            rest = tail;
        }
    }

    fn send_payload(&self, pane_id: PaneId, payload: InputPayload) {
        self.inner.queue(Outgoing::Input { pane_id, payload });
    }

    /// Withdraws op `op_id` if it is still waiting for a connection, so it is never applied
    /// (its caller gave up on it). Returns whether it was waiting.
    pub fn withdraw_op(&self, op_id: u64) -> bool {
        self.inner.outgoing.withdraw_op(op_id)
    }

    /// Requests and input waiting to be sent: a handful, or what waits for a connection.
    pub fn queued(&self) -> usize {
        self.inner.outgoing.len()
    }

    fn next_id(&self) -> u64 {
        self.inner.next_op.fetch_add(1, Ordering::Relaxed)
    }

    /// Searches a pane's whole scrollback on the daemon; the page arrives as
    /// [`ClientEvent::SearchResult`] with the returned id. Pass the previous page's
    /// `next` as `cursor` for the next page.
    pub fn search(&self, pane_id: PaneId, query: SearchQuery, cursor: u32, limit: u32) -> u64 {
        let req_id = self.next_id();
        self.inner.send(ClientCtl::Search {
            req_id,
            pane_id,
            query,
            cursor,
            limit,
        });
        req_id
    }

    /// Asks for the hyperlinks, URLs and paths on a pane's screen and in its last `commands`
    /// commands' output ([`ClientEvent::Links`]).
    pub fn links(&self, pane_id: PaneId, commands: u16) -> u64 {
        let req_id = self.next_id();
        self.inner.send(ClientCtl::Links {
            req_id,
            pane_id,
            commands,
        });
        req_id
    }

    /// Asks for a pane's shell-integration commands ([`ClientEvent::Commands`]).
    pub fn commands(&self, pane_id: PaneId) -> u64 {
        let req_id = self.next_id();
        self.inner.send(ClientCtl::Commands { req_id, pane_id });
        req_id
    }

    /// Asks for a command's output, or the last finished command's with `None`
    /// ([`ClientEvent::CommandOutput`]).
    pub fn command_output(&self, pane_id: PaneId, command_id: Option<u64>) -> u64 {
        let req_id = self.next_id();
        self.inner.send(ClientCtl::CommandOutput {
            req_id,
            pane_id,
            command_id,
        });
        req_id
    }

    /// Fetches the next page of a followed pane's scrollback older than its snapshot, newest
    /// first, up to about `max_bytes` of records; it arrives as [`ClientEvent::PaneHistory`].
    /// Returns `false` when there is nothing to fetch: no snapshot yet, all history already
    /// fetched, or a page still in flight.
    pub fn fetch_history(&self, pane_id: PaneId, max_bytes: u32) -> bool {
        let request = {
            let mut mirrors = lock(&self.inner.mirrors);
            let Some(history) = mirrors.get_mut(&pane_id).map(|mirror| &mut mirror.history) else {
                return false;
            };
            if history.done || history.in_flight {
                return false;
            }
            history.in_flight = true;
            ClientCtl::FetchHistory {
                pane_id,
                snapshot_seq: Seq(history.snapshot_seq),
                offset: history.next_offset,
                max_bytes,
            }
        };
        self.inner.send(request);
        true
    }

    /// Plain text of a followed pane's mirror including the scrollback it holds.
    pub fn pane_text_all(&self, pane_id: PaneId) -> Option<String> {
        lock(&self.inner.mirrors).get(&pane_id)?.text_all()
    }

    /// Scrollback rows the mirror holds for a pane.
    pub fn pane_scrollback_rows(&self, pane_id: PaneId) -> Option<usize> {
        lock(&self.inner.mirrors).get(&pane_id)?.scrollback_rows()
    }

    /// Launches a coding agent in a new pane split off `pane_id`.
    pub fn launch_agent(&self, pane_id: PaneId, agent: AgentKind, axis: proto::Axis) -> u64 {
        self.op(LayoutOp::Split {
            pane_id,
            axis,
            launch: proto::PaneLaunch::Agent {
                agent,
                resume: None,
                cwd: None,
            },
        })
    }

    /// Answers an agent approval request, signed with this device's key so the daemon's
    /// audit log can prove who approved.
    pub fn decide(&self, request_id: proto::RequestId, option_id: proto::OptionId) {
        let mut decide = Decide {
            request_id,
            option_id,
            actor: self.actor(),
            sig: Vec::new(),
        };
        if let Ok(key) = grants::DeviceKey::from_seed(&self.inner.config.secret_key) {
            grants::sign_approval(&key, self.inner.ticket.daemon_id, &mut decide);
        }
        self.inner.send(ClientCtl::Decide(decide));
    }

    /// What the program in `pane_id` last reported about itself, if anything (with
    /// [`ConnectOptions::program_status`]).
    pub fn program_status(&self, pane_id: PaneId) -> Option<proto::ProgramReport> {
        lock(&self.inner.programs).get(&pane_id).cloned()
    }

    /// Plain text of a followed pane's visible screen, from the VT mirror.
    pub fn pane_text(&self, pane_id: PaneId) -> Option<String> {
        lock(&self.inner.mirrors).get(&pane_id)?.text()
    }

    /// A Ghostty snapshot of a followed pane's mirror, for painting before the network is up.
    pub fn pane_snapshot(&self, pane_id: PaneId) -> Option<Vec<u8>> {
        lock(&self.inner.mirrors).get(&pane_id)?.snapshot()
    }

    /// Kitty graphics placements on a followed pane's mirror (active screen), each with its
    /// image; the image's `pixels` are `None` while still on the way.
    pub fn pane_images(
        &self,
        pane_id: PaneId,
    ) -> Option<Vec<(ghostty_vt::KittyPlacement, Option<ghostty_vt::KittyImage>)>> {
        lock(&self.inner.mirrors).get(&pane_id)?.images()
    }

    /// The mirror as VT escape sequences that redraw the visible screen, styles and cursor
    /// included (used by `gudo attach` to repaint after a snapshot).
    pub fn pane_vt(&self, pane_id: PaneId) -> Option<String> {
        lock(&self.inner.mirrors).get(&pane_id)?.vt()
    }

    /// Output applied so far for a pane.
    pub fn pane_seq(&self, pane_id: PaneId) -> Option<u64> {
        lock(&self.inner.mirrors).get(&pane_id).map(Mirror::seq)
    }

    /// Changes how the daemon is reached (the app's relay settings): `relay` and the relay
    /// parts of `options` (`relay_ca_der`, `relay_urls`, `relay_auth_token`; `askpass` and
    /// `browser` stay as connected). Drops the connection and redials on a new endpoint, keeping all resume
    /// state; a suspended client uses them when it resumes.
    pub fn set_relays(&self, relay: RelayMode, options: &ConnectOptions) {
        {
            let mut net = lock(&self.inner.net);
            net.0 = relay;
            net.1.relay_ca_der.clone_from(&options.relay_ca_der);
            net.1.relay_urls.clone_from(&options.relay_urls);
            net.1.relay_auth_token.clone_from(&options.relay_auth_token);
        }
        self.inner.rebind.store(true, Ordering::SeqCst);
        if *lock(&self.inner.paused) {
            return;
        }
        if let Some(connection) = lock(&self.inner.connection).take() {
            connection.close(0u32.into(), b"relay settings");
        }
        self.inner.reconnect.notify_one();
    }

    /// Whether the daemon of the last connection offers `feature`.
    pub fn daemon_offers(&self, feature: proto::MoreDaemonFeatures) -> bool {
        lock(&self.inner.more_daemon_features).contains(feature)
    }

    /// Whether the daemon of the current (or last) connection announced `feature`.
    pub fn daemon_supports(&self, feature: proto::DaemonFeatures) -> bool {
        self.inner.daemon_has(feature)
    }

    /// Drops the connection and redials immediately.
    pub fn reconnect(&self) {
        self.unpause();
        if let Some(connection) = lock(&self.inner.connection).take() {
            connection.close(0u32.into(), b"reconnect");
        }
        self.refresh_network();
        self.inner.skips_backoff.store(true, Ordering::SeqCst);
        self.inner.reconnect.notify_one();
    }

    /// How much the device's network can carry (`Constrained` in Low Data Mode). The daemon
    /// hears it in the handshake, so a change reconnects a live connection.
    pub fn set_link(&self, link: proto::LinkClass) {
        if std::mem::replace(&mut *lock(&self.inner.link), link) == link {
            return;
        }
        if !*lock(&self.inner.paused) && self.live_connection().is_some() {
            self.reconnect();
        }
    }

    /// Back in the foreground: probes a live link, otherwise redials at once.
    pub fn resume_now(&self) {
        self.unpause();
        self.refresh_network();
        match self.live_connection() {
            Some(connection) => {
                let inner = Arc::clone(&self.inner);
                self.handle.spawn(conn::probe(
                    inner,
                    connection,
                    conn::ProbeDeadlines::FOREGROUND,
                ));
            }
            None => self.redial_unless_dialing(),
        }
    }

    /// The device's network changed. A live connection is kept: iroh moves it onto a path that
    /// works (a new direct address, or the relay), so streams on it (forwarded websockets)
    /// survive. Without one the client redials, unless a dial is in flight; a suspended client
    /// stays suspended.
    pub fn network_changed(&self) {
        if *lock(&self.inner.paused) {
            return;
        }
        self.refresh_network();
        if self.live_connection().is_none() {
            self.redial_unless_dialing();
        }
    }

    fn live_connection(&self) -> Option<Connection> {
        lock(&self.inner.connection)
            .clone()
            .filter(|connection| connection.close_reason().is_none())
    }

    fn unpause(&self) {
        if std::mem::replace(&mut *lock(&self.inner.paused), false) {
            self.inner.resumed.send_modify(|resumes| *resumes += 1);
        }
    }

    // A dial in flight carries on over the refreshed endpoint: restarting it throws away a
    // handshake that may be about to finish.
    fn redial_unless_dialing(&self) {
        self.inner.skips_backoff.store(true, Ordering::SeqCst);
        if !self.inner.is_dialing.load(Ordering::SeqCst) {
            self.inner.reconnect.notify_one();
        }
    }

    // Otherwise a relay connection that died in the background is noticed only at its next ping.
    fn refresh_network(&self) {
        if let Some(endpoint) = lock(&self.inner.endpoint).clone() {
            self.handle
                .spawn(async move { endpoint.network_change().await });
        }
    }

    /// Checks that the live connection still reaches the daemon (app foregrounded, typing that
    /// got no answer): a ping must come back within [`PROBE_DEADLINE`], or within
    /// [`PROBE_SLOW_DEADLINE`] while the link still carries packets (slow, not dead). Otherwise
    /// the connection is dropped and redialled, so a half-open link shows as reconnecting in
    /// seconds rather than at the idle timeout. Without a live connection it does nothing (one
    /// is already being dialled). Returns at once.
    pub fn probe(&self) {
        let Some(connection) = lock(&self.inner.connection).clone() else {
            return;
        };
        let inner = Arc::clone(&self.inner);
        self.handle
            .spawn(conn::probe(inner, connection, conn::ProbeDeadlines::TYPING));
    }

    /// Drops the connection and stays offline until [`reconnect`](Self::reconnect), keeping
    /// all resume state (app suspended).
    pub fn suspend(&self) {
        *lock(&self.inner.paused) = true;
        if let Some(connection) = lock(&self.inner.connection).take() {
            connection.close(0u32.into(), b"suspend");
        }
        // A dial in flight is abandoned rather than left to come up behind the pause.
        self.inner.reconnect.notify_one();
    }

    /// Forwards `127.0.0.1:local_port` on this device to `localhost:remote_port` on the
    /// daemon's host. Returns the bound local port (`local_port` 0 picks one).
    ///
    /// # Errors
    ///
    /// Returns [`ClientError::Io`] if the local port cannot be bound.
    pub fn forward_port(&self, local_port: u16, remote_port: u16) -> Result<u16, ClientError> {
        let listener = StdTcpListener::bind(("127.0.0.1", local_port))?;
        listener.set_nonblocking(true)?;
        let port = listener.local_addr()?.port();
        let inner = Arc::clone(&self.inner);
        let task = self
            .handle
            .spawn(conn::serve_forward(inner, listener, remote_port));
        lock(&self.tasks).push(task.abort_handle());
        Ok(port)
    }

    pub fn stats(&self) -> ClientStats {
        *lock(&self.inner.stats)
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        if let Some(connection) = lock(&self.inner.connection).take() {
            connection.close(0u32.into(), b"bye");
        }
        let endpoint = lock(&self.inner.endpoint).take();
        for task in lock(&self.tasks).drain(..) {
            task.abort();
        }
        self.inner.ws.stop_forwards();
        let Some(runtime) = self.runtime.take() else {
            // A shared runtime: close in the background, never block the caller (it may be
            // the app's main thread).
            if let Some(endpoint) = endpoint {
                self.handle.spawn(async move {
                    let _ = tokio::time::timeout(CLOSE_GRACE, endpoint.close()).await;
                });
            }
            return;
        };
        // Give the close one short chance to reach the daemon, so it releases this client's
        // attachment now rather than after the idle timeout. A helper thread keeps this safe
        // to call from inside an async context.
        if let Some(endpoint) = endpoint {
            let handle = runtime.handle().clone();
            let _ = std::thread::spawn(move || {
                handle.block_on(async {
                    let _ = tokio::time::timeout(CLOSE_GRACE, endpoint.close()).await;
                });
            })
            .join();
        }
        runtime.shutdown_background();
    }
}

/// How long dropping a [`Client`] waits for its close to be delivered.
const CLOSE_GRACE: std::time::Duration = std::time::Duration::from_millis(250);

pub(crate) fn device_id(config: &ClientConfig) -> proto::DeviceId {
    let key: [u8; 32] = config
        .secret_key
        .as_slice()
        .try_into()
        .expect("checked in connect");
    proto::DeviceId(*iroh::SecretKey::from_bytes(&key).public().as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debug_output_leaves_secrets_out() {
        let config = ClientConfig::new(vec![0xAB; 32]);
        let text = format!("{config:?}");
        assert!(!text.contains("171"), "device key bytes in {text}");
        let options = ConnectOptions {
            relay_auth_token: Some("relay-token-value".into()),
            ..ConnectOptions::default()
        };
        let text = format!("{options:?}");
        assert!(!text.contains("relay-token-value"), "relay token in {text}");
        assert!(text.contains("<redacted>"));
    }
}
