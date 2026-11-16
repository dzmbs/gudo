//! A daemon whose log cannot be written (a full disk under its log file, a closed pipe) keeps
//! running: losing a log line must never take the panes down.

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const HOSTD: &str = env!("CARGO_BIN_EXE_gudo-hostd");

/// A log written to a file or the journal has no terminal colour codes in it.
#[test]
fn a_log_that_is_not_a_terminal_is_plain_text() {
    use std::io::Read as _;
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("hostd.log");
    let mut daemon = Command::new(HOSTD)
        .env("HOME", dir.path())
        .env("CLAUDE_CONFIG_DIR", dir.path().join(".claude"))
        .env("CODEX_HOME", dir.path().join(".codex"))
        .arg("--state-dir")
        .arg(dir.path().join("state"))
        .args([
            "run",
            "--no-relay",
            "--bind",
            "127.0.0.1:0",
            "--shell",
            "/bin/sh",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(std::fs::File::create(&log_path).unwrap())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut log = String::new();
    while !log.contains("INFO") && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(100));
        log.clear();
        std::fs::File::open(&log_path)
            .unwrap()
            .read_to_string(&mut log)
            .unwrap();
    }
    let _ = daemon.kill();
    let _ = daemon.wait();
    assert!(log.contains("INFO"), "{log}");
    assert!(!log.contains('\u{1b}'), "{log:?}");
}

/// Started without a service manager, the daemon writes its own log file, where it can
/// keep it small, instead of whatever its stderr is.
#[test]
fn a_log_file_takes_the_whole_log() {
    use std::io::Read as _;
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("hostd.log");
    let mut daemon = Command::new(HOSTD)
        .env("HOME", dir.path())
        .env("CLAUDE_CONFIG_DIR", dir.path().join(".claude"))
        .env("CODEX_HOME", dir.path().join(".codex"))
        .arg("--state-dir")
        .arg(dir.path().join("state"))
        .args([
            "run",
            "--no-relay",
            "--bind",
            "127.0.0.1:0",
            "--shell",
            "/bin/sh",
            "--log-file",
        ])
        .arg(&log_path)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut log = String::new();
    while !log.contains("serving as") && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(100));
        log = std::fs::read_to_string(&log_path).unwrap_or_default();
    }
    let _ = daemon.kill();
    let _ = daemon.wait();
    let mut elsewhere = String::new();
    daemon
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut elsewhere)
        .unwrap();
    assert!(log.contains("INFO") && log.contains("serving as"), "{log}");
    assert_eq!(elsewhere, "");
}

#[test]
fn an_unwritable_log_does_not_stop_the_daemon() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let mut daemon = Command::new(HOSTD)
        .env("HOME", dir.path())
        .env("CLAUDE_CONFIG_DIR", dir.path().join(".claude"))
        .env("CODEX_HOME", dir.path().join(".codex"))
        .arg("--state-dir")
        .arg(&state)
        .args([
            "run",
            "--no-relay",
            "--bind",
            "127.0.0.1:0",
            "--shell",
            "/bin/sh",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    drop(daemon.stderr.take());

    let deadline = Instant::now() + Duration::from_secs(20);
    while !state.join("endpoint.json").exists() && Instant::now() < deadline {
        if let Some(status) = daemon.try_wait().unwrap() {
            panic!("the daemon exited with {status} when its log broke");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    std::thread::sleep(Duration::from_secs(1));
    let exited = daemon.try_wait().unwrap();
    let _ = daemon.kill();
    let _ = daemon.wait();
    assert!(
        exited.is_none(),
        "the daemon exited with {exited:?} when its log broke"
    );
}
