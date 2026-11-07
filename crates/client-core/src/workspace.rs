//! Developer-workflow API: port forwards to TCP ports or Unix sockets, detected ports,
//! the editor server, git status and diffs, agent-turn changes, review notes, worktrees,
//! files (with streamed upload and download) and the attention feed.
//!
//! Requests are `async` and return the daemon's typed answer or a [`WsError`]; they can be
//! awaited from any executor (the network work runs on the client's own runtime). Pushes —
//! port changes, watched-directory changes, attention updates — go to a
//! [`WorkspaceListener`] set with [`Client::set_workspace_listener`], separate from
//! [`ClientListener`](crate::ClientListener) so existing event handling is unaffected.

use std::collections::HashMap;
use std::net::TcpListener as StdTcpListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::{
    AgentUsageReport, AttentionList, AttentionSeen, AttentionUpdate, Axis, DeleteMode, DirListing,
    DownloadHeader, EditorInstance, EditorLaunch, EditorList, EditorOpened, FileChunk, FileStat,
    ForwardReply, ForwardTarget, FsChange, GitDiff, GitDiffRequest, GitStatus, PaneId, PortInfo,
    ReviewRequest, ServerCtl, StreamHeader, TransferReply, TurnInfo, UploadHeader,
    VsCodeCliInstall, VsCodeTunnelOpen, VsCodeTunnelOpened, VsCodeTunnelStart, VsCodeTunnelStatus,
    WorkspaceRequest, WorkspaceResponse, WorktreeCreate, WorktreeInfo, WriteTarget, WsError,
};
use proto::{
    ArchivedWorktree, PrCheckout, PrCreate, PrMerge, PullRequest, RepoHooksFor, RepoHooksTrust,
    RepoSnapshot, ScriptRun, TaskCreate, TaskCreated, Workflow, WorkflowList, WorkflowSave,
    WorktreeSettings,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot};
use tokio::task::AbortHandle;

use crate::listen::LocalListener;
use crate::{Client, ClientError, Inner, lock};

/// How long a request waits for its answer (a large diff or a first editor start can take a
/// while; `code serve-web` downloads its server on first use).
const REQUEST_TIMEOUT: Duration = Duration::from_secs(300);
const COPY_CHUNK: usize = 64 << 10;

/// A push from the daemon about the workspace.
#[derive(Debug, Clone)]
pub enum WorkspaceEvent {
    /// The listening ports in panes (the whole list).
    PortsChanged {
        ports: Vec<PortInfo>,
    },
    /// A watched directory changed ([`Client::fs_watch`]).
    FsChanged {
        change: FsChange,
    },
    /// The attention feed changed.
    Attention {
        update: AttentionUpdate,
    },
    /// The host's VS Code tunnel changed state: show a device code
    /// ([`TunnelState::NeedsLogin`](proto::TunnelState::NeedsLogin)), connected, failed.
    VsCodeTunnel {
        status: VsCodeTunnelStatus,
    },
    /// Agent plan usage changed (while watching, [`Client::usage_watch`]).
    AgentUsage {
        report: AgentUsageReport,
    },
    /// The host's agent accounts or the panes' accounts changed (owner devices).
    Accounts {
        report: proto::AccountsReport,
    },
    /// Plan usage per account changed (owner devices, while watching usage).
    AccountUsage {
        report: proto::AccountUsageReport,
    },
    /// The repositories, worktrees, branches and pull requests of the panes (the whole
    /// snapshot; only with [`ClientConfig::repo_status`](crate::ClientConfig::repo_status)).
    Repos {
        snapshot: RepoSnapshot,
    },
    /// A workflow file the daemon listed changed: list again ([`Client::workflow_list`]).
    WorkflowsChanged {
        rev: u64,
    },
    Timeline {
        update: proto::TimelineUpdate,
    },
}

/// Receives [`WorkspaceEvent`]s. Must return quickly; it runs on the network threads.
pub trait WorkspaceListener: Send + Sync {
    /// Called once per event, in order.
    fn on_workspace_event(&self, event: WorkspaceEvent);
}

/// A [`WorkspaceListener`] that queues events for async Rust consumers (the `gudo` CLI, tests).
pub struct WorkspaceEventQueue {
    tx: mpsc::UnboundedSender<WorkspaceEvent>,
}

impl WorkspaceEventQueue {
    /// Returns the listener and the receiving end.
    pub fn channel() -> (
        Arc<dyn WorkspaceListener>,
        mpsc::UnboundedReceiver<WorkspaceEvent>,
    ) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Self { tx }), rx)
    }
}

impl WorkspaceListener for WorkspaceEventQueue {
    fn on_workspace_event(&self, event: WorkspaceEvent) {
        let _ = self.tx.send(event);
    }
}

/// Progress of an upload or download.
pub trait TransferProgress: Send + Sync {
    /// `done` of `total` bytes moved.
    fn on_progress(&self, done: u64, total: u64);
}

/// Workspace state kept by the client.
#[derive(Default)]
pub(crate) struct WsState {
    pending: Mutex<HashMap<u64, oneshot::Sender<Result<WorkspaceResponse, WsError>>>>,
    listener: Mutex<Option<Arc<dyn WorkspaceListener>>>,
    ports: Mutex<Vec<PortInfo>>,
    forwards: Mutex<HashMap<u16, (ForwardTarget, AbortHandle)>>,
    repos: Mutex<Option<RepoSnapshot>>,
}

impl WsState {
    /// Handles a workspace message from `ctl`; returns it back if it is not one.
    pub(crate) fn dispatch(&self, msg: ServerCtl) -> Option<ServerCtl> {
        let event = match msg {
            ServerCtl::WorkspaceResult { req_id, result } => {
                if let Some(tx) = lock(&self.pending).remove(&req_id) {
                    let _ = tx.send(result);
                }
                return None;
            }
            ServerCtl::PortsChanged { ports } => {
                lock(&self.ports).clone_from(&ports);
                WorkspaceEvent::PortsChanged { ports }
            }
            ServerCtl::FsChanged(change) => WorkspaceEvent::FsChanged { change },
            ServerCtl::Attention(update) => WorkspaceEvent::Attention { update },
            ServerCtl::VsCodeTunnel(status) => WorkspaceEvent::VsCodeTunnel { status },
            ServerCtl::AgentUsage(report) => WorkspaceEvent::AgentUsage { report },
            ServerCtl::Accounts(report) => WorkspaceEvent::Accounts { report },
            ServerCtl::AccountUsage(report) => WorkspaceEvent::AccountUsage { report },
            ServerCtl::Repos(snapshot) => {
                *lock(&self.repos) = Some(snapshot.clone());
                WorkspaceEvent::Repos { snapshot }
            }
            ServerCtl::WorkflowsChanged { rev } => WorkspaceEvent::WorkflowsChanged { rev },
            ServerCtl::Timeline(update) => WorkspaceEvent::Timeline { update },
            other => return Some(other),
        };
        let listener = lock(&self.listener).clone();
        if let Some(listener) = listener {
            listener.on_workspace_event(event);
        }
        None
    }

    /// The connection dropped: requests in flight will not be answered.
    pub(crate) fn fail_pending(&self) {
        for (_, tx) in lock(&self.pending).drain() {
            let _ = tx.send(Err(WsError::Disconnected));
        }
    }
}

fn failed(err: impl std::fmt::Display) -> WsError {
    WsError::Failed(err.to_string())
}

macro_rules! expect {
    ($response:expr, $pat:pat => $out:expr) => {
        match $response {
            $pat => Ok($out),
            other => Err(WsError::Failed(format!("unexpected answer {other:?}"))),
        }
    };
}

impl Client {
    /// Sets the receiver of [`WorkspaceEvent`]s (replacing any previous one).
    pub fn set_workspace_listener(&self, listener: Arc<dyn WorkspaceListener>) {
        *lock(&self.inner.ws.listener) = Some(listener);
    }

    /// The last port list the daemon pushed.
    pub fn ports(&self) -> Vec<PortInfo> {
        lock(&self.inner.ws.ports).clone()
    }

    /// Sends any workspace request and waits for the answer.
    ///
    /// # Errors
    ///
    /// The daemon's [`WsError`], or [`WsError::Disconnected`] if the connection dropped (or
    /// nothing came back within five minutes).
    pub async fn workspace(&self, request: WorkspaceRequest) -> Result<WorkspaceResponse, WsError> {
        let req_id = self
            .inner
            .next_op
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        lock(&self.inner.ws.pending).insert(req_id, tx);
        self.inner.send(proto::ClientCtl::Workspace {
            req_id,
            req: request,
        });
        let inner = Arc::clone(&self.inner);
        // The timer runs on the client's runtime, so any executor can await this.
        self.handle
            .spawn(async move {
                match tokio::time::timeout(REQUEST_TIMEOUT, rx).await {
                    Ok(Ok(result)) => result,
                    _ => {
                        lock(&inner.ws.pending).remove(&req_id);
                        Err(WsError::Disconnected)
                    }
                }
            })
            .await
            .unwrap_or(Err(WsError::Disconnected))
    }

    /// Listening ports in the daemon's panes, scanned now.
    pub async fn list_ports(&self) -> Result<Vec<PortInfo>, WsError> {
        let ports = expect!(self.workspace(WorkspaceRequest::ListPorts).await?,
            WorkspaceResponse::Ports(ports) => ports)?;
        lock(&self.inner.ws.ports).clone_from(&ports);
        Ok(ports)
    }

    /// Listens on `127.0.0.1:local_port` (0 picks a port) and tunnels every accepted
    /// connection over its own QUIC stream to `target` on the daemon's host. Returns the bound
    /// port. Forwards survive reconnects (new connections wait for the link).
    ///
    /// # Errors
    ///
    /// Returns [`ClientError::Io`] if the local port cannot be bound.
    pub fn forward(&self, local_port: u16, target: ForwardTarget) -> Result<u16, ClientError> {
        let listener = StdTcpListener::bind(("127.0.0.1", local_port))?;
        listener.set_nonblocking(true)?;
        let port = listener.local_addr()?.port();
        let inner = Arc::clone(&self.inner);
        let task = self
            .handle
            .spawn(serve_forward(inner, listener, target.clone()));
        lock(&self.inner.ws.forwards).insert(port, (target, task.abort_handle()));
        Ok(port)
    }

    /// Stops the forward listening on `local_port` (open connections keep running until they
    /// close). Returns whether there was one.
    pub fn stop_forward(&self, local_port: u16) -> bool {
        lock(&self.inner.ws.forwards)
            .remove(&local_port)
            .map(|(_, task)| task.abort())
            .is_some()
    }

    /// Splices one connection to `target` on the daemon's host onto `reader`/`writer` (for
    /// example stdin/stdout, as an SSH `ProxyCommand` to the host's sshd over this link).
    /// Returns when both directions are done.
    ///
    /// # Errors
    ///
    /// [`WsError::Failed`] if the daemon refused the target or the stream broke.
    pub async fn forward_io(
        &self,
        target: ForwardTarget,
        reader: impl tokio::io::AsyncRead + Unpin + Send + 'static,
        writer: impl tokio::io::AsyncWrite + Unpin + Send + 'static,
    ) -> Result<(), WsError> {
        let inner = Arc::clone(&self.inner);
        self.handle
            .spawn(async move {
                match forward_stream(&inner, target, reader, writer).await? {
                    Ended::Clean => Ok(()),
                    Ended::Broken => Err(WsError::Failed("the forward stream broke".into())),
                }
            })
            .await
            .unwrap_or(Err(WsError::Disconnected))
    }

    /// Forwards started with [`forward`](Self::forward): `(local port, target)`.
    pub fn forwards(&self) -> Vec<(u16, ForwardTarget)> {
        lock(&self.inner.ws.forwards)
            .iter()
            .map(|(&port, (target, _))| (port, target.clone()))
            .collect()
    }

    /// Editors the host can run, and the running ones.
    pub async fn editor_status(&self) -> Result<EditorList, WsError> {
        expect!(self.workspace(WorkspaceRequest::EditorStatus).await?,
            WorkspaceResponse::Editors(editors) => editors)
    }

    /// Starts (or reuses) the editor server for a folder. Open
    /// `http://localhost:<port><url_path>` through [`forward`](Self::forward).
    pub async fn editor_launch(&self, launch: EditorLaunch) -> Result<EditorInstance, WsError> {
        expect!(self.workspace(WorkspaceRequest::EditorLaunch(launch)).await?,
            WorkspaceResponse::Editor(editor) => editor)
    }

    /// Stops the editor serving `folder`.
    pub async fn editor_stop(&self, folder: String) -> Result<(), WsError> {
        expect!(self.workspace(WorkspaceRequest::EditorStop { folder }).await?,
            WorkspaceResponse::Done => ())
    }

    /// Opens `path` at a line in the running editor (see [`EditorOpened`]).
    pub async fn editor_open(
        &self,
        folder: Option<String>,
        path: String,
        line: Option<u32>,
        column: Option<u32>,
    ) -> Result<EditorOpened, WsError> {
        let request = WorkspaceRequest::EditorOpen {
            folder,
            path,
            line,
            column,
        };
        expect!(self.workspace(request).await?, WorkspaceResponse::EditorOpened(opened) => opened)
    }

    /// Agent plan usage on the host now, and its changes as [`WorkspaceEvent::AgentUsage`]
    /// until [`Client::usage_unwatch`]. Only for daemons offering
    /// [`DaemonFeatures::AGENT_USAGE`](proto::DaemonFeatures::AGENT_USAGE); older ones drop a
    /// connection that sends it.
    ///
    /// # Errors
    ///
    /// The daemon's [`WsError`] (owners only).
    pub async fn usage_watch(&self) -> Result<AgentUsageReport, WsError> {
        let request = WorkspaceRequest::UsageWatch(proto::UsageWatch {
            api_fallback: false,
        });
        expect!(self.workspace(request).await?, WorkspaceResponse::AgentUsage(usage) => usage)
    }

    /// Stops this connection's usage pushes.
    ///
    /// # Errors
    ///
    /// The daemon's [`WsError`].
    pub async fn usage_unwatch(&self) -> Result<(), WsError> {
        expect!(self.workspace(WorkspaceRequest::UsageUnwatch).await?, WorkspaceResponse::Done => ())
    }

    /// Whether each agent's command is installed on the host, as a pane would find it.
    ///
    /// # Errors
    ///
    /// [`WsError::Unavailable`] without asking when the daemon does not offer
    /// [`DaemonFeatures::AGENT_INSTALLS`](proto::DaemonFeatures::AGENT_INSTALLS) (older
    /// daemons drop a connection that sends the request); else the daemon's error.
    pub async fn agent_installs(&self) -> Result<Vec<proto::AgentInstall>, WsError> {
        if !self.daemon_has(proto::DaemonFeatures::AGENT_INSTALLS) {
            return Err(WsError::Unavailable(
                "the host's helper predates install checks; update it".into(),
            ));
        }
        expect!(self.workspace(WorkspaceRequest::AgentInstalls).await?,
            WorkspaceResponse::AgentInstalls(list) => list)
    }

    /// The commands that add the daemon's MCP server to each installed agent's user-wide
    /// configuration (`register`), or remove it. Nothing runs on the host.
    ///
    /// # Errors
    ///
    /// [`WsError::Unavailable`] without asking when the daemon does not offer
    /// [`DaemonFeatures::AGENT_MCP`](proto::DaemonFeatures::AGENT_MCP); else the daemon's error.
    pub async fn agent_mcp_commands(
        &self,
        register: bool,
    ) -> Result<Vec<proto::AgentMcpCommand>, WsError> {
        if !self.daemon_has(proto::DaemonFeatures::AGENT_MCP) {
            return Err(WsError::Unavailable(
                "the host's helper predates agent tool registration; update it".into(),
            ));
        }
        expect!(self.workspace(WorkspaceRequest::AgentMcpCommands { register }).await?,
            WorkspaceResponse::AgentMcpCommands(list) => list)
    }

    fn accounts_offered(&self) -> Result<(), WsError> {
        if self.daemon_has(proto::DaemonFeatures::ACCOUNTS) {
            Ok(())
        } else {
            Err(WsError::Unavailable(
                "the host's helper predates agent accounts; update it".into(),
            ))
        }
    }

    /// The host's agent accounts.
    ///
    /// # Errors
    ///
    /// [`WsError::Unavailable`] without asking when the daemon does not offer
    /// [`DaemonFeatures::ACCOUNTS`](proto::DaemonFeatures::ACCOUNTS); else the daemon's error
    /// (owners only).
    pub async fn accounts(&self) -> Result<proto::AccountsReport, WsError> {
        self.accounts_offered()?;
        expect!(self.workspace(WorkspaceRequest::Accounts).await?,
            WorkspaceResponse::Accounts(accounts) => accounts)
    }

    /// Makes an account, signed out; sign in with
    /// [`PaneLaunch::AccountSignIn`](proto::PaneLaunch::AccountSignIn).
    ///
    /// # Errors
    ///
    /// As [`Client::accounts`].
    pub async fn account_add(
        &self,
        add: proto::AccountAdd,
    ) -> Result<proto::AgentAccount, WsError> {
        self.accounts_offered()?;
        expect!(self.workspace(WorkspaceRequest::AccountAdd(add)).await?,
            WorkspaceResponse::Account(account) => account)
    }

    /// Renames or recolours an account.
    ///
    /// # Errors
    ///
    /// As [`Client::accounts`].
    pub async fn account_edit(
        &self,
        agent: proto::AgentKind,
        account: String,
        label: String,
        color: u8,
    ) -> Result<proto::AccountsReport, WsError> {
        self.accounts_offered()?;
        let request = WorkspaceRequest::AccountEdit {
            agent,
            account,
            label,
            color,
        };
        expect!(self.workspace(request).await?, WorkspaceResponse::Accounts(accounts) => accounts)
    }

    /// Signs an account out with the agent's own logout and deletes it.
    ///
    /// # Errors
    ///
    /// As [`Client::accounts`]; [`WsError::Conflict`] while agent panes run under it.
    pub async fn account_remove(
        &self,
        agent: proto::AgentKind,
        account: String,
    ) -> Result<proto::AccountsReport, WsError> {
        self.accounts_offered()?;
        expect!(self.workspace(WorkspaceRequest::AccountRemove { agent, account }).await?,
            WorkspaceResponse::Accounts(accounts) => accounts)
    }

    /// Asks the agent whether an account is signed in, and as whom.
    ///
    /// # Errors
    ///
    /// As [`Client::accounts`].
    pub async fn account_check(
        &self,
        agent: proto::AgentKind,
        account: String,
    ) -> Result<proto::AgentAccount, WsError> {
        self.accounts_offered()?;
        expect!(self.workspace(WorkspaceRequest::AccountCheck { agent, account }).await?,
            WorkspaceResponse::Account(account) => account)
    }

    /// Sets or clears an agent's default account on the host (`project` `None`) or in a
    /// project.
    ///
    /// # Errors
    ///
    /// As [`Client::accounts`].
    pub async fn account_set_default(
        &self,
        agent: proto::AgentKind,
        project: Option<String>,
        account: Option<String>,
    ) -> Result<proto::AccountsReport, WsError> {
        self.accounts_offered()?;
        let request = WorkspaceRequest::AccountSetDefault {
            agent,
            project,
            account,
        };
        expect!(self.workspace(request).await?, WorkspaceResponse::Accounts(accounts) => accounts)
    }

    /// The host's VS Code tunnel and `code` CLI.
    pub async fn vscode_tunnel_status(&self) -> Result<VsCodeTunnelStatus, WsError> {
        expect!(self.workspace(WorkspaceRequest::VsCodeTunnelStatus).await?,
            WorkspaceResponse::VsCodeTunnel(status) => status)
    }

    /// Has the daemon download Microsoft's `code` CLI from Microsoft's update service. Show
    /// [`VSCODE_LICENSE_URL`](proto::VSCODE_LICENSE_URL) first; `accept_license` records that
    /// the user accepted it (refused with [`WsError::Denied`] otherwise).
    pub async fn vscode_cli_install(
        &self,
        accept_license: bool,
    ) -> Result<VsCodeTunnelStatus, WsError> {
        let request = WorkspaceRequest::VsCodeCliInstall(VsCodeCliInstall { accept_license });
        expect!(self.workspace(request).await?, WorkspaceResponse::VsCodeTunnel(status) => status)
    }

    /// Starts (or reuses) the host's tunnel. Show
    /// [`VSCODE_SERVER_LICENSE_URL`](proto::VSCODE_SERVER_LICENSE_URL) and the privacy
    /// statement first. A device code to show arrives as [`WorkspaceEvent::VsCodeTunnel`].
    pub async fn vscode_tunnel_start(
        &self,
        start: VsCodeTunnelStart,
    ) -> Result<VsCodeTunnelStatus, WsError> {
        expect!(self.workspace(WorkspaceRequest::VsCodeTunnelStart(start)).await?,
            WorkspaceResponse::VsCodeTunnel(status) => status)
    }

    /// Stops the tunnel the daemon runs.
    pub async fn vscode_tunnel_stop(&self) -> Result<VsCodeTunnelStatus, WsError> {
        expect!(self.workspace(WorkspaceRequest::VsCodeTunnelStop).await?,
            WorkspaceResponse::VsCodeTunnel(status) => status)
    }

    /// The vscode.dev URL and desktop URI for a folder or `path` at a line; opens the file in
    /// an already connected window when there is one.
    pub async fn vscode_tunnel_open(
        &self,
        open: VsCodeTunnelOpen,
    ) -> Result<VsCodeTunnelOpened, WsError> {
        expect!(self.workspace(WorkspaceRequest::VsCodeTunnelOpen(open)).await?,
            WorkspaceResponse::VsCodeTunnelOpened(opened) => opened)
    }

    /// Branch, upstream, ahead/behind and changed files of the repository containing `path`.
    pub async fn git_status(&self, path: String) -> Result<GitStatus, WsError> {
        expect!(self.workspace(WorkspaceRequest::GitStatus { path }).await?,
            WorkspaceResponse::GitStatus(status) => status)
    }

    /// A diff, file by file (renames detected, binaries flagged, large patches capped).
    pub async fn git_diff(&self, request: GitDiffRequest) -> Result<GitDiff, WsError> {
        expect!(self.workspace(WorkspaceRequest::GitDiff(request)).await?,
            WorkspaceResponse::GitDiff(diff) => diff)
    }

    /// The agent turns recorded for a pane.
    pub async fn list_turns(&self, pane_id: PaneId) -> Result<Vec<TurnInfo>, WsError> {
        expect!(self.workspace(WorkspaceRequest::ListTurns { pane_id }).await?,
            WorkspaceResponse::Turns(turns) => turns)
    }

    /// What an agent turn changed (`turn` `None`: the latest).
    pub async fn turn_diff(
        &self,
        pane_id: PaneId,
        turn: Option<u64>,
        context: u32,
        hunks: bool,
    ) -> Result<GitDiff, WsError> {
        let request = WorkspaceRequest::TurnDiff {
            pane_id,
            turn,
            context,
            hunks,
        };
        expect!(self.workspace(request).await?, WorkspaceResponse::GitDiff(diff) => diff)
    }

    /// Formats review notes into a prompt and types it into the agent pane. Returns the
    /// prompt.
    pub async fn send_review(&self, review: ReviewRequest) -> Result<String, WsError> {
        expect!(self.workspace(WorkspaceRequest::SendReview(review)).await?,
            WorkspaceResponse::ReviewSent { prompt } => prompt)
    }

    /// Creates a worktree on a new branch (and allocates its `PORT`).
    pub async fn worktree_create(&self, create: WorktreeCreate) -> Result<WorktreeInfo, WsError> {
        expect!(self.workspace(WorkspaceRequest::WorktreeCreate(create)).await?,
            WorkspaceResponse::Worktree(worktree) => worktree)
    }

    /// The repository's worktrees.
    pub async fn worktree_list(&self, repo: String) -> Result<Vec<WorktreeInfo>, WsError> {
        expect!(self.workspace(WorkspaceRequest::WorktreeList { repo }).await?,
            WorkspaceResponse::Worktrees(worktrees) => worktrees)
    }

    /// Removes a worktree (refused with [`WsError::Conflict`] when dirty, unless `force`).
    pub async fn worktree_remove(
        &self,
        path: String,
        force: bool,
        delete_branch: bool,
    ) -> Result<(), WsError> {
        let request = WorkspaceRequest::WorktreeRemove {
            path,
            force,
            delete_branch,
        };
        expect!(self.workspace(request).await?, WorkspaceResponse::Done => ())
    }

    /// Splits `split_from` and starts a shell or an agent in the worktree, with its `PORT`.
    pub async fn worktree_launch(
        &self,
        path: String,
        split_from: PaneId,
        axis: Axis,
        agent: Option<proto::AgentKind>,
    ) -> Result<PaneId, WsError> {
        let request = WorkspaceRequest::WorktreeLaunch {
            path,
            split_from,
            axis,
            agent,
        };
        expect!(self.workspace(request).await?, WorkspaceResponse::PaneCreated { pane_id } => pane_id)
    }

    /// Lists a directory.
    pub async fn fs_list(&self, path: String, show_hidden: bool) -> Result<DirListing, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsList { path, show_hidden }).await?,
            WorkspaceResponse::Dir(listing) => listing)
    }

    /// `lstat` of a path.
    pub async fn fs_stat(&self, path: String) -> Result<FileStat, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsStat { path }).await?,
            WorkspaceResponse::Stat(stat) => stat)
    }

    /// Reads up to 1 MiB of a file.
    pub async fn fs_read(&self, path: String, offset: u64, len: u32) -> Result<FileChunk, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsRead { path, offset, len }).await?,
            WorkspaceResponse::FileData(chunk) => chunk)
    }

    /// Writes a small file (up to 1 MiB) atomically.
    pub async fn fs_write(&self, target: WriteTarget, data: Vec<u8>) -> Result<FileStat, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsWrite { target, data }).await?,
            WorkspaceResponse::Stat(stat) => stat)
    }

    /// Creates a directory.
    pub async fn fs_mkdir(&self, path: String, parents: bool) -> Result<FileStat, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsMkdir { path, parents }).await?,
            WorkspaceResponse::Stat(stat) => stat)
    }

    /// Renames or moves.
    pub async fn fs_rename(
        &self,
        from: String,
        to: String,
        overwrite: bool,
    ) -> Result<FileStat, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsRename { from, to, overwrite }).await?,
            WorkspaceResponse::Stat(stat) => stat)
    }

    /// Deletes, or moves to the trash.
    pub async fn fs_delete(
        &self,
        path: String,
        mode: DeleteMode,
        recursive: bool,
    ) -> Result<(), WsError> {
        let request = WorkspaceRequest::FsDelete {
            path,
            mode,
            recursive,
        };
        expect!(self.workspace(request).await?, WorkspaceResponse::Done => ())
    }

    /// Watches a directory; changes arrive as [`WorkspaceEvent::FsChanged`]. Watches end with
    /// the connection (set them up again after [`ClientEvent::Connected`](crate::ClientEvent)).
    pub async fn fs_watch(&self, path: String) -> Result<u64, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsWatch { path }).await?,
            WorkspaceResponse::Watching { watch_id } => watch_id)
    }

    /// Stops a watch.
    pub async fn fs_unwatch(&self, watch_id: u64) -> Result<(), WsError> {
        expect!(self.workspace(WorkspaceRequest::FsUnwatch { watch_id }).await?,
            WorkspaceResponse::Done => ())
    }

    /// Uploads a local file to the host over its own stream (bulk priority, flow controlled),
    /// written atomically there.
    pub async fn upload_file(
        &self,
        local_path: String,
        target: WriteTarget,
        progress: Option<Arc<dyn TransferProgress>>,
    ) -> Result<FileStat, WsError> {
        let inner = Arc::clone(&self.inner);
        self.handle
            .spawn(async move {
                let file = tokio::fs::File::open(&local_path)
                    .await
                    .map_err(|err| WsError::NotFound(format!("{local_path}: {err}")))?;
                let size = file.metadata().await.map_err(failed)?.len();
                upload(&inner, file, size, target, progress).await
            })
            .await
            .unwrap_or_else(|err| Err(failed(err)))
    }

    /// Uploads bytes held in memory (see [`upload_file`](Self::upload_file)).
    pub async fn upload_bytes(
        &self,
        data: Vec<u8>,
        target: WriteTarget,
    ) -> Result<FileStat, WsError> {
        let inner = Arc::clone(&self.inner);
        let size = data.len() as u64;
        self.handle
            .spawn(
                async move { upload(&inner, std::io::Cursor::new(data), size, target, None).await },
            )
            .await
            .unwrap_or_else(|err| Err(failed(err)))
    }

    /// Downloads a remote file to `local_path` (written to a temporary file next to it, then
    /// renamed). `len` `None` reads to the end.
    pub async fn download_file(
        &self,
        remote_path: String,
        local_path: String,
        offset: u64,
        len: Option<u64>,
        progress: Option<Arc<dyn TransferProgress>>,
    ) -> Result<FileStat, WsError> {
        let inner = Arc::clone(&self.inner);
        self.handle
            .spawn(async move {
                let header = DownloadHeader {
                    path: remote_path,
                    offset,
                    len,
                };
                download(&inner, header, PathBuf::from(local_path), progress).await
            })
            .await
            .unwrap_or_else(|err| Err(failed(err)))
    }

    /// The attention feed (the inbox) and its unseen count.
    pub async fn attention_list(&self) -> Result<AttentionList, WsError> {
        expect!(self.workspace(WorkspaceRequest::AttentionList).await?,
            WorkspaceResponse::Attention(attention) => attention)
    }

    /// Marks items seen on every device; returns the feed after the change.
    pub async fn attention_seen(&self, seen: AttentionSeen) -> Result<AttentionList, WsError> {
        expect!(self.workspace(WorkspaceRequest::AttentionSeen(seen)).await?,
            WorkspaceResponse::Attention(attention) => attention)
    }

    /// The last repository snapshot the daemon pushed.
    pub fn repos(&self) -> Option<RepoSnapshot> {
        lock(&self.inner.ws.repos).clone()
    }

    /// Re-reads every watched worktree now, and `path`'s pull request (all of them when
    /// `None`).
    pub async fn repo_refresh(&self, path: Option<String>) -> Result<RepoSnapshot, WsError> {
        let snapshot = expect!(self.workspace(WorkspaceRequest::RepoRefresh { path }).await?,
            WorkspaceResponse::Repos(snapshot) => snapshot)?;
        *lock(&self.inner.ws.repos) = Some(snapshot.clone());
        Ok(snapshot)
    }

    /// Merges a worktree's pull request; the pull request after merging.
    pub async fn pr_merge(&self, merge: PrMerge) -> Result<Option<PullRequest>, WsError> {
        expect!(self.workspace(WorkspaceRequest::PrMerge(merge)).await?,
            WorkspaceResponse::Pr(pull_request) => pull_request)
    }

    /// Re-runs the failed jobs of a worktree's pull request.
    pub async fn pr_rerun_failed(&self, path: String) -> Result<Option<PullRequest>, WsError> {
        expect!(self.workspace(WorkspaceRequest::PrRerunFailed { path }).await?,
            WorkspaceResponse::Pr(pull_request) => pull_request)
    }

    /// Pushes the branch and opens a pull request.
    pub async fn pr_create(&self, create: PrCreate) -> Result<Option<PullRequest>, WsError> {
        expect!(self.workspace(WorkspaceRequest::PrCreate(create)).await?,
            WorkspaceResponse::Pr(pull_request) => pull_request)
    }

    /// Checks a pull request out into a new worktree.
    pub async fn pr_checkout(&self, checkout: PrCheckout) -> Result<WorktreeInfo, WsError> {
        expect!(self.workspace(WorkspaceRequest::PrCheckout(checkout)).await?,
            WorkspaceResponse::Worktree(worktree) => worktree)
    }

    /// Archives a worktree (its commits and, with `force`, its changes are kept).
    pub async fn worktree_archive(&self, path: String, force: bool) -> Result<(), WsError> {
        expect!(self.workspace(WorkspaceRequest::WorktreeArchive { path, force }).await?,
            WorkspaceResponse::Done => ())
    }

    /// Archived worktrees, newest first.
    pub async fn worktree_archived(
        &self,
        repo: Option<String>,
    ) -> Result<Vec<ArchivedWorktree>, WsError> {
        expect!(self.workspace(WorkspaceRequest::WorktreeArchived { repo }).await?,
            WorkspaceResponse::Archived(archived) => archived)
    }

    /// Restores an archived worktree.
    pub async fn worktree_restore(&self, id: u64) -> Result<WorktreeInfo, WsError> {
        expect!(self.workspace(WorkspaceRequest::WorktreeRestore { id }).await?,
            WorkspaceResponse::Worktree(worktree) => worktree)
    }

    pub async fn timeline_watch(
        &self,
        pane_id: PaneId,
    ) -> Result<proto::TimelineSnapshot, WsError> {
        self.require_timeline()?;
        let request =
            proto::TimelineVersion::CURRENT.watch_request(pane_id, self.inner.daemon_features());
        expect!(self.workspace(request).await?,
            WorkspaceResponse::Timeline(snapshot) => snapshot)
    }

    pub async fn timeline_unwatch(&self, pane_id: PaneId) -> Result<(), WsError> {
        if !self.daemon_has(proto::DaemonFeatures::AGENT_TIMELINE) {
            return Ok(());
        }
        expect!(self.workspace(WorkspaceRequest::TimelineUnwatch { pane_id }).await?,
            WorkspaceResponse::Done => ())
    }

    pub async fn timeline_items_before(
        &self,
        pane_id: PaneId,
        before: u64,
        limit: u16,
    ) -> Result<proto::TimelineSnapshot, WsError> {
        self.require_timeline()?;
        expect!(self.workspace(WorkspaceRequest::TimelineItemsBefore { pane_id, before, limit }).await?,
            WorkspaceResponse::Timeline(snapshot) => snapshot)
    }

    pub async fn timeline_tool_output(
        &self,
        pane_id: PaneId,
        handle: String,
        offset: u64,
        len: u32,
    ) -> Result<proto::TimelineToolOutput, WsError> {
        self.require_timeline()?;
        expect!(self.workspace(WorkspaceRequest::TimelineToolOutput { pane_id, handle, offset, len }).await?,
            WorkspaceResponse::TimelineOutput(output) => output)
    }

    /// Reads complete bounded changes from one recorded tool result, not the working tree.
    pub async fn timeline_tool_diff(
        &self,
        pane_id: PaneId,
        handle: String,
    ) -> Result<Vec<proto::FileDiff>, WsError> {
        let request = crate::timeline_diff::request(self.inner.daemon_features(), pane_id, handle)?;
        expect!(self.workspace(request).await?,
            WorkspaceResponse::TimelineDiff(files) => files)
    }

    fn require_timeline(&self) -> Result<(), WsError> {
        if self.daemon_has(proto::DaemonFeatures::AGENT_TIMELINE) {
            return Ok(());
        }
        Err(WsError::Unavailable("update the helper to use Chat".into()))
    }

    pub async fn power_settings(
        &self,
        policy: Option<proto::PowerPolicy>,
    ) -> Result<proto::PowerStatus, WsError> {
        if !self.daemon_has(proto::DaemonFeatures::POWER_SETTINGS) {
            return Err(WsError::Unavailable(
                "update the helper to manage its power policy".into(),
            ));
        }
        expect!(self.workspace(WorkspaceRequest::PowerSettings(policy)).await?,
            WorkspaceResponse::PowerStatus(status) => status)
    }

    /// Reads (`None`) or changes the worktree housekeeping.
    pub async fn worktree_settings(
        &self,
        set: Option<WorktreeSettings>,
    ) -> Result<WorktreeSettings, WsError> {
        expect!(self.workspace(WorkspaceRequest::WorktreeSettings(set)).await?,
            WorkspaceResponse::WorktreeSettings(settings) => settings)
    }

    /// A repository's setup and teardown commands and whether the owner trusts them (only
    /// trusted ones run).
    pub async fn repo_hooks(&self, of: RepoHooksFor) -> Result<RepoHooksTrust, WsError> {
        expect!(self.workspace(WorkspaceRequest::RepoHooks(of)).await?,
            WorkspaceResponse::RepoHooks(trust) => trust)
    }

    /// Trusts a repository's commands (`RepoHooksTrust::repo` and `hash`): they run from now
    /// on until they change. Owner devices only.
    pub async fn repo_trust(&self, repo: String, hash: String) -> Result<(), WsError> {
        expect!(self.workspace(WorkspaceRequest::RepoTrust { repo, hash }).await?,
            WorkspaceResponse::Done => ())
    }

    /// A new task: worktree, branch, and a tab with a shell or agent in it.
    pub async fn task_create(&self, task: TaskCreate) -> Result<TaskCreated, WsError> {
        expect!(self.workspace(WorkspaceRequest::TaskCreate(task)).await?,
            WorkspaceResponse::TaskCreated(created) => created)
    }

    /// Runs a script in a new tab; its pane.
    pub async fn script_run(&self, run: ScriptRun) -> Result<PaneId, WsError> {
        expect!(self.workspace(WorkspaceRequest::ScriptRun(run)).await?,
            WorkspaceResponse::PaneCreated { pane_id } => pane_id)
    }

    /// The workflows `pane` can use: its repository's, then the global ones (only the global
    /// ones without a pane).
    ///
    /// # Errors
    ///
    /// [`WsError::Unavailable`] without asking when the daemon does not offer
    /// [`DaemonFeatures::WORKFLOWS`](proto::DaemonFeatures::WORKFLOWS) (older daemons drop a
    /// connection that sends the request); else the daemon's error.
    pub async fn workflow_list(&self, pane: Option<PaneId>) -> Result<WorkflowList, WsError> {
        self.require_workflows()?;
        expect!(self.workspace(WorkspaceRequest::WorkflowList { pane_id: pane }).await?,
            WorkspaceResponse::Workflows(list) => list)
    }

    /// Writes a new workflow file on the host; the workflow as saved.
    ///
    /// # Errors
    ///
    /// As [`workflow_list`](Self::workflow_list).
    pub async fn workflow_save(&self, save: WorkflowSave) -> Result<Workflow, WsError> {
        self.require_workflows()?;
        expect!(self.workspace(WorkspaceRequest::WorkflowSave(save)).await?,
            WorkspaceResponse::WorkflowSaved(workflow) => workflow)
    }

    fn require_workflows(&self) -> Result<(), WsError> {
        if self.daemon_has(proto::DaemonFeatures::WORKFLOWS) {
            Ok(())
        } else {
            Err(WsError::Unavailable(
                "the host's helper predates workflows; update it".into(),
            ))
        }
    }
}

/// The live connection, waiting while the client is between reconnects.
async fn connection(inner: &Inner) -> iroh::endpoint::Connection {
    loop {
        if let Some(conn) = lock(&inner.connection).clone() {
            return conn;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn send_frame<T: serde::Serialize>(
    stream: &mut iroh::endpoint::SendStream,
    msg: &T,
) -> Result<(), WsError> {
    let frame = proto::frame::to_vec(msg).map_err(failed)?;
    stream.write_all(&frame).await.map_err(failed)
}

async fn recv_frame<T: serde::de::DeserializeOwned>(
    stream: &mut iroh::endpoint::RecvStream,
) -> Result<Option<T>, WsError> {
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    match stream.read_exact(&mut prefix).await {
        Ok(()) => {}
        Err(iroh::endpoint::ReadExactError::FinishedEarly(0)) => return Ok(None),
        Err(err) => return Err(failed(err)),
    }
    let len = proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).map_err(failed)?;
    let mut body = vec![0; len];
    stream.read_exact(&mut body).await.map_err(failed)?;
    proto::frame::decode_body(&body).map(Some).map_err(failed)
}

/// Accepts local TCP connections and tunnels each over a forward stream.
async fn serve_forward(inner: Arc<Inner>, listener: StdTcpListener, target: ForwardTarget) {
    let mut listener = match LocalListener::new(listener, inner.resumed.subscribe()) {
        Ok(listener) => listener,
        Err(err) => {
            tracing::warn!("port forward listener: {err}");
            return;
        }
    };
    loop {
        let tcp = listener.accept().await;
        let inner = Arc::clone(&inner);
        let target = target.clone();
        tokio::spawn(async move {
            if let Err(err) = forward_one(&inner, tcp, target).await {
                tracing::debug!("port forward: {err}");
            }
        });
    }
}

async fn forward_one(
    inner: &Inner,
    tcp: tokio::net::TcpStream,
    target: ForwardTarget,
) -> Result<(), WsError> {
    let _ = tcp.set_nodelay(true);
    let (mut tcp_read, mut tcp_write) = tcp.into_split();
    let end = forward_stream(inner, target, &mut tcp_read, &mut tcp_write).await;
    if !matches!(end, Ok(Ended::Clean)) {
        // A reset, not an orderly close: the local client (a browser's websocket) must see
        // the link broke and reconnect, rather than take it for the server's own goodbye.
        if let Ok(tcp) = tcp_read.reunite(tcp_write) {
            let _ = tcp.set_zero_linger();
        }
    }
    end.map(drop)
}

/// How a spliced forward ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ended {
    /// Both sides finished their halves.
    Clean,
    /// The link or a side failed midway.
    Broken,
}

/// How long a new forward connection waits for the link to come back when the connection it
/// found had already died: about VS Code's own wait before it calls a socket dead.
const LINK_WAIT: Duration = Duration::from_secs(20);

/// Opens a forward stream to `target`. A connection that died before the client noticed fails
/// the first try; nothing has flowed yet, so the next live connection gets one more.
async fn open_forward(
    inner: &Inner,
    target: &ForwardTarget,
) -> Result<(iroh::endpoint::SendStream, iroh::endpoint::RecvStream), WsError> {
    let conn = connection(inner).await;
    let first = try_open_forward(&conn, target).await;
    let Err(OpenError::Link(link_error)) = first else {
        return first.map_err(OpenError::into_ws);
    };
    let dead = conn.stable_id();
    let next = tokio::time::timeout(LINK_WAIT, async {
        loop {
            let candidate = connection(inner).await;
            if candidate.stable_id() != dead && candidate.close_reason().is_none() {
                return candidate;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .map_err(|_| link_error)?;
    try_open_forward(&next, target)
        .await
        .map_err(OpenError::into_ws)
}

enum OpenError {
    /// The connection failed (worth one more try on the next).
    Link(WsError),
    /// The daemon answered: no.
    Refused(WsError),
}

impl OpenError {
    fn into_ws(self) -> WsError {
        match self {
            Self::Link(err) | Self::Refused(err) => err,
        }
    }
}

async fn try_open_forward(
    conn: &iroh::endpoint::Connection,
    target: &ForwardTarget,
) -> Result<(iroh::endpoint::SendStream, iroh::endpoint::RecvStream), OpenError> {
    let link = OpenError::Link;
    let (mut send, mut recv) = conn.open_bi().await.map_err(|err| link(failed(err)))?;
    // Below the focused pane (80), above bulk (1).
    let _ = send.set_priority(40);
    let header = StreamHeader::Forward {
        target: target.clone(),
    };
    send_frame(&mut send, &header).await.map_err(link)?;
    match recv_frame::<ForwardReply>(&mut recv).await.map_err(link)? {
        Some(ForwardReply::Connected) => Ok((send, recv)),
        Some(ForwardReply::Refused { reason }) => Err(OpenError::Refused(WsError::Failed(reason))),
        None => Err(link(WsError::Failed("forward stream closed".into()))),
    }
}

/// Opens one forward stream to `target` and copies `tcp_read` into it and it into
/// `tcp_write` until both directions finish.
async fn forward_stream(
    inner: &Inner,
    target: ForwardTarget,
    mut tcp_read: impl tokio::io::AsyncRead + Unpin,
    mut tcp_write: impl tokio::io::AsyncWrite + Unpin,
) -> Result<Ended, WsError> {
    let (mut send, mut recv) = open_forward(inner, &target).await?;
    // Half-close both ways; each direction only reads after the previous write completed, so
    // a slow side throttles the other (QUIC flow control / TCP window). A failure resets the
    // other side instead of finishing it.
    let up = async {
        let mut chunk = vec![0; COPY_CHUNK];
        loop {
            match tcp_read.read(&mut chunk).await {
                Ok(0) => {
                    let _ = send.finish();
                    return Ended::Clean;
                }
                Ok(read) => {
                    if send.write_all(&chunk[..read]).await.is_err() {
                        return Ended::Broken;
                    }
                }
                Err(_) => {
                    let _ = send.reset(1u32.into());
                    return Ended::Broken;
                }
            }
        }
    };
    let down = async {
        let mut chunk = vec![0; COPY_CHUNK];
        loop {
            match recv.read(&mut chunk).await {
                Ok(Some(read)) => {
                    if tcp_write.write_all(&chunk[..read]).await.is_err() {
                        let _ = recv.stop(0u32.into());
                        return Ended::Broken;
                    }
                }
                Ok(None) => {
                    let _ = tcp_write.shutdown().await;
                    return Ended::Clean;
                }
                Err(_) => return Ended::Broken,
            }
        }
    };
    let ended = splice_ends(up, down).await;
    if ended == Ended::Broken {
        let _ = send.reset(1u32.into());
        let _ = recv.stop(0u32.into());
    }
    Ok(ended)
}

/// Runs both directions of a splice: clean once both finished, broken as soon as either broke
/// (the other would wait on its side forever).
async fn splice_ends(
    up: impl std::future::Future<Output = Ended>,
    down: impl std::future::Future<Output = Ended>,
) -> Ended {
    tokio::pin!(up, down);
    let (mut up_done, mut down_done) = (false, false);
    while !(up_done && down_done) {
        let ended = tokio::select! {
            ended = &mut up, if !up_done => { up_done = true; ended }
            ended = &mut down, if !down_done => { down_done = true; ended }
        };
        if ended == Ended::Broken {
            return Ended::Broken;
        }
    }
    Ended::Clean
}

async fn upload(
    inner: &Inner,
    mut source: impl tokio::io::AsyncRead + Unpin,
    size: u64,
    target: WriteTarget,
    progress: Option<Arc<dyn TransferProgress>>,
) -> Result<FileStat, WsError> {
    let conn = connection(inner).await;
    let (mut send, mut recv) = conn.open_bi().await.map_err(failed)?;
    let _ = send.set_priority(1);
    send_frame(
        &mut send,
        &StreamHeader::Upload(UploadHeader { target, size }),
    )
    .await?;
    match recv_frame::<TransferReply>(&mut recv).await? {
        Some(TransferReply::Ready { .. }) => {}
        Some(TransferReply::Failed(err)) => return Err(err),
        other => return Err(WsError::Failed(format!("unexpected reply {other:?}"))),
    }
    let mut chunk = vec![0; COPY_CHUNK];
    let mut done = 0u64;
    while done < size {
        let want = chunk.len().min((size - done) as usize);
        let read = source.read(&mut chunk[..want]).await.map_err(failed)?;
        if read == 0 {
            return Err(WsError::Failed(
                "the local file shrank during the upload".into(),
            ));
        }
        if send.write_all(&chunk[..read]).await.is_err() {
            // The daemon stopped reading: its reply says why.
            break;
        }
        done += read as u64;
        if let Some(progress) = &progress {
            progress.on_progress(done, size);
        }
    }
    let _ = send.finish();
    match recv_frame::<TransferReply>(&mut recv).await? {
        Some(TransferReply::Done(stat)) => Ok(stat),
        Some(TransferReply::Failed(err)) => Err(err),
        other => Err(WsError::Failed(format!("unexpected reply {other:?}"))),
    }
}

async fn download(
    inner: &Inner,
    header: DownloadHeader,
    local_path: PathBuf,
    progress: Option<Arc<dyn TransferProgress>>,
) -> Result<FileStat, WsError> {
    let conn = connection(inner).await;
    let (mut send, mut recv) = conn.open_bi().await.map_err(failed)?;
    let _ = send.set_priority(1);
    send_frame(&mut send, &StreamHeader::Download(header)).await?;
    let _ = send.finish();
    let (stat, len) = match recv_frame::<TransferReply>(&mut recv).await? {
        Some(TransferReply::Ready {
            stat: Some(stat),
            len,
        }) => (stat, len),
        Some(TransferReply::Failed(err)) => return Err(err),
        other => return Err(WsError::Failed(format!("unexpected reply {other:?}"))),
    };
    let name = local_path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let partial_path = local_path.with_file_name(format!(".{name}.download"));
    let mut file = tokio::fs::File::create(&partial_path)
        .await
        .map_err(|err| WsError::Failed(format!("{}: {err}", partial_path.display())))?;
    let mut chunk = vec![0; COPY_CHUNK];
    let mut done = 0u64;
    let result = loop {
        match recv.read(&mut chunk).await {
            Ok(Some(read)) => {
                if let Err(err) = file.write_all(&chunk[..read]).await {
                    break Err(failed(err));
                }
                done += read as u64;
                if let Some(progress) = &progress {
                    progress.on_progress(done, len);
                }
            }
            Ok(None) if done == len => break Ok(()),
            Ok(None) => break Err(WsError::Failed(format!("got {done} of {len} bytes"))),
            Err(err) => break Err(failed(err)),
        }
    };
    let result = match result {
        Ok(()) => match file.sync_all().await {
            Ok(()) => tokio::fs::rename(&partial_path, &local_path)
                .await
                .map_err(failed),
            Err(err) => Err(failed(err)),
        },
        Err(err) => Err(err),
    };
    if result.is_err() {
        let _ = tokio::fs::remove_file(&partial_path).await;
    }
    result.map(|()| stat)
}
