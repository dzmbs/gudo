//! The git-native workspace: which repository, worktree and branch every pane is in, how far
//! each worktree is from `HEAD` and its upstream, its GitHub pull request (through the host's
//! own `gh` CLI), the worktree lifecycle (tasks, archive and restore, auto-delete once merged)
//! and repository scripts.
//!
//! Clients that announce [`Caps::REPO_STATUS`](crate::Caps::REPO_STATUS) get the whole
//! picture as [`ServerCtl::Repos`](crate::ServerCtl::Repos) right after they attach and again
//! whenever it changes (debounced). The daemon only watches and refreshes while at least one
//! such client is connected. Requests are [`WorkspaceRequest`](crate::WorkspaceRequest)
//! variants; see each type.
//!
//! The app never sees a GitHub token: the daemon runs `gh` as the user on the host, and
//! [`GhStatus`] says when `gh` is missing or not signed in.
//!
//! Same compatibility rules as the rest of the crate: append only.

use serde::{Deserialize, Serialize};

use crate::ids::{PaneId, SessionId, TabId, UnixMillis};
use crate::layout::AgentKind;
use crate::workspace::WorktreeInfo;

/// Everything the sidebar needs about the host's repositories, sent whole.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepoSnapshot {
    /// Increases with every snapshot the daemon builds.
    pub rev: u64,
    /// Each pane inside a git worktree and that worktree (a pane outside any repository is
    /// left out).
    pub panes: Vec<PaneRepo>,
    /// Every worktree of every repository a pane is in, panes or not, ordered by repository
    /// and then main worktree first.
    pub worktrees: Vec<WorktreeState>,
    /// Whether pull requests can be read on this host.
    pub gh: GhStatus,
}

/// A pane and the worktree its working directory is in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneRepo {
    /// The pane.
    pub pane_id: PaneId,
    /// [`WorktreeState::path`] of its worktree.
    pub worktree: String,
}

/// One worktree as the sidebar shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorktreeState {
    /// Top level of the worktree.
    pub path: String,
    /// The repository: top level of its main worktree. Group by this.
    pub repo: String,
    /// The repository's name (the main worktree's directory name).
    pub repo_name: String,
    /// The worktree's own name (its directory name).
    pub name: String,
    /// The repository's main worktree.
    pub main: bool,
    /// Checked-out branch; `None` when detached.
    pub branch: Option<String>,
    /// `HEAD` commit; `None` in a repository with no commits.
    pub head: Option<String>,
    /// Upstream branch, if set.
    pub upstream: Option<String>,
    /// Commits ahead of the upstream.
    pub ahead: u32,
    /// Commits behind the upstream.
    pub behind: u32,
    /// Lines added since `HEAD` (staged, unstaged and untracked files).
    pub added: u32,
    /// Lines removed since `HEAD`.
    pub removed: u32,
    /// Changed, unmerged and untracked paths.
    pub changed_files: u32,
    /// Has uncommitted changes or untracked files.
    pub dirty: bool,
    /// The branch's pull request, if `gh` found one.
    pub pr: Option<PullRequest>,
    /// Scripts from the worktree's `.<product>.json`.
    pub scripts: Vec<RepoScript>,
    /// The setup and teardown commands from the same file.
    pub hooks: RepoHooks,
    /// The daemon created this worktree (New Task, Checkout PR), so it may auto-delete it
    /// once merged.
    pub managed: bool,
    /// When the daemon first saw its pull request merged (the auto-delete clock).
    pub merged_at: Option<UnixMillis>,
    /// When its git state was last read.
    pub updated_at: UnixMillis,
}

/// A pull request as `gh pr view --json …` reports it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PullRequest {
    /// Its number.
    pub number: u32,
    /// Its title.
    pub title: String,
    /// Open, closed or merged.
    pub state: PrState,
    /// A draft.
    pub draft: bool,
    /// The web page.
    pub url: String,
    /// The head branch.
    pub head_ref: String,
    /// Lines added.
    pub additions: u32,
    /// Lines removed.
    pub deletions: u32,
    /// Whether it can be merged now.
    pub merge_state: MergeState,
    /// Checks and commit statuses on the head commit.
    pub checks: Vec<PrCheck>,
    /// When `gh` was asked.
    pub fetched_at: UnixMillis,
}

/// A pull request's state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PrState {
    /// Open.
    Open,
    /// Closed without merging.
    Closed,
    /// Merged.
    Merged,
}

/// GitHub's `mergeStateStatus`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MergeState {
    /// Mergeable, checks passing.
    Clean,
    /// Mergeable, but a check that is not required failed.
    Unstable,
    /// Mergeable with passing checks and pre-receive hooks.
    HasHooks,
    /// The head branch is behind the base and must be updated first.
    Behind,
    /// Blocked by required reviews or checks.
    Blocked,
    /// Merge conflicts.
    Dirty,
    /// A draft cannot be merged.
    Draft,
    /// GitHub has not computed it yet.
    Unknown,
}

impl MergeState {
    /// `gh pr merge` can merge now (possibly with a failed optional check).
    pub fn mergeable(self) -> bool {
        matches!(self, Self::Clean | Self::Unstable | Self::HasHooks)
    }
}

/// One check run or commit status.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrCheck {
    /// The check's name (or the status context).
    pub name: String,
    /// Where it stands.
    pub status: CheckStatus,
    /// Its page (details URL or target URL).
    pub url: Option<String>,
    /// The Actions workflow it belongs to, if any.
    pub workflow: Option<String>,
}

/// Where a check stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CheckStatus {
    /// Queued or running.
    Pending,
    /// Passed.
    Success,
    /// Failed, errored or timed out.
    Failure,
    /// Finished without a verdict (neutral).
    Neutral,
    /// Skipped.
    Skipped,
    /// Cancelled.
    Cancelled,
}

/// Whether the host's `gh` can read pull requests.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum GhStatus {
    /// Not checked yet (no worktree with a branch seen).
    Unknown,
    /// `gh` is installed and signed in.
    Ready {
        /// The signed-in account, if `gh` said.
        account: Option<String>,
    },
    /// `gh` is not installed (or not on the daemon's `PATH`).
    Missing,
    /// `gh` is installed but not signed in (`gh auth login`).
    NotAuthenticated {
        /// What `gh auth status` said.
        message: String,
    },
}

/// A named command for a repository (or global, kept by the app), run in its own tab.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepoScript {
    /// Menu title.
    pub name: String,
    /// Shell command line, run with the user's shell in the worktree.
    pub command: String,
    /// SF Symbol name.
    pub icon: Option<String>,
    /// Tint name (`green`, `blue`, …) or `#RRGGBB`.
    pub tint: Option<String>,
    /// The one ⌘R runs.
    pub default: bool,
}

/// Commands run around a worktree's life.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepoHooks {
    /// Run in the first pane of a new task's worktree, before the shell or agent.
    pub setup: Option<String>,
    /// Run in the worktree before it is archived or deleted.
    pub teardown: Option<String>,
}

/// How a pull request is merged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MergeStrategy {
    /// A merge commit (`--merge`).
    Merge,
    /// One squashed commit (`--squash`).
    Squash,
    /// Rebased commits (`--rebase`).
    Rebase,
}

/// Merges a worktree's pull request (`gh pr merge`) → [`WorkspaceResponse::Pr`](crate::WorkspaceResponse::Pr).
/// Refused with `Conflict` unless its [`MergeState`] is mergeable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrMerge {
    /// The worktree.
    pub path: String,
    /// The pull request the user confirmed; refused if the branch's is another one now.
    pub number: u32,
    /// How.
    pub strategy: MergeStrategy,
}

/// Pushes the branch and opens a pull request (`git push -u`, `gh pr create --fill`) →
/// [`WorkspaceResponse::Pr`](crate::WorkspaceResponse::Pr).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrCreate {
    /// The worktree.
    pub path: String,
    /// Open it as a draft.
    pub draft: bool,
    /// Base branch; the repository's default when `None`.
    pub base: Option<String>,
}

/// Checks a pull request out into a new worktree → [`WorkspaceResponse::Worktree`](crate::WorkspaceResponse::Worktree).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrCheckout {
    /// Any directory inside the repository.
    pub repo: String,
    /// The pull request.
    pub number: u32,
}

/// A worktree that was archived: its directory is gone, its commits are kept under a ref.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArchivedWorktree {
    /// Id for [`WorkspaceRequest::WorktreeRestore`](crate::WorkspaceRequest::WorktreeRestore).
    pub id: u64,
    /// The repository (main worktree).
    pub repo: String,
    /// The repository's name.
    pub repo_name: String,
    /// Where the worktree was (and is restored to).
    pub path: String,
    /// Its branch; `None` if it was detached.
    pub branch: Option<String>,
    /// The commit it was at.
    pub head: Option<String>,
    /// Uncommitted changes were saved with it and come back on restore.
    pub saved_changes: bool,
    /// When.
    pub archived_at: UnixMillis,
}

/// The daemon's worktree housekeeping.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorktreeSettings {
    /// Delete worktrees the daemon created this many days after their pull request merged;
    /// 0 never. A worktree with uncommitted changes is never deleted this way.
    pub auto_delete_merged_days: u32,
}

/// A new task: a worktree on a new branch, with a tab running a shell or an agent in it →
/// [`WorkspaceResponse::TaskCreated`](crate::WorkspaceResponse::TaskCreated). The repository's
/// setup command runs first in that tab.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskCreate {
    /// Any directory inside the repository.
    pub repo: String,
    /// The session the tab opens in.
    pub session_id: SessionId,
    /// The tab's name (and the worktree's directory name).
    pub name: String,
    /// New branch; derived from `name` when `None`.
    pub branch: Option<String>,
    /// Commit or branch to start from; `HEAD` when `None`.
    pub base: Option<String>,
    /// Agent to start; `None` opens a shell.
    pub agent: Option<AgentKind>,
}

/// What [`TaskCreate`] made.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskCreated {
    /// The worktree.
    pub worktree: WorktreeInfo,
    /// The new tab.
    pub tab_id: TabId,
    /// Its pane.
    pub pane_id: PaneId,
    /// The setup command that runs first, if the repository has one.
    pub setup: Option<String>,
}

/// Runs a script in a new tab of `session_id` → [`WorkspaceResponse::PaneCreated`](crate::WorkspaceResponse::PaneCreated).
/// The tab stays open as a shell when the command ends.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScriptRun {
    /// Working directory (a worktree).
    pub cwd: String,
    /// The session.
    pub session_id: SessionId,
    /// Tab name.
    pub name: String,
    /// Shell command line.
    pub command: String,
}
