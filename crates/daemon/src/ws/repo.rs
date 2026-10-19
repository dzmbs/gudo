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

/// How long a directory → worktree answer is trusted.
const ROOT_TTL: Duration = Duration::from_secs(20);
/// How often a repository's worktree list is re-read without an event.
const LIST_TTL: Duration = Duration::from_secs(30);
/// How often `gh auth status` is asked again while `gh` is not ready.
const GH_RECHECK: Duration = Duration::from_secs(300);
/// Untracked files counted for `+added`, at most this many and this large.
const MAX_UNTRACKED: usize = 500;
const MAX_UNTRACKED_BYTES: u64 = 1 << 20;

/// The repository config file: `.<product>.json` at a worktree's top level.
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
        .map(|d| d.join(&name))
        .find(|p| p.is_file());
    let Some(file) = file else {
        return (Vec::new(), RepoHooks::default());
    };
    let parsed: ConfigFile = match std::fs::read(&file).ok().and_then(|b| {
        serde_json::from_slice(&b)
            .map_err(|e| tracing::info!("{}: {e}", file.display()))
            .ok()
    }) {
        Some(c) => c,
        None => return (Vec::new(), RepoHooks::default()),
    };
    let nonempty = |s: Option<String>| s.filter(|s| !s.trim().is_empty());
    let scripts = parsed
        .scripts
        .into_iter()
        .filter(|s| !s.name.trim().is_empty() && !s.command.trim().is_empty())
        .map(|s| RepoScript {
            name: s.name,
            command: s.command,
            icon: nonempty(s.icon),
            tint: nonempty(s.tint),
            default: s.default,
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

/// What reading a worktree's git state gives.
#[derive(Debug, Clone, PartialEq, Eq)]
struct GitBits {
    branch: Option<String>,
    head: Option<String>,
    upstream: Option<String>,
    ahead: u32,
    behind: u32,
    added: u32,
    removed: u32,
    changed_files: u32,
}

/// Reads one worktree (blocking).
fn read_git(root: &Path) -> Result<GitBits, WsError> {
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
        &["diff", "--numstat", "-z", "--no-renames", &base, "--"],
    )?;
    for record in numstat.split(|&b| b == 0) {
        let mut fields = record.split(|&b| b == b'\t');
        let (Some(a), Some(r)) = (fields.next(), fields.next()) else {
            continue;
        };
        // Binary files show `-`.
        added += std::str::from_utf8(a)
            .ok()
            .and_then(|s| s.parse::<u32>().ok())
            .unwrap_or(0);
        removed += std::str::from_utf8(r)
            .ok()
            .and_then(|s| s.parse::<u32>().ok())
            .unwrap_or(0);
    }
    let untracked = git(root, &["ls-files", "--others", "--exclude-standard", "-z"])?;
    for name in untracked
        .split(|&b| b == 0)
        .filter(|n| !n.is_empty())
        .take(MAX_UNTRACKED)
    {
        added = added.saturating_add(count_lines(
            &root.join(String::from_utf8_lossy(name).as_ref()),
        ));
    }
    Ok(GitBits {
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
    let newlines = data.iter().filter(|&&b| b == b'\n').count();
    let partial = usize::from(data.last().is_some_and(|&b| b != b'\n'));
    u32::try_from(newlines + partial).unwrap_or(u32::MAX)
}

fn now() -> UnixMillis {
    UnixMillis(crate::identity::now_millis())
}

/// Requests to the tracker task.
enum Cmd {
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

/// Shared handle to the tracker, owned by [`super::Ws`].
pub(crate) struct Repos {
    watchers: AtomicUsize,
    wake: Notify,
    cmds: mpsc::UnboundedSender<Cmd>,
    cmd_rx: Mutex<Option<mpsc::UnboundedReceiver<Cmd>>>,
    snapshot: Mutex<Arc<RepoSnapshot>>,
    /// Commands to run first in the next pane started in a directory (setup, scripts).
    pre: Mutex<Vec<(PathBuf, String)>>,
}

impl Repos {
    pub fn new() -> Self {
        let (cmds, rx) = mpsc::unbounded_channel();
        Self {
            watchers: AtomicUsize::new(0),
            wake: Notify::new(),
            cmds,
            cmd_rx: Mutex::new(Some(rx)),
            snapshot: Mutex::new(Arc::new(RepoSnapshot {
                rev: 0,
                panes: Vec::new(),
                worktrees: Vec::new(),
                gh: GhStatus::Unknown,
            })),
            pre: Mutex::new(Vec::new()),
        }
    }

    /// A client with `Caps::REPO_STATUS` connected (`true`) or left.
    pub fn watch(&self, up: bool) {
        if up {
            self.watchers.fetch_add(1, Ordering::AcqRel);
        } else {
            self.watchers.fetch_sub(1, Ordering::AcqRel);
        }
        self.wake.notify_one();
    }

    pub fn snapshot(&self) -> Arc<RepoSnapshot> {
        Arc::clone(&lock(&self.snapshot))
    }

    /// Queues `command` to run first in the next pane started in `dir`.
    pub fn queue_pre_command(&self, dir: &Path, command: &str) {
        let dir = dir.canonicalize().unwrap_or_else(|_| dir.to_owned());
        // Show what runs, dimmed, like a typed command.
        let shown = crate::core::shell_quote(&format!("› {command}"));
        let line = format!("printf '\\033[2m%s\\033[0m\\n' {shown}; {command}");
        lock(&self.pre).push((dir, line));
    }

    pub fn take_pre_command(&self, dir: &Path) -> Option<String> {
        let mut pre = lock(&self.pre);
        if pre.is_empty() {
            return None;
        }
        let dir = dir.canonicalize().unwrap_or_else(|_| dir.to_owned());
        let at = pre.iter().position(|(d, _)| *d == dir)?;
        Some(pre.remove(at).1)
    }

    /// Reads everything now and returns the snapshot (`RepoRefresh`).
    pub async fn refresh(&self, pr: Option<PathBuf>) -> Result<RepoSnapshot, WsError> {
        let (reply, rx) = oneshot::channel();
        let all_prs = pr.is_none();
        self.cmds
            .send(Cmd::Refresh { pr, all_prs, reply })
            .map_err(|_| WsError::Failed("the repository tracker stopped".into()))?;
        rx.await
            .map_err(|_| WsError::Failed("the repository tracker stopped".into()))
    }

    /// A request changed a worktree's pull request.
    pub fn pr_changed(&self, path: PathBuf, pr: Option<PullRequest>) {
        let _ = self.cmds.send(Cmd::Pr(path, pr));
    }

    /// Worktrees were created or removed.
    pub fn relist(&self) {
        let _ = self.cmds.send(Cmd::Relist);
    }
}

// --- the tracker task ---------------------------------------------------------------------

struct Wt {
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
    wts: BTreeMap<PathBuf, Wt>,
    panes: Vec<PaneRepo>,
    fs: HashMap<PathBuf, Vec<notify::RecommendedWatcher>>,
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

/// Runs the tracker until the daemon shuts down.
pub(crate) async fn run(core: Arc<Core>) {
    let repos = &core.ws.repos;
    let Some(mut cmds) = lock(&repos.cmd_rx).take() else {
        return;
    };
    let (fs_tx, mut fs_rx) = mpsc::unbounded_channel();
    let (results, mut done_rx) = mpsc::unbounded_channel();
    let mut events = core.events.subscribe();
    let cfg = core.cfg.repos.clone();
    let mut t = Tracker {
        core: Arc::clone(&core),
        roots: HashMap::new(),
        repos: BTreeMap::new(),
        wts: BTreeMap::new(),
        panes: Vec::new(),
        fs: HashMap::new(),
        fs_tx,
        gh_path: None,
        gh: GhStatus::Unknown,
        gh_at: None,
        gh_inflight: false,
        results,
        rev: 0,
    };
    let mut sweep_at = Instant::now() + cfg.sweep.min(Duration::from_secs(60));
    loop {
        if core.shutting_down.load(Ordering::Acquire) {
            return;
        }
        let watched = repos.watchers.load(Ordering::Acquire) > 0;
        if !watched && !t.fs.is_empty() {
            t.fs.clear();
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
            Some(cmd) = cmds.recv() => match cmd {
                Cmd::Refresh { pr, all_prs, reply: r } => {
                    t.resolve_panes().await;
                    t.list_repos(true).await;
                    for wt in t.wts.values_mut() {
                        wt.due = Some(Instant::now());
                    }
                    t.read_due(&cfg, true).await;
                    t.refresh_prs_now(pr.as_deref(), all_prs).await;
                    reply = Some(r);
                }
                Cmd::Pr(path, pr) => t.apply_pr(&path, Ok(pr)),
                Cmd::Relist => {
                    for (_, at) in t.repos.values_mut() {
                        *at = Instant::now() - LIST_TTL;
                    }
                }
            },
            Some(root) = fs_rx.recv() => t.touched(&root, cfg.debounce),
            Some(done) = done_rx.recv() => match done {
                Done::Pr(path, res) => t.apply_pr(&path, res),
                Done::Gh(status) => {
                    t.gh_inflight = false;
                    t.gh_at = Some(Instant::now());
                    t.gh = status;
                }
            },
            ev = events.recv() => match ev {
                // A command finished or an agent did something: its worktree may have changed.
                Ok(Event::Command(mark)) if mark.finished.is_some() => t.pane_touched(mark.pane_id, cfg.debounce),
                Ok(Event::Agent { pane_id, .. }) => t.pane_touched(pane_id, cfg.debounce),
                Ok(_) => {}
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(_) => return,
            },
        }
        if watched || reply.is_some() {
            if reply.is_none() {
                t.resolve_panes().await;
                t.list_repos(false).await;
                t.read_due(&cfg, false).await;
                t.ensure_watches();
                t.schedule_prs(&cfg);
            }
            t.publish();
        }
        if let Some(r) = reply {
            let _ = r.send((*repos.snapshot()).clone());
        }
        if Instant::now() >= sweep_at {
            sweep(&core, &mut t).await;
            sweep_at = Instant::now() + cfg.sweep;
        }
    }
}

impl Tracker {
    /// Maps every pane to its worktree.
    async fn resolve_panes(&mut self) {
        let mut cwds: Vec<(proto::PaneId, String)> = Vec::new();
        for (id, entry) in self.core.pane_entries() {
            let meta = lock(&entry.meta).cwd.clone();
            let cwd = meta.or_else(|| lock(&entry.record).cwd.clone());
            if let Some(cwd) = cwd {
                cwds.push((id, cwd));
            }
        }
        let stale: Vec<String> = cwds
            .iter()
            .map(|(_, c)| c.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .filter(|c| {
                self.roots
                    .get(c)
                    .is_none_or(|(_, at)| at.elapsed() > ROOT_TTL)
            })
            .collect();
        if !stale.is_empty() {
            let answers = tokio::task::spawn_blocking(move || {
                stale
                    .into_iter()
                    .map(|c| {
                        let root = super::git::toplevel(Path::new(&c))
                            .ok()
                            .map(|r| r.canonicalize().unwrap_or(r));
                        (c, root)
                    })
                    .collect::<Vec<_>>()
            })
            .await
            .unwrap_or_default();
            for (c, root) in answers {
                self.roots.insert(c, (root, Instant::now()));
            }
        }
        let mut panes: Vec<PaneRepo> = cwds
            .into_iter()
            .filter_map(|(pane_id, c)| {
                let root = self.roots.get(&c)?.0.as_ref()?;
                Some(PaneRepo {
                    pane_id,
                    worktree: root.to_string_lossy().into_owned(),
                })
            })
            .collect();
        panes.sort_by_key(|p| p.pane_id);
        let active: BTreeSet<PathBuf> = panes.iter().map(|p| PathBuf::from(&p.worktree)).collect();
        for (path, wt) in &mut self.wts {
            let was = wt.active;
            wt.active = active.contains(path);
            if wt.active && !was {
                wt.due = Some(Instant::now());
            }
        }
        // A pane in a worktree the tracker has not listed yet: list its repository.
        if active.iter().any(|p| !self.wts.contains_key(p)) {
            for (_, at) in self.repos.values_mut() {
                *at = Instant::now() - LIST_TTL;
            }
            let unknown: Vec<PathBuf> = active
                .iter()
                .filter(|p| !self.wts.contains_key(*p))
                .cloned()
                .collect();
            self.list_new(unknown).await;
        }
        self.panes = panes;
    }

    /// Lists the repositories of worktrees not seen yet.
    async fn list_new(&mut self, roots: Vec<PathBuf>) {
        let listed = tokio::task::spawn_blocking(move || {
            roots
                .into_iter()
                .filter_map(|r| list_worktrees(&r).ok())
                .collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        for (main, list) in listed {
            self.repos.insert(main, (list, Instant::now()));
        }
        self.sync_wts();
    }

    /// Re-lists repositories whose list is old (or all with `force`) and drops repositories
    /// no pane is in any more.
    async fn list_repos(&mut self, force: bool) {
        let active: BTreeSet<PathBuf> = self
            .panes
            .iter()
            .map(|p| PathBuf::from(&p.worktree))
            .collect();
        // A repository stays while one of its worktrees has a pane.
        self.repos
            .retain(|_, (list, _)| list.iter().any(|w| active.contains(&canonical(&w.path))));
        let stale: Vec<PathBuf> = self
            .repos
            .iter()
            .filter(|(_, (_, at))| force || at.elapsed() >= LIST_TTL)
            .map(|(main, _)| main.clone())
            .collect();
        if !stale.is_empty() {
            let listed = tokio::task::spawn_blocking(move || {
                stale
                    .into_iter()
                    .filter_map(|r| list_worktrees(&r).ok())
                    .collect::<Vec<_>>()
            })
            .await
            .unwrap_or_default();
            for (main, list) in listed {
                self.repos.insert(main, (list, Instant::now()));
            }
        }
        self.sync_wts();
    }

    /// Makes `wts` match the listed repositories.
    fn sync_wts(&mut self) {
        let mut seen = BTreeSet::new();
        for (main, (list, _)) in &self.repos {
            let repo_name = file_name(main);
            for info in list.iter().filter(|w| !w.prunable) {
                let path = canonical(&info.path);
                seen.insert(path.clone());
                let managed = self.core.ws.worktrees.is_managed(&path);
                let entry = self.wts.entry(path.clone()).or_insert_with(|| Wt {
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
        self.wts.retain(|p, _| seen.contains(p));
        let active: BTreeSet<PathBuf> = self
            .panes
            .iter()
            .map(|p| PathBuf::from(&p.worktree))
            .collect();
        for (p, wt) in &mut self.wts {
            wt.active = active.contains(p);
        }
    }

    /// A file changed under a watched worktree.
    fn touched(&mut self, root: &Path, debounce: Duration) {
        if let Some(wt) = self.wts.get_mut(root) {
            let at = Instant::now() + debounce;
            // Keep the earliest pending deadline so a stream of events cannot starve reads.
            if wt.due.is_none_or(|d| d > at) {
                wt.due = Some(at);
            }
        }
    }

    fn pane_touched(&mut self, pane: proto::PaneId, debounce: Duration) {
        if let Some(root) = self
            .panes
            .iter()
            .find(|p| p.pane_id == pane)
            .map(|p| PathBuf::from(&p.worktree))
        {
            self.touched(&root, debounce);
        }
    }

    /// Reads worktrees that are due (or every one with `all`).
    async fn read_due(&mut self, cfg: &crate::config::RepoConfig, all: bool) {
        let now = Instant::now();
        let mains: HashMap<PathBuf, PathBuf> = self
            .wts
            .iter()
            .map(|(p, w)| (p.clone(), PathBuf::from(&w.state.repo)))
            .collect();
        let due: Vec<PathBuf> = self
            .wts
            .iter()
            .filter(|(_, w)| {
                let poll = if w.active { cfg.poll } else { cfg.idle_poll };
                all || w.due.is_some_and(|d| d <= now)
                    || w.read_at.is_none_or(|r| r.elapsed() >= poll)
            })
            // At most one read per debounce period per worktree.
            .filter(|(_, w)| all || w.read_at.is_none_or(|r| r.elapsed() >= cfg.debounce))
            .map(|(p, _)| p.clone())
            .collect();
        if due.is_empty() {
            return;
        }
        let read = tokio::task::spawn_blocking(move || {
            due.into_iter()
                .map(|p| {
                    let bits = read_git(&p);
                    let config = read_config(&p, mains.get(&p).map(PathBuf::as_path));
                    (p, bits, config)
                })
                .collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        let stamp = now_ms();
        for (path, bits, (scripts, hooks)) in read {
            let Some(wt) = self.wts.get_mut(&path) else {
                continue;
            };
            wt.read_at = Some(Instant::now());
            wt.due = None;
            let Ok(bits) = bits else {
                continue;
            };
            let s = &mut wt.state;
            let before = (
                s.branch.clone(),
                s.head.clone(),
                s.upstream.clone(),
                s.ahead,
                s.behind,
                s.added,
                s.removed,
                s.changed_files,
            );
            if s.branch != bits.branch {
                // A new branch: its pull request is another one.
                s.pr = None;
                wt.pr_at = Instant::now();
                wt.pr_fail = 0;
            }
            if s.head != bits.head || s.ahead != bits.ahead {
                // Commits or a push: checks may have started.
                wt.pr_at = wt.pr_at.min(Instant::now() + Duration::from_secs(5));
            }
            s.branch = bits.branch;
            s.head = bits.head;
            s.upstream = bits.upstream;
            s.ahead = bits.ahead;
            s.behind = bits.behind;
            s.added = bits.added;
            s.removed = bits.removed;
            s.changed_files = bits.changed_files;
            s.dirty = bits.changed_files > 0;
            s.scripts = scripts;
            s.hooks = hooks;
            let after = (
                s.branch.clone(),
                s.head.clone(),
                s.upstream.clone(),
                s.ahead,
                s.behind,
                s.added,
                s.removed,
                s.changed_files,
            );
            if before != after || s.updated_at.0 == 0 {
                s.updated_at = UnixMillis(stamp);
            }
        }
    }

    /// Watches worktrees with panes (and stops watching the others).
    fn ensure_watches(&mut self) {
        let active: BTreeSet<PathBuf> = self
            .wts
            .iter()
            .filter(|(_, w)| w.active)
            .map(|(p, _)| p.clone())
            .collect();
        self.fs.retain(|p, _| active.contains(p));
        for root in active {
            if self.fs.contains_key(&root) {
                continue;
            }
            match watch_worktree(&root, self.fs_tx.clone()) {
                Ok(w) => {
                    self.fs.insert(root, w);
                }
                Err(e) => {
                    tracing::debug!("watching {}: {e}", root.display());
                    // Polling still covers it; do not try again every tick.
                    self.fs.insert(root, Vec::new());
                }
            }
        }
    }

    /// Starts `gh` lookups that are due.
    fn schedule_prs(&mut self, cfg: &crate::config::RepoConfig) {
        let needs_gh = self.wts.values().any(|w| w.state.branch.is_some());
        if !needs_gh {
            return;
        }
        let ready = matches!(self.gh, GhStatus::Ready { .. });
        if !self.gh_inflight
            && (self.gh_at.is_none()
                || (!ready && self.gh_at.is_some_and(|a| a.elapsed() >= GH_RECHECK)))
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
        for (path, wt) in &mut self.wts {
            let Some(branch) = wt.state.branch.clone() else {
                continue;
            };
            if wt.pr_inflight || wt.not_github || wt.pr_at > now {
                continue;
            }
            wt.pr_inflight = true;
            // Placeholder until the answer lands; `apply_pr` sets the real schedule.
            wt.pr_at = now + cfg.pr_poll;
            let tx = self.results.clone();
            let gh_path = gh_path.clone();
            let path = path.clone();
            tokio::task::spawn_blocking(move || {
                let res = gh::pr_view(&gh_path, &path, &branch, now_millis());
                let _ = tx.send(Done::Pr(path, res));
            });
        }
    }

    /// Asks `gh` right now, for a refresh request.
    async fn refresh_prs_now(&mut self, one: Option<&Path>, all: bool) {
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
            .wts
            .iter()
            .filter(|(p, w)| (all || one.is_some_and(|o| o == p.as_path())) && !w.not_github)
            .filter_map(|(p, w)| Some((p.clone(), w.state.branch.clone()?)))
            .collect();
        let answers = tokio::task::spawn_blocking(move || {
            targets
                .into_iter()
                .map(|(p, b)| {
                    let res = gh::pr_view(&gh_path, &p, &b, now_millis());
                    (p, res)
                })
                .collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        for (p, res) in answers {
            self.apply_pr(&p, res);
        }
    }

    fn apply_pr(&mut self, path: &Path, res: Result<Option<PullRequest>, ViewError>) {
        let pr_poll = self.core.cfg.repos.pr_poll;
        let Some(wt) = self.wts.get_mut(path) else {
            return;
        };
        wt.pr_inflight = false;
        match res {
            Ok(pr) => {
                wt.pr_fail = 0;
                wt.pr_at = Instant::now()
                    + match &pr {
                        None => pr_poll * 10,
                        Some(p) if p.state != PrState::Open => pr_poll * 30,
                        Some(p) if p.checks.iter().any(|c| c.status == CheckStatus::Pending) => {
                            pr_poll
                        }
                        Some(_) => pr_poll * 4,
                    };
                let merged = pr.as_ref().is_some_and(|p| p.state == PrState::Merged);
                wt.state.merged_at = self
                    .core
                    .ws
                    .worktrees
                    .merged_since(path, merged, now_millis().0)
                    .map(UnixMillis);
                wt.state.pr = pr;
            }
            Err(ViewError::NotGitHub) => {
                wt.not_github = true;
                wt.state.pr = None;
            }
            Err(ViewError::Missing) => {
                self.gh = GhStatus::Missing;
                self.gh_at = Some(Instant::now());
            }
            Err(ViewError::Auth(message)) => {
                self.gh = GhStatus::NotAuthenticated { message };
                self.gh_at = Some(Instant::now());
            }
            Err(ViewError::Other(e)) => {
                tracing::debug!("gh pr view in {}: {e}", path.display());
                wt.pr_fail = (wt.pr_fail + 1).min(6);
                // 1, 2, 4 … 32 minutes.
                wt.pr_at = Instant::now() + Duration::from_secs(60 << (wt.pr_fail - 1));
            }
        }
    }

    /// Builds the snapshot and sends it if anything changed.
    fn publish(&mut self) {
        let mut worktrees: Vec<WorktreeState> =
            self.wts.values().map(|w| w.state.clone()).collect();
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

fn canonical(p: impl AsRef<Path>) -> PathBuf {
    let p = p.as_ref();
    p.canonicalize().unwrap_or_else(|_| p.to_owned())
}

fn file_name(p: &Path) -> String {
    p.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| p.to_string_lossy().into_owned())
}

/// The repository's main worktree and its worktrees.
fn list_worktrees(root: &Path) -> Result<(PathBuf, Vec<proto::WorktreeInfo>), WsError> {
    let out = git(root, &["worktree", "list", "--porcelain", "-z"])?;
    let list = super::worktree::parse_list(&out);
    let main = list
        .iter()
        .find(|w| w.main)
        .map(|w| canonical(&w.path))
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
        .map(|o| PathBuf::from(String::from_utf8_lossy(&o).trim()))
        .ok();
    let common = git(root, &["rev-parse", "--git-common-dir"])
        .map(|o| root.join(String::from_utf8_lossy(&o).trim()))
        .ok()
        .map(canonical);
    let key = root.to_owned();
    let skip_git = gitdir.clone();
    let make = |tx: mpsc::UnboundedSender<PathBuf>, key: PathBuf| {
        let skip_git = skip_git.clone();
        notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            let Ok(event) = res else {
                let _ = tx.send(key.clone());
                return;
            };
            if matches!(event.kind, notify::EventKind::Access(_)) {
                return;
            }
            let relevant = event.paths.iter().any(|p| relevant(p, skip_git.as_deref()));
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
        let mut g = make(tx.clone(), key.clone())?;
        g.watch(gitdir, RecursiveMode::NonRecursive)?;
        watchers.push(g);
    }
    // Branch heads live in the common directory (shared by every worktree).
    if let Some(common) = common.map(|c| c.join("refs").join("heads"))
        && common.is_dir()
        && !(cfg!(target_os = "macos") && common.starts_with(root))
    {
        let mut g = make(tx, key)?;
        g.watch(&common, RecursiveMode::Recursive)?;
        watchers.push(g);
    }
    Ok(watchers)
}

/// Whether a changed path can change what the sidebar shows: anything in the worktree, but
/// inside a git directory only HEAD, the index and refs (not objects, logs or locks).
fn relevant(path: &Path, gitdir: Option<&Path>) -> bool {
    let s = path.to_string_lossy();
    if s.ends_with(".lock") {
        return false;
    }
    let in_git = gitdir.is_some_and(|g| path.starts_with(g)) || s.contains("/.git/");
    if !in_git {
        return true;
    }
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    name == "HEAD" || name == "index" || s.contains("/refs/")
}

// --- auto-delete --------------------------------------------------------------------------

/// Removes managed worktrees whose pull request merged long enough ago and that are clean.
async fn sweep(core: &Arc<Core>, t: &mut Tracker) {
    let worktrees = &core.ws.worktrees;
    let managed = worktrees.managed_paths();
    if managed.is_empty() {
        return;
    }
    // Merge state of managed worktrees the tracker does not follow (no pane in the repo).
    let gh_path = gh::find(core.cfg.repos.gh.as_deref());
    let untracked: Vec<PathBuf> = managed
        .iter()
        .filter(|p| p.is_dir() && !t.wts.contains_key(*p))
        .cloned()
        .collect();
    let core2 = Arc::clone(core);
    let _ = tokio::task::spawn_blocking(move || {
        let Some(gh_path) = gh_path else {
            return;
        };
        for path in untracked {
            let Ok(Some(branch)) = super::git::status(&path).map(|s| s.branch) else {
                continue;
            };
            if let Ok(pr) = gh::pr_view(&gh_path, &path, &branch, now()) {
                let merged = pr.is_some_and(|p| p.state == PrState::Merged);
                core2
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
        let core2 = Arc::clone(core);
        let res = tokio::task::spawn_blocking(move || {
            if !path.is_dir() {
                core2.ws.worktrees.forget(&path);
                return Ok(false);
            }
            if super::worktree::dirty_count(&path)? > 0 {
                // Never without asking: the app shows it as merged with changes.
                return Ok(false);
            }
            let main = list_worktrees(&path).ok().map(|(m, _)| m);
            let (_, hooks) = read_config(&path, main.as_deref());
            core2
                .ws
                .worktrees
                .remove(&path, false, false, hooks.teardown.as_deref())
                .map(|()| {
                    tracing::info!("auto-deleted merged worktree {}", path.display());
                    true
                })
        })
        .await
        .unwrap_or_else(|e| Err(WsError::Failed(e.to_string())));
        match res {
            Ok(r) => removed_any |= r,
            Err(e) => tracing::info!("auto-delete: {e}"),
        }
    }
    if removed_any {
        for (_, at) in t.repos.values_mut() {
            *at = Instant::now() - LIST_TTL;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_lines_like_git() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("a");
        std::fs::write(&p, "one\ntwo\nthree").unwrap();
        assert_eq!(count_lines(&p), 3);
        std::fs::write(&p, "one\n").unwrap();
        assert_eq!(count_lines(&p), 1);
        std::fs::write(&p, b"\0bin\n").unwrap();
        assert_eq!(count_lines(&p), 0);
    }

    #[test]
    fn filters_git_internals() {
        let g = Path::new("/r/.git");
        assert!(relevant(Path::new("/r/src/a.rs"), Some(g)));
        assert!(relevant(Path::new("/r/.git/HEAD"), Some(g)));
        assert!(relevant(Path::new("/r/.git/index"), Some(g)));
        assert!(relevant(Path::new("/r/.git/refs/heads/main"), Some(g)));
        assert!(!relevant(Path::new("/r/.git/objects/ab/cdef"), Some(g)));
        assert!(!relevant(Path::new("/r/.git/index.lock"), Some(g)));
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
