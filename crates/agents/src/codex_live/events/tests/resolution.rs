use super::*;

fn waiting(identifier: Value, turn: &str) -> String {
    json!({"id":identifier,"method":"item/commandExecution/requestApproval","params":{"threadId":"primary","turnId":turn,"itemId":"command"}}).to_string()
}

fn resolved(thread: &str, identifier: Value) -> String {
    json!({"method":"serverRequest/resolved","params":{"threadId":thread,"requestId":identifier}})
        .to_string()
}

#[test]
fn resolution_is_scoped_to_the_exact_pending_identity_and_is_once_only() {
    let connection = connection("primary");
    let mut stream = CodexLiveEvents::new(connection.binding().unwrap().clone());
    stream
        .observe(&connection, &start("primary", "turn"))
        .unwrap();
    stream
        .observe(&connection, &waiting(json!(7), "turn"))
        .unwrap();
    for frame in [
        resolved("title", json!(7)),
        resolved("primary", json!("7")),
        resolved("primary", json!(8)),
    ] {
        assert!(stream.observe(&connection, &frame).unwrap().is_none());
    }
    let event = stream
        .observe(&connection, &resolved("primary", json!(7)))
        .unwrap();
    assert_eq!(
        event,
        Some(CodexLiveEvent::ApprovalResolved {
            request: RpcId::Integer(7),
            turn: "turn".into(),
            item: "command".into(),
            kind: CodexApprovalKind::Command,
        })
    );
    assert!(
        stream
            .observe(&connection, &resolved("primary", json!(7)))
            .unwrap()
            .is_none()
    );
    assert!(
        stream
            .observe(&connection, &waiting(json!(7), "turn"))
            .unwrap()
            .is_none()
    );
}

#[test]
fn old_turn_resolution_cannot_unblock_the_current_turn() {
    let connection = connection("primary");
    let mut stream = CodexLiveEvents::new(connection.binding().unwrap().clone());
    stream
        .observe(&connection, &start("primary", "first"))
        .unwrap();
    stream
        .observe(&connection, &waiting(json!(7), "first"))
        .unwrap();
    stream
        .observe(&connection, &complete("primary", "first", "interrupted"))
        .unwrap();
    stream
        .observe(&connection, &start("primary", "second"))
        .unwrap();
    stream
        .observe(&connection, &waiting(json!(8), "second"))
        .unwrap();
    assert!(
        stream
            .observe(&connection, &resolved("primary", json!(7)))
            .unwrap()
            .is_none()
    );
    assert!(
        matches!(stream.observe(&connection, &resolved("primary", json!(8))).unwrap(), Some(CodexLiveEvent::ApprovalResolved { turn, .. }) if turn == "second")
    );
}

#[test]
fn reused_request_ids_fail_closed_instead_of_resolving_a_different_request() {
    let connection = connection("primary");
    let mut stream = CodexLiveEvents::new(connection.binding().unwrap().clone());
    stream
        .observe(&connection, &start("primary", "first"))
        .unwrap();
    stream
        .observe(&connection, &waiting(json!(7), "first"))
        .unwrap();
    stream
        .observe(&connection, &start("primary", "second"))
        .unwrap();
    assert!(
        stream
            .observe(&connection, &waiting(json!(7), "second"))
            .is_err()
    );
}

#[test]
fn changed_approval_metadata_cannot_reuse_an_admitted_native_identity() {
    let connection = connection("primary");
    let mut stream = CodexLiveEvents::new(connection.binding().unwrap().clone());
    stream
        .observe(&connection, &start("primary", "turn"))
        .unwrap();
    let mut frame: Value = serde_json::from_str(&waiting(json!(7), "turn")).unwrap();
    frame["params"]["command"] = json!("printf allowed");
    frame["params"]["cwd"] = json!("/fixture");
    frame["params"]["availableDecisions"] = json!(["accept", "cancel"]);
    let Some(CodexLiveEvent::ApprovalWaiting { details, .. }) =
        stream.observe(&connection, &frame.to_string()).unwrap()
    else {
        panic!("missing approval");
    };
    assert_eq!(details.command.as_deref(), Some("printf allowed"));
    assert!(
        stream
            .observe(&connection, &frame.to_string())
            .unwrap()
            .is_none()
    );
    frame["params"]["command"] = json!("printf different");
    assert!(stream.observe(&connection, &frame.to_string()).is_err());
}
