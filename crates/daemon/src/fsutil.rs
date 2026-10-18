//! Small filesystem helpers: atomic writes and private files.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

/// Writes `data` to `path` atomically: a temporary file in the same directory, `fsync`, rename,
/// then `fsync` of the directory, so a crash leaves either the old or the new contents.
/// The file is created with mode 0600.
pub(crate) fn write_atomic(path: &Path, data: &[u8]) -> io::Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no parent"))?;
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(
        ".{}.tmp{}",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("state"),
        std::process::id()
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

/// Creates `dir` (and parents) with mode 0700 for the leaf.
pub(crate) fn create_private_dir(dir: &Path) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
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
