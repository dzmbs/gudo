//! File requests: list, stat, read, write, mkdir, rename, delete (or trash), and the upload
//! and download streams.
//!
//! Writes never leave a half-written file: data goes to a temporary file in the target's
//! directory (`.<name>.<product>-upload-<hex>`), is fsynced, then renamed over the target (or
//! hard-linked when the target must not exist, which fails atomically if it appeared), and the
//! directory is fsynced. `if_match` compares the target's version right before the rename.

use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use iroh::endpoint::{RecvStream, SendStream};
use proto::{
    DeleteMode, DirListing, DownloadHeader, FileChunk, FileKind, FileStat, TransferReply,
    UnixMillis, UploadHeader, WriteTarget, WsError,
};
use tokio::io::AsyncReadExt;

use super::paths::{Policy, io_error};
use crate::net;

/// Most entries returned by one listing.
const MAX_ENTRIES: usize = 10_000;
/// Most bytes returned by one `FsRead` or accepted by one `FsWrite` (a ctl frame).
pub(crate) const MAX_INLINE: usize = 1 << 20;
/// Copy buffer for transfers.
const CHUNK: usize = 256 << 10;

fn kind_of(meta: &Metadata) -> FileKind {
    let t = meta.file_type();
    if t.is_symlink() {
        FileKind::Symlink
    } else if t.is_dir() {
        FileKind::Dir
    } else if t.is_file() {
        FileKind::File
    } else {
        FileKind::Other
    }
}

fn version_of(meta: &Metadata) -> String {
    let nanos = meta.mtime() as i128 * 1_000_000_000 + i128::from(meta.mtime_nsec());
    format!("{:x}-{:x}-{:x}", meta.ino(), meta.size(), nanos)
}

/// `lstat` of `path` as a [`FileStat`].
pub(crate) fn stat(path: &Path) -> Result<FileStat, WsError> {
    let meta = fs::symlink_metadata(path).map_err(|e| io_error(path, &e))?;
    Ok(stat_from(path, &meta))
}

fn stat_from(path: &Path, meta: &Metadata) -> FileStat {
    let name = path
        .file_name()
        .map_or_else(|| "/".to_owned(), |n| n.to_string_lossy().into_owned());
    let kind = kind_of(meta);
    let (link_target, target_kind) = if kind == FileKind::Symlink {
        (
            fs::read_link(path)
                .ok()
                .map(|t| t.to_string_lossy().into_owned()),
            fs::metadata(path).ok().map(|m| kind_of(&m)),
        )
    } else {
        (None, None)
    };
    FileStat {
        path: path.to_string_lossy().into_owned(),
        hidden: name.starts_with('.'),
        name,
        kind,
        size: meta.size(),
        modified: UnixMillis(
            (meta.mtime().max(0) as u64) * 1000 + (meta.mtime_nsec().max(0) as u64) / 1_000_000,
        ),
        mode: meta.mode() & 0o7777,
        link_target,
        target_kind,
        version: version_of(meta),
    }
}

pub(crate) fn list(policy: &Policy, raw: &str, show_hidden: bool) -> Result<DirListing, WsError> {
    let dir = policy.resolve_followed(raw)?;
    let entries = fs::read_dir(&dir).map_err(|e| io_error(&dir, &e))?;
    let mut out = Vec::new();
    let mut truncated = false;
    for entry in entries.filter_map(Result::ok) {
        let hidden = entry.file_name().as_encoded_bytes().first() == Some(&b'.');
        if hidden && !show_hidden {
            continue;
        }
        if out.len() == MAX_ENTRIES {
            truncated = true;
            break;
        }
        let path = entry.path();
        if let Ok(meta) = fs::symlink_metadata(&path) {
            out.push(stat_from(&path, &meta));
        }
    }
    let is_dirish = |s: &FileStat| s.kind == FileKind::Dir || s.target_kind == Some(FileKind::Dir);
    out.sort_by(|a, b| {
        is_dirish(b)
            .cmp(&is_dirish(a))
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            .then_with(|| a.name.cmp(&b.name))
    });
    Ok(DirListing {
        path: dir.to_string_lossy().into_owned(),
        entries: out,
        truncated,
    })
}

pub(crate) fn read(
    policy: &Policy,
    raw: &str,
    offset: u64,
    len: u32,
) -> Result<FileChunk, WsError> {
    let path = policy.resolve_followed(raw)?;
    let mut file = File::open(&path).map_err(|e| io_error(&path, &e))?;
    let meta = file.metadata().map_err(|e| io_error(&path, &e))?;
    if meta.is_dir() {
        return Err(WsError::Invalid(format!(
            "{} is a directory",
            path.display()
        )));
    }
    let len = (len as usize).min(MAX_INLINE);
    file.seek(SeekFrom::Start(offset))
        .map_err(|e| io_error(&path, &e))?;
    let mut data = Vec::with_capacity(len.min(meta.size().saturating_sub(offset) as usize));
    Read::by_ref(&mut file)
        .take(len as u64)
        .read_to_end(&mut data)
        .map_err(|e| io_error(&path, &e))?;
    let eof = offset + data.len() as u64 >= meta.size();
    Ok(FileChunk {
        stat: stat_from(&path, &meta),
        offset,
        data,
        eof,
    })
}

pub(crate) fn mkdir(policy: &Policy, raw: &str, parents: bool) -> Result<FileStat, WsError> {
    let path = policy.resolve(raw)?;
    let made = if parents {
        fs::create_dir_all(&path)
    } else {
        fs::create_dir(&path)
    };
    made.map_err(|e| io_error(&path, &e))?;
    stat(&path)
}

pub(crate) fn rename(
    policy: &Policy,
    from: &str,
    to: &str,
    overwrite: bool,
) -> Result<FileStat, WsError> {
    let from = policy.resolve(from)?;
    let to = policy.resolve(to)?;
    fs::symlink_metadata(&from).map_err(|e| io_error(&from, &e))?;
    if overwrite {
        fs::rename(&from, &to).map_err(|e| io_error(&to, &e))?;
    } else {
        rename_noreplace(&from, &to).map_err(|e| io_error(&to, &e))?;
    }
    stat(&to)
}

/// `rename` that fails with `AlreadyExists` instead of replacing the destination, atomically
/// (`renameat2(RENAME_NOREPLACE)` / `renamex_np(RENAME_EXCL)`).
fn rename_noreplace(from: &Path, to: &Path) -> io::Result<()> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let c = |p: &Path| {
        CString::new(p.as_os_str().as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path contains NUL"))
    };
    let (f, t) = (c(from)?, c(to)?);
    // The raw syscall: the static musl builds (zig's musl) have no `renameat2` wrapper.
    #[cfg(target_os = "linux")]
    // SAFETY: both arguments are valid NUL-terminated paths for the duration of the call, and
    // renameat2 takes (int, const char *, int, const char *, unsigned int).
    let ret = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            f.as_ptr(),
            libc::AT_FDCWD,
            t.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(target_os = "macos")]
    // SAFETY: as above.
    let ret = unsafe { libc::renamex_np(f.as_ptr(), t.as_ptr(), libc::RENAME_EXCL) };
    if ret == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

pub(crate) fn delete(
    policy: &Policy,
    raw: &str,
    mode: DeleteMode,
    recursive: bool,
) -> Result<(), WsError> {
    let path = policy.resolve(raw)?;
    if policy.home() == path.as_path() || path.parent().is_none() {
        return Err(WsError::Denied(format!(
            "refusing to delete {}",
            path.display()
        )));
    }
    let meta = fs::symlink_metadata(&path).map_err(|e| io_error(&path, &e))?;
    let is_dir = meta.is_dir();
    if is_dir && !recursive {
        let empty = fs::read_dir(&path)
            .map_err(|e| io_error(&path, &e))?
            .next()
            .is_none();
        if !empty {
            return Err(WsError::Conflict(format!(
                "{} is not empty (set recursive)",
                path.display()
            )));
        }
    }
    match mode {
        DeleteMode::Trash => trash(policy.home(), &path),
        DeleteMode::Permanent => {
            let removed = if is_dir {
                fs::remove_dir_all(&path)
            } else {
                fs::remove_file(&path)
            };
            removed.map_err(|e| io_error(&path, &e))
        }
    }
}

/// Moves `path` into the user's trash.
fn trash(home: &Path, path: &Path) -> Result<(), WsError> {
    let name = path
        .file_name()
        .ok_or_else(|| WsError::Invalid("nothing to trash".into()))?
        .to_string_lossy()
        .into_owned();
    let (files, info) = trash_dirs(home);
    fs::create_dir_all(&files).map_err(|e| io_error(&files, &e))?;
    if let Some(info) = &info {
        fs::create_dir_all(info).map_err(|e| io_error(info, &e))?;
    }
    for n in 0..1000u32 {
        let candidate = if n == 0 {
            name.clone()
        } else {
            format!("{name}.{n}")
        };
        let dest = files.join(&candidate);
        // Reserve the info file first (the XDG spec's lock), then move.
        if let Some(info) = &info {
            let info_path = info.join(format!("{candidate}.trashinfo"));
            let mut f = match OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&info_path)
            {
                Ok(f) => f,
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(io_error(&info_path, &e)),
            };
            let body = format!(
                "[Trash Info]\nPath={}\nDeletionDate={}\n",
                percent_encode(&path.to_string_lossy()),
                iso_datetime(crate::identity::now_millis() / 1000)
            );
            f.write_all(body.as_bytes())
                .map_err(|e| io_error(&info_path, &e))?;
            return match rename_noreplace(path, &dest) {
                Ok(()) => Ok(()),
                Err(e) => {
                    let _ = fs::remove_file(&info_path);
                    Err(trash_error(path, &e))
                }
            };
        }
        match rename_noreplace(path, &dest) {
            Ok(()) => return Ok(()),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(trash_error(path, &e)),
        }
    }
    Err(WsError::Failed(
        "the trash has too many items with that name".into(),
    ))
}

fn trash_error(path: &Path, e: &io::Error) -> WsError {
    if e.raw_os_error() == Some(libc::EXDEV) {
        WsError::Failed(format!(
            "{} is on another filesystem than the trash; delete it permanently instead",
            path.display()
        ))
    } else {
        io_error(path, e)
    }
}

/// `(files, info)`: `~/.Trash` on macOS; the XDG home trash on Linux.
fn trash_dirs(home: &Path) -> (PathBuf, Option<PathBuf>) {
    if cfg!(target_os = "macos") {
        return (home.join(".Trash"), None);
    }
    let data = std::env::var_os("XDG_DATA_HOME")
        .filter(|v| !v.is_empty())
        .map_or_else(|| home.join(".local/share"), PathBuf::from);
    let trash = data.join("Trash");
    (trash.join("files"), Some(trash.join("info")))
}

fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"/-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// `YYYY-MM-DDThh:mm:ss` (UTC) for `secs` since the epoch.
fn iso_datetime(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}",
        rem / 3600,
        rem / 60 % 60,
        rem % 60
    )
}

// --- atomic writes ---------------------------------------------------------------------------

/// A write in progress: the temporary file next to the target.
pub(crate) struct PendingWrite {
    target: PathBuf,
    tmp: PathBuf,
    file: Option<File>,
    if_match: Option<String>,
    create_new: bool,
    keep_mode: Option<u32>,
}

impl PendingWrite {
    /// Checks the preconditions and creates the temporary file. Returns the existing file's
    /// stat too.
    pub fn begin(
        policy: &Policy,
        target: &WriteTarget,
    ) -> Result<(Self, Option<FileStat>), WsError> {
        let path = policy.resolve_followed(&target.path)?;
        // Write through a symlink to its target, as editors do.
        let path = fs::canonicalize(&path).unwrap_or(path);
        let parent = path
            .parent()
            .ok_or_else(|| WsError::Invalid("no parent directory".into()))?
            .to_owned();
        if target.mkdirs {
            fs::create_dir_all(&parent).map_err(|e| io_error(&parent, &e))?;
        }
        let existing = match fs::metadata(&path) {
            Ok(m) if m.is_dir() => {
                return Err(WsError::Invalid(format!(
                    "{} is a directory",
                    path.display()
                )));
            }
            Ok(m) => Some(m),
            Err(e) if e.kind() == io::ErrorKind::NotFound => None,
            Err(e) => return Err(io_error(&path, &e)),
        };
        check_preconditions(&path, existing.as_ref(), target)?;
        let name = path
            .file_name()
            .ok_or_else(|| WsError::Invalid("no file name".into()))?
            .to_string_lossy();
        let tmp = parent.join(format!(
            ".{name}.{}-upload-{}",
            brand::DIR_NAME,
            crate::fsutil::hex(&crate::fsutil::random::<6>())
        ));
        let keep_mode = existing.as_ref().map(|m| m.mode() & 0o7777);
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(keep_mode.or(target.mode).unwrap_or(0o666))
            .open(&tmp)
            .map_err(|e| io_error(&tmp, &e))?;
        let stat = existing.as_ref().map(|m| stat_from(&path, m));
        Ok((
            Self {
                target: path,
                tmp,
                file: Some(file),
                if_match: target.if_match.clone(),
                create_new: target.create_new,
                keep_mode,
            },
            stat,
        ))
    }

    pub fn write(&mut self, data: &[u8]) -> Result<(), WsError> {
        let file = self.file.as_mut().expect("open until commit");
        file.write_all(data).map_err(|e| io_error(&self.tmp, &e))
    }

    /// fsyncs and moves the file into place.
    pub fn commit(mut self) -> Result<FileStat, WsError> {
        let file = self.file.take().expect("open until commit");
        file.sync_all().map_err(|e| io_error(&self.tmp, &e))?;
        if let Some(mode) = self.keep_mode {
            // Creation applied the umask; an existing file keeps its exact bits.
            let _ = fs::set_permissions(&self.tmp, fs::Permissions::from_mode(mode));
        }
        drop(file);
        let current = fs::metadata(&self.target).ok();
        let target = WriteTarget {
            path: String::new(),
            if_match: self.if_match.clone(),
            create_new: self.create_new,
            mkdirs: false,
            mode: None,
        };
        check_preconditions(&self.target, current.as_ref(), &target)?;
        if self.create_new && self.if_match.is_none() {
            // A hard link fails if the target appeared meanwhile; rename would replace it.
            fs::hard_link(&self.tmp, &self.target).map_err(|e| io_error(&self.target, &e))?;
            let _ = fs::remove_file(&self.tmp);
        } else {
            fs::rename(&self.tmp, &self.target).map_err(|e| io_error(&self.target, &e))?;
        }
        if let Some(dir) = self.target.parent() {
            let _ = File::open(dir).and_then(|d| d.sync_all());
        }
        stat(&self.target)
    }
}

impl Drop for PendingWrite {
    fn drop(&mut self) {
        // Not committed (failed or abandoned): never leave the temporary file behind.
        if self.file.is_some() || self.tmp.exists() {
            let _ = fs::remove_file(&self.tmp);
        }
    }
}

fn check_preconditions(
    path: &Path,
    existing: Option<&Metadata>,
    target: &WriteTarget,
) -> Result<(), WsError> {
    match (&target.if_match, existing) {
        (Some(want), Some(m)) if *want != version_of(m) => Err(WsError::Conflict(format!(
            "{} changed since version {want}",
            path.display()
        ))),
        (Some(want), None) => Err(WsError::Conflict(format!(
            "{} no longer exists (expected version {want})",
            path.display()
        ))),
        (None, Some(_)) if target.create_new => Err(WsError::Conflict(format!(
            "{} already exists",
            path.display()
        ))),
        _ => Ok(()),
    }
}

/// `FsWrite`: a small file in one message.
pub(crate) fn write_small(
    policy: &Policy,
    target: &WriteTarget,
    data: &[u8],
) -> Result<FileStat, WsError> {
    if data.len() > MAX_INLINE {
        return Err(WsError::Invalid(
            "too large for FsWrite; use an upload stream".into(),
        ));
    }
    let (mut pending, _) = PendingWrite::begin(policy, target)?;
    pending.write(data)?;
    pending.commit()
}

// --- transfer streams ----------------------------------------------------------------------

/// Serves an upload stream: header → `Ready` → `size` bytes → `Done`.
pub(crate) async fn serve_upload(
    policy: Policy,
    header: UploadHeader,
    mut send: SendStream,
    mut recv: RecvStream,
) {
    let reply = upload(&policy, &header, &mut send, &mut recv).await;
    let msg = match reply {
        Ok(stat) => TransferReply::Done(stat),
        Err(e) => {
            let _ = recv.stop(0u32.into());
            TransferReply::Failed(e)
        }
    };
    let _ = net::send(&mut send, &msg).await;
    let _ = send.finish();
    let _ = send.stopped().await;
}

async fn upload(
    policy: &Policy,
    header: &UploadHeader,
    send: &mut SendStream,
    recv: &mut RecvStream,
) -> Result<FileStat, WsError> {
    let (policy2, target) = (policy.clone(), header.target.clone());
    let (pending, existing) =
        tokio::task::spawn_blocking(move || PendingWrite::begin(&policy2, &target))
            .await
            .map_err(|e| WsError::Failed(e.to_string()))??;
    let ready = TransferReply::Ready {
        stat: existing,
        len: header.size,
    };
    net::send(send, &ready)
        .await
        .map_err(|e| WsError::Failed(e.to_string()))?;
    // The file is written from a blocking thread fed through a small channel, so a slow disk
    // slows the stream (QUIC flow control) instead of buffering in memory.
    let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<u8>>(4);
    let writer = tokio::task::spawn_blocking(move || {
        let mut pending = pending;
        while let Some(chunk) = rx.blocking_recv() {
            pending.write(&chunk)?;
        }
        Ok::<_, WsError>(pending)
    });
    let mut received: u64 = 0;
    let mut buf = vec![0; CHUNK];
    let read_result = loop {
        match recv.read(&mut buf).await {
            Ok(Some(n)) => {
                received += n as u64;
                if received > header.size {
                    break Err(WsError::Invalid(format!(
                        "more than the announced {} bytes",
                        header.size
                    )));
                }
                if tx.send(buf[..n].to_vec()).await.is_err() {
                    break Ok(());
                }
            }
            Ok(None) => break Ok(()),
            Err(e) => break Err(WsError::Failed(format!("upload stream: {e}"))),
        }
    };
    drop(tx);
    let pending = writer.await.map_err(|e| WsError::Failed(e.to_string()))??;
    read_result?;
    if received != header.size {
        return Err(WsError::Invalid(format!(
            "stream ended after {received} of {} bytes",
            header.size
        )));
    }
    tokio::task::spawn_blocking(move || pending.commit())
        .await
        .map_err(|e| WsError::Failed(e.to_string()))?
}

/// Serves a download stream: header → `Ready{len}` → `len` bytes → finish.
pub(crate) async fn serve_download(policy: Policy, header: DownloadHeader, mut send: SendStream) {
    let opened = open_download(&policy, &header).await;
    let (file, stat, len) = match opened {
        Ok(v) => v,
        Err(e) => {
            let _ = net::send(&mut send, &TransferReply::Failed(e)).await;
            let _ = send.finish();
            return;
        }
    };
    let ready = TransferReply::Ready {
        stat: Some(stat),
        len,
    };
    if net::send(&mut send, &ready).await.is_err() {
        return;
    }
    let mut file = tokio::fs::File::from_std(file).take(len);
    let mut buf = vec![0; CHUNK];
    loop {
        match file.read(&mut buf).await {
            Ok(0) => break,
            Ok(n) => {
                if send.write_all(&buf[..n]).await.is_err() {
                    return;
                }
            }
            Err(e) => {
                tracing::debug!("download read: {e}");
                // Resetting tells the client the bytes are incomplete.
                let _ = send.reset(1u32.into());
                return;
            }
        }
    }
    let _ = send.finish();
    let _ = send.stopped().await;
}

async fn open_download(
    policy: &Policy,
    header: &DownloadHeader,
) -> Result<(File, FileStat, u64), WsError> {
    let (policy, header) = (policy.clone(), header.clone());
    tokio::task::spawn_blocking(move || {
        let path = policy.resolve_followed(&header.path)?;
        let mut file = File::open(&path).map_err(|e| io_error(&path, &e))?;
        let meta = file.metadata().map_err(|e| io_error(&path, &e))?;
        if meta.is_dir() {
            return Err(WsError::Invalid(format!(
                "{} is a directory",
                path.display()
            )));
        }
        let available = meta.size().saturating_sub(header.offset);
        let len = header.len.map_or(available, |l| l.min(available));
        file.seek(SeekFrom::Start(header.offset))
            .map_err(|e| io_error(&path, &e))?;
        Ok((file, stat_from(&path, &meta), len))
    })
    .await
    .map_err(|e| WsError::Failed(e.to_string()))?
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(path: &Path) -> WriteTarget {
        WriteTarget {
            path: path.to_string_lossy().into_owned(),
            if_match: None,
            create_new: false,
            mkdirs: true,
            mode: None,
        }
    }

    #[test]
    fn writes_are_atomic_and_versioned() {
        let home = tempfile::tempdir().unwrap();
        let policy = Policy::new(home.path(), &[]);
        let file = home.path().join("sub/f.txt");
        let first = write_small(&policy, &target(&file), b"one").unwrap();
        assert_eq!(fs::read(&file).unwrap(), b"one");
        let mut t = target(&file);
        t.if_match = Some(first.version.clone());
        let second = write_small(&policy, &t, b"two!").unwrap();
        assert_ne!(first.version, second.version);
        // A stale version is refused and nothing is left behind.
        assert!(matches!(
            write_small(&policy, &t, b"three"),
            Err(WsError::Conflict(_))
        ));
        assert_eq!(fs::read(&file).unwrap(), b"two!");
        let mut t = target(&file);
        t.create_new = true;
        assert!(matches!(
            write_small(&policy, &t, b"x"),
            Err(WsError::Conflict(_))
        ));
        let names: Vec<_> = fs::read_dir(home.path().join("sub"))
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names.len(), 1, "temporary files left: {names:?}");
    }

    #[test]
    fn trash_info_date_is_iso() {
        assert_eq!(iso_datetime(0), "1970-01-01T00:00:00");
        assert_eq!(iso_datetime(1_760_000_000), "2025-10-09T08:53:20");
        assert_eq!(percent_encode("/a b/ü"), "/a%20b/%C3%BC");
    }
}
