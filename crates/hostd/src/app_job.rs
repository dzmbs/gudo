//! The helper as a launchd job started on demand (`service start`, macOS): the Mac app starts
//! it, it runs until logout or `service stop`, and launchd starts it again after a crash.
//! Nothing starts it at login and nothing is left in `~/Library/LaunchAgents`: the property
//! list lives in the state directory only until launchd has loaded it.

use std::ffi::OsString;
use std::fs::{DirBuilder, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

use crate::service::xml_escape;

/// `service start` exits with this when launchd refused the job, so a caller can run the
/// helper some other way.
pub const LAUNCHD_REFUSED_EXIT: i32 = 3;

const START_LOCK: &str = "start.lock";
const LOG_DIRECTORY: &str = "logs";
const LOG_FILE: &str = "hostd.log";
/// A log over this size is kept as `hostd.log.1` when the job starts again.
const LOG_ROTATE_BYTES: u64 = 8 * 1024 * 1024;
const POLL_INTERVAL: Duration = Duration::from_millis(25);
const STOP_WAIT: Duration = Duration::from_secs(30);
/// A job just booted out can keep its label for a moment; bootstrapping tries again meanwhile.
const BOOTSTRAP_ATTEMPTS: u32 = 8;

/// launchd refused to load the job.
#[derive(Debug)]
pub struct LaunchdRefused(String);

impl std::fmt::Display for LaunchdRefused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "launchd refused the helper's job: {}", self.0)
    }
}

impl std::error::Error for LaunchdRefused {}

/// The helper serving a state directory, as `service start` found or started it.
#[derive(Debug, serde::Serialize)]
pub struct Started {
    pub label: String,
    /// False when a helper already ran there (started by anyone).
    pub started: bool,
    pub pid: u32,
    pub daemon_id: String,
    pub endpoint: daemon::EndpointInfo,
}

/// The job's label for a state directory: one job per directory, whichever build starts it.
pub fn job_label(canonical_state_dir: &Path) -> String {
    use std::os::unix::ffi::OsStrExt;
    let digest = ring::digest::digest(
        &ring::digest::SHA256,
        canonical_state_dir.as_os_str().as_bytes(),
    );
    let short: String = digest.as_ref()[..6]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    format!("{}.app.{short}", brand::SERVICE_LABEL)
}

/// The job's property list: `exe` runs `run` on the state directory with `run_arguments`.
/// No `RunAtLoad`: `KeepAlive` with `SuccessfulExit` false starts it once loaded, and again
/// whenever it ends with a failure or a signal, never after a clean stop.
pub fn job_plist(
    label: &str,
    exe: &Path,
    state_dir: &Path,
    run_arguments: &[OsString],
    log: &Path,
) -> String {
    let argument = |text: &str| format!("    <string>{}</string>\n", xml_escape(text));
    let mut arguments = String::new();
    arguments.push_str(&argument(&exe.to_string_lossy()));
    arguments.push_str(&argument("--state-dir"));
    arguments.push_str(&argument(&state_dir.to_string_lossy()));
    arguments.push_str(&argument("run"));
    for extra in run_arguments {
        arguments.push_str(&argument(&extra.to_string_lossy()));
    }
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key>
  <array>
{arguments}  </array>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>AbandonProcessGroup</key><true/>
  <key>WorkingDirectory</key><string>{state}</string>
  <key>StandardOutPath</key><string>{log}</string>
  <key>StandardErrorPath</key><string>{log}</string>
</dict>
</plist>
"#,
        label = xml_escape(label),
        state = xml_escape(&state_dir.to_string_lossy()),
        log = xml_escape(&log.to_string_lossy()),
    )
}

/// Returns the helper running on `state_dir`, or loads a job that runs `exe` there and waits
/// up to `timeout` for it to record its endpoint. Concurrent starts wait for each other.
///
/// # Errors
///
/// [`LaunchdRefused`] when launchd does not load the job; otherwise the helper did not come up
/// in time (the job is removed again) or the state directory cannot be used.
pub fn start(
    exe: &Path,
    state_dir: &Path,
    run_arguments: &[OsString],
    timeout: Duration,
) -> Result<Started> {
    let deadline = Instant::now() + timeout;
    create_private_dir(state_dir)?;
    let state_dir = state_dir
        .canonicalize()
        .with_context(|| format!("resolving {}", state_dir.display()))?;
    let _start_lock = lock_start(&state_dir)?;
    let label = job_label(&state_dir);
    if let Some(endpoint) = running_endpoint(&state_dir) {
        return Ok(Started::new(label, false, endpoint));
    }
    if crate::instance_locked(&state_dir) {
        // A helper is starting there (launchd restarting a crash, or anyone's `run`).
        let endpoint = wait_ready(&state_dir, deadline).with_context(|| {
            format!(
                "a helper holds {} but did not record its endpoint",
                state_dir.display()
            )
        })?;
        return Ok(Started::new(label, false, endpoint));
    }
    let log = prepare_log(&state_dir)?;
    let plist_path = state_dir.join(format!("{label}.plist"));
    write_private(
        &plist_path,
        job_plist(&label, exe, &state_dir, run_arguments, &log).as_bytes(),
    )?;
    let _ = launchctl(&["bootout", &service_target(&label)]);
    let loaded = bootstrap(&plist_path);
    let _ = std::fs::remove_file(&plist_path);
    loaded?;
    let Some(endpoint) = wait_ready(&state_dir, deadline) else {
        let _ = launchctl(&["bootout", &service_target(&label)]);
        bail!(
            "the helper did not start within {} s{}",
            timeout.as_secs(),
            last_log_line(&log)
                .map(|line| format!(": {line}"))
                .unwrap_or_default()
        );
    };
    match job_pid(&label) {
        Some(pid) if pid != endpoint.pid => {
            // Another helper took the folder first; this job could only fail to, again and
            // again.
            let _ = launchctl(&["bootout", &service_target(&label)]);
            Ok(Started::new(label, false, endpoint))
        }
        _ => Ok(Started::new(label, true, endpoint)),
    }
}

/// What [`stop`] did.
#[derive(Debug, PartialEq, Eq)]
pub enum Stopped {
    /// The job's helper ended (it saved its screens and layout first).
    Helper {
        pid: u32,
    },
    /// The job was loaded but ran nothing.
    Job,
    NotLoaded,
}

/// Stops the job [`start`] loads for `state_dir`: its helper gets SIGTERM and saves its
/// sessions, then launchd forgets the job. A helper started any other way is left running.
///
/// # Errors
///
/// The state directory cannot be resolved or locked.
pub fn stop(state_dir: &Path) -> Result<Stopped> {
    let Ok(state_dir) = state_dir.canonicalize() else {
        return Ok(Stopped::NotLoaded);
    };
    let _start_lock = lock_start(&state_dir)?;
    let label = job_label(&state_dir);
    let pid = job_pid(&label);
    if let Some(pid) = pid {
        // SAFETY: kill only sends a signal; the pid is the job's own, as launchd reports it.
        unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
        let deadline = Instant::now() + STOP_WAIT;
        while crate::pid_alive(pid) && Instant::now() < deadline {
            std::thread::sleep(POLL_INTERVAL);
        }
    }
    let unloaded = launchctl(&["bootout", &service_target(&label)]).is_ok();
    Ok(match (pid, unloaded) {
        (Some(pid), _) => Stopped::Helper { pid },
        (None, true) => Stopped::Job,
        (None, false) => Stopped::NotLoaded,
    })
}

impl Started {
    fn new(label: String, started: bool, endpoint: daemon::EndpointInfo) -> Self {
        Self {
            label,
            started,
            pid: endpoint.pid,
            daemon_id: endpoint.daemon_id.clone(),
            endpoint,
        }
    }
}

fn running_endpoint(state_dir: &Path) -> Option<daemon::EndpointInfo> {
    daemon::endpoint_info(state_dir)
        .ok()
        .flatten()
        .filter(|info| crate::daemon_running(state_dir, info))
}

fn wait_ready(state_dir: &Path, deadline: Instant) -> Option<daemon::EndpointInfo> {
    loop {
        if let Some(endpoint) = running_endpoint(state_dir) {
            return Some(endpoint);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(POLL_INTERVAL);
    }
}

fn create_private_dir(path: &Path) -> Result<()> {
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .with_context(|| format!("creating {}", path.display()))
}

fn write_private(path: &Path, contents: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .with_context(|| format!("writing {}", path.display()))?;
    file.write_all(contents)?;
    Ok(())
}

/// Held while one start or stop runs, so two never load the same job at once.
fn lock_start(state_dir: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(state_dir.join(START_LOCK))
        .context("opening the start lock")?;
    rustix::fs::flock(&file, rustix::fs::FlockOperation::LockExclusive)
        .context("taking the start lock")?;
    Ok(file)
}

/// The job's log in the state directory, the previous one kept aside once it grows large.
fn prepare_log(state_dir: &Path) -> Result<PathBuf> {
    let directory = state_dir.join(LOG_DIRECTORY);
    create_private_dir(&directory)?;
    let log = directory.join(LOG_FILE);
    if std::fs::metadata(&log).is_ok_and(|metadata| metadata.len() > LOG_ROTATE_BYTES) {
        let _ = std::fs::rename(&log, directory.join(format!("{LOG_FILE}.1")));
    }
    if !log.exists() {
        write_private(&log, b"")?;
    }
    Ok(log)
}

fn last_log_line(log: &Path) -> Option<String> {
    let text = std::fs::read_to_string(log).ok()?;
    text.lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .map(str::to_owned)
}

fn gui_domain() -> String {
    // SAFETY: getuid never fails.
    format!("gui/{}", unsafe { libc::getuid() })
}

fn service_target(label: &str) -> String {
    format!("{}/{label}", gui_domain())
}

fn launchctl(arguments: &[&str]) -> Result<Output> {
    let output = Command::new("/bin/launchctl")
        .args(arguments)
        .output()
        .context("running launchctl")?;
    if !output.status.success() {
        bail!(
            "launchctl {} failed ({}): {}",
            arguments.first().copied().unwrap_or_default(),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(output)
}

fn bootstrap(plist: &Path) -> Result<()> {
    let domain = gui_domain();
    let plist = plist.to_string_lossy();
    let mut last_error = None;
    for attempt in 0..BOOTSTRAP_ATTEMPTS {
        if attempt > 0 {
            std::thread::sleep(Duration::from_millis(100));
        }
        match launchctl(&["bootstrap", &domain, &plist]) {
            Ok(_) => return Ok(()),
            Err(error) => last_error = Some(error),
        }
    }
    Err(LaunchdRefused(last_error.map_or_else(String::new, |error| error.to_string())).into())
}

/// The process launchd runs for the job, if it is loaded and running.
fn job_pid(label: &str) -> Option<u32> {
    let output = launchctl(&["print", &service_target(label)]).ok()?;
    parse_job_pid(&String::from_utf8_lossy(&output.stdout))
}

/// The `pid = N` line of `launchctl print` (the job's own, not a nested section's).
fn parse_job_pid(printed: &str) -> Option<u32> {
    printed
        .lines()
        .filter(|line| line.starts_with('\t') && !line.starts_with("\t\t"))
        .find_map(|line| line.trim().strip_prefix("pid = "))
        .and_then(|pid| pid.trim().parse().ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_label_follows_the_state_directory() {
        let label = job_label(Path::new("/tmp/a"));
        assert!(label.starts_with(&format!("{}.app.", brand::SERVICE_LABEL)));
        assert_eq!(label.len(), brand::SERVICE_LABEL.len() + ".app.".len() + 12);
        assert_eq!(label, job_label(Path::new("/tmp/a")));
        assert_ne!(label, job_label(Path::new("/tmp/b")));
    }

    #[test]
    fn the_plist_runs_the_helper_on_its_folder_and_restarts_only_failures() {
        let plist = job_plist(
            "dev.gudo.hostd.app.0123456789ab",
            Path::new("/Users/a&b/Versions/Current/gudo-hostd"),
            Path::new("/state <dir>"),
            &["--no-relay".into()],
            Path::new("/state <dir>/logs/hostd.log"),
        );
        assert!(plist.contains(
            "    <string>/Users/a&amp;b/Versions/Current/gudo-hostd</string>\n    \
             <string>--state-dir</string>\n    <string>/state &lt;dir&gt;</string>\n    \
             <string>run</string>\n    <string>--no-relay</string>\n"
        ));
        assert!(
            plist.contains("<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>")
        );
        assert!(plist.contains("<key>AbandonProcessGroup</key><true/>"));
        assert!(plist.contains("<key>ProcessType</key><string>Interactive</string>"));
        assert!(!plist.contains("RunAtLoad"));
        assert!(plist.contains("<string>/state &lt;dir&gt;/logs/hostd.log</string>"));
    }

    #[test]
    fn the_jobs_own_pid_is_read_from_launchctl() {
        let printed = "gui/501/x = {\n\tactive count = 1\n\tpath = /tmp/x.plist\n\t\
                       state = running\n\n\tprogram = /bin/sleep\n\tpid = 4242\n\t\
                       endpoints = {\n\t\tpid = 7\n\t}\n}\n";
        assert_eq!(parse_job_pid(printed), Some(4242));
        assert_eq!(
            parse_job_pid("gui/501/x = {\n\tstate = not running\n}\n"),
            None
        );
    }
}
