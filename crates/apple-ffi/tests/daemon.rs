//! The FFI surface against a real daemon (relays off, loopback), driven the way Swift drives
//! it: from a plain thread, with a listener object.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use unnamed_core::{
    Axis, ClientConfig, ClientEvent, ClientEventListener, DaemonClient, LayoutOp, OpOutcome,
    PaneLaunch, PaneSize, RelayMode, generate_device_key,
};

#[derive(Default)]
struct Recorder(Mutex<Vec<ClientEvent>>);

impl ClientEventListener for Recorder {
    fn on_event(&self, event: ClientEvent) {
        self.0.lock().unwrap().push(event);
    }
}

impl Recorder {
    fn wait<T>(&self, what: &str, mut f: impl FnMut(&[ClientEvent]) -> Option<T>) -> T {
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if let Some(found) = f(&self.0.lock().unwrap()) {
                return found;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("timed out waiting for {what}");
    }
}

#[test]
fn connect_attach_split_echo() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let daemon = rt.block_on(async {
        let mut config = daemon::Config::new(dir.path());
        config.relay = daemon::RelayMode::Disabled;
        config.bind = Some("127.0.0.1:0".parse().unwrap());
        config.shell = Some("/bin/sh".into());
        daemon::Daemon::start(config).await.unwrap()
    });
    let ticket = daemon
        .pairing_ticket(daemon::PAIRING_TTL)
        .unwrap()
        .to_string();

    let events = Arc::new(Recorder::default());
    let client = DaemonClient::connect(
        ticket,
        ClientConfig {
            secret_key: generate_device_key(),
            relay: RelayMode::Disabled,
            mirror_vt: true,
            repo_status: false,
        },
        events.clone(),
    )
    .unwrap();
    events.wait("connected", |all| {
        all.iter()
            .any(|e| matches!(e, ClientEvent::Connected { .. }))
            .then_some(())
    });
    client.attach(None);
    let layout = events.wait("layout", |all| {
        all.iter().find_map(|e| match e {
            ClientEvent::Layout { layout } => Some(layout.clone()),
            _ => None,
        })
    });
    let pane = layout.tabs[0].focused;
    client.subscribe(pane);
    client.resize(
        pane,
        PaneSize {
            cols: 80,
            rows: 24,
            width_px: 0,
            height_px: 0,
        },
    );
    // Subscribing starts with a snapshot; output after it streams as raw `PaneBytes`. Type
    // only once the snapshot is in, or a fast echo can land inside the snapshot instead.
    events.wait("snapshot", |all| {
        all.iter()
            .any(|e| matches!(e, ClientEvent::PaneSnapshot { .. }))
            .then_some(())
    });
    client.send_input(pane, b"echo ffi-$((6*7))\r");
    events.wait("echo", |_| {
        client
            .pane_text(pane)
            .filter(|t| t.contains("ffi-42"))
            .map(drop)
    });
    let bytes: usize = events
        .0
        .lock()
        .unwrap()
        .iter()
        .map(|e| match e {
            ClientEvent::PaneBytes { data, .. } => data.len(),
            _ => 0,
        })
        .sum();
    assert!(bytes > 0, "raw output crossed as PaneBytes");

    let op_id = client.op(LayoutOp::Split {
        pane_id: pane,
        axis: Axis::Vertical,
        launch: PaneLaunch::Shell { cwd: None },
    });
    let outcome = events.wait("op result", |all| {
        all.iter().find_map(|e| match e {
            ClientEvent::OpResult { op_id: id, outcome } if *id == op_id => Some(outcome.clone()),
            _ => None,
        })
    });
    assert!(
        matches!(outcome, OpOutcome::PaneCreated { .. }),
        "{outcome:?}"
    );
    let layout = events.wait("two panes", |all| {
        all.iter().rev().find_map(|e| match e {
            ClientEvent::Layout { layout } if layout.tabs[0].nodes.len() == 3 => {
                Some(layout.clone())
            }
            _ => None,
        })
    });
    assert!(matches!(
        layout.tabs[0].nodes[0],
        unnamed_core::LayoutNode::Split {
            axis: Axis::Vertical,
            first: 1,
            second: 2,
            ..
        }
    ));

    drop(client);
    rt.block_on(daemon.shutdown());
}
