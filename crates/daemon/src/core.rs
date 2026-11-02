//! Daemon-wide state: the layout, the panes, the event bus, and the operations on them.

use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant, SystemTime};

use agents::LaunchMode;
use proto::{
    Actor, AgentKind, CommandMark, Decide, Decided, EchoHint, EchoHintAt, LayoutOp, OpError,
    OpOutcome, PaneId, PaneLaunch, PaneMeta, PaneSize, Prediction, PrincipalId, Scope, ServerCtl,
    SessionEpoch, SessionId, SessionLayout, SizePolicy, SnapGen,
};
use serde::{Deserialize, Serialize};
use tokio::sync::{Notify, broadcast, mpsc};
use tokio::task::AbortHandle;

use crate::agent::{AgentRuntime, HookServer};
use crate::commands::CommandUpdate;
use crate::config::Config;
use crate::identity::Identity;
use crate::layout::{Layout, Removed};
use crate::osc::Osc;
use crate::pane::{Pane, VtEvent};
use crate::persist;
use crate::shell::ShellIntegration;

/// How long a float that closes when its work is done stays to show the outcome.
const FLOAT_LINGER: std::time::Duration = std::time::Duration::from_millis(2500);

/// Identifies one client connection for the daemon's lifetime.
pub(crate) type ConnId = u64;

/// Something every connection may need to forward. Payload-free variants are re-read from the
/// current state by the receiver, so a burst of changes costs one fresh read each.
#[derive(Debug, Clone)]
pub(crate) enum Event {
    Layout(SessionId),
    Sessions,
    PaneMeta(PaneId),
    PaneClosed(PaneId),
    Echo(EchoHintAt),
    Agent {
        pane_id: PaneId,
        json: Arc<str>,
    },
    Decided(Decided),
    /// A shell-integration command started or finished.
    Command(CommandMark),
    /// A long command finished while no client showed its pane.
    CommandUnseen(CommandMark),
    /// The detected ports changed (read the list from `ws.ports`).
    Ports,
    /// The attention feed changed.
    Attention(proto::AttentionUpdate),
    /// The VS Code tunnel changed state.
    VsCodeTunnel(proto::VsCodeTunnelStatus),
    /// Someone joined, left, renamed or changed focus (read the list from `mp`).
    Participants,
    /// A participant's presence (typing, cursor).
    Presence(proto::Presence),
    /// A connection's live presence changed (read it from `mp`).
    Peer(ConnId),
    /// A pane's control lease changed.
    Lease(proto::Lease),
    /// A drawing or image of `session` changed, or live ink (not echoed to `from`).
    Artifact {
        session: SessionId,
        event: Arc<proto::ArtifactEvent>,
        from: Option<ConnId>,
    },
    /// A pane's foreground program, or a watched pane's prompt state, changed.
    Assist(proto::AssistPush),
    /// What the program in a pane reports about itself changed (read it with
    /// `Core::program_report`).
    ProgramStatus(PaneId),
    /// A native password prompt opened or closed, or a detected one changed (`askpass`).
    Askpass(proto::AskpassPush),
    /// The repository snapshot changed (read it from `ws.repos`).
    Repos,
    /// A knock arrived or ended (owner devices hear it).
    Knock(proto::KnockUpdate),
    /// An owner device paired.
    DevicePaired(proto::DeviceInfo),
    /// A session's approval policy changed.
    ApprovalPolicy(SessionId, proto::ApprovalPolicy),
    /// An open approval request's votes or claim changed.
    ApprovalStatus(proto::ApprovalStatus),
    /// An approval request's extras or a pane's auto-approve rules changed (`approve`).
    Approval(proto::ApprovalPush),
    /// A watched workflow directory changed (the new revision).
    Workflows(u64),
    /// The agent accounts or the panes' accounts changed (read them with
    /// `Core::accounts_report`).
    Accounts,
    /// For connection `conn` only: open a URL or run a browser tool (`browser`).
    Browser {
        conn: ConnId,
        push: proto::BrowserPush,
    },
    /// A program wrote to the clipboard (OSC 52): for `conn` only.
    Clipboard {
        conn: ConnId,
        pane_id: PaneId,
        text: Arc<str>,
    },
}

/// What restoring a pane after a daemon restart needs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct PaneRecord {
    pub launch: PaneLaunch,
    /// Last working directory reported by the shell (OSC 7), else the launch directory.
    pub cwd: Option<String>,
    pub agent: Option<AgentRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<WorktreeRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct WorktreeRecord {
    pub path: String,
    pub port: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct AgentRecord {
    pub kind: AgentKind,
    /// The agent's own session id, once known.
    pub session_id: Option<String>,
    /// The account it runs under (`proto::account`); `None` in records written before
    /// accounts, which ran under the system account.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<String>,
}

/// A pane that closed, kept so a recently closed tab can come back (`PaneLaunch::Reopen`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ClosedPane {
    pub pane_id: PaneId,
    /// Its last working directory.
    pub cwd: Option<String>,
    /// The agent it ran, when its session id was known.
    pub agent: Option<AgentRecord>,
}

/// How many closed panes the daemon remembers, oldest dropped first.
pub(crate) const CLOSED_PANES: usize = 64;

#[derive(Debug, Default)]
pub(crate) struct MetaState {
    pub title: String,
    pub cwd: Option<String>,
    pub exit: Option<i32>,
    /// The connection whose size the PTY has, and its principal.
    pub sized_by: Option<(ConnId, PrincipalId)>,
    /// The connection that typed into the pane last; `None` once an agent typed, or it left.
    pub typed_by: Option<ConnId>,
    pub at_prompt: bool,
    pub last_hint: Option<(EchoHint, Prediction)>,
    /// The password prompt on the cursor row while input is hidden (`askpass::detect`).
    pub secret_prompt: Option<String>,
    /// The program's own last OSC 7501 report (or `status_set`), whatever the program.
    pub program: Option<agents::ProgramStatus>,
    /// Turns the pane's agent has finished, and the last one.
    pub turns: u64,
    pub last_turn: Option<LastTurn>,
}

/// How an agent's last turn ended, for agents waiting on it (`daemon::term`).
#[derive(Debug, Clone)]
pub(crate) struct LastTurn {
    pub outcome: agents::TurnOutcome,
    pub message: Option<String>,
    pub at: proto::UnixMillis,
    pub transcript: Option<PathBuf>,
}

pub(crate) struct PaneEntry {
    pub pane: Arc<Pane>,
    pub meta: Mutex<MetaState>,
    pub record: Mutex<PaneRecord>,
    pub agent: Mutex<Option<AgentRuntime>>,
    /// Wakes the pane task when an agent attaches from outside it (a hook), so its timers run.
    pub agent_attached: Notify,
    /// Periodic ticks the pane task has run.
    ticks: AtomicU64,
    task: Mutex<Option<AbortHandle>>,
    /// When the pane's process started, for matching a Codex rollout to it.
    launched_at: SystemTime,
}

impl PaneEntry {
    /// Whether the pane existed at `at` (its process started no later).
    pub fn existed_at(&self, at: proto::UnixMillis) -> bool {
        let started = self
            .launched_at
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis() as u64);
        started <= at.0
    }
}

/// A report as clients see it; `None` for `Clear`.
/// Longest message or title kept from a program's own status report, in characters.
const PROGRAM_TEXT_CHARS: usize = 512;

fn program_report(status: &agents::ProgramStatus) -> Option<proto::ProgramReport> {
    use agents::{ProgramKind as K, ProgramState as S};
    let state = match status.state {
        S::Idle => proto::ProgramState::Idle,
        S::Working => proto::ProgramState::Working,
        S::Done => proto::ProgramState::Done,
        S::Blocked => proto::ProgramState::Blocked,
        S::Error => proto::ProgramState::Error,
        S::Clear => return None,
    };
    Some(proto::ProgramReport {
        state,
        kind: status.kind.map(|k| match k {
            K::Permission => proto::ProgramKind::Permission,
            K::Question => proto::ProgramKind::Question,
            K::Auth => proto::ProgramKind::Auth,
        }),
        app: status.app.clone(),
        message: status.msg.clone(),
        progress: status.progress,
    })
}

pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

pub(crate) struct Core {
    pub cfg: Config,
    pub epoch: SessionEpoch,
    pub identity: Arc<Identity>,
    pub layout: Mutex<Layout>,
    panes: Mutex<HashMap<PaneId, Arc<PaneEntry>>>,
    /// Recently closed panes, newest last.
    closed: Mutex<VecDeque<ClosedPane>>,
    pub events: broadcast::Sender<Event>,
    attached: Mutex<HashMap<ConnId, SessionId>>,
    next_conn: AtomicU64,
    pub persist_dirty: Notify,
    pub shutting_down: AtomicBool,
    pub hooks: HookServer,
    shell: Option<ShellIntegration>,
    /// Panes each connection shows (focused and visible), for "finished while unseen".
    /// Panes each connection shows, with the device it belongs to.
    views: Mutex<HashMap<ConnId, (proto::DeviceId, Vec<PaneId>)>>,
    /// Developer-workflow state: ports, attention, turns, editors, worktrees.
    pub ws: crate::ws::Ws,
    /// Push registrations and delivery (docs/PUSH.md).
    pub push: crate::notifier::Push,
    /// Multiplayer: grants, leases, presence, audit.
    pub mp: crate::mp::Mp,
    pub art: crate::art::Art,
    /// Input assistance: foreground programs, prompt watches, history, completion caches.
    pub assist: crate::assist::Assist,
    pub(crate) term: crate::term::Term,
    /// Self upgrade: one at a time, and the restart it asks the host process for.
    pub upgrade: crate::upgrade::Upgrade,
    /// Input already applied per client input stream, so a resend after a reconnect is not.
    pub(crate) inputs: crate::resume::InputStreams,
    /// Native password prompts: the helper, open prompts, connections that may answer.
    pub askpass: crate::askpass::Askpass,
    /// URLs and browser tools for the app (`browser`).
    pub browser: crate::browser::Browser,
    /// Auto-approve rules and the open requests' extras (`approve`).
    pub approvals: crate::approve::Approvals,
    connected: AtomicUsize,
    /// Each device's open connections, oldest first (`MAX_CONNS_PER_DEVICE`).
    device_conns: Mutex<
        HashMap<proto::DeviceId, std::collections::VecDeque<(ConnId, iroh::endpoint::Connection)>>,
    >,
    /// Signalled when a client connects or knocks, so work done only for clients resumes.
    pub client_arrived: Notify,
    /// This core, for work it schedules on itself (closing finished floats).
    me: std::sync::Weak<Core>,
}

impl Core {
    pub fn new(
        cfg: Config,
        identity: Arc<Identity>,
        layout: Layout,
        hooks: HookServer,
        shell: Option<ShellIntegration>,
        mp: crate::mp::Mp,
    ) -> Arc<Self> {
        let (events, _) = broadcast::channel(1024);
        let ws = crate::ws::Ws::new(&cfg, events.clone());
        Arc::new_cyclic(|me| Self {
            me: me.clone(),
            epoch: SessionEpoch(crate::identity::now_millis()),
            identity,
            layout: Mutex::new(layout),
            panes: Mutex::new(HashMap::new()),
            closed: Mutex::new(VecDeque::new()),
            events,
            attached: Mutex::new(HashMap::new()),
            next_conn: AtomicU64::new(1),
            persist_dirty: Notify::new(),
            shutting_down: AtomicBool::new(false),
            hooks,
            shell,
            views: Mutex::new(HashMap::new()),
            ws,
            push: crate::notifier::Push::load(&cfg.state_dir),
            mp,
            art: crate::art::Art::open(&cfg.state_dir, cfg.artifacts),
            assist: crate::assist::Assist::new(&cfg),
            term: crate::term::Term::default(),
            upgrade: crate::upgrade::Upgrade::default(),
            inputs: crate::resume::InputStreams::default(),
            askpass: crate::askpass::Askpass::install(
                &cfg.askpass,
                &cfg.state_dir,
                &cfg.hook_bin(),
            ),
            approvals: crate::approve::Approvals::default(),
            browser: crate::browser::Browser::install(&cfg.state_dir, &cfg.hook_bin()),
            cfg,
            connected: AtomicUsize::new(0),
            device_conns: Mutex::default(),
            client_arrived: Notify::new(),
        })
    }

    /// A client connected (`true`) or left.
    pub fn client_connected(&self, up: bool) {
        if up {
            self.connected.fetch_add(1, Ordering::Relaxed);
            self.ws.ports.trigger.notify_one();
            self.client_arrived.notify_waiters();
        } else {
            self.connected.fetch_sub(1, Ordering::Relaxed);
        }
    }

    /// Records a device's new connection and closes its oldest beyond
    /// [`MAX_CONNS_PER_DEVICE`]. A device reconnecting after a network change, or a peer that
    /// opens connections and never closes them, would otherwise keep every old one (and what
    /// its streams hold in flight) until it times out.
    pub fn device_connected(
        &self,
        device: proto::DeviceId,
        id: ConnId,
        conn: iroh::endpoint::Connection,
    ) {
        let evicted = {
            let mut all = lock(&self.device_conns);
            let conns = all.entry(device).or_default();
            conns.push_back((id, conn));
            let excess = conns.len().saturating_sub(MAX_CONNS_PER_DEVICE);
            conns.drain(..excess).collect::<Vec<_>>()
        };
        for (_, old) in evicted {
            old.close(4u32.into(), b"replaced by a newer connection");
        }
    }

    /// Forgets a connection recorded by [`device_connected`](Self::device_connected).
    pub fn device_disconnected(&self, device: proto::DeviceId, id: ConnId) {
        let mut all = lock(&self.device_conns);
        if let Some(conns) = all.get_mut(&device) {
            conns.retain(|(c, _)| *c != id);
            if conns.is_empty() {
                all.remove(&device);
            }
        }
    }

    /// Clients currently connected.
    pub fn connected_clients(&self) -> usize {
        self.connected.load(Ordering::Relaxed)
    }

    /// Records the panes `conn` shows.
    pub fn set_view(&self, conn: ConnId, device: proto::DeviceId, panes: Vec<PaneId>) {
        lock(&self.views).insert(conn, (device, panes));
    }

    /// Whether any connected client shows `pane`.
    pub fn pane_seen(&self, pane: PaneId) -> bool {
        lock(&self.views).values().any(|(_, v)| v.contains(&pane))
    }

    /// Whether `device` is connected and showing some pane of this host (the app is in the
    /// foreground here, so it alerts in-app and a push would be a duplicate).
    pub fn device_active(&self, device: proto::DeviceId) -> bool {
        lock(&self.views)
            .values()
            .any(|(d, v)| *d == device && !v.is_empty())
    }

    pub fn emit(&self, event: Event) {
        let _ = self.events.send(event);
    }

    /// Broadcasts an artifact event to the session's clients (except `from`).
    pub fn emit_artifact(
        &self,
        session: SessionId,
        event: proto::ArtifactEvent,
        from: Option<ConnId>,
    ) {
        self.emit(Event::Artifact {
            session,
            event: Arc::new(event),
            from,
        });
    }

    /// Broadcasts a session's canvas panes.
    pub fn emit_canvases(&self, session: SessionId) {
        let canvases = self.art.canvases(session);
        self.emit_artifact(
            session,
            proto::ArtifactEvent::Canvases {
                session_id: session,
                canvases,
            },
            None,
        );
    }

    pub fn mark_dirty(&self) {
        self.persist_dirty.notify_one();
    }

    pub fn next_conn_id(&self) -> ConnId {
        self.next_conn.fetch_add(1, Ordering::Relaxed)
    }

    pub fn pane(&self, id: PaneId) -> Option<Arc<PaneEntry>> {
        lock(&self.panes).get(&id).cloned()
    }

    pub fn pane_entries(&self) -> Vec<(PaneId, Arc<PaneEntry>)> {
        lock(&self.panes)
            .iter()
            .map(|(id, e)| (*id, Arc::clone(e)))
            .collect()
    }

    // --- attachment -------------------------------------------------------------------------

    pub fn attach(&self, conn: ConnId, session: SessionId) {
        lock(&self.attached).insert(conn, session);
        lock(&self.layout).touch(session);
        self.emit(Event::Sessions);
    }

    /// The panes of every session some connection is attached to.
    pub fn attached_panes(&self) -> Vec<(PaneId, Arc<PaneEntry>)> {
        let mut sessions: Vec<SessionId> = lock(&self.attached).values().copied().collect();
        sessions.sort_unstable();
        sessions.dedup();
        let ids: Vec<PaneId> = {
            let layout = lock(&self.layout);
            sessions
                .iter()
                .filter_map(|&s| layout.session(s))
                .flat_map(|s| &s.tabs)
                .flat_map(|t| crate::layout::leaves(&t.root))
                .collect()
        };
        let panes = lock(&self.panes);
        ids.into_iter()
            .filter_map(|id| Some((id, Arc::clone(panes.get(&id)?))))
            .collect()
    }

    /// Panes some connection shows (focused or visible).
    pub fn viewed_panes(&self) -> HashSet<PaneId> {
        lock(&self.views)
            .values()
            .flat_map(|(_, panes)| panes.iter().copied())
            .collect()
    }

    /// The session `conn` is attached to.
    pub fn attached_session(&self, conn: ConnId) -> Option<SessionId> {
        lock(&self.attached).get(&conn).copied()
    }

    pub fn detach(&self, conn: ConnId) {
        lock(&self.views).remove(&conn);
        self.assist.forget_conn(conn);
        self.askpass.forget_conn(conn);
        self.browser.forget_conn(conn);
        if lock(&self.attached).remove(&conn).is_some() {
            self.emit(Event::Sessions);
        }
        // A departed client no longer sizes anything; the next typist takes over.
        for (_, entry) in self.pane_entries() {
            let mut meta = lock(&entry.meta);
            if meta.sized_by.is_some_and(|(c, _)| c == conn) {
                meta.sized_by = None;
            }
            if meta.typed_by == Some(conn) {
                meta.typed_by = None;
            }
        }
    }

    pub fn sessions_message(&self, scope: Scope) -> ServerCtl {
        let attached = lock(&self.attached).clone();
        let all =
            lock(&self.layout).summaries(|s| attached.values().filter(|&&a| a == s).count() as u32);
        // Filtered after the layout lock is released: `session_visible` takes it again.
        let sessions = all
            .into_iter()
            .filter(|s| self.session_visible(s.session_id, scope))
            .collect();
        ServerCtl::Sessions { sessions }
    }

    // --- scopes (multiplayer) ---------------------------------------------------------------

    /// Whether `inner` lies within `outer` in the current layout.
    pub fn scope_within(&self, inner: Scope, outer: Scope) -> bool {
        if inner == outer || outer == Scope::Daemon {
            return true;
        }
        let layout = lock(&self.layout);
        match (inner, outer) {
            (Scope::Tab(t), Scope::Session(s)) => layout.session_of_tab(t) == Some(s),
            (Scope::Pane(p), Scope::Session(s)) => layout.session_of_pane(p) == Some(s),
            (Scope::Pane(p), Scope::Tab(t)) => layout.tab_of_pane(p) == Some(t),
            _ => false,
        }
    }

    /// Whether a session holds anything a `scope` covers.
    pub fn session_visible(&self, session: SessionId, scope: Scope) -> bool {
        let layout = lock(&self.layout);
        match scope {
            Scope::Daemon => true,
            Scope::Session(s) => s == session,
            Scope::Tab(t) => layout.session_of_tab(t) == Some(session),
            Scope::Pane(p) => layout.session_of_pane(p) == Some(session),
        }
    }

    /// The most recently used session a `scope` can see.
    pub fn recent_session_in(&self, scope: Scope) -> Option<SessionId> {
        let layout = lock(&self.layout);
        match scope {
            Scope::Daemon => layout.most_recent(),
            Scope::Session(s) => layout.session(s).map(|_| s),
            Scope::Tab(t) => layout.session_of_tab(t),
            Scope::Pane(p) => layout.session_of_pane(p),
        }
    }

    /// A session's layout cut down to `scope`: a tab-scoped guest sees only its tab, a
    pub fn layout_for(&self, session: SessionId, scope: Scope) -> Option<SessionLayout> {
        let mut layout = lock(&self.layout).snapshot(session)?;
        match scope {
            Scope::Daemon | Scope::Session(_) => {}
            Scope::Tab(t) => {
                layout.tabs.retain(|tab| tab.tab_id == t);
                layout.active_tab = layout.tabs.first().map(|tab| tab.tab_id);
            }
            Scope::Pane(p) => {
                layout
                    .tabs
                    .retain(|tab| crate::layout::leaves(&tab.root).any(|leaf| leaf == p));
                for tab in &mut layout.tabs {
                    tab.root = proto::LayoutNode::Leaf(p);
                    tab.focused = p;
                    tab.zoomed = None;
                }
                layout.active_tab = layout.tabs.first().map(|tab| tab.tab_id);
            }
        }
        Some(layout)
    }

    /// A session's projects cut down to the tabs `scope` sees, with only the definitions
    /// those tabs use.
    pub fn projects_for(&self, session: SessionId, scope: Scope) -> Option<proto::SessionProjects> {
        let layout = lock(&self.layout);
        let mut all = layout.projects(session)?;
        let shown = match scope {
            Scope::Daemon | Scope::Session(_) => return Some(all),
            Scope::Tab(t) => Some(t),
            Scope::Pane(p) => layout.tab_of_pane(p),
        };
        let proto::SessionProjects { projects, tabs, .. } = &mut all;
        tabs.retain(|m| Some(m.tab_id) == shown);
        projects.retain(|p| tabs.iter().any(|m| m.project == p.id));
        Some(all)
    }

    /// A session's floating windows cut down to `scope`: a tab-scoped guest sees its tab's,
    /// a pane-scoped one none (it sees its pane alone, tiled).
    pub fn floats_for(&self, session: SessionId, scope: Scope) -> Option<proto::SessionFloats> {
        let layout = lock(&self.layout);
        let mut all = layout.floats(session)?;
        match scope {
            Scope::Daemon | Scope::Session(_) => {}
            Scope::Tab(t) => all
                .floats
                .retain(|w| layout.tab_of_pane(w.panes[0]) == Some(t)),
            Scope::Pane(_) => all.floats.clear(),
        }
        Some(all)
    }

    pub fn session_of_pane(&self, pane: PaneId) -> Option<SessionId> {
        lock(&self.layout).session_of_pane(pane)
    }

    pub fn tab_of_pane(&self, pane: PaneId) -> Option<proto::TabId> {
        lock(&self.layout).tab_of_pane(pane)
    }

    /// `pane`'s work is done (its agent's turn ended, its program reported done or failed, or
    /// its command finished): a float opened to close then closes after [`FLOAT_LINGER`], so
    /// the outcome can be read first.
    pub fn work_done(&self, pane: PaneId) {
        let wanted = lock(&self.layout)
            .window_of(pane)
            .is_some_and(|w| w.close == proto::CloseWhen::Done);
        let Ok(rt) = tokio::runtime::Handle::try_current() else {
            return;
        };
        if !wanted {
            return;
        }
        let me = self.me.clone();
        rt.spawn(async move {
            tokio::time::sleep(FLOAT_LINGER).await;
            let Some(core) = me.upgrade() else {
                return;
            };
            let still = lock(&core.layout)
                .window_of(pane)
                .is_some_and(|w| w.close == proto::CloseWhen::Done);
            if still {
                core.term.finished(&core, pane);
                core.apply_op(LayoutOp::ClosePane { pane_id: pane });
            }
        });
    }

    /// The pane whose agent asked approval request `id`.
    pub fn request_pane(&self, id: proto::RequestId) -> Option<PaneId> {
        if let Some(pane) = self.term.asks.caller_of(id) {
            return Some(pane);
        }
        self.pane_entries().into_iter().find_map(|(pane, entry)| {
            lock(&entry.agent)
                .as_ref()
                .is_some_and(|rt| rt.knows_request(id))
                .then_some(pane)
        })
    }

    /// The pane of open request `id` and what an approval policy needs to know about it
    /// (with `option`, whether that option allows the call).
    pub fn request_facts(
        &self,
        id: proto::RequestId,
        option: Option<proto::OptionId>,
    ) -> Option<(PaneId, crate::agent::RequestFacts)> {
        if let Some(facts) = self.term.asks.facts(id) {
            let chosen = option.and_then(crate::term::ask::option_label);
            return Some((
                facts.caller,
                crate::agent::RequestFacts {
                    tool: Some(facts.tool.to_owned()),
                    allows: option.map(|o| o != proto::DriveAsk::DENY),
                    option: chosen.map(str::to_owned),
                    summary: facts.summary,
                    request: crate::term::ask::agent_request(id),
                },
            ));
        }
        self.pane_entries().into_iter().find_map(|(pane, entry)| {
            lock(&entry.agent)
                .as_ref()
                .and_then(|rt| rt.request_facts(id, option))
                .map(|facts| (pane, facts))
        })
    }

    /// The hook request a pane's agent is blocked on now.
    pub fn open_request(&self, pane: PaneId) -> Option<proto::RequestId> {
        let entry = self.pane(pane)?;
        lock(&entry.agent).as_ref()?.open_request()
    }

    /// Whether an agent runs (or ran) in the pane.
    pub fn is_agent_pane(&self, pane: PaneId) -> bool {
        self.pane(pane).is_some_and(|e| {
            lock(&e.agent).is_some() || matches!(lock(&e.record).launch, PaneLaunch::Agent { .. })
        })
    }

    // --- pane metadata ----------------------------------------------------------------------

    pub fn pane_meta(&self, id: PaneId) -> Option<PaneMeta> {
        let entry = self.pane(id)?;
        let meta = lock(&entry.meta);
        let mut agent = lock(&entry.agent).as_mut().map(AgentRuntime::wire_status);
        // Waiting on the owner to let it drive a pane is a block like any approval.
        if let Some(blocker) = self.term.asks.blocker(id) {
            let kind = agent.map_or_else(|| "program".to_owned(), |a| a.kind);
            agent = Some(crate::term::ask::status(kind, blocker));
        }
        Some(PaneMeta {
            pane_id: id,
            title: meta.title.clone(),
            cwd: meta.cwd.clone(),
            exit: meta.exit,
            agent,
            size: entry.pane.size(),
            size_policy: SizePolicy::LastInput,
            sized_by: meta.sized_by.map(|(_, p)| p),
        })
    }

    /// What the program in pane `id` last reported about itself, as clients see it.
    pub fn program_report(&self, id: PaneId) -> Option<proto::ProgramReport> {
        let entry = self.pane(id)?;
        lock(&entry.meta).program.as_ref().and_then(program_report)
    }

    /// Records the program's own top-level report (`Clear` removes it) and tells clients
    /// when what they see changes.
    pub fn set_program(&self, entry: &PaneEntry, mut status: agents::ProgramStatus) {
        // Any program's words, shown in status lines, the Inbox and to agents: as they print.
        let clean = |text: Option<String>| {
            text.map(|t| proto::clean_prompt_text(&t, PROGRAM_TEXT_CHARS))
                .filter(|t| !t.is_empty())
        };
        status.msg = clean(status.msg);
        status.title = clean(status.title);
        let status = (status.state != agents::ProgramState::Clear).then_some(status);
        let status_state = status.as_ref().map(|s| s.state);
        let mut meta = lock(&entry.meta);
        let changed = meta.program.as_ref().and_then(program_report)
            != status.as_ref().and_then(program_report);
        meta.program = status;
        drop(meta);
        if changed {
            self.emit(Event::ProgramStatus(entry.pane.id));
            if matches!(
                status_state,
                Some(agents::ProgramState::Done | agents::ProgramState::Error)
            ) {
                self.work_done(entry.pane.id);
            }
        }
    }

    pub fn echo_hint(&self, id: PaneId) -> Option<EchoHintAt> {
        let entry = self.pane(id)?;
        let (hint, prediction) = compute_hint(&entry);
        Some(EchoHintAt {
            hint,
            at_seq: entry.pane.head(),
            prediction,
        })
    }

    /// Applies `conn`'s size for a pane if the PTY follows that client (it typed last, or no
    /// one has sized the pane yet). `force` makes `conn` the sizing client (it just typed).
    pub fn apply_client_size(
        &self,
        entry: &PaneEntry,
        conn: ConnId,
        principal: PrincipalId,
        size: PaneSize,
        force: bool,
    ) {
        let take = {
            let mut meta = lock(&entry.meta);
            let follows = meta.sized_by.is_none_or(|(c, _)| c == conn);
            if follows || force {
                meta.sized_by = Some((conn, principal));
            }
            follows || force
        };
        if !take {
            return;
        }
        match entry.pane.resize(size) {
            Ok(changed) => {
                if changed {
                    self.emit(Event::PaneMeta(entry.pane.id));
                }
            }
            Err(e) => tracing::debug!(pane = %entry.pane.id, "resize refused: {e}"),
        }
    }

    // --- layout operations ------------------------------------------------------------------

    /// Applies a layout op and broadcasts its effects.
    pub fn apply_op(self: &Arc<Self>, op: LayoutOp) -> OpOutcome {
        match self.try_op(op) {
            Ok(outcome) => outcome,
            Err((code, message)) => OpOutcome::Failed { code, message },
        }
    }

    fn try_op(self: &Arc<Self>, op: LayoutOp) -> Result<OpOutcome, (OpError, String)> {
        let fail = |code: OpError| (code, format!("{code:?}"));
        let outcome = match op {
            LayoutOp::Split {
                pane_id,
                axis,
                launch,
            } => {
                let session = lock(&self.layout)
                    .session_of_pane(pane_id)
                    .ok_or(fail(OpError::NotFound))?;
                lock(&self.layout).check_split(pane_id).map_err(|e| {
                    let max = crate::layout::MAX_SPLIT_DEPTH;
                    (e, format!("too many nested splits (at most {max})"))
                })?;
                let cwd_hint = self.pane(pane_id).and_then(|e| lock(&e.meta).cwd.clone());
                let new = lock(&self.layout).alloc_pane();
                self.spawn_pane(new, launch, cwd_hint, false)?;
                let result = lock(&self.layout).split(pane_id, axis, new);
                if let Err(e) = result {
                    self.kill_panes(&[new]);
                    return Err(fail(e));
                }
                self.layout_changed(session, false);
                OpOutcome::PaneCreated { pane_id: new }
            }
            LayoutOp::ClosePane { pane_id } => {
                let session = lock(&self.layout).session_of_pane(pane_id);
                let removed = lock(&self.layout).close_pane(pane_id).map_err(fail)?;
                self.after_removal(session, removed);
                OpOutcome::Done
            }
            LayoutOp::Focus { pane_id } => {
                self.simple(self.session_of_pane(pane_id), |l| l.focus(pane_id))?
            }
            LayoutOp::FocusDirection { tab_id, direction } => self
                .simple(self.session_of_tab(tab_id), |l| {
                    l.focus_direction(tab_id, direction)
                })?,
            LayoutOp::Resize {
                pane_id,
                axis,
                delta,
            } => self.simple(self.session_of_pane(pane_id), |l| {
                l.resize(pane_id, axis, delta)
            })?,
            LayoutOp::ToggleZoom { pane_id } => {
                self.simple(self.session_of_pane(pane_id), |l| l.toggle_zoom(pane_id))?
            }
            LayoutOp::NewTab {
                session_id,
                name,
                launch,
            } => {
                if lock(&self.layout).session(session_id).is_none() {
                    return Err(fail(OpError::NotFound));
                }
                let pane = lock(&self.layout).alloc_pane();
                self.spawn_pane(pane, launch, None, false)?;
                let tab = lock(&self.layout).new_tab(session_id, name, pane);
                let tab_id = tab.map_err(|e| {
                    self.kill_panes(&[pane]);
                    fail(e)
                })?;
                self.layout_changed(session_id, false);
                OpOutcome::TabCreated {
                    tab_id,
                    pane_id: pane,
                }
            }
            LayoutOp::CloseTab { tab_id } => {
                let session = lock(&self.layout).session_of_tab(tab_id);
                let removed = lock(&self.layout).close_tab(tab_id).map_err(fail)?;
                self.after_removal(session, removed);
                OpOutcome::Done
            }
            LayoutOp::MoveTab { tab_id, index } => {
                self.simple(self.session_of_tab(tab_id), |l| l.move_tab(tab_id, index))?
            }
            LayoutOp::SelectTab { tab_id } => {
                self.simple(self.session_of_tab(tab_id), |l| l.select_tab(tab_id))?
            }
            LayoutOp::RenameTab { tab_id, name } => {
                self.simple(self.session_of_tab(tab_id), |l| l.rename_tab(tab_id, name))?
            }
            LayoutOp::RenameSession { session_id, name } => {
                lock(&self.layout)
                    .rename_session(session_id, name)
                    .map_err(fail)?;
                self.layout_changed(session_id, true);
                OpOutcome::Done
            }
            LayoutOp::CreateSession { name, launch } => {
                let (session_id, tab_id, pane_id) = self.create_session(name, launch)?;
                OpOutcome::SessionCreated {
                    session_id,
                    tab_id,
                    pane_id,
                }
            }
            LayoutOp::BreakPane { pane_id } => {
                let (session, tab_id) = lock(&self.layout).break_pane(pane_id).map_err(fail)?;
                self.layout_changed(session, false);
                OpOutcome::TabCreated { tab_id, pane_id }
            }
            LayoutOp::MovePane {
                pane_id,
                target,
                side,
            } => {
                let session = lock(&self.layout)
                    .move_pane(pane_id, target, side)
                    .map_err(fail)?;
                self.layout_changed(session, true);
                OpOutcome::Done
            }
            LayoutOp::MergeTab {
                tab_id,
                target,
                side,
            } => {
                let session = lock(&self.layout)
                    .merge_tab(tab_id, target, side)
                    .map_err(fail)?;
                self.layout_changed(session, true);
                OpOutcome::Done
            }
            LayoutOp::CloseSession { session_id } => {
                let removed = lock(&self.layout).close_session(session_id).map_err(fail)?;
                self.after_removal(Some(session_id), removed);
                OpOutcome::Done
            }
            LayoutOp::SetTabProject {
                tab_id,
                project,
                rank,
            } => {
                let session = lock(&self.layout)
                    .set_tab_project(tab_id, project, rank)
                    .map_err(fail)?;
                self.layout_changed(session, false);
                OpOutcome::Done
            }
            LayoutOp::PutProject {
                session_id,
                project,
            } => {
                lock(&self.layout)
                    .put_project(session_id, project)
                    .map_err(fail)?;
                self.layout_changed(session_id, false);
                OpOutcome::Done
            }
            LayoutOp::RemoveProject {
                session_id,
                project,
            } => {
                lock(&self.layout)
                    .remove_project(session_id, &project)
                    .map_err(fail)?;
                self.layout_changed(session_id, false);
                OpOutcome::Done
            }
            LayoutOp::NewFloat {
                pane_id,
                launch,
                frame,
                focus,
                close,
            } => {
                let session = lock(&self.layout)
                    .session_of_pane(pane_id)
                    .ok_or(fail(OpError::NotFound))?;
                let cwd_hint = self.pane(pane_id).and_then(|e| lock(&e.meta).cwd.clone());
                let new = lock(&self.layout).alloc_pane();
                self.spawn_pane(new, launch, cwd_hint, false)?;
                let result = lock(&self.layout).new_float(pane_id, new, frame, focus, close);
                if let Err(e) = result {
                    self.kill_panes(&[new]);
                    return Err(fail(e));
                }
                self.layout_changed(session, false);
                OpOutcome::PaneCreated { pane_id: new }
            }
            LayoutOp::FloatPane { pane_id, frame } => self
                .simple(self.session_of_pane(pane_id), |l| {
                    l.float_pane(pane_id, frame).map(drop)
                })?,
            LayoutOp::SetFloat {
                pane_id,
                frame,
                minimized,
                pinned,
            } => self.simple(self.session_of_pane(pane_id), |l| {
                l.set_float(pane_id, frame, minimized, pinned).map(drop)
            })?,
            LayoutOp::DockPane { pane_id, beside } => self
                .simple(self.session_of_pane(pane_id), |l| {
                    l.dock_pane(pane_id, beside).map(drop)
                })?,
            LayoutOp::MovePaneToEdge {
                pane_id,
                tab_id,
                side,
            } => self.simple(self.session_of_pane(pane_id), |l| {
                l.move_pane_to_edge(pane_id, tab_id, side).map(drop)
            })?,
        };
        Ok(outcome)
    }

    /// Creates a session (used by ops and by `Attach` with no sessions).
    pub fn create_session(
        self: &Arc<Self>,
        name: String,
        launch: PaneLaunch,
    ) -> Result<(SessionId, proto::TabId, PaneId), (OpError, String)> {
        let name = if name.is_empty() {
            lock(&self.layout).unique_name("main")
        } else {
            name
        };
        lock(&self.layout)
            .check_session_name(&name)
            .map_err(|e| (e, format!("session name {name:?}: {e:?}")))?;
        let pane = lock(&self.layout).alloc_pane();
        self.spawn_pane(pane, launch, None, false)?;
        let created = lock(&self.layout).create_session(name, pane);
        let (session, tab) = created.map_err(|e| {
            self.kill_panes(&[pane]);
            (e, format!("{e:?}"))
        })?;
        self.layout_changed(session, true);
        Ok((session, tab, pane))
    }

    fn session_of_tab(&self, tab: proto::TabId) -> Option<SessionId> {
        lock(&self.layout).session_of_tab(tab)
    }

    fn simple(
        &self,
        session: Option<SessionId>,
        f: impl FnOnce(&mut Layout) -> Result<(), OpError>,
    ) -> Result<OpOutcome, (OpError, String)> {
        let session = session.ok_or((OpError::NotFound, "not found".to_owned()))?;
        let before = lock(&self.layout).session(session).map(|s| s.revision);
        f(&mut lock(&self.layout)).map_err(|e| (e, format!("{e:?}")))?;
        let after = lock(&self.layout).session(session).map(|s| s.revision);
        if before != after {
            self.layout_changed(session, false);
        }
        Ok(OpOutcome::Done)
    }

    fn layout_changed(&self, session: SessionId, sessions_too: bool) {
        self.emit(Event::Layout(session));
        if sessions_too {
            self.emit(Event::Sessions);
        }
        self.mark_dirty();
    }

    fn after_removal(&self, session: Option<SessionId>, removed: Removed) {
        self.kill_panes(&removed.panes);
        if let Some(closed) = removed.session {
            self.art.delete_session(closed);
        }
        match (removed.session, session) {
            (Some(_), _) => self.emit(Event::Sessions),
            (None, Some(s)) => self.emit(Event::Layout(s)),
            (None, None) => {}
        }
        self.emit(Event::Sessions);
        self.mark_dirty();
    }

    pub fn kill_panes(&self, panes: &[PaneId]) {
        for id in panes {
            if let Some(info) = self.art.remove_canvas(*id) {
                self.emit(Event::PaneClosed(*id));
                self.emit_artifact(
                    info.session_id,
                    proto::ArtifactEvent::Info(info.clone()),
                    None,
                );
                self.emit_canvases(info.session_id);
                continue;
            }
            let entry = lock(&self.panes).remove(id);
            if let Some(entry) = entry {
                if let Some(task) = lock(&entry.task).take() {
                    task.abort();
                }
                self.hooks.cancel_pending(*id);
                self.approvals.forget_pane(*id);
                self.ws.forget_pane(*id);
                self.mp.forget_pane(*id);
                if !self.shutting_down.load(Ordering::Acquire) {
                    self.remember_closed(*id, &lock(&entry.record));
                    self.term.forget(*id);
                    if let Some((agent, account)) = self.ws.accounts.sign_in_closed(*id) {
                        self.check_account(agent, account);
                    }
                    if lock(&entry.record).agent.is_some() {
                        self.emit(Event::Accounts);
                    }
                }
                entry.pane.hang_up();
                kill_if_lingering(Arc::clone(&entry.pane));
                self.emit(Event::PaneClosed(*id));
            }
        }
    }

    fn remember_closed(&self, pane_id: PaneId, record: &PaneRecord) {
        let agent = record
            .agent
            .clone()
            .filter(|agent| agent.session_id.is_some());
        let mut closed = lock(&self.closed);
        closed.push_back(ClosedPane {
            pane_id,
            cwd: record.cwd.clone(),
            agent,
        });
        while closed.len() > CLOSED_PANES {
            closed.pop_front();
        }
    }

    /// The closed panes, oldest first (persisted with the layout).
    pub fn closed_panes(&self) -> Vec<ClosedPane> {
        lock(&self.closed).iter().cloned().collect()
    }

    /// Takes back the closed panes saved before a restart.
    pub fn restore_closed(&self, panes: Vec<ClosedPane>) {
        let mut closed = lock(&self.closed);
        closed.extend(panes);
        while closed.len() > CLOSED_PANES {
            closed.pop_front();
        }
    }

    /// What `PaneLaunch::Reopen` starts: the closed pane's agent resuming its session, else a
    /// shell in its last directory (else `cwd`). The record is used up, so one session never
    /// resumes in two panes.
    fn reopen_launch(&self, pane: PaneId, cwd: Option<String>) -> PaneLaunch {
        let closed = {
            let mut closed = lock(&self.closed);
            closed
                .iter()
                .rposition(|c| c.pane_id == pane)
                .and_then(|i| closed.remove(i))
        };
        let Some(closed) = closed else {
            return PaneLaunch::Shell { cwd };
        };
        self.mark_dirty();
        let cwd = closed.cwd.or(cwd);
        match closed.agent {
            Some(AgentRecord {
                kind,
                session_id: Some(id),
                account,
            }) => PaneLaunch::AccountAgent {
                agent: kind,
                account,
                resume: Some(id),
                cwd,
            },
            _ => PaneLaunch::Shell { cwd },
        }
    }

    /// The pane's process exited: remove it from the layout like `ClosePane`.
    fn pane_exited(self: &Arc<Self>, id: PaneId) {
        if self.shutting_down.load(Ordering::Acquire) || self.pane(id).is_none() {
            return;
        }
        let session = lock(&self.layout).session_of_pane(id);
        let removed = lock(&self.layout).close_pane(id);
        if let Ok(removed) = removed {
            self.after_removal(session, removed);
        }
    }

    // --- spawning ---------------------------------------------------------------------------

    /// Starts a pane process and its task. `restored` marks an agent resumed after a restart.
    pub fn spawn_pane(
        self: &Arc<Self>,
        id: PaneId,
        launch: PaneLaunch,
        cwd_hint: Option<String>,
        restored: bool,
    ) -> Result<(), (OpError, String)> {
        let (launch, restored) = match launch {
            PaneLaunch::Reopen { pane_id, cwd } => {
                let launch = self.reopen_launch(pane_id, cwd);
                let resumed = matches!(launch, PaneLaunch::AccountAgent { .. });
                (launch, restored || resumed)
            }
            launch => (launch, restored),
        };
        // An agent is recorded as `Agent`, its account beside it.
        let (launch, asked_account) = match launch {
            PaneLaunch::AccountAgent {
                agent,
                account,
                resume,
                cwd,
            } => (PaneLaunch::Agent { agent, resume, cwd }, account),
            launch => (launch, None),
        };
        let home = std::env::var("HOME").unwrap_or_else(|_| "/".to_owned());
        let launch_cwd = match &launch {
            PaneLaunch::Shell { cwd }
            | PaneLaunch::Command { cwd, .. }
            | PaneLaunch::Agent { cwd, .. }
            | PaneLaunch::Reopen { cwd, .. } => cwd.clone(),
            PaneLaunch::AccountSignIn { .. } => None,
            PaneLaunch::AccountAgent { .. } => unreachable!("recorded as Agent above"),
            PaneLaunch::Canvas { artifact_id } => {
                let artifact = artifact_id.ok_or((
                    OpError::Invalid,
                    "a canvas pane needs its drawing (the daemon creates one for Split and \
                     NewTab)"
                        .to_owned(),
                ))?;
                let info = self
                    .art
                    .add_canvas(id, artifact)
                    .map_err(|e| (OpError::NotFound, e.to_string()))?;
                self.emit_artifact(
                    info.session_id,
                    proto::ArtifactEvent::Info(info.clone()),
                    None,
                );
                self.emit_canvases(info.session_id);
                return Ok(());
            }
        };
        let max = crate::limits::max_panes();
        if lock(&self.panes).len() >= max {
            return Err((
                OpError::SpawnFailed,
                format!("too many panes: this host's file descriptor limit allows {max}"),
            ));
        }
        let cwd = launch_cwd
            .or(cwd_hint)
            .filter(|c| std::path::Path::new(c).is_dir())
            .unwrap_or(home);
        let shell = self.cfg.shell();
        let mut cmd = Command::new(&shell);
        let mut agent = None;
        let injection = self
            .shell
            .as_ref()
            .filter(|_| self.cfg.shell_integration)
            .and_then(|si| si.injection(&shell, |name| self.cfg.pane_var(name)))
            .map(|mut inj| {
                self.askpass.wrap_injection(&mut inj);
                inj
            });
        let mut inject_env = Vec::new();
        // `exec`s the login shell with shell integration, for panes that run something first.
        let then_shell = || {
            let mut then = vec!["exec".to_owned()];
            if let Some(inj) = &injection {
                then.push("env".into());
                then.extend(
                    inj.env
                        .iter()
                        .map(|(k, v)| shell_quote(&format!("{k}={v}"))),
                );
            }
            then.push(shell_quote(&shell.to_string_lossy()));
            if let Some(inj) = &injection {
                then.extend(inj.args.iter().map(|a| shell_quote(a)));
            }
            then.push("-l".into());
            then.join(" ")
        };
        // A setup or repository script queued for this directory runs first (git workspace).
        let pre = self
            .ws
            .repos
            .take_pre_command(std::path::Path::new(&cwd))
            .map(|c| format!("{c}\n"));
        match &launch {
            PaneLaunch::Shell { .. } | PaneLaunch::Reopen { .. } => match &pre {
                Some(pre) => {
                    cmd.args(["-l", "-c", &format!("{pre}{}", then_shell())]);
                }
                None => {
                    if let Some(inj) = &injection {
                        cmd.args(&inj.args);
                        inject_env.clone_from(&inj.env);
                    }
                    cmd.arg("-l");
                }
            },
            PaneLaunch::Command { argv, .. } => {
                if argv.is_empty() {
                    return Err((OpError::Invalid, "empty argv".into()));
                }
                let line = argv
                    .iter()
                    .map(|a| shell_quote(a))
                    .collect::<Vec<_>>()
                    .join(" ");
                let pre = pre.as_deref().unwrap_or_default();
                cmd.args(["-l", "-c", &format!("{pre}exec {line}")]);
            }
            PaneLaunch::AccountSignIn {
                agent,
                account: account_id,
                device_code,
            } => {
                let account = self
                    .ws
                    .accounts
                    .context(*agent, account_id)
                    .ok_or((OpError::NotFound, "no such account".to_owned()))?;
                let ctx = self.hooks.launch_context(id, PathBuf::from(&cwd), account);
                let spec = match agent {
                    AgentKind::Claude => agents::ClaudeCode::sign_in(&ctx),
                    AgentKind::Codex => agents::Codex::sign_in(&ctx, *device_code),
                };
                // The shim tells the daemon the sign-in ended, so it checks the account.
                let done = format!(
                    "{} {} {} </dev/null",
                    shell_quote(&ctx.hook_bin.to_string_lossy()),
                    crate::agent::ACCOUNT_HOOK,
                    crate::agent::SIGN_IN_EVENT
                );
                cmd.args([
                    "-i",
                    "-l",
                    "-c",
                    &format!("{}; {done}; {}", spec.shell_line(), then_shell()),
                ]);
                for (k, v) in &spec.env {
                    cmd.env(k, v);
                }
                for k in &spec.env_remove {
                    cmd.env_remove(k);
                }
                self.ws.accounts.signing_in(id, *agent, account_id);
            }
            PaneLaunch::AccountAgent { .. } => unreachable!("recorded as Agent above"),
            PaneLaunch::Agent {
                agent: kind,
                resume,
                ..
            } => {
                let project = lock(&self.layout).project_of_pane(id);
                let account = self
                    .ws
                    .accounts
                    .resolve(
                        *kind,
                        asked_account.as_deref(),
                        resume.as_deref(),
                        project.as_deref(),
                    )
                    .map_err(|e| (OpError::Invalid, e))?;
                if let Some(dir) = &account.dir
                    && !dir.is_dir()
                {
                    return Err((
                        OpError::SpawnFailed,
                        "the account's directory is missing; sign in again".to_owned(),
                    ));
                }
                let ctx = self
                    .hooks
                    .launch_context(id, PathBuf::from(&cwd), account.clone());
                let adapter = crate::agent::adapter(*kind);
                let session_id = resume.clone().or_else(|| match kind {
                    // Claude accepts a pinned id, which makes resume work without waiting
                    // for its SessionStart hook.
                    AgentKind::Claude => Some(crate::agent::new_uuid()),
                    AgentKind::Codex => None,
                });
                let mode = match (resume, &session_id) {
                    (Some(r), _) => LaunchMode::Resume {
                        session_id: agents::NativeSessionId::new(r.clone()),
                    },
                    (None, id) => LaunchMode::Fresh {
                        session_id: id.clone().map(agents::NativeSessionId::new),
                    },
                };
                let spec = adapter.launch(&ctx, &mode);
                for file in &spec.files {
                    if let Some(dir) = file.path.parent() {
                        let _ = std::fs::create_dir_all(dir);
                    }
                    if let Err(e) = std::fs::write(&file.path, &file.contents) {
                        return Err((
                            OpError::SpawnFailed,
                            format!("{}: {e}", file.path.display()),
                        ));
                    }
                }
                let line = spec.shell_line();
                if let Some(session) = &session_id {
                    self.ws.accounts.pin(*kind, session, &account.id);
                }
                // integration for that shell. Interactive, so rc files set `PATH` as in any
                // pane and the install check holds.
                let pre = pre.as_deref().unwrap_or_default();
                cmd.args(["-i", "-l", "-c", &format!("{pre}{line}; {}", then_shell())]);
                for (k, v) in &spec.env {
                    cmd.env(k, v);
                }
                for k in &spec.env_remove {
                    cmd.env_remove(k);
                }
                agent = Some((
                    *kind,
                    session_id,
                    account.id,
                    AgentRuntime::new(*kind, id, adapter, restored),
                ));
            }
            PaneLaunch::Canvas { .. } => unreachable!("canvas panes returned above"),
        }
        let worktree =
            self.ws
                .worktrees
                .port_for(std::path::Path::new(&cwd))
                .map(|(path, port)| WorktreeRecord {
                    path: path.to_string_lossy().into_owned(),
                    port,
                });
        if let Some(wt) = &worktree {
            cmd.env("PORT", wt.port.to_string());
            cmd.env(brand::env_var("WORKTREE"), &wt.path);
        }
        cmd.current_dir(&cwd);
        // SAFETY: runs between fork and exec and only calls `setrlimit`.
        unsafe {
            std::os::unix::process::CommandExt::pre_exec(
                &mut cmd,
                crate::limits::restore_for_child,
            );
        }
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        cmd.env(brand::env_var("PANE_ID"), id.0.to_string());
        for (k, v) in self
            .askpass
            .pane_env(self, id)
            .into_iter()
            .chain(self.browser.pane_env(self, id))
        {
            cmd.env(k, v);
        }
        for (k, v) in &self.cfg.pane_env {
            cmd.env(k, OsString::from(v));
        }
        for (k, v) in &inject_env {
            cmd.env(k, v);
        }
        let (cols, rows) = self.cfg.default_size;
        let size = PaneSize {
            cols,
            rows,
            width_px: 0,
            height_px: 0,
        };
        let (pane, vt_events) = Pane::spawn(
            id,
            SnapGen(self.epoch.0),
            cmd,
            size,
            self.cfg.ring_capacity,
            crate::pane::VtLimits {
                scrollback_bytes: self.cfg.scrollback_bytes,
                image_storage_bytes: self.cfg.image_storage_bytes,
            },
        )
        .map_err(|e| (OpError::SpawnFailed, e.to_string()))?;
        let record = PaneRecord {
            // A sign-in is not run again after a restart.
            launch: match &launch {
                PaneLaunch::AccountSignIn { .. } => PaneLaunch::Shell {
                    cwd: Some(cwd.clone()),
                },
                launch => launch.clone(),
            },
            cwd: Some(cwd.clone()),
            agent: agent
                .as_ref()
                .map(|(kind, session_id, account, _)| AgentRecord {
                    kind: *kind,
                    session_id: session_id.clone(),
                    account: Some(account.clone()),
                }),
            worktree,
        };
        let accounts_changed = agent.is_some();
        let entry = Arc::new(PaneEntry {
            pane,
            meta: Mutex::new(MetaState {
                cwd: Some(cwd),
                ..MetaState::default()
            }),
            record: Mutex::new(record),
            agent: Mutex::new(agent.map(|(_, _, _, rt)| rt)),
            agent_attached: Notify::new(),
            ticks: AtomicU64::new(0),
            task: Mutex::new(None),
            launched_at: SystemTime::now(),
        });
        let task = tokio::spawn(pane_task(Arc::clone(self), Arc::clone(&entry), vt_events));
        *lock(&entry.task) = Some(task.abort_handle());
        lock(&self.panes).insert(id, entry);
        if accounts_changed {
            self.emit(Event::Accounts);
        }
        Ok(())
    }

    // --- accounts ---------------------------------------------------------------------------

    /// The accounts report, with the account of every agent pane.
    pub fn accounts_report(&self) -> proto::AccountsReport {
        let mut panes: Vec<proto::PaneAccount> = self
            .pane_entries()
            .into_iter()
            .filter_map(|(id, entry)| {
                let record = lock(&entry.record);
                let agent = record.agent.as_ref()?;
                Some(proto::PaneAccount {
                    pane_id: id,
                    agent: agent.kind,
                    account: agent
                        .account
                        .clone()
                        .unwrap_or_else(|| proto::SYSTEM_ACCOUNT.into()),
                })
            })
            .collect();
        panes.sort_by_key(|p| p.pane_id.0);
        self.ws.accounts.report(panes)
    }

    /// The account a daemon-launched agent pane runs under.
    pub fn pane_account(&self, pane: PaneId) -> Option<(AgentKind, String)> {
        let entry = self.pane(pane)?;
        let record = lock(&entry.record);
        let agent = record.agent.as_ref()?;
        Some((
            agent.kind,
            agent
                .account
                .clone()
                .unwrap_or_else(|| proto::SYSTEM_ACCOUNT.into()),
        ))
    }

    /// Asks the agent about an account in the background; clients hear of a change.
    pub fn check_account(&self, agent: AgentKind, id: String) {
        let accounts = Arc::clone(&self.ws.accounts);
        let tools = self.ws.tools.clone();
        let events = self.events.clone();
        tokio::spawn(async move {
            if let Ok((_, true)) = accounts.check(&tools, agent, &id).await {
                let _ = events.send(Event::Accounts);
            }
        });
    }

    // --- agents -----------------------------------------------------------------------------

    /// Broadcasts an agent event and refreshes the pane's metadata and record.
    pub fn agent_event(&self, id: PaneId, event: Option<agents::AgentEvent>) {
        self.agent_attention(id);
        let Some(event) = event else {
            return;
        };
        self.agent_turn(id, &event);
        if let Some(entry) = self.pane(id) {
            let native = event.session.native_id.as_ref().map(|n| n.to_string());
            let mut record = lock(&entry.record);
            if let (Some(agent), Some(native)) = (record.agent.as_mut(), native)
                && agent.session_id.as_deref() != Some(native.as_str())
            {
                let account = agent.account.as_deref().unwrap_or(proto::SYSTEM_ACCOUNT);
                self.ws.accounts.pin(agent.kind, &native, account);
                agent.session_id = Some(native);
                self.mark_dirty();
            }
        }
        match serde_json::to_string(&event) {
            Ok(json) => self.emit(Event::Agent {
                pane_id: id,
                json: json.into(),
            }),
            Err(e) => tracing::warn!("serializing agent event: {e}"),
        }
        self.emit(Event::PaneMeta(id));
    }

    /// Snapshots the worktree at agent turn boundaries ("what did this turn change").
    fn agent_turn(&self, id: PaneId, event: &agents::AgentEvent) {
        use agents::EventKind;
        if event.subagent.is_some() {
            return;
        }
        match event.kind {
            EventKind::TurnStarted => {
                // The agent's own directory (from its hooks) first, then the pane's.
                let cwd = event
                    .session
                    .cwd
                    .clone()
                    .filter(|c| c.is_dir())
                    .or_else(|| {
                        self.pane(id).and_then(|e| {
                            let meta = lock(&e.meta).cwd.clone();
                            meta.or_else(|| lock(&e.record).cwd.clone())
                                .map(PathBuf::from)
                        })
                    });
                if let Some(cwd) = cwd {
                    self.ws
                        .turns
                        .record(crate::ws::turns::Boundary::Start { pane: id, cwd });
                }
                crate::approve::turn_started(self, id);
            }
            EventKind::SessionStarted | EventKind::SessionIdChanged => {
                crate::approve::session_over(self, id);
            }
            EventKind::TurnEnded
            | EventKind::Interrupted
            | EventKind::Error
            | EventKind::SessionEnded => {
                if let (Some(turn), Some(entry)) = (&event.turn, self.pane(id)) {
                    let mut meta = lock(&entry.meta);
                    meta.turns += 1;
                    meta.last_turn = Some(LastTurn {
                        outcome: turn.outcome,
                        message: turn.last_message.clone(),
                        at: proto::UnixMillis(crate::identity::now_millis()),
                        transcript: event.session.transcript.clone(),
                    });
                }
                self.ws
                    .turns
                    .record(crate::ws::turns::Boundary::End { pane: id });
                self.work_done(id);
                if event.kind == EventKind::SessionEnded {
                    crate::approve::session_over(self, id);
                }
            }
            _ => {}
        }
    }

    /// Turns the agent's notifications into attention items, and retires blocked items once
    /// the agent is no longer blocked.
    fn agent_attention(&self, id: PaneId) {
        use crate::ws::AgentNotice;
        let Some(entry) = self.pane(id) else {
            return;
        };
        let (kind, notices, blocked, wire) = {
            let mut agent = lock(&entry.agent);
            let Some(rt) = agent.as_mut() else {
                return;
            };
            let notices = rt.take_notices();
            let wire = (!notices.is_empty()).then(|| rt.wire_status());
            (rt.kind(), notices, rt.is_blocked(), wire)
        };
        for (notify, event) in notices {
            let message = event
                .as_ref()
                .and_then(|e| e.turn.as_ref())
                .and_then(|t| t.last_message.as_deref())
                .map(notice_text);
            let notice = match notify {
                agents::Notify::Blocked { .. } => {
                    let (request_id, summary) = match &wire {
                        Some(proto::AgentStatus {
                            state: proto::AgentState::Blocked(b),
                            ..
                        }) => (Some(b.request_id), b.summary.clone()),
                        _ => (None, String::new()),
                    };
                    AgentNotice::Blocked {
                        request_id,
                        summary,
                    }
                }
                agents::Notify::Done => AgentNotice::Done { message },
                agents::Notify::Failed => AgentNotice::Failed { message },
            };
            crate::ws::agent_notice(self, id, kind, notice);
        }
        // Votes and claims belong to one request; drop them once the agent moved on, and
        // tell clients the risk of a new one so they can say who may answer it.
        let open = self.open_request(id);
        self.mp.approvals.forget_pane_except(id, open);
        if let Some(request) = open
            && let Some((_, facts)) = self.request_facts(request, None)
        {
            let policy = self.mp.policy_of_pane(self, id);
            let risk = proto::Risk::of_tool(facts.tool.as_deref());
            if let Some(status) = self.mp.approvals.open(policy, id, request, risk) {
                self.emit(Event::ApprovalStatus(status));
            }
        }
        if !blocked {
            crate::ws::agent_unblocked(self, id);
            self.approvals.clear_request(id);
        }
    }

    /// Applies a client's decision on an approval request; returns the broadcast and what
    /// was decided, for the audit log.
    ///
    /// `record` runs once the decision is accepted and before the hook is answered or anyone
    /// is told, so the audit log never lags behind what the agent did.
    pub fn decide(
        &self,
        actor: Actor,
        decide: &Decide,
        record: impl FnOnce(&Decided, &crate::agent::DecidedRequest),
    ) -> Result<Decided, Option<Actor>> {
        self.decide_with(actor, decide, None, record)
    }

    /// [`Core::decide`], allowing with `edited` as the command to run instead when given (the
    /// caller checked that the request takes edited input and that the option allows it).
    pub fn decide_with(
        &self,
        actor: Actor,
        decide: &Decide,
        edited: Option<&str>,
        record: impl FnOnce(&Decided, &crate::agent::DecidedRequest),
    ) -> Result<Decided, Option<Actor>> {
        if self.term.asks.caller_of(decide.request_id).is_some() {
            // A drive request runs exactly the action asked; it has no edited form.
            if edited.is_some() {
                return Err(None);
            }
            return self
                .term
                .asks
                .decide(self, actor, decide, record)
                .ok_or(None);
        }
        for (id, entry) in self.pane_entries() {
            let mut agent = lock(&entry.agent);
            let Some(rt) = agent.as_mut() else {
                continue;
            };
            if !rt.knows_request(decide.request_id) {
                continue;
            }
            let outcome = rt.decide(decide.request_id, decide.option_id, actor);
            drop(agent);
            return match outcome {
                Ok(details) => {
                    let decided = Decided {
                        pane_id: id,
                        request_id: decide.request_id,
                        option_id: decide.option_id,
                        decided_by: actor,
                        at: proto::UnixMillis(crate::identity::now_millis()),
                    };
                    record(&decided, &details);
                    match edited {
                        Some(command) => {
                            self.hooks.resolve_edited(id, &details.request, command);
                        }
                        None => self.hooks.resolve(id, &details.request, details.choice),
                    }
                    self.approvals.clear_request(id);
                    self.emit(Event::Decided(decided));
                    self.emit(Event::PaneMeta(id));
                    Ok(decided)
                }
                Err(by) => Err(by),
            };
        }
        Err(None)
    }
}

/// The current echo facts and verdict for a pane.
fn compute_hint(entry: &PaneEntry) -> (EchoHint, Prediction) {
    let echo = entry.pane.echo();
    let alt = entry.pane.alt_screen();
    let at_prompt = lock(&entry.meta).at_prompt;
    let hint = EchoHint {
        pane_id: entry.pane.id,
        echo: echo.echo,
        icanon: echo.canonical,
        alt_screen: alt,
        at_prompt,
    };
    (
        hint,
        Prediction::decide(echo.echo, echo.canonical, alt, at_prompt),
    )
}

/// Publishes the echo hint if it changed.
fn refresh_hint(core: &Core, entry: &PaneEntry) {
    let (hint, prediction) = compute_hint(entry);
    let changed = {
        let mut meta = lock(&entry.meta);
        let changed = meta.last_hint != Some((hint, prediction));
        meta.last_hint = Some((hint, prediction));
        changed
    };
    if changed {
        core.emit(Event::Echo(EchoHintAt {
            hint,
            at_seq: entry.pane.head(),
            prediction,
        }));
    }
}

/// How long a closed pane's process may outlive its hangup before it is killed.
const HANGUP_GRACE: Duration = Duration::from_secs(3);

/// Kills a closed pane's process group if it is still running after [`HANGUP_GRACE`]: a
/// program that ignores SIGHUP (`nohup`, `trap '' HUP`) would otherwise run on unseen, holding
/// the pane's threads, for as long as the daemon runs.
fn kill_if_lingering(pane: Arc<Pane>) {
    let Ok(runtime) = tokio::runtime::Handle::try_current() else {
        return;
    };
    runtime.spawn(async move {
        if tokio::time::timeout(HANGUP_GRACE, pane.pty().wait())
            .await
            .is_err()
        {
            tracing::debug!(pane = %pane.id, "process ignored the hangup; killing it");
            let _ = pane.pty().signal_group(pty::Signal::Kill);
        }
    });
}

/// Connections one device may hold at once: the app and its extensions, with room to spare.
const MAX_CONNS_PER_DEVICE: usize = 16;

/// How often a pane task checks for agents and feeds agent timers.
const PANE_TICK: Duration = Duration::from_millis(500);
/// How long after its last event a pane without an agent keeps ticking: long enough to see a
/// program that was just started become an agent.
const PANE_ACTIVE: Duration = Duration::from_secs(5);
/// Title and directory changes reach clients at most this often per pane (the last one always
/// arrives): a program that sets its title in a loop must not flood every client.
const META_INTERVAL: Duration = Duration::from_millis(50);

/// Per-pane task: turns VT events, termios changes, agent timers and process exit into
/// metadata, echo hints and agent events.
async fn pane_task(core: Arc<Core>, entry: Arc<PaneEntry>, mut vt_events: mpsc::Receiver<VtEvent>) {
    let id = entry.pane.id;
    let pane = Arc::clone(&entry.pane);
    let mut echo = pane.echo_updates();
    let exit = pane.pty().wait();
    tokio::pin!(exit);
    let mut agent_tick = tokio::time::interval(PANE_TICK);
    agent_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // Ticks run while an agent is attached or for a while after the pane did anything: a
    // quiet shell pane costs no wakeups.
    let mut active_until = Instant::now() + PANE_ACTIVE;
    let mut screen_dirty = false;
    let mut detect_tick = 0u32;
    let codex_lookup = Arc::new(AtomicBool::new(false));
    let mut meta_sent: Option<Instant> = None;
    let mut meta_due: Option<tokio::time::Instant> = None;
    refresh_hint(&core, &entry);
    loop {
        let ticking = Instant::now() < active_until || lock(&entry.agent).is_some();
        tokio::select! {
            event = vt_events.recv() => {
                let Some(event) = event else { break };
                active_until = Instant::now() + PANE_ACTIVE;
                match event {
                    VtEvent::Reply(bytes) => {
                        let _ = pane.pty().try_write(bytes);
                    }
                    VtEvent::Activity => {
                        screen_dirty = true;
                        if lock(&entry.meta).secret_prompt.is_some()
                            || pane.echo().is_hidden_input()
                        {
                            crate::askpass::detect(&core, &entry);
                        }
                        if let Some(rt) = lock(&entry.agent).as_mut() {
                            rt.pty_output();
                        }
                    }
                    VtEvent::AltScreen => {
                        refresh_hint(&core, &entry);
                        crate::askpass::detect(&core, &entry);
                    }
                    VtEvent::Osc(osc) => {
                        handle_osc(&core, &entry, osc);
                    }
                    VtEvent::Command(update) => handle_command(&core, &entry, update),
                }
            }
            () = pane.latest_meta().changed.notified() => {
                active_until = Instant::now() + PANE_ACTIVE;
                let latest = pane.latest_meta().take();
                let mut changed = false;
                if let Some(title) = latest.title {
                    changed |= handle_osc(&core, &entry, Osc::Title(title));
                }
                if let Some(cwd) = latest.cwd {
                    changed |= handle_osc(&core, &entry, Osc::Cwd(cwd));
                }
                if changed && meta_due.is_none() {
                    match meta_sent {
                        Some(t) if t.elapsed() < META_INTERVAL => {
                            meta_due = Some((t + META_INTERVAL).into());
                        }
                        _ => {
                            meta_sent = Some(Instant::now());
                            core.emit(Event::PaneMeta(id));
                        }
                    }
                }
            }
            () = sleep_until_some(meta_due) => {
                meta_due = None;
                meta_sent = Some(Instant::now());
                core.emit(Event::PaneMeta(id));
            }
            () = entry.agent_attached.notified() => {}
            changed = echo.changed() => {
                if changed.is_err() {
                    continue;
                }
                active_until = Instant::now() + PANE_ACTIVE;
                refresh_hint(&core, &entry);
                crate::askpass::detect(&core, &entry);
            }
            status = &mut exit => {
                let code = status.ok().and_then(|s| s.code());
                lock(&entry.meta).exit = code;
                let update = lock(&entry.agent).as_mut().map(AgentRuntime::process_exited);
                core.agent_event(id, update.flatten());
                core.emit(Event::PaneMeta(id));
                // Let the last output reach subscribers before the pane disappears.
                tokio::time::sleep(Duration::from_millis(100)).await;
                core.pane_exited(id);
                break;
            }
            _ = agent_tick.tick(), if ticking => {
                entry.ticks.fetch_add(1, Ordering::Relaxed);
                detect_tick += 1;
                if detect_tick.is_multiple_of(2) {
                    if lock(&entry.agent).is_none() {
                        detect_agent(&entry);
                    } else {
                        end_exited_agent(&core, &entry);
                    }
                }
                if detect_tick.is_multiple_of(2) {
                    capture_codex_session(&core, &entry, &codex_lookup);
                }
                let screen = screen_dirty.then(|| pane.screen_text());
                screen_dirty = false;
                if let Some(screen) = &screen {
                    core.ws.ports.observe_screen(id, screen);
                }
                let title = lock(&entry.meta).title.clone();
                let update = lock(&entry.agent)
                    .as_mut()
                    .map(|rt| rt.tick(screen.as_deref(), &title));
                if let Some(update) = update {
                    for event in update {
                        core.agent_event(id, Some(event));
                    }
                    // Notifications can come due on a timer without an event.
                    core.agent_event(id, None);
                }
            }
        }
    }
}

/// Sleeps until `at`, or forever without one.
async fn sleep_until_some(at: Option<tokio::time::Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

/// Applies an OSC sequence. Returns whether the pane's title or directory changed, which the
/// caller pushes to clients (rate-limited).
fn handle_osc(core: &Core, entry: &PaneEntry, osc: Osc) -> bool {
    let id = entry.pane.id;
    match osc {
        Osc::Title(title) => {
            let mut meta = lock(&entry.meta);
            let changed = meta.title != title;
            meta.title = title;
            return changed;
        }
        Osc::Cwd(cwd) => {
            let changed = lock(&entry.meta).cwd.as_deref() != Some(cwd.as_str());
            lock(&entry.meta).cwd = Some(cwd.clone());
            let mut record = lock(&entry.record);
            if record.cwd.as_deref() != Some(cwd.as_str()) {
                record.cwd = Some(cwd);
                core.mark_dirty();
            }
            return changed;
        }
        Osc::Clipboard(text) => {
            // Only the device that typed into the pane last copies (vim's `y`, tmux's copy
            // mode): never another participant's, and nobody's after an agent typed.
            let typed_by = lock(&entry.meta).typed_by;
            if let Some(conn) = typed_by {
                core.emit(Event::Clipboard {
                    conn,
                    pane_id: id,
                    text: text.into(),
                });
            }
        }
        Osc::Notify(body) => {
            let event = lock(&entry.agent).as_mut().and_then(|rt| rt.osc9(&body));
            core.agent_event(id, event);
        }
        Osc::ProgramStatus(body) => {
            // Reports about sub-records (`id=`) belong to the agent integrations below. Any
            // printed text can claim to be an agent: only a pane running one may.
            let has_agent = lock(&entry.agent).is_some();
            if let Some(report) = agents::ProgramStatus::parse(&body)
                .filter(|r| r.id.is_none())
                .filter(|r| has_agent || !crate::agent::names_an_agent(r))
            {
                core.set_program(entry, report);
            }
            let event = lock(&entry.agent)
                .as_mut()
                .and_then(|rt| rt.program_status(&body));
            core.agent_event(id, event);
        }
    }
    false
}

fn handle_command(core: &Core, entry: &PaneEntry, update: CommandUpdate) {
    match update {
        // 133;C: the command runs and owns the terminal.
        CommandUpdate::AtPrompt(at_prompt) => {
            lock(&entry.meta).at_prompt = at_prompt;
            refresh_hint(core, entry);
        }
        CommandUpdate::Mark(mark) => {
            let long = mark
                .finished
                .is_some_and(|f| f.duration_ms >= core.cfg.long_command.as_millis() as u64);
            if long && !core.pane_seen(mark.pane_id) {
                core.emit(Event::CommandUnseen(mark.clone()));
                crate::ws::command_unseen(core, &mark);
            }
            // A command starting or ending is when servers come and go.
            core.ws.ports.trigger.notify_one();
            crate::assist::command_finished(core, entry, &mark);
            if mark.finished.is_some() {
                core.work_done(mark.pane_id);
            }
            core.emit(Event::Command(mark));
        }
    }
}

/// While a launched Codex pane's session id is unknown, looks for it off the async runtime
/// (process table and file system) and records it when found.
fn capture_codex_session(core: &Arc<Core>, entry: &Arc<PaneEntry>, busy: &Arc<AtomicBool>) {
    let wanted = lock(&entry.record)
        .agent
        .as_ref()
        .is_some_and(|a| a.kind == AgentKind::Codex && a.session_id.is_none());
    if !wanted || busy.swap(true, Ordering::AcqRel) {
        return;
    }
    let claimed: Vec<String> = core
        .pane_entries()
        .iter()
        .filter_map(|(_, e)| lock(&e.record).agent.as_ref()?.session_id.clone())
        .collect();
    let cwd = lock(&entry.record).cwd.clone().unwrap_or_default();
    let account = lock(&entry.record)
        .agent
        .as_ref()
        .and_then(|a| a.account.clone())
        .unwrap_or_else(|| proto::SYSTEM_ACCOUNT.into());
    // Rollouts are under the pane's account's home.
    let codex_home = core
        .ws
        .accounts
        .context(AgentKind::Codex, &account)
        .and_then(|a| a.dir)
        .or_else(|| core.cfg.pane_var("CODEX_HOME").map(PathBuf::from))
        .or_else(|| {
            core.cfg
                .pane_var("HOME")
                .map(|h| PathBuf::from(h).join(".codex"))
        });
    let root = entry.pane.pty().pid();
    let since = entry.launched_at;
    let (core, entry, busy) = (Arc::clone(core), Arc::clone(entry), Arc::clone(busy));
    tokio::task::spawn_blocking(move || {
        let found = crate::codex_session::from_open_files(root).or_else(|| {
            let home = codex_home?;
            crate::codex_session::from_rollouts(&home, std::path::Path::new(&cwd), since, &claimed)
        });
        if let Some(session_id) = found {
            let mut record = lock(&entry.record);
            if let Some(agent) = record.agent.as_mut()
                && agent.session_id.is_none()
            {
                tracing::info!(pane = %entry.pane.id, %session_id, "codex session found");
                core.ws
                    .accounts
                    .pin(AgentKind::Codex, &session_id, &account);
                agent.session_id = Some(session_id);
                core.mark_dirty();
            }
        }
        busy.store(false, Ordering::Release);
    });
}

/// Starts tracking an agent the user launched by hand (no hooks, screen and OSC only).
fn detect_agent(entry: &PaneEntry) {
    let Some(fg) = entry.pane.pty().foreground_process() else {
        return;
    };
    let kind = match fg.program() {
        "claude" => AgentKind::Claude,
        "codex" => AgentKind::Codex,
        _ => return,
    };
    let adapter = crate::agent::adapter(kind);
    let mut rt = AgentRuntime::new(kind, entry.pane.id, adapter, false);
    rt.note_process(fg.pid);
    *lock(&entry.agent) = Some(rt);
}

/// Ends the pane's agent once its process exited and the pane is back at its shell: the
/// pane is a shell again, on every client and after a restore.
fn end_exited_agent(core: &Core, entry: &PaneEntry) {
    let foreground = entry.pane.pty().foreground_process();
    // A launched agent's pane at its own shell, past the `sh -c` that ran the agent.
    let launched = matches!(lock(&entry.record).launch, PaneLaunch::Agent { .. });
    let at_shell = launched
        && foreground.as_ref().is_some_and(|fg| {
            fg.pid == entry.pane.pty().pid()
                && !fg.argv.is_empty()
                && !fg.argv.iter().any(|a| a == "-c")
        });
    let event = {
        let mut agent = lock(&entry.agent);
        let Some(rt) = agent.as_mut() else {
            return;
        };
        if !rt.process_gone(foreground.as_ref(), at_shell, |pid| {
            pty::ForegroundProcess::of(pid).is_some()
        }) {
            return;
        }
        rt.process_exited()
    };
    let id = entry.pane.id;
    tracing::info!(pane = %id, "agent exited");
    // While the runtime is still there, so its open requests are retired.
    core.agent_event(id, event);
    *lock(&entry.agent) = None;
    {
        let mut record = lock(&entry.record);
        if let PaneLaunch::Agent { cwd, .. } = &record.launch {
            record.launch = PaneLaunch::Shell { cwd: cwd.clone() };
        }
        record.agent = None;
    }
    core.mark_dirty();
    core.emit(Event::PaneMeta(id));
}

/// Quotes `s` for a POSIX shell as one word.
pub(crate) fn shell_quote(s: &str) -> String {
    if !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"/._-+=:,@".contains(&b))
    {
        return s.to_owned();
    }
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// Restores the saved layout, respawning every pane (agents resume their sessions).
pub(crate) fn restore(
    core: &Arc<Core>,
    panes: HashMap<PaneId, PaneRecord>,
    closed: Vec<ClosedPane>,
) {
    core.restore_closed(closed);
    let ids = lock(&core.layout).all_panes();
    let mut failed = Vec::new();
    for id in ids {
        // Canvas panes run nothing; the artifact store remembers them.
        if core.art.is_canvas(id) {
            continue;
        }
        let Some(record) = panes.get(&id).cloned() else {
            failed.push(id);
            continue;
        };
        let mut launch = record.launch.clone();
        let restored_agent = match (&mut launch, &record.agent) {
            (PaneLaunch::Agent { resume, cwd, .. }, Some(agent)) => {
                *resume = agent.session_id.clone();
                *cwd = record.cwd.clone().or(cwd.take());
                let resumed = agent.session_id.is_some();
                // Back under the account it ran under.
                if let PaneLaunch::Agent {
                    agent: kind,
                    resume,
                    cwd,
                } = &launch
                {
                    launch = PaneLaunch::AccountAgent {
                        agent: *kind,
                        account: agent.account.clone(),
                        resume: resume.clone(),
                        cwd: cwd.clone(),
                    };
                }
                resumed
            }
            (PaneLaunch::Shell { cwd }, _) => {
                *cwd = record.cwd.clone();
                false
            }
            // A one-off command is not re-run on restore; the pane comes back as a shell.
            (PaneLaunch::Command { cwd, .. }, _) => {
                launch = PaneLaunch::Shell {
                    cwd: record.cwd.clone().or(cwd.take()),
                };
                false
            }
            _ => false,
        };
        if let Err((_, e)) = core.spawn_pane(id, launch, None, restored_agent) {
            tracing::warn!(pane = %id, "restoring pane failed: {e}");
            failed.push(id);
        }
    }
    for id in failed {
        let _ = lock(&core.layout).close_pane(id);
    }
}

/// Saved state, for [`persist`].
pub(crate) fn saved_state(core: &Core) -> persist::Saved {
    let layout = lock(&core.layout).clone();
    let panes = core
        .pane_entries()
        .into_iter()
        .map(|(id, e)| (id.0, lock(&e.record).clone()))
        .collect();
    persist::Saved::new(layout, panes, core.closed_panes()).with_creators(core.term.creators())
}

/// A notification's share of an agent's message.
fn notice_text(message: &str) -> String {
    const MAX: usize = 500;
    match message.char_indices().nth(MAX) {
        Some((cut, _)) => format!("{}…", &message[..cut]),
        None => message.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A quiet shell pane with no agent and no client does no periodic work: dozens of idle
    /// panes must not mean dozens of wakeups a second.
    #[tokio::test(flavor = "multi_thread")]
    async fn idle_panes_stop_ticking() {
        let dir = tempfile::tempdir().unwrap();
        let mut config = Config::new(dir.path());
        config.relay = crate::RelayMode::Disabled;
        config.bind = Some("127.0.0.1:0".parse().unwrap());
        config.shell = Some("/bin/sh".into());
        config.pane_env = vec![("PS1".into(), "$ ".into()), ("ENV".into(), String::new())];
        let daemon = crate::Daemon::start(config).await.unwrap();
        let core = Arc::clone(&daemon.core);
        for i in 0..3 {
            let launch = PaneLaunch::Shell { cwd: None };
            core.create_session(format!("s{i}"), launch).unwrap();
        }
        let ticks = || -> u64 {
            core.pane_entries()
                .iter()
                .map(|(_, e)| e.ticks.load(Ordering::Relaxed))
                .sum()
        };
        // Busy right after start (the shell prints its prompt), then quiet.
        tokio::time::sleep(PANE_ACTIVE + Duration::from_secs(2)).await;
        let settled = ticks();
        assert!(settled > 0, "panes tick while they start");
        tokio::time::sleep(PANE_TICK * 6).await;
        assert_eq!(ticks(), settled, "idle panes kept ticking");

        // Output makes a pane tick again.
        let (_, entry) = core.pane_entries().remove(0);
        entry.pane.pty().try_write(b"echo hi\n".to_vec()).unwrap();
        tokio::time::sleep(PANE_TICK * 3).await;
        assert!(ticks() > settled, "a pane with output ticks");
        daemon.shutdown().await;
    }
}
