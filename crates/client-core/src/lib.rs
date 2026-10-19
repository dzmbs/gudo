//! Platform-neutral client core: dial a daemon by pairing ticket, attach to a session, follow
//! panes with seq/ack, resume after disconnects, forward ports.
//!
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

mod artifacts;
mod assist;
mod conn;
mod mirror;
mod mp;
pub mod push;
mod ssh_pane;
mod upgrade;
pub mod vscode;
mod workspace;

use std::collections::HashMap;
use std::net::TcpListener as StdTcpListener;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use iroh::endpoint::Connection;
use proto::{
    AgentKind, AttachVia, ClientCtl, CommandList, CommandMark, CommandOutput, Decide, EchoHintAt,
    FullKeyEvent, InputPayload, LayoutOp, Links, MouseEvent, OpError, OpOutcome, PaneId, PaneMeta,
    PaneSize, RpcError, SearchPage, SearchQuery, Seq, SessionId, SessionLayout, SessionSummary,
    Ticket,
};
use tokio::runtime::Runtime;
use tokio::sync::{Notify, mpsc};

use crate::mirror::Mirror;

pub use artifacts::{ArtifactEventQueue, ArtifactListener, ArtifactUpdate};
pub use assist::{AssistEvent, AssistEventQueue, AssistListener};
pub use drawing;
pub use grants::{self, GrantSpec};
pub use mp::{MultiplayerEvent, MultiplayerEventQueue, MultiplayerListener, now_millis};
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

/// Client settings.
#[derive(Debug, Clone)]
pub struct ClientConfig {
    /// The device's Ed25519 secret key (32 bytes). Keep it in the Keychain; it identifies the
    /// device to every daemon it pairs with.
    pub secret_key: Vec<u8>,
    /// Relay usage.
    pub relay: RelayMode,
    /// Keep a libghostty-vt mirror of each followed pane (needed for [`Client::pane_text`]
    /// and [`Client::pane_snapshot`]). An app that feeds its own renderer's VT can turn this
    /// off; seq/ack and resume work either way.
    pub mirror_vt: bool,
}

impl ClientConfig {
    /// Defaults: n0 relays, VT mirror on.
    pub fn new(secret_key: Vec<u8>) -> Self {
        Self {
            secret_key,
            relay: RelayMode::Default,
            mirror_vt: true,
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
/// FFI layer builds it).
#[derive(Debug, Clone, Default)]
pub struct ConnectOptions {
    /// Extra CA certificates (DER) to trust for the daemon's self-hosted relays, e.g. a
    /// private CA. The usual web roots stay trusted.
    pub relay_ca_der: Vec<Vec<u8>>,
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
        /// Why, in words.
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
        /// Why.
        reason: String,
    },
    /// The daemon refused the connection (bad grant, version mismatch). The client stops
    /// redialling until [`Client::reconnect`].
    Refused {
        /// Why.
        reason: String,
    },
    /// The session list.
    Sessions {
        /// Sessions.
        sessions: Vec<SessionSummary>,
    },
    /// Attached to a session.
    Attached {
        /// The session.
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
        /// Why, in words.
        message: String,
    },
    /// The attached session's layout.
    Layout {
        /// The layout.
        layout: SessionLayout,
    },
    /// A pane's metadata.
    PaneMeta {
        /// The metadata.
        meta: PaneMeta,
    },
    /// A pane closed.
    PaneClosed {
        /// The pane.
        pane_id: PaneId,
    },
    /// Raw output to feed the pane's VT, in order, continuing from the previous event.
    PaneBytes {
        /// The pane.
        pane_id: PaneId,
        /// Offset of `data[0]`.
        seq: u64,
        /// The bytes.
        data: Vec<u8>,
    },
    /// Replace the pane's VT with this Ghostty snapshot (READY section, decompressed).
    PaneSnapshot {
        /// The pane.
        pane_id: PaneId,
        /// Offset the snapshot reflects.
        seq: u64,
        /// The snapshot.
        data: Vec<u8>,
    },
    /// Resize the pane's VT here in the stream.
    PaneResized {
        /// The pane.
        pane_id: PaneId,
        /// Offset of the resize.
        seq: u64,
        /// The new size.
        size: PaneSize,
    },
    /// Input `input_seq` is reflected at or after `at_seq`.
    InputAck {
        /// The pane.
        pane_id: PaneId,
        /// The input.
        input_seq: u64,
        /// Output offset.
        at_seq: u64,
    },
    /// Echo prediction facts for a pane.
    EchoHint {
        /// The hint.
        hint: EchoHintAt,
    },
    AgentEvent {
        /// The pane.
        pane_id: PaneId,
        /// The event.
        json: String,
    },
    /// The result of [`Client::op`].
    OpResult {
        /// The id `op` returned.
        op_id: u64,
        /// What happened.
        outcome: OpOutcome,
    },
    /// Older scrollback for a pane, from [`Client::fetch_history`]: Ghostty snapshot history
    /// records continuing the pane's last snapshot (feed them to the snapshot's streaming
    /// decoder). The VT mirror, if on, has already prepended them.
    PaneHistory {
        /// The pane.
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
        /// The pane.
        pane_id: PaneId,
    },
    /// A shell-integration command started or finished in the attached session.
    CommandMark {
        /// The mark.
        mark: CommandMark,
    },
    /// A long command finished while no client was showing its pane (any session).
    CommandFinishedUnseen {
        /// The mark.
        mark: CommandMark,
    },
    /// The answer to [`Client::search`].
    SearchResult {
        /// The id `search` returned.
        req_id: u64,
        /// The pane.
        pane_id: PaneId,
        /// One page of matches.
        result: Result<SearchPage, RpcError>,
    },
    /// The answer to [`Client::links`].
    Links {
        /// The id `links` returned.
        req_id: u64,
        /// The pane.
        pane_id: PaneId,
        /// What was found.
        result: Result<Links, RpcError>,
    },
    /// The answer to [`Client::commands`].
    Commands {
        /// The id `commands` returned.
        req_id: u64,
        /// The pane.
        pane_id: PaneId,
        /// The commands.
        result: Result<CommandList, RpcError>,
    },
    /// The answer to [`Client::command_output`].
    CommandOutput {
        /// The id `command_output` returned.
        req_id: u64,
        /// The pane.
        pane_id: PaneId,
        /// The output.
        result: Result<CommandOutput, RpcError>,
    },
}

/// Receives [`ClientEvent`]s. Must return quickly; it runs on the network threads.
pub trait ClientListener: Send + Sync {
    /// Called once per event, in order.
    fn on_event(&self, event: ClientEvent);
}

/// A [`ClientListener`] that queues events for async Rust consumers (the `un` CLI, tests).
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
    /// Snapshots received.
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
}

/// Something for the live connection to send.
#[derive(Debug)]
pub(crate) enum Outgoing {
    Ctl(ClientCtl),
    Input {
        pane_id: PaneId,
        payload: InputPayload,
    },
}

pub(crate) struct Inner {
    pub ticket: Ticket,
    /// The daemon's relays, from the ticket's extras (self-hosted, none, or the default).
    pub relays: proto::TicketRelays,
    pub options: ConnectOptions,
    pub config: ClientConfig,
    pub listener: Arc<dyn ClientListener>,
    pub wanted: Mutex<Wanted>,
    pub mirrors: Mutex<HashMap<PaneId, Mirror>>,
    pub outgoing_tx: mpsc::UnboundedSender<Outgoing>,
    pub outgoing_rx: tokio::sync::Mutex<mpsc::UnboundedReceiver<Outgoing>>,
    pub connection: Mutex<Option<Connection>>,
    pub endpoint: Mutex<Option<iroh::Endpoint>>,
    pub reconnect: Notify,
    pub paused: Mutex<bool>,
    pub epoch: Mutex<Option<u64>>,
    pub resume_token: Mutex<Option<proto::ResumeToken>>,
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
    /// What the daemon said about itself on the last connection.
    pub daemon_info: Mutex<Option<proto::DaemonInfo>>,
    /// The last connection was for an upgrade only.
    pub incompatible: Mutex<bool>,
}

/// How a client authenticates: as a paired device (pairing ticket) or a guest (invite).
pub(crate) enum Dial {
    Ticket(Ticket, proto::TicketRelays),
    Invite(proto::Invite),
}

pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Inner {
    pub fn emit(&self, event: ClientEvent) {
        self.listener.on_event(event);
    }

    fn send(&self, msg: ClientCtl) {
        let _ = self.outgoing_tx.send(Outgoing::Ctl(msg));
    }
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
        let (outgoing_tx, outgoing_rx) = mpsc::unbounded_channel();
        let inner = Arc::new(Inner {
            ticket,
            relays,
            options,
            config,
            listener,
            wanted: Mutex::new(Wanted::default()),
            mirrors: Mutex::new(HashMap::new()),
            outgoing_tx,
            outgoing_rx: tokio::sync::Mutex::new(outgoing_rx),
            connection: Mutex::new(None),
            endpoint: Mutex::new(None),
            reconnect: Notify::new(),
            paused: Mutex::new(false),
            epoch: Mutex::new(None),
            resume_token: Mutex::new(None),
            paired: Mutex::new(false),
            next_op: AtomicU64::new(1),
            stats: Mutex::new(ClientStats::default()),
            ws: workspace::WsState::default(),
            mp: mp::MpState::with_invite(invite),
            art: artifacts::ArtState::default(),
            assist: assist::AssistState::default(),
            daemon_info: Mutex::new(None),
            incompatible: Mutex::new(false),
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
        lock(&self.inner.wanted)
            .subscribed
            .retain(|&p| p != pane_id);
        lock(&self.inner.mirrors).remove(&pane_id);
        self.inner.send(ClientCtl::Unsubscribe { pane_id });
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

    /// This client's size for a pane. The PTY takes it when this client types.
    pub fn resize(&self, pane_id: PaneId, size: PaneSize) {
        lock(&self.inner.wanted).sizes.insert(pane_id, size);
        self.inner.send(ClientCtl::Resize { pane_id, size });
    }

    /// Sends input to a pane. Queued while disconnected and delivered after reconnecting.
    pub fn send_input(&self, pane_id: PaneId, data: Vec<u8>) {
        self.send_payload(pane_id, InputPayload::Bytes(data));
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
    pub fn send_paste(&self, pane_id: PaneId, text: String) {
        self.send_payload(pane_id, InputPayload::Paste(text));
    }

    fn send_payload(&self, pane_id: PaneId, payload: InputPayload) {
        let _ = self
            .inner
            .outgoing_tx
            .send(Outgoing::Input { pane_id, payload });
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
            let Some(h) = mirrors.get_mut(&pane_id).map(|m| &mut m.history) else {
                return false;
            };
            if h.done || h.in_flight {
                return false;
            }
            h.in_flight = true;
            ClientCtl::FetchHistory {
                pane_id,
                snapshot_seq: Seq(h.snapshot_seq),
                offset: h.next_offset,
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

    /// Plain text of a followed pane's visible screen, from the VT mirror.
    pub fn pane_text(&self, pane_id: PaneId) -> Option<String> {
        lock(&self.inner.mirrors).get(&pane_id)?.text()
    }

    /// A Ghostty snapshot of a followed pane's mirror, for painting before the network is up
    pub fn pane_snapshot(&self, pane_id: PaneId) -> Option<Vec<u8>> {
        lock(&self.inner.mirrors).get(&pane_id)?.snapshot()
    }

    /// The mirror as VT escape sequences that redraw the visible screen, styles and cursor
    /// included (used by `un attach` to repaint after a snapshot).
    pub fn pane_vt(&self, pane_id: PaneId) -> Option<String> {
        lock(&self.inner.mirrors).get(&pane_id)?.vt()
    }

    /// Output applied so far for a pane.
    pub fn pane_seq(&self, pane_id: PaneId) -> Option<u64> {
        lock(&self.inner.mirrors).get(&pane_id).map(Mirror::seq)
    }

    /// Drops the connection and redials immediately (network change, app foregrounded).
    pub fn reconnect(&self) {
        *lock(&self.inner.paused) = false;
        if let Some(conn) = lock(&self.inner.connection).take() {
            conn.close(0u32.into(), b"reconnect");
        }
        self.inner.reconnect.notify_one();
    }

    /// Drops the connection and stays offline until [`reconnect`](Self::reconnect), keeping
    /// all resume state (app suspended).
    pub fn suspend(&self) {
        *lock(&self.inner.paused) = true;
        if let Some(conn) = lock(&self.inner.connection).take() {
            conn.close(0u32.into(), b"suspend");
        }
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

    /// Counters.
    pub fn stats(&self) -> ClientStats {
        *lock(&self.inner.stats)
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        if let Some(conn) = lock(&self.inner.connection).take() {
            conn.close(0u32.into(), b"bye");
        }
        let endpoint = lock(&self.inner.endpoint).take();
        for task in lock(&self.tasks).drain(..) {
            task.abort();
        }
        let Some(rt) = self.runtime.take() else {
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
            let handle = rt.handle().clone();
            let _ = std::thread::spawn(move || {
                handle.block_on(async {
                    let _ = tokio::time::timeout(CLOSE_GRACE, endpoint.close()).await;
                });
            })
            .join();
        }
        rt.shutdown_background();
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
