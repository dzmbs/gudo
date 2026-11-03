//! Self upgrade: the owner streams a new build over the connection, the daemon verifies it and
//! swaps it in, then asks the host process to restart into it (`proto::info`).
//!
//! Verification, in order: the stream carries exactly the announced size; the decoded
//! executable's SHA-256 matches the header (the owner's device, authenticated by the QUIC
//! handshake, vouches for the bytes; there is no release signing key yet); the new file runs
//! on this host (`<new> build-info --json` within 15 s) and reports this OS and CPU; it is not
//! older than the running build unless the owner asked for a downgrade (rollback protection: a
//! stale or compromised owner device cannot quietly reinstate a build with known bugs). Only then
//! is it renamed over the running executable (atomic within the directory; the old one is
//! kept as `<exe>.prev`), and the host process `exec`s it after saving the layout and stopping
//! the panes. Any failure leaves the running daemon and its file untouched.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use iroh::endpoint::{RecvStream, SendStream};
use proto::{
    Actor, AuditKind, DaemonFeatures, DaemonInfo, StreamHeader, UpgradeEncoding, UpgradeFailure,
    UpgradeHeader, UpgradeReply,
};
use tokio::sync::watch;

use crate::core::Core;
use crate::net;

/// Largest build accepted, encoded or decoded.
const MAX_SIZE: u64 = 256 << 20;
/// How long the new build may take to report itself.
const CHECK_TIMEOUT: Duration = Duration::from_secs(15);

/// Upgrade state kept by the core.
pub(crate) struct Upgrade {
    busy: AtomicBool,
    restart: watch::Sender<Option<PathBuf>>,
    /// The build to restart into continues running panes (`handoff`).
    successor_adopts: AtomicBool,
    /// The file the daemon started from ([`file_identity`] of `Config::exe`), so a local
    /// restart request for the same file changes nothing.
    started_from: Option<(u64, u64, u64, i64)>,
}

impl Upgrade {
    pub fn new(exe: Option<&Path>) -> Self {
        Self {
            busy: AtomicBool::new(false),
            restart: watch::channel(None).0,
            successor_adopts: AtomicBool::new(false),
            started_from: exe.and_then(file_identity),
        }
    }

    pub fn successor_adopts(&self) -> bool {
        self.successor_adopts.load(Ordering::Acquire)
    }

    fn request_restart(&self, exe: PathBuf, adopts: bool) {
        self.successor_adopts.store(adopts, Ordering::Release);
        self.restart.send_replace(Some(exe));
    }

    /// Resolves with the executable to restart into once an upgrade was installed.
    pub fn restart_requested(&self) -> impl Future<Output = PathBuf> + Send + 'static {
        let mut rx = self.restart.subscribe();
        async move {
            loop {
                if let Some(path) = rx.borrow_and_update().clone() {
                    return path;
                }
                if rx.changed().await.is_err() {
                    std::future::pending::<()>().await;
                }
            }
        }
    }
}

type Failure = (UpgradeFailure, String);

fn fail(code: UpgradeFailure, message: impl Into<String>) -> Failure {
    (code, message.into())
}

/// The build an upgrade stream announces, and whether the owner sent it as a downgrade.
pub(crate) fn requested(header: &StreamHeader) -> Option<(&UpgradeHeader, bool)> {
    match header {
        StreamHeader::Upgrade(upgrade) => Some((upgrade, false)),
        StreamHeader::Downgrade(upgrade) => Some((upgrade, true)),
        _ => None,
    }
}

/// Serves one upgrade stream. `owner` is whether the connection is the daemon's owner (a
/// paired device, not a guest), checked by the caller; `downgrade` whether the owner sent it
/// as an explicit downgrade.
pub(crate) async fn serve(
    core: Arc<Core>,
    actor: Actor,
    owner: bool,
    downgrade: bool,
    header: UpgradeHeader,
    mut send: SendStream,
    mut recv: RecvStream,
) {
    let result = if owner {
        install(&core, &header, downgrade, &mut send, &mut recv).await
    } else {
        core.mp.audit.append(
            AuditKind::Denied,
            crate::mp::AuditEntry {
                actor: Some(actor),
                detail: "refused a daemon upgrade: owner only".into(),
                ..crate::mp::AuditEntry::default()
            },
        );
        Err(fail(
            UpgradeFailure::Forbidden,
            "only the host's owner can update its helper",
        ))
    };
    let (reply, restart) = match result {
        Ok((info, exe, adopts)) => {
            tracing::info!(build = %info.build, protocol = info.protocol, "upgrade installed; restarting");
            (UpgradeReply::Installed(info), Some((exe, adopts)))
        }
        Err((code, message)) => {
            tracing::warn!(?code, "upgrade failed: {message}");
            let _ = recv.stop(0u32.into());
            (UpgradeReply::Failed { code, message }, None)
        }
    };
    let _ = net::send(&mut send, &reply).await;
    let _ = send.finish();
    // Let the answer reach the client before the restart closes the connection.
    let _ = tokio::time::timeout(Duration::from_secs(2), send.stopped()).await;
    if let Some((exe, adopts)) = restart {
        core.upgrade.request_restart(exe, adopts);
    }
}

/// Holds the one-upgrade-at-a-time flag; released on drop unless the upgrade went through
/// (the daemon is about to restart, so later attempts stay refused).
struct Busy<'a>(&'a AtomicBool);

impl<'a> Busy<'a> {
    fn acquire(flag: &'a AtomicBool) -> Option<Self> {
        (!flag.swap(true, Ordering::AcqRel)).then_some(Self(flag))
    }

    fn keep(self) {
        std::mem::forget(self);
    }
}

impl Drop for Busy<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

async fn install(
    core: &Arc<Core>,
    header: &UpgradeHeader,
    downgrade: bool,
    send: &mut SendStream,
    recv: &mut RecvStream,
) -> Result<(DaemonInfo, PathBuf, bool), Failure> {
    let exe = core.cfg.self_exe.clone().ok_or_else(|| {
        fail(
            UpgradeFailure::Unsupported,
            "this helper cannot replace itself; update it over SSH",
        )
    })?;
    if header.size == 0 || header.size > MAX_SIZE {
        return Err(fail(
            UpgradeFailure::Corrupt,
            format!("a build of {} bytes is not plausible", header.size),
        ));
    }
    let busy = Busy::acquire(&core.upgrade.busy)
        .ok_or_else(|| fail(UpgradeFailure::Busy, "an update is already running"))?;
    tracing::info!(
        build = %header.build,
        size = header.size,
        encoding = ?header.encoding,
        "receiving an upgrade"
    );
    let staged = Staged::create(&exe).map_err(|error| {
        fail(
            UpgradeFailure::Unsupported,
            format!("cannot write next to {}: {error}", exe.display()),
        )
    })?;
    net::send(send, &UpgradeReply::Ready)
        .await
        .map_err(|error| fail(UpgradeFailure::Io, error.to_string()))?;
    let staged = receive(staged, header, recv).await?;
    let (info, adopts) = check(&staged.path).await?;
    let running = crate::info::build_info(DaemonFeatures::EMPTY);
    if info.is_older_than(&running) {
        if !downgrade {
            return Err(fail(
                UpgradeFailure::Older,
                format!(
                    "{} is older than the running {}; downgrading needs an explicit request",
                    info.build, running.build
                ),
            ));
        }
        tracing::warn!(from = %running.build, to = %info.build, "owner downgrade");
    }
    let path = staged.path.clone();
    let target = exe.clone();
    tokio::task::spawn_blocking(move || swap(&path, &target))
        .await
        .map_err(|error| fail(UpgradeFailure::Io, error.to_string()))?
        .map_err(|error| {
            fail(
                UpgradeFailure::Io,
                format!("swapping in the new build: {error}"),
            )
        })?;
    staged.keep();
    busy.keep();
    Ok((info, exe, adopts))
}

/// The new build's file next to the executable; removed unless kept.
struct Staged {
    path: PathBuf,
    kept: bool,
}

impl Staged {
    fn create(exe: &Path) -> io::Result<(Self, File)> {
        let dir = exe.parent().unwrap_or(Path::new("."));
        let name = exe.file_name().map_or_else(
            || brand::DAEMON_BIN.to_owned(),
            |file_name| file_name.to_string_lossy().into_owned(),
        );
        let path = dir.join(format!(".{name}.upgrade-{}", std::process::id()));
        // A leftover of a crashed attempt goes; whatever else sits there is never followed.
        let _ = fs::remove_file(&path);
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o755)
            .open(&path)?;
        Ok((Self { path, kept: false }, file))
    }

    fn keep(mut self) {
        self.kept = true;
    }
}

impl Drop for Staged {
    fn drop(&mut self) {
        if !self.kept {
            let _ = fs::remove_file(&self.path);
        }
    }
}

/// A writer that hashes what passes through it.
struct Hashing<W> {
    inner: W,
    digest: ring::digest::Context,
    written: u64,
}

impl<W: Write> Write for Hashing<W> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let count = self.inner.write(bytes)?;
        self.digest.update(&bytes[..count]);
        self.written += count as u64;
        if self.written > MAX_SIZE {
            return Err(io::Error::other("the decoded build is too large"));
        }
        Ok(count)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

/// Reads exactly `header.size` bytes, decodes them into the staged file and checks the hash.
async fn receive(
    (staged, file): (Staged, File),
    header: &UpgradeHeader,
    recv: &mut RecvStream,
) -> Result<Staged, Failure> {
    let encoding = header.encoding;
    let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<u8>>(4);
    // Decoding and writing happen on a blocking thread fed through a small channel, so a slow
    // disk slows the stream (QUIC flow control) instead of buffering the build in memory.
    let writer = tokio::task::spawn_blocking(move || -> io::Result<(File, [u8; 32])> {
        let hashing = Hashing {
            inner: io::BufWriter::new(file),
            digest: ring::digest::Context::new(&ring::digest::SHA256),
            written: 0,
        };
        let finish = |hashed: Hashing<io::BufWriter<File>>| -> io::Result<(File, [u8; 32])> {
            let digest = hashed.digest.finish();
            let file = hashed
                .inner
                .into_inner()
                .map_err(io::IntoInnerError::into_error)?;
            let mut sha = [0u8; 32];
            sha.copy_from_slice(digest.as_ref());
            Ok((file, sha))
        };
        match encoding {
            UpgradeEncoding::Raw => {
                let mut writer = hashing;
                while let Some(chunk) = rx.blocking_recv() {
                    writer.write_all(&chunk)?;
                }
                finish(writer)
            }
            UpgradeEncoding::Gzip => {
                let mut decoder = flate2::write::GzDecoder::new(hashing);
                while let Some(chunk) = rx.blocking_recv() {
                    decoder.write_all(&chunk)?;
                }
                finish(decoder.finish()?)
            }
        }
    });
    let mut received: u64 = 0;
    let mut chunk = vec![0; 64 * 1024];
    let read = loop {
        match recv.read(&mut chunk).await {
            Ok(Some(len)) => {
                received += len as u64;
                if received > header.size {
                    break Err(fail(
                        UpgradeFailure::Corrupt,
                        format!("more than the announced {} bytes", header.size),
                    ));
                }
                if tx.send(chunk[..len].to_vec()).await.is_err() {
                    break Ok(());
                }
            }
            Ok(None) => break Ok(()),
            Err(error) => break Err(fail(UpgradeFailure::Io, format!("upgrade stream: {error}"))),
        }
    };
    drop(tx);
    let written = writer
        .await
        .map_err(|error| fail(UpgradeFailure::Io, error.to_string()))?;
    read?;
    if received != header.size {
        return Err(fail(
            UpgradeFailure::Corrupt,
            format!("the stream ended after {received} of {} bytes", header.size),
        ));
    }
    let (file, sha) = written.map_err(|error| {
        fail(
            UpgradeFailure::Corrupt,
            format!("decoding the build failed: {error}"),
        )
    })?;
    if sha != header.sha256 {
        return Err(fail(
            UpgradeFailure::Corrupt,
            "the build's SHA-256 does not match what was announced",
        ));
    }
    file.sync_all()
        .map_err(|error| fail(UpgradeFailure::Io, error.to_string()))?;
    Ok(staged)
}

/// Runs `<new> build-info --json`: the build must start on this host and report this OS and
/// CPU.
async fn check(path: &Path) -> Result<(DaemonInfo, bool), Failure> {
    let run = tokio::process::Command::new(path)
        .args(["build-info", "--json"])
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let output = tokio::time::timeout(CHECK_TIMEOUT, run)
        .await
        .map_err(|_| fail(UpgradeFailure::Rejected, "the new build did not answer"))?
        .map_err(|error| {
            fail(
                UpgradeFailure::Rejected,
                format!("the new build does not run on this host: {error}"),
            )
        })?;
    if !output.status.success() {
        return Err(fail(
            UpgradeFailure::Rejected,
            format!(
                "the new build failed its self-check ({}): {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        ));
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let line = text
        .lines()
        .rev()
        .find(|candidate| candidate.trim_start().starts_with('{'))
        .unwrap_or_default();
    let info: DaemonInfo = serde_json::from_str(line).map_err(|error| {
        fail(
            UpgradeFailure::Rejected,
            format!("the new build reported nonsense ({error})"),
        )
    })?;
    if info.os != std::env::consts::OS || info.arch != std::env::consts::ARCH {
        return Err(fail(
            UpgradeFailure::Rejected,
            format!(
                "the new build is for {} {}, this host is {} {}",
                info.os,
                info.arch,
                std::env::consts::OS,
                std::env::consts::ARCH
            ),
        ));
    }
    Ok((info, reads_handoff(line)))
}

/// Whether a `build-info --json` line says the build continues panes handed off in this
/// build's format (`"handoff": [versions]`; builds before hot upgrades report none).
fn reads_handoff(line: &str) -> bool {
    #[derive(serde::Deserialize)]
    struct Reads {
        #[serde(default)]
        handoff: Vec<u32>,
    }
    serde_json::from_str::<Reads>(line)
        .is_ok_and(|reads| reads.handoff.contains(&crate::handoff::HANDOFF_VERSION))
}

/// A local request to restart into the build installed at the daemon's own path, as the Mac
/// app sends after it updated itself (and `gudo-hostd restart`), over the hook socket.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RestartCall {
    pub restart: RestartAsk,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RestartAsk {
    /// The daemon's own hook token (`<state>/hook.token`), not a pane's.
    pub token: String,
}

/// The answer to a [`RestartCall`].
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RestartReply {
    /// The daemon hands its panes to the installed build and becomes it.
    Restarting,
    /// The daemon already runs the installed build.
    Current,
    /// Nothing changes, for this reason. A build that cannot continue running panes is
    /// refused too: restarting into it would end them.
    Refused(String),
}

/// Answers a local restart request; on [`RestartReply::Restarting`] the caller asks the host
/// process to restart once the answer is sent ([`after_restart_reply`]).
pub(crate) async fn serve_restart(core: &Arc<Core>, call: &RestartCall) -> RestartReply {
    if !core.hooks.is_daemon_token(&call.restart.token) {
        tracing::warn!("refused a restart request with a bad token");
        return RestartReply::Refused("not allowed".into());
    }
    let Some(exe) = core.cfg.exe.clone() else {
        return RestartReply::Refused("this daemon does not know its executable".into());
    };
    if core.upgrade.started_from.is_some() && core.upgrade.started_from == file_identity(&exe) {
        return RestartReply::Current;
    }
    let Some(busy) = Busy::acquire(&core.upgrade.busy) else {
        return RestartReply::Refused("an update is already running".into());
    };
    match check(&exe).await {
        Ok((info, true)) => {
            tracing::info!(build = %info.build, "restarting into the installed build");
            busy.keep();
            RestartReply::Restarting
        }
        Ok((info, false)) => RestartReply::Refused(format!(
            "the installed build {} cannot take over running sessions",
            info.build
        )),
        Err((_, message)) => RestartReply::Refused(message),
    }
}

/// After the [`RestartReply::Restarting`] answer went out: asks the host process to restart
/// into the installed build.
pub(crate) fn after_restart_reply(core: &Core, reply: &RestartReply) {
    if *reply == RestartReply::Restarting
        && let Some(exe) = core.cfg.exe.clone()
    {
        core.upgrade.request_restart(exe, true);
    }
}

/// Which file a path names now: device, inode, size and modification time.
pub(crate) fn file_identity(path: &Path) -> Option<(u64, u64, u64, i64)> {
    use std::os::unix::fs::MetadataExt;
    let metadata = fs::metadata(path).ok()?;
    Some((
        metadata.dev(),
        metadata.ino(),
        metadata.size(),
        metadata.mtime(),
    ))
}

/// Keeps the running executable as `<exe>.prev` and renames the new build over it.
fn swap(new: &Path, exe: &Path) -> io::Result<()> {
    let prev = prev_path(exe);
    let _ = fs::remove_file(&prev);
    if fs::hard_link(exe, &prev).is_err() {
        // Not fatal: a filesystem without hard links just keeps no fallback copy.
        let _ = fs::copy(exe, &prev);
    }
    fs::rename(new, exe)?;
    if let Some(dir) = exe.parent()
        && let Ok(dir_file) = File::open(dir)
    {
        let _ = dir_file.sync_all();
    }
    Ok(())
}

pub fn prev_path(exe: &Path) -> PathBuf {
    let mut name = exe.file_name().unwrap_or_default().to_os_string();
    name.push(".prev");
    exe.with_file_name(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prev_sits_next_to_the_executable() {
        assert_eq!(
            prev_path(Path::new("/home/u/.local/bin/gudo-hostd")),
            PathBuf::from("/home/u/.local/bin/gudo-hostd.prev")
        );
    }

    #[test]
    fn swap_keeps_the_old_build() {
        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("hostd");
        let new = dir.path().join(".hostd.upgrade-1");
        fs::write(&exe, b"old").unwrap();
        fs::write(&new, b"new").unwrap();
        swap(&new, &exe).unwrap();
        assert_eq!(fs::read(&exe).unwrap(), b"new");
        assert_eq!(fs::read(prev_path(&exe)).unwrap(), b"old");
        assert!(!new.exists());
    }
}
