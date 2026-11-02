//! Pane streams under load: what the client follows, it gets; what it stops following stays
//! stopped; a flooding pane does not starve the others.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use client_core::proto::{Axis, LayoutOp, OpOutcome, PaneId, PaneLaunch};
use client_core::{Client, ClientConfig, ClientEvent, ClientListener, RelayMode};
use tokio::sync::mpsc;

use super::{connect, daemon, next_matching};

/// Takes as long over each output frame as the app's terminal does (about 16 MB/s), and
/// notes when a probe byte shows up in the probe pane.
struct SlowTerminal {
    tx: mpsc::UnboundedSender<ClientEvent>,
    probe: Mutex<Option<(PaneId, u8, Instant)>>,
    echoes: Mutex<Vec<Duration>>,
}

impl ClientListener for SlowTerminal {
    fn on_event(&self, event: ClientEvent) {
        if let ClientEvent::PaneBytes { pane_id, data, .. } = &event {
            let mut probe = self.probe.lock().unwrap();
            if let Some((pane, byte, sent)) = *probe
                && pane == *pane_id
                && data.contains(&byte)
            {
                self.echoes.lock().unwrap().push(sent.elapsed());
                *probe = None;
            }
            drop(probe);
            let busy = Duration::from_micros(data.len() as u64 / 16);
            let start = Instant::now();
            while start.elapsed() < busy {
                std::hint::spin_loop();
            }
            return;
        }
        let _ = self.tx.send(event);
    }
}

/// Two panes flood into a client whose runtime has two workers (the app's) while a third
/// pane echoes keystrokes: each keystroke's echo arrives promptly, not after the floods.
#[tokio::test(flavor = "multi_thread")]
async fn a_flood_does_not_starve_another_panes_echo() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let ticket = daemon
        .pairing_ticket(daemon::PAIRING_TTL)
        .unwrap()
        .to_string();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let (tx, mut events) = mpsc::unbounded_channel();
    let listener = Arc::new(SlowTerminal {
        tx,
        probe: Mutex::new(None),
        echoes: Mutex::new(Vec::new()),
    });
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = RelayMode::Disabled;
    let client = Client::connect_on(runtime.handle(), &ticket, config, listener.clone()).unwrap();
    client.attach(None);
    let ClientEvent::Layout { layout } = next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Layout { .. })
    })
    .await
    else {
        unreachable!()
    };
    let mut panes = vec![layout.tabs[0].focused];
    for _ in 0..2 {
        let op = client.op(LayoutOp::Split {
            pane_id: panes[0],
            axis: Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        });
        let ClientEvent::OpResult {
            outcome: OpOutcome::PaneCreated { pane_id },
            ..
        } = next_matching(
            &mut events,
            |event| matches!(event, ClientEvent::OpResult { op_id, .. } if *op_id == op),
        )
        .await
        else {
            panic!("split failed")
        };
        panes.push(pane_id);
    }
    let probe_pane = panes[2];
    // Each flood has a connection of its own that shows it focused (several hosts in one
    // app), all on the same two workers.
    client.set_view(Some(probe_pane), vec![probe_pane]);
    client.subscribe(probe_pane);
    let mut flooders = Vec::new();
    for &pane in &panes[..2] {
        let ticket = daemon
            .pairing_ticket(daemon::PAIRING_TTL)
            .unwrap()
            .to_string();
        let (tx, mut events) = mpsc::unbounded_channel();
        let flood = Arc::new(SlowTerminal {
            tx,
            probe: Mutex::new(None),
            echoes: Mutex::new(Vec::new()),
        });
        let mut config = ClientConfig::new(ClientConfig::generate_key());
        config.relay = RelayMode::Disabled;
        let other = Client::connect_on(runtime.handle(), &ticket, config, flood).unwrap();
        other.attach(None);
        next_matching(&mut events, |event| {
            matches!(event, ClientEvent::Layout { .. })
        })
        .await;
        other.set_view(Some(pane), vec![pane]);
        other.subscribe(pane);
        other.send_input(pane, b"yes\r".to_vec());
        flooders.push((other, events));
    }
    tokio::time::sleep(Duration::from_secs(1)).await;

    let mut asked = 0;
    for byte in b"abcdefghijklmnopqrstuvwxz"
        .iter()
        .copied()
        .cycle()
        .take(40)
    {
        *listener.probe.lock().unwrap() = Some((probe_pane, byte, Instant::now()));
        client.send_input(probe_pane, vec![byte]);
        asked += 1;
        let deadline = Instant::now() + Duration::from_secs(3);
        while listener.probe.lock().unwrap().is_some() && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        client.send_input(probe_pane, vec![0x7f]);
        tokio::time::sleep(Duration::from_millis(30)).await;
    }
    let mut echoes = listener.echoes.lock().unwrap().clone();
    echoes.sort();
    let p50 = echoes.get(echoes.len() / 2).copied();
    client.send_input(panes[0], b"\x03".to_vec());
    client.send_input(panes[1], b"\x03".to_vec());
    drop(client);
    drop(flooders);
    runtime.shutdown_background();
    daemon.shutdown().await;
    assert!(
        echoes.len() >= asked * 9 / 10,
        "{} of {asked} echoed",
        echoes.len()
    );
    let p50 = p50.unwrap();
    // Measured: 2-4 ms when streams take turns, 17-23 ms when a flood holds a worker.
    assert!(
        p50 < Duration::from_millis(8),
        "median echo {p50:?}: {echoes:?}"
    );
}

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
    let ClientEvent::Layout { layout } = next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Layout { .. })
    })
    .await
    else {
        unreachable!()
    };
    let pane = layout.tabs[0].focused;
    client.subscribe(pane);
    next_matching(&mut events, |event| {
        matches!(event, ClientEvent::PaneSnapshot { .. })
    })
    .await;
    client.send_input(pane, b"yes\r".to_vec());
    let mut flooded = 0;
    next_matching(&mut events, |event| {
        if let ClientEvent::PaneBytes { data, .. } = event {
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
    while let Ok(event) = events.try_recv() {
        if matches!(
            event,
            ClientEvent::PaneBytes { pane_id, .. } | ClientEvent::PaneSnapshot { pane_id, .. }
                if pane_id == pane
        ) {
            late += 1;
        }
    }
    let after = client.stats();
    assert_eq!(late, 0, "events for an unsubscribed pane");
    assert_eq!(
        after.snapshots, settled.snapshots,
        "the stream was not resubscribed"
    );
    assert_eq!(
        after.byte_frames, settled.byte_frames,
        "no bytes after it settled"
    );
    drop(client);
    daemon.shutdown().await;
}
