//! Identifying the foreground job of a PTY, so the agents layer can tell `claude` from `zsh`.
//!
//! Adapted from herdr's `platform/{macos,linux}.rs` foreground-job code (Apache-2.0,

use std::os::fd::AsFd;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;

#[cfg(target_os = "linux")]
use linux as imp;
#[cfg(target_os = "macos")]
use macos as imp;

/// The leader of the PTY's foreground process group.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ForegroundProcess {
    /// Process id of the group leader, which is also the process group id.
    pub pid: u32,
    /// Kernel short name (`comm`; on macOS the longer `p_name` when available). For script
    /// runtimes this is often the interpreter, e.g. `node`.
    pub name: String,
    /// Full argument vector, empty if it could not be read (exited, or not ours to inspect).
    /// `argv[0]` reflects runtime title changes such as Node's `process.title`.
    pub argv: Vec<String>,
}

impl ForegroundProcess {
    /// Returns the basename of `argv[0]` with any login-shell `-` stripped, falling back to
    /// [`name`](Self::name).
    ///
    /// # Examples
    ///
    /// ```
    /// let p = pty::ForegroundProcess {
    ///     pid: 1,
    ///     name: "node".into(),
    ///     argv: vec!["/usr/local/bin/claude".into(), "--resume".into()],
    /// };
    /// assert_eq!(p.program(), "claude");
    /// ```
    pub fn program(&self) -> &str {
        self.argv
            .first()
            .and_then(|argv0| argv0.rsplit('/').next())
            .map(|base| base.strip_prefix('-').unwrap_or(base))
            .filter(|base| !base.is_empty())
            .unwrap_or(&self.name)
    }
}

/// Looks up the foreground process group of the terminal behind `master`, falling back to the
/// terminal's foreground group as seen from `session_leader` when `tcgetpgrp` on the master is
/// not supported.
pub(crate) fn foreground_process(
    master: impl AsFd,
    session_leader: u32,
) -> Option<ForegroundProcess> {
    let pgid = match rustix::termios::tcgetpgrp(master) {
        Ok(pid) => pid.as_raw_nonzero().get() as u32,
        Err(_) => imp::terminal_pgid_of(session_leader)?,
    };
    let name = imp::process_name(pgid)?;
    Some(ForegroundProcess {
        pid: pgid,
        name,
        argv: imp::process_argv(pgid).unwrap_or_default(),
    })
}

#[cfg(test)]
mod tests {
    use std::process::Command;
    use std::time::Duration;

    use crate::spawn::spawn;
    use crate::termios::WinSize;

    /// `tcgetpgrp` works on the master itself, so the `e_tpgid`/`tpgid` fallback is a fallback.
    #[test]
    fn tcgetpgrp_on_master_names_the_session_leader() {
        let mut spawned = spawn(Command::new("/bin/cat"), WinSize::new(24, 80)).unwrap();
        let pid = spawned.child.id();
        // The child is the foreground group once it has run setsid + TIOCSCTTY.
        let mut pgid = None;
        for _ in 0..200 {
            pgid = rustix::termios::tcgetpgrp(&spawned.master)
                .ok()
                .map(|p| p.as_raw_nonzero().get() as u32);
            if pgid == Some(pid) {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(pgid, Some(pid));
        assert_eq!(super::imp::terminal_pgid_of(pid), Some(pid));
        spawned.child.kill().unwrap();
        spawned.child.wait().unwrap();
    }
}
