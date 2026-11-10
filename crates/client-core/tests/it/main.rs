//! client-core against a real daemon (relays off, loopback), and against an SSH host.

mod liveness;
mod offline;
mod outage;
mod panes;
mod queue;
mod recovery;
mod redial;
mod ssh_host;
mod streams;
mod upgrade_only;

use std::time::Duration;

use client_core::proto::{PairingSecret, Ticket};
use client_core::{Client, ClientConfig, ClientError, ClientEvent, EventQueue, RelayMode};
use tokio::sync::mpsc::UnboundedReceiver;

async fn daemon(dir: &std::path::Path) -> daemon::Daemon {
    let mut config = daemon::Config::new(dir);
    config.relay = daemon::RelayMode::Disabled;
    config.bind = Some("127.0.0.1:0".parse().unwrap());
    config.shell = Some("/bin/sh".into());
    daemon::Daemon::start(config).await.unwrap()
}

/// A daemon that goes down and comes back on the same address with the same identity, as a
/// host that drops off the network or restarts.
struct Host {
    daemon: Option<daemon::Daemon>,
    address: std::net::SocketAddr,
    state: std::path::PathBuf,
    home: std::path::PathBuf,
    _dirs: (tempfile::TempDir, tempfile::TempDir),
}

impl Host {
    async fn start() -> Self {
        let state_dir = tempfile::tempdir().unwrap();
        let home_dir = tempfile::tempdir().unwrap();
        let state = state_dir.path().canonicalize().unwrap();
        let home = home_dir.path().canonicalize().unwrap();
        let unbound = "127.0.0.1:0".parse().unwrap();
        let daemon = Self::start_daemon(&state, &home, unbound).await;
        let address = daemon
            .bound_sockets()
            .into_iter()
            .find(std::net::SocketAddr::is_ipv4)
            .expect("an IPv4 socket");
        Self {
            daemon: Some(daemon),
            address,
            state,
            home,
            _dirs: (state_dir, home_dir),
        }
    }

    async fn start_daemon(
        state: &std::path::Path,
        home: &std::path::Path,
        address: std::net::SocketAddr,
    ) -> daemon::Daemon {
        let mut config = daemon::Config::new(state);
        config.relay = daemon::RelayMode::Disabled;
        config.bind = Some(address);
        config.shell = Some("/bin/sh".into());
        config.pane_env = vec![
            ("PS1".into(), "$ ".into()),
            ("ENV".into(), String::new()),
            ("HOME".into(), home.to_string_lossy().into_owned()),
        ];
        config.fs_allow.push(home.to_path_buf());
        daemon::Daemon::start(config).await.unwrap()
    }

    fn ticket(&self) -> String {
        self.daemon
            .as_ref()
            .expect("the host is up")
            .pairing_ticket(daemon::PAIRING_TTL)
            .unwrap()
            .to_string()
    }

    async fn go_down(&mut self) {
        if let Some(daemon) = self.daemon.take() {
            daemon.shutdown().await;
        }
    }

    async fn come_back(&mut self) {
        assert!(self.daemon.is_none(), "the host is already up");
        self.daemon = Some(Self::start_daemon(&self.state, &self.home, self.address).await);
    }

    fn write_target(&self, name: &str) -> client_core::proto::WriteTarget {
        client_core::proto::WriteTarget {
            path: self.home.join(name).to_string_lossy().into_owned(),
            if_match: None,
            create_new: false,
            mkdirs: true,
            mode: None,
        }
    }
}

fn connect(ticket: &str, mirror_vt: bool) -> (Client, UnboundedReceiver<ClientEvent>) {
    let (listener, events) = EventQueue::channel();
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Disabled;
    config.mirror_vt = mirror_vt;
    (Client::connect(ticket, config, listener).unwrap(), events)
}

async fn next_matching(
    events: &mut UnboundedReceiver<ClientEvent>,
    mut predicate: impl FnMut(&ClientEvent) -> bool,
) -> ClientEvent {
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            let event = events.recv().await.expect("client alive");
            if predicate(&event) {
                return event;
            }
        }
    })
    .await
    .expect("event in time")
}

#[test]
fn rejects_bad_input_up_front() {
    let (listener, _events) = EventQueue::channel();
    assert!(matches!(
        Client::connect(
            "not a ticket",
            ClientConfig::new(vec![0; 32]),
            listener.clone()
        ),
        Err(ClientError::Ticket(_))
    ));
    let ticket = Ticket {
        v: Ticket::VERSION,
        daemon_id: client_core::proto::DaemonId([1; 32]),
        addrs: vec![],
        relay_url: None,
        principal: client_core::proto::PrincipalId([2; 16]),
        secret: PairingSecret([3; 16]),
        expires: client_core::proto::UnixMillis(0),
    };
    assert!(matches!(
        Client::connect(&ticket.to_string(), ClientConfig::new(vec![0; 3]), listener),
        Err(ClientError::Key)
    ));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_wrong_secret_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut ticket = daemon.pairing_ticket(daemon::PAIRING_TTL).unwrap();
    ticket.secret = PairingSecret([0xab; 16]);
    let (_client, mut events) = connect(&ticket.to_string(), true);
    next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Refused { .. })
    })
    .await;
    assert_eq!(daemon.paired_devices(), 0);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_ticket_pairs_only_one_device() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let ticket = daemon
        .pairing_ticket(daemon::PAIRING_TTL)
        .unwrap()
        .to_string();
    let (_a, mut a_events) = connect(&ticket, true);
    next_matching(&mut a_events, |event| {
        matches!(event, ClientEvent::Connected { .. })
    })
    .await;
    let (_b, mut b_events) = connect(&ticket, true);
    next_matching(&mut b_events, |event| {
        matches!(event, ClientEvent::Refused { .. })
    })
    .await;
    assert_eq!(daemon.paired_devices(), 1);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn without_a_mirror_bytes_and_snapshots_still_flow() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let ticket = daemon
        .pairing_ticket(daemon::PAIRING_TTL)
        .unwrap()
        .to_string();
    let (client, mut events) = connect(&ticket, false);
    client.attach(None);
    let ClientEvent::Layout { layout } = next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Layout { .. })
    })
    .await
    else {
        unreachable!()
    };
    let pane = layout.tabs[0].focused;
    client.subscribe(pane);
    let ClientEvent::PaneSnapshot { data, .. } = next_matching(&mut events, |event| {
        matches!(event, ClientEvent::PaneSnapshot { .. })
    })
    .await
    else {
        unreachable!()
    };
    assert!(
        data.starts_with(b"GHOSTSNP"),
        "decompressed Ghostty snapshot"
    );
    client.send_input(pane, b"echo x$((7*6))\r".to_vec());
    let mut seen = Vec::new();
    next_matching(&mut events, |event| {
        if let ClientEvent::PaneBytes { data, .. } = event {
            seen.extend_from_slice(data);
        }
        seen.windows(3).any(|window| window == b"x42")
    })
    .await;
    assert!(client.pane_text(pane).is_none(), "no mirror kept");
    assert!(client.pane_seq(pane).is_some(), "but the resume point is");
    drop(client);
    daemon.shutdown().await;
}
