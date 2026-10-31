//! FFI mirrors of the `proto` wire types the client API uses.
//!
//! The wire types use newtype ids, boxed trees and `Result` fields, none of which UniFFI can
//! express, so each gets a plain twin here plus a lossless conversion. Ids are `u64` in
//! Swift. Split trees are flattened ([`TabLayout::nodes`]).

use client_core::proto;

/// A pane's terminal size.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PaneSize {
    /// Columns.
    pub cols: u16,
    /// Rows.
    pub rows: u16,
    /// Width in pixels (0 if unknown); used for SGR-pixel mouse reports.
    #[uniffi(default = 0)]
    pub width_px: u16,
    /// Height in pixels (0 if unknown).
    #[uniffi(default = 0)]
    pub height_px: u16,
}

impl From<proto::PaneSize> for PaneSize {
    fn from(s: proto::PaneSize) -> Self {
        Self {
            cols: s.cols,
            rows: s.rows,
            width_px: s.width_px,
            height_px: s.height_px,
        }
    }
}

impl From<PaneSize> for proto::PaneSize {
    fn from(s: PaneSize) -> Self {
        Self {
            cols: s.cols,
            rows: s.rows,
            width_px: s.width_px,
            height_px: s.height_px,
        }
    }
}

/// How a split arranges its two children.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Axis {
    /// Side by side: first on the left.
    Horizontal,
    /// Stacked: first on top.
    Vertical,
}

impl From<proto::Axis> for Axis {
    fn from(a: proto::Axis) -> Self {
        match a {
            proto::Axis::Horizontal => Self::Horizontal,
            proto::Axis::Vertical => Self::Vertical,
        }
    }
}

impl From<Axis> for proto::Axis {
    fn from(a: Axis) -> Self {
        match a {
            Axis::Horizontal => Self::Horizontal,
            Axis::Vertical => Self::Vertical,
        }
    }
}

/// A direction for moving focus.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Direction {
    /// Towards smaller x.
    Left,
    /// Towards larger x.
    Right,
    /// Towards smaller y.
    Up,
    /// Towards larger y.
    Down,
}

impl From<Direction> for proto::Direction {
    fn from(d: Direction) -> Self {
        match d {
            Direction::Left => Self::Left,
            Direction::Right => Self::Right,
            Direction::Up => Self::Up,
            Direction::Down => Self::Down,
        }
    }
}

/// One node of a flattened split tree; children are indices into [`TabLayout::nodes`].
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum LayoutNode {
    /// A pane.
    Leaf {
        /// The pane.
        pane_id: u64,
    },
    /// Two subtrees sharing the space along `axis`.
    Split {
        /// How the children are arranged.
        axis: Axis,
        /// The first child's share, strictly between 0 and 1.
        ratio: f32,
        /// Index of the left or top child.
        first: u32,
        /// Index of the right or bottom child.
        second: u32,
    },
}

/// One tab of a session.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TabLayout {
    /// The tab.
    pub tab_id: u64,
    /// User-visible name; empty means "use the focused pane's title".
    pub name: String,
    /// The split tree, root first (`nodes[0]`), parents before children.
    pub nodes: Vec<LayoutNode>,
    /// The pane with keyboard focus.
    pub focused: u64,
    /// The pane shown full-tab, if any.
    pub zoomed: Option<u64>,
}

fn flatten(node: &proto::LayoutNode, out: &mut Vec<LayoutNode>) -> u32 {
    let index = u32::try_from(out.len()).expect("a split tree fits in u32 nodes");
    match node {
        proto::LayoutNode::Leaf(pane) => out.push(LayoutNode::Leaf { pane_id: pane.0 }),
        proto::LayoutNode::Split {
            axis,
            ratio,
            first,
            second,
        } => {
            out.push(LayoutNode::Split {
                axis: (*axis).into(),
                ratio: *ratio,
                first: 0,
                second: 0,
            });
            let a = flatten(first, out);
            let b = flatten(second, out);
            if let LayoutNode::Split { first, second, .. } = &mut out[index as usize] {
                (*first, *second) = (a, b);
            }
        }
    }
    index
}

impl From<proto::TabLayout> for TabLayout {
    fn from(t: proto::TabLayout) -> Self {
        let mut nodes = Vec::new();
        flatten(&t.root, &mut nodes);
        Self {
            tab_id: t.tab_id.0,
            name: t.name,
            nodes,
            focused: t.focused.0,
            zoomed: t.zoomed.map(|p| p.0),
        }
    }
}

/// A session's whole layout, sent again on every change.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SessionLayout {
    /// The session.
    pub session_id: u64,
    /// Its name.
    pub name: String,
    /// Bumped on every change; ignore a layout older than one already applied.
    pub revision: u64,
    /// The tab on screen.
    pub active_tab: Option<u64>,
    /// Tabs in display order.
    pub tabs: Vec<TabLayout>,
}

impl From<proto::SessionLayout> for SessionLayout {
    fn from(l: proto::SessionLayout) -> Self {
        Self {
            session_id: l.session_id.0,
            name: l.name,
            revision: l.revision,
            active_tab: l.active_tab.map(|t| t.0),
            tabs: l.tabs.into_iter().map(Into::into).collect(),
        }
    }
}

/// A line of the session list.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SessionSummary {
    /// The session.
    pub session_id: u64,
    /// Its name.
    pub name: String,
    /// Tabs.
    pub tabs: u32,
    /// Panes across all tabs.
    pub panes: u32,
    /// Attached clients.
    pub clients: u32,
}

impl From<proto::SessionSummary> for SessionSummary {
    fn from(s: proto::SessionSummary) -> Self {
        Self {
            session_id: s.session_id.0,
            name: s.name,
            tabs: s.tabs,
            panes: s.panes,
            clients: s.clients,
        }
    }
}

/// Which coding agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AgentKind {
    /// Claude Code.
    Claude,
    /// Codex CLI.
    Codex,
}

impl From<AgentKind> for proto::AgentKind {
    fn from(a: AgentKind) -> Self {
        match a {
            AgentKind::Claude => Self::Claude,
            AgentKind::Codex => Self::Codex,
        }
    }
}

/// What a new pane runs.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PaneLaunch {
    /// The login shell.
    Shell {
        /// Working directory; `nil` inherits from the split pane.
        cwd: Option<String>,
    },
    /// A program, run through the login shell.
    Command {
        /// Program and arguments.
        argv: Vec<String>,
        /// Working directory.
        cwd: Option<String>,
    },
    /// A coding agent with the daemon's launch recipe.
    Agent {
        /// Which agent.
        agent: AgentKind,
        /// The agent's own session id to resume.
        resume: Option<String>,
        /// Working directory.
        cwd: Option<String>,
    },
    /// A canvas pane (no process) showing a drawing or Excalidraw scene; `nil` has the daemon
    /// create a new Excalidraw scene (docs/DAEMON.md §7.2, §7.11). Which leaves are canvases
    /// comes from `ArtifactEvent.canvases`.
    Canvas {
        /// The artifact to show.
        artifact_id: Option<u64>,
    },
    /// A pane closed earlier on this daemon, back: its agent resumes its session, else a
    /// shell in its last directory, else `cwd` (needs `DaemonInfo.reopen` and the owner).
    Reopen {
        /// The closed pane.
        pane_id: u64,
        /// Where to start when the daemon kept no directory for it.
        cwd: Option<String>,
    },
}

impl From<PaneLaunch> for proto::PaneLaunch {
    fn from(l: PaneLaunch) -> Self {
        match l {
            PaneLaunch::Shell { cwd } => Self::Shell { cwd },
            PaneLaunch::Command { argv, cwd } => Self::Command { argv, cwd },
            PaneLaunch::Agent { agent, resume, cwd } => Self::Agent {
                agent: agent.into(),
                resume,
                cwd,
            },
            PaneLaunch::Canvas { artifact_id } => Self::Canvas {
                artifact_id: artifact_id.map(proto::ArtifactId),
            },
            PaneLaunch::Reopen { pane_id, cwd } => Self::Reopen {
                pane_id: proto::PaneId(pane_id),
                cwd,
            },
        }
    }
}

/// A layout change for [`DaemonClient::op`](crate::DaemonClient::op).
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum LayoutOp {
    /// Splits a pane; the new pane goes after it and takes focus.
    Split {
        /// The pane to split.
        pane_id: u64,
        /// Arrangement.
        axis: Axis,
        /// What the new pane runs.
        launch: PaneLaunch,
    },
    /// Closes a pane (and its tab, if it was the last one).
    ClosePane {
        /// The pane.
        pane_id: u64,
    },
    /// Focuses a pane and selects its tab.
    Focus {
        /// The pane.
        pane_id: u64,
    },
    /// Moves a tab's focus to the nearest pane in `direction`.
    FocusDirection {
        /// The tab.
        tab_id: u64,
        /// Where to.
        direction: Direction,
    },
    /// Grows (positive) or shrinks a pane along `axis` by moving its nearest divider.
    Resize {
        /// The pane.
        pane_id: u64,
        /// Dimension.
        axis: Axis,
        /// Change of the pane's share.
        delta: f32,
    },
    /// Zooms a pane to fill its tab, or unzooms it.
    ToggleZoom {
        /// The pane.
        pane_id: u64,
    },
    /// Appends a tab with one pane and selects it.
    NewTab {
        /// The session.
        session_id: u64,
        /// Name, empty for the default.
        name: String,
        /// What its pane runs.
        launch: PaneLaunch,
    },
    /// Closes a tab and its panes.
    CloseTab {
        /// The tab.
        tab_id: u64,
    },
    /// Moves a tab to `index` (clamped).
    MoveTab {
        /// The tab.
        tab_id: u64,
        /// New position.
        index: u32,
    },
    /// Shows a tab.
    SelectTab {
        /// The tab.
        tab_id: u64,
    },
    /// Renames a tab.
    RenameTab {
        /// The tab.
        tab_id: u64,
        /// New name.
        name: String,
    },
    /// Renames a session (fails if the name is taken).
    RenameSession {
        /// The session.
        session_id: u64,
        /// New name.
        name: String,
    },
    /// Creates a session with one tab and pane.
    CreateSession {
        /// Its name.
        name: String,
        /// What its pane runs.
        launch: PaneLaunch,
    },
    /// Closes a session and its panes.
    CloseSession {
        /// The session.
        session_id: u64,
    },
    /// Moves a pane into a new tab after its own (daemons with `pane_moves`).
    BreakPane {
        /// The pane.
        pane_id: u64,
    },
    /// Moves a pane beside `target` on `side` (daemons with `pane_moves`).
    MovePane {
        /// The pane.
        pane_id: u64,
        /// The pane it goes beside.
        target: u64,
        /// Which side of `target`.
        side: Direction,
    },
    /// Moves a tab's panes beside `target` on `side`; the tab closes (daemons with
    /// `pane_moves`).
    MergeTab {
        /// The tab.
        tab_id: u64,
        /// The pane they go beside.
        target: u64,
        /// Which side of `target`.
        side: Direction,
    },
    /// Puts a tab in a project defined in its session (`PutProject` first), moves it within
    /// it by `rank`, or ungroups it with `nil` (daemons with `projects`).
    SetTabProject {
        /// The tab.
        tab_id: u64,
        /// The project, or `nil` to ungroup.
        project_id: Option<String>,
        /// Where the tab sorts within the project.
        rank: i64,
    },
    /// Defines or updates a project in a session; an older `updated_ms` than the daemon's
    /// copy is ignored (daemons with `projects`).
    PutProject {
        /// The session.
        session_id: u64,
        /// The definition.
        project: DaemonProject,
    },
    /// Ungroups every tab of a project in a session and drops it (daemons with `projects`).
    RemoveProject {
        /// The session.
        session_id: u64,
        /// The project.
        project_id: String,
    },
}

impl From<LayoutOp> for proto::LayoutOp {
    fn from(op: LayoutOp) -> Self {
        use proto::{PaneId, SessionId, TabId};
        match op {
            LayoutOp::Split {
                pane_id,
                axis,
                launch,
            } => Self::Split {
                pane_id: PaneId(pane_id),
                axis: axis.into(),
                launch: launch.into(),
            },
            LayoutOp::ClosePane { pane_id } => Self::ClosePane {
                pane_id: PaneId(pane_id),
            },
            LayoutOp::Focus { pane_id } => Self::Focus {
                pane_id: PaneId(pane_id),
            },
            LayoutOp::FocusDirection { tab_id, direction } => Self::FocusDirection {
                tab_id: TabId(tab_id),
                direction: direction.into(),
            },
            LayoutOp::Resize {
                pane_id,
                axis,
                delta,
            } => Self::Resize {
                pane_id: PaneId(pane_id),
                axis: axis.into(),
                delta,
            },
            LayoutOp::ToggleZoom { pane_id } => Self::ToggleZoom {
                pane_id: PaneId(pane_id),
            },
            LayoutOp::NewTab {
                session_id,
                name,
                launch,
            } => Self::NewTab {
                session_id: SessionId(session_id),
                name,
                launch: launch.into(),
            },
            LayoutOp::CloseTab { tab_id } => Self::CloseTab {
                tab_id: TabId(tab_id),
            },
            LayoutOp::MoveTab { tab_id, index } => Self::MoveTab {
                tab_id: TabId(tab_id),
                index,
            },
            LayoutOp::SelectTab { tab_id } => Self::SelectTab {
                tab_id: TabId(tab_id),
            },
            LayoutOp::RenameTab { tab_id, name } => Self::RenameTab {
                tab_id: TabId(tab_id),
                name,
            },
            LayoutOp::RenameSession { session_id, name } => Self::RenameSession {
                session_id: SessionId(session_id),
                name,
            },
            LayoutOp::CreateSession { name, launch } => Self::CreateSession {
                name,
                launch: launch.into(),
            },
            LayoutOp::CloseSession { session_id } => Self::CloseSession {
                session_id: SessionId(session_id),
            },
            LayoutOp::BreakPane { pane_id } => Self::BreakPane {
                pane_id: PaneId(pane_id),
            },
            LayoutOp::MovePane {
                pane_id,
                target,
                side,
            } => Self::MovePane {
                pane_id: PaneId(pane_id),
                target: PaneId(target),
                side: side.into(),
            },
            LayoutOp::MergeTab {
                tab_id,
                target,
                side,
            } => Self::MergeTab {
                tab_id: TabId(tab_id),
                target: PaneId(target),
                side: side.into(),
            },
            LayoutOp::SetTabProject {
                tab_id,
                project_id,
                rank,
            } => Self::SetTabProject {
                tab_id: TabId(tab_id),
                project: project_id,
                rank,
            },
            LayoutOp::PutProject {
                session_id,
                project,
            } => Self::PutProject {
                session_id: SessionId(session_id),
                project: project.into(),
            },
            LayoutOp::RemoveProject {
                session_id,
                project_id,
            } => Self::RemoveProject {
                session_id: SessionId(session_id),
                project: project_id,
            },
        }
    }
}

/// A project (a named, coloured group of tabs) as one daemon session knows it. The same id
/// on several daemons is one project.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DaemonProject {
    /// Client-chosen id, 1–64 bytes.
    pub id: String,
    /// Its name, up to 128 bytes.
    pub name: String,
    /// Palette index, 0–7.
    pub color: u8,
    /// Where it sorts among projects.
    pub order: i64,
    /// When it was last changed (Unix milliseconds); the newer definition wins.
    pub updated_ms: u64,
}

impl From<proto::Project> for DaemonProject {
    fn from(p: proto::Project) -> Self {
        Self {
            id: p.id,
            name: p.name,
            color: p.color,
            order: p.order,
            updated_ms: p.updated.0,
        }
    }
}

impl From<DaemonProject> for proto::Project {
    fn from(p: DaemonProject) -> Self {
        Self {
            id: p.id,
            name: p.name,
            color: p.color,
            order: p.order,
            updated: proto::UnixMillis(p.updated_ms),
        }
    }
}

/// One tab's membership in a project.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DaemonTabProject {
    /// The tab.
    pub tab_id: u64,
    /// The project.
    pub project_id: String,
    /// Where the tab sorts within the project.
    pub rank: i64,
}

/// A session's projects, as far as the connection sees.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DaemonProjects {
    /// The session.
    pub session_id: u64,
    /// The session layout revision these belong to.
    pub revision: u64,
    /// Definitions of the projects `tabs` use.
    pub projects: Vec<DaemonProject>,
    /// Tab memberships.
    pub tabs: Vec<DaemonTabProject>,
}

impl From<proto::SessionProjects> for DaemonProjects {
    fn from(p: proto::SessionProjects) -> Self {
        Self {
            session_id: p.session_id.0,
            revision: p.revision,
            projects: p.projects.into_iter().map(Into::into).collect(),
            tabs: p
                .tabs
                .into_iter()
                .map(|m| DaemonTabProject {
                    tab_id: m.tab_id.0,
                    project_id: m.project,
                    rank: m.rank,
                })
                .collect(),
        }
    }
}

/// Why a layout op failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum OpErrorCode {
    /// A referenced session, tab or pane does not exist.
    NotFound,
    /// The session name is taken.
    NameTaken,
    /// The process could not be started.
    SpawnFailed,
    /// Invalid arguments.
    Invalid,
    /// Not allowed by the grant.
    Forbidden,
}

impl From<proto::OpError> for OpErrorCode {
    fn from(code: proto::OpError) -> Self {
        match code {
            proto::OpError::NotFound => Self::NotFound,
            proto::OpError::NameTaken => Self::NameTaken,
            proto::OpError::SpawnFailed => Self::SpawnFailed,
            proto::OpError::Invalid => Self::Invalid,
            proto::OpError::Forbidden => Self::Forbidden,
        }
    }
}

/// How the daemon chose the session a connection attached to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AttachVia {
    /// The session the client asked for.
    Requested,
    /// The most recently used session.
    MostRecent,
    /// A new session, because there was none.
    Created,
}

impl From<proto::AttachVia> for AttachVia {
    fn from(via: proto::AttachVia) -> Self {
        match via {
            proto::AttachVia::Requested => Self::Requested,
            proto::AttachVia::MostRecent => Self::MostRecent,
            proto::AttachVia::Created => Self::Created,
        }
    }
}

/// The result of a layout op.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum OpOutcome {
    /// Applied; nothing created.
    Done,
    /// A pane was created.
    PaneCreated {
        /// The new pane.
        pane_id: u64,
    },
    /// A tab was created.
    TabCreated {
        /// The new tab.
        tab_id: u64,
        /// Its pane.
        pane_id: u64,
    },
    /// A session was created.
    SessionCreated {
        /// The session.
        session_id: u64,
        /// Its tab.
        tab_id: u64,
        /// Its pane.
        pane_id: u64,
    },
    /// Not applied.
    Failed {
        /// Machine-readable reason.
        code: OpErrorCode,
        /// Detail.
        message: String,
    },
}

impl From<proto::OpOutcome> for OpOutcome {
    fn from(o: proto::OpOutcome) -> Self {
        match o {
            proto::OpOutcome::Done => Self::Done,
            proto::OpOutcome::PaneCreated { pane_id } => Self::PaneCreated { pane_id: pane_id.0 },
            proto::OpOutcome::TabCreated { tab_id, pane_id } => Self::TabCreated {
                tab_id: tab_id.0,
                pane_id: pane_id.0,
            },
            proto::OpOutcome::SessionCreated {
                session_id,
                tab_id,
                pane_id,
            } => Self::SessionCreated {
                session_id: session_id.0,
                tab_id: tab_id.0,
                pane_id: pane_id.0,
            },
            proto::OpOutcome::Failed { code, message } => Self::Failed {
                code: code.into(),
                message,
            },
        }
    }
}

/// A choice offered by a blocked agent.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DecisionOption {
    /// Pass to [`DaemonClient::decide`](crate::DaemonClient::decide).
    pub id: u32,
    /// Button label.
    pub label: String,
}

/// What an agent is doing.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AgentState {
    /// Waiting for a prompt.
    Idle,
    /// Working.
    Running,
    /// Needs a decision.
    Blocked {
        /// Answer with [`DaemonClient::decide`](crate::DaemonClient::decide).
        request_id: u64,
        /// What it asks.
        summary: String,
        /// The choices.
        options: Vec<DecisionOption>,
    },
    /// Finished its turn.
    Done,
}

/// An agent running in a pane.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AgentStatus {
    /// `claude`, `codex`, …
    pub kind: String,
    /// Its state.
    pub state: AgentState,
}

impl From<proto::AgentStatus> for AgentStatus {
    fn from(a: proto::AgentStatus) -> Self {
        Self {
            kind: a.kind,
            state: match a.state {
                proto::AgentState::Idle => AgentState::Idle,
                proto::AgentState::Running => AgentState::Running,
                proto::AgentState::Done => AgentState::Done,
                proto::AgentState::Blocked(b) => AgentState::Blocked {
                    request_id: b.request_id.0,
                    summary: b.summary,
                    options: b
                        .options
                        .into_iter()
                        .map(|o| DecisionOption {
                            id: o.id.0,
                            label: o.label,
                        })
                        .collect(),
                },
            },
        }
    }
}

/// What any program in a pane says about itself (OSC 7501 or the `status_set` tool). A
/// blocked report is a status only: there is no request to answer.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProgramReport {
    /// What it is doing.
    pub state: ProgramState,
    /// What a blocked program waits for, if it said.
    pub kind: Option<ProgramKind>,
    /// The program's name (`pi`, `opencode`), if it gave one.
    pub app: Option<String>,
    /// One line for people.
    pub message: Option<String>,
    /// Percent complete (0–100).
    pub progress: Option<u8>,
}

/// What a program says it is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ProgramState {
    /// At rest.
    Idle,
    /// Running.
    Working,
    /// Finished work not looked at yet.
    Done,
    /// Waiting on the user.
    Blocked,
    /// Failed and stopped.
    Error,
}

/// What a blocked program waits for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ProgramKind {
    /// Approval to do something.
    Permission,
    /// An answer to type.
    Question,
    /// A login or credential.
    Auth,
}

impl From<proto::ProgramReport> for ProgramReport {
    fn from(r: proto::ProgramReport) -> Self {
        Self {
            state: match r.state {
                proto::ProgramState::Idle => ProgramState::Idle,
                proto::ProgramState::Working => ProgramState::Working,
                proto::ProgramState::Done => ProgramState::Done,
                proto::ProgramState::Blocked => ProgramState::Blocked,
                proto::ProgramState::Error => ProgramState::Error,
            },
            kind: r.kind.map(|k| match k {
                proto::ProgramKind::Permission => ProgramKind::Permission,
                proto::ProgramKind::Question => ProgramKind::Question,
                proto::ProgramKind::Auth => ProgramKind::Auth,
            }),
            app: r.app,
            message: r.message,
            progress: r.progress,
        }
    }
}

/// Whose size a pane's PTY follows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SizePolicy {
    /// The lease holder's.
    FollowLease,
    /// The client that last typed.
    LastInput,
    /// A fixed size.
    Fixed {
        /// Columns.
        cols: u16,
        /// Rows.
        rows: u16,
    },
    /// The smallest attached client's.
    Smallest,
}

/// A pane's metadata.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PaneMeta {
    /// The pane.
    pub pane_id: u64,
    /// Title (OSC 0/2).
    pub title: String,
    /// Working directory (OSC 7).
    pub cwd: Option<String>,
    /// Exit status once the process ended.
    pub exit: Option<i32>,
    /// The agent in it, if any.
    pub agent: Option<AgentStatus>,
    /// The PTY's size.
    pub size: PaneSize,
    /// Whose size it follows.
    pub size_policy: SizePolicy,
    /// The principal whose size it has (16 bytes), if any.
    pub sized_by: Option<Vec<u8>>,
}

impl From<proto::PaneMeta> for PaneMeta {
    fn from(m: proto::PaneMeta) -> Self {
        Self {
            pane_id: m.pane_id.0,
            title: m.title,
            cwd: m.cwd,
            exit: m.exit,
            agent: m.agent.map(Into::into),
            size: m.size.into(),
            size_policy: match m.size_policy {
                proto::SizePolicy::FollowLease => SizePolicy::FollowLease,
                proto::SizePolicy::LastInput => SizePolicy::LastInput,
                proto::SizePolicy::Fixed { cols, rows } => SizePolicy::Fixed { cols, rows },
                proto::SizePolicy::Smallest => SizePolicy::Smallest,
            },
            sized_by: m.sized_by.map(|p| p.0.to_vec()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Prediction {
    /// Predict.
    Allow,
    /// Hidden input (password prompt): never predict.
    HiddenInput,
    /// Full-screen program: never predict.
    AltScreen,
    /// Raw mode outside a shell prompt: don't predict.
    RawOutsidePrompt,
}

/// Echo prediction facts for a pane, at a point in its output.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct EchoHint {
    /// The pane.
    pub pane_id: u64,
    /// termios `ECHO`.
    pub echo: bool,
    /// termios `ICANON`.
    pub icanon: bool,
    /// The alternate screen is active.
    pub alt_screen: bool,
    /// At a shell prompt (OSC 133).
    pub at_prompt: bool,
    /// Output offset the facts hold from.
    pub at_seq: u64,
    /// The decision.
    pub prediction: Prediction,
}

impl From<proto::EchoHintAt> for EchoHint {
    fn from(h: proto::EchoHintAt) -> Self {
        Self {
            pane_id: h.hint.pane_id.0,
            echo: h.hint.echo,
            icanon: h.hint.icanon,
            alt_screen: h.hint.alt_screen,
            at_prompt: h.hint.at_prompt,
            at_seq: h.at_seq.0,
            prediction: match h.prediction {
                proto::Prediction::Allow => Prediction::Allow,
                proto::Prediction::HiddenInput => Prediction::HiddenInput,
                proto::Prediction::AltScreen => Prediction::AltScreen,
                proto::Prediction::RawOutsidePrompt => Prediction::RawOutsidePrompt,
            },
        }
    }
}

/// How a command ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct CommandEnd {
    /// Exit status, if the shell reported one.
    pub exit: Option<i32>,
    /// Run time.
    pub duration_ms: u64,
}

/// A shell-integration command (OSC 133).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommandMark {
    /// The pane.
    pub pane_id: u64,
    /// Per-pane id.
    pub command_id: u64,
    /// The command line, if known.
    pub command: Option<String>,
    /// Working directory.
    pub cwd: Option<String>,
    /// Start, Unix milliseconds.
    pub started_at_ms: u64,
    /// Output offset of the mark.
    pub at_seq: u64,
    /// Set once finished.
    pub finished: Option<CommandEnd>,
}

impl From<proto::CommandMark> for CommandMark {
    fn from(m: proto::CommandMark) -> Self {
        Self {
            pane_id: m.pane_id.0,
            command_id: m.command_id,
            command: m.command,
            cwd: m.cwd,
            started_at_ms: m.started_at.0,
            at_seq: m.at_seq.0,
            finished: m.finished.map(|e| CommandEnd {
                exit: e.exit,
                duration_ms: e.duration_ms,
            }),
        }
    }
}

/// A command with its screen rows (row 0 = oldest retained row).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommandInfo {
    /// The command.
    pub mark: CommandMark,
    /// Prompt row.
    pub prompt_row: Option<u64>,
    /// First output row.
    pub output_row: Option<u64>,
    /// Row after the output.
    pub end_row: Option<u64>,
}

/// A pane's remembered commands.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommandList {
    /// Output offset the rows refer to.
    pub at_seq: u64,
    /// Rows on the screen including scrollback.
    pub total_rows: u64,
    /// Oldest first.
    pub commands: Vec<CommandInfo>,
}

impl From<proto::CommandList> for CommandList {
    fn from(l: proto::CommandList) -> Self {
        Self {
            at_seq: l.at_seq.0,
            total_rows: l.total_rows,
            commands: l
                .commands
                .into_iter()
                .map(|c| CommandInfo {
                    mark: c.mark.into(),
                    prompt_row: c.rows.prompt,
                    output_row: c.rows.output,
                    end_row: c.rows.end,
                })
                .collect(),
        }
    }
}

/// A command's output text.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommandOutput {
    /// The command.
    pub mark: CommandMark,
    /// Output, soft wraps joined.
    pub text: String,
    /// Cut to the last 2 MiB.
    pub truncated: bool,
}

impl From<proto::CommandOutput> for CommandOutput {
    fn from(o: proto::CommandOutput) -> Self {
        Self {
            mark: o.mark.into(),
            text: o.text,
            truncated: o.truncated,
        }
    }
}

/// Plain text or regex.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SearchMode {
    /// Literal text.
    Plain,
    /// Rust `regex` syntax.
    Regex,
}

/// Case handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CaseMode {
    /// Exact case.
    Sensitive,
    /// Ignore case.
    Insensitive,
    /// Sensitive only if the pattern has an uppercase letter.
    Smart,
}

/// A scrollback search.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SearchQuery {
    /// What to find.
    pub pattern: String,
    /// How to read it.
    pub mode: SearchMode,
    /// Case handling.
    pub case: CaseMode,
}

impl From<SearchQuery> for proto::SearchQuery {
    fn from(q: SearchQuery) -> Self {
        Self {
            pattern: q.pattern,
            mode: match q.mode {
                SearchMode::Plain => proto::SearchMode::Plain,
                SearchMode::Regex => proto::SearchMode::Regex,
            },
            case: match q.case {
                CaseMode::Sensitive => proto::CaseMode::Sensitive,
                CaseMode::Insensitive => proto::CaseMode::Insensitive,
                CaseMode::Smart => proto::CaseMode::Smart,
            },
        }
    }
}

/// One match, in screen rows at the page's `at_seq` (row 0 = oldest retained row).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SearchMatch {
    /// Start row.
    pub row: u64,
    /// Start column.
    pub col: u16,
    /// End row.
    pub end_row: u64,
    /// End column (exclusive).
    pub end_col: u16,
    /// The matched line's text.
    pub line: String,
}

/// One page of search results, newest first.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SearchPage {
    /// Output offset the rows refer to.
    pub at_seq: u64,
    /// Rows on the screen including scrollback.
    pub total_rows: u64,
    /// Matches in total.
    pub total: u32,
    /// This page.
    pub matches: Vec<SearchMatch>,
    /// Cursor for the next page.
    pub next: Option<u32>,
}

impl From<proto::SearchPage> for SearchPage {
    fn from(p: proto::SearchPage) -> Self {
        Self {
            at_seq: p.at_seq.0,
            total_rows: p.total_rows,
            total: p.total,
            matches: p
                .matches
                .into_iter()
                .map(|m| SearchMatch {
                    row: m.row,
                    col: m.col,
                    end_row: m.end_row,
                    end_col: m.end_col,
                    line: m.line,
                })
                .collect(),
            next: p.next,
        }
    }
}

/// What kind of link.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkKind {
    /// OSC 8 hyperlink.
    Hyperlink,
    /// A URL in the text.
    Url,
    /// A file path.
    Path,
}

/// Where a link was found.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkSource {
    /// The visible screen.
    Screen,
    /// A command's output.
    Command {
        /// The command.
        command_id: u64,
    },
}

/// A link or path.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Link {
    /// Kind.
    pub kind: LinkKind,
    /// The text as shown.
    pub text: String,
    /// URL or absolute path.
    pub target: String,
    /// `path:line`.
    pub line: Option<u32>,
    /// `path:line:col`.
    pub column: Option<u32>,
    /// For paths: whether it exists on the host.
    pub exists: Option<bool>,
    /// Where it was found.
    pub source: LinkSource,
}

/// Links on a pane's screen and in recent output.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Links {
    /// The pane's directory paths were resolved against.
    pub cwd: Option<String>,
    /// Screen first, bottom up.
    pub links: Vec<Link>,
}

impl From<proto::Links> for Links {
    fn from(l: proto::Links) -> Self {
        Self {
            cwd: l.cwd,
            links: l
                .links
                .into_iter()
                .map(|k| Link {
                    kind: match k.kind {
                        proto::LinkKind::Hyperlink => LinkKind::Hyperlink,
                        proto::LinkKind::Url => LinkKind::Url,
                        proto::LinkKind::Path => LinkKind::Path,
                    },
                    text: k.text,
                    target: k.target,
                    line: k.line,
                    column: k.column,
                    exists: k.exists,
                    source: match k.source {
                        proto::LinkSource::Screen => LinkSource::Screen,
                        proto::LinkSource::Command { command_id } => {
                            LinkSource::Command { command_id }
                        }
                    },
                })
                .collect(),
        }
    }
}

/// Why a daemon request failed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RpcError {
    /// No such pane.
    UnknownPane,
    /// The request was invalid (e.g. a bad regex).
    BadRequest {
        /// Why.
        message: String,
    },
    /// Nothing to return (e.g. no finished command).
    NotFound,
    /// The daemon failed.
    Internal {
        /// Why.
        message: String,
    },
}

impl From<proto::RpcError> for RpcError {
    fn from(e: proto::RpcError) -> Self {
        match e {
            proto::RpcError::UnknownPane => Self::UnknownPane,
            proto::RpcError::BadRequest(message) => Self::BadRequest { message },
            proto::RpcError::NotFound => Self::NotFound,
            proto::RpcError::Internal(message) => Self::Internal { message },
        }
    }
}

/// Press, repeat or release.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum KeyAction {
    /// Key down.
    Press,
    /// Auto-repeat.
    Repeat,
    /// Key up.
    Release,
}

impl From<KeyAction> for proto::KeyAction {
    fn from(a: KeyAction) -> Self {
        match a {
            KeyAction::Press => Self::Press,
            KeyAction::Repeat => Self::Repeat,
            KeyAction::Release => Self::Release,
        }
    }
}

/// A key event, encoded by the daemon for the program's keyboard modes. Field meanings
/// follow libghostty-vt's key event (`GhosttyKey` code, `GhosttyMods` bits).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KeyEvent {
    /// Physical key (`GhosttyKey`).
    pub key: u32,
    /// Modifier bits.
    pub mods: u16,
    /// Modifiers consumed to produce `text`.
    #[uniffi(default = 0)]
    pub consumed_mods: u16,
    /// Press, repeat or release.
    pub action: KeyAction,
    /// Text the key produced.
    #[uniffi(default = None)]
    pub text: Option<String>,
    /// The key's codepoint without Shift (kitty protocol).
    #[uniffi(default = None)]
    pub unshifted_codepoint: Option<u32>,
    /// Part of an IME composition.
    #[uniffi(default = false)]
    pub composing: bool,
}

impl From<KeyEvent> for proto::FullKeyEvent {
    fn from(k: KeyEvent) -> Self {
        Self {
            key: k.key,
            mods: k.mods,
            consumed_mods: k.consumed_mods,
            action: k.action.into(),
            text: k.text,
            unshifted_codepoint: k.unshifted_codepoint,
            composing: k.composing,
        }
    }
}

/// Mouse press, release or motion.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MouseAction {
    /// Button down.
    Press,
    /// Button up.
    Release,
    /// Movement.
    Motion,
}

/// Which mouse button.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MouseButton {
    /// None (motion).
    None,
    /// Left.
    Left,
    /// Middle.
    Middle,
    /// Right.
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

/// A mouse event in cell coordinates; the daemon encodes it for the program's tracking
/// mode and drops it if the program does not track the mouse.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct MouseEvent {
    /// What happened.
    pub action: MouseAction,
    /// Which button.
    pub button: MouseButton,
    /// Column.
    pub col: u16,
    /// Row.
    pub row: u16,
    /// Modifier bits.
    #[uniffi(default = 0)]
    pub mods: u16,
}

impl From<MouseEvent> for proto::MouseEvent {
    fn from(m: MouseEvent) -> Self {
        Self {
            action: match m.action {
                MouseAction::Press => proto::MouseAction::Press,
                MouseAction::Release => proto::MouseAction::Release,
                MouseAction::Motion => proto::MouseAction::Motion,
            },
            button: match m.button {
                MouseButton::None => proto::MouseButton::None,
                MouseButton::Left => proto::MouseButton::Left,
                MouseButton::Middle => proto::MouseButton::Middle,
                MouseButton::Right => proto::MouseButton::Right,
                MouseButton::WheelUp => proto::MouseButton::WheelUp,
                MouseButton::WheelDown => proto::MouseButton::WheelDown,
                MouseButton::WheelLeft => proto::MouseButton::WheelLeft,
                MouseButton::WheelRight => proto::MouseButton::WheelRight,
            },
            col: m.col,
            row: m.row,
            mods: m.mods,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_trees_flatten_root_first() {
        let root = proto::LayoutNode::Split {
            axis: proto::Axis::Horizontal,
            ratio: 0.5,
            first: Box::new(proto::LayoutNode::Leaf(proto::PaneId(1))),
            second: Box::new(proto::LayoutNode::Split {
                axis: proto::Axis::Vertical,
                ratio: 0.25,
                first: Box::new(proto::LayoutNode::Leaf(proto::PaneId(2))),
                second: Box::new(proto::LayoutNode::Leaf(proto::PaneId(3))),
            }),
        };
        let tab = TabLayout::from(proto::TabLayout {
            tab_id: proto::TabId(7),
            name: String::new(),
            root,
            focused: proto::PaneId(3),
            zoomed: None,
        });
        assert_eq!(
            tab.nodes,
            [
                LayoutNode::Split {
                    axis: Axis::Horizontal,
                    ratio: 0.5,
                    first: 1,
                    second: 2
                },
                LayoutNode::Leaf { pane_id: 1 },
                LayoutNode::Split {
                    axis: Axis::Vertical,
                    ratio: 0.25,
                    first: 3,
                    second: 4
                },
                LayoutNode::Leaf { pane_id: 2 },
                LayoutNode::Leaf { pane_id: 3 },
            ]
        );
    }
}
