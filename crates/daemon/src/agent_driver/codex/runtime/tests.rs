use super::*;
use crate::agent::AgentRuntime;
use serde_json::{Value, json};

fn observe(source: &Arc<Live>, frame: Value, outgoing: bool) {
    let effects = {
        let mut state = lock(&source.state);
        state.observe(&frame.to_string(), outgoing);
        std::mem::take(&mut state.effects)
    };
    source.publish(effects);
}

fn started() -> Value {
    json!({"method":"turn/started","params":{"threadId":"primary","turn":{"id":"turn","status":"inProgress"}}})
}

fn waiting(request: i64) -> Value {
    json!({"id":request,"method":"item/commandExecution/requestApproval","params":{"threadId":"primary","turnId":"turn","itemId":format!("command-{request}")}})
}

#[tokio::test]
async fn mapped_events_register_the_session_and_drive_status_without_notify() {
    let raw = crate::agent_input::chat_tests::raw_fixture().await;
    let core = &raw.daemon.core;
    let pane = raw.entry.pane.id;
    raw.entry.stop_task();
    *lock(&raw.entry.agent) = Some(AgentRuntime::structured(
        proto::AgentKind::Codex,
        pane,
        crate::agent::adapter(proto::AgentKind::Codex),
    ));
    {
        let mut record = lock(&raw.entry.record);
        let agent = record.agent.as_mut().unwrap();
        agent.kind = proto::AgentKind::Codex;
        agent.session_id = None;
    }
    let source = super::super::tests::source();
    *lock(&raw.entry.codex) = Some(Arc::clone(&source));
    source.set_owner(core, &raw.entry);
    source.capture_context(raw.root.path().to_owned(), raw.entry.pane.pty().pid());
    observe(&source, json!({"id":1,"method":"thread/start"}), true);
    observe(
        &source,
        json!({"id":1,"result":{"thread":{"id":"primary"}}}),
        false,
    );
    assert_eq!(
        lock(&raw.entry.record)
            .agent
            .as_ref()
            .unwrap()
            .session_id
            .as_deref(),
        Some("primary")
    );
    assert_eq!(
        lock(&raw.entry.agent)
            .as_ref()
            .unwrap()
            .session()
            .cwd
            .as_deref(),
        Some(raw.root.path())
    );
    observe(&source, started(), false);
    assert_eq!(
        lock(&raw.entry.agent).as_ref().unwrap().state(),
        agents::AgentState::Working
    );
    for request in [7, 8] {
        observe(&source, waiting(request), false);
    }
    assert!(lock(&raw.entry.agent).as_ref().unwrap().is_blocked());
    assert!(
        lock(&raw.entry.agent)
            .as_mut()
            .unwrap()
            .blocked_detail()
            .unwrap()
            .options
            .is_empty()
    );
    for (thread, request) in [("helper", 7), ("primary", 99), ("primary", 7)] {
        observe(
            &source,
            json!({"method":"serverRequest/resolved","params":{"threadId":thread,"requestId":request}}),
            false,
        );
        assert!(lock(&raw.entry.agent).as_ref().unwrap().is_blocked());
    }
    observe(
        &source,
        json!({"method":"serverRequest/resolved","params":{"threadId":"primary","requestId":8}}),
        false,
    );
    assert_eq!(
        lock(&raw.entry.agent).as_ref().unwrap().state(),
        agents::AgentState::Working
    );
    observe(
        &source,
        json!({"method":"turn/completed","params":{"threadId":"helper","turn":{"id":"turn","status":"completed"}}}),
        false,
    );
    assert_eq!(lock(&raw.entry.meta).turns, 0);
    observe(
        &source,
        json!({"method":"turn/completed","params":{"threadId":"primary","turn":{"id":"turn","status":"completed"}}}),
        false,
    );
    assert_eq!(
        lock(&raw.entry.agent).as_ref().unwrap().state(),
        agents::AgentState::Idle
    );
    assert_eq!(lock(&raw.entry.meta).turns, 1);
    observe(
        &source,
        json!({"method":"turn/completed","params":{"threadId":"primary","turn":{"id":"turn","status":"completed"}}}),
        false,
    );
    assert_eq!(lock(&raw.entry.meta).turns, 1);
    observe(
        &source,
        json!({"method":"turn/started","params":{"threadId":"primary","turn":{"id":"next","status":"inProgress"}}}),
        false,
    );
    observe(
        &source,
        json!({"method":"turn/completed","params":{"threadId":"primary","turn":{"id":"next","status":"newUnknownOutcome"}}}),
        false,
    );
    assert_eq!(
        lock(&raw.entry.agent).as_ref().unwrap().state(),
        agents::AgentState::Error
    );
    assert_eq!(
        lock(&raw.entry.meta).turns,
        1,
        "unknown is not a completed turn"
    );
    let effects = {
        let mut state = lock(&source.state);
        state.fail();
        std::mem::take(&mut state.effects)
    };
    source.publish(effects);
    assert_eq!(
        lock(&raw.entry.agent).as_ref().unwrap().state(),
        agents::AgentState::Unknown
    );
    assert_eq!(lock(&raw.entry.meta).turns, 1);
    let replacement = super::super::tests::source();
    *lock(&raw.entry.codex) = Some(replacement);
    source.publish(vec![
        Effect::Bound("obsolete".into(), None),
        Effect::Completed(CodexTurnOutcome::Completed),
    ]);
    assert_eq!(
        lock(&raw.entry.record)
            .agent
            .as_ref()
            .unwrap()
            .session_id
            .as_deref(),
        Some("primary")
    );
    assert_eq!(lock(&raw.entry.meta).turns, 1);
    raw.daemon.shutdown().await;
}

#[test]
fn bound_thread_context_replaces_the_post_login_launch_directory() {
    let mut runtime = Runtime {
        cwd: Some("/launch".into()),
        ..Runtime::default()
    };
    let signal = runtime
        .apply(Effect::Bound(
            "primary".into(),
            Some("/resumed-project".into()),
        ))
        .unwrap();
    assert_eq!(signal.session.cwd, Some("/resumed-project".into()));
}

#[test]
fn resolution_of_one_request_does_not_unblock_another() {
    let mut runtime = Runtime::default();
    let _ = runtime.apply(Effect::Bound("primary".into(), None));
    let _ = runtime.apply(Effect::Started);
    let _ = runtime.apply(Effect::Waiting(
        CodexRpcId::Integer(7),
        CodexApprovalKind::Command,
    ));
    let _ = runtime.apply(Effect::Waiting(
        CodexRpcId::Text("7".into()),
        CodexApprovalKind::FileChange,
    ));
    let signal = runtime
        .apply(Effect::Resolved(CodexRpcId::Integer(7)))
        .unwrap();
    assert_eq!(signal.kind, EventKind::Blocked);
    assert!(matches!(signal.claim, Some(Claim::Blocked(_))));
    let signal = runtime
        .apply(Effect::Resolved(CodexRpcId::Text("7".into())))
        .unwrap();
    assert_eq!(signal.claim, Some(Claim::Working));
    assert_eq!(
        signal.turn, None,
        "resolved does not mean approved or completed"
    );
}
