//! The git-native workspace's requests: refresh, pull request actions through `gh`, archive
//! and restore, housekeeping settings, new tasks and scripts (`proto::repo`).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use proto::{
    LayoutOp, OpOutcome, PaneLaunch, PrState, PullRequest, WorkspaceRequest, WorkspaceResponse,
    WorktreeCreate, WorktreeInfo, WsError,
};

use super::git::{self, git};
use super::paths::Policy;
use super::{blocking, existing_dir, gh, repo};
use crate::core::Core;

fn gh_path(core: &Core) -> Result<PathBuf, WsError> {
    gh::find(core.cfg.repos.gh.as_deref()).ok_or_else(|| {
        WsError::Unavailable(
            "the GitHub CLI (gh) is not installed on the host; install it from https://cli.github.com"
                .into(),
        )
    })
}

/// The worktree top level containing `dir` and its branch.
fn worktree_branch(dir: &Path) -> Result<(PathBuf, String), WsError> {
    let status = git::status(dir)?;
    let root = PathBuf::from(&status.root);
    let root = root.canonicalize().unwrap_or(root);
    let branch = status
        .branch
        .ok_or_else(|| WsError::Invalid("the worktree is on a detached HEAD".into()))?;
    Ok((root, branch))
}

/// The branch's pull request, fresh from `gh`.
fn view(gh: &Path, root: &Path, branch: &str) -> Result<Option<PullRequest>, WsError> {
    gh::pr_view(
        gh,
        root,
        branch,
        proto::UnixMillis(crate::identity::now_millis()),
    )
    .map_err(|e| match e {
        gh::ViewError::Missing => {
            WsError::Unavailable("the GitHub CLI (gh) is not installed on the host".into())
        }
        gh::ViewError::Auth(m) => WsError::Unavailable(format!(
            "gh is not signed in on the host; run `gh auth login` there ({m})"
        )),
        gh::ViewError::NotGitHub => WsError::NotFound("the repository has no GitHub remote".into()),
        gh::ViewError::Other(m) => WsError::Failed(m),
    })
}

fn why_not_mergeable(pr: &PullRequest) -> String {
    use proto::MergeState as M;
    match pr.merge_state {
        M::Behind => "the branch is behind its base; update it first".into(),
        M::Blocked => "required reviews or checks are missing".into(),
        M::Dirty => "it has merge conflicts".into(),
        M::Draft => "it is a draft".into(),
        M::Unknown => "GitHub is still checking whether it can be merged; try again shortly".into(),
        M::Clean | M::Unstable | M::HasHooks => String::new(),
    }
}

/// A branch name from a task name: lower case, `-` for anything git would mind.
pub(crate) fn branch_slug(name: &str) -> String {
    let mut out = String::new();
    for c in name.trim().chars() {
        let c = c.to_ascii_lowercase();
        if c.is_ascii_alphanumeric() || c == '/' || c == '.' || c == '_' {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let out = out.trim_matches(['-', '.', '/']).replace("..", ".");
    if out.is_empty() { "task".into() } else { out }
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

fn main_of(dir: &Path) -> Result<PathBuf, WsError> {
    let out = git(dir, &["worktree", "list", "--porcelain", "-z"])?;
    super::worktree::parse_list(&out)
        .into_iter()
        .find(|w| w.main)
        .map(|w| PathBuf::from(w.path))
        .ok_or_else(|| WsError::Failed("no main worktree".into()))
}

pub(crate) async fn handle(
    core: &Arc<Core>,
    policy: &Policy,
    worktree_root: &Path,
    req: WorkspaceRequest,
) -> Result<WorkspaceResponse, WsError> {
    use WorkspaceRequest as R;
    use WorkspaceResponse as A;
    let repos = &core.ws.repos;
    match req {
        R::RepoRefresh { path } => {
            let path = match path {
                Some(p) => {
                    let dir = existing_dir(policy, &p)?;
                    Some(blocking(move || git::toplevel(&dir)).await?)
                        .map(|p| p.canonicalize().unwrap_or(p))
                }
                None => None,
            };
            repos.refresh(path).await.map(A::Repos)
        }
        R::PrMerge(merge) => {
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
            Ok(A::Pr(after))
        }
        R::PrRerunFailed { path } => {
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
            Ok(A::Pr(after))
        }
        R::PrCreate(create) => {
            let dir = existing_dir(policy, &create.path)?;
            let gh = gh_path(core)?;
            let (root, after) = blocking(move || {
                let status = git::status(&dir)?;
                let (root, branch) = worktree_branch(&dir)?;
                let remote = status
                    .upstream
                    .as_deref()
                    .and_then(|u| u.split_once('/'))
                    .map_or_else(|| "origin".to_owned(), |(r, _)| r.to_owned());
                git(&root, &["push", "-u", &remote, "HEAD"])?;
                gh::create(&gh, &root, create.draft, create.base.as_deref())?;
                let after = view(&gh, &root, &branch)?;
                Ok((root, after))
            })
            .await?;
            repos.pr_changed(root, after.clone());
            Ok(A::Pr(after))
        }
        R::PrCheckout(checkout) => {
            let dir = existing_dir(policy, &checkout.repo)?;
            let gh = gh_path(core)?;
            let root = worktree_root.to_owned();
            let core2 = Arc::clone(core);
            let made = blocking(move || {
                let main = main_of(&dir)?;
                let name = main
                    .file_name()
                    .map_or_else(|| "repo".to_owned(), |n| n.to_string_lossy().into_owned());
                let path = root.join(name).join(format!("pr-{}", checkout.number));
                if path.exists() {
                    return Err(WsError::Conflict(format!("{} exists", path.display())));
                }
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent)
                        .map_err(|e| super::paths::io_error(parent, &e))?;
                }
                let path_str = path.to_string_lossy().into_owned();
                git(
                    &main,
                    &["worktree", "add", "--detach", "--", &path_str, "HEAD"],
                )?;
                let fallback = format!("pr-{}", checkout.number);
                let res = gh::checkout(&gh, &path, checkout.number, None)
                    .or_else(|_| gh::checkout(&gh, &path, checkout.number, Some(&fallback)));
                if let Err(e) = res {
                    let _ = git(&main, &["worktree", "remove", "--force", "--", &path_str]);
                    return Err(e);
                }
                let port = core2.ws.worktrees.allocate(&path);
                core2.ws.worktrees.mark_managed(&path);
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
            Ok(A::Worktree(made))
        }
        R::WorktreeArchive { path, force } => {
            let path = policy.resolve(&path)?;
            let core2 = Arc::clone(core);
            blocking(move || {
                let main = main_of(&path).ok();
                let (_, hooks) = repo::read_config(&path, main.as_deref());
                core2.ws.worktrees.archive(
                    &path,
                    force,
                    hooks.teardown.as_deref(),
                    crate::identity::now_millis(),
                )
            })
            .await?;
            repos.relist();
            Ok(A::Done)
        }
        R::WorktreeArchived { repo } => {
            let main = match repo {
                Some(r) => {
                    let dir = existing_dir(policy, &r)?;
                    Some(blocking(move || main_of(&dir)).await?)
                        .map(|m| m.canonicalize().unwrap_or(m))
                }
                None => None,
            };
            Ok(A::Archived(core.ws.worktrees.archived(main.as_deref())))
        }
        R::WorktreeRestore { id } => {
            let core2 = Arc::clone(core);
            let info = blocking(move || core2.ws.worktrees.restore(id)).await?;
            repos.relist();
            Ok(A::Worktree(info))
        }
        R::WorktreeSettings(set) => Ok(A::WorktreeSettings(core.ws.worktrees.settings(set))),
        R::TaskCreate(task) => {
            let dir = existing_dir(policy, &task.repo)?;
            let core2 = Arc::clone(core);
            let root = worktree_root.to_owned();
            let name = task.name.clone();
            let explicit = task.branch.clone();
            let base = task.base.clone();
            let (info, hooks) = blocking(move || {
                let repo_root = git::toplevel(&dir)?;
                let branch = match explicit {
                    Some(b) => b,
                    None => {
                        let slug = branch_slug(&name);
                        (1..100)
                            .map(|i| {
                                if i == 1 {
                                    slug.clone()
                                } else {
                                    format!("{slug}-{i}")
                                }
                            })
                            .find(|b| !branch_exists(&repo_root, b))
                            .unwrap_or(slug)
                    }
                };
                let info = core2.ws.worktrees.create(
                    &WorktreeCreate {
                        repo: repo_root.to_string_lossy().into_owned(),
                        branch: Some(branch),
                        base,
                        path: None,
                    },
                    &root,
                )?;
                let main = main_of(Path::new(&info.path)).ok();
                let (_, hooks) = repo::read_config(Path::new(&info.path), main.as_deref());
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
                    Ok(A::TaskCreated(proto::TaskCreated {
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
                        o => format!("unexpected outcome {o:?}"),
                    }))
                }
            }
        }
        R::ScriptRun(run) => {
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
                OpOutcome::TabCreated { pane_id, .. } => Ok(A::PaneCreated { pane_id }),
                other => {
                    if script {
                        let _ = repos.take_pre_command(&dir);
                    }
                    Err(WsError::Failed(match other {
                        OpOutcome::Failed { message, .. } => message,
                        o => format!("unexpected outcome {o:?}"),
                    }))
                }
            }
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
