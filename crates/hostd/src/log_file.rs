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

/// The file stderr was pointed at by whoever started the daemon (launchd's
/// `StandardErrorPath`), so a log the daemon was not told about is kept small too.
pub fn inherited_stderr_file() -> Option<PathBuf> {
    regular_file_path(&std::io::stderr())
}

fn regular_file_path(fd: &impl std::os::fd::AsFd) -> Option<PathBuf> {
    let path = fd_path(fd)?;
    std::fs::metadata(&path)
        .is_ok_and(|meta| meta.is_file())
        .then_some(path)
}

#[cfg(target_os = "macos")]
fn fd_path(fd: &impl std::os::fd::AsFd) -> Option<PathBuf> {
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    let mut buffer = [0u8; libc::PATH_MAX as usize];
    // SAFETY: F_GETPATH writes a NUL-terminated path of at most PATH_MAX bytes into `buffer`.
    let status =
        unsafe { libc::fcntl(fd.as_fd().as_raw_fd(), libc::F_GETPATH, buffer.as_mut_ptr()) };
    if status == -1 {
        return None;
    }
    let length = buffer.iter().position(|&byte| byte == 0)?;
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(
        &buffer[..length],
    )))
}

#[cfg(not(target_os = "macos"))]
fn fd_path(fd: &impl std::os::fd::AsFd) -> Option<PathBuf> {
    use std::os::fd::AsRawFd;
    std::fs::read_link(format!("/proc/self/fd/{}", fd.as_fd().as_raw_fd())).ok()
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

    #[test]
    fn an_inherited_log_file_is_found_by_its_open_descriptor() {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("hostd.log");
        let file = open(&log).unwrap();
        assert_eq!(
            regular_file_path(&file).map(|path| path.canonicalize().unwrap()),
            Some(log.canonicalize().unwrap())
        );
    }

    #[test]
    fn a_pipe_is_not_a_log_file() {
        let (reader, _writer) = rustix::pipe::pipe().unwrap();
        assert_eq!(regular_file_path(&reader), None);
    }
}
