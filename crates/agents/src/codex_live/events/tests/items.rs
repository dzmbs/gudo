use super::*;

#[test]
fn current_items_are_typed_and_foreign_or_stale_items_are_ignored() {
    let connection = connection("primary");
    let mut events = CodexLiveEvents::new(connection.binding().unwrap().clone());
    events
        .observe(&connection, &start("primary", "turn"))
        .unwrap();
    let mut item = json!({"method":"item/completed", "params":{"threadId":"primary", "turnId":"turn",
        "item":{"type":"agentMessage", "id":"message", "text":"final"}}});
    assert!(
        matches!(events.observe(&connection, &item.to_string()).unwrap(), Some(CodexLiveEvent::Item {
        item: super::super::super::CodexItem::AgentMessage { text, .. }, completed: true, .. }) if text == "final")
    );
    item["params"]["threadId"] = json!("other-pane");
    assert!(
        events
            .observe(&connection, &item.to_string())
            .unwrap()
            .is_none()
    );
    item["params"]["threadId"] = json!("primary");
    item["params"]["turnId"] = json!("old-turn");
    assert!(
        events
            .observe(&connection, &item.to_string())
            .unwrap()
            .is_none()
    );
}

#[test]
fn oversized_item_identity_permanently_closes_native_events() {
    let connection = connection("primary");
    let mut events = CodexLiveEvents::new(connection.binding().unwrap().clone());
    events
        .observe(&connection, &start("primary", "turn"))
        .unwrap();
    let item = json!({"method":"item/started", "params":{"threadId":"primary", "turnId":"turn",
        "item":{"type":"agentMessage", "id":"x".repeat(129), "text":""}}});
    assert!(events.observe(&connection, &item.to_string()).is_err());
    assert!(
        events
            .observe(&connection, &start("primary", "next"))
            .is_err()
    );
}
