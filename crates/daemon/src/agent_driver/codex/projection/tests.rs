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

fn user(turn: &str, id: &str, parts: &[&str]) -> CodexLiveEvent {
    CodexLiveEvent::Item {
        turn: turn.into(),
        completed: true,
        item: CodexItem::UserMessage {
            id: id.into(),
            content: parts
                .iter()
                .map(|text| CodexInput::Text {
                    text: (*text).into(),
                })
                .collect(),
        },
    }
}

fn bodies(projection: &Projection) -> Vec<TimelineBody> {
    projection
        .snapshot(SNAPSHOT_ITEMS, None)
        .items
        .into_iter()
        .map(|item| item.body)
        .collect()
}

fn is_preview_of(text: &str, head: &str, tail: &str, total_bytes: usize) -> bool {
    text.starts_with(head)
        && text.ends_with(tail)
        && text.len() < total_bytes
        && text.contains(&describe_size(total_bytes))
        && text.contains("Terminal")
}

#[test]
fn an_oversized_message_keeps_its_start_and_end_and_streaming_continues() {
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
    assert!(
        matches!(&bodies(&projection)[..], [TimelineBody::Assistant { text, .. }] if is_preview_of(text, "xxx", "xxx", chunk.len() * 3))
    );
    let final_text = format!("start{}end", "y".repeat(MAX_TEXT));
    projection
        .apply(message("turn", "item", &final_text))
        .unwrap();
    projection
        .apply(message("turn", "next", "still streaming"))
        .unwrap();
    let bodies = bodies(&projection);
    assert!(
        matches!(&bodies[0], TimelineBody::Assistant { text, streaming: false } if is_preview_of(text, "start", "end", final_text.len()))
    );
    assert!(
        matches!(&bodies[1], TimelineBody::Assistant { text, .. } if text == "still streaming")
    );
    assert!(projection.bytes <= MAX_BYTES);
}

#[test]
fn an_oversized_command_keeps_a_bounded_title_and_input() {
    let command = format!("cat <<EOF{}EOF", "z".repeat(MAX_TEXT));
    let mut projection = Projection::new("thread".into());
    projection
        .apply(CodexLiveEvent::Item {
            turn: "turn".into(),
            completed: true,
            item: CodexItem::CommandExecution {
                id: "command".into(),
                command: command.clone(),
                status: "completed".into(),
                aggregated_output: Some("done".into()),
                exit_code: Some(0),
                duration_ms: None,
            },
        })
        .unwrap();
    assert!(matches!(
        &bodies(&projection)[..],
        [TimelineBody::Tool(TimelineTool { title, input, status: TimelineToolStatus::Done, .. })]
            if is_preview_of(title, "cat <<EOF", "EOF", command.len())
                && input.starts_with("cat <<EOF")
                && input.ends_with("done")
    ));
}

#[test]
fn a_skipped_item_is_marked_where_it_belongs_and_a_later_copy_replaces_it() {
    let mut projection = Projection::new("thread".into());
    projection
        .apply(message("turn", "before", "before"))
        .unwrap();
    projection.skipped("turn".into(), "huge").unwrap();
    assert!(matches!(
        &bodies(&projection)[1],
        TimelineBody::Notice { kind: TimelineNoticeKind::Error, text } if text == TOO_LARGE
    ));
    projection.apply(message("turn", "huge", "fits")).unwrap();
    assert!(
        matches!(&bodies(&projection)[..], [_, TimelineBody::Assistant { text, .. }] if text == "fits")
    );
}

#[test]
fn context_codex_injects_as_user_messages_is_not_a_user_row() {
    let mut projection = Projection::new("thread".into());
    for (index, parts) in [
        &["# AGENTS.md instructions for /project\n\n<INSTRUCTIONS>\nbody\n</INSTRUCTIONS>"][..],
        &["<environment_context>\n  <cwd>/project</cwd>\n</environment_context>"],
        &["<user_instructions>\nbe brief\n</user_instructions>\n"],
        &[
            "<ENVIRONMENT_CONTEXT>x</ENVIRONMENT_CONTEXT>",
            "<turn_aborted>\nstopped\n</turn_aborted>",
        ],
    ]
    .into_iter()
    .enumerate()
    {
        let operations = projection
            .apply(user("turn", &index.to_string(), parts))
            .unwrap();
        assert!(operations.is_empty(), "{parts:?}");
    }
    projection
        .apply(user(
            "turn",
            "typed",
            &[
                "<environment_context>x</environment_context>",
                "What changed?",
            ],
        ))
        .unwrap();
    projection
        .apply(user(
            "turn",
            "quoted",
            &["Why does <environment_context> exist?"],
        ))
        .unwrap();
    assert!(matches!(
        &bodies(&projection)[..],
        [TimelineBody::User { .. }, TimelineBody::User { .. }]
    ));
}
