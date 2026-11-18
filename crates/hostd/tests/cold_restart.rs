//! `restart` of a helper that cannot hand its sessions over. A test binary of its own: the
//! build check has a deadline, which the busy hand-off tests running alongside could make it
//! miss.

use std::path::{Path, PathBuf};
use std::process::{Child, Command};

const HOSTD: &str = env!("CARGO_BIN_EXE_gudo-hostd");

fn restart_into_command(exe: &Path, state: &Path, into: &Path) -> std::process::Output {
    Command::new(exe)
        .arg("--state-dir")
        .arg(state)
        .arg("restart")
        .arg("--into")
        .arg(into)
        .output()
        .unwrap()
}

/// A helper that cannot hand over: it holds the state directory and gives `answer` (nothing,
/// as builds before hot hand-off) to a restart request; its process is the one a cold restart
/// would stop.
struct PreHandOffHelper {
    process: Child,
    _lock: std::fs::File,
    _socket: std::os::unix::net::UnixListener,
}

impl Drop for PreHandOffHelper {
    fn drop(&mut self) {
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}

impl PreHandOffHelper {
    fn start(state: &Path) -> Self {
        Self::answering(state, "")
    }

    fn answering(state: &Path, answer: &'static str) -> Self {
        std::fs::create_dir_all(state).unwrap();
        let lock = std::fs::File::create(state.join("hostd.lock")).unwrap();
        rustix::fs::flock(&lock, rustix::fs::FlockOperation::LockExclusive).unwrap();
        let socket_path = state.join("hook.sock");
        let socket = std::os::unix::net::UnixListener::bind(&socket_path).unwrap();
        let answers = socket.try_clone().unwrap();
        std::thread::spawn(move || {
            for connection in answers.incoming().flatten() {
                let mut request = String::new();
                let _ = std::io::BufRead::read_line(
                    &mut std::io::BufReader::new(&connection),
                    &mut request,
                );
                let _ = std::io::Write::write_all(&mut &connection, answer.as_bytes());
            }
        });
        std::fs::write(
            state.join("hook.endpoint"),
            socket_path.as_os_str().as_encoded_bytes(),
        )
        .unwrap();
        std::fs::write(state.join("hook.token"), "token").unwrap();
        let process = Command::new("/bin/sleep").arg("600").spawn().unwrap();
        let endpoint = serde_json::json!({
            "daemon_id": "00", "addrs": [], "relay_url": null,
            "pid": process.id(), "started_at": 1u64,
        });
        std::fs::write(state.join("endpoint.json"), endpoint.to_string()).unwrap();
        Self {
            process,
            _lock: lock,
            _socket: socket,
        }
    }

    fn is_running(&mut self) -> bool {
        self.process.try_wait().unwrap().is_none()
    }
}

fn fake_build(dir: &Path, name: &str, info: &serde_json::Value) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join(name);
    let script =
        format!("#!/bin/sh\nif [ \"$1\" = build-info ]; then echo '{info}'; exit 0; fi\nexit 3\n");
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// A helper that cannot hand over is restarted cold, and that restart passes the same checks
/// as a hand-off: never onto an older build, nor onto one that does not run here.
#[test]
fn a_cold_restart_refuses_an_older_or_foreign_build() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let mut helper = PreHandOffHelper::start(&state);
    let older = fake_build(
        dir.path(),
        "older",
        &serde_json::json!({
            "version": "0.1.0", "build": "older", "built_unix": 1_700_000_000u64,
            "protocol": 0, "min_client_protocol": 0, "features": 0, "hostname": "test",
            "os": std::env::consts::OS, "arch": std::env::consts::ARCH, "os_name": "",
        }),
    );
    let output = restart_into_command(Path::new(HOSTD), &state, &older);
    assert!(!output.status.success(), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("older than"),
        "{output:?}"
    );
    assert!(helper.is_running(), "the running helper was stopped");

    let foreign = fake_build(
        dir.path(),
        "foreign",
        &serde_json::json!({
            "version": "9.9.9", "build": "foreign", "built_unix": 4_000_000_000u64,
            "protocol": 999, "min_client_protocol": 0, "features": 0, "hostname": "test",
            "os": "plan9", "arch": std::env::consts::ARCH, "os_name": "",
        }),
    );
    let output = restart_into_command(Path::new(HOSTD), &state, &foreign);
    assert!(!output.status.success(), "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("plan9"),
        "{output:?}"
    );
    assert!(helper.is_running(), "the running helper was stopped");
}

fn hot_only_restart_command(state: &Path) -> std::process::Output {
    Command::new(HOSTD)
        .arg("--state-dir")
        .arg(state)
        .args(["restart", "--hot-only"])
        .output()
        .unwrap()
}

/// `--hot-only` never ends running commands: a helper that could only be restarted cold, from
/// before hot hand-off or refusing for live Chat, is left alone, and the command says so with
/// an exit status of its own.
#[test]
fn a_hot_only_restart_leaves_a_helper_that_cannot_hand_over_alone() {
    let refused_for_live_chat =
        "{\"refused\":\"Live agent Chat cannot survive a helper restart yet.\"}\n";
    for answer in ["", refused_for_live_chat] {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let mut helper = PreHandOffHelper::answering(&state, answer);
        let output = hot_only_restart_command(&state);
        assert_eq!(output.status.code(), Some(3), "{answer}: {output:?}");
        assert!(
            String::from_utf8_lossy(&output.stderr).contains("only a cold restart"),
            "{output:?}"
        );
        assert!(
            helper.is_running(),
            "{answer}: the running helper was stopped"
        );
    }
}
