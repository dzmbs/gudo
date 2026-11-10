//! What the client sends while the host is away: what its caller gave up on is never applied
//! once the host is back, and what waits for it stays small.

use std::time::Duration;

use client_core::ClientEvent;
use client_core::proto::{LayoutOp, PaneLaunch, PaneSize};

use super::{Host, connect, next_matching};

#[tokio::test(flavor = "multi_thread")]
async fn requests_given_up_during_an_outage_are_never_applied_and_the_rest_stays_small() {
    let mut host = Host::start().await;
    let (client, mut events) = connect(&host.ticket(), false);
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
    host.go_down().await;
    next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Disconnected { .. })
    })
    .await;

    let new_tab = || LayoutOp::NewTab {
        session_id,
        name: String::new(),
        launch: PaneLaunch::Shell { cwd: None },
    };
    let abandoned_op = client.op(new_tab());
    assert!(client.withdraw_op(abandoned_op), "the op was not waiting");
    let kept_op = client.op(new_tab());
    let abandoned_dir = host.home.join("abandoned");
    let gave_up = tokio::time::timeout(
        Duration::from_millis(300),
        client.fs_mkdir(abandoned_dir.to_string_lossy().into_owned(), true),
    )
    .await;
    assert!(gave_up.is_err(), "the request ended on its own");
    for cols in 0..10_000u16 {
        client.resize(
            pane,
            PaneSize {
                cols: 20 + cols % 200,
                rows: 24,
                width_px: 0,
                height_px: 0,
            },
        );
        client.set_typing(pane, cols % 2 == 0);
    }
    assert!(
        client.queued() < 10,
        "{} items wait for the host",
        client.queued()
    );

    host.come_back().await;
    let mut answered = Vec::new();
    next_matching(&mut events, |event| {
        if let ClientEvent::OpResult { op_id, .. } = event {
            answered.push(*op_id);
        }
        answered.contains(&kept_op)
    })
    .await;
    tokio::time::sleep(Duration::from_secs(2)).await;
    while let Ok(event) = events.try_recv() {
        if let ClientEvent::OpResult { op_id, .. } = event {
            answered.push(op_id);
        }
    }
    assert!(
        !answered.contains(&abandoned_op),
        "a withdrawn op was applied"
    );
    assert!(
        !abandoned_dir.exists(),
        "a request its caller gave up on was applied"
    );
    drop(client);
    host.go_down().await;
}
