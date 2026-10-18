//! Daemon-wide state: the layout, the panes, the event bus, and the operations on them.

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime};

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
    /// A pane's control lease changed.
    Lease(proto::Lease),
    /// A drawing or image of `session` changed, or live ink (not echoed to `from`).
    Artifact {
        session: SessionId,
        event: Arc<proto::ArtifactEvent>,
        from: Option<ConnId>,
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
}

#[derive(Debug, Default)]
pub(crate) struct MetaState {
    pub title: String,
    pub cwd: Option<String>,
    pub exit: Option<i32>,
    /// The connection whose size the PTY has, and its principal.
    pub sized_by: Option<(ConnId, PrincipalId)>,
    pub at_prompt: bool,
    pub last_hint: Option<(EchoHint, Prediction)>,
}

pub(crate) struct PaneEntry {
    pub pane: Arc<Pane>,
    pub meta: Mutex<MetaState>,
    pub record: Mutex<PaneRecord>,
    pub agent: Mutex<Option<AgentRuntime>>,
    task: Mutex<Option<AbortHandle>>,
    /// When the pane's process started, for matching a Codex rollout to it.
    launched_at: SystemTime,
}

pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

pub(crate) struct Core {
    pub cfg: Config,
    pub epoch: SessionEpoch,
    pub identity: Identity,
    pub layout: Mutex<Layout>,
    panes: Mutex<HashMap<PaneId, Arc<PaneEntry>>>,
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
    connected: AtomicUsize,
}

impl Core {
    pub fn new(
        cfg: Config,
        identity: Identity,
        layout: Layout,
        hooks: HookServer,
        shell: Option<ShellIntegration>,
        mp: crate::mp::Mp,
    ) -> Arc<Self> {
        let (events, _) = broadcast::channel(1024);
        let ws = crate::ws::Ws::new(&cfg, events.clone());
        Arc::new(Self {
            epoch: SessionEpoch(crate::identity::now_millis()),
            identity,
            layout: Mutex::new(layout),
            panes: Mutex::new(HashMap::new()),
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
            cfg,
            connected: AtomicUsize::new(0),
        })
    }

    /// A client connected (`true`) or left.
    pub fn client_connected(&self, up: bool) {
        if up {
            self.connected.fetch_add(1, Ordering::Relaxed);
            self.ws.ports.trigger.notify_one();
        } else {
            self.connected.fetch_sub(1, Ordering::Relaxed);
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

    pub fn detach(&self, conn: ConnId) {
        lock(&self.views).remove(&conn);
        if lock(&self.attached).remove(&conn).is_some() {
            self.emit(Event::Sessions);
        }
        // A departed client no longer sizes anything; the next typist takes over.
        for (_, entry) in self.pane_entries() {
            let mut meta = lock(&entry.meta);
            if meta.sized_by.is_some_and(|(c, _)| c == conn) {
                meta.sized_by = None;
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

    pub fn session_of_pane(&self, pane: PaneId) -> Option<SessionId> {
        lock(&self.layout).session_of_pane(pane)
    }

    /// The pane whose agent asked approval request `id`.
    pub fn request_pane(&self, id: proto::RequestId) -> Option<PaneId> {
        self.pane_entries().into_iter().find_map(|(pane, entry)| {
            lock(&entry.agent)
                .as_ref()
                .is_some_and(|rt| rt.knows_request(id))
                .then_some(pane)
        })
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
        let agent = lock(&entry.agent).as_mut().map(AgentRuntime::wire_status);
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
            LayoutOp::CloseSession { session_id } => {
                let removed = lock(&self.layout).close_session(session_id).map_err(fail)?;
                self.after_removal(Some(session_id), removed);
                OpOutcome::Done
            }
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
                self.ws.forget_pane(*id);
                self.mp.forget_pane(*id);
                entry.pane.hang_up();
                self.emit(Event::PaneClosed(*id));
            }
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
        let home = std::env::var("HOME").unwrap_or_else(|_| "/".to_owned());
        let launch_cwd = match &launch {
            PaneLaunch::Shell { cwd }
            | PaneLaunch::Command { cwd, .. }
            | PaneLaunch::Agent { cwd, .. } => cwd.clone(),
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
            .and_then(|si| si.injection(&shell, |name| self.cfg.pane_var(name)));
        let mut inject_env = Vec::new();
        match &launch {
            PaneLaunch::Shell { .. } => {
                if let Some(inj) = &injection {
                    cmd.args(&inj.args);
                    inject_env.clone_from(&inj.env);
                }
                cmd.arg("-l");
            }
            PaneLaunch::Command { argv, .. } => {
                if argv.is_empty() {
                    return Err((OpError::Invalid, "empty argv".into()));
                }
                let line = argv
                    .iter()
                    .map(|a| shell_quote(a))
                    .collect::<Vec<_>>()
                    .join(" ");
                cmd.args(["-l", "-c", &format!("exec {line}")]);
            }
            PaneLaunch::Agent {
                agent: kind,
                resume,
                ..
            } => {
                let ctx = self.hooks.launch_context(id, PathBuf::from(&cwd));
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
                let line = std::iter::once(&spec.program)
                    .chain(&spec.args)
                    .map(|a| shell_quote(&a.to_string_lossy()))
                    .collect::<Vec<_>>()
                    .join(" ");
                // integration for that shell.
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
                cmd.args(["-l", "-c", &format!("{line}; {}", then.join(" "))]);
                for (k, v) in &spec.env {
                    cmd.env(k, v);
                }
                agent = Some((
                    *kind,
                    session_id,
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
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        cmd.env(brand::env_var("PANE_ID"), id.0.to_string());
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
            self.cfg.scrollback_bytes,
        )
        .map_err(|e| (OpError::SpawnFailed, e.to_string()))?;
        let record = PaneRecord {
            launch: launch.clone(),
            cwd: Some(cwd.clone()),
            agent: agent.as_ref().map(|(kind, session_id, _)| AgentRecord {
                kind: *kind,
                session_id: session_id.clone(),
            }),
            worktree,
        };
        let entry = Arc::new(PaneEntry {
            pane,
            meta: Mutex::new(MetaState {
                cwd: Some(cwd),
                ..MetaState::default()
            }),
            record: Mutex::new(record),
            agent: Mutex::new(agent.map(|(_, _, rt)| rt)),
            task: Mutex::new(None),
            launched_at: SystemTime::now(),
        });
        let task = tokio::spawn(pane_task(Arc::clone(self), Arc::clone(&entry), vt_events));
        *lock(&entry.task) = Some(task.abort_handle());
        lock(&self.panes).insert(id, entry);
        Ok(())
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
            }
            EventKind::TurnEnded
            | EventKind::Interrupted
            | EventKind::Error
            | EventKind::SessionEnded => {
                self.ws
                    .turns
                    .record(crate::ws::turns::Boundary::End { pane: id });
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
                .and_then(|t| t.last_message.clone());
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
        if !blocked {
            crate::ws::agent_unblocked(self, id);
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
                    self.hooks.resolve(id, &details.request, details.choice);
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

/// Per-pane task: turns VT events, termios changes, agent timers and process exit into
/// metadata, echo hints and agent events.
async fn pane_task(
    core: Arc<Core>,
    entry: Arc<PaneEntry>,
    mut vt_events: mpsc::UnboundedReceiver<VtEvent>,
) {
    let id = entry.pane.id;
    let pane = Arc::clone(&entry.pane);
    let mut echo = pane.echo_updates();
    let exit = pane.pty().wait();
    tokio::pin!(exit);
    let mut agent_tick = tokio::time::interval(Duration::from_millis(500));
    agent_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut screen_dirty = false;
    let mut detect_tick = 0u32;
    let codex_lookup = Arc::new(AtomicBool::new(false));
    refresh_hint(&core, &entry);
    loop {
        tokio::select! {
            event = vt_events.recv() => {
                let Some(event) = event else { break };
                match event {
                    VtEvent::Reply(bytes) => {
                        let _ = pane.pty().try_write(bytes);
                    }
                    VtEvent::Activity => {
                        screen_dirty = true;
                        if let Some(rt) = lock(&entry.agent).as_mut() {
                            rt.pty_output();
                        }
                    }
                    VtEvent::AltScreen => refresh_hint(&core, &entry),
                    VtEvent::Osc(osc) => handle_osc(&core, &entry, osc),
                    VtEvent::Command(update) => handle_command(&core, &entry, update),
                }
            }
            changed = echo.changed() => {
                if changed.is_err() {
                    continue;
                }
                refresh_hint(&core, &entry);
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
            _ = agent_tick.tick() => {
                detect_tick += 1;
                if detect_tick.is_multiple_of(2) && lock(&entry.agent).is_none() {
                    detect_agent(&entry);
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

fn handle_osc(core: &Core, entry: &PaneEntry, osc: Osc) {
    let id = entry.pane.id;
    match osc {
        Osc::Title(title) => {
            lock(&entry.meta).title = title;
            core.emit(Event::PaneMeta(id));
        }
        Osc::Cwd(cwd) => {
            lock(&entry.meta).cwd = Some(cwd.clone());
            let mut record = lock(&entry.record);
            if record.cwd.as_deref() != Some(cwd.as_str()) {
                record.cwd = Some(cwd);
                core.mark_dirty();
            }
            core.emit(Event::PaneMeta(id));
        }
        Osc::Notify(body) => {
            let event = lock(&entry.agent).as_mut().and_then(|rt| rt.osc9(&body));
            core.agent_event(id, event);
        }
        Osc::ProgramStatus(body) => {
            let event = lock(&entry.agent)
                .as_mut()
                .and_then(|rt| rt.program_status(&body));
            core.agent_event(id, event);
        }
    }
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
    let codex_home = core
        .cfg
        .pane_var("CODEX_HOME")
        .map(PathBuf::from)
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
    *lock(&entry.agent) = Some(AgentRuntime::new(kind, entry.pane.id, adapter, false));
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
pub(crate) fn restore(core: &Arc<Core>, panes: HashMap<PaneId, PaneRecord>) {
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
                agent.session_id.is_some()
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
    persist::Saved::new(layout, panes)
}
