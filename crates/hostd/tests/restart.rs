//! A real `unnamed-hostd` upgraded while clients come and go restarts into the new build (the
//! same process) every time. It used to die of SIGPIPE half of the time: `Command::exec`
//! resets SIGPIPE to its default before `execve`, while the runtime's threads still write to
//! sockets peers have just closed.

use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use client_core::{Client, ClientConfig, ClientEvent, DaemonBuild, EventQueue, RelayMode};

const HOSTD: &str = env!("CARGO_BIN_EXE_unnamed-hostd");

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
    let out = Command::new(exe)
        .arg("--state-dir")
        .arg(state)
        .args(["pair", "--json", "--local", "--wait", "10"])
        .output()
        .unwrap();
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    v["ticket"].as_str().unwrap().to_owned()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn upgrades_restart_the_daemon_while_clients_reconnect() {
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("bin");
    std::fs::create_dir(&bin).unwrap();
    let exe = bin.join("unnamed-hostd");
    std::fs::copy(HOSTD, &exe).unwrap();
    let state = dir.path().join("state");
    let mut daemon = Daemon(
        Command::new(&exe)
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
            while let Some(e) = events.recv().await {
                if matches!(e, ClientEvent::Connected { .. }) {
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
                    let c = Client::connect_on(&handle, &ticket, config(&key), listener).unwrap();
                    c.attach(None);
                    tokio::time::sleep(Duration::from_millis(50 + 70 * i)).await;
                    drop(c);
                }
            })
        })
        .collect();
    for round in 1..=4 {
        let build = DaemonBuild::from_file(HOSTD, format!("round {round}")).unwrap();
        owner
            .upgrade_daemon(build, None)
            .await
            .unwrap_or_else(|e| panic!("round {round}: {e}"));
        connected(&mut events).await;
        let status = daemon.0.try_wait().unwrap();
        assert!(
            status.is_none(),
            "died restarting (round {round}): {status:?}"
        );
    }
    stop.store(true, Ordering::Relaxed);
    for c in churn {
        let _ = c.await;
    }
}
