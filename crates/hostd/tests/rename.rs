//! A host set up before the product's rename keeps working under the new name: started the
//! way the old service starts it (the old default state directory named explicitly), the
//! daemon moves that state to today's default and a device paired before still connects.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use client_core::{Client, ClientConfig, ClientEvent, EventQueue, RelayMode};

const HOSTD: &str = env!("CARGO_BIN_EXE_gudo-hostd");

/// The daemon, killed when the test ends however it ends.
struct Daemon(Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// A home of its own: XDG state and config roots under `root`.
fn hostd(exe: &Path, root: &Path) -> Command {
    let mut command = Command::new(exe);
    command
        .env("HOME", root.join("home"))
        .env("XDG_STATE_HOME", root.join("state"))
        .env("XDG_CONFIG_HOME", root.join("config"))
        .env_remove("GUDO_STATE_DIR")
        .env_remove("UN_STATE_DIR");
    command
}

fn start(exe: &Path, root: &Path, state: &Path, port: u16) -> Daemon {
    Daemon(
        hostd(exe, root)
            .arg("--state-dir")
            .arg(state)
            .args(["run", "--no-relay", "--shell", "/bin/sh", "--bind"])
            .arg(format!("127.0.0.1:{port}"))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    )
}

fn endpoint(state: &Path) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Ok(text) = std::fs::read_to_string(state.join("endpoint.json"))
            && let Ok(value) = serde_json::from_str(&text)
        {
            return value;
        }
        assert!(
            Instant::now() < deadline,
            "no endpoint in {}",
            state.display()
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

async fn connects(ticket: &str, key: &[u8]) {
    let mut config = ClientConfig::new(key.to_vec());
    config.relay = RelayMode::Disabled;
    let (listener, mut events) = EventQueue::channel();
    let handle = tokio::runtime::Handle::current();
    let _client = Client::connect_on(&handle, ticket, config, listener).unwrap();
    tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(event) = events.recv().await {
            if matches!(event, ClientEvent::Connected { .. }) {
                return;
            }
        }
    })
    .await
    .expect("the paired device connects");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_old_install_moves_to_the_new_name_and_keeps_its_devices() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let bin = root.join("bin");
    std::fs::create_dir(&bin).unwrap();
    let exe = bin.join(brand::DAEMON_BIN);
    std::fs::copy(HOSTD, &exe).unwrap();
    let port = std::net::UdpSocket::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();

    // The install before the rename: its state, a paired device, a global workflow.
    let old_state: PathBuf = root.join("state").join(brand::legacy::DIR_NAME);
    let scratch = root.join("scratch");
    let daemon = start(&exe, root, &scratch, port);
    let daemon_id = endpoint(&scratch)["daemon_id"].clone();
    let out = hostd(&exe, root)
        .arg("--state-dir")
        .arg(&scratch)
        .args(["pair", "--json", "--local", "--wait", "10"])
        .output()
        .unwrap();
    let paired: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let ticket = paired["ticket"].as_str().unwrap().to_owned();
    let key = ClientConfig::generate_key();
    connects(&ticket, &key).await;
    drop(daemon);
    std::fs::create_dir_all(old_state.parent().unwrap()).unwrap();
    std::fs::rename(&scratch, &old_state).unwrap();
    let old_config = root.join("config").join(brand::legacy::DIR_NAME);
    std::fs::create_dir_all(old_config.join("workflows")).unwrap();
    std::fs::write(old_config.join("workflows/build.yaml"), "name: build\n").unwrap();
    std::fs::write(bin.join(brand::legacy::DAEMON_BIN), "old build").unwrap();

    // Started as the old service starts it.
    let _daemon = start(&exe, root, &old_state, port);
    let new_state = root.join("state").join(brand::DIR_NAME);
    assert_eq!(
        endpoint(&new_state)["daemon_id"],
        daemon_id,
        "same identity"
    );
    assert!(!old_state.exists());
    let new_config = root.join("config").join(brand::DIR_NAME);
    assert!(new_config.join("workflows/build.yaml").exists());
    assert!(
        !bin.join(brand::legacy::DAEMON_BIN).exists(),
        "the old binary is gone"
    );
    connects(&ticket, &key).await;
}
