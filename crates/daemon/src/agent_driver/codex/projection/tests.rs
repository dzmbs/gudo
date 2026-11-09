use super::*;

fn message(turn: &str, id: &str, text: &str) -> CodexLiveEvent {
    CodexLiveEvent::Item {
        turn: turn.into(),
        completed: true,
        item: CodexItem::AgentMessage {
            id: id.into(),
            text: text.into(),
        },
    }
}

#[test]
fn identical_provider_ids_in_different_turns_never_replace_previous_messages() {
    let mut projection = Projection::new("thread".into());
    projection
        .apply(message("first", "provider-id", "First turn"))
        .unwrap();
    projection
        .apply(message("second", "provider-id", "Second turn"))
        .unwrap();
    let snapshot = projection.snapshot(SNAPSHOT_ITEMS, None);
    assert_eq!(snapshot.items.len(), 2);
    assert_ne!(snapshot.items[0].id, snapshot.items[1].id);
    assert_eq!(projection.page(2, 100, None).unwrap().items.len(), 1);
}

#[test]
fn incremental_json_weight_accounts_for_quotes_controls_and_unicode() {
    let mut projection = Projection::new("thread".into());
    for text in ["plain ", "\"\\\n\0", "🧪"] {
        projection
            .apply(CodexLiveEvent::AssistantDelta {
                turn: "turn".into(),
                item: "item".into(),
                text: text.into(),
            })
            .unwrap();
        let expected: usize = projection
            .items
            .values()
            .map(|(_, item)| serde_json::to_vec(&item.body).unwrap().len())
            .sum();
        assert_eq!(projection.bytes, expected);
    }
    projection
        .apply(message("turn", "item", "authoritative final"))
        .unwrap();
    assert_eq!(projection.snapshot(SNAPSHOT_ITEMS, None).items.len(), 1);
    assert!(
        matches!(&projection.snapshot(SNAPSHOT_ITEMS, None).items[0].body, TimelineBody::Assistant { text, streaming: false } if text == "authoritative final")
    );
}

#[test]
fn unknown_tool_status_is_not_running_or_success_and_nonzero_exit_is_failed() {
    for (status, exit) in [("future-status", None), ("completed", Some(1))] {
        let (_, body) = body(
            CodexItem::CommandExecution {
                id: "command".into(),
                command: "false".into(),
                status: status.into(),
                aggregated_output: None,
                exit_code: exit,
                duration_ms: None,
            },
            true,
            "turn",
        );
        if exit.is_none() {
            assert!(matches!(body, TimelineBody::Notice { .. }));
        } else {
            assert!(matches!(
                body,
                TimelineBody::Tool(TimelineTool {
                    status: TimelineToolStatus::Failed,
                    ..
                })
            ));
        }
    }
}

#[test]
fn a_long_conversation_forgets_its_oldest_items_instead_of_closing_chat() {
    let mut projection = Projection::new("thread".into());
    for index in 0..MAX_ITEMS + 10 {
        projection
            .apply(message("turn", &index.to_string(), "bounded"))
            .unwrap();
    }
    assert_eq!(projection.items.len(), MAX_ITEMS);
    let newest = projection.snapshot(1, None);
    assert!(
        matches!(&newest.items[0].body, TimelineBody::Assistant { text, .. } if text == "bounded")
    );
    let text = "x".repeat(MAX_TEXT / 2);
    for index in 0..8 {
        projection
            .apply(message("large", &index.to_string(), &text))
            .unwrap();
    }
    assert!(projection.bytes <= MAX_BYTES);
    assert_eq!(projection.order.len(), projection.items.len());
}

#[test]
fn an_oversized_message_becomes_a_terminal_notice_and_streaming_continues() {
    let mut projection = Projection::new("thread".into());
    let chunk = "x".repeat(MAX_TEXT / 2);
    for _ in 0..3 {
        projection
            .apply(CodexLiveEvent::AssistantDelta {
                turn: "turn".into(),
                item: "item".into(),
                text: chunk.clone(),
            })
            .unwrap();
    }
    projection
        .apply(message("turn", "item", &"y".repeat(MAX_TEXT + 1)))
        .unwrap();
    projection
        .apply(message("turn", "next", "still streaming"))
        .unwrap();
    let snapshot = projection.snapshot(SNAPSHOT_ITEMS, None);
    assert!(matches!(
        &snapshot.items[0].body,
        TimelineBody::Notice {
            kind: TimelineNoticeKind::Error,
            ..
        }
    ));
    assert!(
        matches!(&snapshot.items[1].body, TimelineBody::Assistant { text, .. } if text == "still streaming")
    );
    projection.skipped().unwrap();
    assert_eq!(projection.snapshot(SNAPSHOT_ITEMS, None).items.len(), 3);
}
