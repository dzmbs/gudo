//! worktrees, files and the attention feed. See `docs/DAEMON.md` §5.
//!
//! [`handle`] answers one [`WorkspaceRequest`]. Blocking work (git, the file system, process
//! tables) runs on `spawn_blocking`; every path goes through [`paths::Policy`] first.

mod attention;
mod editor;
mod files;
mod git;
mod paths;
pub(crate) mod ports;
mod review;
pub(crate) mod turns;
mod watch;
mod worktree;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::{
    AgentKind, AttentionKind, CommandMark, InputPayload, PaneId, PaneLaunch, ServerCtl,
    WorkspaceRequest, WorkspaceResponse, WsError,
};
use tokio::sync::mpsc;

pub(crate) use attention::{Attention, NewItem};
pub(crate) use files::{serve_download, serve_upload};
pub(crate) use paths::Policy;
pub(crate) use watch::Watch;

use crate::config::Config;
use crate::core::{Core, Event, lock};

/// Workspace state owned by the core.
pub(crate) struct Ws {
    pub policy: Policy,
    pub ports: ports::Ports,
    pub attention: Attention,
    pub turns: turns::Turns,
    pub editors: editor::Editors,
    pub worktrees: worktree::Worktrees,
    worktree_root: PathBuf,
}

impl Ws {
    pub fn new(cfg: &Config) -> Self {
        let home = cfg.home();
        Self {
            policy: Policy::new(&home, &cfg.fs_allow),
            ports: ports::Ports::new(),
            attention: Attention::default(),
            turns: turns::Turns::new(),
            editors: editor::Editors::default(),
            worktrees: worktree::Worktrees::load(&cfg.state_dir, cfg.worktree_port_base),
            worktree_root: cfg
                .worktree_root
                .clone()
                .unwrap_or_else(|| home.join(format!(".{}", brand::DIR_NAME)).join("worktrees")),
        }
    }

    pub fn forget_pane(&self, pane: PaneId) {
        self.ports.forget_pane(pane);
        self.turns.forget_pane(pane);
    }
}

/// What a connection lends a request: where its pushes go and its directory watches.
#[derive(Clone)]
pub(crate) struct ConnCtx {
    pub ctl: mpsc::UnboundedSender<ServerCtl>,
    pub watches: Arc<Mutex<HashMap<u64, Watch>>>,
}

/// Runs `f` on the blocking pool.
async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, WsError> + Send + 'static,
) -> Result<T, WsError> {
    tokio::task::spawn_blocking(f)
        .await
        .unwrap_or_else(|e| Err(WsError::Failed(e.to_string())))
}

fn existing_dir(policy: &Policy, raw: &str) -> Result<PathBuf, WsError> {
    let path = policy.resolve_followed(raw)?;
    if path.is_dir() {
        Ok(path)
    } else if path.exists() {
        Ok(path.parent().map_or(path.clone(), Path::to_owned))
    } else {
        Err(WsError::NotFound(path.display().to_string()))
    }
}

static NEXT_WATCH: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// Answers one request.
pub(crate) async fn handle(
    core: &Arc<Core>,
    conn: &ConnCtx,
    req: WorkspaceRequest,
) -> Result<WorkspaceResponse, WsError> {
    use WorkspaceRequest as R;
    use WorkspaceResponse as A;
    let ws = &core.ws;
    let policy = ws.policy.clone();
    match req {
        R::ListPorts => Ok(A::Ports(ports::scan(core).await)),
        R::EditorStatus => Ok(A::Editors(ws.editors.status(&core.cfg).await)),
        R::EditorLaunch(launch) => {
            let folder = existing_dir(&policy, &launch.folder)?;
            let folder = folder.canonicalize().unwrap_or(folder);
            ws.editors
                .launch(&core.cfg, &launch, &folder)
                .await
                .map(A::Editor)
        }
        R::EditorStop { folder } => {
            let folder = policy.resolve(&folder)?;
            let folder = folder.canonicalize().unwrap_or(folder);
            ws.editors.stop(&folder.to_string_lossy()).await?;
            Ok(A::Done)
        }
        R::EditorOpen {
            folder,
            path,
            line,
            column,
        } => {
            let path = policy.resolve_followed(&path)?;
            let path = path.canonicalize().unwrap_or(path);
            let folder = match folder {
                Some(f) => {
                    let f = policy.resolve(&f)?;
                    Some(f.canonicalize().unwrap_or(f).to_string_lossy().into_owned())
                }
                None => None,
            };
            ws.editors
                .open(folder.as_deref(), &path, line, column)
                .await
                .map(A::EditorOpened)
        }
        R::GitStatus { path } => {
            let dir = existing_dir(&policy, &path)?;
            blocking(move || git::status(&dir)).await.map(A::GitStatus)
        }
        R::GitDiff(req) => {
            let dir = existing_dir(&policy, &req.path)?;
            blocking(move || git::diff(&req, &dir))
                .await
                .map(A::GitDiff)
        }
        R::ListTurns { pane_id } => Ok(A::Turns(ws.turns.list(pane_id))),
        R::TurnDiff {
            pane_id,
            turn,
            context,
            hunks,
        } => {
            let core = Arc::clone(core);
            blocking(move || core.ws.turns.diff(pane_id, turn, context, hunks))
                .await
                .map(A::GitDiff)
        }
        R::SendReview(review) => {
            let entry = core
                .pane(review.pane_id)
                .ok_or_else(|| WsError::NotFound(format!("pane {}", review.pane_id)))?;
            if review.notes.is_empty() {
                return Err(WsError::Invalid("no notes".into()));
            }
            let prompt = review::format_prompt(review.preamble.as_deref(), &review.notes);
            let bytes = entry.pane.encode_input(InputPayload::Paste(prompt.clone()));
            entry
                .pane
                .write(bytes)
                .await
                .map_err(|_| WsError::NotFound(format!("pane {} exited", review.pane_id)))?;
            if review.submit {
                // Let the agent's input box take the paste before Enter arrives.
                tokio::time::sleep(Duration::from_millis(80)).await;
                let _ = entry.pane.write(b"\r".to_vec()).await;
            }
            Ok(A::ReviewSent { prompt })
        }
        R::WorktreeCreate(mut create) => {
            let repo = existing_dir(&policy, &create.repo)?;
            create.repo = repo.to_string_lossy().into_owned();
            if let Some(p) = &create.path {
                create.path = Some(policy.resolve(p)?.to_string_lossy().into_owned());
            }
            let core2 = Arc::clone(core);
            let root = ws.worktree_root.clone();
            blocking(move || core2.ws.worktrees.create(&create, &root))
                .await
                .map(A::Worktree)
        }
        R::WorktreeList { repo } => {
            let dir = existing_dir(&policy, &repo)?;
            let core2 = Arc::clone(core);
            blocking(move || core2.ws.worktrees.list(&dir))
                .await
                .map(A::Worktrees)
        }
        R::WorktreeRemove {
            path,
            force,
            delete_branch,
        } => {
            let path = policy.resolve(&path)?;
            let core2 = Arc::clone(core);
            blocking(move || core2.ws.worktrees.remove(&path, force, delete_branch)).await?;
            Ok(A::Done)
        }
        R::WorktreeLaunch {
            path,
            split_from,
            axis,
            agent,
        } => {
            let dir = existing_dir(&policy, &path)?;
            let cwd = Some(dir.to_string_lossy().into_owned());
            // Make sure the worktree has its port even if it was created outside the daemon.
            ws.worktrees.allocate(&dir);
            let launch = match agent {
                Some(agent) => PaneLaunch::Agent {
                    agent,
                    resume: None,
                    cwd,
                },
                None => PaneLaunch::Shell { cwd },
            };
            match core.apply_op(proto::LayoutOp::Split {
                pane_id: split_from,
                axis,
                launch,
            }) {
                proto::OpOutcome::PaneCreated { pane_id } => Ok(A::PaneCreated { pane_id }),
                proto::OpOutcome::Failed { message, .. } => Err(WsError::Failed(message)),
                other => Err(WsError::Failed(format!("unexpected outcome {other:?}"))),
            }
        }
        R::FsList { path, show_hidden } => {
            blocking(move || files::list(&policy, &path, show_hidden))
                .await
                .map(A::Dir)
        }
        R::FsStat { path } => blocking(move || files::stat(&policy.resolve(&path)?))
            .await
            .map(A::Stat),
        R::FsRead { path, offset, len } => {
            blocking(move || files::read(&policy, &path, offset, len))
                .await
                .map(A::FileData)
        }
        R::FsWrite { target, data } => {
            blocking(move || files::write_small(&policy, &target, &data))
                .await
                .map(A::Stat)
        }
        R::FsMkdir { path, parents } => blocking(move || files::mkdir(&policy, &path, parents))
            .await
            .map(A::Stat),
        R::FsRename {
            from,
            to,
            overwrite,
        } => blocking(move || files::rename(&policy, &from, &to, overwrite))
            .await
            .map(A::Stat),
        R::FsDelete {
            path,
            mode,
            recursive,
        } => {
            blocking(move || files::delete(&policy, &path, mode, recursive)).await?;
            Ok(A::Done)
        }
        R::FsWatch { path } => {
            let dir = policy.resolve_followed(&path)?;
            let watch_id = NEXT_WATCH.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let watch = watch::start(&dir, watch_id, conn.ctl.clone())?;
            lock(&conn.watches).insert(watch_id, watch);
            Ok(A::Watching { watch_id })
        }
        R::FsUnwatch { watch_id } => lock(&conn.watches)
            .remove(&watch_id)
            .map(|_| A::Done)
            .ok_or_else(|| WsError::NotFound(format!("watch {watch_id}"))),
        R::AttentionList => Ok(A::Attention(ws.attention.list())),
        R::AttentionSeen(seen) => {
            if let Some(update) = ws.attention.mark(&seen) {
                core.emit(Event::Attention(update));
            }
            Ok(A::Attention(ws.attention.list()))
        }
    }
}

// --- hooks from the rest of the daemon ------------------------------------------------------

/// A long command finished unseen.
pub(crate) fn command_unseen(core: &Core, mark: &CommandMark) {
    let duration = mark.finished.map_or(0, |f| f.duration_ms) / 1000;
    let status = match mark.finished.and_then(|f| f.exit) {
        Some(0) => "succeeded".to_owned(),
        Some(code) => format!("failed ({code})"),
        None => "finished".to_owned(),
    };
    let command = mark.command.clone().unwrap_or_else(|| "command".into());
    let update = core.ws.attention.add(NewItem {
        pane_id: mark.pane_id,
        session_id: lock(&core.layout).session_of_pane(mark.pane_id),
        kind: AttentionKind::CommandFinished(mark.clone()),
        title: format!("{command} {status}"),
        body: format!("after {duration} s"),
        while_viewed: false,
    });
    core.emit(Event::Attention(update));
}

/// What an agent's arbiter asked to notify about.
pub(crate) enum AgentNotice {
    Blocked {
        request_id: Option<proto::RequestId>,
        summary: String,
    },
    Done {
        message: Option<String>,
    },
    Failed {
        message: Option<String>,
    },
}

pub(crate) fn agent_notice(core: &Core, pane: PaneId, agent: AgentKind, notice: AgentNotice) {
    let name = match agent {
        AgentKind::Claude => "claude",
        AgentKind::Codex => "codex",
    }
    .to_owned();
    let (kind, title, body) = match notice {
        AgentNotice::Blocked {
            request_id,
            summary,
        } => (
            AttentionKind::AgentBlocked {
                agent: name.clone(),
                request_id,
            },
            format!("{name} needs you"),
            summary,
        ),
        AgentNotice::Done { message } => (
            AttentionKind::AgentDone {
                agent: name.clone(),
            },
            format!("{name} finished"),
            message.unwrap_or_default(),
        ),
        AgentNotice::Failed { message } => (
            AttentionKind::AgentFailed {
                agent: name.clone(),
            },
            format!("{name} failed"),
            message.unwrap_or_default(),
        ),
    };
    let update = core.ws.attention.add(NewItem {
        pane_id: pane,
        session_id: lock(&core.layout).session_of_pane(pane),
        kind,
        title,
        body: body.chars().take(500).collect(),
        while_viewed: core.pane_seen(pane),
    });
    core.emit(Event::Attention(update));
}

/// The agent left the blocked state: its blocked items are no longer actionable.
pub(crate) fn agent_unblocked(core: &Core, pane: PaneId) {
    if let Some(update) = core.ws.attention.resolve_blocked(pane) {
        core.emit(Event::Attention(update));
    }
}

/// A client focused a pane: its items count as seen everywhere.
pub(crate) fn pane_focused(core: &Core, pane: PaneId) {
    let seen = proto::AttentionSeen {
        ids: Vec::new(),
        up_to: None,
        pane_id: Some(pane),
    };
    if let Some(update) = core.ws.attention.mark(&seen) {
        core.emit(Event::Attention(update));
    }
}
