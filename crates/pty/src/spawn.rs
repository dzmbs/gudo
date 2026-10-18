//! Opening a PTY pair and starting a child as session leader on it.
//!
//! The approach (`/dev/ptmx` + `std::process::Command` with a `pre_exec` doing `setsid` and
//! `TIOCSCTTY`) matches what `portable-pty`, used by herdr (Apache-2.0), does on Unix, without
//! its trait objects and Windows layer.

use std::ffi::CString;
use std::io;
use std::os::fd::{BorrowedFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};

use rustix::fs::{Mode, OFlags};
use rustix::pty;

use crate::termios::{self, WinSize};

pub(crate) struct Spawned {
    pub(crate) master: OwnedFd,
    pub(crate) child: Child,
}

/// Opens a PTY of `size` and spawns `cmd` on it as a new session whose controlling terminal is
/// the PTY. Only the master fd stays open in the parent.
pub(crate) fn spawn(mut cmd: Command, size: WinSize) -> io::Result<Spawned> {
    let master = open_master()?;
    let slave_name = pty::ptsname(&master, Vec::new())?;
    let slave = open_slave(&slave_name)?;
    termios::set_size(&slave, size)?;

    cmd.stdin(Stdio::from(slave.try_clone()?))
        .stdout(Stdio::from(slave.try_clone()?))
        .stderr(Stdio::from(slave));
    // SAFETY: the closure runs between fork and exec, so it may only make async-signal-safe
    // calls. `setsid` and `ioctl` are plain syscalls, and the error conversion does not
    // allocate.
    unsafe {
        cmd.pre_exec(|| {
            rustix::process::setsid()?;
            // stdin is already the slave (std dup2'd it before running this closure).
            rustix::process::ioctl_tiocsctty(BorrowedFd::borrow_raw(0))?;
            Ok(())
        });
    }
    let child = cmd.spawn()?;
    // `cmd` owns the parent's copies of the slave fds; dropping it here (it was moved in) closes
    // them so the master sees EOF once the child side is gone.
    drop(cmd);
    Ok(Spawned { master, child })
}

fn open_master() -> io::Result<OwnedFd> {
    let master = open_ptmx()?;
    pty::grantpt(&master)?;
    pty::unlockpt(&master)?;
    Ok(master)
}

/// Opens the clone device directly rather than through `posix_openpt`, which takes no
/// `O_CLOEXEC` on macOS.
#[cfg(target_os = "linux")]
fn open_ptmx() -> rustix::io::Result<OwnedFd> {
    rustix::fs::open(
        c"/dev/ptmx",
        OFlags::RDWR | OFlags::NOCTTY | OFlags::CLOEXEC,
        Mode::empty(),
    )
}

/// Opens the clone device directly rather than through `posix_openpt`, which takes no
/// `O_CLOEXEC` on macOS.
///
/// xnu's internal "re-drive the open" code for clone devices (`EREDRIVEOPEN`, -6) leaks out of
/// `open("/dev/ptmx")` when several threads allocate PTYs at once (`posix_openpt` too). A retry
/// succeeds.
#[cfg(target_os = "macos")]
fn open_ptmx() -> rustix::io::Result<OwnedFd> {
    const EREDRIVEOPEN: i32 = -6;
    const ATTEMPTS: usize = 100;
    let open = || {
        rustix::fs::open(
            c"/dev/ptmx",
            OFlags::RDWR | OFlags::NOCTTY | OFlags::CLOEXEC,
            Mode::empty(),
        )
    };
    for _ in 1..ATTEMPTS {
        match open() {
            Err(err) if err.raw_os_error() == EREDRIVEOPEN => std::thread::yield_now(),
            result => return result,
        }
    }
    open()
}

fn open_slave(name: &CString) -> io::Result<OwnedFd> {
    Ok(rustix::fs::open(
        name.as_c_str(),
        OFlags::RDWR | OFlags::NOCTTY | OFlags::CLOEXEC,
        Mode::empty(),
    )?)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Many threads spawning at once: each fork briefly copies every other thread's open slave.
    #[test]
    fn concurrent_spawns() {
        let handles: Vec<_> = (0..32)
            .map(|_| {
                std::thread::spawn(|| {
                    for _ in 0..10 {
                        let mut spawned =
                            spawn(Command::new("/usr/bin/true"), WinSize::new(24, 80))
                                .map_err(|err| format!("{err:?}"))?;
                        spawned.child.wait().map_err(|err| format!("{err:?}"))?;
                    }
                    Ok::<_, String>(())
                })
            })
            .collect();
        let errors: Vec<_> = handles
            .into_iter()
            .filter_map(|handle| handle.join().unwrap().err())
            .collect();
        assert!(errors.is_empty(), "{errors:?}");
    }
}
