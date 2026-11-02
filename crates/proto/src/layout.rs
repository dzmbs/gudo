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

use crate::artifact::ArtifactId;
use crate::ids::{PaneId, SessionId, TabId};
use crate::project::Project;

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
    pub tab_id: TabId,
    /// User-visible name; empty means "derive from the focused pane's title".
    pub name: String,
    pub root: LayoutNode,
    /// The pane with keyboard focus. Always a leaf of `root`.
    pub focused: PaneId,
    /// The pane shown full-tab, if any. Always a leaf of `root`.
    pub zoomed: Option<PaneId>,
}

/// The full layout of one session, sent whole on every change.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionLayout {
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
    pub session_id: SessionId,
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
        agent: AgentKind,
        /// The agent's own session id to resume, or `None` for a fresh session.
        resume: Option<String>,
        /// Working directory, as for `Shell`.
        cwd: Option<String>,
    },
    /// A canvas pane showing a drawing (no process). `None` creates a new drawing in the
    /// session. Clients learn which leaves are canvases from
    /// [`ArtifactEvent::Canvases`](crate::ArtifactEvent::Canvases).
    Canvas {
        /// The drawing to show.
        artifact_id: Option<ArtifactId>,
    },
    /// Reopens a pane closed earlier on this daemon (a recently closed tab): its agent
    /// resumes its session when the daemon knew the session id, otherwise a shell starts in
    /// the pane's last directory, else `cwd`. An unknown pane is a shell in `cwd`. Needs the
    /// owner role and [`DaemonFeatures::REOPEN`](crate::DaemonFeatures::REOPEN).
    Reopen {
        /// The closed pane.
        pane_id: PaneId,
        /// Where to start when the daemon kept no directory for it.
        cwd: Option<String>,
    },
    /// A coding agent under one of the host's accounts (see [`crate::account`]); otherwise as
    /// `Agent`. Needs [`DaemonFeatures::ACCOUNTS`](crate::DaemonFeatures::ACCOUNTS). A resumed
    /// session always runs under the account that created it, whatever `account` says.
    AccountAgent {
        agent: AgentKind,
        /// The account ([`AgentAccount::id`](crate::AgentAccount::id)); `None` uses the
        /// tab's project default, else the host default.
        account: Option<String>,
        /// The agent's own session id to resume, or `None` for a fresh session.
        resume: Option<String>,
        /// Working directory, as for `Shell`.
        cwd: Option<String>,
    },
    /// The agent's own sign-in for an account (`claude auth login`, `codex login`) with only
    /// that account's directory in its environment, then a shell. The user completes it in
    /// the pane; the daemon checks the account when it ends. Owner only.
    AccountSignIn {
        agent: AgentKind,
        account: String,
        /// Codex: sign in with a device code (`codex login --device-auth`), for a host whose
        /// browser is not the user's. Claude prints a URL and takes a pasted code anyway.
        device_code: bool,
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
        pane_id: PaneId,
    },
    /// Focuses a pane (and selects its tab).
    Focus {
        pane_id: PaneId,
    },
    /// Moves a tab's focus to the nearest pane in `direction`. A no-op at the edge.
    FocusDirection {
        tab_id: TabId,
        direction: Direction,
    },
    /// Grows (positive `delta`) or shrinks the pane along `axis`, by moving the divider of its
    /// nearest enclosing split on that axis. `delta` is in units of that split's size.
    Resize {
        pane_id: PaneId,
        axis: Axis,
        /// Change of the pane's share.
        delta: f32,
    },
    /// Zooms `pane_id` to fill its tab, or unzooms if it is already zoomed.
    ToggleZoom {
        pane_id: PaneId,
    },
    /// Appends a tab with one pane and selects it.
    NewTab {
        session_id: SessionId,
        /// Tab name, empty for the default.
        name: String,
        /// What its pane runs.
        launch: PaneLaunch,
    },
    /// Closes a tab and every pane in it.
    CloseTab {
        tab_id: TabId,
    },
    /// Moves a tab to `index` in its session's tab order (clamped to the end).
    MoveTab {
        tab_id: TabId,
        /// New position.
        index: u32,
    },
    /// Shows a tab.
    SelectTab {
        tab_id: TabId,
    },
    RenameTab {
        tab_id: TabId,
        name: String,
    },
    /// Renames a session. Fails if another session has that name.
    RenameSession {
        session_id: SessionId,
        name: String,
    },
    /// Creates a session with one tab and one pane. Fails if the name is taken.
    CreateSession {
        name: String,
        /// What its first pane runs.
        launch: PaneLaunch,
    },
    /// Closes a session and every pane in it.
    CloseSession {
        session_id: SessionId,
    },
    /// Moves a pane out of its tab into a new tab right after it, focused and selected; the
    /// process keeps running. A tab's only pane cannot be moved out (`Invalid`). Only daemons
    /// with [`DaemonFeatures::PANE_MOVES`](crate::DaemonFeatures::PANE_MOVES) understand it.
    BreakPane {
        pane_id: PaneId,
    },
    /// Moves a pane beside `target` (in the same session), on `side` of it, focused; a tab
    /// left without panes closes. Needs
    /// [`DaemonFeatures::PANE_MOVES`](crate::DaemonFeatures::PANE_MOVES).
    MovePane {
        pane_id: PaneId,
        /// The pane it goes beside.
        target: PaneId,
        /// Which side of `target`.
        side: Direction,
    },
    /// Moves every pane of `tab_id` beside `target` (in another tab of the same session), on
    /// `side` of it, keeping their arrangement; `tab_id` closes. Needs
    /// [`DaemonFeatures::PANE_MOVES`](crate::DaemonFeatures::PANE_MOVES).
    MergeTab {
        /// The tab whose panes move.
        tab_id: TabId,
        /// The pane they go beside.
        target: PaneId,
        /// Which side of `target`.
        side: Direction,
    },
    /// Puts a tab in a project (or moves it within one by `rank`), or takes it out with
    /// `None`. The project must already be defined in the tab's session (`Invalid`
    /// otherwise). Needs [`DaemonFeatures::PROJECTS`](crate::DaemonFeatures::PROJECTS).
    SetTabProject {
        tab_id: TabId,
        /// The project's id, or `None` to ungroup.
        project: Option<String>,
        /// Where the tab sorts within the project.
        rank: i64,
    },
    /// Defines or updates a project in a session; ignored (`Done`) when the session's copy
    /// has a newer `updated`. Needs
    /// [`DaemonFeatures::PROJECTS`](crate::DaemonFeatures::PROJECTS).
    PutProject {
        session_id: SessionId,
        project: Project,
    },
    /// Ungroups every tab of a project in a session and drops its definition. Needs
    /// [`DaemonFeatures::PROJECTS`](crate::DaemonFeatures::PROJECTS).
    RemoveProject {
        session_id: SessionId,
        /// The project's id.
        project: String,
    },
    /// Opens a pane in a new floating window over `pane_id`'s tab. In the tree it goes right
    /// of the whole tab, where it docks to and where clients without floats show it. Answers
    /// `PaneCreated`. Needs [`DaemonFeatures::FLOATS`](crate::DaemonFeatures::FLOATS).
    NewFloat {
        /// The pane it opens beside.
        pane_id: PaneId,
        /// What it runs.
        launch: PaneLaunch,
        /// Where it sits; `None` for a free spot.
        frame: Option<crate::float::FloatFrame>,
        /// Whether it takes focus. Agents' floats never do.
        focus: bool,
        /// When the daemon closes it by itself.
        close: crate::float::CloseWhen,
    },
    /// Floats a tiled pane in a window of its own, raised in front; tears a pane out of a
    /// window it shares into one of its own; or moves a window that is only this pane to
    /// `frame`. A tab's last tiled pane stays (`Invalid`). Panes move into a window with
    /// [`MovePane`](LayoutOp::MovePane) beside one of its panes. Needs
    /// [`DaemonFeatures::FLOATS`](crate::DaemonFeatures::FLOATS).
    FloatPane {
        pane_id: PaneId,
        /// Where it sits; `None` keeps a float's frame or picks a free spot.
        frame: Option<crate::float::FloatFrame>,
    },
    /// Changes the floating window holding `pane_id`; `None` fields stay. Needs
    /// [`DaemonFeatures::FLOATS`](crate::DaemonFeatures::FLOATS).
    SetFloat {
        /// A pane of the window.
        pane_id: PaneId,
        frame: Option<crate::float::FloatFrame>,
        /// Shown as a chip, or restored (restoring raises it).
        minimized: Option<bool>,
        /// Shown over every tab of its session.
        pinned: Option<bool>,
    },
    /// Docks the floating window holding `pane_id` back into its tab's tree, keeping its
    /// splits: where it is, or beside a tiled pane of the same session (moving it into that
    /// pane's tab). Focuses `pane_id`. Needs
    /// [`DaemonFeatures::FLOATS`](crate::DaemonFeatures::FLOATS).
    DockPane {
        /// A pane of the window.
        pane_id: PaneId,
        /// Beside which pane, or `None` for its own place.
        beside: Option<crate::float::DockTarget>,
    },
    /// Moves a pane (out of a window too) along one whole edge of a tab's tiled panes,
    /// focused; a tab left without panes closes. Needs
    /// [`DaemonFeatures::FLOATS`](crate::DaemonFeatures::FLOATS).
    MovePaneToEdge {
        pane_id: PaneId,
        /// The tab (in the same session).
        tab_id: TabId,
        /// Which edge.
        side: Direction,
    },
}

/// The result of a [`LayoutOp`], in [`ServerCtl::OpResult`](crate::ServerCtl::OpResult).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum OpOutcome {
    /// Applied; nothing was created.
    Done,
    /// Applied; a pane was created (split).
    PaneCreated { pane_id: PaneId },
    /// Applied; a tab was created.
    TabCreated { tab_id: TabId, pane_id: PaneId },
    /// Applied; a session was created.
    SessionCreated {
        session_id: SessionId,
        tab_id: TabId,
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
