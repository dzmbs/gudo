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

mod conn;
mod mirror;
mod ssh_pane;

use std::collections::HashMap;
use std::net::TcpListener as StdTcpListener;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use iroh::endpoint::Connection;
use proto::{
    AgentKind, ClientCtl, Decide, EchoHintAt, LayoutOp, OpOutcome, PaneId, PaneMeta, PaneSize,
    SessionId, SessionLayout, SessionSummary, Ticket,
};
use tokio::runtime::Runtime;
use tokio::sync::{Notify, mpsc};

use crate::mirror::Mirror;

pub use proto;
pub use ssh;
pub use ssh_pane::{RESTART_MARKER, SshPane, SshPaneOptions, ssh_runtime};

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
    Input { pane_id: PaneId, data: Vec<u8> },
}

pub(crate) struct Inner {
    pub ticket: Ticket,
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
    runtime: Option<Runtime>,
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
        let ticket: Ticket = ticket.parse()?;
        if config.secret_key.len() != 32 {
            return Err(ClientError::Key);
        }
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("client-core")
            .enable_all()
            .build()?;
        let (outgoing_tx, outgoing_rx) = mpsc::unbounded_channel();
        let inner = Arc::new(Inner {
            ticket,
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
        });
        runtime.spawn(conn::supervise(Arc::clone(&inner)));
        Ok(Self {
            inner,
            runtime: Some(runtime),
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
        let _ = self
            .inner
            .outgoing_tx
            .send(Outgoing::Input { pane_id, data });
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

    /// Answers an agent approval request.
    pub fn decide(&self, request_id: proto::RequestId, option_id: proto::OptionId) {
        let actor = proto::Actor {
            principal: self.inner.ticket.principal,
            device: device_id(&self.inner.config),
        };
        self.inner.send(ClientCtl::Decide(Decide {
            request_id,
            option_id,
            actor,
            sig: Vec::new(),
        }));
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
        self.handle()
            .spawn(conn::serve_forward(inner, listener, remote_port));
        Ok(port)
    }

    /// Counters.
    pub fn stats(&self) -> ClientStats {
        *lock(&self.inner.stats)
    }

    fn handle(&self) -> &tokio::runtime::Handle {
        self.runtime
            .as_ref()
            .expect("runtime lives until drop")
            .handle()
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        if let Some(conn) = lock(&self.inner.connection).take() {
            conn.close(0u32.into(), b"bye");
        }
        let endpoint = lock(&self.inner.endpoint).take();
        if let Some(rt) = self.runtime.take() {
            // Give the close one short chance to reach the daemon, so it releases this
            // client's attachment now rather than after the idle timeout. A helper thread
            // keeps this safe to call from inside an async context.
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
