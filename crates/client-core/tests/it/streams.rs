//! Pane streams under load: what the client follows, it gets; what it stops following stays
//! stopped.

use std::time::Duration;

use client_core::ClientEvent;

use super::{connect, daemon, next_matching};

/// Output already in flight when a flooding pane is unsubscribed must not bring the stream
/// back: the client asked for nothing more, so nothing more (no snapshot, no bytes) comes.
#[tokio::test(flavor = "multi_thread")]
async fn unsubscribing_a_flooding_pane_stops_its_stream() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let ticket = daemon
        .pairing_ticket(daemon::PAIRING_TTL)
        .unwrap()
        .to_string();
    let (client, mut events) = connect(&ticket, false);
    client.attach(None);
    let ClientEvent::Layout { layout } =
        next_matching(&mut events, |e| matches!(e, ClientEvent::Layout { .. })).await
    else {
        unreachable!()
    };
    let pane = layout.tabs[0].focused;
    client.subscribe(pane);
    next_matching(&mut events, |e| {
        matches!(e, ClientEvent::PaneSnapshot { .. })
    })
    .await;
    client.send_input(pane, b"yes\r".to_vec());
    let mut flooded = 0;
    next_matching(&mut events, |e| {
        if let ClientEvent::PaneBytes { data, .. } = e {
            flooded += data.len();
        }
        flooded > 4 << 20
    })
    .await;

    client.unsubscribe(pane);
    // What was in flight drains; then the pane is quiet for good.
    tokio::time::sleep(Duration::from_millis(500)).await;
    while events.try_recv().is_ok() {}
    let settled = client.stats();
    tokio::time::sleep(Duration::from_secs(2)).await;
    let mut late = 0;
    while let Ok(e) = events.try_recv() {
        if matches!(
            e,
            ClientEvent::PaneBytes { pane_id, .. } | ClientEvent::PaneSnapshot { pane_id, .. }
                if pane_id == pane
        ) {
            late += 1;
        }
    }
    let now = client.stats();
    assert_eq!(late, 0, "events for an unsubscribed pane");
    assert_eq!(
        now.snapshots, settled.snapshots,
        "the stream was not resubscribed"
    );
    assert_eq!(
        now.byte_frames, settled.byte_frames,
        "no bytes after it settled"
    );
    drop(client);
    daemon.shutdown().await;
}
