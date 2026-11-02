//! The git-native workspace's requests: refresh, pull request actions through `gh`, archive
//! and restore, housekeeping settings, new tasks and scripts (`proto::repo`).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use proto::{
    LayoutOp, OpOutcome, PaneLaunch, PrState, PullRequest, RepoHooks, RepoHooksFor, RepoHooksTrust,
    WorkspaceRequest, WorkspaceResponse, WorktreeCreate, WorktreeInfo, WsError,
};

use super::git::{self, git};
use super::paths::Policy;
use super::{blocking, existing_dir, gh, repo, trust};
use crate::core::Core;

fn gh_path(core: &Core) -> Result<PathBuf, WsError> {
    gh::find(core.cfg.repos.gh.as_deref()).ok_or_else(|| {
        WsError::Unavailable(
            "the GitHub CLI (gh) is not installed on the host; install it from https://cli.github.com"
                .into(),
        )
    })
}

fn worktree_branch(dir: &Path) -> Result<(PathBuf, String), WsError> {
    let status = git::status(dir)?;
    let root = PathBuf::from(&status.root);
    let root = root.canonicalize().unwrap_or(root);
    let branch = status
        .branch
        .ok_or_else(|| WsError::Invalid("the worktree is on a detached HEAD".into()))?;
    Ok((root, branch))
}

fn view(gh: &Path, root: &Path, branch: &str) -> Result<Option<PullRequest>, WsError> {
    gh::pr_view(
        gh,
        root,
        branch,
        proto::UnixMillis(crate::identity::now_millis()),
    )
    .map_err(|error| match error {
        gh::ViewError::Missing => {
            WsError::Unavailable("the GitHub CLI (gh) is not installed on the host".into())
        }
        gh::ViewError::Auth(message) => WsError::Unavailable(format!(
            "gh is not signed in on the host; run `gh auth login` there ({message})"
        )),
        gh::ViewError::NotGitHub => WsError::NotFound("the repository has no GitHub remote".into()),
        gh::ViewError::Other(message) => WsError::Failed(message),
    })
}

fn why_not_mergeable(pr: &PullRequest) -> String {
    use proto::MergeState;
    match pr.merge_state {
        MergeState::Behind => "the branch is behind its base; update it first".into(),
        MergeState::Blocked => "required reviews or checks are missing".into(),
        MergeState::Dirty => "it has merge conflicts".into(),
        MergeState::Draft => "it is a draft".into(),
        MergeState::Unknown => {
            "GitHub is still checking whether it can be merged; try again shortly".into()
        }
        MergeState::Clean | MergeState::Unstable | MergeState::HasHooks => String::new(),
    }
}

/// A branch name from a task name: lower case, `-` for anything git would mind.
pub(crate) fn branch_slug(name: &str) -> String {
    let mut slug = String::new();
    for ch in name.trim().chars() {
        let ch = ch.to_ascii_lowercase();
        if ch.is_ascii_alphanumeric() || ch == '/' || ch == '.' || ch == '_' {
            slug.push(ch);
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches(['-', '.', '/']).replace("..", ".");
    if slug.is_empty() { "task".into() } else { slug }
}

fn branch_exists(repo: &Path, branch: &str) -> bool {
    git(
        repo,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("refs/heads/{branch}"),
        ],
    )
    .is_ok()
}

/// The hooks a task's new worktree from `base` in `root` will have: the config file committed
/// at `base`, else the main worktree's (as [`repo::read_config`] falls back).
fn new_task_hooks(root: &Path, main: &Path, base: Option<&str>) -> Result<RepoHooks, WsError> {
    let base = base.unwrap_or("HEAD");
    if base.starts_with('-') {
        return Err(WsError::Invalid(format!("bad base {base:?}")));
    }
    let object = format!("{base}:{}", repo::config_file_name());
    Ok(match git(root, &["cat-file", "blob", &object]) {
        Ok(bytes) => repo::parse_config(&bytes, &object).1,
        Err(_) => repo::read_config(main, None).1,
    })
}

pub(crate) fn main_of(dir: &Path) -> Result<PathBuf, WsError> {
    let porcelain = git(dir, &["worktree", "list", "--porcelain", "-z"])?;
    super::worktree::parse_list(&porcelain)
        .into_iter()
        .find(|worktree| worktree.main)
        .map(|worktree| PathBuf::from(worktree.path))
        .ok_or_else(|| WsError::Failed("no main worktree".into()))
}

pub(crate) async fn handle(
    core: &Arc<Core>,
    policy: &Policy,
    worktree_root: &Path,
    request: WorkspaceRequest,
) -> Result<WorkspaceResponse, WsError> {
    use WorkspaceRequest as Request;
    use WorkspaceResponse as Response;
    let repos = &core.ws.repos;
    match request {
        Request::RepoRefresh { path } => {
            let path = match path {
                Some(path) => {
                    let dir = existing_dir(policy, &path)?;
                    Some(blocking(move || git::toplevel(&dir)).await?)
                        .map(|root| root.canonicalize().unwrap_or(root))
                }
                None => None,
            };
            repos.refresh(path).await.map(Response::Repos)
        }
        Request::PrMerge(merge) => {
            let dir = existing_dir(policy, &merge.path)?;
            let gh = gh_path(core)?;
            let (root, after) = blocking(move || {
                let (root, branch) = worktree_branch(&dir)?;
                let pr = view(&gh, &root, &branch)?
                    .ok_or_else(|| WsError::NotFound(format!("no pull request for {branch}")))?;
                if pr.number != merge.number {
                    return Err(WsError::Conflict(format!(
                        "{branch}'s pull request is #{} now, not #{}",
                        pr.number, merge.number
                    )));
                }
                if pr.state != PrState::Open {
                    return Err(WsError::Conflict(format!("#{} is not open", pr.number)));
                }
                if !pr.merge_state.mergeable() {
                    return Err(WsError::Conflict(format!(
                        "#{} cannot be merged: {}",
                        pr.number,
                        why_not_mergeable(&pr)
                    )));
                }
                gh::merge(&gh, &root, pr.number, merge.strategy)?;
                let after = view(&gh, &root, &branch).ok().flatten();
                Ok((root, after))
            })
            .await?;
            repos.pr_changed(root, after.clone());
            Ok(Response::Pr(after))
        }
        Request::PrRerunFailed { path } => {
            let dir = existing_dir(policy, &path)?;
            let gh = gh_path(core)?;
            let (root, after) = blocking(move || {
                let (root, branch) = worktree_branch(&dir)?;
                let pr = view(&gh, &root, &branch)?
                    .ok_or_else(|| WsError::NotFound(format!("no pull request for {branch}")))?;
                let runs = gh::failed_runs(&pr);
                if runs.is_empty() {
                    return Err(WsError::Invalid(
                        "no failed GitHub Actions runs to re-run".into(),
                    ));
                }
                gh::rerun_failed(&gh, &root, &runs)?;
                let after = view(&gh, &root, &branch).ok().flatten();
                Ok((root, after))
            })
            .await?;
            repos.pr_changed(root, after.clone());
            Ok(Response::Pr(after))
        }
        Request::PrCreate(create) => {
            let dir = existing_dir(policy, &create.path)?;
            let gh = gh_path(core)?;
            let (root, after) = blocking(move || {
                let status = git::status(&dir)?;
                let (root, branch) = worktree_branch(&dir)?;
                let remote = status
                    .upstream
                    .as_deref()
                    .and_then(|upstream| upstream.split_once('/'))
                    .map_or_else(|| "origin".to_owned(), |(remote, _)| remote.to_owned());
                git(&root, &["push", "-u", &remote, "HEAD"])?;
                gh::create(&gh, &root, create.draft, create.base.as_deref())?;
                let after = view(&gh, &root, &branch)?;
                Ok((root, after))
            })
            .await?;
            repos.pr_changed(root, after.clone());
            Ok(Response::Pr(after))
        }
        Request::PrCheckout(checkout) => {
            let dir = existing_dir(policy, &checkout.repo)?;
            let gh = gh_path(core)?;
            let root = worktree_root.to_owned();
            let core = Arc::clone(core);
            let made = blocking(move || {
                let main = main_of(&dir)?;
                let name = main.file_name().map_or_else(
                    || "repo".to_owned(),
                    |name| name.to_string_lossy().into_owned(),
                );
                let path = root.join(name).join(format!("pr-{}", checkout.number));
                if path.exists() {
                    return Err(WsError::Conflict(format!("{} exists", path.display())));
                }
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent)
                        .map_err(|error| super::paths::io_error(parent, &error))?;
                }
                let path_str = path.to_string_lossy().into_owned();
                git(
                    &main,
                    &["worktree", "add", "--detach", "--", &path_str, "HEAD"],
                )?;
                let fallback = format!("pr-{}", checkout.number);
                let checked_out = gh::checkout(&gh, &path, checkout.number, None)
                    .or_else(|_| gh::checkout(&gh, &path, checkout.number, Some(&fallback)));
                if let Err(error) = checked_out {
                    let _ = git(&main, &["worktree", "remove", "--force", "--", &path_str]);
                    return Err(error);
                }
                let port = core.ws.worktrees.allocate(&path);
                core.ws.worktrees.mark_managed(&path);
                let status = git::status(&path)?;
                Ok(WorktreeInfo {
                    path: path
                        .canonicalize()
                        .unwrap_or(path)
                        .to_string_lossy()
                        .into_owned(),
                    branch: status.branch,
                    head: status.head,
                    main: false,
                    locked: false,
                    prunable: false,
                    port: Some(port),
                })
            })
            .await?;
            repos.relist();
            Ok(Response::Worktree(made))
        }
        Request::WorktreeArchive { path, force } => {
            let path = policy.resolve(&path)?;
            let core = Arc::clone(core);
            blocking(move || {
                let main = main_of(&path).ok();
                let hooks = repo::runnable_hooks(&core, &path, main.as_deref());
                core.ws.worktrees.archive(
                    &path,
                    force,
                    hooks.teardown.as_deref(),
                    crate::identity::now_millis(),
                )
            })
            .await?;
            repos.relist();
            Ok(Response::Done)
        }
        Request::WorktreeArchived { repo } => {
            let main = match repo {
                Some(repo) => {
                    let dir = existing_dir(policy, &repo)?;
                    Some(blocking(move || main_of(&dir)).await?)
                        .map(|main| main.canonicalize().unwrap_or(main))
                }
                None => None,
            };
            Ok(Response::Archived(
                core.ws.worktrees.archived(main.as_deref()),
            ))
        }
        Request::WorktreeRestore { id } => {
            let core = Arc::clone(core);
            let info = blocking(move || core.ws.worktrees.restore(id)).await?;
            repos.relist();
            Ok(Response::Worktree(info))
        }
        Request::WorktreeSettings(set) => {
            Ok(Response::WorktreeSettings(core.ws.worktrees.settings(set)))
        }
        Request::TaskCreate(task) => {
            let dir = existing_dir(policy, &task.repo)?;
            let worker_core = Arc::clone(core);
            let root = worktree_root.to_owned();
            let name = task.name.clone();
            let explicit = task.branch.clone();
            let base = task.base.clone();
            let (info, hooks) = blocking(move || {
                let repo_root = git::toplevel(&dir)?;
                let branch = match explicit {
                    Some(branch) => branch,
                    None => {
                        let slug = branch_slug(&name);
                        (1..100)
                            .map(|n| {
                                if n == 1 {
                                    slug.clone()
                                } else {
                                    format!("{slug}-{n}")
                                }
                            })
                            .find(|candidate| !branch_exists(&repo_root, candidate))
                            .unwrap_or(slug)
                    }
                };
                let info = worker_core.ws.worktrees.create(
                    &WorktreeCreate {
                        repo: repo_root.to_string_lossy().into_owned(),
                        branch: Some(branch),
                        base,
                        path: None,
                    },
                    &root,
                )?;
                let main = main_of(Path::new(&info.path)).ok();
                let hooks =
                    repo::runnable_hooks(&worker_core, Path::new(&info.path), main.as_deref());
                Ok((info, hooks))
            })
            .await?;
            let path = PathBuf::from(&info.path);
            if let Some(setup) = &hooks.setup {
                repos.queue_pre_command(&path, setup);
            }
            let cwd = Some(info.path.clone());
            let launch = match task.agent {
                Some(agent) => PaneLaunch::Agent {
                    agent,
                    resume: None,
                    cwd,
                },
                None => PaneLaunch::Shell { cwd },
            };
            repos.relist();
            match core.apply_op(LayoutOp::NewTab {
                session_id: task.session_id,
                name: task.name,
                launch,
            }) {
                OpOutcome::TabCreated { tab_id, pane_id } => {
                    Ok(Response::TaskCreated(proto::TaskCreated {
                        worktree: info,
                        tab_id,
                        pane_id,
                        setup: hooks.setup,
                    }))
                }
                other => {
                    let _ = repos.take_pre_command(&path);
                    Err(WsError::Failed(match other {
                        OpOutcome::Failed { message, .. } => message,
                        other => format!("unexpected outcome {other:?}"),
                    }))
                }
            }
        }
        Request::ScriptRun(run) => {
            let dir = existing_dir(policy, &run.cwd)?;
            // An empty command opens a plain shell tab in the directory.
            let script = !run.command.trim().is_empty();
            if script {
                repos.queue_pre_command(&dir, &run.command);
            }
            match core.apply_op(LayoutOp::NewTab {
                session_id: run.session_id,
                name: run.name,
                launch: PaneLaunch::Shell {
                    cwd: Some(dir.to_string_lossy().into_owned()),
                },
            }) {
                OpOutcome::TabCreated { pane_id, .. } => Ok(Response::PaneCreated { pane_id }),
                other => {
                    if script {
                        let _ = repos.take_pre_command(&dir);
                    }
                    Err(WsError::Failed(match other {
                        OpOutcome::Failed { message, .. } => message,
                        other => format!("unexpected outcome {other:?}"),
                    }))
                }
            }
        }
        Request::RepoHooks(of) => {
            let core = Arc::clone(core);
            let policy = policy.clone();
            blocking(move || {
                let (main, hooks) = match of {
                    RepoHooksFor::NewTask { repo, base } => {
                        let root = git::toplevel(&existing_dir(&policy, &repo)?)?;
                        let main = main_of(&root)?;
                        (main.clone(), new_task_hooks(&root, &main, base.as_deref())?)
                    }
                    RepoHooksFor::Worktree { path } => {
                        let dir = existing_dir(&policy, &path)?;
                        let main = main_of(&dir)?;
                        (main.clone(), repo::read_config(&dir, Some(&main)).1)
                    }
                };
                let main = main.canonicalize().unwrap_or(main);
                Ok(Response::RepoHooks(RepoHooksTrust {
                    repo: main.to_string_lossy().into_owned(),
                    hash: trust::hash(&hooks),
                    trusted: core.ws.hook_trust.trusted(&main, &hooks),
                    hooks,
                }))
            })
            .await
        }
        Request::RepoTrust { repo, hash } => {
            let dir = existing_dir(policy, &repo)?;
            let main = blocking(move || main_of(&dir)).await?;
            if hash.len() != 64 || !hash.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                return Err(WsError::Invalid("not a command hash".into()));
            }
            tracing::info!(repo = %main.display(), "repository commands trusted");
            core.ws.hook_trust.trust(&main, &hash.to_ascii_lowercase());
            Ok(Response::Done)
        }
        other => Err(WsError::Invalid(format!(
            "not a repository request: {other:?}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::branch_slug;

    #[test]
    fn slugs_branch_names() {
        assert_eq!(branch_slug("quiet-otter"), "quiet-otter");
        assert_eq!(branch_slug("Fix the Login bug!"), "fix-the-login-bug");
        assert_eq!(branch_slug("feat/new  thing"), "feat/new-thing");
        assert_eq!(branch_slug("  "), "task");
    }
}
