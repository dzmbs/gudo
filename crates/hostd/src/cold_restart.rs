//! Updating a running helper that refuses to hand its sessions over: 0.1.5 and 0.1.6 refuse
//! while an agent has live Chat. Rather than leave the user on that build, the helper is
//! stopped the usual way (it saves the layout, screens and agent sessions) and the build now at
//! its path is started, which resumes every agent in its pane.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

/// What those builds answer a restart or an upgrade while an agent has live Chat.
pub const REFUSED_FOR_LIVE_CHAT: &str = "Live agent Chat cannot survive a helper restart yet.";

const STOP_WAIT: Duration = Duration::from_secs(30);
const START_WAIT: Duration = Duration::from_secs(60);
const POLL: Duration = Duration::from_millis(100);

/// What keeps the helper running, and so starts it again.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Supervisor {
    /// A launchd job: its label.
    Launchd(String),
    /// A systemd user unit.
    Systemd,
    /// Nothing: a helper started by hand or by a test, started again here.
    None(Vec<OsString>),
}

impl Supervisor {
    // A helper started from a terminal inherits that terminal's launchd label or systemd
    // invocation, so each is trusted only when the job or unit really is this helper.
    fn of(pid: u32) -> Result<Self> {
        if let Some(label) = daemon::process_env_var(pid, "XPC_SERVICE_NAME")
            && is_launchd_job(&label, pid)
        {
            return Ok(Self::Launchd(label));
        }
        if runs_in_systemd_unit(pid) {
            return Ok(Self::Systemd);
        }
        let arguments = daemon::process_arguments(pid)
            .filter(|arguments| !arguments.is_empty())
            .context("reading the running helper's command line")?;
        Ok(Self::None(arguments))
    }
}

fn is_launchd_job(label: &str, pid: u32) -> bool {
    if label.is_empty() || label == "0" || !cfg!(target_os = "macos") {
        return false;
    }
    let target = format!("gui/{}/{label}", rustix::process::getuid().as_raw());
    Command::new("launchctl")
        .args(["print", &target])
        .stderr(Stdio::null())
        .output()
        .is_ok_and(|output| {
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .any(|line| line.trim() == format!("pid = {pid}"))
        })
}

fn runs_in_systemd_unit(pid: u32) -> bool {
    let unit = format!("/{}.service", brand::DAEMON_BIN);
    std::fs::read_to_string(format!("/proc/{pid}/cgroup")).is_ok_and(|groups| {
        groups
            .lines()
            .any(|group| group.trim_end().ends_with(&unit))
    })
}

/// Stops the helper `pid` (serving `state_dir`, started at `started_at`), lets what supervises
/// it start the build at `exe` in its place, and waits until that build serves.
pub fn restart(state_dir: &Path, pid: u32, started_at: u64, exe: &Path) -> Result<()> {
    match Supervisor::of(pid)? {
        Supervisor::Launchd(label) => {
            let target = format!("gui/{}/{label}", rustix::process::getuid().as_raw());
            run(Command::new("launchctl").args(["kickstart", "-k", &target]))?;
        }
        Supervisor::Systemd => {
            let unit = format!("{}.service", brand::DAEMON_BIN);
            run(Command::new("systemctl").args(["--user", "restart", &unit]))?;
        }
        Supervisor::None(arguments) => {
            stop(pid)?;
            start(exe, &arguments[1..])?;
        }
    }
    wait_for_start(state_dir, started_at)
}

fn run(command: &mut Command) -> Result<()> {
    let status = command
        .status()
        .with_context(|| format!("running {command:?}"))?;
    if !status.success() {
        bail!("{command:?} failed: {status}");
    }
    Ok(())
}

fn stop(pid: u32) -> Result<()> {
    let process = rustix::process::Pid::from_raw(i32::try_from(pid)?)
        .context("the running helper has no valid pid")?;
    rustix::process::kill_process(process, rustix::process::Signal::TERM)
        .context("stopping the running helper")?;
    let deadline = Instant::now() + STOP_WAIT;
    while rustix::process::test_kill_process(process).is_ok() {
        if Instant::now() > deadline {
            bail!(
                "the running helper did not stop within {} s",
                STOP_WAIT.as_secs()
            );
        }
        std::thread::sleep(POLL);
    }
    Ok(())
}

/// Starts `exe` with `arguments` on its own, outliving this command.
fn start(exe: &Path, arguments: &[OsString]) -> Result<()> {
    use std::os::unix::process::CommandExt;
    Command::new(exe)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .with_context(|| format!("starting {}", exe.display()))?;
    Ok(())
}

fn wait_for_start(state_dir: &Path, started_at: u64) -> Result<()> {
    let deadline = Instant::now() + START_WAIT;
    while Instant::now() < deadline {
        if daemon::endpoint_info(state_dir)
            .ok()
            .flatten()
            .is_some_and(|info| info.started_at > started_at && crate::pid_alive(info.pid))
        {
            return Ok(());
        }
        std::thread::sleep(POLL);
    }
    bail!(
        "the helper did not start again within {} s",
        START_WAIT.as_secs()
    )
}

/// The executable the helper `pid` runs from: where the update put the new build.
pub fn executable_of(pid: u32) -> Option<PathBuf> {
    let program = daemon::process_arguments(pid)?.into_iter().next()?;
    let program = PathBuf::from(program);
    program.is_absolute().then_some(program)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_helper_started_by_hand_is_started_again_with_its_arguments() {
        // A label inherited from the terminal it was started in names some other job.
        let mut child = Command::new("/bin/sleep")
            .arg("30")
            .env("XPC_SERVICE_NAME", "application.example.terminal.1")
            .env("INVOCATION_ID", "0123456789abcdef")
            .spawn()
            .unwrap();
        let supervisor = Supervisor::of(child.id());
        let _ = child.kill();
        let _ = child.wait();
        assert_eq!(
            supervisor.unwrap(),
            Supervisor::None(vec!["/bin/sleep".into(), "30".into()])
        );
    }
}
