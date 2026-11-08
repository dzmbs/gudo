//! `ResolvePaths`: paths a pane printed, made absolute where the printing command ran.

use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use proto::{PathFound, PathQuery, ResolvedPath, WsError};

use super::paths::Policy;
use crate::scan::normalize;

const MAX_PATH_LEN: usize = 4096;

/// Rejects a query the daemon will not walk: too many paths, or ones no file system has.
pub(crate) fn validate(query: &PathQuery) -> Result<(), WsError> {
    if query.paths.len() > PathQuery::MAX_PATHS {
        return Err(WsError::Invalid(format!(
            "at most {} paths at once",
            PathQuery::MAX_PATHS
        )));
    }
    if query
        .paths
        .iter()
        .any(|path| path.is_empty() || path.len() > MAX_PATH_LEN || path.contains('\0'))
    {
        return Err(WsError::Invalid("empty, overlong or NUL path".into()));
    }
    Ok(())
}

pub(crate) fn resolve_all(
    policy: &Policy,
    paths: &[String],
    directory: Option<&Path>,
    home: &Path,
) -> Vec<ResolvedPath> {
    paths
        .iter()
        .map(|printed| match absolute(printed, directory, home) {
            Some(path) => ResolvedPath {
                path: path.to_string_lossy().into_owned(),
                found: look(policy, &path),
            },
            None => ResolvedPath {
                path: printed.clone(),
                found: PathFound::Missing,
            },
        })
        .collect()
}

fn absolute(printed: &str, directory: Option<&Path>, home: &Path) -> Option<PathBuf> {
    let joined = if printed == "~" {
        home.to_owned()
    } else if let Some(rest) = printed.strip_prefix("~/") {
        home.join(rest)
    } else if printed.starts_with('/') {
        PathBuf::from(printed)
    } else {
        directory
            .filter(|directory| directory.is_absolute())?
            .join(printed)
    };
    Some(normalize(&joined))
}

// Security: policy first, so a denied path never reveals whether it exists.
fn look(policy: &Policy, path: &Path) -> PathFound {
    let Ok(allowed) = policy.resolve_followed(&path.to_string_lossy()) else {
        return PathFound::Denied;
    };
    match std::fs::metadata(&allowed) {
        Ok(meta) if meta.is_file() => PathFound::File { size: meta.len() },
        Ok(meta) if meta.is_dir() => PathFound::Dir,
        Ok(_) => PathFound::Other,
        Err(error) if error.kind() == ErrorKind::PermissionDenied => PathFound::Denied,
        Err(_) => PathFound::Missing,
    }
}
