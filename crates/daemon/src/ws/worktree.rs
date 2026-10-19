//! with a dirty check, and a stable `PORT` per worktree so parallel dev servers never collide.
//!
//! Ports live in `<state>/worktrees.json` (`{ "ports": { "<path>": 4101 } }`): a worktree
//! keeps its port for its whole life, across daemon restarts, and a new one gets the lowest
//! port from [`Config::worktree_port_base`](crate::Config::worktree_port_base) that no other
//! worktree holds and nothing is listening on. Every pane started inside a registered worktree
//! gets `PORT` and `<PREFIX>WORKTREE` in its environment, recorded in the layout file.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use proto::{
    ArchivedWorktree, UnixMillis, WorktreeCreate, WorktreeInfo, WorktreeSettings, WsError,
};
use serde::{Deserialize, Serialize};

use super::git::{self, git};
use crate::core::lock;
use crate::fsutil;

#[derive(Debug, Default, Serialize, Deserialize)]
struct Registry {
    ports: BTreeMap<PathBuf, u16>,
    /// Worktrees the daemon created (New Task, Checkout PR, `WorktreeCreate`): the only ones
    /// auto-delete may remove.
    #[serde(default)]
    managed: BTreeSet<PathBuf>,
    /// When each managed worktree's pull request was first seen merged (Unix ms).
    #[serde(default)]
    merged: BTreeMap<PathBuf, u64>,
    /// Archived worktrees, oldest first.
    #[serde(default)]
    archived: Vec<Archived>,
    #[serde(default)]
    next_archive: u64,
    /// Days after merging before auto-delete; `None` is the default (7).
    #[serde(default)]
    auto_delete_days: Option<u32>,
}

/// Default for [`proto::WorktreeSettings::auto_delete_merged_days`].
pub(crate) const DEFAULT_AUTO_DELETE_DAYS: u32 = 7;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Archived {
    id: u64,
    repo: PathBuf,
    path: PathBuf,
    branch: Option<String>,
    head: Option<String>,
    saved_changes: bool,
    archived_at: u64,
}

impl Archived {
    fn wire(&self) -> ArchivedWorktree {
        ArchivedWorktree {
            id: self.id,
            repo: self.repo.to_string_lossy().into_owned(),
            repo_name: self
                .repo
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
            path: self.path.to_string_lossy().into_owned(),
            branch: self.branch.clone(),
            head: self.head.clone(),
            saved_changes: self.saved_changes,
            archived_at: UnixMillis(self.archived_at),
        }
    }
}

/// Refs an archived worktree is kept under: `refs/<product>/archived/<id>/head` (its commit)
/// and `…/changes` (its uncommitted changes, when saved).
fn archive_ref(id: u64, part: &str) -> String {
    format!("refs/{}/archived/{id}/{part}", brand::DIR_NAME)
}

pub(crate) struct Worktrees {
    file: PathBuf,
    base: u16,
    registry: Mutex<Registry>,
}

impl Worktrees {
    pub fn load(state_dir: &Path, base: u16) -> Self {
        let file = state_dir.join("worktrees.json");
        let registry = fsutil::read_optional(&file)
            .ok()
            .flatten()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        Self {
            file,
            base,
            registry: Mutex::new(registry),
        }
    }

    fn save(&self, registry: &Registry) {
        match serde_json::to_vec_pretty(registry) {
            Ok(data) => {
                if let Err(e) = fsutil::write_atomic(&self.file, &data) {
                    tracing::warn!("saving worktree ports: {e}");
                }
            }
            Err(e) => tracing::warn!("encoding worktree ports: {e}"),
        }
    }

    /// The worktree containing `dir` and its port, if it is registered.
    pub fn port_for(&self, dir: &Path) -> Option<(PathBuf, u16)> {
        let dir = dir.canonicalize().unwrap_or_else(|_| dir.to_owned());
        lock(&self.registry)
            .ports
            .iter()
            .filter(|(path, _)| dir.starts_with(path))
            .max_by_key(|(path, _)| path.as_os_str().len())
            .map(|(p, &port)| (p.clone(), port))
    }

    /// The worktree's port, allocating one if needed.
    pub fn allocate(&self, path: &Path) -> u16 {
        let path = path.canonicalize().unwrap_or_else(|_| path.to_owned());
        let mut registry = lock(&self.registry);
        if let Some(&port) = registry.ports.get(&path) {
            return port;
        }
        let taken: Vec<u16> = registry.ports.values().copied().collect();
        let port = (self.base..=u16::MAX)
            .find(|p| !taken.contains(p) && port_free(*p))
            .unwrap_or(self.base);
        registry.ports.insert(path, port);
        self.save(&registry);
        port
    }

    fn release(&self, path: &Path) {
        let mut registry = lock(&self.registry);
        let canonical = path.canonicalize().unwrap_or_else(|_| path.to_owned());
        let mut removed =
            registry.ports.remove(&canonical).is_some() || registry.ports.remove(path).is_some();
        for p in [&canonical, &path.to_owned()] {
            removed |= registry.managed.remove(p);
            removed |= registry.merged.remove(p).is_some();
        }
        if removed {
            self.save(&registry);
        }
    }

    pub fn list(&self, repo: &Path) -> Result<Vec<WorktreeInfo>, WsError> {
        let root = git::toplevel(repo)?;
        let out = git(&root, &["worktree", "list", "--porcelain", "-z"])?;
        let mut list = parse_list(&out);
        for wt in &mut list {
            wt.port = self
                .port_for(Path::new(&wt.path))
                .filter(|(p, _)| p == &PathBuf::from(&wt.path).canonicalize().unwrap_or_default())
                .map(|(_, port)| port);
        }
        Ok(list)
    }

    pub fn create(&self, req: &WorktreeCreate, root_dir: &Path) -> Result<WorktreeInfo, WsError> {
        let repo = git::toplevel(Path::new(&req.repo))?;
        let branch = match &req.branch {
            Some(b) => b.clone(),
            None => generated_branch(),
        };
        // `check-ref-format --branch` rejects names git would refuse (and option-like ones).
        if branch.starts_with('-') {
            return Err(WsError::Invalid(format!("bad branch name {branch:?}")));
        }
        git(&repo, &["check-ref-format", "--branch", &branch])
            .map_err(|_| WsError::Invalid(format!("bad branch name {branch:?}")))?;
        let base = req.base.clone().unwrap_or_else(|| "HEAD".to_owned());
        if base.starts_with('-') {
            return Err(WsError::Invalid(format!("bad base {base:?}")));
        }
        let path = match &req.path {
            Some(p) => PathBuf::from(p),
            None => {
                let repo_name = repo
                    .file_name()
                    .map_or_else(|| "repo".to_owned(), |n| n.to_string_lossy().into_owned());
                root_dir.join(repo_name).join(branch.replace('/', "-"))
            }
        };
        if path.exists() {
            return Err(WsError::Conflict(format!("{} exists", path.display())));
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| super::paths::io_error(parent, &e))?;
        }
        let path_str = path.to_string_lossy().into_owned();
        git(
            &repo,
            &["worktree", "add", "-b", &branch, "--", &path_str, &base],
        )
        .map_err(|e| match e {
            WsError::Failed(m) if m.contains("already exists") => WsError::Conflict(m),
            e => e,
        })?;
        let port = self.allocate(&path);
        self.mark_managed(&path);
        let head = git(&path, &["rev-parse", "HEAD"])
            .ok()
            .map(|o| String::from_utf8_lossy(&o).trim().to_owned());
        Ok(WorktreeInfo {
            path: path
                .canonicalize()
                .unwrap_or(path)
                .to_string_lossy()
                .into_owned(),
            branch: Some(branch),
            head,
            main: false,
            locked: false,
            prunable: false,
            port: Some(port),
        })
    }

    /// The worktree at `path` (canonical), its repository's list and its main worktree;
    /// refuses the main worktree itself.
    fn linked(&self, path: &Path) -> Result<(PathBuf, WorktreeInfo, PathBuf), WsError> {
        let path = path
            .canonicalize()
            .map_err(|e| super::paths::io_error(path, &e))?;
        let list = self.list(&path)?;
        let wt = list
            .iter()
            .find(|w| Path::new(&w.path).canonicalize().ok().as_deref() == Some(path.as_path()))
            .cloned()
            .ok_or_else(|| WsError::Invalid(format!("{} is not a worktree", path.display())))?;
        if wt.main {
            return Err(WsError::Denied(
                "refusing to remove the main worktree".into(),
            ));
        }
        // Run from the main worktree: the removed directory must not be git's cwd.
        let main = list
            .iter()
            .find(|w| w.main)
            .map(|w| PathBuf::from(&w.path))
            .ok_or_else(|| WsError::Failed("no main worktree".into()))?;
        Ok((path, wt, main))
    }

    pub fn remove(
        &self,
        path: &Path,
        force: bool,
        delete_branch: bool,
        teardown: Option<&str>,
    ) -> Result<(), WsError> {
        let (path, wt, main) = self.linked(path)?;
        let count = dirty_count(&path)?;
        if !force && count > 0 {
            return Err(WsError::Conflict(format!(
                "{} has {count} uncommitted or untracked change(s); remove with force",
                path.display()
            )));
        }
        if let Some(cmd) = teardown {
            run_hook(&path, cmd).or_else(|e| if force { Ok(()) } else { Err(e) })?;
        }
        let path_str = path.to_string_lossy().into_owned();
        let mut args = vec!["worktree", "remove"];
        if force {
            args.push("--force");
        }
        args.extend(["--", &path_str]);
        git(&main, &args)?;
        self.release(&path);
        if delete_branch && let Some(branch) = &wt.branch {
            // `-d` refuses unmerged branches; that refusal is not an error of the removal.
            if let Err(e) = git(&main, &["branch", "-d", "--", branch]) {
                tracing::info!("kept branch {branch}: {e}");
            }
        }
        Ok(())
    }

    // --- managed worktrees and auto-delete ----------------------------------------------------

    pub fn mark_managed(&self, path: &Path) {
        let path = path.canonicalize().unwrap_or_else(|_| path.to_owned());
        let mut registry = lock(&self.registry);
        if registry.managed.insert(path) {
            self.save(&registry);
        }
    }

    pub fn is_managed(&self, path: &Path) -> bool {
        lock(&self.registry).managed.contains(path)
    }

    pub fn managed_paths(&self) -> Vec<PathBuf> {
        lock(&self.registry).managed.iter().cloned().collect()
    }

    /// Drops a worktree that disappeared behind the daemon's back.
    pub fn forget(&self, path: &Path) {
        self.release(path);
    }

    /// When `path`'s pull request was first seen merged; records `now` the first time.
    pub fn merged_since(&self, path: &Path, merged: bool, now: u64) -> Option<u64> {
        let mut registry = lock(&self.registry);
        if !registry.managed.contains(path) {
            return None;
        }
        if !merged {
            if registry.merged.remove(path).is_some() {
                self.save(&registry);
            }
            return None;
        }
        if let Some(&at) = registry.merged.get(path) {
            return Some(at);
        }
        registry.merged.insert(path.to_owned(), now);
        self.save(&registry);
        Some(now)
    }

    /// Managed worktrees merged at least `days` days ago (of `day` length).
    pub fn due_for_delete(&self, now: u64, day: std::time::Duration) -> Vec<PathBuf> {
        let registry = lock(&self.registry);
        let days = registry
            .auto_delete_days
            .unwrap_or(DEFAULT_AUTO_DELETE_DAYS);
        if days == 0 {
            return Vec::new();
        }
        let after = u64::try_from(day.as_millis())
            .unwrap_or(u64::MAX)
            .saturating_mul(u64::from(days));
        registry
            .merged
            .iter()
            .filter(|(p, at)| registry.managed.contains(*p) && now.saturating_sub(**at) >= after)
            .map(|(p, _)| p.clone())
            .collect()
    }

    pub fn settings(&self, set: Option<WorktreeSettings>) -> WorktreeSettings {
        let mut registry = lock(&self.registry);
        if let Some(s) = set {
            registry.auto_delete_days = Some(s.auto_delete_merged_days);
            self.save(&registry);
        }
        WorktreeSettings {
            auto_delete_merged_days: registry
                .auto_delete_days
                .unwrap_or(DEFAULT_AUTO_DELETE_DAYS),
        }
    }

    // --- archive and restore ------------------------------------------------------------------

    /// Archives a linked worktree: teardown, its commit (and with `force` its uncommitted
    /// changes) kept under [`archive_ref`], directory removed, branch kept.
    pub fn archive(
        &self,
        path: &Path,
        force: bool,
        teardown: Option<&str>,
        now: u64,
    ) -> Result<ArchivedWorktree, WsError> {
        let (path, wt, main) = self.linked(path)?;
        let count = dirty_count(&path)?;
        if count > 0 && !force {
            return Err(WsError::Conflict(format!(
                "{} has {count} uncommitted or untracked change(s); archive with force to keep \
                 them with it",
                path.display()
            )));
        }
        if let Some(cmd) = teardown {
            run_hook(&path, cmd).or_else(|e| if force { Ok(()) } else { Err(e) })?;
        }
        let head = git(&path, &["rev-parse", "--verify", "HEAD"])
            .map(|o| String::from_utf8_lossy(&o).trim().to_owned())
            .map_err(|_| {
                WsError::Invalid("a worktree without commits cannot be archived".into())
            })?;
        let id = {
            let mut registry = lock(&self.registry);
            registry.next_archive += 1;
            registry.next_archive
        };
        let keep = || -> Result<bool, WsError> {
            git(&main, &["update-ref", &archive_ref(id, "head"), &head])?;
            if count == 0 {
                return Ok(false);
            }
            let tree = git::worktree_tree(&path)?;
            let commit = git(
                &path,
                &[
                    "-c",
                    "user.name=archive",
                    "-c",
                    "user.email=archive@localhost",
                    "commit-tree",
                    &tree,
                    "-p",
                    &head,
                    "-m",
                    "uncommitted changes at archive",
                ],
            )?;
            let commit = String::from_utf8_lossy(&commit).trim().to_owned();
            git(&main, &["update-ref", &archive_ref(id, "changes"), &commit])?;
            Ok(true)
        };
        let path_str = path.to_string_lossy().into_owned();
        let saved_changes = keep().and_then(|saved| {
            git(&main, &["worktree", "remove", "--force", "--", &path_str]).map(|_| saved)
        });
        let saved_changes = match saved_changes {
            Ok(saved) => saved,
            Err(e) => {
                // Leave nothing half done: the worktree is still there.
                for part in ["head", "changes"] {
                    let _ = git(&main, &["update-ref", "-d", &archive_ref(id, part)]);
                }
                return Err(e);
            }
        };
        self.release(&path);
        let record = Archived {
            id,
            repo: main,
            path,
            branch: wt.branch,
            head: Some(head),
            saved_changes,
            archived_at: now,
        };
        let wire = record.wire();
        let mut registry = lock(&self.registry);
        registry.archived.push(record);
        self.save(&registry);
        Ok(wire)
    }

    /// Archived worktrees, newest first, optionally of one repository (its main worktree).
    pub fn archived(&self, repo: Option<&Path>) -> Vec<ArchivedWorktree> {
        let registry = lock(&self.registry);
        registry
            .archived
            .iter()
            .rev()
            .filter(|a| repo.is_none_or(|r| a.repo == r))
            .map(Archived::wire)
            .collect()
    }

    /// Recreates an archived worktree where it was, on its branch (recreated from the kept
    /// commit if it was deleted), with its saved changes back as uncommitted changes.
    pub fn restore(&self, id: u64) -> Result<WorktreeInfo, WsError> {
        let record = lock(&self.registry)
            .archived
            .iter()
            .find(|a| a.id == id)
            .cloned()
            .ok_or_else(|| WsError::NotFound(format!("archived worktree {id}")))?;
        if record.path.exists() {
            return Err(WsError::Conflict(format!(
                "{} exists",
                record.path.display()
            )));
        }
        let main = &record.repo;
        let base_ref = archive_ref(id, "head");
        let path_str = record.path.to_string_lossy().into_owned();
        if let Some(parent) = record.path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| super::paths::io_error(parent, &e))?;
        }
        match &record.branch {
            Some(branch) => {
                let exists = git(
                    main,
                    &["rev-parse", "--verify", &format!("refs/heads/{branch}")],
                )
                .is_ok();
                if exists {
                    git(main, &["worktree", "add", "--", &path_str, branch])?;
                } else {
                    git(
                        main,
                        &["worktree", "add", "-b", branch, "--", &path_str, &base_ref],
                    )?;
                }
            }
            None => {
                git(
                    main,
                    &["worktree", "add", "--detach", "--", &path_str, &base_ref],
                )?;
            }
        }
        if record.saved_changes {
            let changes = archive_ref(id, "changes");
            git(&record.path, &["checkout", &changes, "--", "."])?;
            // Back to uncommitted changes: the index follows HEAD again, the files stay.
            git(&record.path, &["reset", "-q"])?;
            let _ = git(main, &["update-ref", "-d", &changes]);
        }
        let _ = git(main, &["update-ref", "-d", &base_ref]);
        let port = self.allocate(&record.path);
        self.mark_managed(&record.path);
        {
            let mut registry = lock(&self.registry);
            registry.archived.retain(|a| a.id != id);
            self.save(&registry);
        }
        let head = git(&record.path, &["rev-parse", "HEAD"])
            .ok()
            .map(|o| String::from_utf8_lossy(&o).trim().to_owned());
        Ok(WorktreeInfo {
            path: record
                .path
                .canonicalize()
                .unwrap_or_else(|_| record.path.clone())
                .to_string_lossy()
                .into_owned(),
            branch: record.branch,
            head,
            main: false,
            locked: false,
            prunable: false,
            port: Some(port),
        })
    }
}

/// Uncommitted and untracked paths in a worktree.
pub(crate) fn dirty_count(path: &Path) -> Result<usize, WsError> {
    let dirty = git(
        path,
        &["status", "--porcelain", "-z", "--untracked-files=normal"],
    )?;
    Ok(dirty.split(|&b| b == 0).filter(|e| !e.is_empty()).count())
}

/// Runs a teardown command in `dir` through `sh -c`, waiting at most five minutes.
pub(crate) fn run_hook(dir: &Path, cmd: &str) -> Result<(), WsError> {
    let mut child = std::process::Command::new("/bin/sh")
        .args(["-c", cmd])
        .current_dir(dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| WsError::Failed(format!("teardown: {e}")))?;
    // Drained on a thread so a chatty teardown never blocks on a full pipe.
    let stderr = child.stderr.take().map(|mut e| {
        std::thread::spawn(move || {
            use std::io::Read;
            let mut s = String::new();
            let _ = e.read_to_string(&mut s);
            s
        })
    });
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(300);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => {
                let err = stderr.and_then(|t| t.join().ok()).unwrap_or_default();
                return Err(WsError::Failed(format!(
                    "teardown `{cmd}` failed ({status}): {}",
                    err.trim()
                )));
            }
            Ok(None) if std::time::Instant::now() >= deadline => {
                let _ = child.kill();
                return Err(WsError::Failed(format!("teardown `{cmd}` timed out")));
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(50)),
            Err(e) => return Err(WsError::Failed(e.to_string())),
        }
    }
}

fn port_free(port: u16) -> bool {
    std::net::TcpListener::bind(("127.0.0.1", port)).is_ok()
}

fn generated_branch() -> String {
    const WORDS: &[&str] = &[
        "amber", "brook", "cedar", "delta", "ember", "fjord", "grove", "harbor", "iris", "juniper",
        "kestrel", "lumen", "maple", "nimbus", "orchid", "pine", "quartz", "river", "sage", "tide",
    ];
    let r = fsutil::random::<3>();
    format!(
        "{}/{}-{}",
        brand::DIR_NAME,
        WORDS[r[0] as usize % WORDS.len()],
        fsutil::hex(&r[1..])
    )
}

/// `git worktree list --porcelain -z`: attribute lines, a blank field between worktrees.
pub(crate) fn parse_list(out: &[u8]) -> Vec<WorktreeInfo> {
    let mut list: Vec<WorktreeInfo> = Vec::new();
    let mut current: Option<WorktreeInfo> = None;
    for field in out.split(|&b| b == 0) {
        let field = String::from_utf8_lossy(field);
        if field.is_empty() {
            list.extend(current.take());
            continue;
        }
        let (key, value) = field.split_once(' ').unwrap_or((&field, ""));
        if key == "worktree" {
            list.extend(current.take());
            current = Some(WorktreeInfo {
                path: value.to_owned(),
                branch: None,
                head: None,
                main: list.is_empty(),
                locked: false,
                prunable: false,
                port: None,
            });
            continue;
        }
        let Some(wt) = current.as_mut() else {
            continue;
        };
        match key {
            "HEAD" => wt.head = Some(value.to_owned()),
            "branch" => {
                wt.branch = Some(
                    value
                        .strip_prefix("refs/heads/")
                        .unwrap_or(value)
                        .to_owned(),
                );
            }
            "locked" => wt.locked = true,
            "prunable" => wt.prunable = true,
            _ => {}
        }
    }
    list.extend(current);
    list
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_worktree_list() {
        let out = b"worktree /r\0HEAD abc\0branch refs/heads/main\0\0\
worktree /w/x\0HEAD def\0detached\0locked\0\0";
        let list = parse_list(out);
        assert_eq!(list.len(), 2);
        assert!(list[0].main);
        assert_eq!(list[0].branch.as_deref(), Some("main"));
        assert!(!list[1].main);
        assert!(list[1].locked);
        assert_eq!(list[1].branch, None);
        assert!(generated_branch().starts_with(&format!("{}/", brand::DIR_NAME)));
    }
}
