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
}

impl Policy {
    pub fn new(home: &Path, extra: &[PathBuf]) -> Self {
        let roots = std::iter::once(home)
            .chain(extra.iter().map(PathBuf::as_path))
            .map(|r| r.canonicalize().unwrap_or_else(|_| r.to_owned()))
            .collect();
        Self {
            home: home.to_owned(),
            roots,
        }
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
        let real = match (path.parent(), path.file_name()) {
            (Some(parent), Some(name)) => real_prefix(parent).join(name),
            _ => path.clone(),
        };
        if self.roots.iter().any(|r| real.starts_with(r)) {
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
            Ok(real) if self.roots.iter().any(|r| real.starts_with(r)) => Ok(path),
            Ok(real) => Err(WsError::Denied(format!(
                "{} points outside the allowed directories ({})",
                path.display(),
                real.display()
            ))),
            Err(_) => Ok(path),
        }
    }
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
}
