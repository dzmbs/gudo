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
    let snapshot = projection.snapshot(60, None);
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
    assert_eq!(projection.snapshot(60, None).items.len(), 1);
    assert!(
        matches!(&projection.snapshot(60, None).items[0].body, TimelineBody::Assistant { text, streaming: false } if text == "authoritative final")
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
fn projection_bounds_fail_instead_of_silently_losing_older_history() {
    let mut projection = Projection::new("thread".into());
    for index in 0..MAX_ITEMS {
        projection
            .apply(message("turn", &index.to_string(), "bounded"))
            .unwrap();
    }
    assert!(
        projection
            .apply(message("turn", "too-many", "bounded"))
            .is_err()
    );
}
