//! The path policy every workspace request goes through.
//!
//! A client path must be absolute or start with `~/`, must not contain `..` components, and
//! must resolve (symlinks followed, for the part that exists) inside an allowed root: `$HOME`
//! plus [`Config::fs_allow`](crate::Config::fs_allow). Resolving the existing ancestor rather
//! than only the string closes symlink escapes (`~/link-to-root/etc/passwd`).

use std::path::{Component, Path, PathBuf};

use proto::WsError;

/// The allowed roots, canonicalized once.
#[derive(Debug, Clone)]
pub(crate) struct Policy {
    home: PathBuf,
    roots: Vec<PathBuf>,
    /// Inside a root but never served: the daemon's state (keys, tokens, grants, audit log).
    denied: Vec<PathBuf>,
}

impl Policy {
    pub fn new(home: &Path, extra: &[PathBuf]) -> Self {
        let roots = std::iter::once(home)
            .chain(extra.iter().map(PathBuf::as_path))
            .map(canonical)
            .collect();
        Self {
            home: home.to_owned(),
            roots,
            denied: Vec::new(),
        }
    }

    /// Also refuses `dir` and everything under it, unless it holds a whole root (that would
    /// refuse everything).
    pub fn deny(mut self, dir: &Path) -> Self {
        let dir = canonical(dir);
        if !self.roots.iter().any(|r| r.starts_with(&dir)) {
            self.denied.push(dir);
        }
        self
    }

    /// Whether the real path `real` may be served.
    fn allows(&self, real: &Path) -> bool {
        self.roots.iter().any(|r| real.starts_with(r))
            && !self.denied.iter().any(|d| real.starts_with(d))
    }

    pub fn home(&self) -> &Path {
        &self.home
    }

    /// Parses a client path: absolute or `~`-relative, no `..`, inside a root. The returned
    /// path is the lexical one (a final symlink is not followed, so `lstat` and delete act on
    /// the link itself); its existing ancestors were checked through their real paths.
    ///
    /// # Errors
    ///
    /// [`WsError::Invalid`] for relative paths, [`WsError::Denied`] for `..` or a path
    /// outside the roots.
    pub fn resolve(&self, raw: &str) -> Result<PathBuf, WsError> {
        let path = if raw == "~" {
            self.home.clone()
        } else if let Some(rest) = raw.strip_prefix("~/") {
            self.home.join(rest)
        } else {
            PathBuf::from(raw)
        };
        if !path.is_absolute() {
            return Err(WsError::Invalid(format!(
                "{raw:?} is not absolute (use / or ~/)"
            )));
        }
        if path.components().any(|c| c == Component::ParentDir) {
            return Err(WsError::Denied(format!("{raw:?} contains '..'")));
        }
        // Lexically normalise `.` and repeated separators.
        let path: PathBuf = path.components().collect();
        // The final component is not followed: a symlink is itself inside the root.
        if self.allows(&real_of(&path)) {
            Ok(path)
        } else {
            Err(WsError::Denied(format!(
                "{} is outside the allowed directories",
                path.display()
            )))
        }
    }

    /// Like [`resolve`](Self::resolve), then follows a final symlink and checks the target
    /// too (reads and writes go through the link).
    pub fn resolve_followed(&self, raw: &str) -> Result<PathBuf, WsError> {
        let path = self.resolve(raw)?;
        match path.canonicalize() {
            Ok(real) if self.allows(&real) => Ok(path),
            Ok(real) => Err(WsError::Denied(format!(
                "{} points outside the allowed directories ({})",
                path.display(),
                real.display()
            ))),
            Err(_) => Ok(path),
        }
    }

    /// Like [`resolve`](Self::resolve), for a path that will be moved or deleted: it must not
    /// hold a refused directory, which would then reappear elsewhere (or in the trash) unrefused.
    pub fn resolve_movable(&self, raw: &str) -> Result<PathBuf, WsError> {
        let path = self.resolve(raw)?;
        let real = real_of(&path);
        if self.denied.iter().any(|d| d.starts_with(&real)) {
            return Err(WsError::Denied(format!(
                "{} holds the daemon's state",
                path.display()
            )));
        }
        Ok(path)
    }
}

/// The real path of `path`, without following a final symlink. An existing entry is
/// canonicalised whole, so another spelling of its name (case on macOS) is not another path.
fn real_of(path: &Path) -> PathBuf {
    if let Ok(meta) = std::fs::symlink_metadata(path)
        && !meta.file_type().is_symlink()
        && let Ok(real) = path.canonicalize()
    {
        return real;
    }
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) => real_prefix(parent).join(name),
        _ => path.to_owned(),
    }
}

fn canonical(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_owned())
}

/// `path` with its longest existing prefix replaced by that prefix's canonical form.
fn real_prefix(path: &Path) -> PathBuf {
    let mut existing = path;
    let mut rest = Vec::new();
    loop {
        if let Ok(real) = existing.canonicalize() {
            let mut out = real;
            out.extend(rest.iter().rev());
            return out;
        }
        match (existing.parent(), existing.file_name()) {
            (Some(parent), Some(name)) => {
                rest.push(name.to_owned());
                existing = parent;
            }
            _ => return path.to_owned(),
        }
    }
}

/// Maps an I/O error to the closest [`WsError`], naming `path`.
pub(crate) fn io_error(path: &Path, e: &std::io::Error) -> WsError {
    use std::io::ErrorKind;
    let what = format!("{}: {e}", path.display());
    match e.kind() {
        ErrorKind::NotFound => WsError::NotFound(what),
        ErrorKind::PermissionDenied => WsError::Denied(what),
        ErrorKind::AlreadyExists | ErrorKind::DirectoryNotEmpty => WsError::Conflict(what),
        ErrorKind::InvalidInput | ErrorKind::NotADirectory | ErrorKind::IsADirectory => {
            WsError::Invalid(what)
        }
        _ => WsError::Failed(what),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn confines_paths_to_the_roots() {
        let home = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let policy = Policy::new(home.path(), &[other.path().to_owned()]);
        std::fs::create_dir(home.path().join("a")).unwrap();
        std::os::unix::fs::symlink(outside.path(), home.path().join("escape")).unwrap();

        assert!(policy.resolve("~/a/new-file").is_ok());
        assert!(policy.resolve("~").is_ok());
        assert!(
            policy
                .resolve(&other.path().join("x").to_string_lossy())
                .is_ok()
        );
        assert!(matches!(
            policy.resolve("~/a/../../etc"),
            Err(WsError::Denied(_))
        ));
        assert!(matches!(policy.resolve("a/b"), Err(WsError::Invalid(_))));
        assert!(matches!(
            policy.resolve(&outside.path().to_string_lossy()),
            Err(WsError::Denied(_))
        ));
        // Through a symlink that leaves the root.
        assert!(matches!(
            policy.resolve("~/escape/secret"),
            Err(WsError::Denied(_))
        ));
        // The link itself may be listed, but not followed.
        assert!(policy.resolve("~/escape").is_ok());
        assert!(matches!(
            policy.resolve_followed("~/escape"),
            Err(WsError::Denied(_))
        ));
    }

    /// On a case-insensitive volume (macOS by default) another spelling names the same
    /// directory.
    #[test]
    fn the_state_dir_is_refused_in_any_case() {
        let home = tempfile::tempdir().unwrap();
        let state = home.path().join("Library/Application Support/Unnamed");
        std::fs::create_dir_all(&state).unwrap();
        std::fs::write(state.join("hook.token"), "secret").unwrap();
        let policy = Policy::new(home.path(), &[]).deny(&state);
        let other = home.path().join("library/application support/UNNAMED");
        if !other.join("hook.token").exists() {
            return; // a case-sensitive volume: another spelling is another path
        }
        for path in [other.join("hook.token"), other.join("new-file"), other] {
            let raw = path.to_string_lossy();
            assert!(
                matches!(policy.resolve(&raw), Err(WsError::Denied(_))),
                "{raw}"
            );
            assert!(
                matches!(policy.resolve_followed(&raw), Err(WsError::Denied(_))),
                "{raw}"
            );
        }
        let parent = home.path().join("LIBRARY");
        assert!(matches!(
            policy.resolve_movable(&parent.to_string_lossy()),
            Err(WsError::Denied(_))
        ));
    }

    /// Moving or deleting a directory that holds the state dir would carry it out of reach of
    /// the refusal (into another name, or the trash).
    #[test]
    fn what_holds_the_state_dir_is_not_moved() {
        let home = tempfile::tempdir().unwrap();
        let state = home.path().join(".local/state/un");
        std::fs::create_dir_all(&state).unwrap();
        std::fs::create_dir_all(home.path().join(".local/share")).unwrap();
        let policy = Policy::new(home.path(), &[]).deny(&state);
        for path in ["~/.local", "~/.local/state", "~/.local/state/un"] {
            assert!(
                matches!(policy.resolve_movable(path), Err(WsError::Denied(_))),
                "{path}"
            );
        }
        assert!(policy.resolve_movable("~/.local/share").is_ok());
        assert!(policy.resolve_movable("~/.local/state-old").is_ok());
    }

    #[test]
    fn the_state_dir_is_never_served() {
        let home = tempfile::tempdir().unwrap();
        let state = home.path().join(".local/state/un");
        std::fs::create_dir_all(&state).unwrap();
        std::fs::write(state.join("hook.token"), "secret").unwrap();
        std::os::unix::fs::symlink(&state, home.path().join("st")).unwrap();
        let policy = Policy::new(home.path(), &[]).deny(&state);
        for path in [
            "~/.local/state/un/hook.token",
            "~/.local/state/un",
            "~/.local/state/un/new-file",
            "~/st/hook.token",
        ] {
            assert!(
                matches!(policy.resolve_followed(path), Err(WsError::Denied(_))),
                "{path}"
            );
        }
        // A link to it may be listed, not followed.
        assert!(matches!(
            policy.resolve_followed("~/st"),
            Err(WsError::Denied(_))
        ));
        assert!(policy.resolve("~/.local/state/other").is_ok());
        // A state dir holding a whole root does not refuse everything.
        std::fs::create_dir(state.join("home")).unwrap();
        let policy = Policy::new(&state.join("home"), &[]).deny(&state);
        assert!(
            policy
                .resolve(&state.join("home/x").to_string_lossy())
                .is_ok()
        );
    }
}
