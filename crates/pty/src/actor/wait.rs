//! The wait thread: learns of the child's exit without reaping, then reaps under the lock that
//! [`PtyActor::signal`](super::PtyActor::signal) takes.

use std::process::Child;

use rustix::io::Errno;
use rustix::process::{WaitId, WaitIdOptions};

use super::Process;

pub(super) fn run(mut child: Child, process: &Process) {
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
    let result = child
        .wait()
        .map_err(|err| err.raw_os_error().unwrap_or(libc::ECHILD));
    match guard {
        Some(mut reaped) => *reaped = true,
        None => *process.reaped() = true,
    }
    process.exit.send_replace(Some(result));
}
