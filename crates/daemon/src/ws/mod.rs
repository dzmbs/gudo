//! worktrees, files and the attention feed. See `docs/DAEMON.md` §5.
//!
//! [`handle`] answers one [`WorkspaceRequest`]. Blocking work (git, the file system, process
//! tables) runs on `spawn_blocking`; every path goes through [`paths::Policy`] first.

mod attention;
mod editor;
mod files;
mod gh;
pub(crate) mod git;
mod paths;
pub(crate) mod ports;
pub(crate) mod repo;
mod repo_ops;
mod review;
pub(crate) mod tunnel;
pub(crate) mod turns;
mod watch;
mod worktree;

pub(crate) use tunnel::DEFAULT_UPDATE_URL as VSCODE_UPDATE_URL;

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
    pub tunnel: tunnel::Tunnel,
    pub worktrees: worktree::Worktrees,
    /// The git-native workspace: repositories of panes, pull requests, scripts.
    pub repos: repo::Repos,
    worktree_root: PathBuf,
    pub usage: Arc<crate::usage::Usage>,
}

impl Ws {
    pub fn new(cfg: &Config, events: tokio::sync::broadcast::Sender<Event>) -> Self {
        let home = cfg.home();
        Self {
            policy: Policy::new(&home, &cfg.fs_allow),
            ports: ports::Ports::new(),
            attention: Attention::default(),
            turns: turns::Turns::new(),
            editors: editor::Editors::default(),
            tunnel: tunnel::Tunnel::new(events),
            worktrees: worktree::Worktrees::load(&cfg.state_dir, cfg.worktree_port_base),
            repos: repo::Repos::new(),
            worktree_root: cfg
                .worktree_root
                .clone()
                .unwrap_or_else(|| home.join(format!(".{}", brand::DIR_NAME)).join("worktrees")),
            usage: Arc::new(crate::usage::Usage::new(cfg)),
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
    /// Who is asking (push registration and notification actions are per device).
    pub actor: proto::Actor,
    /// The client's optional features (`Caps::AGENT_USAGE` takes usage pushes).
    pub caps: proto::Caps,
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

/// The folder to open a file in: the enclosing git work tree, else the file's directory.
fn workspace_folder(file: &Path) -> PathBuf {
    let dir = file.parent().unwrap_or(file);
    dir.ancestors()
        .find(|d| d.join(".git").exists())
        .unwrap_or(dir)
        .to_owned()
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
            let made = blocking(move || core2.ws.worktrees.create(&create, &root)).await;
            ws.repos.relist();
            made.map(A::Worktree)
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
            blocking(move || {
                let (_, hooks) = repo::read_config(&path, None);
                core2
                    .ws
                    .worktrees
                    .remove(&path, force, delete_branch, hooks.teardown.as_deref())
            })
            .await?;
            ws.repos.relist();
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
        R::VsCodeTunnelStatus => Ok(A::VsCodeTunnel(ws.tunnel.status(&core.cfg).await)),
        R::VsCodeCliInstall(install) => {
            if !install.accept_license {
                return Err(WsError::Denied(format!(
                    "installing the VS Code CLI needs Microsoft's licence accepted ({})",
                    proto::VSCODE_LICENSE_URL
                )));
            }
            ws.tunnel.install_cli(&core.cfg).await.map(A::VsCodeTunnel)
        }
        R::VsCodeTunnelStart(start) => {
            if !start.accept_server_license {
                return Err(WsError::Denied(format!(
                    "the VS Code tunnel needs the VS Code Server licence accepted ({})",
                    proto::VSCODE_SERVER_LICENSE_URL
                )));
            }
            ws.tunnel
                .start(&core.cfg, &start)
                .await
                .map(A::VsCodeTunnel)
        }
        R::VsCodeTunnelStop => ws.tunnel.stop(&core.cfg).await.map(A::VsCodeTunnel),
        R::VsCodeTunnelOpen(open) => {
            let path = policy.resolve_followed(&open.path)?;
            let path = path.canonicalize().unwrap_or(path);
            if !path.exists() {
                return Err(WsError::NotFound(path.display().to_string()));
            }
            let folder = match &open.folder {
                Some(f) => {
                    let f = policy.resolve_followed(f)?;
                    f.canonicalize().unwrap_or(f)
                }
                None if path.is_dir() => path.clone(),
                None => workspace_folder(&path),
            };
            ws.tunnel
                .open(&folder, &path, open.line, open.column)
                .await
                .map(A::VsCodeTunnelOpened)
        }
        R::PushRegister(reg) => Ok(A::Push(crate::notifier::register(core, conn.actor, reg)?)),
        R::PushUnregister => Ok(A::Push(crate::notifier::unregister(core, conn.actor))),
        R::PushStatus => Ok(A::Push(crate::notifier::status(core, conn.actor.device))),
        R::PushAction(action) => {
            crate::notifier::action(core, conn.actor, &action).map(A::PushDecided)
        }
        R::RepoRefresh { .. }
        | R::PrMerge(_)
        | R::PrRerunFailed { .. }
        | R::PrCreate(_)
        | R::PrCheckout(_)
        | R::WorktreeArchive { .. }
        | R::WorktreeArchived { .. }
        | R::WorktreeRestore { .. }
        | R::WorktreeSettings(_)
        | R::TaskCreate(_)
        | R::ScriptRun(_) => {
            let root = ws.worktree_root.clone();
            repo_ops::handle(core, &policy, &root, req).await
        }
        R::AttentionList => Ok(A::Attention(ws.attention.list())),
        R::AttentionSeen(seen) => {
            if let Some(update) = ws.attention.mark(&seen) {
                core.emit(Event::Attention(update));
            }
            Ok(A::Attention(ws.attention.list()))
        }
        R::UsageWatch(opts) => Ok(A::AgentUsage(
            ws.usage.watch(&conn.ctl, conn.caps, opts).await,
        )),
        R::UsageUnwatch => {
            ws.usage.unwatch(&conn.ctl);
            Ok(A::Done)
        }
    }
}

// --- hooks from the rest of the daemon ------------------------------------------------------

/// A long command finished unseen. The body says how long it ran and ends with its last line
/// of output, the line that usually says what happened.
pub(crate) fn command_unseen(core: &Core, mark: &CommandMark) {
    let duration = mark.finished.map_or(0, |f| f.duration_ms) / 1000;
    let status = match mark.finished.and_then(|f| f.exit) {
        Some(0) => "succeeded".to_owned(),
        Some(code) => format!("failed ({code})"),
        None => "finished".to_owned(),
    };
    let command = mark.command.clone().unwrap_or_else(|| "command".into());
    let last_line = core
        .pane(mark.pane_id)
        .and_then(|entry| entry.pane.command_output(None, Some(mark.command_id)).ok())
        .and_then(|output| last_output_line(&output.text));
    let body = match last_line {
        Some(line) => format!("after {} · {line}", run_time(duration)),
        None => format!("after {}", run_time(duration)),
    };
    let update = core.ws.attention.add(NewItem {
        pane_id: mark.pane_id,
        session_id: lock(&core.layout).session_of_pane(mark.pane_id),
        kind: AttentionKind::CommandFinished(mark.clone()),
        title: format!("{command} {status}"),
        body,
        while_viewed: false,
    });
    core.emit(Event::Attention(update));
}

/// Longest last line put in a notification body, in characters.
const LAST_LINE_CHARS: usize = 120;

/// The last line of output with something on it, trimmed and cut to [`LAST_LINE_CHARS`].
fn last_output_line(text: &str) -> Option<String> {
    let line = text.lines().rev().map(str::trim).find(|l| !l.is_empty())?;
    let line: String = line.chars().filter(|c| !c.is_control()).collect();
    if line.chars().count() > LAST_LINE_CHARS {
        let cut: String = line.chars().take(LAST_LINE_CHARS - 1).collect();
        Some(format!("{}…", cut.trim_end()))
    } else {
        Some(line)
    }
}

/// A run time in the app's words: `42 s`, `3 min 5 s`, `2 h 4 min`.
fn run_time(secs: u64) -> String {
    match secs {
        0..60 => format!("{secs} s"),
        60..3600 => format!("{} min {} s", secs / 60, secs % 60),
        _ => format!("{} h {} min", secs / 3600, secs % 3600 / 60),
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notification_body_parts() {
        assert_eq!(
            last_output_line("Compiling x\nerror: could not compile\n\n  \n").as_deref(),
            Some("error: could not compile")
        );
        assert_eq!(last_output_line("\n \n"), None);
        assert_eq!(last_output_line("\tok\t").as_deref(), Some("ok"));
        let long = "x".repeat(300);
        let cut = last_output_line(&long).unwrap();
        assert_eq!(cut.chars().count(), LAST_LINE_CHARS);
        assert!(cut.ends_with('…'));
        assert_eq!(run_time(42), "42 s");
        assert_eq!(run_time(185), "3 min 5 s");
        assert_eq!(run_time(7440), "2 h 4 min");
    }
}
