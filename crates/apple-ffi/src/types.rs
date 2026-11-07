//! FFI mirrors of the `proto` wire types the client API uses.
//!
//! The wire types use newtype ids, boxed trees and `Result` fields, none of which UniFFI can
//! express, so each gets a plain twin here plus a lossless conversion. Ids are `u64` in
//! Swift. Split trees are flattened ([`TabLayout::nodes`]).

use client_core::proto;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PaneSize {
    pub cols: u16,
    pub rows: u16,
    /// Width in pixels (0 if unknown); used for SGR-pixel mouse reports.
    #[uniffi(default = 0)]
    pub width_px: u16,
    /// Height in pixels (0 if unknown).
    #[uniffi(default = 0)]
    pub height_px: u16,
}

impl From<proto::PaneSize> for PaneSize {
    fn from(pane_size: proto::PaneSize) -> Self {
        Self {
            cols: pane_size.cols,
            rows: pane_size.rows,
            width_px: pane_size.width_px,
            height_px: pane_size.height_px,
        }
    }
}

/// A terminal theme's colors, each `0xRRGGBB`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TerminalColors {
    pub foreground: u32,
    pub background: u32,
    /// `None`: the cursor takes the foreground color.
    pub cursor: Option<u32>,
    /// All 256 palette colors, or none for the default palette.
    pub palette: Vec<u32>,
}

impl From<TerminalColors> for proto::TerminalColors {
    fn from(colors: TerminalColors) -> Self {
        let rgb = |color: u32| {
            let [_, red, green, blue] = color.to_be_bytes();
            [red, green, blue]
        };
        Self {
            foreground: rgb(colors.foreground),
            background: rgb(colors.background),
            cursor: colors.cursor.map(rgb),
            palette: colors.palette.into_iter().map(rgb).collect(),
        }
    }
}

impl From<PaneSize> for proto::PaneSize {
    fn from(pane_size: PaneSize) -> Self {
        Self {
            cols: pane_size.cols,
            rows: pane_size.rows,
            width_px: pane_size.width_px,
            height_px: pane_size.height_px,
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
    fn from(axis: proto::Axis) -> Self {
        match axis {
            proto::Axis::Horizontal => Self::Horizontal,
            proto::Axis::Vertical => Self::Vertical,
        }
    }
}

impl From<Axis> for proto::Axis {
    fn from(axis: Axis) -> Self {
        match axis {
            Axis::Horizontal => Self::Horizontal,
            Axis::Vertical => Self::Vertical,
        }
    }
}

/// A direction for moving focus.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

impl From<Direction> for proto::Direction {
    fn from(direction: Direction) -> Self {
        match direction {
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
    Leaf {
        pane_id: u64,
    },
    /// Two subtrees sharing the space along `axis`.
    Split {
        axis: Axis,
        /// The first child's share, strictly between 0 and 1.
        ratio: f32,
        /// Index of the left or top child.
        first: u32,
        /// Index of the right or bottom child.
        second: u32,
    },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TabLayout {
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
            let first_index = flatten(first, out);
            let second_index = flatten(second, out);
            if let LayoutNode::Split { first, second, .. } = &mut out[index as usize] {
                (*first, *second) = (first_index, second_index);
            }
        }
    }
    index
}

impl From<proto::TabLayout> for TabLayout {
    fn from(tab_layout: proto::TabLayout) -> Self {
        let mut nodes = Vec::new();
        flatten(&tab_layout.root, &mut nodes);
        Self {
            tab_id: tab_layout.tab_id.0,
            name: tab_layout.name,
            nodes,
            focused: tab_layout.focused.0,
            zoomed: tab_layout.zoomed.map(|p| p.0),
        }
    }
}

/// A session's whole layout, sent again on every change.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SessionLayout {
    pub session_id: u64,
    pub name: String,
    /// Bumped on every change; ignore a layout older than one already applied.
    pub revision: u64,
    /// The tab on screen.
    pub active_tab: Option<u64>,
    /// Tabs in display order.
    pub tabs: Vec<TabLayout>,
}

impl From<proto::SessionLayout> for SessionLayout {
    fn from(session_layout: proto::SessionLayout) -> Self {
        Self {
            session_id: session_layout.session_id.0,
            name: session_layout.name,
            revision: session_layout.revision,
            active_tab: session_layout.active_tab.map(|t| t.0),
            tabs: session_layout.tabs.into_iter().map(Into::into).collect(),
        }
    }
}

/// A line of the session list.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SessionSummary {
    pub session_id: u64,
    pub name: String,
    pub tabs: u32,
    /// Panes across all tabs.
    pub panes: u32,
    /// Attached clients.
    pub clients: u32,
}

impl From<proto::SessionSummary> for SessionSummary {
    fn from(session_summary: proto::SessionSummary) -> Self {
        Self {
            session_id: session_summary.session_id.0,
            name: session_summary.name,
            tabs: session_summary.tabs,
            panes: session_summary.panes,
            clients: session_summary.clients,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AgentKind {
    Claude,
    Codex,
}

impl From<AgentKind> for proto::AgentKind {
    fn from(agent_kind: AgentKind) -> Self {
        match agent_kind {
            AgentKind::Claude => Self::Claude,
            AgentKind::Codex => Self::Codex,
        }
    }
}

/// What a new pane runs.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PaneLaunch {
    Shell {
        /// Working directory; `nil` inherits from the split pane.
        cwd: Option<String>,
    },
    /// A program, run through the login shell.
    Command {
        argv: Vec<String>,
        cwd: Option<String>,
    },
    /// A coding agent with the daemon's launch recipe.
    Agent {
        agent: AgentKind,
        /// The agent's own session id to resume.
        resume: Option<String>,
        cwd: Option<String>,
    },
    /// A canvas pane (no process) showing a drawing or Excalidraw scene; `nil` has the daemon
    /// create a new Excalidraw scene (docs/DAEMON.md §7.2, §7.11). Which leaves are canvases
    /// comes from `ArtifactEvent.canvases`.
    Canvas { artifact_id: Option<u64> },
    /// A pane closed earlier on this daemon, back: its agent resumes its session, else a
    /// shell in its last directory, else `cwd` (needs `DaemonInfo.reopen` and the owner).
    Reopen {
        pane_id: u64,
        /// Where to start when the daemon kept no directory for it.
        cwd: Option<String>,
    },
}

impl From<PaneLaunch> for proto::PaneLaunch {
    fn from(pane_launch: PaneLaunch) -> Self {
        match pane_launch {
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
        pane_id: u64,
        axis: Axis,
        launch: PaneLaunch,
    },
    /// Closes a pane (and its tab, if it was the last one).
    ClosePane {
        pane_id: u64,
    },
    Focus {
        pane_id: u64,
    },
    /// Moves a tab's focus to the nearest pane in `direction`.
    FocusDirection {
        tab_id: u64,
        direction: Direction,
    },
    /// Grows (positive) or shrinks a pane along `axis` by moving its nearest divider.
    Resize {
        pane_id: u64,
        axis: Axis,
        /// Change of the pane's share.
        delta: f32,
    },
    /// Zooms a pane to fill its tab, or unzooms it.
    ToggleZoom {
        pane_id: u64,
    },
    /// Appends a tab with one pane and selects it.
    NewTab {
        session_id: u64,
        /// Name, empty for the default.
        name: String,
        launch: PaneLaunch,
    },
    CloseTab {
        tab_id: u64,
    },
    /// Moves a tab to `index` (clamped).
    MoveTab {
        tab_id: u64,
        index: u32,
    },
    SelectTab {
        tab_id: u64,
    },
    RenameTab {
        tab_id: u64,
        name: String,
    },
    /// Renames a session (fails if the name is taken).
    RenameSession {
        session_id: u64,
        name: String,
    },
    CreateSession {
        name: String,
        launch: PaneLaunch,
    },
    CloseSession {
        session_id: u64,
    },
    /// Moves a pane into a new tab after its own (daemons with `pane_moves`).
    BreakPane {
        pane_id: u64,
    },
    /// Moves a pane beside `target` on `side` (daemons with `pane_moves`).
    MovePane {
        pane_id: u64,
        /// The pane it goes beside.
        target: u64,
        /// Which side of `target`.
        side: Direction,
    },
    /// Moves a tab's panes beside `target` on `side`; the tab closes (daemons with
    /// `pane_moves`).
    MergeTab {
        tab_id: u64,
        /// The pane they go beside.
        target: u64,
        /// Which side of `target`.
        side: Direction,
    },
    /// Puts a tab in a project defined in its session (`PutProject` first), moves it within
    /// it by `rank`, or ungroups it with `nil` (daemons with `projects`).
    SetTabProject {
        tab_id: u64,
        /// The project, or `nil` to ungroup.
        project_id: Option<String>,
        /// Where the tab sorts within the project.
        rank: i64,
    },
    /// Defines or updates a project in a session; an older `updated_ms` than the daemon's
    /// copy is ignored (daemons with `projects`).
    PutProject {
        session_id: u64,
        project: DaemonProject,
    },
    /// Ungroups every tab of a project in a session and drops it (daemons with `projects`).
    RemoveProject {
        session_id: u64,
        project_id: String,
    },
    /// Opens a pane in a new floating window over `pane_id`'s tab (daemons with `floats`).
    NewFloat {
        /// A pane of the tab.
        pane_id: u64,
        launch: PaneLaunch,
        /// Where it sits; `nil` for a free spot.
        frame: Option<FloatFrame>,
        focus: bool,
        /// Closes itself once its run is done.
        close_when_done: bool,
    },
    /// Floats a tiled pane, tears a pane out of a shared window, or moves a one-pane window
    /// (daemons with `floats`).
    FloatPane {
        pane_id: u64,
        /// Where it sits; `nil` keeps it or picks a free spot.
        frame: Option<FloatFrame>,
    },
    /// Changes the window holding `pane_id`; `nil` fields stay (daemons with `floats`).
    SetFloat {
        /// A pane of the window.
        pane_id: u64,
        frame: Option<FloatFrame>,
        /// In the tray, or restored.
        minimized: Option<bool>,
        /// Shown over every tab.
        pinned: Option<bool>,
    },
    /// Docks the window holding `pane_id`, where it is or beside `target` on `side`
    /// (daemons with `floats`).
    DockPane {
        /// A pane of the window.
        pane_id: u64,
        /// The tiled pane it docks beside, or `nil` for its own place.
        target: Option<u64>,
        /// Which side of `target`.
        side: Direction,
    },
    /// Moves a pane along one whole edge of a tab's tiled panes (daemons with `floats`).
    MovePaneToEdge {
        pane_id: u64,
        tab_id: u64,
        side: Direction,
    },
}

/// Where a floating window sits, in fractions of its tab (`0,0` top left).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct FloatFrame {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl From<FloatFrame> for proto::FloatFrame {
    fn from(float_frame: FloatFrame) -> Self {
        Self {
            x: float_frame.x,
            y: float_frame.y,
            w: float_frame.w,
            h: float_frame.h,
        }
    }
}

impl From<proto::FloatFrame> for FloatFrame {
    fn from(float_frame: proto::FloatFrame) -> Self {
        Self {
            x: float_frame.x,
            y: float_frame.y,
            w: float_frame.w,
            h: float_frame.h,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DaemonFloat {
    /// The window, unique within its session.
    pub id: u64,
    /// Its panes, a subtree of the tab's tree.
    pub panes: Vec<u64>,
    pub frame: FloatFrame,
    /// Stacking order; higher is in front.
    pub z: u32,
    /// In the tray.
    pub minimized: bool,
    /// Shown over every tab of the session.
    pub pinned: bool,
    /// Closes itself once its run is done.
    pub close_when_done: bool,
}

/// A session's floating windows, back to front.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DaemonFloats {
    pub session_id: u64,
    /// The session layout revision these belong to.
    pub revision: u64,
    pub floats: Vec<DaemonFloat>,
}

impl From<proto::SessionFloats> for DaemonFloats {
    fn from(session_floats: proto::SessionFloats) -> Self {
        Self {
            session_id: session_floats.session_id.0,
            revision: session_floats.revision,
            floats: session_floats
                .floats
                .into_iter()
                .map(|window| DaemonFloat {
                    id: window.id.0,
                    panes: window.panes.into_iter().map(|pane| pane.0).collect(),
                    frame: window.frame.into(),
                    z: window.z,
                    minimized: window.minimized,
                    pinned: window.pinned,
                    close_when_done: window.close == proto::CloseWhen::Done,
                })
                .collect(),
        }
    }
}

impl From<LayoutOp> for proto::LayoutOp {
    fn from(layout_op: LayoutOp) -> Self {
        use proto::{PaneId, SessionId, TabId};
        match layout_op {
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
            LayoutOp::NewFloat {
                pane_id,
                launch,
                frame,
                focus,
                close_when_done,
            } => Self::NewFloat {
                pane_id: PaneId(pane_id),
                launch: launch.into(),
                frame: frame.map(Into::into),
                focus,
                close: if close_when_done {
                    proto::CloseWhen::Done
                } else {
                    proto::CloseWhen::Never
                },
            },
            LayoutOp::FloatPane { pane_id, frame } => Self::FloatPane {
                pane_id: PaneId(pane_id),
                frame: frame.map(Into::into),
            },
            LayoutOp::SetFloat {
                pane_id,
                frame,
                minimized,
                pinned,
            } => Self::SetFloat {
                pane_id: PaneId(pane_id),
                frame: frame.map(Into::into),
                minimized,
                pinned,
            },
            LayoutOp::DockPane {
                pane_id,
                target,
                side,
            } => Self::DockPane {
                pane_id: PaneId(pane_id),
                beside: target.map(|target| proto::DockTarget {
                    pane_id: PaneId(target),
                    side: side.into(),
                }),
            },
            LayoutOp::MovePaneToEdge {
                pane_id,
                tab_id,
                side,
            } => Self::MovePaneToEdge {
                pane_id: PaneId(pane_id),
                tab_id: TabId(tab_id),
                side: side.into(),
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
    fn from(project: proto::Project) -> Self {
        Self {
            id: project.id,
            name: project.name,
            color: project.color,
            order: project.order,
            updated_ms: project.updated.0,
        }
    }
}

impl From<DaemonProject> for proto::Project {
    fn from(daemon_project: DaemonProject) -> Self {
        Self {
            id: daemon_project.id,
            name: daemon_project.name,
            color: daemon_project.color,
            order: daemon_project.order,
            updated: proto::UnixMillis(daemon_project.updated_ms),
        }
    }
}

/// One tab's membership in a project.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DaemonTabProject {
    pub tab_id: u64,
    pub project_id: String,
    /// Where the tab sorts within the project.
    pub rank: i64,
}

/// A session's projects, as far as the connection sees.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DaemonProjects {
    pub session_id: u64,
    /// The session layout revision these belong to.
    pub revision: u64,
    /// Definitions of the projects `tabs` use.
    pub projects: Vec<DaemonProject>,
    pub tabs: Vec<DaemonTabProject>,
}

impl From<proto::SessionProjects> for DaemonProjects {
    fn from(session_projects: proto::SessionProjects) -> Self {
        Self {
            session_id: session_projects.session_id.0,
            revision: session_projects.revision,
            projects: session_projects
                .projects
                .into_iter()
                .map(Into::into)
                .collect(),
            tabs: session_projects
                .tabs
                .into_iter()
                .map(|membership| DaemonTabProject {
                    tab_id: membership.tab_id.0,
                    project_id: membership.project,
                    rank: membership.rank,
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum OpErrorCode {
    /// A referenced session, tab or pane does not exist.
    NotFound,
    /// The session name is taken.
    NameTaken,
    /// The process could not be started.
    SpawnFailed,
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

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum OpOutcome {
    /// Applied; nothing created.
    Done,
    PaneCreated {
        pane_id: u64,
    },
    TabCreated {
        tab_id: u64,
        pane_id: u64,
    },
    SessionCreated {
        session_id: u64,
        tab_id: u64,
        pane_id: u64,
    },
    Failed {
        code: OpErrorCode,
        message: String,
    },
}

impl From<proto::OpOutcome> for OpOutcome {
    fn from(op_outcome: proto::OpOutcome) -> Self {
        match op_outcome {
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
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AgentState {
    /// Waiting for a prompt.
    Idle,
    Running,
    Blocked {
        /// Answer with [`DaemonClient::decide`](crate::DaemonClient::decide).
        request_id: u64,
        summary: String,
        options: Vec<DecisionOption>,
    },
    Done,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AgentStatus {
    /// `claude`, `codex`, …
    pub kind: String,
    pub state: AgentState,
}

impl From<proto::AgentStatus> for AgentStatus {
    fn from(agent_status: proto::AgentStatus) -> Self {
        Self {
            kind: agent_status.kind,
            state: match agent_status.state {
                proto::AgentState::Idle => AgentState::Idle,
                proto::AgentState::Running => AgentState::Running,
                proto::AgentState::Done => AgentState::Done,
                proto::AgentState::Blocked(blocked) => AgentState::Blocked {
                    request_id: blocked.request_id.0,
                    summary: blocked.summary,
                    options: blocked
                        .options
                        .into_iter()
                        .map(|option| DecisionOption {
                            id: option.id.0,
                            label: option.label,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ProgramState {
    Idle,
    Working,
    /// Finished work not looked at yet.
    Done,
    Blocked,
    Error,
}

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
    fn from(program_report: proto::ProgramReport) -> Self {
        Self {
            state: match program_report.state {
                proto::ProgramState::Idle => ProgramState::Idle,
                proto::ProgramState::Working => ProgramState::Working,
                proto::ProgramState::Done => ProgramState::Done,
                proto::ProgramState::Blocked => ProgramState::Blocked,
                proto::ProgramState::Error => ProgramState::Error,
            },
            kind: program_report.kind.map(|kind| match kind {
                proto::ProgramKind::Permission => ProgramKind::Permission,
                proto::ProgramKind::Question => ProgramKind::Question,
                proto::ProgramKind::Auth => ProgramKind::Auth,
            }),
            app: program_report.app,
            message: program_report.message,
            progress: program_report.progress,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PaneActivity {
    Active,
    Inactive,
}

impl From<PaneActivity> for proto::PaneActivity {
    fn from(activity: PaneActivity) -> Self {
        match activity {
            PaneActivity::Active => Self::Active,
            PaneActivity::Inactive => Self::Inactive,
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
    Fixed {
        cols: u16,
        rows: u16,
    },
    /// The smallest active driving client's.
    Smallest,
    LastActive,
}

impl From<SizePolicy> for proto::SizePolicy {
    fn from(policy: SizePolicy) -> Self {
        match policy {
            SizePolicy::FollowLease => Self::FollowLease,
            SizePolicy::LastInput => Self::LastInput,
            SizePolicy::Fixed { cols, rows } => Self::Fixed { cols, rows },
            SizePolicy::Smallest => Self::Smallest,
            SizePolicy::LastActive => Self::LastActive,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PaneSizing {
    pub pane_id: u64,
    pub peer: Option<u64>,
}

impl From<proto::PaneSizing> for PaneSizing {
    fn from(state: proto::PaneSizing) -> Self {
        Self {
            pane_id: state.pane_id.0,
            peer: state.peer.map(|peer| peer.0),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PaneMeta {
    pub pane_id: u64,
    /// Title (OSC 0/2).
    pub title: String,
    /// Working directory (OSC 7).
    pub cwd: Option<String>,
    /// Exit status once the process ended.
    pub exit: Option<i32>,
    pub agent: Option<AgentStatus>,
    pub size: PaneSize,
    pub size_policy: SizePolicy,
    /// The principal whose size it has (16 bytes), if any.
    pub sized_by: Option<Vec<u8>>,
}

impl From<proto::PaneMeta> for PaneMeta {
    fn from(pane_meta: proto::PaneMeta) -> Self {
        Self {
            pane_id: pane_meta.pane_id.0,
            title: pane_meta.title,
            cwd: pane_meta.cwd,
            exit: pane_meta.exit,
            agent: pane_meta.agent.map(Into::into),
            size: pane_meta.size.into(),
            size_policy: match pane_meta.size_policy {
                proto::SizePolicy::FollowLease => SizePolicy::FollowLease,
                proto::SizePolicy::LastInput => SizePolicy::LastInput,
                proto::SizePolicy::Fixed { cols, rows } => SizePolicy::Fixed { cols, rows },
                proto::SizePolicy::Smallest => SizePolicy::Smallest,
                proto::SizePolicy::LastActive => SizePolicy::LastActive,
            },
            sized_by: pane_meta.sized_by.map(|principal| principal.0.to_vec()),
        }
    }
}

/// Whether local echo prediction may run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Prediction {
    Allow,
    /// Hidden input (password prompt): never predict.
    HiddenInput,
    /// Full-screen program: never predict.
    AltScreen,
    /// Raw mode outside a shell prompt: don't predict.
    RawOutsidePrompt,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct EchoHint {
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
    pub prediction: Prediction,
}

impl From<proto::EchoHintAt> for EchoHint {
    fn from(echo_hint_at: proto::EchoHintAt) -> Self {
        Self {
            pane_id: echo_hint_at.hint.pane_id.0,
            echo: echo_hint_at.hint.echo,
            icanon: echo_hint_at.hint.icanon,
            alt_screen: echo_hint_at.hint.alt_screen,
            at_prompt: echo_hint_at.hint.at_prompt,
            at_seq: echo_hint_at.at_seq.0,
            prediction: match echo_hint_at.prediction {
                proto::Prediction::Allow => Prediction::Allow,
                proto::Prediction::HiddenInput => Prediction::HiddenInput,
                proto::Prediction::AltScreen => Prediction::AltScreen,
                proto::Prediction::RawOutsidePrompt => Prediction::RawOutsidePrompt,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct CommandEnd {
    /// Exit status, if the shell reported one.
    pub exit: Option<i32>,
    pub duration_ms: u64,
}

/// A shell-integration command (OSC 133).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommandMark {
    pub pane_id: u64,
    /// Per-pane id.
    pub command_id: u64,
    /// The command line, if known.
    pub command: Option<String>,
    pub cwd: Option<String>,
    /// Start, Unix milliseconds.
    pub started_at_ms: u64,
    /// Output offset of the mark.
    pub at_seq: u64,
    /// Set once finished.
    pub finished: Option<CommandEnd>,
}

impl From<proto::CommandMark> for CommandMark {
    fn from(command_mark: proto::CommandMark) -> Self {
        Self {
            pane_id: command_mark.pane_id.0,
            command_id: command_mark.command_id,
            command: command_mark.command,
            cwd: command_mark.cwd,
            started_at_ms: command_mark.started_at.0,
            at_seq: command_mark.at_seq.0,
            finished: command_mark.finished.map(|end| CommandEnd {
                exit: end.exit,
                duration_ms: end.duration_ms,
            }),
        }
    }
}

/// A command with its screen rows (row 0 = oldest retained row).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommandInfo {
    pub mark: CommandMark,
    pub prompt_row: Option<u64>,
    pub output_row: Option<u64>,
    /// Row after the output.
    pub end_row: Option<u64>,
}

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
    fn from(command_list: proto::CommandList) -> Self {
        Self {
            at_seq: command_list.at_seq.0,
            total_rows: command_list.total_rows,
            commands: command_list
                .commands
                .into_iter()
                .map(|command| CommandInfo {
                    mark: command.mark.into(),
                    prompt_row: command.rows.prompt,
                    output_row: command.rows.output,
                    end_row: command.rows.end,
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommandOutput {
    pub mark: CommandMark,
    /// Output, soft wraps joined.
    pub text: String,
    /// Cut to the last 2 MiB.
    pub truncated: bool,
}

impl From<proto::CommandOutput> for CommandOutput {
    fn from(command_output: proto::CommandOutput) -> Self {
        Self {
            mark: command_output.mark.into(),
            text: command_output.text,
            truncated: command_output.truncated,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SearchMode {
    Plain,
    /// Rust `regex` syntax.
    Regex,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CaseMode {
    Sensitive,
    Insensitive,
    /// Sensitive only if the pattern has an uppercase letter.
    Smart,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SearchQuery {
    pub pattern: String,
    pub mode: SearchMode,
    pub case: CaseMode,
}

impl From<SearchQuery> for proto::SearchQuery {
    fn from(search_query: SearchQuery) -> Self {
        Self {
            pattern: search_query.pattern,
            mode: match search_query.mode {
                SearchMode::Plain => proto::SearchMode::Plain,
                SearchMode::Regex => proto::SearchMode::Regex,
            },
            case: match search_query.case {
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
    pub row: u64,
    pub col: u16,
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
    pub total: u32,
    pub matches: Vec<SearchMatch>,
    /// Cursor for the next page.
    pub next: Option<u32>,
}

impl From<proto::SearchPage> for SearchPage {
    fn from(search_page: proto::SearchPage) -> Self {
        Self {
            at_seq: search_page.at_seq.0,
            total_rows: search_page.total_rows,
            total: search_page.total,
            matches: search_page
                .matches
                .into_iter()
                .map(|found| SearchMatch {
                    row: found.row,
                    col: found.col,
                    end_row: found.end_row,
                    end_col: found.end_col,
                    line: found.line,
                })
                .collect(),
            next: search_page.next,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkKind {
    /// OSC 8 hyperlink.
    Hyperlink,
    /// A URL in the text.
    Url,
    Path,
}

/// Where a link was found.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LinkSource {
    Screen,
    Command { command_id: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Link {
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
    fn from(found: proto::Links) -> Self {
        Self {
            cwd: found.cwd,
            links: found
                .links
                .into_iter()
                .map(|link| Link {
                    kind: match link.kind {
                        proto::LinkKind::Hyperlink => LinkKind::Hyperlink,
                        proto::LinkKind::Url => LinkKind::Url,
                        proto::LinkKind::Path => LinkKind::Path,
                    },
                    text: link.text,
                    target: link.target,
                    line: link.line,
                    column: link.column,
                    exists: link.exists,
                    source: match link.source {
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
    UnknownPane,
    /// The request was invalid (e.g. a bad regex).
    BadRequest {
        message: String,
    },
    /// Nothing to return (e.g. no finished command).
    NotFound,
    Internal {
        message: String,
    },
}

impl From<proto::RpcError> for RpcError {
    fn from(rpc_error: proto::RpcError) -> Self {
        match rpc_error {
            proto::RpcError::UnknownPane => Self::UnknownPane,
            proto::RpcError::BadRequest(message) => Self::BadRequest { message },
            proto::RpcError::NotFound => Self::NotFound,
            proto::RpcError::Internal(message) => Self::Internal { message },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum KeyAction {
    Press,
    Repeat,
    Release,
}

impl From<KeyAction> for proto::KeyAction {
    fn from(key_action: KeyAction) -> Self {
        match key_action {
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
    pub mods: u16,
    /// Modifiers consumed to produce `text`.
    #[uniffi(default = 0)]
    pub consumed_mods: u16,
    pub action: KeyAction,
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
    fn from(key_event: KeyEvent) -> Self {
        Self {
            key: key_event.key,
            mods: key_event.mods,
            consumed_mods: key_event.consumed_mods,
            action: key_event.action.into(),
            text: key_event.text,
            unshifted_codepoint: key_event.unshifted_codepoint,
            composing: key_event.composing,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MouseAction {
    Press,
    Release,
    Motion,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MouseButton {
    /// None (motion).
    None,
    Left,
    Middle,
    Right,
    WheelUp,
    WheelDown,
    WheelLeft,
    WheelRight,
}

/// A mouse event in cell coordinates; the daemon encodes it for the program's tracking
/// mode and drops it if the program does not track the mouse.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct MouseEvent {
    pub action: MouseAction,
    pub button: MouseButton,
    pub col: u16,
    pub row: u16,
    #[uniffi(default = 0)]
    pub mods: u16,
}

impl From<MouseEvent> for proto::MouseEvent {
    fn from(mouse_event: MouseEvent) -> Self {
        Self {
            action: match mouse_event.action {
                MouseAction::Press => proto::MouseAction::Press,
                MouseAction::Release => proto::MouseAction::Release,
                MouseAction::Motion => proto::MouseAction::Motion,
            },
            button: match mouse_event.button {
                MouseButton::None => proto::MouseButton::None,
                MouseButton::Left => proto::MouseButton::Left,
                MouseButton::Middle => proto::MouseButton::Middle,
                MouseButton::Right => proto::MouseButton::Right,
                MouseButton::WheelUp => proto::MouseButton::WheelUp,
                MouseButton::WheelDown => proto::MouseButton::WheelDown,
                MouseButton::WheelLeft => proto::MouseButton::WheelLeft,
                MouseButton::WheelRight => proto::MouseButton::WheelRight,
            },
            col: mouse_event.col,
            row: mouse_event.row,
            mods: mouse_event.mods,
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
