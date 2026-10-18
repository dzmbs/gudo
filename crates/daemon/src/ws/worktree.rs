//! with a dirty check, and a stable `PORT` per worktree so parallel dev servers never collide.
//!
//! Ports live in `<state>/worktrees.json` (`{ "ports": { "<path>": 4101 } }`): a worktree
//! keeps its port for its whole life, across daemon restarts, and a new one gets the lowest
//! port from [`Config::worktree_port_base`](crate::Config::worktree_port_base) that no other
//! worktree holds and nothing is listening on. Every pane started inside a registered worktree
//! gets `PORT` and `<PREFIX>WORKTREE` in its environment, recorded in the layout file.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use proto::{WorktreeCreate, WorktreeInfo, WsError};
use serde::{Deserialize, Serialize};

use super::git::{self, git};
use crate::core::lock;
use crate::fsutil;

#[derive(Debug, Default, Serialize, Deserialize)]
struct Registry {
    ports: BTreeMap<PathBuf, u16>,
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
        let removed =
            registry.ports.remove(&canonical).is_some() || registry.ports.remove(path).is_some();
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

    pub fn remove(&self, path: &Path, force: bool, delete_branch: bool) -> Result<(), WsError> {
        let path = path
            .canonicalize()
            .map_err(|e| super::paths::io_error(path, &e))?;
        let list = self.list(&path)?;
        let wt = list
            .iter()
            .find(|w| Path::new(&w.path).canonicalize().ok().as_deref() == Some(path.as_path()))
            .ok_or_else(|| WsError::Invalid(format!("{} is not a worktree", path.display())))?;
        if wt.main {
            return Err(WsError::Denied(
                "refusing to remove the main worktree".into(),
            ));
        }
        if !force {
            let dirty = git(
                &path,
                &["status", "--porcelain", "-z", "--untracked-files=normal"],
            )?;
            let count = dirty.split(|&b| b == 0).filter(|e| !e.is_empty()).count();
            if count > 0 {
                return Err(WsError::Conflict(format!(
                    "{} has {count} uncommitted or untracked change(s); remove with force",
                    path.display()
                )));
            }
        }
        // Run from the main worktree: the removed directory must not be git's cwd.
        let main = list
            .iter()
            .find(|w| w.main)
            .map(|w| PathBuf::from(&w.path))
            .ok_or_else(|| WsError::Failed("no main worktree".into()))?;
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
fn parse_list(out: &[u8]) -> Vec<WorktreeInfo> {
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
