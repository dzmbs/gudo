use super::*;
use serde_json::{Value, json};

pub(super) fn source() -> Arc<Live> {
    Arc::new(Live {
        owner: tokio::sync::watch::channel(None).0,
        fault: std::sync::atomic::AtomicBool::new(false),
        state: Mutex::new(State::new()),
        runtime: Mutex::new(runtime::Runtime::default()),
        process: Mutex::new(None),
        task: Mutex::new(None),
        directory: crate::fsutil::create_private_temp_dir("gudo-codex-fixture").unwrap(),
    })
}

fn recording() -> Value {
    serde_json::from_str(include_str!(
        "../../../../agents/tests/fixtures/codex-live/pane-stream-0.166.0.json"
    ))
    .unwrap()
}

fn bind(state: &mut State, recording: &Value) {
    state.observe(&recording["request"].to_string(), true);
    state.observe(&recording["response"].to_string(), false);
    assert!(!state.closed);
}

#[test]
fn recorded_deltas_materialize_once_and_finalize_without_an_observer() {
    let recording = recording();
    let mut state = State::new();
    bind(&mut state, &recording);
    for event in recording["events"].as_array().unwrap() {
        state.observe(&event.to_string(), false);
    }
    assert!(!state.closed);
    let snapshot = state.projection.snapshot(60, None);
    assert_eq!(snapshot.items.len(), 1);
    assert!(
        matches!(&snapshot.items[0].body, proto::TimelineBody::Assistant { text, streaming: false }
        if text == "A same-process live mirror.\n")
    );
    let cursor = snapshot.cursor;
    state.observe(&recording["events"][2].to_string(), false);
    assert_eq!(
        state.projection.cursor(),
        cursor,
        "a late delta cannot reopen a completed turn"
    );
}

#[test]
fn unsupported_observation_does_not_corrupt_the_binding_or_accumulate_history() {
    let recording = recording();
    let mut state = State::new();
    bind(&mut state, &recording);
    state.observe("not json", false);
    assert!(state.closed);
    assert!(state.operations.is_empty());
    for _ in 0..1000 {
        state.observe(&recording["events"][1].to_string(), false);
    }
    assert!(state.operations.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn common_watch_is_read_only_and_catches_up_after_unwatch() {
    use client_core::{WorkspaceEvent, WorkspaceEventQueue};
    let raw = crate::agent_input::chat_tests::raw_fixture().await;
    let pane = raw.entry.pane.id;
    *lock(&raw.entry.agent) = Some(crate::agent::AgentRuntime::new(
        proto::AgentKind::Codex,
        pane,
        crate::agent::adapter(proto::AgentKind::Codex),
        false,
    ));
    lock(&raw.entry.record).agent.as_mut().unwrap().kind = proto::AgentKind::Codex;
    let source = source();
    *lock(&raw.entry.codex) = Some(Arc::clone(&source));
    let recording = recording();
    bind(&mut lock(&source.state), &recording);
    let (listener, mut events) = WorkspaceEventQueue::channel();
    raw.client.set_workspace_listener(listener);
    let response = raw.client.timeline_watch_capabilities(pane).await.unwrap();
    assert_eq!(
        response.capabilities,
        AgentCapabilities::READ | AgentCapabilities::STREAMING_DELTAS
    );
    assert!(response.snapshot.items.is_empty());
    lock(&source.state).observe(&recording["events"][0].to_string(), false);
    lock(&source.state).observe(&recording["events"][1].to_string(), false);
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            if let WorkspaceEvent::Timeline { update } = events.recv().await.unwrap()
                && update.operations.iter().any(|operation| matches!(operation, TimelineOp::Append { text, .. } if text == "A same-process ")) { break; }
        }
    }).await.unwrap();
    raw.client.timeline_unwatch(pane).await.unwrap();
    for event in &recording["events"].as_array().unwrap()[2..] {
        lock(&source.state).observe(&event.to_string(), false);
    }
    let response = raw.client.timeline_watch_capabilities(pane).await.unwrap();
    assert!(
        matches!(&response.snapshot.items[0].body, proto::TimelineBody::Assistant { text, streaming: false }
        if text == "A same-process live mirror.\n")
    );
    assert!(
        super::super::driver(proto::AgentKind::Codex)
            .send(
                &raw.daemon.core,
                &raw.entry.pane,
                None,
                "must not reach the PTY"
            )
            .is_err()
    );
    assert!(source.is_running());
    raw.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn snapshot_and_refresh_have_one_cursor_even_when_the_producer_advances() {
    let raw = crate::agent_input::chat_tests::raw_fixture().await;
    let source = source();
    *lock(&raw.entry.codex) = Some(Arc::clone(&source));
    let recording = recording();
    bind(&mut lock(&source.state), &recording);
    let (wake, _receiver) = mpsc::channel(1);
    let mut session = open(&raw.daemon.core, raw.entry.pane.id, wake).unwrap();
    let original = session.snapshot(None);
    assert!(session.check_history_scope(Some(UnixMillis(0))).is_err());
    lock(&source.state).observe(&recording["events"][0].to_string(), false);
    lock(&source.state).observe(&recording["events"][1].to_string(), false);
    assert_eq!(
        session.snapshot(None),
        original,
        "snapshot must not race ahead of the session cursor"
    );
    let operations = session
        .refresh(&raw.daemon.core, raw.entry.pane.id)
        .unwrap();
    assert_eq!(
        operations
            .iter()
            .filter(|operation| matches!(operation, TimelineOp::Append { .. }))
            .count(),
        1
    );
    assert!(
        session
            .refresh(&raw.daemon.core, raw.entry.pane.id)
            .unwrap()
            .is_empty()
    );
    assert!(
        matches!(&session.snapshot(None).items[0].body, proto::TimelineBody::Assistant { text, .. } if text == "A same-process ")
    );
    assert!(session.snapshot(Some(UnixMillis(0))).items.is_empty());
    assert!(
        session
            .read(
                TimelineRead::ItemsBefore {
                    before: 2,
                    limit: 60
                },
                Some(UnixMillis(0))
            )
            .await
            .is_err()
    );
    raw.daemon.shutdown().await;
}

#[test]
fn a_frame_for_another_thread_cannot_change_projection() {
    let recording = recording();
    let mut state = State::new();
    bind(&mut state, &recording);
    let mut event = recording["events"][0].clone();
    event["params"]["threadId"] = json!("other-pane");
    state.observe(&event.to_string(), false);
    assert!(state.projection.snapshot(60, None).items.is_empty());
    assert!(!state.closed);
}
