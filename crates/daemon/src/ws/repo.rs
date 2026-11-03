//! The git-native workspace (`proto::repo`): which worktree every pane is in, each
//! worktree's branch, upstream distance, `+added −removed` against `HEAD` and dirty state, its
//! pull request through the host's `gh`, and auto-delete of merged worktrees.
//!
//! One task ([`run`]) owns the state. It only watches and reads while a client with
//! `Caps::REPO_STATUS` is connected ([`Repos::watch`]):
//!
//! - **Panes → worktrees**: each pane's directory (OSC 7, else its launch directory) is
//!   resolved with `git rev-parse --show-toplevel`, cached for a while per directory.
//! - **Repositories**: every repository a pane is in is listed (`git worktree list`), so the
//!   sidebar also shows its worktrees without panes.
//! - **Reading** a worktree is `git status --porcelain=v2`, `git diff --numstat HEAD` and the
//!   line counts of untracked files (capped), all with `GIT_OPTIONAL_LOCKS=0` so reading never
//!   touches the index (and never triggers its own file events).
//! - **When**: a file event under the worktree (recursive FSEvents on macOS; the top level
//!   and the git directory elsewhere, where recursive inotify would need a watch per
//!   directory), debounced; any finished command or agent turn in a pane (shell integration
//!   and hooks); and a slow poll as a safety net. A worktree is read at most once per
//!   debounce period.
//! - **Pull requests**: `gh pr view <branch> --json …` per worktree branch, on its own
//!   schedule (running checks often, settled ones rarely, none rarely), with exponential
//!   back-off on errors and none at all while `gh` is missing or signed out.
//!
//! The whole [`RepoSnapshot`] goes out whenever it changes (`Event::Repos`).
//!
//! Merged worktrees the daemon created are removed `auto_delete_merged_days` after the merge
//! was first seen, by a sweep that runs whether or not anyone watches — never one with
//! uncommitted changes (the snapshot shows it as merged and dirty, and the app asks).

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use notify::{RecursiveMode, Watcher};
use proto::{
    CheckStatus, GhStatus, PaneRepo, PrState, PullRequest, RepoHooks, RepoScript, RepoSnapshot,
    UnixMillis, WorktreeState, WsError,
};
use serde::Deserialize;
use tokio::sync::{Notify, mpsc, oneshot};

use super::gh::{self, ViewError};
use super::git::git;
use crate::core::{Core, Event, lock};

const ROOT_TTL: Duration = Duration::from_secs(20);
/// How often a repository's worktree list is re-read without an event.
const LIST_TTL: Duration = Duration::from_secs(30);
/// How often `gh auth status` is asked again while `gh` is not ready.
const GH_RECHECK: Duration = Duration::from_secs(300);
/// Untracked files counted for `+added`, at most this many and this large.
const MAX_UNTRACKED: usize = 500;
const MAX_UNTRACKED_BYTES: u64 = 1 << 20;

/// `.<product>.json` at a worktree's top level.
pub(crate) fn config_file_name() -> String {
    format!(".{}.json", brand::DIR_NAME)
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct ConfigFile {
    setup: Option<String>,
    teardown: Option<String>,
    scripts: Vec<ScriptFile>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct ScriptFile {
    name: String,
    command: String,
    icon: Option<String>,
    tint: Option<String>,
    default: bool,
}

/// Scripts and hooks of the worktree at `root` (falling back to the main worktree's file).
pub(crate) fn read_config(root: &Path, main: Option<&Path>) -> (Vec<RepoScript>, RepoHooks) {
    let name = config_file_name();
    let file = std::iter::once(root)
        .chain(main)
        .map(|dir| dir.join(&name))
        .find(|candidate| candidate.is_file());
    let Some(file) = file else {
        return (Vec::new(), RepoHooks::default());
    };
    match std::fs::read(&file) {
        Ok(bytes) => parse_config(&bytes, &file.display().to_string()),
        Err(_) => (Vec::new(), RepoHooks::default()),
    }
}

/// The hooks of the worktree at `root` that may run: only commands the owner trusts in its
/// repository (`main`, the main worktree), see [`super::trust`].
pub(crate) fn runnable_hooks(core: &Core, root: &Path, main: Option<&Path>) -> RepoHooks {
    let (_, hooks) = read_config(root, main);
    core.ws.hook_trust.runnable(main.unwrap_or(root), hooks)
}

/// Scripts and hooks from a config file's contents (`what` names it in the log).
pub(crate) fn parse_config(bytes: &[u8], what: &str) -> (Vec<RepoScript>, RepoHooks) {
    let parsed: ConfigFile = match serde_json::from_slice(bytes) {
        Ok(config) => config,
        Err(error) => {
            tracing::info!("{what}: {error}");
            return (Vec::new(), RepoHooks::default());
        }
    };
    let nonempty = |text: Option<String>| text.filter(|text| !text.trim().is_empty());
    let scripts = parsed
        .scripts
        .into_iter()
        .filter(|script| !script.name.trim().is_empty() && !script.command.trim().is_empty())
        .map(|script| RepoScript {
            name: script.name,
            command: script.command,
            icon: nonempty(script.icon),
            tint: nonempty(script.tint),
            default: script.default,
        })
        .collect();
    (
        scripts,
        RepoHooks {
            setup: nonempty(parsed.setup),
            teardown: nonempty(parsed.teardown),
        },
    )
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct GitSummary {
    branch: Option<String>,
    head: Option<String>,
    upstream: Option<String>,
    ahead: u32,
    behind: u32,
    added: u32,
    removed: u32,
    changed_files: u32,
}

/// Blocks.
fn read_git(root: &Path) -> Result<GitSummary, WsError> {
    let status = super::git::status(root)?;
    let mut added = 0u32;
    let mut removed = 0u32;
    // Tracked changes, staged and unstaged, against HEAD (or the empty tree before the
    // first commit).
    let base = if status.head.is_some() {
        "HEAD".to_owned()
    } else {
        String::from_utf8_lossy(&git(root, &["hash-object", "-t", "tree", "/dev/null"])?)
            .trim()
            .to_owned()
    };
    let numstat = git(
        root,
        &[
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--numstat",
            "-z",
            "--no-renames",
            &base,
            "--",
        ],
    )?;
    for record in numstat.split(|&byte| byte == 0) {
        let mut fields = record.split(|&byte| byte == b'\t');
        let (Some(added_field), Some(removed_field)) = (fields.next(), fields.next()) else {
            continue;
        };
        // Binary files show `-`.
        added += std::str::from_utf8(added_field)
            .ok()
            .and_then(|count| count.parse::<u32>().ok())
            .unwrap_or(0);
        removed += std::str::from_utf8(removed_field)
            .ok()
            .and_then(|count| count.parse::<u32>().ok())
            .unwrap_or(0);
    }
    let untracked = git(root, &["ls-files", "--others", "--exclude-standard", "-z"])?;
    for name in untracked
        .split(|&byte| byte == 0)
        .filter(|name| !name.is_empty())
        .take(MAX_UNTRACKED)
    {
        added = added.saturating_add(count_lines(
            &root.join(String::from_utf8_lossy(name).as_ref()),
        ));
    }
    Ok(GitSummary {
        branch: status.branch,
        head: status.head,
        upstream: status.upstream,
        ahead: status.ahead,
        behind: status.behind,
        added,
        removed,
        changed_files: u32::try_from(status.files.len()).unwrap_or(u32::MAX),
    })
}

/// Lines in a small text file (0 for binary or large files), as `git diff` would count them.
fn count_lines(path: &Path) -> u32 {
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        return 0;
    };
    if !meta.is_file() || meta.len() > MAX_UNTRACKED_BYTES {
        return 0;
    }
    let Ok(data) = std::fs::read(path) else {
        return 0;
    };
    if data[..data.len().min(8000)].contains(&0) {
        return 0;
    }
    let newlines = data.iter().filter(|&&byte| byte == b'\n').count();
    let partial = usize::from(data.last().is_some_and(|&byte| byte != b'\n'));
    u32::try_from(newlines + partial).unwrap_or(u32::MAX)
}

fn now() -> UnixMillis {
    UnixMillis(crate::identity::now_millis())
}

enum TrackerRequest {
    /// Read everything now (and the pull request of `pr`, or of every worktree when
    /// `all_prs`), then answer with the snapshot.
    Refresh {
        pr: Option<PathBuf>,
        all_prs: bool,
        reply: oneshot::Sender<RepoSnapshot>,
    },
    /// A request changed a worktree's pull request: here it is.
    Pr(PathBuf, Option<PullRequest>),
    /// Worktrees were created or removed: list repositories again.
    Relist,
}

pub(crate) struct Repos {
    watchers: AtomicUsize,
    wake: Notify,
    requests: mpsc::UnboundedSender<TrackerRequest>,
    request_rx: Mutex<Option<mpsc::UnboundedReceiver<TrackerRequest>>>,
    snapshot: Mutex<Arc<RepoSnapshot>>,
    /// Commands to run first in the next pane started in a directory (setup, scripts).
    pre_commands: Mutex<Vec<(PathBuf, String)>>,
}

impl Repos {
    pub fn new() -> Self {
        let (requests, request_rx) = mpsc::unbounded_channel();
        Self {
            watchers: AtomicUsize::new(0),
            wake: Notify::new(),
            requests,
            request_rx: Mutex::new(Some(request_rx)),
            snapshot: Mutex::new(Arc::new(RepoSnapshot {
                rev: 0,
                panes: Vec::new(),
                worktrees: Vec::new(),
                gh: GhStatus::Unknown,
            })),
            pre_commands: Mutex::new(Vec::new()),
        }
    }

    /// A client with `Caps::REPO_STATUS` connected (`true`) or left.
    pub fn watch(&self, connected: bool) {
        if connected {
            self.watchers.fetch_add(1, Ordering::AcqRel);
        } else {
            self.watchers.fetch_sub(1, Ordering::AcqRel);
        }
        self.wake.notify_one();
    }

    pub fn snapshot(&self) -> Arc<RepoSnapshot> {
        Arc::clone(&lock(&self.snapshot))
    }

    pub fn queue_pre_command(&self, dir: &Path, command: &str) {
        let dir = dir.canonicalize().unwrap_or_else(|_| dir.to_owned());
        // Show what runs, dimmed, like a typed command.
        let shown = crate::core::shell_quote(&format!("› {command}"));
        let line = format!("printf '\\033[2m%s\\033[0m\\n' {shown}; {command}");
        lock(&self.pre_commands).push((dir, line));
    }

    pub fn take_pre_command(&self, dir: &Path) -> Option<String> {
        let mut pre_commands = lock(&self.pre_commands);
        if pre_commands.is_empty() {
            return None;
        }
        let dir = dir.canonicalize().unwrap_or_else(|_| dir.to_owned());
        let index = pre_commands.iter().position(|(queued, _)| *queued == dir)?;
        Some(pre_commands.remove(index).1)
    }

    /// Reads everything now and returns the snapshot (`RepoRefresh`).
    pub async fn refresh(&self, pr: Option<PathBuf>) -> Result<RepoSnapshot, WsError> {
        let (reply, reply_rx) = oneshot::channel();
        let all_prs = pr.is_none();
        self.requests
            .send(TrackerRequest::Refresh { pr, all_prs, reply })
            .map_err(|_| WsError::Failed("the repository tracker stopped".into()))?;
        reply_rx
            .await
            .map_err(|_| WsError::Failed("the repository tracker stopped".into()))
    }

    pub fn pr_changed(&self, path: PathBuf, pr: Option<PullRequest>) {
        let _ = self.requests.send(TrackerRequest::Pr(path, pr));
    }

    /// Worktrees were created or removed.
    pub fn relist(&self) {
        let _ = self.requests.send(TrackerRequest::Relist);
    }
}

struct TrackedWorktree {
    state: WorktreeState,
    /// A pane is in it.
    active: bool,
    /// Read once this passes (debounced file event or command).
    due: Option<Instant>,
    read_at: Option<Instant>,
    pr_at: Instant,
    pr_fail: u32,
    pr_inflight: bool,
    /// The repository has no GitHub remote: stop asking.
    not_github: bool,
}

struct Tracker {
    core: Arc<Core>,
    roots: HashMap<String, (Option<PathBuf>, Instant)>,
    /// Main worktree → its worktrees' directories, and when listed.
    repos: BTreeMap<PathBuf, (Vec<proto::WorktreeInfo>, Instant)>,
    worktrees: BTreeMap<PathBuf, TrackedWorktree>,
    panes: Vec<PaneRepo>,
    fs_watches: HashMap<PathBuf, Vec<notify::RecommendedWatcher>>,
    fs_tx: mpsc::UnboundedSender<PathBuf>,
    gh_path: Option<PathBuf>,
    gh: GhStatus,
    gh_at: Option<Instant>,
    gh_inflight: bool,
    results: mpsc::UnboundedSender<Done>,
    rev: u64,
}

enum Done {
    Pr(PathBuf, Result<Option<PullRequest>, ViewError>),
    Gh(GhStatus),
}

pub(crate) async fn run(core: Arc<Core>) {
    let repos = &core.ws.repos;
    let Some(mut requests) = lock(&repos.request_rx).take() else {
        return;
    };
    let (fs_tx, mut fs_rx) = mpsc::unbounded_channel();
    let (results, mut done_rx) = mpsc::unbounded_channel();
    let mut events = core.events.subscribe();
    let config = core.cfg.repos.clone();
    let mut tracker = Tracker {
        core: Arc::clone(&core),
        roots: HashMap::new(),
        repos: BTreeMap::new(),
        worktrees: BTreeMap::new(),
        panes: Vec::new(),
        fs_watches: HashMap::new(),
        fs_tx,
        gh_path: None,
        gh: GhStatus::Unknown,
        gh_at: None,
        gh_inflight: false,
        results,
        rev: 0,
    };
    let mut sweep_at = Instant::now() + config.sweep.min(Duration::from_secs(60));
    loop {
        if core.shutting_down.load(Ordering::Acquire) {
            return;
        }
        let watched = repos.watchers.load(Ordering::Acquire) > 0;
        if !watched && !tracker.fs_watches.is_empty() {
            tracker.fs_watches.clear();
        }
        let tick = if watched {
            Duration::from_millis(250)
        } else {
            sweep_at.saturating_duration_since(Instant::now())
        };
        let mut reply = None;
        tokio::select! {
            () = repos.wake.notified() => {}
            () = tokio::time::sleep(tick) => {}
            Some(request) = requests.recv() => match request {
                TrackerRequest::Refresh { pr, all_prs, reply: reply_to } => {
                    tracker.resolve_panes().await;
                    tracker.list_repos(true).await;
                    for worktree in tracker.worktrees.values_mut() {
                        worktree.due = Some(Instant::now());
                    }
                    tracker.read_due(&config, true).await;
                    tracker.refresh_prs_now(pr.as_deref(), all_prs).await;
                    reply = Some(reply_to);
                }
                TrackerRequest::Pr(path, pr) => tracker.apply_pr(&path, Ok(pr)),
                TrackerRequest::Relist => {
                    for (_, listed_at) in tracker.repos.values_mut() {
                        *listed_at = Instant::now() - LIST_TTL;
                    }
                }
            },
            Some(root) = fs_rx.recv() => tracker.touched(&root, config.debounce),
            Some(done) = done_rx.recv() => match done {
                Done::Pr(path, result) => tracker.apply_pr(&path, result),
                Done::Gh(status) => {
                    tracker.gh_inflight = false;
                    tracker.gh_at = Some(Instant::now());
                    tracker.gh = status;
                }
            },
            event = events.recv() => match event {
                // A command finished or an agent did something: its worktree may have changed.
                Ok(Event::Command(mark)) if mark.finished.is_some() => tracker.pane_touched(mark.pane_id, config.debounce),
                Ok(Event::Agent { pane_id, .. }) => tracker.pane_touched(pane_id, config.debounce),
                Ok(_) => {}
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(_) => return,
            },
        }
        if watched || reply.is_some() {
            if reply.is_none() {
                tracker.resolve_panes().await;
                tracker.list_repos(false).await;
                tracker.read_due(&config, false).await;
                tracker.ensure_watches();
                tracker.schedule_prs(&config);
            }
            tracker.publish();
        }
        if let Some(reply) = reply {
            let _ = reply.send((*repos.snapshot()).clone());
        }
        if Instant::now() >= sweep_at {
            sweep(&core, &mut tracker).await;
            sweep_at = Instant::now() + config.sweep;
        }
    }
}

impl Tracker {
    async fn resolve_panes(&mut self) {
        let mut cwds: Vec<(proto::PaneId, String)> = Vec::new();
        for (id, entry) in self.core.pane_entries() {
            let reported = lock(&entry.meta).cwd.clone();
            let cwd = reported.or_else(|| lock(&entry.record).cwd.clone());
            if let Some(cwd) = cwd {
                cwds.push((id, cwd));
            }
        }
        let stale: Vec<String> = cwds
            .iter()
            .map(|(_, cwd)| cwd.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .filter(|cwd| {
                self.roots
                    .get(cwd)
                    .is_none_or(|(_, resolved_at)| resolved_at.elapsed() > ROOT_TTL)
            })
            .collect();
        if !stale.is_empty() {
            let home = self.core.cfg.home();
            let answers = tokio::task::spawn_blocking(move || {
                stale
                    .into_iter()
                    .map(|cwd| {
                        let root = super::git::toplevel(Path::new(&cwd))
                            .ok()
                            .map(|root| root.canonicalize().unwrap_or(root))
                            .filter(|root| !super::paths::holds_home(root, &home));
                        (cwd, root)
                    })
                    .collect::<Vec<_>>()
            })
            .await
            .unwrap_or_default();
            for (cwd, root) in answers {
                self.roots.insert(cwd, (root, Instant::now()));
            }
        }
        let mut panes: Vec<PaneRepo> = cwds
            .into_iter()
            .filter_map(|(pane_id, cwd)| {
                let root = self.roots.get(&cwd)?.0.as_ref()?;
                Some(PaneRepo {
                    pane_id,
                    worktree: root.to_string_lossy().into_owned(),
                })
            })
            .collect();
        panes.sort_by_key(|pane| pane.pane_id);
        let active: BTreeSet<PathBuf> = panes
            .iter()
            .map(|pane| PathBuf::from(&pane.worktree))
            .collect();
        for (path, worktree) in &mut self.worktrees {
            let was_active = worktree.active;
            worktree.active = active.contains(path);
            if worktree.active && !was_active {
                worktree.due = Some(Instant::now());
            }
        }
        // A pane in a worktree the tracker has not listed yet: list its repository.
        if active.iter().any(|path| !self.worktrees.contains_key(path)) {
            for (_, listed_at) in self.repos.values_mut() {
                *listed_at = Instant::now() - LIST_TTL;
            }
            let unknown: Vec<PathBuf> = active
                .iter()
                .filter(|path| !self.worktrees.contains_key(*path))
                .cloned()
                .collect();
            self.list_new(unknown).await;
        }
        self.panes = panes;
    }

    async fn list_new(&mut self, roots: Vec<PathBuf>) {
        let listed = tokio::task::spawn_blocking(move || {
            roots
                .into_iter()
                .filter_map(|root| list_worktrees(&root).ok())
                .collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        for (main, list) in listed {
            self.repos.insert(main, (list, Instant::now()));
        }
        self.sync_worktrees();
    }

    /// Re-lists repositories whose list is old (or all with `force`) and drops repositories
    /// no pane is in any more.
    async fn list_repos(&mut self, force: bool) {
        let active: BTreeSet<PathBuf> = self
            .panes
            .iter()
            .map(|pane| PathBuf::from(&pane.worktree))
            .collect();
        // A repository stays while one of its worktrees has a pane.
        self.repos.retain(|_, (list, _)| {
            list.iter()
                .any(|worktree| active.contains(&canonical(&worktree.path)))
        });
        let stale: Vec<PathBuf> = self
            .repos
            .iter()
            .filter(|(_, (_, listed_at))| force || listed_at.elapsed() >= LIST_TTL)
            .map(|(main, _)| main.clone())
            .collect();
        if !stale.is_empty() {
            let listed = tokio::task::spawn_blocking(move || {
                stale
                    .into_iter()
                    .filter_map(|root| list_worktrees(&root).ok())
                    .collect::<Vec<_>>()
            })
            .await
            .unwrap_or_default();
            for (main, list) in listed {
                self.repos.insert(main, (list, Instant::now()));
            }
        }
        self.sync_worktrees();
    }

    /// Makes `worktrees` match the listed repositories.
    fn sync_worktrees(&mut self) {
        let mut seen = BTreeSet::new();
        for (main, (list, _)) in &self.repos {
            let repo_name = file_name(main);
            for info in list.iter().filter(|worktree| !worktree.prunable) {
                let path = canonical(&info.path);
                seen.insert(path.clone());
                let managed = self.core.ws.worktrees.is_managed(&path);
                let entry = self
                    .worktrees
                    .entry(path.clone())
                    .or_insert_with(|| TrackedWorktree {
                        state: WorktreeState {
                            path: path.to_string_lossy().into_owned(),
                            repo: main.to_string_lossy().into_owned(),
                            repo_name: repo_name.clone(),
                            name: file_name(&path),
                            main: info.main,
                            branch: info.branch.clone(),
                            head: info.head.clone(),
                            upstream: None,
                            ahead: 0,
                            behind: 0,
                            added: 0,
                            removed: 0,
                            changed_files: 0,
                            dirty: false,
                            pr: None,
                            scripts: Vec::new(),
                            hooks: RepoHooks::default(),
                            managed,
                            merged_at: None,
                            updated_at: UnixMillis(0),
                        },
                        active: false,
                        due: Some(Instant::now()),
                        read_at: None,
                        pr_at: Instant::now(),
                        pr_fail: 0,
                        pr_inflight: false,
                        not_github: false,
                    });
                entry.state.managed = managed;
                entry.state.main = info.main;
            }
        }
        self.worktrees.retain(|path, _| seen.contains(path));
        let active: BTreeSet<PathBuf> = self
            .panes
            .iter()
            .map(|pane| PathBuf::from(&pane.worktree))
            .collect();
        for (path, worktree) in &mut self.worktrees {
            worktree.active = active.contains(path);
        }
    }

    fn touched(&mut self, root: &Path, debounce: Duration) {
        if let Some(worktree) = self.worktrees.get_mut(root) {
            let deadline = Instant::now() + debounce;
            // Keep the earliest pending deadline so a stream of events cannot starve reads.
            if worktree.due.is_none_or(|due| due > deadline) {
                worktree.due = Some(deadline);
            }
        }
    }

    fn pane_touched(&mut self, pane: proto::PaneId, debounce: Duration) {
        if let Some(root) = self
            .panes
            .iter()
            .find(|repo| repo.pane_id == pane)
            .map(|repo| PathBuf::from(&repo.worktree))
        {
            self.touched(&root, debounce);
        }
    }

    /// Reads worktrees that are due (or every one with `all`).
    async fn read_due(&mut self, config: &crate::config::RepoConfig, all: bool) {
        let now = Instant::now();
        let mains: HashMap<PathBuf, PathBuf> = self
            .worktrees
            .iter()
            .map(|(path, worktree)| (path.clone(), PathBuf::from(&worktree.state.repo)))
            .collect();
        let due: Vec<PathBuf> = self
            .worktrees
            .iter()
            .filter(|(_, worktree)| {
                let poll = if worktree.active {
                    config.poll
                } else {
                    config.idle_poll
                };
                all || worktree.due.is_some_and(|due| due <= now)
                    || worktree
                        .read_at
                        .is_none_or(|read_at| read_at.elapsed() >= poll)
            })
            // At most one read per debounce period per worktree.
            .filter(|(_, worktree)| {
                all || worktree
                    .read_at
                    .is_none_or(|read_at| read_at.elapsed() >= config.debounce)
            })
            .map(|(path, _)| path.clone())
            .collect();
        if due.is_empty() {
            return;
        }
        let read = tokio::task::spawn_blocking(move || {
            due.into_iter()
                .map(|path| {
                    let summary = read_git(&path);
                    let config = read_config(&path, mains.get(&path).map(PathBuf::as_path));
                    (path, summary, config)
                })
                .collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        let stamp = now_ms();
        for (path, summary, (scripts, hooks)) in read {
            let Some(worktree) = self.worktrees.get_mut(&path) else {
                continue;
            };
            worktree.read_at = Some(Instant::now());
            worktree.due = None;
            let Ok(summary) = summary else {
                continue;
            };
            let state = &mut worktree.state;
            let before = (
                state.branch.clone(),
                state.head.clone(),
                state.upstream.clone(),
                state.ahead,
                state.behind,
                state.added,
                state.removed,
                state.changed_files,
            );
            if state.branch != summary.branch {
                // A new branch: its pull request is another one.
                state.pr = None;
                worktree.pr_at = Instant::now();
                worktree.pr_fail = 0;
            }
            if state.head != summary.head || state.ahead != summary.ahead {
                // Commits or a push: checks may have started.
                worktree.pr_at = worktree.pr_at.min(Instant::now() + Duration::from_secs(5));
            }
            state.branch = summary.branch;
            state.head = summary.head;
            state.upstream = summary.upstream;
            state.ahead = summary.ahead;
            state.behind = summary.behind;
            state.added = summary.added;
            state.removed = summary.removed;
            state.changed_files = summary.changed_files;
            state.dirty = summary.changed_files > 0;
            state.scripts = scripts;
            state.hooks = hooks;
            let after = (
                state.branch.clone(),
                state.head.clone(),
                state.upstream.clone(),
                state.ahead,
                state.behind,
                state.added,
                state.removed,
                state.changed_files,
            );
            if before != after || state.updated_at.0 == 0 {
                state.updated_at = UnixMillis(stamp);
            }
        }
    }

    /// Also stops watching worktrees without panes.
    fn ensure_watches(&mut self) {
        let active: BTreeSet<PathBuf> = self
            .worktrees
            .iter()
            .filter(|(_, worktree)| worktree.active)
            .map(|(path, _)| path.clone())
            .collect();
        self.fs_watches.retain(|path, _| active.contains(path));
        for root in active {
            if self.fs_watches.contains_key(&root) {
                continue;
            }
            match watch_worktree(&root, self.fs_tx.clone()) {
                Ok(watchers) => {
                    self.fs_watches.insert(root, watchers);
                }
                Err(error) => {
                    tracing::debug!("watching {}: {error}", root.display());
                    // Polling still covers it; do not try again every tick.
                    self.fs_watches.insert(root, Vec::new());
                }
            }
        }
    }

    /// Starts `gh` lookups that are due.
    fn schedule_prs(&mut self, config: &crate::config::RepoConfig) {
        let needs_gh = self
            .worktrees
            .values()
            .any(|worktree| worktree.state.branch.is_some());
        if !needs_gh {
            return;
        }
        let ready = matches!(self.gh, GhStatus::Ready { .. });
        if !self.gh_inflight
            && (self.gh_at.is_none()
                || (!ready
                    && self
                        .gh_at
                        .is_some_and(|asked_at| asked_at.elapsed() >= GH_RECHECK)))
        {
            self.gh_inflight = true;
            self.gh_path = gh::find(self.core.cfg.repos.gh.as_deref());
            let path = self.gh_path.clone();
            let tx = self.results.clone();
            tokio::task::spawn_blocking(move || {
                let _ = tx.send(Done::Gh(gh::auth_status(path.as_deref())));
            });
        }
        let (true, Some(gh_path)) = (ready, self.gh_path.clone()) else {
            return;
        };
        let now = Instant::now();
        for (path, worktree) in &mut self.worktrees {
            let Some(branch) = worktree.state.branch.clone() else {
                continue;
            };
            if worktree.pr_inflight || worktree.not_github || worktree.pr_at > now {
                continue;
            }
            worktree.pr_inflight = true;
            // Placeholder until the answer lands; `apply_pr` sets the real schedule.
            worktree.pr_at = now + config.pr_poll;
            let tx = self.results.clone();
            let gh_path = gh_path.clone();
            let path = path.clone();
            tokio::task::spawn_blocking(move || {
                let result = gh::pr_view(&gh_path, &path, &branch, now_millis());
                let _ = tx.send(Done::Pr(path, result));
            });
        }
    }

    /// Asks `gh` right now, for a refresh request.
    async fn refresh_prs_now(&mut self, only: Option<&Path>, all: bool) {
        if !matches!(self.gh, GhStatus::Ready { .. }) {
            self.gh_path = gh::find(self.core.cfg.repos.gh.as_deref());
            let path = self.gh_path.clone();
            self.gh = tokio::task::spawn_blocking(move || gh::auth_status(path.as_deref()))
                .await
                .unwrap_or(GhStatus::Unknown);
            self.gh_at = Some(Instant::now());
        }
        let Some(gh_path) = self
            .gh_path
            .clone()
            .filter(|_| matches!(self.gh, GhStatus::Ready { .. }))
        else {
            return;
        };
        let targets: Vec<(PathBuf, String)> = self
            .worktrees
            .iter()
            .filter(|(path, worktree)| {
                (all || only.is_some_and(|only| only == path.as_path())) && !worktree.not_github
            })
            .filter_map(|(path, worktree)| Some((path.clone(), worktree.state.branch.clone()?)))
            .collect();
        let answers = tokio::task::spawn_blocking(move || {
            targets
                .into_iter()
                .map(|(path, branch)| {
                    let result = gh::pr_view(&gh_path, &path, &branch, now_millis());
                    (path, result)
                })
                .collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        for (path, result) in answers {
            self.apply_pr(&path, result);
        }
    }

    fn apply_pr(&mut self, path: &Path, result: Result<Option<PullRequest>, ViewError>) {
        let pr_poll = self.core.cfg.repos.pr_poll;
        let Some(worktree) = self.worktrees.get_mut(path) else {
            return;
        };
        worktree.pr_inflight = false;
        match result {
            Ok(pr) => {
                worktree.pr_fail = 0;
                worktree.pr_at = Instant::now()
                    + match &pr {
                        None => pr_poll * 10,
                        Some(pr) if pr.state != PrState::Open => pr_poll * 30,
                        Some(pr)
                            if pr
                                .checks
                                .iter()
                                .any(|check| check.status == CheckStatus::Pending) =>
                        {
                            pr_poll
                        }
                        Some(_) => pr_poll * 4,
                    };
                let merged = pr.as_ref().is_some_and(|pr| pr.state == PrState::Merged);
                worktree.state.merged_at = self
                    .core
                    .ws
                    .worktrees
                    .merged_since(path, merged, now_millis().0)
                    .map(UnixMillis);
                worktree.state.pr = pr;
            }
            Err(ViewError::NotGitHub) => {
                worktree.not_github = true;
                worktree.state.pr = None;
            }
            Err(ViewError::Missing) => {
                self.gh = GhStatus::Missing;
                self.gh_at = Some(Instant::now());
            }
            Err(ViewError::Auth(message)) => {
                self.gh = GhStatus::NotAuthenticated { message };
                self.gh_at = Some(Instant::now());
            }
            Err(ViewError::Other(error)) => {
                tracing::debug!("gh pr view in {}: {error}", path.display());
                worktree.pr_fail = (worktree.pr_fail + 1).min(6);
                // 1, 2, 4 … 32 minutes.
                worktree.pr_at = Instant::now() + Duration::from_secs(60 << (worktree.pr_fail - 1));
            }
        }
    }

    /// Sends the snapshot if anything changed.
    fn publish(&mut self) {
        let mut worktrees: Vec<WorktreeState> = self
            .worktrees
            .values()
            .map(|worktree| worktree.state.clone())
            .collect();
        worktrees.sort_by(|a, b| {
            (
                a.repo_name.to_lowercase(),
                &a.repo,
                !a.main,
                a.name.to_lowercase(),
            )
                .cmp(&(
                    b.repo_name.to_lowercase(),
                    &b.repo,
                    !b.main,
                    b.name.to_lowercase(),
                ))
        });
        let repos = &self.core.ws.repos;
        let current = repos.snapshot();
        if current.rev > 0
            && current.panes == self.panes
            && current.worktrees == worktrees
            && current.gh == self.gh
        {
            return;
        }
        self.rev += 1;
        let snapshot = RepoSnapshot {
            rev: self.rev,
            panes: self.panes.clone(),
            worktrees,
            gh: self.gh.clone(),
        };
        *lock(&repos.snapshot) = Arc::new(snapshot);
        self.core.emit(Event::Repos);
    }
}

fn now_millis() -> UnixMillis {
    now()
}

fn now_ms() -> u64 {
    crate::identity::now_millis()
}

fn canonical(path: impl AsRef<Path>) -> PathBuf {
    let path = path.as_ref();
    path.canonicalize().unwrap_or_else(|_| path.to_owned())
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string_lossy().into_owned())
}

/// The repository's main worktree and its worktrees.
fn list_worktrees(root: &Path) -> Result<(PathBuf, Vec<proto::WorktreeInfo>), WsError> {
    let porcelain = git(root, &["worktree", "list", "--porcelain", "-z"])?;
    let list = super::worktree::parse_list(&porcelain);
    let main = list
        .iter()
        .find(|worktree| worktree.main)
        .map(|worktree| canonical(&worktree.path))
        .ok_or_else(|| WsError::Failed("no main worktree".into()))?;
    Ok((main, list))
}

/// Watches a worktree for changes that matter: files (recursively where the platform does
/// it cheaply) and its git directory (HEAD, index, refs).
fn watch_worktree(
    root: &Path,
    tx: mpsc::UnboundedSender<PathBuf>,
) -> Result<Vec<notify::RecommendedWatcher>, notify::Error> {
    let gitdir = git(root, &["rev-parse", "--absolute-git-dir"])
        .map(|stdout| PathBuf::from(String::from_utf8_lossy(&stdout).trim()))
        .ok();
    let common = git(root, &["rev-parse", "--git-common-dir"])
        .map(|stdout| root.join(String::from_utf8_lossy(&stdout).trim()))
        .ok()
        .map(canonical);
    let key = root.to_owned();
    let skip_git = gitdir.clone();
    let make = |tx: mpsc::UnboundedSender<PathBuf>, key: PathBuf| {
        let skip_git = skip_git.clone();
        notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
            let Ok(event) = result else {
                let _ = tx.send(key.clone());
                return;
            };
            if matches!(event.kind, notify::EventKind::Access(_)) {
                return;
            }
            let relevant = event
                .paths
                .iter()
                .any(|path| relevant(path, skip_git.as_deref()));
            if relevant {
                let _ = tx.send(key.clone());
            }
        })
    };
    let mut watchers = Vec::new();
    let mut files = make(tx.clone(), key.clone())?;
    let mode = if cfg!(target_os = "macos") {
        RecursiveMode::Recursive
    } else {
        RecursiveMode::NonRecursive
    };
    files.watch(root, mode)?;
    watchers.push(files);
    if let Some(gitdir) = &gitdir
        && !(cfg!(target_os = "macos") && gitdir.starts_with(root))
    {
        let mut gitdir_watcher = make(tx.clone(), key.clone())?;
        gitdir_watcher.watch(gitdir, RecursiveMode::NonRecursive)?;
        watchers.push(gitdir_watcher);
    }
    // Branch heads live in the common directory (shared by every worktree).
    if let Some(heads) = common.map(|common| common.join("refs").join("heads"))
        && heads.is_dir()
        && !(cfg!(target_os = "macos") && heads.starts_with(root))
    {
        let mut heads_watcher = make(tx, key)?;
        heads_watcher.watch(&heads, RecursiveMode::Recursive)?;
        watchers.push(heads_watcher);
    }
    Ok(watchers)
}

/// Whether a changed path can change what the sidebar shows: anything in the worktree, but
/// inside a git directory only HEAD, the index and refs (not objects, logs or locks).
fn relevant(path: &Path, gitdir: Option<&Path>) -> bool {
    let text = path.to_string_lossy();
    if text.ends_with(".lock") {
        return false;
    }
    let in_git = gitdir.is_some_and(|gitdir| path.starts_with(gitdir)) || text.contains("/.git/");
    if !in_git {
        return true;
    }
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    name == "HEAD" || name == "index" || text.contains("/refs/")
}

/// Removes managed worktrees whose pull request merged long enough ago and that are clean.
async fn sweep(core: &Arc<Core>, tracker: &mut Tracker) {
    let worktrees = &core.ws.worktrees;
    let managed = worktrees.managed_paths();
    if managed.is_empty() {
        return;
    }
    // Merge state of managed worktrees the tracker does not follow (no pane in the repo).
    let gh_path = gh::find(core.cfg.repos.gh.as_deref());
    let untracked: Vec<PathBuf> = managed
        .iter()
        .filter(|path| path.is_dir() && !tracker.worktrees.contains_key(*path))
        .cloned()
        .collect();
    let worker_core = Arc::clone(core);
    let _ = tokio::task::spawn_blocking(move || {
        let Some(gh_path) = gh_path else {
            return;
        };
        for path in untracked {
            let Ok(Some(branch)) = super::git::status(&path).map(|status| status.branch) else {
                continue;
            };
            if let Ok(pr) = gh::pr_view(&gh_path, &path, &branch, now()) {
                let merged = pr.is_some_and(|pr| pr.state == PrState::Merged);
                worker_core
                    .ws
                    .worktrees
                    .merged_since(&path, merged, crate::identity::now_millis());
            }
        }
    })
    .await;
    let due = worktrees.due_for_delete(now_ms(), core.cfg.repos.day);
    let mut removed_any = false;
    for path in due {
        let worker_core = Arc::clone(core);
        let removed = tokio::task::spawn_blocking(move || {
            if !path.is_dir() {
                worker_core.ws.worktrees.forget(&path);
                return Ok(false);
            }
            if super::worktree::dirty_count(&path)? > 0 {
                // Never without asking: the app shows it as merged with changes.
                return Ok(false);
            }
            let main = list_worktrees(&path).ok().map(|(main, _)| main);
            let hooks = runnable_hooks(&worker_core, &path, main.as_deref());
            worker_core
                .ws
                .worktrees
                .remove(&path, false, false, hooks.teardown.as_deref())
                .map(|()| {
                    tracing::info!("auto-deleted merged worktree {}", path.display());
                    true
                })
        })
        .await
        .unwrap_or_else(|error| Err(WsError::Failed(error.to_string())));
        match removed {
            Ok(removed) => removed_any |= removed,
            Err(error) => tracing::info!("auto-delete: {error}"),
        }
    }
    if removed_any {
        for (_, listed_at) in tracker.repos.values_mut() {
            *listed_at = Instant::now() - LIST_TTL;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_lines_like_git() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("a");
        std::fs::write(&file, "one\ntwo\nthree").unwrap();
        assert_eq!(count_lines(&file), 3);
        std::fs::write(&file, "one\n").unwrap();
        assert_eq!(count_lines(&file), 1);
        std::fs::write(&file, b"\0bin\n").unwrap();
        assert_eq!(count_lines(&file), 0);
    }

    #[test]
    fn filters_git_internals() {
        let gitdir = Path::new("/r/.git");
        assert!(relevant(Path::new("/r/src/a.rs"), Some(gitdir)));
        assert!(relevant(Path::new("/r/.git/HEAD"), Some(gitdir)));
        assert!(relevant(Path::new("/r/.git/index"), Some(gitdir)));
        assert!(relevant(Path::new("/r/.git/refs/heads/main"), Some(gitdir)));
        assert!(!relevant(
            Path::new("/r/.git/objects/ab/cdef"),
            Some(gitdir)
        ));
        assert!(!relevant(Path::new("/r/.git/index.lock"), Some(gitdir)));
    }

    #[test]
    fn reads_the_config_file() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join(config_file_name()),
            r#"{"setup":"make deps","scripts":[{"name":"Dev","command":"make dev","icon":"play","tint":"green","default":true},{"name":"","command":"x"}]}"#,
        )
        .unwrap();
        let (scripts, hooks) = read_config(dir.path(), None);
        assert_eq!(scripts.len(), 1);
        assert!(scripts[0].default);
        assert_eq!(hooks.setup.as_deref(), Some("make deps"));
        assert_eq!(hooks.teardown, None);
    }
}
