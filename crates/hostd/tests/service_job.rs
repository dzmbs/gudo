//! `service start` and `service stop` against the real launchd of this login session: each test
//! has its own state directory, so its own job label, and removes its job however it ends.
#![cfg(target_os = "macos")]

use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{Duration, Instant};

use serde_json::Value;

const HOSTD: &str = env!("CARGO_BIN_EXE_gudo-hostd");

/// A state directory whose launchd job is stopped and removed when the test ends.
struct Job {
    _dir: tempfile::TempDir,
    exe: PathBuf,
    state: PathBuf,
    labels: std::sync::Mutex<Vec<String>>,
}

impl Job {
    /// None when this session has no GUI launchd domain (a headless runner).
    fn new() -> Option<Self> {
        if !launchctl(&["print", &gui_domain()]).status.success() {
            eprintln!("skipped: no launchd GUI domain for this user");
            return None;
        }
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        let exe = bin.join("gudo-hostd");
        std::fs::copy(HOSTD, &exe).unwrap();
        let state = dir.path().join("state");
        Some(Self {
            _dir: dir,
            exe,
            state,
            labels: std::sync::Mutex::default(),
        })
    }

    fn hostd(&self, arguments: &[&str]) -> Output {
        Command::new(&self.exe)
            .arg("--state-dir")
            .arg(&self.state)
            .args(arguments)
            .output()
            .unwrap()
    }

    fn start(&self) -> Value {
        let output = self.hostd(&[
            "service",
            "start",
            "--json",
            "--timeout",
            "30",
            "--no-relay",
            "--bind",
            "127.0.0.1:0",
            "--shell",
            "/bin/sh",
        ]);
        assert!(
            output.status.success(),
            "service start: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let started: Value = serde_json::from_slice(&output.stdout).unwrap();
        self.labels
            .lock()
            .unwrap()
            .push(started["label"].as_str().unwrap().to_owned());
        started
    }

    fn stop(&self) -> String {
        let output = self.hostd(&["service", "stop"]);
        assert!(output.status.success());
        String::from_utf8_lossy(&output.stdout).trim().to_owned()
    }

    fn endpoint_pid(&self) -> Option<u32> {
        let text = std::fs::read(self.state.join("endpoint.json")).ok()?;
        let endpoint: Value = serde_json::from_slice(&text).ok()?;
        endpoint["pid"].as_u64().map(|pid| pid as u32)
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        let _ = self.hostd(&["service", "stop"]);
        for label in self.labels.lock().unwrap().iter() {
            let _ = launchctl(&["bootout", &format!("{}/{label}", gui_domain())]);
        }
        if let Some(pid) = self.endpoint_pid() {
            signal(pid, libc::SIGKILL);
        }
    }
}

fn gui_domain() -> String {
    // SAFETY: getuid never fails.
    format!("gui/{}", unsafe { libc::getuid() })
}

fn launchctl(arguments: &[&str]) -> Output {
    Command::new("/bin/launchctl")
        .args(arguments)
        .output()
        .unwrap()
}

fn is_loaded(label: &str) -> bool {
    launchctl(&["print", &format!("{}/{label}", gui_domain())])
        .status
        .success()
}

fn alive(pid: u32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn signal(pid: u32, signal: libc::c_int) {
    // SAFETY: kill only sends a signal to the test's own helper.
    unsafe { libc::kill(pid as libc::pid_t, signal) };
}

fn wait_until(limit: Duration, mut condition: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        if condition() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    condition()
}

fn pid(started: &Value) -> u32 {
    started["pid"].as_u64().unwrap() as u32
}

#[test]
fn a_second_start_finds_the_running_helper_and_stop_ends_it() {
    let Some(job) = Job::new() else { return };
    let first = job.start();
    assert_eq!(first["started"], true);
    let label = first["label"].as_str().unwrap();
    assert!(is_loaded(label));
    assert_eq!(
        first["daemon_id"], first["endpoint"]["daemon_id"],
        "{first}"
    );
    let state = job.state.canonicalize().unwrap();
    assert!(
        !state.join(format!("{label}.plist")).exists(),
        "the property list goes once launchd has it"
    );

    let second = job.start();
    assert_eq!(second["started"], false);
    assert_eq!(pid(&second), pid(&first));

    assert_eq!(job.stop(), format!("stopped (pid {})", pid(&first)));
    assert!(!alive(pid(&first)));
    assert!(!is_loaded(label));
    let log = std::fs::read_to_string(state.join("logs/hostd.log")).unwrap();
    assert!(
        log.contains("shutting down"),
        "a clean stop, which saves the sessions: {log}"
    );
    assert_eq!(job.stop(), "not running as a job");
}

#[test]
fn launchd_starts_a_crashed_helper_again() {
    let Some(job) = Job::new() else { return };
    let crashed = pid(&job.start());
    signal(crashed, libc::SIGKILL);
    assert!(
        wait_until(Duration::from_secs(40), || {
            job.endpoint_pid()
                .is_some_and(|pid| pid != crashed && alive(pid))
        }),
        "launchd started the helper again"
    );
    let found = job.start();
    assert_eq!(found["started"], false, "{found}");
    assert_ne!(pid(&found), crashed);
}

#[test]
fn a_job_whose_helper_stopped_is_replaced() {
    let Some(job) = Job::new() else { return };
    let started = job.start();
    let first = pid(&started);
    // A clean exit: launchd keeps the job loaded and does not start it again.
    signal(first, libc::SIGTERM);
    assert!(wait_until(Duration::from_secs(20), || !alive(first)));
    assert!(is_loaded(started["label"].as_str().unwrap()));

    let again = job.start();
    assert_eq!(again["started"], true, "{again}");
    assert_ne!(pid(&again), first);
    assert!(alive(pid(&again)));
}

#[test]
fn concurrent_starts_share_one_helper() {
    let Some(job) = Job::new() else { return };
    let results: Vec<Value> = std::thread::scope(|scope| {
        let starts: Vec<_> = (0..4).map(|_| scope.spawn(|| job.start())).collect();
        starts
            .into_iter()
            .map(|start| start.join().unwrap())
            .collect()
    });
    let first = pid(&results[0]);
    assert!(
        results.iter().all(|result| pid(result) == first),
        "{results:?}"
    );
    assert_eq!(
        results
            .iter()
            .filter(|result| result["started"] == true)
            .count(),
        1,
        "{results:?}"
    );
}

#[test]
fn stop_leaves_a_helper_it_did_not_start() {
    let Some(job) = Job::new() else { return };
    std::fs::create_dir_all(&job.state).unwrap();
    let mut daemon = Command::new(&job.exe)
        .arg("--state-dir")
        .arg(&job.state)
        .args([
            "run",
            "--no-relay",
            "--bind",
            "127.0.0.1:0",
            "--shell",
            "/bin/sh",
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let pid = daemon.id();
    assert!(wait_until(Duration::from_secs(20), || job.endpoint_pid() == Some(pid)));

    let found = job.start();
    assert_eq!(found["started"], false);
    assert_eq!(self::pid(&found), pid);
    assert_eq!(job.stop(), "not running as a job");
    assert!(alive(pid));
    let _ = daemon.kill();
    let _ = daemon.wait();
}
