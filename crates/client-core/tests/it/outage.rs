//! The host goes away for a long while (`GUDO_OUTAGE_SECS`, 30 s by default; minutes in a
//! release soak) while the app keeps working: typing, resizing, drawing, an op, an upload and
//! a forwarded connection. What waits for the host stays small, the upload and the forward give
//! up within their deadline, an op given up on is never applied, and once the host is back the
//! pane renders again.

use std::time::{Duration, Instant};

use client_core::drawing::{self, InkPoint};
use client_core::proto::{
    Actor, ArtifactId, DeviceId, ElementId, ForwardTarget, InkLive, LayoutOp, PaneId, PaneLaunch,
    PaneSize, PrincipalId, Style, Tool,
};
use client_core::{Client, ClientEvent};
use tokio::io::AsyncReadExt;

use super::{Host, connect, next_matching};

/// How long an upload or a forwarded connection may wait for a host that is away.
const GIVES_UP_WITHIN: Duration = Duration::from_secs(30);
/// What waits for the host besides typed input: a few replayed states and the op.
const HELD_BESIDES_INPUT: usize = 16;

fn outage() -> Duration {
    let seconds = std::env::var("GUDO_OUTAGE_SECS")
        .ok()
        .and_then(|seconds| seconds.parse().ok())
        .unwrap_or(30);
    Duration::from_secs(seconds)
}

fn ink(chunk: u32) -> InkLive {
    InkLive {
        artifact_id: ArtifactId(1),
        stroke_id: ElementId(1),
        actor: Actor {
            principal: PrincipalId([0; 16]),
            device: DeviceId([0; 32]),
        },
        chunk,
        tool: Tool::Pen,
        style: Style {
            color: 0x00ff_00ff,
            width: 0.2,
        },
        points: drawing::pack(&[InkPoint::at(chunk as f32, 1.0, chunk)]),
        done: false,
    }
}

/// Keeps the app busy until `until`: typing, resizing, drawing. Returns the keystrokes typed
/// and the most that ever waited beyond them.
async fn keep_working(client: &Client, pane: PaneId, until: Instant) -> (usize, usize) {
    let mut keystrokes = 0;
    let mut most_held_besides_input = 0;
    let mut chunk = 0u32;
    while Instant::now() < until {
        for _ in 0..50 {
            chunk += 1;
            client.resize(
                pane,
                PaneSize {
                    cols: 40 + (chunk % 120) as u16,
                    rows: 24,
                    width_px: 0,
                    height_px: 0,
                },
            );
            client.ink_live(ink(chunk));
            client.set_typing(pane, chunk % 2 == 0);
        }
        client.send_input(pane, b"x".to_vec());
        keystrokes += 1;
        most_held_besides_input =
            most_held_besides_input.max(client.queued().saturating_sub(keystrokes));
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    (keystrokes, most_held_besides_input)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_long_outage_while_working_stays_bounded_and_recovers() {
    let mut host = Host::start().await;
    let (client, mut events) = connect(&host.ticket(), true);
    client.attach(None);
    let ClientEvent::Layout { layout } = next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Layout { .. })
    })
    .await
    else {
        unreachable!()
    };
    let session_id = layout.session_id;
    let pane = layout.tabs[0].focused;
    client.subscribe(pane);
    next_matching(&mut events, |event| {
        matches!(event, ClientEvent::PaneSnapshot { .. })
    })
    .await;
    let forwarded_port = client
        .forward(0, ForwardTarget::Tcp { port: 9 })
        .expect("bound");

    host.go_down().await;
    let outage_ends = Instant::now() + outage();

    let abandoned_op = client.op(LayoutOp::NewTab {
        session_id,
        name: "abandoned".into(),
        launch: PaneLaunch::Shell { cwd: None },
    });
    let upload = async {
        let started = Instant::now();
        let result = client
            .upload_bytes(b"lost".to_vec(), host.write_target("outage.txt"))
            .await;
        (result, started.elapsed())
    };
    let forward = async {
        let started = Instant::now();
        let mut local = tokio::net::TcpStream::connect(("127.0.0.1", forwarded_port))
            .await
            .expect("the forward listens");
        let mut ignored = [0; 16];
        let _ = tokio::time::timeout(GIVES_UP_WITHIN * 2, local.read(&mut ignored)).await;
        started.elapsed()
    };
    let give_up_on_the_op = async {
        tokio::time::sleep(Duration::from_secs(1)).await;
        client.withdraw_op(abandoned_op)
    };
    let ((upload, upload_took), forward_took, withdrawn, (keystrokes, most_held)) = tokio::join!(
        upload,
        forward,
        give_up_on_the_op,
        keep_working(&client, pane, outage_ends),
    );

    assert!(upload.is_err(), "{upload:?}");
    assert!(
        upload_took < GIVES_UP_WITHIN,
        "the upload waited {upload_took:?}"
    );
    assert!(
        forward_took < GIVES_UP_WITHIN,
        "the forwarded connection waited {forward_took:?}"
    );
    assert!(withdrawn, "the op had left before the host came back");
    assert!(
        most_held <= HELD_BESIDES_INPUT,
        "{most_held} items besides {keystrokes} keystrokes waited for the host"
    );

    host.come_back().await;
    let mut ops_answered = Vec::new();
    let mut tabs_after = None;
    next_matching(&mut events, |event| match event {
        ClientEvent::OpResult { op_id, .. } => {
            ops_answered.push(*op_id);
            false
        }
        ClientEvent::Layout { layout } => {
            tabs_after = Some(
                layout
                    .tabs
                    .iter()
                    .map(|tab| tab.name.clone())
                    .collect::<Vec<_>>(),
            );
            true
        }
        _ => false,
    })
    .await;
    client.send_input(pane, b"\recho back$((6*7))\r".to_vec());
    let rendering = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            if client
                .pane_text(pane)
                .is_some_and(|text| text.contains("back42"))
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await;
    assert!(rendering.is_ok(), "the pane did not render again");
    tokio::time::sleep(Duration::from_secs(1)).await;
    while let Ok(event) = events.try_recv() {
        if let ClientEvent::OpResult { op_id, .. } = event {
            ops_answered.push(op_id);
        }
    }
    assert!(
        !ops_answered.contains(&abandoned_op),
        "a withdrawn op was applied"
    );
    assert!(
        !tabs_after
            .unwrap_or_default()
            .iter()
            .any(|name| name == "abandoned"),
        "a withdrawn op made a tab"
    );
    assert!(!host.home.join("outage.txt").exists());
    drop(client);
    host.go_down().await;
}
