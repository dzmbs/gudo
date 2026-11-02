//! files and transfers, ports, attention, and the agent-pane launcher. Forwards are in
//! `client.rs`, the editor in `editor.rs`.
//!
//! Every request is an `async` method that runs on the core runtime and returns the
//! daemon's typed answer or a [`WorkspaceError`]. Pushes go to a [`WorkspaceListener`].

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use client_core::proto;

use crate::bytes::Bytes;
use crate::client::{DaemonClient, lock};
use crate::on_runtime;
use crate::types::{AgentKind, Axis, OpOutcome};
use crate::ws_types::{
    AttentionList, AttentionSeen, DeleteMode, DirListing, FileChunk, FileStat, GitDiff,
    GitDiffRequest, GitStatus, PortInfo, ReviewRequest, TurnInfo, WorkspaceError, WorkspaceEvent,
    WorktreeCreate, WorktreeInfo, WorktreeLaunch, WriteTarget,
};

/// Receives [`WorkspaceEvent`]s; implemented in Swift.
///
/// Called on a runtime thread, in order, one at a time per client. Return quickly.
#[uniffi::export(foreign)]
pub trait WorkspaceListener: Send + Sync {
    /// One event.
    fn on_workspace_event(&self, event: WorkspaceEvent);
}

struct WsForward(Arc<dyn WorkspaceListener>);

impl client_core::WorkspaceListener for WsForward {
    fn on_workspace_event(&self, event: client_core::WorkspaceEvent) {
        self.0.on_workspace_event(event.into());
    }
}

/// Progress of an upload or download; implemented in Swift. Called on a runtime thread
/// after every chunk (64 KiB), so throttle UI updates on the Swift side.
#[uniffi::export(foreign)]
pub trait TransferProgress: Send + Sync {
    /// `done` of `total` bytes moved.
    fn on_progress(&self, done: u64, total: u64);
}

struct ProgressForward(Arc<dyn TransferProgress>);

impl client_core::TransferProgress for ProgressForward {
    fn on_progress(&self, done: u64, total: u64) {
        self.0.on_progress(done, total);
    }
}

pub(crate) fn progress_adapter(
    p: Option<Arc<dyn TransferProgress>>,
) -> Option<Arc<dyn client_core::TransferProgress>> {
    p.map(|p| Arc::new(ProgressForward(p)) as Arc<dyn client_core::TransferProgress>)
}

/// What [`DaemonClient::launch_agent_pane`] starts.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AgentLaunch {
    /// The pane to split.
    pub split_from: u64,
    /// Claude Code or Codex.
    pub agent: AgentKind,
    /// Split direction.
    pub axis: Axis,
    /// Run in this worktree (with its `PORT`); see `worktree_create`. Takes precedence over
    /// `cwd`.
    #[uniffi(default = None)]
    pub worktree: Option<String>,
    /// Working directory; `nil` inherits from the split pane.
    #[uniffi(default = None)]
    pub cwd: Option<String>,
    /// The agent's own session id to resume (not with `worktree`).
    #[uniffi(default = None)]
    pub resume: Option<String>,
    /// A first prompt, typed through the composer path once the agent is idle.
    #[uniffi(default = None)]
    pub prompt: Option<String>,
    /// Press Enter after the prompt.
    #[uniffi(default = true)]
    pub submit: bool,
    /// How long to wait for the agent to become idle before giving up on the prompt.
    #[uniffi(default = 30000)]
    pub ready_timeout_ms: u64,
    /// Open the agent in a new tab of this session (selected) instead of splitting
    /// `split_from`, whose directory it still inherits when `cwd` is `None`. Not with
    /// `worktree`.
    #[uniffi(default = None)]
    pub new_tab_in: Option<u64>,
    /// The account to run under (`AgentAccount.id`); `nil` uses the host's default. Ignored
    /// by daemons without accounts, and by a resume, which keeps the session's account.
    #[uniffi(default = None)]
    pub account: Option<String>,
}

/// The pane a layout op made, or its failure as a [`WorkspaceError`].
pub(crate) fn created_pane(outcome: OpOutcome) -> Result<u64, WorkspaceError> {
    match outcome {
        OpOutcome::PaneCreated { pane_id } | OpOutcome::TabCreated { pane_id, .. } => Ok(pane_id),
        OpOutcome::Failed { code, message } => Err(match code {
            crate::types::OpErrorCode::Forbidden => WorkspaceError::Denied { message },
            crate::types::OpErrorCode::NotFound => WorkspaceError::NotFound { message },
            _ => WorkspaceError::Failed { message },
        }),
        other => Err(WorkspaceError::Failed {
            message: format!("unexpected outcome {other:?}"),
        }),
    }
}

/// The tab [`DaemonClient::reopen_tab`] made.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ReopenedTab {
    /// The new tab.
    pub tab_id: u64,
    /// Its pane.
    pub pane_id: u64,
}

/// What [`DaemonClient::launch_agent_pane`] did.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AgentLaunched {
    /// The new pane.
    pub pane_id: u64,
    /// Characters of the prompt sent, if one was given and sent.
    pub prompt_chars: Option<u32>,
    /// Why the prompt was not sent (the agent did not become idle in time, or the daemon
    /// refused it). The pane runs either way.
    pub prompt_error: Option<String>,
}

impl DaemonClient {
    /// Runs a client-core request on the runtime and converts its answer.
    pub(crate) async fn ws_call<T, U, F, Fut>(&self, f: F) -> Result<U, WorkspaceError>
    where
        F: FnOnce(Arc<client_core::Client>) -> Fut,
        Fut: Future<Output = Result<T, proto::WsError>> + Send + 'static,
        T: Send + 'static,
        U: From<T>,
    {
        let fut = f(self.core());
        on_runtime(fut).await.map(U::from).map_err(Into::into)
    }

    /// Waits until `pane_id`'s agent reports [`proto::AgentState::Idle`].
    pub(crate) async fn agent_idle(&self, pane_id: u64, timeout: Duration) -> bool {
        let tap = Arc::clone(&self.tap);
        on_runtime(async move {
            let deadline = tokio::time::Instant::now() + timeout;
            loop {
                let notified = tap.meta_changed.notified();
                tokio::pin!(notified);
                notified.as_mut().enable();
                let idle = lock(&tap.agents).get(&pane_id).is_some_and(|a| {
                    a.as_ref()
                        .is_some_and(|a| matches!(a.state, proto::AgentState::Idle))
                });
                if idle {
                    return true;
                }
                if tokio::time::timeout_at(deadline, notified).await.is_err() {
                    return false;
                }
            }
        })
        .await
    }
}

#[uniffi::export]
impl DaemonClient {
    /// Sets the receiver of [`WorkspaceEvent`]s (ports, watched directories, attention, the
    /// VS Code tunnel), replacing any previous one.
    pub fn set_workspace_listener(&self, listener: Arc<dyn WorkspaceListener>) {
        self.inner
            .set_workspace_listener(Arc::new(WsForward(listener)));
    }

    // --- ports ----------------------------------------------------------------------------

    /// The last port list the daemon pushed (no round trip).
    pub fn ports(&self) -> Vec<PortInfo> {
        self.inner.ports().into_iter().map(Into::into).collect()
    }

    /// Listening ports in the daemon's panes, scanned now.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn list_ports(&self) -> Result<Vec<PortInfo>, WorkspaceError> {
        let ports: Vec<proto::PortInfo> = self
            .ws_call(|c| async move { c.list_ports().await })
            .await?;
        Ok(ports.into_iter().map(Into::into).collect())
    }

    // --- git ------------------------------------------------------------------------------

    /// Branch, upstream, ahead/behind and changed files of the repository containing `path`.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`] (`NotFound` outside a repository).
    pub async fn git_status(&self, path: String) -> Result<GitStatus, WorkspaceError> {
        self.ws_call(|c| async move { c.git_status(path).await })
            .await
    }

    /// A diff, file by file.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn git_diff(&self, request: GitDiffRequest) -> Result<GitDiff, WorkspaceError> {
        self.ws_call(|c| async move { c.git_diff(request.into()).await })
            .await
    }

    /// The agent turns recorded for a pane, newest last.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn list_turns(&self, pane_id: u64) -> Result<Vec<TurnInfo>, WorkspaceError> {
        let turns: Vec<proto::TurnInfo> = self
            .ws_call(|c| async move { c.list_turns(proto::PaneId(pane_id)).await })
            .await?;
        Ok(turns.into_iter().map(Into::into).collect())
    }

    /// What an agent turn changed (`turn` `nil`: the latest; a running turn diffs against
    /// now).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn turn_diff(
        &self,
        pane_id: u64,
        turn: Option<u64>,
        context: u32,
        hunks: bool,
    ) -> Result<GitDiff, WorkspaceError> {
        self.ws_call(|c| async move {
            c.turn_diff(proto::PaneId(pane_id), turn, context, hunks)
                .await
        })
        .await
    }

    /// Formats review notes into a prompt and types it into the agent pane; returns the
    /// prompt.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn send_review(&self, review: ReviewRequest) -> Result<String, WorkspaceError> {
        self.ws_call(|c| async move { c.send_review(review.into()).await })
            .await
    }

    // --- worktrees ------------------------------------------------------------------------

    /// Creates a worktree on a new branch (with its own `PORT`).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn worktree_create(
        &self,
        create: WorktreeCreate,
    ) -> Result<WorktreeInfo, WorkspaceError> {
        self.ws_call(|c| async move { c.worktree_create(create.into()).await })
            .await
    }

    /// The repository's worktrees.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn worktree_list(&self, repo: String) -> Result<Vec<WorktreeInfo>, WorkspaceError> {
        let all: Vec<proto::WorktreeInfo> = self
            .ws_call(|c| async move { c.worktree_list(repo).await })
            .await?;
        Ok(all.into_iter().map(Into::into).collect())
    }

    /// Removes a worktree (`Conflict` when it has changes, unless `force`).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn worktree_remove(
        &self,
        path: String,
        force: bool,
        delete_branch: bool,
    ) -> Result<(), WorkspaceError> {
        self.ws_call(|c| async move { c.worktree_remove(path, force, delete_branch).await })
            .await
    }

    /// Splits a pane and starts a shell or an agent in a worktree; returns the new pane.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn worktree_launch(&self, launch: WorktreeLaunch) -> Result<u64, WorkspaceError> {
        let pane: proto::PaneId = self
            .ws_call(|c| async move {
                c.worktree_launch(
                    launch.path,
                    proto::PaneId(launch.split_from),
                    launch.axis.into(),
                    launch.agent.map(Into::into),
                )
                .await
            })
            .await?;
        Ok(pane.0)
    }

    // --- agents ---------------------------------------------------------------------------

    /// Starts Claude Code or Codex in a new pane or tab (in a worktree, a directory, or
    /// resuming a session) and, if `prompt` is set, types it through the composer path once the agent
    /// is idle. Agent state then arrives in `PaneMeta.agent`, raw agent events as
    /// `ClientEvent.agentEvent`, and approvals are answered with
    /// [`decide`](Self::decide) (signed with the device key).
    ///
    /// # Errors
    ///
    /// [`WorkspaceError`] if the pane could not be created; a refused prompt is reported in
    /// [`AgentLaunched::prompt_error`] instead, as the pane exists by then.
    pub async fn launch_agent_pane(
        &self,
        launch: AgentLaunch,
    ) -> Result<AgentLaunched, WorkspaceError> {
        let pane_id = match launch.worktree {
            Some(path) => {
                self.worktree_launch(WorktreeLaunch {
                    path,
                    split_from: launch.split_from,
                    axis: launch.axis,
                    agent: Some(launch.agent),
                })
                .await?
            }
            None => {
                let accounts = self
                    .inner
                    .daemon_info()
                    .is_some_and(|i| i.features.contains(proto::DaemonFeatures::ACCOUNTS));
                let agent = if accounts {
                    proto::PaneLaunch::AccountAgent {
                        agent: launch.agent.into(),
                        account: launch.account,
                        resume: launch.resume,
                        cwd: launch.cwd,
                    }
                } else {
                    proto::PaneLaunch::Agent {
                        agent: launch.agent.into(),
                        resume: launch.resume,
                        cwd: launch.cwd,
                    }
                };
                let op = match launch.new_tab_in {
                    Some(session) => proto::LayoutOp::NewTab {
                        session_id: proto::SessionId(session),
                        name: String::new(),
                        launch: agent,
                    },
                    None => proto::LayoutOp::Split {
                        pane_id: proto::PaneId(launch.split_from),
                        axis: launch.axis.into(),
                        launch: agent,
                    },
                };
                created_pane(self.await_op(op).await?)?
            }
        };
        let mut launched = AgentLaunched {
            pane_id,
            prompt_chars: None,
            prompt_error: None,
        };
        let Some(text) = launch.prompt else {
            return Ok(launched);
        };
        if !self
            .agent_idle(pane_id, Duration::from_millis(launch.ready_timeout_ms))
            .await
        {
            launched.prompt_error = Some("the agent did not become ready in time".into());
            return Ok(launched);
        }
        match self.prompt(pane_id, text, launch.submit).await {
            Ok(chars) => launched.prompt_chars = Some(chars),
            Err(e) => launched.prompt_error = Some(e.to_string()),
        }
        Ok(launched)
    }

    /// Reopens a closed tab as a new tab of `session_id` named `name` (empty: the daemon's
    /// default), selected: the closed pane's agent resumes its session and a shell comes back
    /// in its last directory. A daemon that does not keep closed panes opens a shell in `cwd`.
    /// Returns the new tab and pane.
    ///
    /// # Errors
    ///
    /// [`WorkspaceError::Denied`] for a connection without the owner role; otherwise as the
    /// op failed.
    pub async fn reopen_tab(
        &self,
        session_id: u64,
        closed_pane: u64,
        cwd: Option<String>,
        name: String,
    ) -> Result<ReopenedTab, WorkspaceError> {
        let reopens = self
            .inner
            .daemon_info()
            .is_some_and(|i| i.features.contains(proto::DaemonFeatures::REOPEN));
        let launch = if reopens {
            proto::PaneLaunch::Reopen {
                pane_id: proto::PaneId(closed_pane),
                cwd,
            }
        } else {
            proto::PaneLaunch::Shell { cwd }
        };
        let op = proto::LayoutOp::NewTab {
            session_id: proto::SessionId(session_id),
            name,
            launch,
        };
        match self.await_op(op).await? {
            OpOutcome::TabCreated { tab_id, pane_id } => Ok(ReopenedTab { tab_id, pane_id }),
            OpOutcome::Failed { code, message } => Err(match code {
                crate::types::OpErrorCode::Forbidden => WorkspaceError::Denied { message },
                crate::types::OpErrorCode::NotFound => WorkspaceError::NotFound { message },
                _ => WorkspaceError::Failed { message },
            }),
            other => Err(WorkspaceError::Failed {
                message: format!("unexpected outcome {other:?}"),
            }),
        }
    }

    // --- files ----------------------------------------------------------------------------

    /// Lists a directory (directories first).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`] (`Denied` outside the allowed roots).
    pub async fn fs_list(
        &self,
        path: String,
        show_hidden: bool,
    ) -> Result<DirListing, WorkspaceError> {
        self.ws_call(|c| async move { c.fs_list(path, show_hidden).await })
            .await
    }

    /// `lstat` of a path.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn fs_stat(&self, path: String) -> Result<FileStat, WorkspaceError> {
        self.ws_call(|c| async move { c.fs_stat(path).await }).await
    }

    /// Reads up to 1 MiB of a file (use [`download_file`](Self::download_file) for more).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn fs_read(
        &self,
        path: String,
        offset: u64,
        len: u32,
    ) -> Result<FileChunk, WorkspaceError> {
        self.ws_call(|c| async move { c.fs_read(path, offset, len).await })
            .await
    }

    /// Writes a small file (up to 1 MiB) atomically; returns its new stat.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`] (`Conflict` on an `if_match` mismatch).
    pub async fn fs_write(
        &self,
        target: WriteTarget,
        data: Bytes,
    ) -> Result<FileStat, WorkspaceError> {
        self.ws_call(|c| async move { c.fs_write(target.into(), data.into()).await })
            .await
    }

    /// Creates a directory.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn fs_mkdir(&self, path: String, parents: bool) -> Result<FileStat, WorkspaceError> {
        self.ws_call(|c| async move { c.fs_mkdir(path, parents).await })
            .await
    }

    /// Renames or moves (no replace unless `overwrite`).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn fs_rename(
        &self,
        from: String,
        to: String,
        overwrite: bool,
    ) -> Result<FileStat, WorkspaceError> {
        self.ws_call(|c| async move { c.fs_rename(from, to, overwrite).await })
            .await
    }

    /// Deletes, or moves to the trash.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn fs_delete(
        &self,
        path: String,
        mode: DeleteMode,
        recursive: bool,
    ) -> Result<(), WorkspaceError> {
        self.ws_call(|c| async move { c.fs_delete(path, mode.into(), recursive).await })
            .await
    }

    /// Watches a directory (not recursively); changes arrive as
    /// [`WorkspaceEvent::FsChanged`] with the returned id. Watches end with the connection:
    /// set them up again after `ClientEvent.connected`.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn fs_watch(&self, path: String) -> Result<u64, WorkspaceError> {
        self.ws_call(|c| async move { c.fs_watch(path).await })
            .await
    }

    /// Stops a watch.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn fs_unwatch(&self, watch_id: u64) -> Result<(), WorkspaceError> {
        self.ws_call(|c| async move { c.fs_unwatch(watch_id).await })
            .await
    }

    /// Uploads a local file (any size) to the host on its own stream at bulk priority,
    /// written atomically there.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`]; `NotFound` if the local file cannot be opened.
    pub async fn upload_file(
        &self,
        local_path: String,
        target: WriteTarget,
        progress: Option<Arc<dyn TransferProgress>>,
    ) -> Result<FileStat, WorkspaceError> {
        let progress = progress_adapter(progress);
        self.ws_call(|c| async move { c.upload_file(local_path, target.into(), progress).await })
            .await
    }

    /// Uploads bytes held in memory (see [`upload_file`](Self::upload_file)).
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn upload_bytes(
        &self,
        data: Bytes,
        target: WriteTarget,
    ) -> Result<FileStat, WorkspaceError> {
        self.ws_call(|c| async move { c.upload_bytes(data.into(), target.into()).await })
            .await
    }

    /// Downloads a remote file to `local_path` (through a temporary file next to it).
    /// `len` `nil` reads to the end. Returns the remote file's stat.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`], or `Failed` for a local write error.
    pub async fn download_file(
        &self,
        remote_path: String,
        local_path: String,
        offset: u64,
        len: Option<u64>,
        progress: Option<Arc<dyn TransferProgress>>,
    ) -> Result<FileStat, WorkspaceError> {
        let progress = progress_adapter(progress);
        self.ws_call(|c| async move {
            c.download_file(remote_path, local_path, offset, len, progress)
                .await
        })
        .await
    }

    // --- attention ------------------------------------------------------------------------

    /// The attention feed (the inbox) and this host's unseen count.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn attention_list(&self) -> Result<AttentionList, WorkspaceError> {
        self.ws_call(|c| async move { c.attention_list().await })
            .await
    }

    /// Marks items seen on every device; returns the feed after the change.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn attention_seen(
        &self,
        seen: AttentionSeen,
    ) -> Result<AttentionList, WorkspaceError> {
        self.ws_call(|c| async move { c.attention_seen(seen.into()).await })
            .await
    }
}
