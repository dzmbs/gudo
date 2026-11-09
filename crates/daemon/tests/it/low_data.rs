//! Low Data Mode: a device on a constrained link is sent only what it shows.

use std::time::{Duration, Instant};

use client_core::ClientConfig;
use proto::LinkClass;

use crate::support::{self, TestClient};

/// Pumps events for `duration`.
async fn pump(client: &mut TestClient, duration: Duration) {
    let end = Instant::now() + duration;
    client
        .until("time to pass", |_| Instant::now() >= end)
        .await;
}

struct HiddenFlood {
    snapshots: u32,
    bytes: u32,
    client: TestClient,
    _daemon: daemon::Daemon,
    _state_dir: tempfile::TempDir,
}

/// Follows a pane printing without pause, then hides it: counts the snapshots and byte frames
/// that arrive for it while hidden.
async fn hidden_flood(link: LinkClass) -> HiddenFlood {
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start(dir.path()).await;
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = client_core::RelayMode::Disabled;
    config.link = link;
    let mut client = TestClient::connect_with(
        &support::ticket(&daemon),
        config,
        client_core::ConnectOptions::default(),
    );
    let pane = client.attach_and_follow().await;
    client.type_line(pane, "yes");
    client
        .until("output", |client| client.byte_events > 20)
        .await;

    client.client.set_view(None, vec![]);
    pump(&mut client, Duration::from_millis(500)).await;
    let (snapshots, bytes) = (client.snapshot_events, client.byte_events);
    pump(&mut client, Duration::from_millis(1500)).await;
    HiddenFlood {
        snapshots: client.snapshot_events - snapshots,
        bytes: client.byte_events - bytes,
        client,
        _daemon: daemon,
        _state_dir: dir,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_hidden_pane_keeps_streaming_on_a_normal_link() {
    let flood = hidden_flood(LinkClass::Normal).await;
    assert!(
        flood.bytes > 0,
        "a hidden pane streams while the link allows it"
    );
    flood
        .client
        .client
        .send_input(flood.client.focused(), vec![3]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_hidden_pane_costs_nothing_on_a_constrained_link_until_it_is_shown() {
    let mut flood = hidden_flood(LinkClass::Constrained).await;
    assert_eq!(
        (flood.snapshots, flood.bytes),
        (0, 0),
        "nothing for a pane the device does not show"
    );
    let client = &mut flood.client;

    let pane = client.focused();
    let shown_at = Instant::now();
    let before = client.snapshot_events;
    client.client.set_view(Some(pane), vec![pane]);
    client
        .until("a fresh screen", |client| client.snapshot_events > before)
        .await;
    assert!(
        shown_at.elapsed() < Duration::from_millis(500),
        "shown again after {:?}",
        shown_at.elapsed()
    );
    client.client.send_input(pane, vec![3]);
}
