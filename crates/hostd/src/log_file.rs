//! The daemon's log in a file it keeps small, for a daemon started without a service manager,
//! whose journal would otherwise bound it.

use std::fs::{File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// A log this large moves to `<file>.1`, replacing the one before, so the two stay under
/// twice this.
pub const MAX_LOG_BYTES: u64 = 8 << 20;
const CHECK_INTERVAL: Duration = Duration::from_secs(30);

/// Points stdout and stderr (the log, panics included) at `path`, appending, and keeps it
/// under [`MAX_LOG_BYTES`] for the life of the process.
pub fn write_to(path: &Path) -> io::Result<()> {
    point_output_at(&open(path)?)?;
    let path = path.to_owned();
    std::thread::Builder::new()
        .name("log-rotation".into())
        .spawn(move || {
            loop {
                std::thread::sleep(CHECK_INTERVAL);
                if let Ok(Some(fresh)) = rotate_if_full(&path, MAX_LOG_BYTES) {
                    let _ = point_output_at(&fresh);
                }
            }
        })?;
    Ok(())
}

/// Moves a log of `max_bytes` or more to `<path>.1` and returns a fresh, empty one at `path`.
pub fn rotate_if_full(path: &Path, max_bytes: u64) -> io::Result<Option<File>> {
    if std::fs::metadata(path)?.len() < max_bytes {
        return Ok(None);
    }
    std::fs::rename(path, rotated_path(path))?;
    open(path).map(Some)
}

pub fn rotated_path(path: &Path) -> PathBuf {
    let mut rotated = path.as_os_str().to_owned();
    rotated.push(".1");
    PathBuf::from(rotated)
}

fn open(path: &Path) -> io::Result<File> {
    OpenOptions::new().create(true).append(true).open(path)
}

fn point_output_at(file: &File) -> io::Result<()> {
    rustix::stdio::dup2_stdout(file)?;
    rustix::stdio::dup2_stderr(file)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_full_log_moves_aside_and_a_fresh_one_starts() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("hostd.log");
        std::fs::write(&log, "old line\n").unwrap();
        assert!(rotate_if_full(&log, 100).unwrap().is_none());

        std::fs::write(rotated_path(&log), "older\n").unwrap();
        std::fs::write(&log, "x".repeat(100)).unwrap();
        let fresh = rotate_if_full(&log, 100).unwrap();
        assert!(fresh.is_some());
        assert_eq!(std::fs::metadata(&log).unwrap().len(), 0);
        assert_eq!(
            std::fs::read_to_string(rotated_path(&log)).unwrap(),
            "x".repeat(100)
        );
    }
}
