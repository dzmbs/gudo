//! client-core against a real daemon (relays off, loopback), and against an SSH host.

mod liveness;
mod redial;
mod ssh_host;
mod streams;

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
