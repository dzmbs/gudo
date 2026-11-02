//! Process limits: enough file descriptors for many panes, and a pane cap that keeps some in
//! reserve so connections, state files and git keep working when the panes have taken the rest.

use std::sync::OnceLock;

use rustix::process::{Resource, Rlimit, getrlimit, setrlimit};

/// Descriptors a pane holds: the PTY master and the I/O thread's wake pipe.
const FDS_PER_PANE: u64 = 3;
/// Descriptors kept free for everything that is not a pane.
const RESERVE: u64 = 256;

/// The soft limit the daemon started with; pane processes get it back.
static INHERITED: OnceLock<Rlimit> = OnceLock::new();

/// Raises the soft descriptor limit as far as the system allows. A LaunchAgent starts with 256
/// and systemd with 1024, which would cap a host at a few dozen or a few hundred panes.
pub(crate) fn raise_fd_limit() {
    let current = getrlimit(Resource::Nofile);
    let _ = INHERITED.set(current);
    let mut candidates = vec![current.maximum];
    if cfg!(target_os = "macos") {
        // macOS refuses an unlimited soft limit; this is the most one process may open.
        candidates.push(sysctl_max_files_per_proc());
        candidates.push(Some(10_240));
    }
    for want in candidates.into_iter().flatten() {
        if current.current.is_some_and(|c| c >= want) {
            return;
        }
        let raised = Rlimit {
            current: Some(want),
            maximum: current.maximum,
        };
        if setrlimit(Resource::Nofile, raised).is_ok() {
            tracing::debug!(limit = want, "raised the descriptor limit");
            return;
        }
    }
}

/// Puts the inherited descriptor limit back, between `fork` and `exec` of a pane's process,
/// so programs that assume small descriptor numbers (`select`) behave as in any terminal.
pub(crate) fn restore_for_child() -> std::io::Result<()> {
    if let Some(limit) = INHERITED.get() {
        // `setrlimit` is a plain syscall: async-signal-safe.
        setrlimit(Resource::Nofile, *limit)?;
    }
    Ok(())
}

/// Most panes the descriptor limit leaves room for.
pub(crate) fn max_panes() -> usize {
    let limit = getrlimit(Resource::Nofile).current.unwrap_or(u64::MAX);
    (limit.saturating_sub(RESERVE) / FDS_PER_PANE) as usize
}

#[cfg(target_os = "macos")]
fn sysctl_max_files_per_proc() -> Option<u64> {
    let mut value: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>();
    // SAFETY: the name is a NUL-terminated string and `value`/`len` describe a c_int buffer.
    let rc = unsafe {
        libc::sysctlbyname(
            c"kern.maxfilesperproc".as_ptr(),
            (&raw mut value).cast(),
            &raw mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    (rc == 0 && value > 0).then_some(value as u64)
}

#[cfg(not(target_os = "macos"))]
fn sysctl_max_files_per_proc() -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Started with launchd's soft limit of 256, the daemon could open about 80 panes.
    #[test]
    fn a_low_soft_limit_is_raised() {
        let hard = getrlimit(Resource::Nofile).maximum;
        if hard.is_some_and(|h| h <= 1024) {
            return;
        }
        let low = Rlimit {
            current: Some(256),
            maximum: hard,
        };
        setrlimit(Resource::Nofile, low).unwrap();
        raise_fd_limit();
        let now = getrlimit(Resource::Nofile).current.unwrap_or(u64::MAX);
        assert!(now > 1024, "soft limit still {now}");
        assert!(max_panes() > 300);
    }
}
