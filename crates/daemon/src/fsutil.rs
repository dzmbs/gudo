//! Small filesystem helpers: atomic writes and private files.

use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

/// Writes `data` to `path` atomically: a temporary file in the same directory, `fsync`, rename,
/// then `fsync` of the directory, so a crash leaves either the old or the new contents.
/// The file is created with mode 0600.
pub(crate) fn write_atomic(path: &Path, data: &[u8]) -> io::Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no parent"))?;
    fs::create_dir_all(dir)?;
    // Unique per process and write: two threads writing the same file must not share one.
    static WRITES: AtomicU64 = AtomicU64::new(0);
    let temp_path = dir.join(format!(
        ".{}.tmp{}.{}",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("state"),
        std::process::id(),
        WRITES.fetch_add(1, Ordering::Relaxed)
    ));
    {
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temp_path)?;
        file.write_all(data)?;
        file.sync_all()?;
    }
    fs::rename(&temp_path, path)?;
    File::open(dir)?.sync_all()
}

/// Runs `update` holding an exclusive lock on `<path>.lock` (`pairing.json` →
/// `pairing.lock`), for a read-modify-write of a state file that the daemon and `hostd`
/// commands (other processes) both change. Without it, `hostd pair` minting while the daemon
/// mints its startup ticket or consumes another one loses a secret, and its ticket is refused.
/// Waits for the lock; it goes when `update` returns.
pub(crate) fn with_lock<T>(path: &Path, update: impl FnOnce() -> io::Result<T>) -> io::Result<T> {
    // The file lock alone may not exclude this process's own threads: on NFS and SMB, flock
    // falls back to per-process record locks.
    static THREADS: Mutex<()> = Mutex::new(());
    let _threads = THREADS.lock().unwrap_or_else(PoisonError::into_inner);
    let lock = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(path.with_extension("lock"))?;
    lock.lock()?;
    update()
}

/// Creates `dir` (and parents) with mode 0700 for the leaf.
pub(crate) fn create_private_dir(dir: &Path) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
}

/// Creates a new directory, mode 0700, with an unguessable name under the temporary
/// directory. Creation fails rather than reuse anything already there, so another user on a
/// shared `/tmp` can neither pre-create it nor redirect it with a symlink.
pub(crate) fn create_private_temp_dir(prefix: &str) -> io::Result<PathBuf> {
    let dir = std::env::temp_dir().join(format!("{prefix}-{}", hex(&random::<12>())));
    fs::DirBuilder::new().mode(0o700).create(&dir)?;
    Ok(dir)
}

/// Creates a new file, mode 0600, with an unguessable name under the temporary directory
/// (`<prefix>-<random>.<ext>`). It never follows or replaces an existing path.
pub fn create_private_temp_file(prefix: &str, ext: &str) -> io::Result<(PathBuf, File)> {
    let path = std::env::temp_dir().join(format!("{prefix}-{}.{ext}", hex(&random::<12>())));
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)?;
    Ok((path, file))
}

pub(crate) fn read_optional(path: &Path) -> io::Result<Option<Vec<u8>>> {
    match fs::read(path) {
        Ok(data) => Ok(Some(data)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

pub(crate) fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0; N];
    getrandom::fill(&mut bytes).expect("the OS random source is available");
    bytes
}

/// Compares secrets in time that depends only on their lengths.
pub(crate) fn constant_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0, |diff, (x, y)| diff | (x ^ y)) == 0
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    data_encoding::HEXLOWER.encode(bytes)
}

/// Parses lowercase or uppercase hex into exactly `N` bytes.
pub(crate) fn unhex<const N: usize>(text: &str) -> Option<[u8; N]> {
    data_encoding::HEXLOWER_PERMISSIVE
        .decode(text.as_bytes())
        .ok()?
        .try_into()
        .ok()
}

/// How long a directory may take to answer before it counts as unreachable: `stat` on a
/// stalled network mount (NFS, SMB, sshfs, autofs) blocks for minutes.
pub(crate) const DIR_PROBE_TIMEOUT: Duration = Duration::from_millis(500);

/// Whether `path` is a directory, asked on a thread of its own so a stalled mount holds the
/// caller at most `within`. While an earlier probe of `path` is stuck past `within`, answers
/// `false` at once without starting another.
pub(crate) fn is_reachable_dir(path: &Path, within: Duration) -> bool {
    probe_dir_with(path, within, |path| path.is_dir())
}

fn probe_dir_with(
    path: &Path,
    within: Duration,
    probe: impl FnOnce(&Path) -> bool + Send + 'static,
) -> bool {
    // Each path's oldest unanswered probe and when it gave up waiting.
    static PROBING: Mutex<BTreeMap<PathBuf, Instant>> = Mutex::new(BTreeMap::new());
    let probing = || PROBING.lock().unwrap_or_else(PoisonError::into_inner);
    {
        let mut probing = probing();
        match probing.get(path) {
            Some(gave_up_at) if Instant::now() >= *gave_up_at => return false,
            Some(_) => {}
            None => {
                probing.insert(path.to_owned(), Instant::now() + within);
            }
        }
    }
    let (answer_tx, answer_rx) = std::sync::mpsc::channel();
    let probed_path = path.to_owned();
    let spawned = std::thread::Builder::new()
        .name("dir-probe".into())
        .spawn(move || {
            let is_dir = probe(&probed_path);
            probing().remove(&probed_path);
            let _ = answer_tx.send(is_dir);
        });
    if spawned.is_err() {
        probing().remove(path);
        return false;
    }
    answer_rx.recv_timeout(within).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::AtomicBool;

    /// A directory on a stalled network mount: `stat` never returns.
    #[test]
    fn a_hanging_directory_is_unreachable_without_holding_the_caller() {
        let path = Path::new("/stalled-mount-for-a-probe-test");
        let (release, released) = std::sync::mpsc::channel::<()>();
        let started = Instant::now();
        let reachable = probe_dir_with(path, Duration::from_millis(100), move |_| {
            let _ = released.recv();
            true
        });
        assert!(!reachable);
        assert!(started.elapsed() < Duration::from_secs(2));

        let probed_again = Arc::new(AtomicBool::new(false));
        let probed = Arc::clone(&probed_again);
        let started = Instant::now();
        let reachable = probe_dir_with(path, Duration::from_secs(5), move |_| {
            probed.store(true, Ordering::SeqCst);
            true
        });
        assert!(!reachable, "still stuck: unreachable at once");
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(!probed_again.load(Ordering::SeqCst));

        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !probe_dir_with(path, Duration::from_secs(5), |_| true) {
            assert!(Instant::now() < deadline, "the mount answers again");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn a_healthy_directory_is_reachable() {
        let dir = tempfile::tempdir().unwrap();
        assert!(is_reachable_dir(dir.path(), DIR_PROBE_TIMEOUT));
        assert!(!is_reachable_dir(
            &dir.path().join("missing"),
            DIR_PROBE_TIMEOUT
        ));
    }
}
