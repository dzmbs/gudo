//! The launch-owned Codex app-server's process group and private directory.

use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use rustix::process::{Pid, Signal, WaitId, WaitIdOptions};

#[cfg(test)]
mod tests;

const EXIT_WAIT: Duration = Duration::from_secs(2);
const EXIT_POLL: Duration = Duration::from_millis(20);
/// Names the daemon that made the directory, so a later daemon can tell what is left over.
/// A file, not part of the name: socket paths inside must stay within the platform's limit.
const OWNER_FILE: &str = "daemon.pid";
const MAX_OWNER_BYTES: u64 = 16;

/// Where this daemon keeps one launch's sockets.
pub(super) fn create_directory() -> std::io::Result<PathBuf> {
    let directory = crate::fsutil::create_private_temp_dir(&directory_prefix())?;
    if let Err(error) = std::fs::write(directory.join(OWNER_FILE), std::process::id().to_string()) {
        let _ = std::fs::remove_dir_all(&directory);
        return Err(error);
    }
    Ok(directory)
}

fn directory_prefix() -> String {
    format!("{}-codex", brand::DIR_NAME)
}

/// Spawns the app-server as the leader of its own process group, so teardown reaches the
/// tools it started.
pub(super) fn isolate(command: &mut tokio::process::Command) {
    command.process_group(0);
    #[cfg(target_os = "linux")]
    {
        // SAFETY: runs between fork and exec and only calls `prctl`, which is
        // async-signal-safe. The forking thread is a runtime worker that lives as long as the
        // daemon, so the signal fires only when the daemon itself is gone.
        unsafe {
            command.pre_exec(|| {
                rustix::process::set_parent_process_death_signal(Some(Signal::KILL))
                    .map_err(std::io::Error::from)
            });
        }
    }
}

/// Asks the app-server's group to stop, then kills whatever is left, and only then reaps the
/// leader: until it is reaped its id cannot name another process group.
pub(super) async fn terminate(mut process: tokio::process::Child) {
    let Some(group) = process.id().and_then(group_of) else {
        return;
    };
    stop_group(group).await;
    let _ = tokio::time::timeout(EXIT_WAIT, process.wait()).await;
}

/// Stops the group `leader` leads, leaving the leader unreaped.
async fn stop_group(leader: Pid) {
    let _ = rustix::process::kill_process_group(leader, Signal::TERM);
    let deadline = tokio::time::Instant::now() + EXIT_WAIT;
    while !has_exited(leader) && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(EXIT_POLL).await;
    }
    let _ = rustix::process::kill_process_group(leader, Signal::KILL);
}

/// Whether `leader` exited, without reaping it.
fn has_exited(leader: Pid) -> bool {
    rustix::process::waitid(
        WaitId::Pid(leader),
        WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT,
    )
    .map_or(true, |status| status.is_some())
}

/// Teardown without an async context: the group is killed at once.
pub(super) fn kill(process: &tokio::process::Child) {
    if let Some(group) = process.id().and_then(group_of) {
        let _ = rustix::process::kill_process_group(group, Signal::KILL);
    }
}

fn group_of(pid: u32) -> Option<Pid> {
    i32::try_from(pid).ok().and_then(Pid::from_raw)
}

/// Removes launch directories left by daemons of this user that are no longer running.
pub(crate) fn sweep_stale_directories(started: SystemTime) {
    sweep(&std::env::temp_dir(), &directory_prefix(), started);
}

fn sweep(parent: &Path, prefix: &str, started: SystemTime) {
    let Ok(entries) = std::fs::read_dir(parent) else {
        return;
    };
    let user = rustix::process::geteuid().as_raw();
    for entry in entries.flatten() {
        let named = entry
            .file_name()
            .to_str()
            .and_then(|name| name.strip_prefix(prefix))
            .is_some_and(|rest| rest.starts_with('-'));
        if !named {
            continue;
        }
        let Ok(metadata) = std::fs::symlink_metadata(entry.path()) else {
            continue;
        };
        let older = metadata.modified().is_ok_and(|modified| modified < started);
        if !metadata.is_dir() || metadata.uid() != user || !older {
            continue;
        }
        let Some(owner) = owner(&entry.path()) else {
            continue;
        };
        if owner != std::process::id() && !is_running(owner) {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

fn owner(directory: &Path) -> Option<u32> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(directory.join(OWNER_FILE))
        .ok()?;
    let mut text = String::new();
    file.take(MAX_OWNER_BYTES).read_to_string(&mut text).ok()?;
    text.trim().parse().ok()
}

fn is_running(pid: u32) -> bool {
    group_of(pid)
        .is_none_or(|pid| rustix::process::test_kill_process(pid) != Err(rustix::io::Errno::SRCH))
}
