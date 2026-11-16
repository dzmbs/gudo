//! A daemon whose log cannot be written (a full disk under its log file, a closed pipe) keeps
//! running: losing a log line must never take the panes down.

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const HOSTD: &str = env!("CARGO_BIN_EXE_gudo-hostd");

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
