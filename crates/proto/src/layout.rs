//! Sessions, tabs and split trees: the layout model shared with the Apple client.
//!
//! A daemon holds many named [sessions](SessionLayout). A session holds an ordered list of
//! [tabs](TabLayout); each tab is a binary split tree of panes ([`LayoutNode`]) with one
//! focused pane and optionally one zoomed pane. The daemon is the source of truth: clients send
//! [`LayoutOp`]s and every attached client receives the whole [`SessionLayout`] again in
//! [`ServerCtl::LayoutChanged`](crate::ServerCtl::LayoutChanged), stamped with a revision.
//!
//! Geometry conventions (the Swift client uses the same ones):
//!
//! - [`Axis::Horizontal`] lays children out left to right, [`Axis::Vertical`] top to bottom.
//! - `ratio` is the first child's share of the split, in `0..1`.
//! - Splitting a pane puts the new pane *after* it (right of it, or below it).

use serde::{Deserialize, Serialize};

use crate::ids::{PaneId, SessionId, TabId};

/// The direction in which a split arranges its two children.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Axis {
    /// Side by side: `first` on the left, `second` on the right.
    Horizontal,
    /// Stacked: `first` on top, `second` below.
    Vertical,
}

/// A direction for moving focus between panes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
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

/// A node of a tab's split tree.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum LayoutNode {
    /// A single pane.
    Leaf(PaneId),
    /// Two subtrees sharing the space along `axis`.
    Split {
        /// How the children are arranged.
        axis: Axis,
        /// The first child's share of the space, strictly between 0 and 1.
        ratio: f32,
        /// Left or top child.
        first: Box<LayoutNode>,
        /// Right or bottom child.
        second: Box<LayoutNode>,
    },
}

/// One tab of a session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TabLayout {
    /// The tab.
    pub tab_id: TabId,
    /// User-visible name; empty means "derive from the focused pane's title".
    pub name: String,
    /// The split tree.
    pub root: LayoutNode,
    /// The pane with keyboard focus. Always a leaf of `root`.
    pub focused: PaneId,
    /// The pane shown full-tab, if any. Always a leaf of `root`.
    pub zoomed: Option<PaneId>,
}

/// The full layout of one session, sent whole on every change.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionLayout {
    /// The session.
    pub session_id: SessionId,
    /// Session name, unique per daemon.
    pub name: String,
    /// Bumped on every structural change; unchanged on a no-op. A client that sees a revision
    /// lower than one it already applied drops the message.
    pub revision: u64,
    /// The tab on screen, if the session has any tabs.
    pub active_tab: Option<TabId>,
    /// Tabs in display order.
    pub tabs: Vec<TabLayout>,
}

/// A line in the session list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionSummary {
    /// The session.
    pub session_id: SessionId,
    /// Its name.
    pub name: String,
    /// Number of tabs.
    pub tabs: u32,
    /// Number of panes across all tabs.
    pub panes: u32,
    /// Clients currently attached to it.
    pub clients: u32,
}

/// Which coding agent to launch in a pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum AgentKind {
    /// Anthropic Claude Code.
    Claude,
    /// OpenAI Codex CLI.
    Codex,
}

/// What a new pane runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum PaneLaunch {
    /// The user's login shell.
    Shell {
        /// Working directory; `None` inherits from the pane being split, else `$HOME`.
        cwd: Option<String>,
    },
    /// A program, run through the user's login shell so `PATH` matches an interactive one.
    Command {
        /// Program and arguments.
        argv: Vec<String>,
        /// Working directory, as for `Shell`.
        cwd: Option<String>,
    },
    /// A coding agent, launched with the daemon's adapter recipe (hooks, status reporting).
    Agent {
        /// Which agent.
        agent: AgentKind,
        /// The agent's own session id to resume, or `None` for a fresh session.
        resume: Option<String>,
        /// Working directory, as for `Shell`.
        cwd: Option<String>,
    },
}

/// A change to the layout, sent in [`ClientCtl::Op`](crate::ClientCtl::Op).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum LayoutOp {
    /// Splits `pane_id` along `axis`; the new pane goes after it and takes focus.
    Split {
        /// The pane to split.
        pane_id: PaneId,
        /// How the two panes are arranged.
        axis: Axis,
        /// What the new pane runs.
        launch: PaneLaunch,
    },
    /// Closes a pane, killing its process. Closing a tab's last pane closes the tab.
    ClosePane {
        /// The pane.
        pane_id: PaneId,
    },
    /// Focuses a pane (and selects its tab).
    Focus {
        /// The pane.
        pane_id: PaneId,
    },
    /// Moves a tab's focus to the nearest pane in `direction`. A no-op at the edge.
    FocusDirection {
        /// The tab.
        tab_id: TabId,
        /// Where to move.
        direction: Direction,
    },
    /// Grows (positive `delta`) or shrinks the pane along `axis`, by moving the divider of its
    /// nearest enclosing split on that axis. `delta` is in units of that split's size.
    Resize {
        /// The pane.
        pane_id: PaneId,
        /// Which dimension.
        axis: Axis,
        /// Change of the pane's share.
        delta: f32,
    },
    /// Zooms `pane_id` to fill its tab, or unzooms if it is already zoomed.
    ToggleZoom {
        /// The pane.
        pane_id: PaneId,
    },
    /// Appends a tab with one pane and selects it.
    NewTab {
        /// The session.
        session_id: SessionId,
        /// Tab name, empty for the default.
        name: String,
        /// What its pane runs.
        launch: PaneLaunch,
    },
    /// Closes a tab and every pane in it.
    CloseTab {
        /// The tab.
        tab_id: TabId,
    },
    /// Moves a tab to `index` in its session's tab order (clamped to the end).
    MoveTab {
        /// The tab.
        tab_id: TabId,
        /// New position.
        index: u32,
    },
    /// Shows a tab.
    SelectTab {
        /// The tab.
        tab_id: TabId,
    },
    /// Renames a tab.
    RenameTab {
        /// The tab.
        tab_id: TabId,
        /// New name.
        name: String,
    },
    /// Renames a session. Fails if another session has that name.
    RenameSession {
        /// The session.
        session_id: SessionId,
        /// New name.
        name: String,
    },
    /// Creates a session with one tab and one pane. Fails if the name is taken.
    CreateSession {
        /// Its name.
        name: String,
        /// What its first pane runs.
        launch: PaneLaunch,
    },
    /// Closes a session and every pane in it.
    CloseSession {
        /// The session.
        session_id: SessionId,
    },
}

/// The result of a [`LayoutOp`], in [`ServerCtl::OpResult`](crate::ServerCtl::OpResult).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum OpOutcome {
    /// Applied; nothing was created.
    Done,
    /// Applied; a pane was created (split).
    PaneCreated {
        /// The new pane.
        pane_id: PaneId,
    },
    /// Applied; a tab was created.
    TabCreated {
        /// The new tab.
        tab_id: TabId,
        /// Its pane.
        pane_id: PaneId,
    },
    /// Applied; a session was created.
    SessionCreated {
        /// The new session.
        session_id: SessionId,
        /// Its tab.
        tab_id: TabId,
        /// Its pane.
        pane_id: PaneId,
    },
    /// Not applied.
    Failed {
        /// Machine-readable reason.
        code: OpError,
        /// Human-readable detail.
        message: String,
    },
}

/// Why a [`LayoutOp`] failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum OpError {
    /// A referenced session, tab or pane does not exist (or is outside the grant's scope).
    NotFound,
    /// A session with that name already exists.
    NameTaken,
    /// The process could not be started.
    SpawnFailed,
    /// The arguments are invalid (for example a non-finite resize delta).
    Invalid,
    /// The grant's roles do not allow it.
    Forbidden,
}
