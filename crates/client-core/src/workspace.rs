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
    AttentionList, AttentionSeen, AttentionUpdate, Axis, DeleteMode, DirListing, DownloadHeader,
    EditorInstance, EditorLaunch, EditorList, EditorOpened, FileChunk, FileStat, ForwardReply,
    ForwardTarget, FsChange, GitDiff, GitDiffRequest, GitStatus, PaneId, PortInfo, ReviewRequest,
    ServerCtl, StreamHeader, TransferReply, TurnInfo, UploadHeader, VsCodeCliInstall,
    VsCodeTunnelOpen, VsCodeTunnelOpened, VsCodeTunnelStart, VsCodeTunnelStatus, WorkspaceRequest,
    WorkspaceResponse, WorktreeCreate, WorktreeInfo, WriteTarget, WsError,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot};
use tokio::task::AbortHandle;

use crate::{Client, ClientError, Inner, lock};

/// How long a request waits for its answer (a large diff or a first editor start can take a
/// while; `code serve-web` downloads its server on first use).
const REQUEST_TIMEOUT: Duration = Duration::from_secs(300);
/// Copy buffer for forwards and transfers.
const BUF: usize = 64 << 10;

/// A push from the daemon about the workspace.
#[derive(Debug, Clone)]
pub enum WorkspaceEvent {
    /// The listening ports in panes (the whole list).
    PortsChanged {
        /// Every detected port.
        ports: Vec<PortInfo>,
    },
    /// A watched directory changed ([`Client::fs_watch`]).
    FsChanged {
        /// What changed.
        change: FsChange,
    },
    /// The attention feed changed.
    Attention {
        /// The change.
        update: AttentionUpdate,
    },
    /// The host's VS Code tunnel changed state: show a device code
    /// ([`TunnelState::NeedsLogin`](proto::TunnelState::NeedsLogin)), connected, failed.
    VsCodeTunnel {
        /// The whole status.
        status: VsCodeTunnelStatus,
    },
}

/// Receives [`WorkspaceEvent`]s. Must return quickly; it runs on the network threads.
pub trait WorkspaceListener: Send + Sync {
    /// Called once per event, in order.
    fn on_workspace_event(&self, event: WorkspaceEvent);
}

/// A [`WorkspaceListener`] that queues events for async Rust consumers (the `un` CLI, tests).
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
            other => return Some(other),
        };
        let listener = lock(&self.listener).clone();
        if let Some(l) = listener {
            l.on_workspace_event(event);
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

fn failed(e: impl std::fmt::Display) -> WsError {
    WsError::Failed(e.to_string())
}

macro_rules! expect {
    ($resp:expr, $pat:pat => $out:expr) => {
        match $resp {
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
    pub async fn workspace(&self, req: WorkspaceRequest) -> Result<WorkspaceResponse, WsError> {
        let req_id = self
            .inner
            .next_op
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        lock(&self.inner.ws.pending).insert(req_id, tx);
        self.inner.send(proto::ClientCtl::Workspace { req_id, req });
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

    // --- ports and forwards ---------------------------------------------------------------

    /// Listening ports in the daemon's panes, scanned now.
    pub async fn list_ports(&self) -> Result<Vec<PortInfo>, WsError> {
        let ports = expect!(self.workspace(WorkspaceRequest::ListPorts).await?,
            WorkspaceResponse::Ports(p) => p)?;
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
            .spawn(async move { forward_stream(&inner, target, reader, writer).await })
            .await
            .unwrap_or(Err(WsError::Disconnected))
    }

    /// Forwards started with [`forward`](Self::forward): `(local port, target)`.
    pub fn forwards(&self) -> Vec<(u16, ForwardTarget)> {
        lock(&self.inner.ws.forwards)
            .iter()
            .map(|(&p, (t, _))| (p, t.clone()))
            .collect()
    }

    // --- editor ---------------------------------------------------------------------------

    /// Editors the host can run, and the running ones.
    pub async fn editor_status(&self) -> Result<EditorList, WsError> {
        expect!(self.workspace(WorkspaceRequest::EditorStatus).await?,
            WorkspaceResponse::Editors(e) => e)
    }

    /// Starts (or reuses) the editor server for a folder. Open
    /// `http://localhost:<port><url_path>` through [`forward`](Self::forward).
    pub async fn editor_launch(&self, launch: EditorLaunch) -> Result<EditorInstance, WsError> {
        expect!(self.workspace(WorkspaceRequest::EditorLaunch(launch)).await?,
            WorkspaceResponse::Editor(e) => e)
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
        let req = WorkspaceRequest::EditorOpen {
            folder,
            path,
            line,
            column,
        };
        expect!(self.workspace(req).await?, WorkspaceResponse::EditorOpened(o) => o)
    }


    /// The host's VS Code tunnel and `code` CLI.
    pub async fn vscode_tunnel_status(&self) -> Result<VsCodeTunnelStatus, WsError> {
        expect!(self.workspace(WorkspaceRequest::VsCodeTunnelStatus).await?,
            WorkspaceResponse::VsCodeTunnel(s) => s)
    }

    /// Has the daemon download Microsoft's `code` CLI from Microsoft's update service. Show
    /// [`VSCODE_LICENSE_URL`](proto::VSCODE_LICENSE_URL) first; `accept_license` records that
    /// the user accepted it (refused with [`WsError::Denied`] otherwise).
    pub async fn vscode_cli_install(
        &self,
        accept_license: bool,
    ) -> Result<VsCodeTunnelStatus, WsError> {
        let req = WorkspaceRequest::VsCodeCliInstall(VsCodeCliInstall { accept_license });
        expect!(self.workspace(req).await?, WorkspaceResponse::VsCodeTunnel(s) => s)
    }

    /// Starts (or reuses) the host's tunnel. Show
    /// [`VSCODE_SERVER_LICENSE_URL`](proto::VSCODE_SERVER_LICENSE_URL) and the privacy
    /// statement first. A device code to show arrives as [`WorkspaceEvent::VsCodeTunnel`].
    pub async fn vscode_tunnel_start(
        &self,
        start: VsCodeTunnelStart,
    ) -> Result<VsCodeTunnelStatus, WsError> {
        expect!(self.workspace(WorkspaceRequest::VsCodeTunnelStart(start)).await?,
            WorkspaceResponse::VsCodeTunnel(s) => s)
    }

    /// Stops the tunnel the daemon runs.
    pub async fn vscode_tunnel_stop(&self) -> Result<VsCodeTunnelStatus, WsError> {
        expect!(self.workspace(WorkspaceRequest::VsCodeTunnelStop).await?,
            WorkspaceResponse::VsCodeTunnel(s) => s)
    }

    /// The vscode.dev URL and desktop URI for a folder or `path` at a line; opens the file in
    /// an already connected window when there is one.
    pub async fn vscode_tunnel_open(
        &self,
        open: VsCodeTunnelOpen,
    ) -> Result<VsCodeTunnelOpened, WsError> {
        expect!(self.workspace(WorkspaceRequest::VsCodeTunnelOpen(open)).await?,
            WorkspaceResponse::VsCodeTunnelOpened(o) => o)
    }

    // --- git ------------------------------------------------------------------------------

    /// Branch, upstream, ahead/behind and changed files of the repository containing `path`.
    pub async fn git_status(&self, path: String) -> Result<GitStatus, WsError> {
        expect!(self.workspace(WorkspaceRequest::GitStatus { path }).await?,
            WorkspaceResponse::GitStatus(s) => s)
    }

    /// A diff, file by file (renames detected, binaries flagged, large patches capped).
    pub async fn git_diff(&self, req: GitDiffRequest) -> Result<GitDiff, WsError> {
        expect!(self.workspace(WorkspaceRequest::GitDiff(req)).await?,
            WorkspaceResponse::GitDiff(d) => d)
    }

    /// The agent turns recorded for a pane.
    pub async fn list_turns(&self, pane_id: PaneId) -> Result<Vec<TurnInfo>, WsError> {
        expect!(self.workspace(WorkspaceRequest::ListTurns { pane_id }).await?,
            WorkspaceResponse::Turns(t) => t)
    }

    /// What an agent turn changed (`turn` `None`: the latest).
    pub async fn turn_diff(
        &self,
        pane_id: PaneId,
        turn: Option<u64>,
        context: u32,
        hunks: bool,
    ) -> Result<GitDiff, WsError> {
        let req = WorkspaceRequest::TurnDiff {
            pane_id,
            turn,
            context,
            hunks,
        };
        expect!(self.workspace(req).await?, WorkspaceResponse::GitDiff(d) => d)
    }

    /// Formats review notes into a prompt and types it into the agent pane. Returns the
    /// prompt.
    pub async fn send_review(&self, review: ReviewRequest) -> Result<String, WsError> {
        expect!(self.workspace(WorkspaceRequest::SendReview(review)).await?,
            WorkspaceResponse::ReviewSent { prompt } => prompt)
    }

    // --- worktrees ------------------------------------------------------------------------

    /// Creates a worktree on a new branch (and allocates its `PORT`).
    pub async fn worktree_create(&self, create: WorktreeCreate) -> Result<WorktreeInfo, WsError> {
        expect!(self.workspace(WorkspaceRequest::WorktreeCreate(create)).await?,
            WorkspaceResponse::Worktree(w) => w)
    }

    /// The repository's worktrees.
    pub async fn worktree_list(&self, repo: String) -> Result<Vec<WorktreeInfo>, WsError> {
        expect!(self.workspace(WorkspaceRequest::WorktreeList { repo }).await?,
            WorkspaceResponse::Worktrees(w) => w)
    }

    /// Removes a worktree (refused with [`WsError::Conflict`] when dirty, unless `force`).
    pub async fn worktree_remove(
        &self,
        path: String,
        force: bool,
        delete_branch: bool,
    ) -> Result<(), WsError> {
        let req = WorkspaceRequest::WorktreeRemove {
            path,
            force,
            delete_branch,
        };
        expect!(self.workspace(req).await?, WorkspaceResponse::Done => ())
    }

    /// Splits `split_from` and starts a shell or an agent in the worktree, with its `PORT`.
    pub async fn worktree_launch(
        &self,
        path: String,
        split_from: PaneId,
        axis: Axis,
        agent: Option<proto::AgentKind>,
    ) -> Result<PaneId, WsError> {
        let req = WorkspaceRequest::WorktreeLaunch {
            path,
            split_from,
            axis,
            agent,
        };
        expect!(self.workspace(req).await?, WorkspaceResponse::PaneCreated { pane_id } => pane_id)
    }

    // --- files ----------------------------------------------------------------------------

    /// Lists a directory.
    pub async fn fs_list(&self, path: String, show_hidden: bool) -> Result<DirListing, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsList { path, show_hidden }).await?,
            WorkspaceResponse::Dir(d) => d)
    }

    /// `lstat` of a path.
    pub async fn fs_stat(&self, path: String) -> Result<FileStat, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsStat { path }).await?,
            WorkspaceResponse::Stat(s) => s)
    }

    /// Reads up to 1 MiB of a file.
    pub async fn fs_read(&self, path: String, offset: u64, len: u32) -> Result<FileChunk, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsRead { path, offset, len }).await?,
            WorkspaceResponse::FileData(c) => c)
    }

    /// Writes a small file (up to 1 MiB) atomically.
    pub async fn fs_write(&self, target: WriteTarget, data: Vec<u8>) -> Result<FileStat, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsWrite { target, data }).await?,
            WorkspaceResponse::Stat(s) => s)
    }

    /// Creates a directory.
    pub async fn fs_mkdir(&self, path: String, parents: bool) -> Result<FileStat, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsMkdir { path, parents }).await?,
            WorkspaceResponse::Stat(s) => s)
    }

    /// Renames or moves.
    pub async fn fs_rename(
        &self,
        from: String,
        to: String,
        overwrite: bool,
    ) -> Result<FileStat, WsError> {
        expect!(self.workspace(WorkspaceRequest::FsRename { from, to, overwrite }).await?,
            WorkspaceResponse::Stat(s) => s)
    }

    /// Deletes, or moves to the trash.
    pub async fn fs_delete(
        &self,
        path: String,
        mode: DeleteMode,
        recursive: bool,
    ) -> Result<(), WsError> {
        let req = WorkspaceRequest::FsDelete {
            path,
            mode,
            recursive,
        };
        expect!(self.workspace(req).await?, WorkspaceResponse::Done => ())
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
                    .map_err(|e| WsError::NotFound(format!("{local_path}: {e}")))?;
                let size = file.metadata().await.map_err(failed)?.len();
                upload(&inner, file, size, target, progress).await
            })
            .await
            .unwrap_or_else(|e| Err(failed(e)))
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
            .unwrap_or_else(|e| Err(failed(e)))
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
            .unwrap_or_else(|e| Err(failed(e)))
    }

    // --- attention ------------------------------------------------------------------------

    /// The attention feed (the inbox) and its unseen count.
    pub async fn attention_list(&self) -> Result<AttentionList, WsError> {
        expect!(self.workspace(WorkspaceRequest::AttentionList).await?,
            WorkspaceResponse::Attention(a) => a)
    }

    /// Marks items seen on every device; returns the feed after the change.
    pub async fn attention_seen(&self, seen: AttentionSeen) -> Result<AttentionList, WsError> {
        expect!(self.workspace(WorkspaceRequest::AttentionSeen(seen)).await?,
            WorkspaceResponse::Attention(a) => a)
    }
}

// --- streams --------------------------------------------------------------------------------

/// The live connection, waiting while the client is between reconnects.
async fn connection(inner: &Inner) -> iroh::endpoint::Connection {
    loop {
        if let Some(c) = lock(&inner.connection).clone() {
            return c;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn send_frame<T: serde::Serialize>(
    stream: &mut iroh::endpoint::SendStream,
    msg: &T,
) -> Result<(), WsError> {
    let buf = proto::frame::to_vec(msg).map_err(failed)?;
    stream.write_all(&buf).await.map_err(failed)
}

async fn recv_frame<T: serde::de::DeserializeOwned>(
    stream: &mut iroh::endpoint::RecvStream,
) -> Result<Option<T>, WsError> {
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    match stream.read_exact(&mut prefix).await {
        Ok(()) => {}
        Err(iroh::endpoint::ReadExactError::FinishedEarly(0)) => return Ok(None),
        Err(e) => return Err(failed(e)),
    }
    let len = proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).map_err(failed)?;
    let mut body = vec![0; len];
    stream.read_exact(&mut body).await.map_err(failed)?;
    proto::frame::decode_body(&body).map(Some).map_err(failed)
}

/// Accepts local TCP connections and tunnels each over a forward stream.
async fn serve_forward(inner: Arc<Inner>, listener: StdTcpListener, target: ForwardTarget) {
    let listener = match tokio::net::TcpListener::from_std(listener) {
        Ok(l) => l,
        Err(e) => {
            tracing::warn!("port forward listener: {e}");
            return;
        }
    };
    loop {
        let tcp = match listener.accept().await {
            Ok((tcp, _)) => tcp,
            Err(e) => {
                // Out of file descriptors and the like: back off instead of spinning.
                tracing::debug!("forward accept: {e}");
                tokio::time::sleep(Duration::from_millis(50)).await;
                continue;
            }
        };
        let inner = Arc::clone(&inner);
        let target = target.clone();
        tokio::spawn(async move {
            if let Err(e) = forward_one(&inner, tcp, target).await {
                tracing::debug!("port forward: {e}");
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
    let (tcp_r, tcp_w) = tcp.into_split();
    forward_stream(inner, target, tcp_r, tcp_w).await
}

/// Opens one forward stream to `target` and copies `tcp_r` into it and it into `tcp_w`
/// until both directions finish.
async fn forward_stream(
    inner: &Inner,
    target: ForwardTarget,
    mut tcp_r: impl tokio::io::AsyncRead + Unpin,
    mut tcp_w: impl tokio::io::AsyncWrite + Unpin,
) -> Result<(), WsError> {
    let conn = connection(inner).await;
    let (mut send, mut recv) = conn.open_bi().await.map_err(failed)?;
    let _ = send.set_priority(40);
    send_frame(&mut send, &StreamHeader::Forward { target }).await?;
    match recv_frame::<ForwardReply>(&mut recv).await? {
        Some(ForwardReply::Connected) => {}
        Some(ForwardReply::Refused { reason }) => return Err(WsError::Failed(reason)),
        None => return Err(WsError::Failed("forward stream closed".into())),
    }
    // Half-close both ways; each direction only reads after the previous write completed, so
    // a slow side throttles the other (QUIC flow control / TCP window).
    let up = async {
        let mut buf = vec![0; BUF];
        loop {
            match tcp_r.read(&mut buf).await {
                Ok(0) => {
                    let _ = send.finish();
                    break;
                }
                Ok(n) => {
                    if send.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                Err(_) => {
                    let _ = send.reset(1u32.into());
                    break;
                }
            }
        }
    };
    let down = async {
        let mut buf = vec![0; BUF];
        while let Ok(Some(n)) = recv.read(&mut buf).await {
            if tcp_w.write_all(&buf[..n]).await.is_err() {
                let _ = recv.stop(0u32.into());
                break;
            }
        }
        let _ = tcp_w.shutdown().await;
    };
    tokio::join!(up, down);
    Ok(())
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
        Some(TransferReply::Failed(e)) => return Err(e),
        other => return Err(WsError::Failed(format!("unexpected reply {other:?}"))),
    }
    let mut buf = vec![0; BUF];
    let mut done = 0u64;
    while done < size {
        let want = buf.len().min((size - done) as usize);
        let n = source.read(&mut buf[..want]).await.map_err(failed)?;
        if n == 0 {
            return Err(WsError::Failed(
                "the local file shrank during the upload".into(),
            ));
        }
        if send.write_all(&buf[..n]).await.is_err() {
            // The daemon stopped reading: its reply says why.
            break;
        }
        done += n as u64;
        if let Some(p) = &progress {
            p.on_progress(done, size);
        }
    }
    let _ = send.finish();
    match recv_frame::<TransferReply>(&mut recv).await? {
        Some(TransferReply::Done(stat)) => Ok(stat),
        Some(TransferReply::Failed(e)) => Err(e),
        other => Err(WsError::Failed(format!("unexpected reply {other:?}"))),
    }
}

async fn download(
    inner: &Inner,
    header: DownloadHeader,
    local: PathBuf,
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
        Some(TransferReply::Failed(e)) => return Err(e),
        other => return Err(WsError::Failed(format!("unexpected reply {other:?}"))),
    };
    let name = local
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let tmp = local.with_file_name(format!(".{name}.download"));
    let mut file = tokio::fs::File::create(&tmp)
        .await
        .map_err(|e| WsError::Failed(format!("{}: {e}", tmp.display())))?;
    let mut buf = vec![0; BUF];
    let mut done = 0u64;
    let result = loop {
        match recv.read(&mut buf).await {
            Ok(Some(n)) => {
                if let Err(e) = file.write_all(&buf[..n]).await {
                    break Err(failed(e));
                }
                done += n as u64;
                if let Some(p) = &progress {
                    p.on_progress(done, len);
                }
            }
            Ok(None) if done == len => break Ok(()),
            Ok(None) => break Err(WsError::Failed(format!("got {done} of {len} bytes"))),
            Err(e) => break Err(failed(e)),
        }
    };
    let result = match result {
        Ok(()) => match file.sync_all().await {
            Ok(()) => tokio::fs::rename(&tmp, &local).await.map_err(failed),
            Err(e) => Err(failed(e)),
        },
        Err(e) => Err(e),
    };
    if result.is_err() {
        let _ = tokio::fs::remove_file(&tmp).await;
    }
    result.map(|()| stat)
}
