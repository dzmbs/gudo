//! The wait thread: learns of the child's exit without reaping, then reaps under the lock that
//! [`PtyActor::signal`](super::PtyActor::signal) takes.

use std::io;
use std::os::unix::process::ExitStatusExt;
use std::process::{Child, ExitStatus};

use rustix::io::Errno;
use rustix::process::{WaitId, WaitIdOptions};

use super::Process;

/// What the wait thread reaps: a child this process spawned, or one it inherited across
/// `exec` from the process it replaced (same pid, so still its child).
pub(super) enum Reap {
    Spawned(Child),
    Adopted,
}

impl Reap {
    fn wait(self, pid: rustix::process::Pid) -> io::Result<ExitStatus> {
        match self {
            Self::Spawned(mut child) => child.wait(),
            Self::Adopted => loop {
                let mut status = 0;
                // SAFETY: waitpid writes the status through a valid pointer to a local.
                let reaped = unsafe { libc::waitpid(pid.as_raw_nonzero().get(), &mut status, 0) };
                if reaped != -1 {
                    break Ok(ExitStatus::from_raw(status));
                }
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    break Err(error);
                }
            },
        }
    }
}

pub(super) fn run(reap: Reap, process: &Process) {
    let exited = loop {
        // WNOWAIT leaves the zombie in place, so the pid cannot be recycled until we reap below.
        match rustix::process::waitid(
            WaitId::Pid(process.pid),
            WaitIdOptions::EXITED | WaitIdOptions::NOWAIT,
        ) {
            Ok(_) => break true,
            Err(Errno::INTR) => continue,
            Err(err) => {
                tracing::debug!(pid = process.pid.as_raw_nonzero(), %err, "waitid failed");
                break false;
            }
        }
    };

    // Only hold the lock across `wait` when we know it will not block; otherwise `signal` could
    // stall for the child's whole lifetime. Without WNOWAIT the kill/reap race guard is lost.
    let guard = exited.then(|| process.reaped());
    if process.handed_off() {
        // The process that replaces this one reaps it: the zombie keeps its pid reserved.
        drop(guard);
        loop {
            std::thread::park();
        }
    }
    let result = reap
        .wait(process.pid)
        .map_err(|err| err.raw_os_error().unwrap_or(libc::ECHILD));
    match guard {
        Some(mut reaped) => *reaped = true,
        None => *process.reaped() = true,
    }
    process.exit.send_replace(Some(result));
}
