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
            Location::live(0),
        )
        .unwrap();
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

fn long_text(body: &TimelineBody) -> Option<(TimelineTextRole, &TimelineOutputRef)> {
    match body {
        TimelineBody::LongText { role, content } => Some((*role, content)),
        _ => None,
    }
}

#[test]
fn a_long_reply_shows_its_start_and_pages_the_rest_while_streaming_and_when_complete() {
    let mut projection = Projection::new("thread".into());
    let chunk = "x".repeat(LONG_TEXT_BYTES / 2);
    for _ in 0..3 {
        projection
            .apply(CodexLiveEvent::AssistantDelta {
                turn: "turn".into(),
                item: "item".into(),
                text: chunk.clone(),
            })
            .unwrap();
    }
    let streaming = bodies(&projection);
    let (role, content) = long_text(&streaming[0]).unwrap();
    assert_eq!(role, TimelineTextRole::Assistant);
    assert_eq!(content.bytes, 3 * chunk.len() as u64);
    assert!(content.preview.len() <= PREVIEW_BYTES && chunk.starts_with(&content.preview));
    assert_eq!(content.handle.id(), item_id("turn", "item"));
    assert_eq!(content.handle.epoch(), projection.cursor().epoch);
    assert_eq!(content.handle.offset(), 0);

    let final_text = format!("start{}end", "y".repeat(4 * LONG_TEXT_BYTES));
    projection
        .apply(message("turn", "item", &final_text))
        .unwrap();
    projection
        .apply(message("turn", "next", "still streaming"))
        .unwrap();
    let bodies = bodies(&projection);
    let (_, content) = long_text(&bodies[0]).unwrap();
    assert_eq!(content.bytes, final_text.len() as u64);
    assert!(content.preview.starts_with("start") && final_text.starts_with(&content.preview));
    assert!(
        matches!(&bodies[1], TimelineBody::Assistant { text, .. } if text == "still streaming")
    );
    assert!(projection.bytes <= MAX_BYTES);
}

#[test]
fn long_user_messages_and_thinking_page_like_replies() {
    let mut projection = Projection::new("thread".into());
    let text = "u".repeat(LONG_TEXT_BYTES + 1);
    projection.apply(user("turn", "typed", &[&text])).unwrap();
    projection
        .apply(CodexLiveEvent::Item {
            turn: "turn".into(),
            completed: true,
            item: CodexItem::Reasoning {
                id: "thought".into(),
                summary: vec![text.clone()],
                content: Vec::new(),
            },
        })
        .unwrap();
    let bodies = bodies(&projection);
    assert_eq!(
        long_text(&bodies[0]).map(|(role, content)| (role, content.bytes)),
        Some((TimelineTextRole::User, text.len() as u64))
    );
    assert_eq!(
        long_text(&bodies[1]).map(|(role, content)| (role, content.bytes)),
        Some((TimelineTextRole::Thinking, text.len() as u64))
    );
}

#[test]
fn a_command_keeps_its_output_behind_a_handle_with_the_end_as_preview() {
    let command = format!("cat <<EOF{}EOF", "z".repeat(4 * LONG_TEXT_BYTES));
    let output = format!("first{}last", "o".repeat(2 * LONG_TEXT_BYTES));
    let mut projection = Projection::new("thread".into());
    projection
        .apply(CodexLiveEvent::Item {
            turn: "turn".into(),
            completed: true,
            item: CodexItem::CommandExecution {
                id: "command".into(),
                command: command.clone(),
                status: "completed".into(),
                aggregated_output: Some(output.clone()),
                exit_code: Some(0),
                duration_ms: None,
            },
        })
        .unwrap();
    let bodies = bodies(&projection);
    let [TimelineBody::Tool(tool)] = &bodies[..] else {
        panic!("expected one command, got {bodies:?}");
    };
    assert_eq!(tool.status, TimelineToolStatus::Done);
    assert!(tool.title.len() <= TITLE_BYTES && command.starts_with(&tool.title));
    assert!(tool.input.len() <= INPUT_BYTES && command.starts_with(&tool.input));
    let reference = tool.output.as_ref().unwrap();
    assert_eq!(reference.bytes, output.len() as u64);
    assert!(reference.preview.ends_with("last") && reference.preview.len() <= 4096);
    assert_eq!(reference.handle.id(), item_id("turn", "command"));
}

#[test]
fn the_paged_text_of_an_item_is_exactly_what_its_preview_and_size_describe() {
    let reply = CodexItem::AgentMessage {
        id: "reply".into(),
        text: "é".repeat(LONG_TEXT_BYTES),
    };
    assert_eq!(paged_text(&reply).unwrap(), "é".repeat(LONG_TEXT_BYTES));
    let typed = CodexItem::UserMessage {
        id: "typed".into(),
        content: vec![
            CodexInput::Text {
                text: "look".into(),
            },
            CodexInput::Unsupported,
        ],
    };
    assert_eq!(
        paged_text(&typed).unwrap(),
        "look\n[Attachment available in Terminal]\n"
    );
    let thought = CodexItem::Reasoning {
        id: "thought".into(),
        summary: vec!["a".into()],
        content: vec!["b".into()],
    };
    assert_eq!(paged_text(&thought).unwrap(), "a\nb");
    let command = CodexItem::CommandExecution {
        id: "command".into(),
        command: "ls".into(),
        status: "completed".into(),
        aggregated_output: Some("out".into()),
        exit_code: Some(0),
        duration_ms: None,
    };
    assert_eq!(paged_text(&command).unwrap(), "out");
    assert_eq!(
        split_item_id(&item_id("turn:with:colons", "item")),
        Some(("turn:with:colons", "item"))
    );
    assert_eq!(split_item_id("turn:4:x"), None);
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

fn replayed(source: &str) -> Projection {
    let fixture: serde_json::Value = serde_json::from_str(source).unwrap();
    let mut connection = agents::CodexBinding::default();
    connection
        .observe_tui(&fixture["request"].to_string())
        .unwrap();
    connection
        .observe_server(&fixture["response"].to_string())
        .unwrap();
    let binding = connection.binding().unwrap().clone();
    let mut events = agents::CodexLiveEvents::new(binding.clone());
    let mut projection = Projection::new(binding.thread_id().into());
    for frame in fixture["events"].as_array().unwrap() {
        if let Some(event) = events.observe(&connection, &frame.to_string()).unwrap() {
            projection.apply(event).unwrap();
        }
    }
    projection
}

fn tools(bodies: &[TimelineBody]) -> Vec<&TimelineTool> {
    bodies
        .iter()
        .filter_map(|body| match body {
            TimelineBody::Tool(tool) => Some(tool),
            _ => None,
        })
        .collect()
}

#[test]
fn file_changes_tools_plans_usage_and_failures_are_rows_like_claude_turns() {
    let projection = replayed(include_str!(
        "../../../../../agents/tests/fixtures/codex-live/pane-items.json"
    ));
    let bodies = bodies(&projection);
    assert!(matches!(&bodies[0], TimelineBody::Plan { entries }
        if entries.len() == 3
            && entries[0].status == proto::TimelinePlanStatus::Completed
            && entries[1].status == proto::TimelinePlanStatus::InProgress
            && entries[1].text == "Fix the off-by-one"));
    let tools = tools(&bodies);
    let edit = tools[0];
    assert_eq!(
        (edit.kind, edit.status),
        (TimelineToolKind::Edit, TimelineToolStatus::Done)
    );
    assert_eq!(edit.diff.len(), 2);
    assert_eq!(edit.diff[0].path, "/fixture/src/parse.rs");
    assert_eq!((edit.diff[0].additions, edit.diff[0].deletions), (1, 1));
    assert_eq!(edit.diff[1].change, proto::FileChange::Added);
    assert!(edit.output.is_some());
    let mcp = tools[1];
    assert_eq!(mcp.kind, TimelineToolKind::Mcp);
    assert_eq!(mcp.name, "mcp__docs__search");
    assert_eq!(mcp.duration_ms, Some(42));
    assert!(mcp.input.contains("parser"));
    assert_eq!(
        mcp.output.as_ref().map(|output| output.preview.as_str()),
        Some("parse.rs: the parser")
    );
    assert_eq!(
        (tools[2].kind, tools[2].title.as_str()),
        (TimelineToolKind::WebSearch, "rust slice end")
    );
    assert_eq!(
        (tools[3].kind, tools[3].title.as_str()),
        (TimelineToolKind::Read, "/fixture/screenshot.png")
    );
    let agent = tools[4];
    assert_eq!(agent.kind, TimelineToolKind::Task);
    assert_eq!(agent.title, "Check the tests");
    assert_eq!(
        agent.output.as_ref().map(|output| output.preview.as_str()),
        Some("All tests pass.")
    );
    assert!(bodies.iter().any(|body| matches!(
        body,
        TimelineBody::Notice {
            kind: TimelineNoticeKind::Compacted,
            ..
        }
    )));
    assert!(bodies.iter().any(|body| matches!(body,
        TimelineBody::Notice { kind: TimelineNoticeKind::Retry, text } if text == "Reconnecting... 1/5")));
    assert!(bodies.iter().any(|body| matches!(body,
        TimelineBody::Notice { kind: TimelineNoticeKind::Error, text }
            if text == "Usage limit reached. Try again later.")));
    assert!(matches!(
        bodies.last(),
        Some(TimelineBody::TurnEnd {
            duration_ms: 3150,
            input_tokens: Some(12000),
            output_tokens: Some(900),
        })
    ));
    assert!(bodies.iter().all(|body| !matches!(body,
        TimelineBody::Notice { text, .. } if text.contains("available in Terminal"))));
    assert_eq!(
        projection.context(),
        Some(ContextUsage {
            used: 6400,
            window: 258_400
        })
    );
}

#[test]
fn a_users_attached_images_are_attachments_not_terminal_markers() {
    let mut projection = Projection::new("thread".into());
    projection
        .apply(CodexLiveEvent::Item {
            turn: "turn".into(),
            completed: true,
            item: CodexItem::UserMessage {
                id: "user".into(),
                content: vec![
                    CodexInput::Text {
                        text: "What is wrong here?".into(),
                    },
                    CodexInput::LocalImage {
                        path: "/host/send/shot@1.png".into(),
                    },
                ],
            },
        })
        .unwrap();
    assert!(
        matches!(&bodies(&projection)[0], TimelineBody::User { text, attachments, .. }
        if text == "What is wrong here?"
            && attachments.len() == 1
            && attachments[0].path == "/host/send/shot@1.png"
            && attachments[0].media_type.as_deref() == Some("image/png"))
    );
}
