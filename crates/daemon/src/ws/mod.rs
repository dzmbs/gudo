//! Developer-workflow requests: ports, editor, git, agent-turn diffs, review notes,
//! worktrees, files and the attention feed.
//!
//! [`handle`] answers one [`WorkspaceRequest`]. Blocking work (git, the file system, process
//! tables) runs on `spawn_blocking`; every path goes through [`paths::Policy`] first.

mod attention;
pub(crate) mod editor;
mod editor_ports;
mod editor_proxy;
mod files;
mod gh;
pub(crate) mod git;
pub(crate) mod installs;
mod paths;
pub(crate) mod ports;
pub(crate) mod repo;
mod repo_ops;
mod resolve;
pub(crate) mod review;
pub(crate) mod trust;
pub(crate) mod tunnel;
pub(crate) mod turns;
mod vscode_server;
mod watch;
pub(crate) mod workflows;
mod worktree;

pub(crate) use tunnel::DEFAULT_UPDATE_URL as VSCODE_UPDATE_URL;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use proto::{
    AgentKind, AttentionKind, CommandMark, PaneId, PaneLaunch, ServerCtl, WorkspaceRequest,
    WorkspaceResponse, WsError,
};
use tokio::sync::mpsc;

pub(crate) use attention::{Attention, NewItem, Viewer};
pub(crate) use files::{serve_download, serve_upload};
pub use paths::Policy;
pub(crate) use watch::Watch;

use crate::config::Config;
use crate::core::{Core, Event, lock};

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
    /// Which repositories' setup and teardown commands the owner trusts.
    pub hook_trust: trust::HookTrust,
    worktree_root: PathBuf,
    pub usage: Arc<crate::usage::Usage>,
    pub accounts: Arc<crate::accounts::Accounts>,
    /// How the agents' own commands run for an account.
    pub tools: crate::accounts::Tools,
    pub workflows: Arc<workflows::Workflows>,
    /// `PATH` as the user's terminal panes see it.
    pub terminal_path: installs::TerminalPath,
    pub timelines: crate::timeline::Timelines,
}

impl Ws {
    pub fn new(config: &Config, events: tokio::sync::broadcast::Sender<Event>) -> Self {
        let home = config.home();
        let accounts = Arc::new(crate::accounts::Accounts::load(&config.state_dir));
        Self {
            policy: Policy::new(&home, &config.fs_allow).deny(&config.state_dir),
            ports: ports::Ports::new(),
            attention: Attention::default(),
            turns: turns::Turns::new(),
            editors: editor::Editors::new(config),
            tunnel: tunnel::Tunnel::new(events.clone()),
            workflows: Arc::new(workflows::Workflows::new(events)),
            worktrees: worktree::Worktrees::load(&config.state_dir, config.worktree_port_base),
            repos: repo::Repos::new(),
            hook_trust: trust::HookTrust::load(&config.state_dir),
            worktree_root: config
                .worktree_root
                .clone()
                .unwrap_or_else(|| home.join(format!(".{}", brand::DIR_NAME)).join("worktrees")),
            usage: Arc::new(crate::usage::Usage::new(config, Arc::clone(&accounts))),
            accounts,
            tools: crate::accounts::Tools::new(config),
            terminal_path: installs::TerminalPath::default(),
            timelines: crate::timeline::Timelines::default(),
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
    pub timeline_watches: Arc<Mutex<HashMap<PaneId, crate::timeline::Watch>>>,
    pub timeline_mailbox: Arc<crate::timeline::Mailbox>,
    pub timeline_since: Option<proto::UnixMillis>,
    /// Who is asking (push registration and notification actions are per device).
    pub actor: proto::Actor,
    /// The client's optional features (`Caps::AGENT_USAGE` takes usage pushes).
    pub caps: proto::Caps,
    /// A paired owner device, not a guest (whatever roles a guest's grant names).
    pub owner: bool,
    /// Whose attention "seen" this connection reads and records.
    pub viewer: Viewer,
    /// The panes it may see.
    pub scope: proto::Scope,
}

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, WsError> + Send + 'static,
) -> Result<T, WsError> {
    tokio::task::spawn_blocking(work)
        .await
        .unwrap_or_else(|error| Err(WsError::Failed(error.to_string())))
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
        .find(|ancestor| ancestor.join(".git").exists())
        .unwrap_or(dir)
        .to_owned()
}

fn repo_root(dir: &Path) -> Option<String> {
    let dir = dir.canonicalize().unwrap_or_else(|_| dir.to_owned());
    dir.ancestors()
        .find(|ancestor| ancestor.join(".git").exists())
        .map(|root| root.to_string_lossy().into_owned())
}

static NEXT_WATCH: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

pub(crate) async fn handle(
    core: &Arc<Core>,
    conn: &ConnCtx,
    request: WorkspaceRequest,
) -> Result<WorkspaceResponse, WsError> {
    use WorkspaceRequest as Request;
    use WorkspaceResponse as Response;
    let ws = &core.ws;
    let policy = ws.policy.clone();
    match request {
        Request::Accounts
        | Request::AccountAdd(_)
        | Request::AccountEdit { .. }
        | Request::AccountRemove { .. }
        | Request::AccountCheck { .. }
        | Request::AccountSetDefault { .. }
            if !conn.owner =>
        {
            Err(WsError::Denied(
                "only the host's owner sees or changes its agent accounts".into(),
            ))
        }
        request @ (Request::Accounts
        | Request::AccountAdd(_)
        | Request::AccountEdit { .. }
        | Request::AccountRemove { .. }
        | Request::AccountCheck { .. }
        | Request::AccountSetDefault { .. }) => accounts(core, request).await,
        Request::PowerSettings(policy) => {
            if !conn.owner {
                return Err(WsError::Denied(
                    "only the host's owner can manage its power policy".into(),
                ));
            }
            core.power
                .settings(policy)
                .map(Response::PowerStatus)
                .map_err(|error| WsError::Failed(error.to_string()))
        }
        request @ (Request::TimelineWatch { .. }
        | Request::TimelineWatchVersioned { .. }
        | Request::TimelineWatchCapabilities { .. }
        | Request::TimelineUnwatch { .. }
        | Request::TimelineItemsBefore { .. }
        | Request::TimelineToolOutput { .. }
        | Request::TimelineToolDiff { .. }) => crate::timeline::handle(core, conn, request).await,
        request @ (Request::ChatPrepare { .. } | Request::ChatSend { .. }) => {
            crate::agent_input::chat_request(core, conn, request)
                .await
                .map(Response::ChatSend)
        }
        request @ (Request::ChatInterruptPrepare { .. } | Request::ChatInterrupt { .. }) => {
            crate::agent_input::interrupt_request(core, conn, request).map(Response::ChatSend)
        }
        Request::ListPorts => Ok(Response::Ports(ports::scan(core).await)),
        Request::EditorStatus => {
            let mut editors = ws.editors.status(&core.cfg).await;
            if !conn.owner {
                // The token opens the owner's editor as the owner, beyond any guest's scope.
                for running in &mut editors.running {
                    running.port = 0;
                    running.token.clear();
                    running.url_path.clear();
                    running.pid = 0;
                }
            }
            Ok(Response::Editors(editors))
        }
        Request::EditorLaunch(launch) => {
            let folder = existing_dir(&policy, &launch.folder)?;
            let folder = folder.canonicalize().unwrap_or(folder);
            ws.editors
                .launch(&core.cfg, &launch, &folder)
                .await
                .map(Response::Editor)
        }
        Request::EditorStop { folder } => {
            let folder = policy.resolve(&folder)?;
            let folder = folder.canonicalize().unwrap_or(folder);
            ws.editors.stop(&folder.to_string_lossy()).await?;
            Ok(Response::Done)
        }
        Request::EditorOpen {
            folder,
            path,
            line,
            column,
        } => {
            let path = policy.resolve_followed(&path)?;
            let path = path.canonicalize().unwrap_or(path);
            let folder = match folder {
                Some(folder) => {
                    let folder = policy.resolve(&folder)?;
                    Some(
                        folder
                            .canonicalize()
                            .unwrap_or(folder)
                            .to_string_lossy()
                            .into_owned(),
                    )
                }
                None => None,
            };
            ws.editors
                .open(folder.as_deref(), &path, line, column)
                .await
                .map(Response::EditorOpened)
        }
        Request::GitStatus { path } => {
            let dir = existing_dir(&policy, &path)?;
            blocking(move || git::status(&dir))
                .await
                .map(Response::GitStatus)
        }
        Request::RepoRoot { path } => {
            let dir = existing_dir(&policy, &path)?;
            blocking(move || Ok(repo_root(&dir)))
                .await
                .map(Response::RepoRoot)
        }
        Request::GitDiff(diff) => {
            let dir = existing_dir(&policy, &diff.path)?;
            blocking(move || git::diff(&diff, &dir))
                .await
                .map(Response::GitDiff)
        }
        Request::ListTurns { pane_id } => Ok(Response::Turns(ws.turns.list(pane_id))),
        Request::TurnDiff {
            pane_id,
            turn,
            context,
            hunks,
        } => {
            let core = Arc::clone(core);
            blocking(move || core.ws.turns.diff(pane_id, turn, context, hunks))
                .await
                .map(Response::GitDiff)
        }
        Request::SendReview(review) => review::send(
            core,
            review.pane_id,
            review.preamble.as_deref(),
            &review.notes,
            review.submit,
            false,
        )
        .await
        .map(|prompt| Response::ReviewSent { prompt }),
        Request::WorktreeCreate(mut create) => {
            let repo = existing_dir(&policy, &create.repo)?;
            create.repo = repo.to_string_lossy().into_owned();
            if let Some(path) = &create.path {
                create.path = Some(policy.resolve(path)?.to_string_lossy().into_owned());
            }
            let core = Arc::clone(core);
            let root = ws.worktree_root.clone();
            let made = blocking(move || core.ws.worktrees.create(&create, &root)).await;
            ws.repos.relist();
            made.map(Response::Worktree)
        }
        Request::WorktreeList { repo } => {
            let dir = existing_dir(&policy, &repo)?;
            let core = Arc::clone(core);
            blocking(move || core.ws.worktrees.list(&dir))
                .await
                .map(Response::Worktrees)
        }
        Request::WorktreeRemove {
            path,
            force,
            delete_branch,
        } => {
            let path = policy.resolve(&path)?;
            let core = Arc::clone(core);
            blocking(move || {
                let main = repo_ops::main_of(&path).ok();
                let hooks = repo::runnable_hooks(&core, &path, main.as_deref());
                core.ws
                    .worktrees
                    .remove(&path, force, delete_branch, hooks.teardown.as_deref())
            })
            .await?;
            ws.repos.relist();
            Ok(Response::Done)
        }
        Request::WorktreeLaunch {
            path,
            split_from,
            axis,
            agent,
        } => {
            let dir = existing_dir(&policy, &path)?;
            let cwd = Some(dir.to_string_lossy().into_owned());
            // A worktree created outside the daemon has no port yet.
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
                proto::OpOutcome::PaneCreated { pane_id } => Ok(Response::PaneCreated { pane_id }),
                proto::OpOutcome::Failed { message, .. } => Err(WsError::Failed(message)),
                other => Err(WsError::Failed(format!("unexpected outcome {other:?}"))),
            }
        }
        Request::FsList { path, show_hidden } => {
            blocking(move || files::list(&policy, &path, show_hidden))
                .await
                .map(Response::Dir)
        }
        Request::FsStat { path } => blocking(move || files::stat(&policy.resolve(&path)?))
            .await
            .map(Response::Stat),
        Request::ResolvePaths(query) => {
            resolve::validate(&query)?;
            let entry = core
                .pane(query.pane_id)
                .filter(|_| core.scope_within(proto::Scope::Pane(query.pane_id), conn.scope))
                .ok_or_else(|| WsError::NotFound(format!("pane {}", query.pane_id.0)))?;
            let home = core
                .cfg
                .pane_var("HOME")
                .map_or_else(|| policy.home().to_owned(), PathBuf::from);
            blocking(move || {
                let directory = query
                    .command_id
                    .and_then(|id| entry.pane.command_cwd(id))
                    .or_else(|| lock(&entry.meta).cwd.clone())
                    .map(PathBuf::from);
                Ok(resolve::resolve_all(
                    &policy,
                    &query.paths,
                    directory.as_deref(),
                    &home,
                ))
            })
            .await
            .map(Response::ResolvedPaths)
        }
        Request::FsRead { path, offset, len } => {
            blocking(move || files::read(&policy, &path, offset, len))
                .await
                .map(Response::FileData)
        }
        Request::FsWrite { target, data } => {
            blocking(move || files::write_small(&policy, &target, &data))
                .await
                .map(Response::Stat)
        }
        Request::FsMkdir { path, parents } => {
            blocking(move || files::mkdir(&policy, &path, parents))
                .await
                .map(Response::Stat)
        }
        Request::FsRename {
            from,
            to,
            overwrite,
        } => blocking(move || files::rename(&policy, &from, &to, overwrite))
            .await
            .map(Response::Stat),
        Request::FsDelete {
            path,
            mode,
            recursive,
        } => {
            blocking(move || files::delete(&policy, &path, mode, recursive)).await?;
            Ok(Response::Done)
        }
        Request::FsWatch { path } => {
            let dir = policy.resolve_followed(&path)?;
            let watch_id = NEXT_WATCH.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let watch = watch::start(&dir, watch_id, conn.ctl.clone())?;
            lock(&conn.watches).insert(watch_id, watch);
            Ok(Response::Watching { watch_id })
        }
        Request::FsUnwatch { watch_id } => lock(&conn.watches)
            .remove(&watch_id)
            .map(|_| Response::Done)
            .ok_or_else(|| WsError::NotFound(format!("watch {watch_id}"))),
        Request::VsCodeTunnelStatus => {
            Ok(Response::VsCodeTunnel(ws.tunnel.status(&core.cfg).await))
        }
        Request::VsCodeCliInstall(install) => {
            if !install.accept_license {
                return Err(WsError::Denied(format!(
                    "installing the VS Code CLI needs Microsoft's licence accepted ({})",
                    proto::VSCODE_LICENSE_URL
                )));
            }
            ws.tunnel
                .install_cli(&core.cfg)
                .await
                .map(Response::VsCodeTunnel)
        }
        Request::VsCodeTunnelStart(start) => {
            if !start.accept_server_license {
                return Err(WsError::Denied(format!(
                    "the VS Code tunnel needs the VS Code Server licence accepted ({})",
                    proto::VSCODE_SERVER_LICENSE_URL
                )));
            }
            ws.tunnel
                .start(&core.cfg, &start)
                .await
                .map(Response::VsCodeTunnel)
        }
        Request::VsCodeTunnelStop => ws.tunnel.stop(&core.cfg).await.map(Response::VsCodeTunnel),
        Request::VsCodeTunnelOpen(open) => {
            let path = policy.resolve_followed(&open.path)?;
            let path = path.canonicalize().unwrap_or(path);
            if !path.exists() {
                return Err(WsError::NotFound(path.display().to_string()));
            }
            let folder = match &open.folder {
                Some(folder) => {
                    let folder = policy.resolve_followed(folder)?;
                    folder.canonicalize().unwrap_or(folder)
                }
                None if path.is_dir() => path.clone(),
                None => workspace_folder(&path),
            };
            ws.tunnel
                .open(&folder, &core.cfg.home(), &path, open.line, open.column)
                .await
                .map(Response::VsCodeTunnelOpened)
        }
        Request::PushRegister(registration) => Ok(Response::Push(crate::notifier::register(
            core,
            conn.actor,
            registration,
        )?)),
        Request::PushUnregister => Ok(Response::Push(crate::notifier::unregister(
            core, conn.actor,
        ))),
        Request::PushStatus => Ok(Response::Push(crate::notifier::status(
            core,
            conn.actor.device,
        ))),
        Request::PushActivity(token) => Ok(Response::Push(crate::notifier::activity_token(
            core, conn.actor, token,
        )?)),
        Request::PushAgents(rules) => Ok(Response::Push(crate::notifier::agent_rules(
            core, conn.actor, rules,
        )?)),
        Request::PushAction(action) => {
            crate::notifier::action(core, conn.actor, &action).map(Response::PushDecided)
        }
        Request::RepoRefresh { .. }
        | Request::PrMerge(_)
        | Request::PrRerunFailed { .. }
        | Request::PrCreate(_)
        | Request::PrCheckout(_)
        | Request::WorktreeArchive { .. }
        | Request::WorktreeArchived { .. }
        | Request::WorktreeRestore { .. }
        | Request::WorktreeSettings(_)
        | Request::TaskCreate(_)
        | Request::ScriptRun(_)
        | Request::RepoHooks(_) => {
            let root = ws.worktree_root.clone();
            repo_ops::handle(core, &policy, &root, request).await
        }
        Request::RepoTrust { .. } if !conn.owner => Err(WsError::Denied(
            "only the host's owner can trust a repository's commands".into(),
        )),
        Request::RepoTrust { .. } => {
            let root = ws.worktree_root.clone();
            repo_ops::handle(core, &policy, &root, request).await
        }
        Request::AttentionList => Ok(Response::Attention(ws.attention.list_for(conn.viewer))),
        Request::AttentionSeen(seen) => {
            mark_seen(core, conn.viewer, &seen, |pane| {
                core.scope_within(proto::Scope::Pane(pane), conn.scope)
            });
            Ok(Response::Attention(ws.attention.list_for(conn.viewer)))
        }
        Request::UsageWatch(options) => Ok(Response::AgentUsage(
            ws.usage.watch(&conn.ctl, conn.caps, options).await,
        )),
        Request::UsageUnwatch => {
            ws.usage.unwatch(&conn.ctl);
            Ok(Response::Done)
        }
        Request::WorkflowList { pane_id } => {
            let cwd = pane_id
                .map(|pane| pane_cwd(core, pane))
                .transpose()?
                .flatten();
            let global = workflow_dir(&core.cfg);
            let workflows = Arc::clone(&ws.workflows);
            blocking(move || Ok(workflows.list(&global, cwd.as_deref())))
                .await
                .map(Response::Workflows)
        }
        Request::WorkflowSave(save) => {
            let cwd = save
                .pane_id
                .map(|pane| pane_cwd(core, pane))
                .transpose()?
                .flatten();
            let global = workflow_dir(&core.cfg);
            let workflows = Arc::clone(&ws.workflows);
            blocking(move || workflows.save(save.scope, &save.workflow, &global, cwd.as_deref()))
                .await
                .map(Response::WorkflowSaved)
        }
        Request::AgentInstalls => {
            let path = ws.terminal_path.refresh(&core.cfg).await;
            Ok(Response::AgentInstalls(installs::check(&core.cfg, path)))
        }
        Request::AgentMcpCommands { register } => {
            let path = ws.terminal_path.cached(&core.cfg).await;
            let accounts: Vec<_> = ws
                .accounts
                .list()
                .into_iter()
                .filter(|account| !account.is_system())
                .map(|account| (account.agent, ws.accounts.dir(account.agent, &account.id)))
                .collect();
            Ok(Response::AgentMcpCommands(installs::mcp_commands(
                &core.cfg, path, register, &accounts,
            )))
        }
    }
}

/// Answers an `Account*` request from the owner.
async fn accounts(
    core: &Arc<Core>,
    request: WorkspaceRequest,
) -> Result<WorkspaceResponse, WsError> {
    use WorkspaceRequest as Request;
    use WorkspaceResponse as Response;
    let ws = &core.ws;
    let changed = |core: &Core| {
        core.emit(Event::Accounts);
        Ok(Response::Accounts(core.accounts_report()))
    };
    match request {
        Request::Accounts => {
            // Accounts nobody asked about yet are asked about now; clients hear the answer.
            for account in ws.accounts.list() {
                if account.status == proto::AccountStatus::Unknown {
                    core.check_account(account.agent, account.id);
                }
            }
            Ok(Response::Accounts(core.accounts_report()))
        }
        Request::AccountAdd(add) => {
            let account = ws.accounts.add(&add).map_err(WsError::Invalid)?;
            core.emit(Event::Accounts);
            Ok(Response::Account(account))
        }
        Request::AccountEdit {
            agent,
            account,
            label,
            color,
        } => {
            ws.accounts
                .edit(agent, &account, &label, color)
                .map_err(WsError::Invalid)?;
            changed(core)
        }
        Request::AccountRemove { agent, account } => {
            let in_use = core
                .accounts_report()
                .panes
                .iter()
                .filter(|pane| pane.agent == agent && pane.account == account)
                .count();
            if in_use > 0 {
                return Err(WsError::Conflict(format!(
                    "{in_use} agent pane{} still run{} under this account; close {} first",
                    if in_use == 1 { "" } else { "s" },
                    if in_use == 1 { "s" } else { "" },
                    if in_use == 1 { "it" } else { "them" },
                )));
            }
            ws.accounts
                .remove(&ws.tools, agent, &account)
                .await
                .map_err(WsError::Failed)?;
            changed(core)
        }
        Request::AccountCheck { agent, account } => {
            let (account, updated) = ws
                .accounts
                .check(&ws.tools, agent, &account)
                .await
                .map_err(WsError::NotFound)?;
            if updated {
                core.emit(Event::Accounts);
            }
            Ok(Response::Account(account))
        }
        Request::AccountSetDefault {
            agent,
            project,
            account,
        } => {
            ws.accounts
                .set_default(agent, project, account)
                .map_err(WsError::Invalid)?;
            changed(core)
        }
        _ => unreachable!("only account requests come here"),
    }
}

/// The global workflow directory of the daemon's user.
fn workflow_dir(config: &Config) -> PathBuf {
    let xdg_config = config.pane_var("XDG_CONFIG_HOME").map(PathBuf::from);
    workflows::global_dir(xdg_config.as_deref(), &config.home())
}

/// A pane's directory: OSC 7, else where it was launched.
fn pane_cwd(core: &Core, pane: PaneId) -> Result<Option<PathBuf>, WsError> {
    let entry = core
        .pane(pane)
        .ok_or_else(|| WsError::NotFound(format!("pane {pane}")))?;
    let reported = lock(&entry.meta).cwd.clone();
    Ok(reported
        .or_else(|| lock(&entry.record).cwd.clone())
        .map(PathBuf::from))
}

/// A long command finished unseen. The body says how long it ran and ends with its last line
/// of output, the line that usually says what happened.
pub(crate) fn command_unseen(core: &Core, mark: &CommandMark) {
    let duration = mark.finished.map_or(0, |finished| finished.duration_ms) / 1000;
    let status = match mark.finished.and_then(|finished| finished.exit) {
        Some(0) => "succeeded".to_owned(),
        Some(code) => format!("failed ({code})"),
        None => "finished".to_owned(),
    };
    // The command line comes from the shell's OSC 133 report: any program can forge it.
    let command = mark
        .command
        .as_deref()
        .map(|command| proto::clean_prompt_text(command, COMMAND_CHARS))
        .filter(|command| !command.is_empty())
        .unwrap_or_else(|| "command".into());
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
        viewers: core.pane_viewers(mark.pane_id),
    });
    core.emit(Event::Attention(update));
}

/// In characters.
const LAST_LINE_CHARS: usize = 120;
/// In characters.
const COMMAND_CHARS: usize = 80;

/// The last line of output with something on it, trimmed and cut to [`LAST_LINE_CHARS`].
fn last_output_line(text: &str) -> Option<String> {
    let line = text
        .lines()
        .rev()
        .map(str::trim)
        .find(|line| !line.is_empty())?;
    let line: String = line
        .chars()
        .filter(|&ch| !ch.is_control() && !proto::is_invisible_format(ch))
        .collect();
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
        viewers: core.pane_viewers(pane),
    });
    core.emit(Event::Attention(update));
}

/// An agent asks to drive one of the user's panes (`term::ask`): an approval item on its pane.
pub(crate) fn drive_notice(
    core: &Core,
    pane: PaneId,
    agent: String,
    request_id: proto::RequestId,
    title: String,
    body: String,
) {
    let update = core.ws.attention.add(NewItem {
        pane_id: pane,
        session_id: lock(&core.layout).session_of_pane(pane),
        kind: AttentionKind::AgentBlocked {
            agent,
            request_id: Some(request_id),
        },
        title,
        body,
        viewers: core.pane_viewers(pane),
    });
    core.emit(Event::Attention(update));
}

/// The agent left the blocked state: its blocked items are no longer actionable.
pub(crate) fn agent_unblocked(core: &Core, pane: PaneId) {
    let ids = core.ws.attention.resolve_blocked(pane);
    if !ids.is_empty() {
        core.emit(Event::AttentionSeen { by: None, ids });
    }
}

/// Marks items seen by `viewer`, limited to the panes it may see, and tells its clients.
pub(crate) fn mark_seen(
    core: &Core,
    viewer: Viewer,
    which: &proto::AttentionSeen,
    visible: impl Fn(PaneId) -> bool,
) {
    let ids = core.ws.attention.mark(viewer, which, visible);
    if !ids.is_empty() {
        core.emit(Event::AttentionSeen {
            by: Some(viewer),
            ids,
        });
    }
}

/// A client focused a pane in its scope: its items count as seen by that client's viewer.
pub(crate) fn pane_focused(core: &Core, viewer: Viewer, pane: PaneId) {
    let seen = proto::AttentionSeen {
        ids: Vec::new(),
        up_to: None,
        pane_id: Some(pane),
    };
    mark_seen(core, viewer, &seen, |item_pane| item_pane == pane);
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
        assert_eq!(
            last_output_line("tests \u{202e}deliaf\u{202c} ok").as_deref(),
            Some("tests deliaf ok")
        );
        let long = "x".repeat(300);
        let cut = last_output_line(&long).unwrap();
        assert_eq!(cut.chars().count(), LAST_LINE_CHARS);
        assert!(cut.ends_with('…'));
        assert_eq!(run_time(42), "42 s");
        assert_eq!(run_time(185), "3 min 5 s");
        assert_eq!(run_time(7440), "2 h 4 min");
    }
}
