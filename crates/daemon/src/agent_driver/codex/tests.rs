use super::*;
use serde_json::{Value, json};

pub(crate) fn source() -> Arc<Live> {
    Arc::new(Live {
        owner: tokio::sync::watch::channel(None).0,
        fault: std::sync::atomic::AtomicBool::new(false),
        state: Mutex::new(State::new()),
        runtime: Mutex::new(runtime::Runtime::default()),
        process: Mutex::new(None),
        task: Mutex::new(None),
        history_task: Mutex::new(None),
        controls: Mutex::new(None),
        control_task: Mutex::new(None),
        history_result: Mutex::new(None),
        observations: Mutex::new(None),
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
    state.observe(&recording["request"].to_string(), Direction::FromTui);
    state.observe(&recording["response"].to_string(), Direction::FromServer);
    assert!(!state.closed);
}

#[test]
fn recorded_deltas_materialize_once_and_finalize_without_an_observer() {
    let recording = recording();
    let mut state = State::new();
    bind(&mut state, &recording);
    for event in recording["events"].as_array().unwrap() {
        state.observe(&event.to_string(), Direction::FromServer);
    }
    assert!(!state.closed);
    let snapshot = state.projection.snapshot(projection::SNAPSHOT_ITEMS, None);
    assert_eq!(snapshot.items.len(), 1);
    assert!(
        matches!(&snapshot.items[0].body, proto::TimelineBody::Assistant { text, streaming: false }
        if text == "A same-process live mirror.\n")
    );
    let cursor = snapshot.cursor;
    state.observe(&recording["events"][2].to_string(), Direction::FromServer);
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
    state.observe("not json", Direction::FromServer);
    assert!(state.closed);
    assert!(state.operations.is_empty());
    for _ in 0..1000 {
        state.observe(&recording["events"][1].to_string(), Direction::FromServer);
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
    lock(&source.state).observe(&recording["events"][0].to_string(), Direction::FromServer);
    lock(&source.state).observe(&recording["events"][1].to_string(), Direction::FromServer);
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            if let WorkspaceEvent::Timeline { update } = events.recv().await.unwrap()
                && update.operations.iter().any(|operation| matches!(operation, TimelineOp::Append { text, .. } if text == "A same-process ")) { break; }
        }
    }).await.unwrap();
    raw.client.timeline_unwatch(pane).await.unwrap();
    for event in &recording["events"].as_array().unwrap()[2..] {
        lock(&source.state).observe(&event.to_string(), Direction::FromServer);
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
                "must not reach the PTY",
                None,
            )
            .is_err()
    );
    assert!(!source.fault.load(std::sync::atomic::Ordering::Acquire));
    assert!(lock(&source.state).is_chat_ready());
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
    lock(&source.state).observe(&recording["events"][0].to_string(), Direction::FromServer);
    lock(&source.state).observe(&recording["events"][1].to_string(), Direction::FromServer);
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
    state.observe(&event.to_string(), Direction::FromServer);
    assert!(
        state
            .projection
            .snapshot(projection::SNAPSHOT_ITEMS, None)
            .items
            .is_empty()
    );
    assert!(!state.closed);
}

fn started_turn(turn: &str) -> String {
    json!({"method":"turn/started","params":{"threadId":"primary","turn":{"id":turn,"status":"inProgress"}}}).to_string()
}

fn primary() -> State {
    let mut state = State::new();
    state.observe(r#"{"id":1,"method":"thread/start"}"#, Direction::FromTui);
    state.observe(
        r#"{"id":1,"result":{"thread":{"id":"primary"}}}"#,
        Direction::FromServer,
    );
    state.effects.clear();
    state
}

#[test]
fn a_skipped_server_message_leaves_a_notice_and_status_keeps_flowing() {
    let mut state = primary();
    state.skipped(Direction::FromServer, None);
    assert!(state.is_chat_ready());
    assert!(matches!(
        &state
            .projection
            .snapshot(projection::SNAPSHOT_ITEMS, None)
            .items[0]
            .body,
        proto::TimelineBody::Notice { .. }
    ));
    state.observe(&started_turn("turn"), Direction::FromServer);
    assert!(matches!(state.effects[..], [runtime::Effect::Started]));
}

#[test]
fn a_skipped_tui_message_or_binding_reply_closes_observation() {
    let mut state = primary();
    state.skipped(Direction::FromTui, None);
    assert!(state.closed);
    let mut state = primary();
    state.observe(
        r#"{"id":2,"method":"thread/resume","params":{"threadId":"other"}}"#,
        Direction::FromTui,
    );
    state.skipped(Direction::FromServer, None);
    assert!(state.closed);
}

#[test]
fn a_full_capture_closes_chat_but_not_status_or_approvals() {
    let mut state = State::new();
    state.observe(
        r#"{"id":9,"method":"thread/resume","params":{"threadId":"primary","excludeTurns":true}}"#,
        Direction::FromTui,
    );
    state.observe(
        r#"{"id":9,"result":{"thread":{"id":"primary","turns":[]}}}"#,
        Direction::FromServer,
    );
    state.observe(&started_turn("turn"), Direction::FromServer);
    let delta = json!({"method":"item/agentMessage/delta","params":{"threadId":"primary","turnId":"turn","itemId":"message","delta":"x"}}).to_string();
    for _ in 0..MAX_CAPTURED_EVENTS {
        state.observe(&delta, Direction::FromServer);
    }
    assert!(!state.closed);
    assert!(!state.is_chat_ready());
    assert!(state.is_ready());
    state.effects.clear();
    state.observe(&json!({"id":5,"method":"item/commandExecution/requestApproval","params":{"threadId":"primary","turnId":"turn","itemId":"tool"}}).to_string(), Direction::FromServer);
    assert!(matches!(state.effects[..], [runtime::Effect::Waiting(..)]));
}

#[tokio::test]
async fn a_slow_observer_still_sees_every_byte_in_order() {
    let source = source();
    let (sender, mut receiver) = tokio::sync::mpsc::channel(1);
    let (mut tui, relay_tui) = tokio::net::UnixStream::pair().unwrap();
    let (mut server, relay_server) = tokio::net::UnixStream::pair().unwrap();
    let relay = tokio::spawn(transport::forward(
        relay_tui,
        relay_server,
        Arc::downgrade(&source),
        sender,
    ));
    let expected: Vec<_> = (0..512 * 1024).map(|index| (index % 251) as u8).collect();
    let bytes = expected.clone();
    let writer = tokio::spawn(async move {
        use tokio::io::AsyncWriteExt;
        server.write_all(&bytes).await.unwrap();
        server.shutdown().await.unwrap();
    });
    let reader = tokio::spawn(async move {
        use tokio::io::AsyncReadExt;
        let mut received = Vec::new();
        tui.read_to_end(&mut received).await.unwrap();
        received
    });
    let mut observed = Vec::new();
    while let Some(observation) = receiver.recv().await {
        tokio::task::yield_now().await;
        if let transport::Observation::Bytes(Direction::FromServer, bytes) = observation {
            observed.extend(bytes);
        }
    }
    writer.await.unwrap();
    relay.await.unwrap().unwrap();
    assert_eq!(reader.await.unwrap(), expected);
    assert_eq!(observed, expected);
    assert!(!source.fault.load(std::sync::atomic::Ordering::Acquire));
}

#[tokio::test]
async fn a_launch_that_never_bootstrapped_does_not_hold_helper_restarts() {
    let source = source();
    assert!(!source.is_running(), "no app-server and no launch");
    let launch = tokio::spawn(std::future::pending::<()>());
    *lock(&source.task) = Some(launch.abort_handle());
    assert!(source.is_running());
    launch.abort();
    let _ = launch.await;
    assert!(!source.is_running());
}

#[tokio::test(flavor = "multi_thread")]
async fn the_exit_fence_retires_the_pane_codex_source() {
    let raw = crate::agent_input::chat_tests::raw_fixture().await;
    let source = source();
    let launch = tokio::spawn(std::future::pending::<()>());
    *lock(&source.task) = Some(launch.abort_handle());
    *lock(&raw.entry.codex) = Some(source);
    assert!(raw.daemon.core.has_live_codex());
    end_launch(&raw.entry);
    assert!(lock(&raw.entry.codex).is_none());
    assert!(!raw.daemon.core.has_live_codex());
    assert!(launch.await.unwrap_err().is_cancelled());
    raw.daemon.shutdown().await;
}
