//! Taking over what an install under the product's earlier name ([`brand::legacy`]) left: its
//! state directory (keys, paired devices, grants, layout) and its config directory.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::config::default_state_dir;
pub use crate::config::legacy_state_dir;

/// The file whose presence makes a directory a daemon's state (its identity).
const KEY_FILE: &str = "daemon.key";
/// A running daemon holds an exclusive `flock` on this file in its state directory.
const LOCK_FILE: &str = "hostd.lock";

/// `requested`, except that the earlier default state directory (which service definitions
/// written before the rename name explicitly) means today's default.
pub fn current_state_dir(requested: PathBuf) -> PathBuf {
    if !brand::IS_DEV && requested == legacy_state_dir() {
        default_state_dir()
    } else {
        requested
    }
}

/// Moves the earlier default state directory into `state_dir` when `state_dir` is today's
/// default and has no identity of its own yet, waiting up to `wait` for a daemon still running
/// on the old one to stop, and the earlier config directory with it ([`adopt_legacy_config`]).
/// Returns whether the state moved.
///
/// # Errors
///
/// The old daemon still runs after `wait`, or a move fails.
pub fn adopt_legacy_state(state_dir: &Path, wait: Duration) -> io::Result<bool> {
    if brand::IS_DEV || state_dir != default_state_dir() {
        return Ok(false);
    }
    if let Err(error) = adopt_legacy_config() {
        tracing::warn!("moving the earlier config directory: {error}");
    }
    adopt(&legacy_state_dir(), state_dir, wait)
}

/// Moves `~/.config/<earlier name>` (`$XDG_CONFIG_HOME` when set) to today's name if that
/// does not exist yet. Returns whether it moved.
///
/// # Errors
///
/// The rename fails.
fn adopt_legacy_config() -> io::Result<bool> {
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")));
    let Some(root) = root else { return Ok(false) };
    let (old, new) = (
        root.join(brand::legacy::DIR_NAME),
        root.join(brand::DIR_NAME),
    );
    if !old.is_dir() || new.exists() {
        return Ok(false);
    }
    fs::rename(old, new).map(|()| true)
}

/// Moves `old` into `new` if `old` holds a daemon's identity and `new` does not. `new` may
/// already exist (an installer put the new binary in it): entries move one by one, and an
/// entry both have is merged when both are directories, else left in `old`.
pub(crate) fn adopt(old: &Path, new: &Path, wait: Duration) -> io::Result<bool> {
    if !old.join(KEY_FILE).is_file() || new.join(KEY_FILE).exists() {
        return Ok(false);
    }
    let _lock = lock(&old.join(LOCK_FILE), wait)?;
    if !new.exists() {
        if let Some(parent) = new.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::rename(old, new)?;
        return Ok(true);
    }
    merge(old, new)?;
    Ok(true)
}

fn merge(old: &Path, new: &Path) -> io::Result<()> {
    for entry in fs::read_dir(old)? {
        let entry = entry?;
        let target = new.join(entry.file_name());
        match fs::symlink_metadata(&target) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                fs::rename(entry.path(), &target)?
            }
            Ok(metadata) if metadata.is_dir() && entry.file_type()?.is_dir() => {
                merge(&entry.path(), &target)?
            }
            _ => {}
        }
    }
    // Left behind only when both had a file of the same name.
    let _ = fs::remove_dir(old);
    Ok(())
}

/// Takes the old daemon's instance lock, waiting for it to stop.
fn lock(path: &Path, wait: Duration) -> io::Result<fs::File> {
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path)?;
    let deadline = Instant::now() + wait;
    loop {
        match rustix::fs::flock(&file, rustix::fs::FlockOperation::NonBlockingLockExclusive) {
            Ok(()) => return Ok(file),
            Err(_) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(100)),
            Err(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    format!(
                        "an older {} still runs on {}; stop it first",
                        brand::legacy::DAEMON_BIN,
                        path.parent().unwrap_or(path).display()
                    ),
                ));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn daemon_dir(dir: &Path) {
        fs::create_dir_all(dir.join("layout")).unwrap();
        fs::write(dir.join(KEY_FILE), b"key").unwrap();
        fs::write(dir.join("devices.json"), b"[1]").unwrap();
        fs::write(dir.join("layout/0.json"), b"{}").unwrap();
    }

    #[test]
    fn moves_the_whole_directory() {
        let root = tempfile::tempdir().unwrap();
        let (old, new) = (root.path().join("unnamed"), root.path().join("gudo"));
        daemon_dir(&old);
        assert!(adopt(&old, &new, Duration::ZERO).unwrap());
        assert!(!old.exists());
        assert_eq!(fs::read(new.join(KEY_FILE)).unwrap(), b"key");
        assert_eq!(fs::read(new.join("layout/0.json")).unwrap(), b"{}");
        assert!(!adopt(&old, &new, Duration::ZERO).unwrap());
    }

    #[test]
    fn merges_into_a_directory_an_installer_made() {
        let root = tempfile::tempdir().unwrap();
        let (old, new) = (root.path().join("unnamed"), root.path().join("Gudo"));
        daemon_dir(&old);
        fs::create_dir_all(old.join("bin")).unwrap();
        fs::write(old.join("bin/unnamed-hostd"), b"old").unwrap();
        fs::create_dir_all(new.join("bin")).unwrap();
        fs::write(new.join("bin/gudo-hostd"), b"new").unwrap();
        assert!(adopt(&old, &new, Duration::ZERO).unwrap());
        assert_eq!(fs::read(new.join("devices.json")).unwrap(), b"[1]");
        assert_eq!(fs::read(new.join("bin/gudo-hostd")).unwrap(), b"new");
        assert_eq!(fs::read(new.join("bin/unnamed-hostd")).unwrap(), b"old");
        assert!(!old.exists());
    }

    #[test]
    fn keeps_an_identity_the_new_directory_already_has() {
        let root = tempfile::tempdir().unwrap();
        let (old, new) = (root.path().join("unnamed"), root.path().join("gudo"));
        daemon_dir(&old);
        fs::create_dir_all(&new).unwrap();
        fs::write(new.join(KEY_FILE), b"mine").unwrap();
        assert!(!adopt(&old, &new, Duration::ZERO).unwrap());
        assert_eq!(fs::read(new.join(KEY_FILE)).unwrap(), b"mine");
        assert!(old.join(KEY_FILE).exists());
    }

    #[test]
    fn waits_for_the_old_daemon_to_let_go() {
        let root = tempfile::tempdir().unwrap();
        let (old, new) = (root.path().join("unnamed"), root.path().join("gudo"));
        daemon_dir(&old);
        let held = lock(&old.join(LOCK_FILE), Duration::ZERO).unwrap();
        let error = adopt(&old, &new, Duration::from_millis(200)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        assert!(old.join(KEY_FILE).exists() && !new.exists());

        let release = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            drop(held);
        });
        assert!(adopt(&old, &new, Duration::from_secs(5)).unwrap());
        release.join().unwrap();
        assert!(new.join(KEY_FILE).exists());
    }
}
