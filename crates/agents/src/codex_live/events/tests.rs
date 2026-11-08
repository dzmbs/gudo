mod items;
mod resolution;

use super::*;
use serde_json::{Value, json};

fn connection(thread: &str) -> CodexBinding {
    let mut connection = CodexBinding::default();
    connection
        .observe_tui(r#"{"id":1,"method":"thread/start"}"#)
        .unwrap();
    connection
        .observe_server(&json!({"id":1,"result":{"thread":{"id":thread}}}).to_string())
        .unwrap();
    connection
}

fn start(thread: &str, turn: &str) -> String {
    json!({"method":"turn/started", "params":{"threadId":thread,"turn":{"id":turn,"status":"inProgress"}}}).to_string()
}

fn complete(thread: &str, turn: &str, status: &str) -> String {
    json!({"method":"turn/completed", "params":{"threadId":thread,"turn":{"id":turn,"status":status}}}).to_string()
}

#[test]
fn physical_pane_fixtures_replay_streaming_and_approval_signals() {
    for (source, expects_approval) in [
        (
            include_str!("../../../tests/fixtures/codex-live/pane-stream-0.166.0.json"),
            false,
        ),
        (
            include_str!("../../../tests/fixtures/codex-live/pane-approval-0.166.0.json"),
            true,
        ),
    ] {
        let fixture: Value = serde_json::from_str(source).unwrap();
        let mut connection = CodexBinding::default();
        connection
            .observe_tui(&fixture["request"].to_string())
            .unwrap();
        connection
            .observe_server(&fixture["response"].to_string())
            .unwrap();
        let mut stream = CodexLiveEvents::new(connection.binding().unwrap().clone());
        let events: Vec<_> = fixture["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|frame| stream.observe(&connection, &frame.to_string()).unwrap())
            .collect();
        assert_eq!(
            events
                .iter()
                .filter(|event| matches!(event, CodexLiveEvent::TurnStarted { .. }))
                .count(),
            1
        );
        assert_eq!(
            events.iter().any(|event| matches!(
                event,
                CodexLiveEvent::ApprovalWaiting {
                    kind: CodexApprovalKind::Command,
                    ..
                }
            )),
            expects_approval
        );
        assert_eq!(
            events.iter().any(|event| matches!(
                event,
                CodexLiveEvent::TurnCompleted {
                    outcome: CodexTurnOutcome::Completed,
                    ..
                }
            )),
            !expects_approval
        );
        if !expects_approval {
            let text: String = events
                .iter()
                .filter_map(|event| match event {
                    CodexLiveEvent::AssistantDelta { text, .. } => Some(text.as_str()),
                    _ => None,
                })
                .collect();
            assert_eq!(text, "A same-process live mirror.\n");
        }
    }
}

#[test]
fn duplicate_starts_do_not_renew_a_turn_and_inconsistent_status_closes() {
    let connection = connection("primary");
    let mut stream = CodexLiveEvents::new(connection.binding().unwrap().clone());
    assert!(
        stream
            .observe(&connection, &start("primary", "turn"))
            .unwrap()
            .is_some()
    );
    assert!(
        stream
            .observe(&connection, &start("primary", "turn"))
            .unwrap()
            .is_none()
    );
    assert!(
        stream
            .observe(&connection, &complete("primary", "turn", "inProgress"))
            .is_err()
    );
    assert_eq!(
        stream.observe(&connection, &complete("primary", "turn", "completed")),
        Err(CodexBindingError::Closed)
    );
}

#[test]
fn recorded_stream_reports_deltas_and_completion_without_notify() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../daemon/tests/fixtures/timeline/codex-0.166.0.json"
    ))
    .unwrap();
    let frames = fixture["clients"][0].as_array().unwrap();
    let thread = frames.iter().find(|frame| frame["id"] == 2).unwrap()["result"]["thread"]["id"]
        .as_str()
        .unwrap();
    let connection = connection(thread);
    let mut stream = CodexLiveEvents::new(connection.binding().unwrap().clone());
    let mut text = String::new();
    let mut completed = 0;
    for frame in frames {
        match stream.observe(&connection, &frame.to_string()).unwrap() {
            Some(CodexLiveEvent::AssistantDelta { text: delta, .. }) => text.push_str(&delta),
            Some(CodexLiveEvent::TurnCompleted { outcome, .. }) => {
                assert_eq!(outcome, CodexTurnOutcome::Completed);
                completed += 1;
            }
            _ => {}
        }
    }
    assert_eq!(text, "A same-process live mirror.\n");
    assert_eq!(completed, 1);
}

#[test]
fn auxiliary_and_obsolete_turns_cannot_complete_the_primary_turn() {
    let connection = connection("primary");
    let mut stream = CodexLiveEvents::new(connection.binding().unwrap().clone());
    assert!(
        stream
            .observe(&connection, &start("primary", "first"))
            .unwrap()
            .is_some()
    );
    assert!(
        stream
            .observe(&connection, &start("title", "helper"))
            .unwrap()
            .is_none()
    );
    assert!(
        stream
            .observe(&connection, &complete("title", "helper", "completed"))
            .unwrap()
            .is_none()
    );
    stream
        .observe(&connection, &start("primary", "second"))
        .unwrap();
    assert!(
        stream
            .observe(&connection, &complete("primary", "first", "completed"))
            .unwrap()
            .is_none()
    );
    let delta = json!({"method":"item/agentMessage/delta","params":{"threadId":"primary","turnId":"first","itemId":"message","delta":"obsolete"}});
    assert!(
        stream
            .observe(&connection, &delta.to_string())
            .unwrap()
            .is_none()
    );
    assert!(
        stream
            .observe(&connection, &complete("primary", "second", "interrupted"))
            .unwrap()
            .is_some()
    );
    assert!(
        stream
            .observe(&connection, &complete("primary", "second", "completed"))
            .unwrap()
            .is_none()
    );
}

#[test]
fn approval_signals_keep_rpc_types_and_current_turn_scope() {
    for (identifier, expected) in [
        (json!(7), RpcId::Integer(7)),
        (json!("7"), RpcId::Text("7".into())),
    ] {
        let connection = connection("primary");
        for (method, kind) in [
            (
                "item/commandExecution/requestApproval",
                CodexApprovalKind::Command,
            ),
            (
                "item/fileChange/requestApproval",
                CodexApprovalKind::FileChange,
            ),
        ] {
            let mut stream = CodexLiveEvents::new(connection.binding().unwrap().clone());
            stream
                .observe(&connection, &start("primary", "turn"))
                .unwrap();
            let mut frame = json!({"id":identifier,"method":method,"params":{"threadId":"title","turnId":"turn","itemId":"tool"}});
            assert!(
                stream
                    .observe(&connection, &frame.to_string())
                    .unwrap()
                    .is_none()
            );
            frame["params"]["threadId"] = json!("primary");
            assert_eq!(
                stream.observe(&connection, &frame.to_string()).unwrap(),
                Some(CodexLiveEvent::ApprovalWaiting {
                    request: expected.clone(),
                    turn: "turn".into(),
                    item: "tool".into(),
                    kind
                })
            );
        }
    }
}

#[test]
fn malformed_frames_permanently_close_only_native_observation() {
    for frame in [
        "not json".to_owned(),
        " ".repeat(super::super::MAX_FRAME_BYTES + 1),
        r#"{"method":"turn/started","params":{"threadId":"primary","threadId":"other","turn":{"id":"turn","status":"inProgress"}}}"#.to_owned(),
        r#"{"id":true,"method":"item/commandExecution/requestApproval","params":{"threadId":"primary","turnId":"turn","itemId":"tool"}}"#.to_owned(),
        r#"{"method":"turn/started","params":{"threadId":"primary","turn":{"id":"","status":"inProgress"}}}"#.to_owned(),
    ] {
        let connection = connection("primary");
        let mut stream = CodexLiveEvents::new(connection.binding().unwrap().clone());
        assert!(stream.observe(&connection, &frame).is_err());
        assert_eq!(stream.observe(&connection, &start("primary","turn")), Err(CodexBindingError::Closed));
        assert!(connection.binding().is_some());
    }
}

#[test]
fn another_connection_with_the_same_thread_cannot_supply_events() {
    let first = connection("primary");
    let second = connection("primary");
    let mut stream = CodexLiveEvents::new(first.binding().unwrap().clone());
    assert_eq!(
        stream.observe(&second, &start("primary", "turn")),
        Err(CodexBindingError::Closed)
    );
    assert_eq!(
        stream.observe(&first, &start("primary", "turn")),
        Err(CodexBindingError::Closed)
    );
}

#[test]
fn unknown_outcome_is_not_success_and_retired_bindings_never_revive() {
    let mut connection = connection("primary");
    let mut stream = CodexLiveEvents::new(connection.binding().unwrap().clone());
    stream
        .observe(&connection, &start("primary", "turn"))
        .unwrap();
    assert_eq!(
        stream
            .observe(&connection, &complete("primary", "turn", "future_status"))
            .unwrap(),
        Some(CodexLiveEvent::TurnCompleted {
            turn: "turn".into(),
            outcome: CodexTurnOutcome::Unknown
        })
    );
    connection
        .observe_tui(r#"{"id":2,"method":"thread/resume","params":{"threadId":"primary"}}"#)
        .unwrap();
    assert_eq!(
        stream.observe(&connection, &start("primary", "turn")),
        Err(CodexBindingError::Closed)
    );
    connection
        .observe_server(r#"{"id":2,"result":{"thread":{"id":"primary"}}}"#)
        .unwrap();
    assert_eq!(
        stream.observe(&connection, &start("primary", "turn")),
        Err(CodexBindingError::Closed)
    );
}
