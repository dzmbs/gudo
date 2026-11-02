//! The git-native workspace on [`DaemonClient`] (`proto::repo`): the repository snapshot
//! pushed as [`WorkspaceEvent::Repos`](crate::ws_types::WorkspaceEvent::Repos), pull request
//! actions through the host's `gh`, archive and restore, housekeeping, new tasks and scripts.
//!
//! Same conventions as [`crate::ws_types`]: ids are `u64`, times are Unix milliseconds
//! (`*_ms`).

use std::time::Duration;

use client_core::proto;

use crate::client::DaemonClient;
use crate::types::AgentKind;
use crate::ws_types::{WorkspaceError, WorktreeInfo};

/// Everything the sidebar needs about the host's repositories.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RepoSnapshot {
    /// Increases with every snapshot.
    pub rev: u64,
    /// Each pane inside a worktree, and that worktree's path.
    pub panes: Vec<PaneRepo>,
    /// Every worktree of every repository a pane is in, by repository, main first.
    pub worktrees: Vec<WorktreeState>,
    /// Whether pull requests can be read on this host.
    pub gh: GhStatus,
}

/// A pane and its worktree.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PaneRepo {
    pub pane_id: u64,
    /// [`WorktreeState::path`].
    pub worktree: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorktreeState {
    /// Top level.
    pub path: String,
    /// The repository (its main worktree's path); group by this.
    pub repo: String,
    /// The repository's name.
    pub repo_name: String,
    /// The worktree's directory name.
    pub name: String,
    pub main: bool,
    /// Branch; `nil` when detached.
    pub branch: Option<String>,
    /// `HEAD`.
    pub head: Option<String>,
    pub upstream: Option<String>,
    /// Commits ahead of the upstream.
    pub ahead: u32,
    pub behind: u32,
    /// Lines added since `HEAD` (untracked files included).
    pub added: u32,
    /// Lines removed since `HEAD`.
    pub removed: u32,
    /// Changed paths.
    pub changed_files: u32,
    /// Uncommitted changes or untracked files.
    pub dirty: bool,
    /// The branch's pull request.
    pub pr: Option<PullRequest>,
    /// Scripts from `.<product>.json`.
    pub scripts: Vec<RepoScript>,
    /// Setup command, if any.
    pub setup: Option<String>,
    /// Teardown command, if any.
    pub teardown: Option<String>,
    /// The daemon created it (auto-delete applies).
    pub managed: bool,
    /// When its pull request was first seen merged.
    pub merged_at_ms: Option<u64>,
    /// When its git state last changed.
    pub updated_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PullRequest {
    pub number: u32,
    pub title: String,
    pub state: PrState,
    pub draft: bool,
    /// Web page.
    pub url: String,
    pub head_ref: String,
    pub additions: u32,
    pub deletions: u32,
    /// Whether it can be merged now.
    pub merge_state: MergeState,
    /// Checks, failures first.
    pub checks: Vec<PrCheck>,
    /// When `gh` was asked.
    pub fetched_at_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PrState {
    Open,
    /// Closed without merging.
    Closed,
    Merged,
}

/// GitHub's `mergeStateStatus`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MergeState {
    /// Mergeable, checks passing.
    Clean,
    /// Mergeable; an optional check failed.
    Unstable,
    /// Mergeable with hooks.
    HasHooks,
    /// Behind its base.
    Behind,
    /// Blocked by reviews or required checks.
    Blocked,
    Dirty,
    Draft,
    /// Not computed yet.
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PrCheck {
    pub name: String,
    /// Where it stands.
    pub status: CheckStatus,
    pub url: Option<String>,
    pub workflow: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CheckStatus {
    /// Queued or running.
    Pending,
    Success,
    Failure,
    Neutral,
    Skipped,
    Cancelled,
}

/// Whether the host's `gh` works.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum GhStatus {
    /// Not checked yet.
    Unknown,
    /// Installed and signed in.
    Ready { account: Option<String> },
    /// Not installed on the host.
    Missing,
    /// Not signed in (`gh auth login`).
    NotAuthenticated {
        /// What `gh` said.
        message: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RepoScript {
    pub name: String,
    /// Shell command line.
    pub command: String,
    /// SF Symbol.
    pub icon: Option<String>,
    /// Tint name or `#RRGGBB`.
    pub tint: Option<String>,
    /// The one ⌘R runs.
    pub is_default: bool,
}

/// How a pull request is merged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MergeStrategy {
    Merge,
    Squash,
    Rebase,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ArchivedWorktree {
    /// Id for [`DaemonClient::worktree_restore`].
    pub id: u64,
    pub repo: String,
    pub repo_name: String,
    /// Where it was.
    pub path: String,
    pub branch: Option<String>,
    pub head: Option<String>,
    /// Uncommitted changes were kept.
    pub saved_changes: bool,
    pub archived_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TaskCreate {
    /// Any directory in the repository.
    pub repo: String,
    /// Session for the tab.
    pub session_id: u64,
    /// Tab and worktree name.
    pub name: String,
    /// Branch; derived from `name` when `nil`.
    #[uniffi(default = None)]
    pub branch: Option<String>,
    /// Start point; `HEAD` when `nil`.
    #[uniffi(default = None)]
    pub base: Option<String>,
    /// Agent; `nil` opens a shell.
    #[uniffi(default = None)]
    pub agent: Option<AgentKind>,
    /// A first prompt for the agent, typed once it is ready.
    #[uniffi(default = None)]
    pub prompt: Option<String>,
}

/// A repository's setup and teardown commands and whether the owner trusts them. Only
/// trusted commands run; changed ones are asked about again.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RepoHooksTrust {
    /// The repository (main worktree); pass it to [`DaemonClient::repo_trust`].
    pub repo: String,
    /// Run in a new task's first pane.
    pub setup: Option<String>,
    /// Run before a worktree is archived or deleted.
    pub teardown: Option<String>,
    /// Pass it to [`DaemonClient::repo_trust`]: exactly these commands.
    pub hash: String,
    /// The owner trusts them (also when there are none).
    pub trusted: bool,
}

impl From<proto::RepoHooksTrust> for RepoHooksTrust {
    fn from(repo_hooks_trust: proto::RepoHooksTrust) -> Self {
        Self {
            repo: repo_hooks_trust.repo,
            setup: repo_hooks_trust.hooks.setup,
            teardown: repo_hooks_trust.hooks.teardown,
            hash: repo_hooks_trust.hash,
            trusted: repo_hooks_trust.trusted,
        }
    }
}

impl RepoHooksTrust {
    /// Whether there is anything to ask about: commands the owner has not trusted.
    fn needs_asking(&self) -> bool {
        !self.trusted && (self.setup.is_some() || self.teardown.is_some())
    }
}

/// What [`DaemonClient::task_create`] made.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TaskCreated {
    pub worktree: WorktreeInfo,
    pub tab_id: u64,
    pub pane_id: u64,
    /// The setup command that runs first.
    pub setup: Option<String>,
    /// Why the prompt was not sent, if one was given and it was not.
    pub prompt_error: Option<String>,
}

impl From<proto::RepoSnapshot> for RepoSnapshot {
    fn from(repo_snapshot: proto::RepoSnapshot) -> Self {
        Self {
            rev: repo_snapshot.rev,
            panes: repo_snapshot
                .panes
                .into_iter()
                .map(|pane| PaneRepo {
                    pane_id: pane.pane_id.0,
                    worktree: pane.worktree,
                })
                .collect(),
            worktrees: repo_snapshot
                .worktrees
                .into_iter()
                .map(Into::into)
                .collect(),
            gh: repo_snapshot.gh.into(),
        }
    }
}

impl From<proto::WorktreeState> for WorktreeState {
    fn from(worktree_state: proto::WorktreeState) -> Self {
        Self {
            path: worktree_state.path,
            repo: worktree_state.repo,
            repo_name: worktree_state.repo_name,
            name: worktree_state.name,
            main: worktree_state.main,
            branch: worktree_state.branch,
            head: worktree_state.head,
            upstream: worktree_state.upstream,
            ahead: worktree_state.ahead,
            behind: worktree_state.behind,
            added: worktree_state.added,
            removed: worktree_state.removed,
            changed_files: worktree_state.changed_files,
            dirty: worktree_state.dirty,
            pr: worktree_state.pr.map(Into::into),
            scripts: worktree_state
                .scripts
                .into_iter()
                .map(|script| RepoScript {
                    name: script.name,
                    command: script.command,
                    icon: script.icon,
                    tint: script.tint,
                    is_default: script.default,
                })
                .collect(),
            setup: worktree_state.hooks.setup,
            teardown: worktree_state.hooks.teardown,
            managed: worktree_state.managed,
            merged_at_ms: worktree_state.merged_at.map(|t| t.0),
            updated_at_ms: worktree_state.updated_at.0,
        }
    }
}

impl From<proto::PullRequest> for PullRequest {
    fn from(pull_request: proto::PullRequest) -> Self {
        Self {
            number: pull_request.number,
            title: pull_request.title,
            state: match pull_request.state {
                proto::PrState::Open => PrState::Open,
                proto::PrState::Closed => PrState::Closed,
                proto::PrState::Merged => PrState::Merged,
            },
            draft: pull_request.draft,
            url: pull_request.url,
            head_ref: pull_request.head_ref,
            additions: pull_request.additions,
            deletions: pull_request.deletions,
            merge_state: match pull_request.merge_state {
                proto::MergeState::Clean => MergeState::Clean,
                proto::MergeState::Unstable => MergeState::Unstable,
                proto::MergeState::HasHooks => MergeState::HasHooks,
                proto::MergeState::Behind => MergeState::Behind,
                proto::MergeState::Blocked => MergeState::Blocked,
                proto::MergeState::Dirty => MergeState::Dirty,
                proto::MergeState::Draft => MergeState::Draft,
                proto::MergeState::Unknown => MergeState::Unknown,
            },
            checks: pull_request
                .checks
                .into_iter()
                .map(|check| PrCheck {
                    name: check.name,
                    status: match check.status {
                        proto::CheckStatus::Pending => CheckStatus::Pending,
                        proto::CheckStatus::Success => CheckStatus::Success,
                        proto::CheckStatus::Failure => CheckStatus::Failure,
                        proto::CheckStatus::Neutral => CheckStatus::Neutral,
                        proto::CheckStatus::Skipped => CheckStatus::Skipped,
                        proto::CheckStatus::Cancelled => CheckStatus::Cancelled,
                    },
                    url: check.url,
                    workflow: check.workflow,
                })
                .collect(),
            fetched_at_ms: pull_request.fetched_at.0,
        }
    }
}

impl From<proto::GhStatus> for GhStatus {
    fn from(gh_status: proto::GhStatus) -> Self {
        match gh_status {
            proto::GhStatus::Unknown => Self::Unknown,
            proto::GhStatus::Ready { account } => Self::Ready { account },
            proto::GhStatus::Missing => Self::Missing,
            proto::GhStatus::NotAuthenticated { message } => Self::NotAuthenticated { message },
        }
    }
}

impl From<MergeStrategy> for proto::MergeStrategy {
    fn from(merge_strategy: MergeStrategy) -> Self {
        match merge_strategy {
            MergeStrategy::Merge => Self::Merge,
            MergeStrategy::Squash => Self::Squash,
            MergeStrategy::Rebase => Self::Rebase,
        }
    }
}

impl From<proto::ArchivedWorktree> for ArchivedWorktree {
    fn from(archived_worktree: proto::ArchivedWorktree) -> Self {
        Self {
            id: archived_worktree.id,
            repo: archived_worktree.repo,
            repo_name: archived_worktree.repo_name,
            path: archived_worktree.path,
            branch: archived_worktree.branch,
            head: archived_worktree.head,
            saved_changes: archived_worktree.saved_changes,
            archived_at_ms: archived_worktree.archived_at.0,
        }
    }
}

impl DaemonClient {
    async fn repo_hooks(
        &self,
        of: proto::RepoHooksFor,
    ) -> Result<Option<RepoHooksTrust>, WorkspaceError> {
        let offered = self
            .inner
            .daemon_info()
            .is_some_and(|i| i.features.contains(proto::DaemonFeatures::REPO_TRUST));
        if !offered {
            return Ok(None);
        }
        let trust: proto::RepoHooksTrust = self
            .ws_call(|client| async move { client.repo_hooks(of).await })
            .await?;
        Ok(Some(RepoHooksTrust::from(trust)).filter(RepoHooksTrust::needs_asking))
    }
}

#[uniffi::export]
impl DaemonClient {
    /// The last repository snapshot the daemon pushed (no round trip).
    pub fn repos(&self) -> Option<RepoSnapshot> {
        self.inner.repos().map(Into::into)
    }

    /// Re-reads the watched worktrees now, and `path`'s pull request (every one when `nil`).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn repo_refresh(&self, path: Option<String>) -> Result<RepoSnapshot, WorkspaceError> {
        self.ws_call(|client| async move { client.repo_refresh(path).await })
            .await
    }

    /// Merges the worktree's pull request `number` (refused unless GitHub says it can be
    /// merged); the pull request afterwards.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`]: `Conflict` when not mergeable or the number changed,
    /// `Unavailable` when `gh` is missing or signed out.
    pub async fn pr_merge(
        &self,
        path: String,
        number: u32,
        strategy: MergeStrategy,
    ) -> Result<Option<PullRequest>, WorkspaceError> {
        let pr: Option<proto::PullRequest> = self
            .ws_call(|client| async move {
                client
                    .pr_merge(proto::PrMerge {
                        path,
                        number,
                        strategy: strategy.into(),
                    })
                    .await
            })
            .await?;
        Ok(pr.map(Into::into))
    }

    /// Re-runs the failed jobs of the worktree's pull request.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn pr_rerun_failed(
        &self,
        path: String,
    ) -> Result<Option<PullRequest>, WorkspaceError> {
        let pr: Option<proto::PullRequest> = self
            .ws_call(|client| async move { client.pr_rerun_failed(path).await })
            .await?;
        Ok(pr.map(Into::into))
    }

    /// Pushes the worktree's branch and opens a pull request (`gh pr create --fill`).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn pr_create(
        &self,
        path: String,
        draft: bool,
        base: Option<String>,
    ) -> Result<Option<PullRequest>, WorkspaceError> {
        let pr: Option<proto::PullRequest> = self
            .ws_call(|client| async move {
                client
                    .pr_create(proto::PrCreate { path, draft, base })
                    .await
            })
            .await?;
        Ok(pr.map(Into::into))
    }

    /// Checks pull request `number` out into a new worktree.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn pr_checkout(
        &self,
        repo: String,
        number: u32,
    ) -> Result<WorktreeInfo, WorkspaceError> {
        self.ws_call(|client| async move {
            client.pr_checkout(proto::PrCheckout { repo, number }).await
        })
        .await
    }

    /// Archives a worktree: its commits stay under a ref, and with `force` its uncommitted
    /// changes too (`Conflict` when it has changes and not `force`).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn worktree_archive(&self, path: String, force: bool) -> Result<(), WorkspaceError> {
        self.ws_call(|client| async move { client.worktree_archive(path, force).await })
            .await
    }

    /// Archived worktrees, newest first (of one repository, or all).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn worktree_archived(
        &self,
        repo: Option<String>,
    ) -> Result<Vec<ArchivedWorktree>, WorkspaceError> {
        let all: Vec<proto::ArchivedWorktree> = self
            .ws_call(|client| async move { client.worktree_archived(repo).await })
            .await?;
        Ok(all.into_iter().map(Into::into).collect())
    }

    /// Restores an archived worktree where it was.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn worktree_restore(&self, id: u64) -> Result<WorktreeInfo, WorkspaceError> {
        self.ws_call(|client| async move { client.worktree_restore(id).await })
            .await
    }

    /// The days after merging before the daemon deletes a worktree it created (0: never);
    /// `set` changes it first.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`] (changing it needs the owner).
    pub async fn worktree_auto_delete_days(&self, set: Option<u32>) -> Result<u32, WorkspaceError> {
        let settings: proto::WorktreeSettings = self
            .ws_call(|client| async move {
                client
                    .worktree_settings(set.map(|desired| proto::WorktreeSettings {
                        auto_delete_merged_days: desired,
                    }))
                    .await
            })
            .await?;
        Ok(settings.auto_delete_merged_days)
    }

    /// A new task: a worktree on a new branch and a tab running a shell or an agent there
    /// (after the repository's setup command); types `prompt` once the agent is ready.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`] if the worktree or tab could not be made; a prompt
    /// that could not be sent is reported in [`TaskCreated::prompt_error`].
    pub async fn task_create(&self, task: TaskCreate) -> Result<TaskCreated, WorkspaceError> {
        let prompt = task.prompt.clone();
        let req = proto::TaskCreate {
            repo: task.repo,
            session_id: proto::SessionId(task.session_id),
            name: task.name,
            branch: task.branch,
            base: task.base,
            agent: task.agent.map(Into::into),
        };
        let made: proto::TaskCreated = self
            .ws_call(|client| async move { client.task_create(req).await })
            .await?;
        let mut out = TaskCreated {
            worktree: made.worktree.into(),
            tab_id: made.tab_id.0,
            pane_id: made.pane_id.0,
            setup: made.setup,
            prompt_error: None,
        };
        if let Some(text) = prompt.filter(|p| !p.trim().is_empty()) {
            // Setup may take a while before the agent starts.
            if !self.agent_idle(out.pane_id, Duration::from_secs(300)).await {
                out.prompt_error = Some("the agent did not become ready in time".into());
            } else if let Err(e) = self.prompt(out.pane_id, text, true).await {
                out.prompt_error = Some(e.to_string());
            }
        }
        Ok(out)
    }

    /// The setup and teardown commands a new task in `repo` from `base` would run, and whether
    /// they are trusted. `None` from daemons that run them without asking (no
    /// `DaemonFeatures::REPO_TRUST`).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn repo_hooks_for_task(
        &self,
        repo: String,
        base: Option<String>,
    ) -> Result<Option<RepoHooksTrust>, WorkspaceError> {
        self.repo_hooks(proto::RepoHooksFor::NewTask { repo, base })
            .await
    }

    /// The teardown (and setup) commands of the worktree at `path`, and whether they are
    /// trusted, before archiving or deleting it. `None` as for
    /// [`repo_hooks_for_task`](Self::repo_hooks_for_task).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn repo_hooks_for_worktree(
        &self,
        path: String,
    ) -> Result<Option<RepoHooksTrust>, WorkspaceError> {
        self.repo_hooks(proto::RepoHooksFor::Worktree { path })
            .await
    }

    /// Trusts a repository's commands ([`RepoHooksTrust::repo`] and [`RepoHooksTrust::hash`]):
    /// they run from now on, until they change. Owner devices only.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`] (`Denied` for a guest).
    pub async fn repo_trust(&self, repo: String, hash: String) -> Result<(), WorkspaceError> {
        self.ws_call(|client| async move { client.repo_trust(repo, hash).await })
            .await
    }

    /// Runs a command in a new tab in `cwd` (it stays a shell afterwards); the new pane.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn script_run(
        &self,
        cwd: String,
        session_id: u64,
        name: String,
        command: String,
    ) -> Result<u64, WorkspaceError> {
        let pane: proto::PaneId = self
            .ws_call(|client| async move {
                client
                    .script_run(proto::ScriptRun {
                        cwd,
                        session_id: proto::SessionId(session_id),
                        name,
                        command,
                    })
                    .await
            })
            .await?;
        Ok(pane.0)
    }
}
