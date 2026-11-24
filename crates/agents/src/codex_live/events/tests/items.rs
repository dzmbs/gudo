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

fn replay(source: &str) -> Vec<CodexLiveEvent> {
    let fixture: Value = serde_json::from_str(source).unwrap();
    let mut connection = CodexBinding::default();
    connection
        .observe_tui(&fixture["request"].to_string())
        .unwrap();
    connection
        .observe_server(&fixture["response"].to_string())
        .unwrap();
    let mut stream = CodexLiveEvents::new(connection.binding().unwrap().clone());
    fixture["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|frame| stream.observe(&connection, &frame.to_string()).unwrap())
        .collect()
}

#[test]
fn tool_items_plans_usage_and_errors_are_typed() {
    use super::super::super::{CodexFileChangeKind, CodexItem};
    let events = replay(include_str!(
        "../../../../tests/fixtures/codex-live/pane-items.json"
    ));
    let completed: Vec<&CodexItem> = events
        .iter()
        .filter_map(|event| match event {
            CodexLiveEvent::Item {
                item,
                completed: true,
                ..
            } => Some(item),
            _ => None,
        })
        .collect();
    assert!(
        matches!(completed[0], CodexItem::FileChange { changes, status, .. }
        if status == "completed" && changes.len() == 2
            && changes[0].kind == CodexFileChangeKind::Update { move_path: None }
            && changes[1].kind == CodexFileChangeKind::Add
            && changes[0].diff.contains("+    let end = len - 1;"))
    );
    assert!(
        matches!(completed[1], CodexItem::McpToolCall { server, tool, duration_ms: Some(42), .. }
        if server == "docs" && tool == "search")
    );
    assert!(
        matches!(completed[2], CodexItem::WebSearch { query, .. } if query == "rust slice end")
    );
    assert!(
        matches!(completed[3], CodexItem::ImageView { path, .. } if path == "/fixture/screenshot.png")
    );
    assert!(
        matches!(completed[4], CodexItem::CollabAgentToolCall { tool, receiver_thread_ids, .. }
        if tool == "spawnAgent" && receiver_thread_ids.len() == 1)
    );
    assert!(matches!(completed[5], CodexItem::ContextCompaction { .. }));
    assert!(events.iter().any(|event| matches!(event,
        CodexLiveEvent::PlanUpdated { plan, .. } if plan.len() == 3 && plan[1].step == "Fix the off-by-one")));
    assert!(events.iter().any(|event| matches!(event,
        CodexLiveEvent::TokenUsage { usage, .. }
            if usage.total.input_tokens == 12000 && usage.last.input_tokens == 6000
                && usage.model_context_window == Some(258_400))));
    assert!(events.iter().any(|event| matches!(event,
        CodexLiveEvent::Error { will_retry: true, message, .. } if message == "Reconnecting... 1/5")));
    assert!(matches!(events.last(), Some(CodexLiveEvent::TurnCompleted {
        outcome: CodexTurnOutcome::Failed, error: Some(message), duration_ms: Some(3150), .. })
        if message == "Usage limit reached. Try again later."));
}
