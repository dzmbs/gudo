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
use crate::mp::Authz;
use crate::mp::policy::{Need, Target};
use crate::osc::Osc;
use crate::pane::{Pane, VtEvent};
use crate::persist;
use crate::shell::ShellIntegration;
use crate::sizing::{EmptyGrid, SizeChoice, Sizing};
use crate::ws::Viewer;

/// How long a float that closes when its work is done stays to show the outcome.
const FLOAT_LINGER: std::time::Duration = std::time::Duration::from_millis(2500);

/// Identifies one client connection for the daemon's lifetime.
pub(crate) type ConnId = u64;

/// The panes a connection shows (focused and visible), and whose they are.
pub(crate) struct View {
    pub device: proto::DeviceId,
    pub viewer: Viewer,
    pub panes: Vec<PaneId>,
}

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
    /// A shell-integration mark, scoped when emitted rather than after its pane may disappear.
    Command {
        session: Option<SessionId>,
        mark: CommandMark,
    },
    /// A long command finished while no client showed its pane.
    CommandUnseen(CommandMark),
    /// The detected ports changed (read the list from `ws.ports`).
    Ports,
    /// An attention item was added (`Added`, as the owner sees it).
    Attention(proto::AttentionUpdate),
    /// Attention items were marked seen by `by`, or by everyone (`None`).
    AttentionSeen {
        by: Option<Viewer>,
        ids: Vec<u64>,
    },
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
    /// Someone other than the owner answered an agent's request.
    GuestAnswered(proto::GuestAnswer),
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
    /// The worktree the pane runs in and the `PORT` it was given.
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
    pub size_policy: Option<SizePolicy>,
    /// The connection that typed into the pane last; `None` once an agent typed, or it left.
    pub typed_by: Option<ConnId>,
    /// The connection whose theme the pane's color replies use; `None`: the latest theme.
    pub theme_by: Option<ConnId>,
    pub at_prompt: bool,
    pub last_hint: Option<(EchoHint, Prediction)>,
    /// The password prompt on the cursor row while input is hidden (`askpass::detect`).
    pub secret_prompt: Option<String>,
    /// The program's own last OSC 7501 report (or `status_set`), whatever the program, or
    /// its progress report (OSC 9;4) when it sends no status of its own.
    pub program: Option<agents::ProgramStatus>,
    /// `program` came from a progress report.
    pub program_from_progress: bool,
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

#[derive(Clone, Copy)]
enum ResizeTiming {
    Immediate,
    Deferred,
    BeforeInput,
}

struct PendingResize {
    choice: SizeChoice,
    due: tokio::time::Instant,
    ownership_changed: bool,
}

pub(crate) struct PaneEntry {
    pub pane: Arc<Pane>,
    pub meta: Mutex<MetaState>,
    pub record: Mutex<PaneRecord>,
    pub agent: Mutex<Option<AgentRuntime>>,
    pub codex: Mutex<Option<Arc<crate::agent_driver::codex::Live>>>,
    /// Wakes the pane task when an agent attaches from outside it (a hook), so its timers run.
    pub agent_attached: Notify,
    /// Serializes policy decisions, request replacement and actual PTY resizes.
    sizing: Mutex<Sizing>,
    pending_resize: Mutex<Option<PendingResize>>,
    resize_changed: Notify,
    /// Periodic ticks the pane task has run.
    ticks: AtomicU64,
    task: Mutex<Option<AbortHandle>>,
    /// When the pane's process started, for matching a Codex rollout to it.
    launched_at: SystemTime,
}

impl PaneEntry {
    /// Stops the pane's task, which reacts to its output and exit.
    pub fn stop_task(&self) {
        lock(&self.codex).take();
        if let Some(task) = lock(&self.task).take() {
            task.abort();
        }
    }

    /// Whether the pane existed at `at` (its process started no later).
    pub fn existed_at(&self, at: proto::UnixMillis) -> bool {
        let started = self
            .launched_at
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since_epoch| since_epoch.as_millis() as u64);
        started <= at.0
    }
}

/// Longest message or title kept from a program's own status report, in characters.
const PROGRAM_TEXT_CHARS: usize = 512;

/// A report as clients see it; `None` for `Clear`.
fn program_report(status: &agents::ProgramStatus) -> Option<proto::ProgramReport> {
    use agents::{ProgramKind, ProgramState};
    let state = match status.state {
        ProgramState::Idle => proto::ProgramState::Idle,
        ProgramState::Working => proto::ProgramState::Working,
        ProgramState::Done => proto::ProgramState::Done,
        ProgramState::Blocked => proto::ProgramState::Blocked,
        ProgramState::Error => proto::ProgramState::Error,
        ProgramState::Clear => return None,
    };
    Some(proto::ProgramReport {
        state,
        kind: status.kind.map(|kind| match kind {
            ProgramKind::Permission => proto::ProgramKind::Permission,
            ProgramKind::Question => proto::ProgramKind::Question,
            ProgramKind::Auth => proto::ProgramKind::Auth,
        }),
        app: status.app.clone(),
        message: status.msg.clone(),
        progress: status.progress,
    })
}

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

pub(crate) struct Core {
    pub cfg: Config,
    pub power: crate::power::Power,
    /// The session's run: the same across hot upgrades, which keep panes and streams.
    pub epoch: SessionEpoch,
    /// The snapshot generation of panes this process starts, unlike any a previous build
    /// handed over.
    pane_gen: SnapGen,
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
    /// Panes each connection shows (focused and visible).
    views: Mutex<HashMap<ConnId, View>>,
    /// Developer-workflow state: ports, attention, turns, editors, worktrees.
    pub ws: crate::ws::Ws,
    /// Push registrations and delivery (docs/PUSH.md).
    pub push: crate::notifier::Push,
    /// Multiplayer: grants, leases, presence, audit.
    pub mp: crate::mp::Mp,
    /// Drawings and images.
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
    /// Clients' terminal themes, for programs' color queries (`theme`).
    pub themes: crate::theme::Themes,
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
    weak_self: std::sync::Weak<Core>,
}

impl Core {
    pub fn new(
        config: Config,
        identity: Arc<Identity>,
        layout: Layout,
        hooks: HookServer,
        shell: Option<ShellIntegration>,
        mp: crate::mp::Mp,
        carried_epoch: Option<SessionEpoch>,
    ) -> Arc<Self> {
        let (events, _) = broadcast::channel(1024);
        let ws = crate::ws::Ws::new(&config, events.clone());
        let started = crate::identity::now_millis();
        Arc::new_cyclic(|weak_self| Self {
            weak_self: weak_self.clone(),
            epoch: carried_epoch.unwrap_or(SessionEpoch(started)),
            pane_gen: SnapGen(started),
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
            push: crate::notifier::Push::load(&config.state_dir),
            mp,
            art: crate::art::Art::open(&config.state_dir, config.artifacts),
            assist: crate::assist::Assist::new(&config),
            term: crate::term::Term::default(),
            upgrade: crate::upgrade::Upgrade::new(config.exe.as_deref()),
            inputs: crate::resume::InputStreams::default(),
            askpass: crate::askpass::Askpass::install(
                &config.askpass,
                &config.state_dir,
                &config.hook_bin(),
            ),
            approvals: crate::approve::Approvals::default(),
            browser: crate::browser::Browser::install(&config.state_dir, &config.hook_bin()),
            themes: crate::theme::Themes::default(),
            power: crate::power::Power::load(&config.state_dir),
            cfg: config,
            connected: AtomicUsize::new(0),
            device_conns: Mutex::default(),
            client_arrived: Notify::new(),
        })
    }

    /// A client connected (`true`) or left.
    pub fn client_connected(&self, connected: bool) {
        if connected {
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
            conns.retain(|(conn_id, _)| *conn_id != id);
            if conns.is_empty() {
                all.remove(&device);
            }
        }
    }

    pub fn connected_clients(&self) -> usize {
        self.connected.load(Ordering::Relaxed)
    }

    /// Records the panes `conn` shows.
    pub fn set_view(&self, conn: ConnId, view: View, authz: &Authz) {
        let visible: HashSet<_> = view.panes.iter().copied().collect();
        let previous = lock(&self.views).insert(conn, view);
        for (pane_id, entry) in self.pane_entries() {
            let was_visible = previous
                .as_ref()
                .is_some_and(|view| view.panes.contains(&pane_id));
            let is_visible = visible.contains(&pane_id);
            if was_visible != is_visible {
                let activity = if is_visible {
                    proto::PaneActivity::Active
                } else {
                    proto::PaneActivity::Inactive
                };
                let mut sizing = lock(&entry.sizing);
                sizing.view_activity(conn, authz, activity);
                self.select_client_size(&entry, &mut sizing, ResizeTiming::Immediate);
            }
        }
    }

    /// Who shows `pane` now.
    pub fn pane_viewers(&self, pane: PaneId) -> Vec<Viewer> {
        let views = lock(&self.views);
        let mut viewers: Vec<Viewer> = views
            .values()
            .filter(|view| view.panes.contains(&pane))
            .map(|view| view.viewer)
            .collect();
        viewers.sort_unstable_by_key(|viewer| match viewer {
            Viewer::Owner => None,
            Viewer::Guest(principal) => Some(principal.0),
        });
        viewers.dedup();
        viewers
    }

    /// Whether one of the owner's devices shows `pane` (a guest watching it does not stand in
    /// for the owner).
    pub fn owner_shows(&self, pane: PaneId) -> bool {
        lock(&self.views)
            .values()
            .any(|view| view.viewer == Viewer::Owner && view.panes.contains(&pane))
    }

    /// Whether `device` is connected and showing some pane of this host (the app is in the
    /// foreground here, so it alerts in-app and a push would be a duplicate).
    pub fn device_active(&self, device: proto::DeviceId) -> bool {
        lock(&self.views)
            .values()
            .any(|view| view.device == device && !view.panes.is_empty())
    }

    pub fn emit(&self, event: Event) {
        if let Event::Lease(lease) = &event
            && let Some(entry) = self.pane(lease.pane_id)
        {
            let mut sizing = lock(&entry.sizing);
            self.select_client_size(&entry, &mut sizing, ResizeTiming::Immediate);
        }
        if matches!(event, Event::PaneMeta(_) | Event::PaneClosed(_)) {
            self.power.changed.notify_one();
        }
        let _ = self.events.send(event);
    }

    /// Captures a shell-integration mark's scope before queueing it for command subscribers.
    pub fn emit_command(&self, mark: CommandMark) {
        self.emit(Event::Command {
            session: self.session_of_pane(mark.pane_id),
            mark,
        });
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
            .map(|(id, entry)| (*id, Arc::clone(entry)))
            .collect()
    }

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
                .filter_map(|&id| layout.session(id))
                .flat_map(|session| &session.tabs)
                .flat_map(|tab| crate::layout::leaves(&tab.root))
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
            .flat_map(|view| view.panes.iter().copied())
            .collect()
    }

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
        for (_, entry) in self.pane_entries() {
            let mut sizing = lock(&entry.sizing);
            sizing.remove(conn);
            self.select_client_size(&entry, &mut sizing, ResizeTiming::Immediate);
            let mut meta = lock(&entry.meta);
            if meta.typed_by == Some(conn) {
                meta.typed_by = None;
            }
            if meta.theme_by == Some(conn) {
                meta.theme_by = None;
            }
        }
        self.themes.forget(conn);
    }

    /// `conn` announced its theme: panes it used last show it, and with `everywhere` (a grant
    /// over the whole host or session) so do panes no client used and panes started later.
    pub fn theme_announced(
        &self,
        conn: ConnId,
        colors: ghostty_vt::DefaultColors,
        everywhere: bool,
    ) {
        let colors = self.themes.announce(conn, colors, everywhere);
        for (_, entry) in self.pane_entries() {
            let shown_by = lock(&entry.meta).theme_by;
            if shown_by == Some(conn) || (everywhere && shown_by.is_none()) {
                entry.pane.set_colors(&colors);
            }
        }
    }

    /// `conn` focused or typed into a pane: its color replies follow `conn`'s theme.
    pub fn theme_used(&self, conn: ConnId, entry: &PaneEntry) {
        let Some(colors) = self.themes.of(conn) else {
            return;
        };
        let mut meta = lock(&entry.meta);
        if meta.theme_by == Some(conn) {
            return;
        }
        meta.theme_by = Some(conn);
        drop(meta);
        entry.pane.set_colors(&colors);
    }

    pub fn sessions_message(&self, scope: Scope) -> ServerCtl {
        let attached = lock(&self.attached).clone();
        let all = lock(&self.layout).summaries(|session| {
            attached
                .values()
                .filter(|&&attached_to| attached_to == session)
                .count() as u32
        });
        // Filtered after the layout lock is released: `session_visible` takes it again.
        let sessions = all
            .into_iter()
            .filter(|summary| self.session_visible(summary.session_id, scope))
            .collect();
        ServerCtl::Sessions { sessions }
    }

    /// Whether `inner` lies within `outer` in the current layout.
    pub fn scope_within(&self, inner: Scope, outer: Scope) -> bool {
        if inner == outer || outer == Scope::Daemon {
            return true;
        }
        let layout = lock(&self.layout);
        match (inner, outer) {
            (Scope::Tab(tab), Scope::Session(session)) => {
                layout.session_of_tab(tab) == Some(session)
            }
            (Scope::Pane(pane), Scope::Session(session)) => {
                layout.session_of_pane(pane) == Some(session)
            }
            (Scope::Pane(pane), Scope::Tab(tab)) => layout.tab_of_pane(pane) == Some(tab),
            _ => false,
        }
    }

    /// Whether a session holds anything a `scope` covers.
    pub fn session_visible(&self, session: SessionId, scope: Scope) -> bool {
        let layout = lock(&self.layout);
        match scope {
            Scope::Daemon => true,
            Scope::Session(scoped) => scoped == session,
            Scope::Tab(tab) => layout.session_of_tab(tab) == Some(session),
            Scope::Pane(pane) => layout.session_of_pane(pane) == Some(session),
        }
    }

    /// The most recently used session a `scope` can see.
    pub fn recent_session_in(&self, scope: Scope) -> Option<SessionId> {
        let layout = lock(&self.layout);
        match scope {
            Scope::Daemon => layout.most_recent(),
            Scope::Session(session) => layout.session(session).map(|_| session),
            Scope::Tab(tab) => layout.session_of_tab(tab),
            Scope::Pane(pane) => layout.session_of_pane(pane),
        }
    }

    /// A session's layout cut down to `scope`: a tab-scoped guest sees only its tab, a
    /// pane-scoped one only its pane (never learn which other panes exist).
    pub fn layout_for(&self, session: SessionId, scope: Scope) -> Option<SessionLayout> {
        let mut layout = lock(&self.layout).snapshot(session)?;
        match scope {
            Scope::Daemon | Scope::Session(_) => {}
            Scope::Tab(tab_id) => {
                layout.tabs.retain(|tab| tab.tab_id == tab_id);
                layout.active_tab = layout.tabs.first().map(|tab| tab.tab_id);
            }
            Scope::Pane(pane_id) => {
                layout
                    .tabs
                    .retain(|tab| crate::layout::leaves(&tab.root).any(|leaf| leaf == pane_id));
                for tab in &mut layout.tabs {
                    tab.root = proto::LayoutNode::Leaf(pane_id);
                    tab.focused = pane_id;
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
            Scope::Tab(tab) => Some(tab),
            Scope::Pane(pane) => layout.tab_of_pane(pane),
        };
        let proto::SessionProjects { projects, tabs, .. } = &mut all;
        tabs.retain(|membership| Some(membership.tab_id) == shown);
        projects.retain(|project| {
            tabs.iter()
                .any(|membership| membership.project == project.id)
        });
        Some(all)
    }

    /// A session's floating windows cut down to `scope`: a tab-scoped guest sees its tab's,
    /// a pane-scoped one none (it sees its pane alone, tiled).
    pub fn floats_for(&self, session: SessionId, scope: Scope) -> Option<proto::SessionFloats> {
        let layout = lock(&self.layout);
        let mut all = layout.floats(session)?;
        match scope {
            Scope::Daemon | Scope::Session(_) => {}
            Scope::Tab(tab) => all
                .floats
                .retain(|window| layout.tab_of_pane(window.panes[0]) == Some(tab)),
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
            .is_some_and(|window| window.close == proto::CloseWhen::Done);
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        if !wanted {
            return;
        }
        let weak_core = self.weak_self.clone();
        runtime.spawn(async move {
            tokio::time::sleep(FLOAT_LINGER).await;
            let Some(core) = weak_core.upgrade() else {
                return;
            };
            let still_wanted = lock(&core.layout)
                .window_of(pane)
                .is_some_and(|window| window.close == proto::CloseWhen::Done);
            if still_wanted {
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
                .is_some_and(|agent| agent.knows_request(id))
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
                    allows: option.map(|picked| picked != proto::DriveAsk::DENY),
                    option: chosen.map(str::to_owned),
                    summary: facts.summary,
                    request: crate::term::ask::agent_request(id),
                },
            ));
        }
        self.pane_entries().into_iter().find_map(|(pane, entry)| {
            lock(&entry.agent)
                .as_ref()
                .and_then(|agent| agent.request_facts(id, option))
                .map(|facts| (pane, facts))
        })
    }

    /// The hook request a pane's agent is blocked on now.
    pub fn open_request(&self, pane: PaneId) -> Option<proto::RequestId> {
        let entry = self.pane(pane)?;
        lock(&entry.agent).as_ref()?.open_request()
    }

    /// Whether an agent runs (or ran) in the pane.
    /// Whether text written to `pane` right now reaches its agent rather than a shell: the
    /// terminal's foreground process group is the agent's process, or, before that process was
    /// seen, anything but the pane's own shell. Checked just before each write of text from
    /// someone who may not drive the pane, since an agent can exit at any moment and the pane
    /// is marked a shell again only on the next tick.
    pub fn agent_has_terminal(&self, pane: PaneId) -> bool {
        if !self.is_agent_pane(pane) {
            return false;
        }
        let Some(entry) = self.pane(pane) else {
            return false;
        };
        let pty = entry.pane.pty();
        let Some(foreground) = pty.foreground_pgid() else {
            return false;
        };
        match lock(&entry.agent).as_ref().and_then(AgentRuntime::pid) {
            Some(agent) => foreground == agent,
            None => foreground != pty.pid(),
        }
    }

    pub fn is_agent_pane(&self, pane: PaneId) -> bool {
        self.pane(pane).is_some_and(|entry| {
            lock(&entry.agent).is_some()
                || matches!(lock(&entry.record).launch, PaneLaunch::Agent { .. })
        })
    }

    pub fn pane_sizing(&self, pane_id: PaneId) -> Option<proto::PaneSizing> {
        let entry = self.pane(pane_id)?;
        let peer = lock(&entry.meta)
            .sized_by
            .map(|(connection, _)| proto::PeerId(connection));
        Some(proto::PaneSizing { pane_id, peer })
    }

    pub fn pane_meta(&self, id: PaneId) -> Option<PaneMeta> {
        let entry = self.pane(id)?;
        let meta = lock(&entry.meta);
        let mut agent = lock(&entry.agent).as_mut().map(AgentRuntime::wire_status);
        // Waiting on the owner to let it drive a pane is a block like any approval.
        if let Some(blocker) = self.term.asks.blocker(id) {
            let kind = agent.map_or_else(|| "program".to_owned(), |status| status.kind);
            agent = Some(crate::term::ask::status(kind, blocker));
        }
        Some(PaneMeta {
            pane_id: id,
            title: meta.title.clone(),
            cwd: meta.cwd.clone(),
            exit: meta.exit,
            agent,
            size: entry.pane.size(),
            size_policy: meta.size_policy.unwrap_or(SizePolicy::LastActive),
            sized_by: meta.sized_by.map(|(_, principal)| principal),
        })
    }

    /// What the program in pane `id` last reported about itself, as clients see it.
    pub fn program_report(&self, id: PaneId) -> Option<proto::ProgramReport> {
        let entry = self.pane(id)?;
        lock(&entry.meta).program.as_ref().and_then(program_report)
    }

    /// Records the program's own top-level report (`Clear` removes it) and tells clients
    /// when what they see changes.
    pub fn set_program(&self, entry: &PaneEntry, status: agents::ProgramStatus) {
        let state = status.state;
        if self.record_program(entry, status, false)
            && matches!(
                state,
                agents::ProgramState::Done | agents::ProgramState::Error
            )
        {
            self.work_done(entry.pane.id);
        }
    }

    /// Shows a progress report (OSC 9;4) as the program's status, or as the percentage of
    /// the status it reports itself. A progress bar never says the work is done.
    pub fn set_progress(&self, entry: &PaneEntry, progress: crate::osc::Progress) {
        use crate::osc::Progress;
        use agents::ProgramState;
        let own = {
            let meta = lock(&entry.meta);
            meta.program.clone().filter(|_| !meta.program_from_progress)
        };
        let (status, from_progress) = match own {
            Some(mut status) => {
                if matches!(status.state, ProgramState::Working | ProgramState::Blocked) {
                    status.progress = progress.percent();
                }
                (status, false)
            }
            None => {
                let state = match progress {
                    Progress::Remove => ProgramState::Clear,
                    Progress::Error(_) => ProgramState::Error,
                    Progress::Set(_) | Progress::Indeterminate | Progress::Paused(_) => {
                        ProgramState::Working
                    }
                };
                let mut status = agents::ProgramStatus::new(state);
                status.progress = progress
                    .percent()
                    .filter(|_| state == ProgramState::Working);
                (status, true)
            }
        };
        self.record_program(entry, status, from_progress);
    }

    /// The shell is back at its prompt: a progress bar the program left behind goes, as in
    /// Ghostty.
    pub fn prompt_returned(&self, entry: &PaneEntry) {
        if lock(&entry.meta).program_from_progress {
            let cleared = agents::ProgramStatus::new(agents::ProgramState::Clear);
            self.record_program(entry, cleared, false);
        }
    }

    /// Stores the program's status; returns whether what clients see changed (they are told).
    fn record_program(
        &self,
        entry: &PaneEntry,
        mut status: agents::ProgramStatus,
        from_progress: bool,
    ) -> bool {
        // Any program's words, shown in status lines, the Inbox and to agents: as they print.
        let clean = |text: Option<String>| {
            text.map(|text| proto::clean_prompt_text(&text, PROGRAM_TEXT_CHARS))
                .filter(|text| !text.is_empty())
        };
        status.msg = clean(status.msg);
        status.title = clean(status.title);
        let status = (status.state != agents::ProgramState::Clear).then_some(status);
        let mut meta = lock(&entry.meta);
        let changed = meta.program.as_ref().and_then(program_report)
            != status.as_ref().and_then(program_report);
        meta.program_from_progress = from_progress && status.is_some();
        meta.program = status;
        drop(meta);
        if changed {
            self.emit(Event::ProgramStatus(entry.pane.id));
        }
        changed
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

    pub fn apply_client_size(
        &self,
        entry: &PaneEntry,
        conn: ConnId,
        authz: &Authz,
        size: PaneSize,
        force: bool,
    ) {
        let visible = lock(&self.views)
            .get(&conn)
            .is_none_or(|view| view.panes.contains(&entry.pane.id));
        let activity = if visible {
            proto::PaneActivity::Active
        } else {
            proto::PaneActivity::Inactive
        };
        let mut sizing = lock(&entry.sizing);
        if sizing.set_size(conn, authz, size, activity).is_err() {
            return;
        }
        if force {
            sizing.input(conn);
        }
        let timing = if force && sizing.is_active(conn) {
            ResizeTiming::BeforeInput
        } else {
            ResizeTiming::Deferred
        };
        self.select_client_size(entry, &mut sizing, timing);
    }

    pub fn pane_activity(
        &self,
        entry: &PaneEntry,
        conn: ConnId,
        authz: &Authz,
        activity: proto::PaneActivity,
    ) {
        let mut sizing = lock(&entry.sizing);
        sizing.explicit_activity(conn, authz, activity);
        self.select_client_size(entry, &mut sizing, ResizeTiming::Immediate);
    }

    pub fn claim_client_size(&self, entry: &PaneEntry, conn: ConnId) {
        let mut sizing = lock(&entry.sizing);
        sizing.input(conn);
        self.select_client_size(entry, &mut sizing, ResizeTiming::Immediate);
    }

    pub fn set_size_policy(&self, entry: &PaneEntry, policy: SizePolicy) -> Result<(), EmptyGrid> {
        let mut sizing = lock(&entry.sizing);
        sizing.set_policy(policy)?;
        lock(&entry.meta).size_policy = Some(policy);
        self.select_client_size(entry, &mut sizing, ResizeTiming::Immediate);
        self.emit(Event::PaneMeta(entry.pane.id));
        Ok(())
    }

    fn sizing_eligible(&self, entry: &PaneEntry, authz: &Authz) -> bool {
        self.mp.still_valid(authz)
            && crate::mp::policy::check(self, authz, Need::Drive, Target::Pane(entry.pane.id))
                .is_ok()
            && self.mp.may_size(entry.pane.id, authz.actor.principal)
    }

    fn select_client_size(&self, entry: &PaneEntry, sizing: &mut Sizing, timing: ResizeTiming) {
        let choice = sizing.choose(|authz| self.sizing_eligible(entry, authz));
        if sizing.update_choice(choice) || matches!(timing, ResizeTiming::BeforeInput) {
            self.queue_size_choice(entry, choice, timing);
        }
    }

    fn queue_size_choice(
        &self,
        entry: &PaneEntry,
        choice: Option<SizeChoice>,
        timing: ResizeTiming,
    ) {
        let mut pending = lock(&entry.pending_resize);
        let mut meta = lock(&entry.meta);
        let Some(choice) = choice else {
            *pending = None;
            if meta.sized_by.take().is_some() {
                self.emit(Event::PaneMeta(entry.pane.id));
            }
            return;
        };
        let ownership_changed = meta.sized_by != choice.owner
            || pending
                .as_ref()
                .is_some_and(|request| request.ownership_changed);
        meta.sized_by = choice.owner;
        match timing {
            ResizeTiming::Immediate | ResizeTiming::BeforeInput => {
                *pending = None;
                self.resize_pane(entry, choice.size, ownership_changed);
            }
            ResizeTiming::Deferred => {
                *pending = Some(PendingResize {
                    choice,
                    ownership_changed,
                    due: tokio::time::Instant::now() + RESIZE_DEBOUNCE,
                });
                entry.resize_changed.notify_one();
            }
        }
    }

    fn flush_client_size(&self, entry: &PaneEntry) {
        let mut sizing = lock(&entry.sizing);
        let request = lock(&entry.pending_resize)
            .take_if(|request| request.due <= tokio::time::Instant::now());
        let Some(request) = request else { return };
        let choice = sizing.choose(|authz| self.sizing_eligible(entry, authz));
        sizing.update_choice(choice);
        if choice == Some(request.choice) {
            let _meta = lock(&entry.meta);
            self.resize_pane(entry, request.choice.size, request.ownership_changed);
        } else {
            self.queue_size_choice(entry, choice, ResizeTiming::Immediate);
        }
    }

    fn resize_pane(&self, entry: &PaneEntry, size: PaneSize, ownership_changed: bool) {
        match entry.pane.resize(size) {
            Ok(changed) => {
                if changed || ownership_changed {
                    self.emit(Event::PaneMeta(entry.pane.id));
                }
            }
            Err(error) => tracing::debug!(pane = %entry.pane.id, "resize refused: {error}"),
        }
    }

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
                lock(&self.layout).check_split(pane_id).map_err(|error| {
                    let max = crate::layout::MAX_SPLIT_DEPTH;
                    (error, format!("too many nested splits (at most {max})"))
                })?;
                let cwd_hint = self
                    .pane(pane_id)
                    .and_then(|entry| lock(&entry.meta).cwd.clone());
                let new = lock(&self.layout).alloc_pane();
                self.spawn_pane(new, launch, cwd_hint, false)?;
                let result = lock(&self.layout).split(pane_id, axis, new);
                if let Err(error) = result {
                    self.kill_panes(&[new]);
                    return Err(fail(error));
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
            LayoutOp::Focus { pane_id } => self
                .simple(self.session_of_pane(pane_id), |layout| {
                    layout.focus(pane_id)
                })?,
            LayoutOp::FocusDirection { tab_id, direction } => self
                .simple(self.session_of_tab(tab_id), |layout| {
                    layout.focus_direction(tab_id, direction)
                })?,
            LayoutOp::Resize {
                pane_id,
                axis,
                delta,
            } => self.simple(self.session_of_pane(pane_id), |layout| {
                layout.resize(pane_id, axis, delta)
            })?,
            LayoutOp::ToggleZoom { pane_id } => self
                .simple(self.session_of_pane(pane_id), |layout| {
                    layout.toggle_zoom(pane_id)
                })?,
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
                let tab_id = tab.map_err(|error| {
                    self.kill_panes(&[pane]);
                    fail(error)
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
            LayoutOp::MoveTab { tab_id, index } => self
                .simple(self.session_of_tab(tab_id), |layout| {
                    layout.move_tab(tab_id, index)
                })?,
            LayoutOp::SelectTab { tab_id } => self
                .simple(self.session_of_tab(tab_id), |layout| {
                    layout.select_tab(tab_id)
                })?,
            LayoutOp::RenameTab { tab_id, name } => self
                .simple(self.session_of_tab(tab_id), |layout| {
                    layout.rename_tab(tab_id, name)
                })?,
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
                let cwd_hint = self
                    .pane(pane_id)
                    .and_then(|entry| lock(&entry.meta).cwd.clone());
                let new = lock(&self.layout).alloc_pane();
                self.spawn_pane(new, launch, cwd_hint, false)?;
                let result = lock(&self.layout).new_float(pane_id, new, frame, focus, close);
                if let Err(error) = result {
                    self.kill_panes(&[new]);
                    return Err(fail(error));
                }
                self.layout_changed(session, false);
                OpOutcome::PaneCreated { pane_id: new }
            }
            LayoutOp::FloatPane { pane_id, frame } => self
                .simple(self.session_of_pane(pane_id), |layout| {
                    layout.float_pane(pane_id, frame).map(drop)
                })?,
            LayoutOp::SetFloat {
                pane_id,
                frame,
                minimized,
                pinned,
            } => self.simple(self.session_of_pane(pane_id), |layout| {
                layout
                    .set_float(pane_id, frame, minimized, pinned)
                    .map(drop)
            })?,
            LayoutOp::DockPane { pane_id, beside } => self
                .simple(self.session_of_pane(pane_id), |layout| {
                    layout.dock_pane(pane_id, beside).map(drop)
                })?,
            LayoutOp::MovePaneToEdge {
                pane_id,
                tab_id,
                side,
            } => self.simple(self.session_of_pane(pane_id), |layout| {
                layout.move_pane_to_edge(pane_id, tab_id, side).map(drop)
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
            .map_err(|error| (error, format!("session name {name:?}: {error:?}")))?;
        let pane = lock(&self.layout).alloc_pane();
        self.spawn_pane(pane, launch, None, false)?;
        let created = lock(&self.layout).create_session(name, pane);
        let (session, tab) = created.map_err(|error| {
            self.kill_panes(&[pane]);
            (error, format!("{error:?}"))
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
        operation: impl FnOnce(&mut Layout) -> Result<(), OpError>,
    ) -> Result<OpOutcome, (OpError, String)> {
        let session = session.ok_or((OpError::NotFound, "not found".to_owned()))?;
        let before = lock(&self.layout)
            .session(session)
            .map(|session| session.revision);
        operation(&mut lock(&self.layout)).map_err(|error| (error, format!("{error:?}")))?;
        let after = lock(&self.layout)
            .session(session)
            .map(|session| session.revision);
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
            (None, Some(session)) => self.emit(Event::Layout(session)),
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
    pub(crate) fn has_live_codex(&self) -> bool {
        self.pane_entries().iter().any(|(_, entry)| {
            lock(&entry.codex)
                .as_ref()
                .is_some_and(|source| source.is_running())
        })
    }

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
                .rposition(|candidate| candidate.pane_id == pane)
                .and_then(|index| closed.remove(index))
        };
        let Some(closed) = closed else {
            return PaneLaunch::Shell { cwd };
        };
        self.mark_dirty();
        let cwd = closed.cwd.or(cwd);
        match closed.agent {
            Some(AgentRecord {
                kind,
                session_id: Some(session_id),
                account,
            }) => PaneLaunch::AccountAgent {
                agent: kind,
                account,
                resume: Some(session_id),
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

    /// Starts a pane process and its task. `restored` marks an agent resumed after a restart.
    pub fn spawn_pane(
        self: &Arc<Self>,
        id: PaneId,
        launch: PaneLaunch,
        cwd_hint: Option<String>,
        restored: bool,
    ) -> Result<(), (OpError, String)> {
        let after_restart = restored;
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
            // A canvas pane runs nothing: it shows a drawing.
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
                    .map_err(|error| (OpError::NotFound, error.to_string()))?;
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
            .filter(|dir| std::path::Path::new(dir).is_dir())
            .unwrap_or(home);
        let shell = self.cfg.shell();
        let mut command = Command::new(&shell);
        if brand::IS_DEV {
            for (key, _) in std::env::vars_os() {
                if key.to_str().is_some_and(|key| {
                    key.starts_with(brand::RELEASE_ENV_PREFIX)
                        || key.starts_with(brand::legacy::ENV_PREFIX)
                }) {
                    command.env_remove(key);
                }
            }
        }
        let mut agent = None;
        let mut codex = None;
        let mut native_input_launch = crate::agent_input::AgentInputGate::default();
        let injection = self
            .shell
            .as_ref()
            .filter(|_| self.cfg.shell_integration)
            .and_then(|integration| integration.injection(&shell, |name| self.cfg.pane_var(name)))
            .map(|mut injection| {
                self.askpass.wrap_injection(&mut injection);
                injection
            });
        let mut inject_env = Vec::new();
        // `exec`s the login shell with shell integration, for panes that run something first.
        let then_shell = || {
            let mut then = vec!["exec".to_owned()];
            if let Some(injection) = &injection {
                then.push("env".into());
                then.extend(
                    injection
                        .env
                        .iter()
                        .map(|(key, value)| shell_quote(&format!("{key}={value}"))),
                );
            }
            then.push(shell_quote(&shell.to_string_lossy()));
            if let Some(injection) = &injection {
                then.extend(injection.args.iter().map(|arg| shell_quote(arg)));
            }
            then.push("-l".into());
            then.join(" ")
        };
        // A setup or repository script queued for this directory runs first (git workspace).
        let pre_command = self
            .ws
            .repos
            .take_pre_command(std::path::Path::new(&cwd))
            .map(|script| format!("{script}\n"));
        match &launch {
            PaneLaunch::Shell { .. } | PaneLaunch::Reopen { .. } => match &pre_command {
                Some(pre_command) => {
                    command.args(["-l", "-c", &format!("{pre_command}{}", then_shell())]);
                }
                None => {
                    if let Some(injection) = &injection {
                        command.args(&injection.args);
                        inject_env.clone_from(&injection.env);
                    }
                    command.arg("-l");
                }
            },
            PaneLaunch::Command { argv, .. } => {
                if argv.is_empty() {
                    return Err((OpError::Invalid, "empty argv".into()));
                }
                let line = argv
                    .iter()
                    .map(|arg| shell_quote(arg))
                    .collect::<Vec<_>>()
                    .join(" ");
                let pre_command = pre_command.as_deref().unwrap_or_default();
                command.args(["-l", "-c", &format!("{pre_command}exec {line}")]);
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
                let context = self.hooks.launch_context(id, PathBuf::from(&cwd), account);
                let spec = match agent {
                    AgentKind::Claude => agents::ClaudeCode::sign_in(&context),
                    AgentKind::Codex => agents::Codex::sign_in(&context, *device_code),
                };
                // The shim tells the daemon the sign-in ended, so it checks the account.
                let done = format!(
                    "{} {} {} </dev/null",
                    shell_quote(&context.hook_bin.to_string_lossy()),
                    crate::agent::ACCOUNT_HOOK,
                    crate::agent::SIGN_IN_EVENT
                );
                command.args([
                    "-i",
                    "-l",
                    "-c",
                    &format!("{}; {done}; {}", spec.shell_line(), then_shell()),
                ]);
                for (key, value) in &spec.env {
                    command.env(key, value);
                }
                for key in &spec.env_remove {
                    command.env_remove(key);
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
                    .map_err(|error| (OpError::Invalid, error))?;
                if let Some(dir) = &account.dir
                    && !dir.is_dir()
                {
                    return Err((
                        OpError::SpawnFailed,
                        "the account's directory is missing; sign in again".to_owned(),
                    ));
                }
                let context = self
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
                    (Some(resume_id), _) => LaunchMode::Resume {
                        session_id: agents::NativeSessionId::new(resume_id.clone()),
                    },
                    (None, pinned) => LaunchMode::Fresh {
                        session_id: pinned.clone().map(agents::NativeSessionId::new),
                    },
                };
                let spec = if brand::IS_DEV && self.cfg.codex_chat && *kind == AgentKind::Codex {
                    let (source, spec) =
                        crate::agent_driver::codex::Live::start(&context, &mode)
                            .map_err(|error| (OpError::SpawnFailed, error.to_string()))?;
                    codex = Some(source);
                    spec
                } else {
                    adapter.launch(&context, &mode)
                };
                for file in &spec.files {
                    if let Some(dir) = file.path.parent() {
                        let _ = std::fs::create_dir_all(dir);
                    }
                    if let Err(error) = std::fs::write(&file.path, &file.contents) {
                        return Err((
                            OpError::SpawnFailed,
                            format!("{}: {error}", file.path.display()),
                        ));
                    }
                }
                let line = spec.shell_line();
                if let Some(session) = &session_id {
                    self.ws.accounts.pin(*kind, session, &account.id);
                }
                // Run the agent, then leave the pane as a shell, with shell integration for
                // that shell. Interactive, so rc files set `PATH` as in any pane and the install
                // check holds.
                let pre_command = pre_command.as_deref().unwrap_or_default();
                let marker = if after_restart && resume.is_some() {
                    RESUMED_MARKER
                } else {
                    ""
                };
                let launch_id = crate::agent::new_uuid();
                native_input_launch =
                    crate::agent_input::AgentInputGate::pending(launch_id.clone());
                let shim = shell_quote(&context.hook_bin.to_string_lossy());
                let launch_id = shell_quote(&launch_id);
                command.args([
                    "-i",
                    "-l",
                    "-c",
                    &format!(
                        "{pre_command}{marker}{shim} agent-input-arm {launch_id} </dev/null; {line}; {shim} agent-exit-fence {launch_id} && {}",
                        then_shell()
                    ),
                ]);
                for (key, value) in &spec.env {
                    command.env(key, value);
                }
                for key in &spec.env_remove {
                    command.env_remove(key);
                }
                agent = Some((
                    *kind,
                    session_id,
                    account.id,
                    if codex.is_some() {
                        AgentRuntime::structured(*kind, id, adapter)
                    } else {
                        AgentRuntime::new(*kind, id, adapter, restored)
                    },
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
        if let Some(worktree) = &worktree {
            command.env("PORT", worktree.port.to_string());
            command.env(brand::env_var("WORKTREE"), &worktree.path);
        }
        command.current_dir(&cwd);
        // SAFETY: runs between fork and exec and only calls `setrlimit`.
        unsafe {
            std::os::unix::process::CommandExt::pre_exec(
                &mut command,
                crate::limits::restore_for_child,
            );
        }
        crate::theme::apply_pane_env(&mut command);
        command.env(brand::env_var("PANE_ID"), id.0.to_string());
        for (key, value) in self
            .askpass
            .pane_env(self, id)
            .into_iter()
            .chain(self.browser.pane_env(self, id))
        {
            command.env(key, value);
        }
        for (key, value) in &self.cfg.pane_env {
            command.env(key, OsString::from(value));
        }
        if let Some(path) = self
            .shell
            .as_ref()
            .and_then(|integration| integration.pane_path(self.cfg.pane_var("PATH")))
        {
            command.env("PATH", path);
        }
        for (key, value) in &inject_env {
            command.env(key, value);
        }
        // Helpers must not inherit the pane that launched this daemon.
        command.env(brand::DAEMON_PID_ENV, std::process::id().to_string());
        let (cols, rows) = self.cfg.default_size;
        let size = PaneSize {
            cols,
            rows,
            width_px: 0,
            height_px: 0,
        };
        let (pane, vt_events) = Pane::spawn(
            id,
            self.pane_gen,
            command,
            size,
            self.cfg.ring_capacity,
            crate::pane::VtLimits {
                scrollback_bytes: self.cfg.scrollback_bytes,
                image_storage_bytes: self.cfg.image_storage_bytes,
            },
            &self.themes.current(),
        )
        .map_err(|error| (OpError::SpawnFailed, error.to_string()))?;
        *lock(&pane.agent_input_gate) = native_input_launch;
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
            agent: Mutex::new(agent.map(|(_, _, _, runtime)| runtime)),
            codex: Mutex::new(codex),
            agent_attached: Notify::new(),
            sizing: Mutex::new(Sizing::default()),
            pending_resize: Mutex::new(None),
            resize_changed: Notify::new(),
            ticks: AtomicU64::new(0),
            task: Mutex::new(None),
            launched_at: SystemTime::now(),
        });
        let task = tokio::spawn(pane_task(Arc::clone(self), Arc::clone(&entry), vt_events));
        *lock(&entry.task) = Some(task.abort_handle());
        lock(&self.panes).insert(id, Arc::clone(&entry));
        if let Some(source) = lock(&entry.codex).as_ref() {
            source.set_owner(self, &entry);
        }
        if accounts_changed {
            self.emit(Event::Accounts);
        }
        Ok(())
    }

    /// Stops every pane for the daemon build that replaces this process with `exec`
    /// (`handoff`), leaving its program running, and returns what that build needs to
    /// continue them. Pane tasks must be stopped already.
    pub fn hand_off_panes(&self) -> Vec<crate::handoff::CarriedPane> {
        let mut carried = Vec::new();
        for (id, entry) in self.pane_entries() {
            let state = match entry.pane.hand_off() {
                Ok(state) => state,
                Err(error) => {
                    tracing::warn!(pane = %id, "cannot hand off the pane: {error}; it ends");
                    entry.pane.pty().end_handed_off(HANGUP_GRACE);
                    continue;
                }
            };
            let meta = lock(&entry.meta);
            carried.push(crate::handoff::CarriedPane {
                id,
                state,
                title: meta.title.clone(),
                cwd: meta.cwd.clone(),
                at_prompt: meta.at_prompt,
                launched_at: entry.launched_at,
                agent: lock(&entry.agent).as_ref().map(AgentRuntime::kind),
            });
        }
        carried
    }

    /// Continues a pane the previous daemon build handed off (`handoff`): same process,
    /// PTY, screens, history and stream offsets. Its record is the one saved with the layout.
    pub fn adopt_pane(
        self: &Arc<Self>,
        carried: crate::handoff::CarriedPane,
        master: std::os::fd::OwnedFd,
        record: PaneRecord,
    ) -> Result<(), pty::AdoptError> {
        let id = carried.id;
        let (pane, vt_events) = Pane::adopt(
            id,
            master,
            &carried.state,
            self.pane_gen,
            crate::pane::VtLimits {
                scrollback_bytes: self.cfg.scrollback_bytes,
                image_storage_bytes: self.cfg.image_storage_bytes,
            },
            &self.themes.current(),
        )?;
        let agent = carried
            .agent
            .or_else(|| record.agent.as_ref().map(|agent| agent.kind))
            .map(|kind| AgentRuntime::new(kind, id, crate::agent::adapter(kind), true));
        if let Some(agent) = &record.agent
            && let Some(session) = &agent.session_id
            && let Some(account) = &agent.account
        {
            self.ws.accounts.pin(agent.kind, session, account);
        }
        let accounts_changed = agent.is_some();
        let entry = Arc::new(PaneEntry {
            pane,
            meta: Mutex::new(MetaState {
                title: carried.title,
                cwd: carried.cwd.or_else(|| record.cwd.clone()),
                at_prompt: carried.at_prompt,
                ..MetaState::default()
            }),
            record: Mutex::new(record),
            agent: Mutex::new(agent),
            codex: Mutex::new(None),
            agent_attached: Notify::new(),
            sizing: Mutex::new(Sizing::default()),
            pending_resize: Mutex::new(None),
            resize_changed: Notify::new(),
            ticks: AtomicU64::new(0),
            task: Mutex::new(None),
            launched_at: carried.launched_at,
        });
        let task = tokio::spawn(pane_task(Arc::clone(self), Arc::clone(&entry), vt_events));
        *lock(&entry.task) = Some(task.abort_handle());
        lock(&self.panes).insert(id, entry);
        if accounts_changed {
            self.emit(Event::Accounts);
        }
        Ok(())
    }

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
        panes.sort_by_key(|account| account.pane_id.0);
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

    /// Broadcasts an agent event and refreshes the pane's metadata and record.
    pub fn agent_event(&self, id: PaneId, event: Option<agents::AgentEvent>) {
        self.agent_attention(id);
        let Some(event) = event else {
            return;
        };
        self.agent_turn(id, &event);
        if let Some(entry) = self.pane(id) {
            let native = event.session.native_id.as_ref().map(|id| id.to_string());
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
            Err(error) => tracing::warn!("serializing agent event: {error}"),
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
                    .filter(|cwd| cwd.is_dir())
                    .or_else(|| {
                        self.pane(id).and_then(|entry| {
                            let meta = lock(&entry.meta).cwd.clone();
                            meta.or_else(|| lock(&entry.record).cwd.clone())
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
            let Some(runtime) = agent.as_mut() else {
                return;
            };
            let notices = runtime.take_notices();
            let wire = (!notices.is_empty()).then(|| runtime.wire_status());
            (runtime.kind(), notices, runtime.is_blocked(), wire)
        };
        for (notify, event) in notices {
            let message = event
                .as_ref()
                .and_then(|agent_event| agent_event.turn.as_ref())
                .and_then(|turn| turn.last_message.as_deref())
                .map(notice_text);
            let notice = match notify {
                agents::Notify::Blocked { .. } => {
                    let (request_id, summary) = match &wire {
                        Some(proto::AgentStatus {
                            state: proto::AgentState::Blocked(block),
                            ..
                        }) => (Some(block.request_id), block.summary.clone()),
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
            let Some(runtime) = agent.as_mut() else {
                continue;
            };
            if !runtime.knows_request(decide.request_id) {
                continue;
            }
            let driver = crate::agent_driver::driver(runtime.kind());
            let outcome = runtime.decide(decide.request_id, decide.option_id, actor);
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
                    let decision = edited.map_or(
                        crate::agent_driver::ApprovalDecision::Choice(details.choice),
                        crate::agent_driver::ApprovalDecision::Edited,
                    );
                    driver.approve(self, id, &details.request, decision);
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
    let alt_screen = entry.pane.alt_screen();
    let at_prompt = lock(&entry.meta).at_prompt;
    let hint = EchoHint {
        pane_id: entry.pane.id,
        echo: echo.echo,
        icanon: echo.canonical,
        alt_screen,
        at_prompt,
    };
    (
        hint,
        Prediction::decide(echo.echo, echo.canonical, alt_screen, at_prompt),
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
            // Tagged with the head now: the state applies to everything after.
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
const RESIZE_DEBOUNCE: Duration = Duration::from_millis(120);

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
    let session_lookup = Arc::new(AtomicBool::new(false));
    let mut meta_sent: Option<Instant> = None;
    let mut meta_due: Option<tokio::time::Instant> = None;
    refresh_hint(&core, &entry);
    loop {
        let ticking = Instant::now() < active_until || lock(&entry.agent).is_some();
        let resize_due = lock(&entry.pending_resize)
            .as_ref()
            .map(|request| request.due);
        tokio::select! {
            () = entry.resize_changed.notified() => {}
            () = sleep_until_some(resize_due) => core.flush_client_size(&entry),
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
                        if let Some(runtime) = lock(&entry.agent).as_mut() {
                            runtime.pty_output();
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
                        Some(sent) if sent.elapsed() < META_INTERVAL => {
                            meta_due = Some((sent + META_INTERVAL).into());
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
                let code = status.ok().and_then(|exit_status| exit_status.code());
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
                        detect_agent(&core, &entry);
                    } else {
                        end_exited_agent(&core, &entry);
                    }
                }
                if detect_tick.is_multiple_of(2) {
                    capture_agent_session(&core, &entry, &session_lookup);
                }
                let screen = screen_dirty.then(|| pane.screen_text());
                screen_dirty = false;
                if let Some(screen) = &screen {
                    core.ws.ports.observe_screen(id, screen);
                }
                let title = lock(&entry.meta).title.clone();
                let update = lock(&entry.agent)
                    .as_mut()
                    .map(|runtime| runtime.tick(screen.as_deref(), &title));
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
            if let Some(progress) = crate::osc::Progress::parse(&body) {
                core.set_progress(entry, progress);
                return false;
            }
            let event = lock(&entry.agent)
                .as_mut()
                .and_then(|runtime| runtime.osc9(&body));
            core.agent_event(id, event);
        }
        Osc::ProgramStatus(body) => {
            // Reports about sub-records (`id=`) belong to the agent integrations below. Any
            // printed text can claim to be an agent: only a pane running one may.
            let has_agent = lock(&entry.agent).is_some();
            if let Some(report) = agents::ProgramStatus::parse(&body)
                .filter(|report| report.id.is_none())
                .filter(|report| has_agent || !crate::agent::names_an_agent(report))
            {
                core.set_program(entry, report);
            }
            let event = lock(&entry.agent)
                .as_mut()
                .and_then(|runtime| runtime.program_status(&body));
            core.agent_event(id, event);
        }
    }
    false
}

fn handle_command(core: &Core, entry: &PaneEntry, update: CommandUpdate) {
    match update {
        // 133;B: the user is editing a command line (raw-mode prediction may run);
        // 133;C: the command runs and owns the terminal.
        CommandUpdate::AtPrompt(at_prompt) => {
            lock(&entry.meta).at_prompt = at_prompt;
            if at_prompt {
                core.prompt_returned(entry);
            }
            refresh_hint(core, entry);
        }
        CommandUpdate::Mark(mark) => {
            let long = mark.finished.is_some_and(|finished| {
                finished.duration_ms >= core.cfg.long_command.as_millis() as u64
            });
            if long && !core.owner_shows(mark.pane_id) {
                core.emit(Event::CommandUnseen(mark.clone()));
                crate::ws::command_unseen(core, &mark);
            }
            // A command starting or ending is when servers come and go.
            core.ws.ports.trigger.notify_one();
            crate::assist::command_finished(core, entry, &mark);
            if mark.finished.is_some() {
                core.work_done(mark.pane_id);
            }
            core.emit_command(mark);
        }
    }
}

/// While an agent pane's session id is unknown, looks for it off the async runtime (process
/// table and file system) and records it when found.
fn capture_agent_session(core: &Arc<Core>, entry: &Arc<PaneEntry>, busy: &Arc<AtomicBool>) {
    if lock(&entry.codex).is_some() {
        return;
    }
    let Some((kind, account)) = lock(&entry.record)
        .agent
        .as_ref()
        .filter(|agent| agent.session_id.is_none())
        .map(|agent| {
            let account = agent
                .account
                .clone()
                .unwrap_or_else(|| proto::SYSTEM_ACCOUNT.into());
            (agent.kind, account)
        })
    else {
        return;
    };
    if busy.swap(true, Ordering::AcqRel) {
        return;
    }
    let claimed: Vec<String> = core
        .pane_entries()
        .iter()
        .filter_map(|(_, other)| lock(&other.record).agent.as_ref()?.session_id.clone())
        .collect();
    let cwd = PathBuf::from(lock(&entry.record).cwd.clone().unwrap_or_default());
    let (directory_var, default_directory) = match kind {
        AgentKind::Codex => (agents::CODEX_DIR_VAR, ".codex"),
        AgentKind::Claude => (agents::CLAUDE_DIR_VAR, ".claude"),
    };
    // Sessions are under the pane's account's directory.
    let agent_dir = core
        .ws
        .accounts
        .context(kind, &account)
        .and_then(|context| context.dir)
        .or_else(|| core.cfg.pane_var(directory_var).map(PathBuf::from))
        .or_else(|| {
            core.cfg
                .pane_var("HOME")
                .map(|home| PathBuf::from(home).join(default_directory))
        });
    let root = entry.pane.pty().pid();
    // Slack for an agent that was running a moment before the pane noticed it.
    let since = lock(&entry.agent)
        .as_ref()
        .map(|runtime| runtime.started_at() - Duration::from_secs(5))
        .map_or(entry.launched_at, |started| started.max(entry.launched_at));
    let (core, entry, busy) = (Arc::clone(core), Arc::clone(entry), Arc::clone(busy));
    tokio::task::spawn_blocking(move || {
        let found = match kind {
            AgentKind::Codex => crate::codex_session::from_open_files(root).or_else(|| {
                crate::codex_session::from_rollouts(&agent_dir?, &cwd, since, &claimed)
            }),
            AgentKind::Claude => agent_dir.and_then(|dir| {
                crate::claude_session::from_transcripts(&dir, &cwd, since, &claimed)
            }),
        };
        if let Some(session_id) = found {
            let mut record = lock(&entry.record);
            if let Some(agent) = record.agent.as_mut()
                && agent.kind == kind
                && agent.session_id.is_none()
            {
                tracing::info!(pane = %entry.pane.id, %session_id, ?kind, "agent session found");
                core.ws.accounts.pin(kind, &session_id, &account);
                agent.session_id = Some(session_id);
                core.mark_dirty();
            }
        }
        busy.store(false, Ordering::Release);
    });
}

/// Starts tracking an agent the user launched by hand (no hooks, screen and OSC only).
fn detect_agent(core: &Core, entry: &PaneEntry) {
    let Some(foreground) = entry.pane.pty().foreground_process() else {
        return;
    };
    track_foreground_agent(core, entry, &foreground);
}

fn track_foreground_agent(core: &Core, entry: &PaneEntry, foreground: &pty::ForegroundProcess) {
    let Some(kind) = crate::agent::running_agent(foreground) else {
        return;
    };
    let adapter = crate::agent::adapter(kind);
    let mut runtime = AgentRuntime::new(kind, entry.pane.id, adapter, false);
    runtime.note_process(foreground.pid);
    *lock(&entry.agent) = Some(runtime);
    let session_id = match kind {
        AgentKind::Claude => crate::claude_session::from_argv(&foreground.argv),
        AgentKind::Codex => None,
    };
    record_agent_started_by_hand(core, entry, kind, session_id);
    core.emit(Event::PaneMeta(entry.pane.id));
}

/// Records an agent the user started by hand in a shell pane, under the user's own setup
/// (the system account), so the pane resumes its session after a daemon restart.
pub(crate) fn record_agent_started_by_hand(
    core: &Core,
    entry: &PaneEntry,
    kind: AgentKind,
    session_id: Option<String>,
) {
    {
        let mut record = lock(&entry.record);
        if record
            .agent
            .as_ref()
            .is_some_and(|agent| agent.kind == kind)
        {
            return;
        }
        if let Some(session) = &session_id {
            core.ws.accounts.pin(kind, session, proto::SYSTEM_ACCOUNT);
        }
        record.agent = Some(AgentRecord {
            kind,
            session_id,
            account: Some(proto::SYSTEM_ACCOUNT.into()),
        });
    }
    core.mark_dirty();
    core.emit(Event::Accounts);
}

/// Ends the pane's agent once its process exited and the pane is back at its shell: the
/// pane is a shell again, on every client and after a restore.
fn end_exited_agent(core: &Core, entry: &PaneEntry) {
    let foreground = entry.pane.pty().foreground_process();
    // A launched agent's pane at its own shell, past the `sh -c` that ran the agent.
    let launched = matches!(lock(&entry.record).launch, PaneLaunch::Agent { .. });
    let at_shell = launched
        && foreground.as_ref().is_some_and(|process| {
            process.pid == entry.pane.pty().pid()
                && !process.argv.is_empty()
                && !process.argv.iter().any(|arg| arg == "-c")
        });
    let event = {
        let mut agent = lock(&entry.agent);
        let Some(runtime) = agent.as_mut() else {
            return;
        };
        if !runtime.process_gone(foreground.as_ref(), at_shell, |pid| {
            pty::ForegroundProcess::of(pid).is_some()
        }) {
            return;
        }
        runtime.process_exited()
    };
    let id = entry.pane.id;
    tracing::info!(pane = %id, "agent exited");
    crate::agent_input::agent_exited(&entry.pane);
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

/// Printed in dim text above an agent that resumes its session after a daemon restart.
const RESUMED_MARKER: &str = "printf '\\033[2m%s\\033[0m\\n' 'Resumed after restart'; ";

/// Quotes `word` for a POSIX shell as one word.
pub(crate) fn shell_quote(word: &str) -> String {
    if !word.is_empty()
        && word
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"/._-+=:,@".contains(&byte))
    {
        return word.to_owned();
    }
    format!("'{}'", word.replace('\'', r"'\''"))
}

/// Restores the saved layout: continues the panes a previous build handed over (`adopted`),
/// respawns the others (agents resume their sessions), and ends carried panes the layout no
/// longer has.
pub(crate) fn restore(
    core: &Arc<Core>,
    panes: HashMap<PaneId, PaneRecord>,
    closed: Vec<ClosedPane>,
    adopted: &mut crate::handoff::Adopted,
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
            if let Some((carried, master)) = adopted.take(id) {
                pty::abandon(master, carried.state.pty.pid, HANGUP_GRACE);
            }
            failed.push(id);
            continue;
        };
        if let Some((carried, master)) = adopted.take(id) {
            match core.adopt_pane(carried, master, record.clone()) {
                Ok(()) => {
                    tracing::info!(pane = %id, "continued the pane from the previous build");
                    continue;
                }
                // The master was closed (the session hung up); a fresh pane takes its place.
                Err(error) => tracing::warn!(pane = %id, "cannot continue the pane: {error}"),
            }
        }
        let mut launch = record.launch.clone();
        // An agent the user started by hand in a shell pane comes back as one launched there.
        if let (PaneLaunch::Shell { .. } | PaneLaunch::Command { .. }, Some(agent)) =
            (&launch, &record.agent)
            && agent.session_id.is_some()
        {
            launch = PaneLaunch::Agent {
                agent: agent.kind,
                resume: None,
                cwd: None,
            };
        }
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
        if let Err((_, message)) = core.spawn_pane(id, launch, None, restored_agent) {
            tracing::warn!(pane = %id, "restoring pane failed: {message}");
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
        .map(|(id, entry)| (id.0, lock(&entry.record).clone()))
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

    #[tokio::test]
    async fn foreground_agent_detection_publishes_metadata_without_incidental_events() {
        let directory = tempfile::tempdir().unwrap();
        let mut config = Config::new(directory.path());
        config.relay = crate::RelayMode::Disabled;
        config.bind = Some("127.0.0.1:0".parse().unwrap());
        config.shell = Some("/bin/sh".into());
        config.pane_env = vec![("HOME".into(), directory.path().display().to_string())];
        let daemon = crate::Daemon::start(config).await.unwrap();
        let core = Arc::clone(&daemon.core);
        core.create_session("tracking".into(), PaneLaunch::Shell { cwd: None })
            .unwrap();
        let (pane_id, entry) = core.pane_entries().pop().unwrap();
        entry.stop_task();
        let mut events = core.events.subscribe();
        let foreground = pty::ForegroundProcess {
            pid: entry.pane.pty().pid(),
            name: "claude".into(),
            argv: vec!["claude".into()],
        };
        track_foreground_agent(&core, &entry, &foreground);
        let agent = core.pane_meta(pane_id).unwrap().agent;
        let published = std::iter::from_fn(|| events.try_recv().ok())
            .any(|event| matches!(event, Event::PaneMeta(id) if id == pane_id));
        daemon.shutdown().await;
        assert!(agent.is_some(), "agent was registered");
        assert!(published, "agent registration must publish its metadata");
    }

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
                .map(|(_, entry)| entry.ticks.load(Ordering::Relaxed))
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
