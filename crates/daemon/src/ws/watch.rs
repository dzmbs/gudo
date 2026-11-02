//! Directory watches for the file browser: `notify` (FSEvents on macOS, inotify on Linux),
//! debounced and delivered to the watching connection only.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use notify::{RecursiveMode, Watcher};
use proto::{FsChange, ServerCtl, WsError};
use tokio::sync::mpsc;
use tokio::task::AbortHandle;

/// Changes are collected this long before one `FsChanged` goes out.
const DEBOUNCE: Duration = Duration::from_millis(100);
/// More changed paths than this in one batch become `rescan`.
const MAX_PATHS: usize = 256;

/// Dropping it stops watching.
pub(crate) struct Watch {
    _watcher: notify::RecommendedWatcher,
    task: AbortHandle,
}

impl Drop for Watch {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// Watches `dir` non-recursively.
pub(crate) fn start(
    dir: &Path,
    watch_id: u64,
    out: mpsc::UnboundedSender<ServerCtl>,
) -> Result<Watch, WsError> {
    if !dir.is_dir() {
        return Err(WsError::Invalid(format!(
            "{} is not a directory",
            dir.display()
        )));
    }
    // FSEvents reports real paths (/private/var/… for /var/…); report them under the path the
    // client asked for.
    let real_dir = dir.canonicalize().unwrap_or_else(|_| dir.to_owned());
    let shown_dir = dir.to_owned();
    let (tx, mut rx) = mpsc::unbounded_channel::<Vec<PathBuf>>();
    let mut watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
        match result {
            Ok(event) => {
                let _ = tx.send(event.paths);
            }
            // Overflow and similar errors: tell the client to list again.
            Err(_) => {
                let _ = tx.send(Vec::new());
            }
        }
    })
    .map_err(|error| WsError::Failed(format!("watching {}: {error}", dir.display())))?;
    watcher
        .watch(dir, RecursiveMode::NonRecursive)
        .map_err(|error| WsError::Failed(format!("watching {}: {error}", dir.display())))?;
    let task = tokio::spawn(async move {
        while let Some(first) = rx.recv().await {
            let mut paths = BTreeSet::new();
            let mut rescan = first.is_empty();
            paths.extend(first);
            let deadline = tokio::time::Instant::now() + DEBOUNCE;
            while let Ok(Some(more)) = tokio::time::timeout_at(deadline, rx.recv()).await {
                rescan |= more.is_empty();
                paths.extend(more);
            }
            let mut shown_paths: Vec<String> = paths
                .into_iter()
                .map(|path| match path.strip_prefix(&real_dir) {
                    Ok(rest) => shown_dir.join(rest),
                    Err(_) => path,
                })
                // The directory itself changing (mtime) is implied by its children.
                .filter(|path| *path != shown_dir)
                .map(|path| path.to_string_lossy().into_owned())
                .collect();
            if shown_paths.len() > MAX_PATHS {
                shown_paths.clear();
                rescan = true;
            }
            if shown_paths.is_empty() && !rescan {
                continue;
            }
            let change = FsChange {
                watch_id,
                paths: shown_paths,
                rescan,
            };
            if out.send(ServerCtl::FsChanged(change)).is_err() {
                return;
            }
        }
    });
    Ok(Watch {
        _watcher: watcher,
        task: task.abort_handle(),
    })
}
