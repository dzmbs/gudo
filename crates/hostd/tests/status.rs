//! `status` and `pair` tell a running daemon from a stale `endpoint.json` whose process id
//! now belongs to something else, as after a reboot: only a daemon holds the state
//! directory's instance lock.

use std::path::Path;
use std::process::{Child, Command, Stdio};

const HOSTD: &str = env!("CARGO_BIN_EXE_gudo-hostd");

/// A live process of this user that is not a daemon.
struct Bystander(Child);

impl Bystander {
    fn start() -> Self {
        Self(
            Command::new("sleep")
                .arg("60")
                .stdin(Stdio::null())
                .spawn()
                .unwrap(),
        )
    }
}

impl Drop for Bystander {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn record_endpoint(state: &Path, pid: u32) {
    let endpoint = serde_json::json!({
        "daemon_id": "00".repeat(32),
        "addrs": ["127.0.0.1:4433"],
        "relay_url": null,
        "pid": pid,
        "started_at": 1,
    });
    std::fs::write(state.join("endpoint.json"), endpoint.to_string()).unwrap();
}

fn status_line(state: &Path) -> String {
    let output = Command::new(HOSTD)
        .arg("--state-dir")
        .arg(state)
        .arg("status")
        .output()
        .unwrap();
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .next()
        .unwrap_or_default()
        .to_owned()
}

#[test]
fn a_reused_process_id_is_not_a_running_daemon() {
    let state = tempfile::tempdir().unwrap();
    let bystander = Bystander::start();
    record_endpoint(state.path(), bystander.0.id());

    let line = status_line(state.path());
    assert!(line.starts_with("not running"), "status said {line:?}");

    let started = std::time::Instant::now();
    let pair = Command::new(HOSTD)
        .arg("--state-dir")
        .arg(state.path())
        .args(["pair", "--json", "--wait", "1"])
        .output()
        .unwrap();
    assert!(
        !pair.status.success(),
        "pair minted a ticket for a daemon that is not running: {}",
        String::from_utf8_lossy(&pair.stdout)
    );
    assert!(started.elapsed() >= std::time::Duration::from_secs(1));
}

#[test]
fn a_daemon_holding_the_instance_lock_is_running() {
    let state = tempfile::tempdir().unwrap();
    let bystander = Bystander::start();
    record_endpoint(state.path(), bystander.0.id());
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(state.path().join("hostd.lock"))
        .unwrap();
    rustix::fs::flock(&lock, rustix::fs::FlockOperation::NonBlockingLockExclusive).unwrap();

    let line = status_line(state.path());
    assert!(line.starts_with("running"), "status said {line:?}");
}
