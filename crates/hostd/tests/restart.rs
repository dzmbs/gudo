//! A real `gudo-hostd` upgraded while clients come and go restarts into the new build (the
//! same process) every time. Guards against SIGPIPE killing it mid-restart: `Command::exec`
//! resets SIGPIPE to its default before `execve`, while the runtime's threads still write to
//! sockets peers have just closed.

use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use client_core::{Client, ClientConfig, ClientEvent, DaemonBuild, EventQueue, RelayMode};

const HOSTD: &str = env!("CARGO_BIN_EXE_gudo-hostd");

fn config(key: &[u8]) -> ClientConfig {
    let mut config = ClientConfig::new(key.to_vec());
    config.relay = RelayMode::Disabled;
    config
}

/// The daemon, killed when the test ends however it ends.
struct Daemon(std::process::Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn pairing_ticket(exe: &Path, state: &Path) -> String {
    let output = Command::new(exe)
        .arg("--state-dir")
        .arg(state)
        .args(["pair", "--json", "--local", "--wait", "10"])
        .output()
        .unwrap();
    let paired: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    paired["ticket"].as_str().unwrap().to_owned()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn upgrades_restart_the_daemon_while_clients_reconnect() {
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("bin");
    std::fs::create_dir(&bin).unwrap();
    let exe = bin.join("gudo-hostd");
    std::fs::copy(HOSTD, &exe).unwrap();
    let state = dir.path().join("state");
    let mut daemon = Daemon(
        Command::new(&exe)
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
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    std::thread::sleep(Duration::from_secs(1));
    let ticket = pairing_ticket(&exe, &state);
    let key = ClientConfig::generate_key();
    let handle = tokio::runtime::Handle::current();
    let (listener, mut events) = EventQueue::channel();
    let owner = Client::connect_on(&handle, &ticket, config(&key), listener).unwrap();
    let connected = async |events: &mut tokio::sync::mpsc::UnboundedReceiver<ClientEvent>| {
        tokio::time::timeout(Duration::from_secs(30), async {
            while let Some(event) = events.recv().await {
                if matches!(event, ClientEvent::Connected { .. }) {
                    return;
                }
            }
        })
        .await
        .expect("the daemon answers (again)");
    };
    // Paired first: the ticket's secret is used once.
    connected(&mut events).await;

    // Other connections of the same device open and drop all along.
    let stop = Arc::new(AtomicBool::new(false));
    let churn: Vec<_> = (0..4)
        .map(|i| {
            let (handle, ticket, key, stop) = (
                handle.clone(),
                ticket.clone(),
                key.clone(),
                Arc::clone(&stop),
            );
            tokio::spawn(async move {
                while !stop.load(Ordering::Relaxed) {
                    let (listener, _events) = EventQueue::channel();
                    let client =
                        Client::connect_on(&handle, &ticket, config(&key), listener).unwrap();
                    client.attach(None);
                    tokio::time::sleep(Duration::from_millis(50 + 70 * i)).await;
                    drop(client);
                }
            })
        })
        .collect();
    for round in 1..=4 {
        let build = DaemonBuild::from_file(HOSTD, format!("round {round}")).unwrap();
        owner
            .upgrade_daemon(build, None)
            .await
            .unwrap_or_else(|error| panic!("round {round}: {error}"));
        connected(&mut events).await;
        let status = daemon.0.try_wait().unwrap();
        assert!(
            status.is_none(),
            "died restarting (round {round}): {status:?}"
        );
    }
    stop.store(true, Ordering::Relaxed);
    for task in churn {
        let _ = task.await;
    }
}
