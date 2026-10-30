//! Small filesystem helpers: atomic writes and private files.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};

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
    let tmp = dir.join(format!(
        ".{}.tmp{}.{}",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("state"),
        std::process::id(),
        WRITES.fetch_add(1, Ordering::Relaxed)
    ));
    {
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(data)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)?;
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

/// Reads a file, mapping "not found" to `None`.
pub(crate) fn read_optional(path: &Path) -> io::Result<Option<Vec<u8>>> {
    match fs::read(path) {
        Ok(data) => Ok(Some(data)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// Fills a buffer with OS randomness.
pub(crate) fn random<const N: usize>() -> [u8; N] {
    let mut buf = [0; N];
    getrandom::fill(&mut buf).expect("the OS random source is available");
    buf
}

/// Compares secrets in time that depends only on their lengths.
pub(crate) fn constant_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0, |diff, (x, y)| diff | (x ^ y)) == 0
}

/// Lowercase hex.
pub(crate) fn hex(bytes: &[u8]) -> String {
    data_encoding::HEXLOWER.encode(bytes)
}

/// Parses lowercase or uppercase hex into exactly `N` bytes.
pub(crate) fn unhex<const N: usize>(s: &str) -> Option<[u8; N]> {
    data_encoding::HEXLOWER_PERMISSIVE
        .decode(s.as_bytes())
        .ok()?
        .try_into()
        .ok()
}
