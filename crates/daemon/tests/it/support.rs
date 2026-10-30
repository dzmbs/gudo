//! Harness: a daemon with relays off on loopback, and clients with an event-driven model.

use std::collections::HashMap;
use std::path::Path;
use std::time::{Duration, Instant};

use client_core::proto::{
    AttachVia, LayoutNode, LayoutOp, OpOutcome, PaneId, PaneSize, SessionId, SessionLayout,
    TabLayout,
};
use client_core::{
    AskpassEvent, AskpassEventQueue, BrowserPushQueue, Client, ClientConfig, ClientEvent,
    EventQueue, MultiplayerEvent, MultiplayerEventQueue, RelayMode,
};
use daemon::{Config, Daemon};
use tokio::sync::mpsc::UnboundedReceiver;

pub const TIMEOUT: Duration = Duration::from_secs(20);

pub fn init_tracing() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "warn".into()),
        )
        .with_test_writer()
        .try_init();
}

pub fn config(state_dir: &Path) -> Config {
    let mut config = Config::new(state_dir);
    config.relay = daemon::RelayMode::Disabled;
    config.bind = Some("127.0.0.1:0".parse().unwrap());
    config.shell = Some("/bin/sh".into());
    config.pane_env = vec![("PS1".into(), "$ ".into()), ("ENV".into(), String::new())];
    config.persist_debounce = Duration::from_millis(50);
    config
}

pub async fn start(state_dir: &Path) -> Daemon {
    start_with(state_dir, |_| {}).await
}

/// Starts a daemon with the test configuration as changed by `edit`.
pub async fn start_with(state_dir: &Path, edit: impl FnOnce(&mut Config)) -> Daemon {
    init_tracing();
    let mut config = config(state_dir);
    edit(&mut config);
    Daemon::start(config).await.expect("daemon starts")
}

pub fn ticket(daemon: &Daemon) -> String {
    daemon
        .pairing_ticket(daemon::PAIRING_TTL)
        .expect("ticket")
        .to_string()
}

/// A client plus everything it has been told.
pub struct TestClient {
    pub client: Client,
    events: UnboundedReceiver<ClientEvent>,
    pub layout: Option<SessionLayout>,
    pub results: HashMap<u64, OpOutcome>,
    pub connected: u32,
    pub snapshot_events: u32,
    pub byte_events: u32,
    pub agent_events: Vec<String>,
    pub marks: Vec<client_core::proto::CommandMark>,
    pub unseen: Vec<client_core::proto::CommandMark>,
    pub hints: Vec<client_core::proto::EchoHintAt>,
    pub answers: HashMap<u64, ClientEvent>,
    pub history: Vec<(u64, bool)>,
    pub history_gone: u32,
    pub metas: HashMap<PaneId, client_core::proto::PaneMeta>,
    pub log: Vec<String>,
    /// Refusals (`ClientEvent::Refused` reasons).
    pub refused: Vec<String>,
    /// Attach answers: (session, how it was chosen, the requested session that was gone).
    pub attached: Vec<(SessionId, AttachVia, Option<SessionId>)>,
    /// Attach failures (`ClientEvent::AttachFailed` messages).
    pub attach_failed: Vec<String>,
    /// `ClientEvent::DaemonInfo`, one per connection.
    pub infos: Vec<Option<client_core::proto::DaemonInfo>>,
    /// `ClientEvent::Incompatible` reasons.
    pub incompatible: Vec<String>,
    mp_events: UnboundedReceiver<MultiplayerEvent>,
    /// Multiplayer pushes received so far.
    pub mp: Vec<MultiplayerEvent>,
    askpass_events: UnboundedReceiver<AskpassEvent>,
    /// Askpass pushes received so far (connections made with `askpass: true`).
    pub askpass: Vec<AskpassEvent>,
    browser_events: UnboundedReceiver<client_core::proto::BrowserPush>,
    /// Browser pushes received so far (connections made with `browser: true`).
    pub browser: Vec<client_core::proto::BrowserPush>,
    /// `ClientEvent::ProgramStatus` pushes, in order (connections with `program_status`).
    pub programs: Vec<(PaneId, Option<client_core::proto::ProgramReport>)>,
}

impl TestClient {
    pub fn connect(ticket: &str, key: Vec<u8>) -> Self {
        let mut config = ClientConfig::new(key);
        config.relay = RelayMode::Disabled;
        Self::connect_with(ticket, config, client_core::ConnectOptions::default())
    }

    /// A client with its own relay settings (relays from the ticket, extra CA roots).
    pub fn connect_with(
        ticket: &str,
        config: ClientConfig,
        options: client_core::ConnectOptions,
    ) -> Self {
        let (listener, events) = EventQueue::channel();
        let client =
            Client::connect_with(ticket, config, options, listener).expect("client starts");
        Self::wrap(client, events)
    }

    /// A client that shows native password prompts (`ConnectOptions::askpass`).
    pub fn connect_askpass(ticket: &str, key: Vec<u8>) -> Self {
        let mut config = ClientConfig::new(key);
        config.relay = RelayMode::Disabled;
        let options = client_core::ConnectOptions {
            askpass: true,
            ..client_core::ConnectOptions::default()
        };
        Self::connect_with(ticket, config, options)
    }

    /// A client that opens URLs and runs browser tools (`ConnectOptions::browser`).
    pub fn connect_browser(ticket: &str, key: Vec<u8>) -> Self {
        let mut config = ClientConfig::new(key);
        config.relay = RelayMode::Disabled;
        let options = client_core::ConnectOptions {
            browser: true,
            ..client_core::ConnectOptions::default()
        };
        Self::connect_with(ticket, config, options)
    }

    /// A client that shows programs' own status (`ConnectOptions::program_status`).
    pub fn connect_program_status(ticket: &str, key: Vec<u8>) -> Self {
        let mut config = ClientConfig::new(key);
        config.relay = RelayMode::Disabled;
        let options = client_core::ConnectOptions {
            program_status: true,
            ..client_core::ConnectOptions::default()
        };
        Self::connect_with(ticket, config, options)
    }

    /// A guest joining with an invite, showing native password prompts.
    pub fn join_askpass(invite: &str, key: Vec<u8>) -> Self {
        let (listener, events) = EventQueue::channel();
        let mut config = ClientConfig::new(key);
        config.relay = RelayMode::Disabled;
        let options = client_core::ConnectOptions {
            askpass: true,
            ..client_core::ConnectOptions::default()
        };
        let client = Client::join_with(invite, config, options, listener).expect("client starts");
        Self::wrap(client, events)
    }

    /// A guest joining with an invite, offering to open URLs and run browser tools.
    pub fn join_browser(invite: &str, key: Vec<u8>) -> Self {
        let (listener, events) = EventQueue::channel();
        let mut config = ClientConfig::new(key);
        config.relay = RelayMode::Disabled;
        let options = client_core::ConnectOptions {
            browser: true,
            ..client_core::ConnectOptions::default()
        };
        let client = Client::join_with(invite, config, options, listener).expect("client starts");
        Self::wrap(client, events)
    }

    /// A guest joining with an invite.
    pub fn join(invite: &str, key: Vec<u8>) -> Self {
        let (listener, events) = EventQueue::channel();
        let mut config = ClientConfig::new(key);
        config.relay = RelayMode::Disabled;
        let client = Client::join(invite, config, listener).expect("client starts");
        Self::wrap(client, events)
    }

    fn wrap(client: Client, events: UnboundedReceiver<ClientEvent>) -> Self {
        let (mp_listener, mp_events) = MultiplayerEventQueue::channel();
        client.set_multiplayer_listener(mp_listener);
        let (askpass_listener, askpass_events) = AskpassEventQueue::channel();
        client.set_askpass_listener(askpass_listener);
        let (browser_listener, browser_events) = BrowserPushQueue::channel();
        client.set_browser_listener(browser_listener);
        Self {
            client,
            events,
            layout: None,
            results: HashMap::new(),
            connected: 0,
            snapshot_events: 0,
            byte_events: 0,
            agent_events: Vec::new(),
            marks: Vec::new(),
            unseen: Vec::new(),
            hints: Vec::new(),
            answers: HashMap::new(),
            history: Vec::new(),
            history_gone: 0,
            metas: HashMap::new(),
            log: Vec::new(),
            refused: Vec::new(),
            attached: Vec::new(),
            attach_failed: Vec::new(),
            infos: Vec::new(),
            incompatible: Vec::new(),
            mp_events,
            mp: Vec::new(),
            askpass_events,
            askpass: Vec::new(),
            browser_events,
            browser: Vec::new(),
            programs: Vec::new(),
        }
    }

    fn apply(&mut self, event: ClientEvent) {
        let name = format!("{event:?}");
        self.log.push(name.chars().take(120).collect());
        match event {
            ClientEvent::Connected { .. } => self.connected += 1,
            ClientEvent::Layout { layout } => {
                if self.layout.as_ref().is_none_or(|l| {
                    l.session_id != layout.session_id || l.revision <= layout.revision
                }) {
                    self.layout = Some(layout);
                }
            }
            ClientEvent::OpResult { op_id, outcome } => {
                self.results.insert(op_id, outcome);
            }
            ClientEvent::PaneSnapshot { .. } => self.snapshot_events += 1,
            ClientEvent::PaneBytes { .. } => self.byte_events += 1,
            ClientEvent::AgentEvent { json, .. } => self.agent_events.push(json),
            ClientEvent::CommandMark { mark } => self.marks.push(mark),
            ClientEvent::CommandFinishedUnseen { mark } => self.unseen.push(mark),
            ClientEvent::EchoHint { hint } => self.hints.push(hint),
            ClientEvent::PaneHistory { rows, done, .. } => self.history.push((rows, done)),
            ClientEvent::PaneHistoryGone { .. } => self.history_gone += 1,
            ClientEvent::SearchResult { req_id, .. }
            | ClientEvent::Links { req_id, .. }
            | ClientEvent::Commands { req_id, .. }
            | ClientEvent::CommandOutput { req_id, .. } => {
                self.answers.insert(req_id, event);
            }
            ClientEvent::PaneMeta { meta } => {
                self.metas.insert(meta.pane_id, meta);
            }
            ClientEvent::Refused { reason } => self.refused.push(reason),
            ClientEvent::Attached {
                session_id,
                via,
                missing,
            } => self.attached.push((session_id, via, missing)),
            ClientEvent::AttachFailed { message, .. } => self.attach_failed.push(message),
            ClientEvent::DaemonInfo { info } => self.infos.push(info),
            ClientEvent::Incompatible { reason } => self.incompatible.push(reason),
            ClientEvent::ProgramStatus { pane_id, status } => {
                self.programs.push((pane_id, status));
            }
            _ => {}
        }
    }

    /// Pumps events until `done` holds.
    pub async fn until(&mut self, what: &str, mut done: impl FnMut(&Self) -> bool) {
        let deadline = Instant::now() + TIMEOUT;
        loop {
            if done(self) {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {what}; last events:\n{}",
                self.log[self.log.len().saturating_sub(15)..].join("\n")
            );
            if let Ok(Some(event)) =
                tokio::time::timeout(Duration::from_millis(20), self.events.recv()).await
            {
                self.apply(event);
                while let Ok(event) = self.events.try_recv() {
                    self.apply(event);
                }
            }
            while let Ok(event) = self.mp_events.try_recv() {
                self.log
                    .push(format!("{event:?}").chars().take(120).collect());
                self.mp.push(event);
            }
            while let Ok(event) = self.askpass_events.try_recv() {
                self.log
                    .push(format!("{event:?}").chars().take(120).collect());
                self.askpass.push(event);
            }
            while let Ok(push) = self.browser_events.try_recv() {
                self.log
                    .push(format!("{push:?}").chars().take(120).collect());
                self.browser.push(push);
            }
        }
    }

    /// Waits for the answer to request `id`.
    pub async fn answer(&mut self, id: u64) -> ClientEvent {
        self.until("request answer", |c| c.answers.contains_key(&id))
            .await;
        self.answers.remove(&id).expect("present")
    }

    /// The visible screen with soft wraps removed (rows concatenated).
    pub fn flat_text(&self, pane: PaneId) -> String {
        self.text(pane).replace('\n', "")
    }

    pub async fn wait_flat(&mut self, pane: PaneId, needle: &str) {
        let what = format!("{needle:?} in pane {pane}");
        self.until(&what, |c| c.flat_text(pane).contains(needle))
            .await;
    }

    pub async fn op(&mut self, op: LayoutOp) -> OpOutcome {
        let id = self.client.op(op);
        self.until("op result", |c| c.results.contains_key(&id))
            .await;
        self.results[&id].clone()
    }

    pub fn tab(&self) -> &TabLayout {
        let layout = self.layout.as_ref().expect("attached");
        layout
            .tabs
            .iter()
            .find(|t| Some(t.tab_id) == layout.active_tab)
            .expect("active tab")
    }

    pub fn focused(&self) -> PaneId {
        self.tab().focused
    }

    /// Attaches to the default session and follows its focused pane.
    pub async fn attach_and_follow(&mut self) -> PaneId {
        self.client.attach(None);
        self.until("layout", |c| c.layout.is_some()).await;
        let pane = self.focused();
        self.follow(pane).await;
        pane
    }

    pub async fn follow(&mut self, pane: PaneId) {
        self.client.resize(
            pane,
            PaneSize {
                cols: 100,
                rows: 30,
                width_px: 0,
                height_px: 0,
            },
        );
        self.client.subscribe(pane);
        self.client.set_view(Some(pane), vec![pane]);
        self.until("pane mirror", |c| c.client.pane_seq(pane).is_some())
            .await;
    }

    pub fn text(&self, pane: PaneId) -> String {
        self.client.pane_text(pane).unwrap_or_default()
    }

    pub async fn wait_text(&mut self, pane: PaneId, needle: &str) {
        let what = format!("{needle:?} in pane {pane}");
        self.until(&what, |c| c.text(pane).contains(needle)).await;
    }

    pub fn type_line(&self, pane: PaneId, line: &str) {
        self.client
            .send_input(pane, format!("{line}\r").into_bytes());
    }
}

/// Leaves of a split tree.
pub fn leaves(node: &LayoutNode) -> Vec<PaneId> {
    match node {
        LayoutNode::Leaf(p) => vec![*p],
        LayoutNode::Split { first, second, .. } => {
            let mut v = leaves(first);
            v.extend(leaves(second));
            v
        }
    }
}

/// The shape of a layout without ids that change.
pub fn shape(layout: &SessionLayout) -> Vec<String> {
    layout
        .tabs
        .iter()
        .map(|t| format!("{}:{:?}", t.name, t.root))
        .collect()
}

pub fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}
