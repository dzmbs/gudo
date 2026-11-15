use std::time::Duration;

use client_core::{WorkspaceEvent, WorkspaceEventQueue};
use proto::{AgentCapabilities, TimelineBody, TimelineOp, WsError};
use serde_json::json;

use super::super::rollout::tests::{Fixture, THREAD};
use crate::agent_input::chat_tests::{RawFixture, raw_fixture_with_pane_env};
use crate::core::lock;

/// A pane running a Codex the daemon did not launch natively, whose home is `fixture`'s.
async fn codex_pane(fixture: &Fixture, session: Option<&str>) -> RawFixture {
    let raw = raw_fixture_with_pane_env(vec![(
        agents::CODEX_DIR_VAR.into(),
        fixture.home.path().display().to_string(),
    )])
    .await;
    *lock(&raw.entry.agent) = Some(crate::agent::AgentRuntime::new(
        proto::AgentKind::Codex,
        raw.entry.pane.id,
        crate::agent::adapter(proto::AgentKind::Codex),
        false,
    ));
    let mut record = lock(&raw.entry.record);
    let agent = record.agent.as_mut().unwrap();
    agent.kind = proto::AgentKind::Codex;
    agent.session_id = session.map(str::to_owned);
    agent.account = Some(proto::SYSTEM_ACCOUNT.into());
    drop(record);
    raw
}

fn text(body: &TimelineBody) -> &str {
    match body {
        TimelineBody::User { text, .. } | TimelineBody::Assistant { text, .. } => text,
        body => panic!("expected text, got {body:?}"),
    }
}

async fn next_operations(
    events: &mut tokio::sync::mpsc::UnboundedReceiver<WorkspaceEvent>,
    accept: impl Fn(&TimelineOp) -> bool,
) -> Vec<TimelineOp> {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let WorkspaceEvent::Timeline { update } = events.recv().await.unwrap()
                && update.operations.iter().any(&accept)
            {
                return update.operations;
            }
        }
    })
    .await
    .expect("the timeline update")
}

#[tokio::test(flavor = "multi_thread")]
async fn a_codex_the_daemon_does_not_drive_shows_its_rollout_and_follows_it_live() {
    let fixture = Fixture::new();
    for index in 0..70 {
        fixture.reply("turn-1", &format!("msg-{index}"), &format!("reply {index}"));
    }
    let raw = codex_pane(&fixture, Some(THREAD)).await;
    let pane = raw.entry.pane.id;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    raw.client.set_workspace_listener(listener);

    let watched = raw.client.timeline_watch_capabilities(pane).await.unwrap();
    assert!(watched.capabilities.contains(AgentCapabilities::READ));
    assert!(!watched.capabilities.contains(AgentCapabilities::STOP));
    assert_eq!(watched.snapshot.session.native_session, THREAD);
    let shown: Vec<_> = watched
        .snapshot
        .items
        .iter()
        .map(|item| text(&item.body))
        .collect();
    let expected: Vec<_> = (10..70).map(|index| format!("reply {index}")).collect();
    assert_eq!(shown, expected);

    let older = raw
        .client
        .timeline_items_before(pane, watched.snapshot.before.unwrap(), 100)
        .await
        .unwrap();
    let shown: Vec<_> = older.items.iter().map(|item| text(&item.body)).collect();
    let expected: Vec<_> = (0..10).map(|index| format!("reply {index}")).collect();
    assert_eq!(shown, expected);
    assert_eq!(older.before, None);

    fixture.item(
        "turn-2",
        json!({"type": "UserMessage", "id": "ask", "content": [{"type": "text", "text": "And now?"}]}),
    );
    fixture.reply("turn-2", "answer", "Done.");
    let mut seen = Vec::new();
    while !seen.iter().any(|shown: &String| shown == "Done.") {
        let operations = next_operations(&mut events, |operation| {
            matches!(operation, TimelineOp::Upsert { .. })
        })
        .await;
        for operation in operations {
            if let TimelineOp::Upsert { item, .. } = operation {
                seen.push(text(&item.body).to_owned());
            }
        }
    }
    assert_eq!(seen, ["And now?", "Done."]);
    raw.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn chat_waits_for_codex_to_save_its_first_turn() {
    let fixture = Fixture::new();
    std::fs::remove_file(&fixture.path).unwrap();
    let raw = codex_pane(&fixture, None).await;
    let pane = raw.entry.pane.id;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    raw.client.set_workspace_listener(listener);

    let watched = raw.client.timeline_watch_capabilities(pane).await.unwrap();
    assert!(watched.snapshot.items.is_empty());

    let saved = Fixture::new();
    std::fs::rename(&saved.path, &fixture.path).unwrap();
    fixture.reply("turn-1", "first", "Hello.");
    lock(&raw.entry.record).agent.as_mut().unwrap().session_id = Some(THREAD.into());
    raw.daemon
        .core
        .emit(crate::core::Event::PaneMeta(raw.entry.pane.id));
    let operations = next_operations(&mut events, |operation| {
        matches!(operation, TimelineOp::Snapshot(snapshot) if !snapshot.items.is_empty())
    })
    .await;
    let Some(TimelineOp::Snapshot(snapshot)) = operations.last() else {
        panic!("expected a snapshot");
    };
    assert_eq!(text(&snapshot.items[0].body), "Hello.");
    assert_eq!(snapshot.session.native_session, THREAD);
    raw.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_codex_that_records_an_older_history_format_says_to_update_it() {
    let fixture = Fixture::with_meta(json!({"history_mode": "legacy"}));
    let raw = codex_pane(&fixture, Some(THREAD)).await;
    let refusal = raw
        .client
        .timeline_watch_capabilities(raw.entry.pane.id)
        .await
        .unwrap_err();
    let WsError::Unavailable(message) = refusal else {
        panic!("expected unavailable, got {refusal:?}");
    };
    assert_eq!(
        message,
        "This Codex saves its history in an older format. Update Codex to see it in Chat."
    );
    raw.daemon.shutdown().await;
}
