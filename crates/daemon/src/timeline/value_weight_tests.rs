use super::*;
use proto::*;

#[test]
fn cached_update_bounds_cover_all_operations_and_session_metadata() {
    let text = "λ\0\"\\".repeat(128);
    let cursor = TimelineCursor {
        epoch: u64::MAX,
        sequence: u64::MAX,
    };
    let session = TimelineSession {
        agent: AgentKind::Claude,
        native_session: text.clone(),
        title: Some(text.clone()),
        model: Some(text.clone()),
        permission_mode: Some(TimelinePermissionMode::BypassPermissions),
        commands: vec![
            TimelineCommand {
                name: text.clone(),
                description: text.clone(),
                source: TimelineCommandSource::Project
            };
            200
        ],
    };
    let value = TimelineItem {
        id: text.clone(),
        revision: u32::MAX,
        turn: Some(text.clone()),
        parent: Some(text.clone()),
        at: UnixMillis(u64::MAX),
        origin: TimelineOrigin::Agent,
        body: TimelineBody::TurnEnd {
            duration_ms: u64::MAX,
            input_tokens: Some(u64::MAX),
            output_tokens: Some(u64::MAX),
        },
    };
    let operations = vec![
        TimelineOp::Snapshot(TimelineSnapshot {
            cursor,
            session: session.clone(),
            items: vec![value.clone(); 8],
            before: Some(u64::MAX),
        }),
        TimelineOp::Upsert {
            cursor,
            item: Box::new(value),
        },
        TimelineOp::Append {
            cursor,
            id: text.clone(),
            field: TimelineField::Thinking,
            text: text.clone(),
        },
        TimelineOp::Remove {
            cursor,
            id: text.clone(),
        },
        TimelineOp::Session { cursor, session },
        TimelineOp::Unavailable { message: text },
        TimelineOp::Checkpoint { cursor },
    ];
    assert!(postcard::to_allocvec(&operations).unwrap().len() <= super::operations(&operations));
    let update = TimelineUpdate {
        pane_id: PaneId(u64::MAX),
        operations,
    };
    assert!(postcard::to_allocvec(&update).unwrap().len() <= super::update(&update));
}

#[test]
fn cached_bounds_cover_every_body_and_nested_wire_value() {
    let text = "λ\0\"\\".repeat(512);
    let tool = TimelineTool {
        kind: TimelineToolKind::Other,
        name: text.clone(),
        title: text.clone(),
        input: text.clone(),
        status: TimelineToolStatus::Interrupted,
        output: Some(TimelineOutputRef {
            handle: OutputHandle::new(u64::MAX, u64::MAX, "tool:λ:part").unwrap(),
            preview: text.clone(),
            bytes: u64::MAX,
        }),
        diff: vec![
            FileDiff {
                path: text.clone(),
                old_path: Some(text.clone()),
                change: FileChange::Renamed,
                binary: false,
                additions: u32::MAX,
                deletions: u32::MAX,
                hunks_omitted: false,
                hunks: vec![
                    Hunk {
                        old_start: u32::MAX,
                        old_lines: u32::MAX,
                        new_start: u32::MAX,
                        new_lines: u32::MAX,
                        header: text.clone(),
                        lines: vec![
                            DiffLine {
                                kind: LineKind::Added,
                                text: text.clone()
                            };
                            20
                        ],
                    };
                    8
                ],
            };
            6
        ],
        exit: Some(i32::MIN),
        duration_ms: Some(u64::MAX),
        command_mark: Some(u64::MAX),
    };
    let bodies = [
        TimelineBody::User {
            text: text.clone(),
            queued: true,
            attachments: vec![
                TimelineAttachment {
                    path: text.clone(),
                    media_type: Some(text.clone()),
                };
                20
            ],
        },
        TimelineBody::Assistant {
            text: text.clone(),
            streaming: true,
        },
        TimelineBody::Thinking {
            text: Some(text.clone()),
            duration_ms: Some(u64::MAX),
        },
        TimelineBody::Tool(tool),
        TimelineBody::Plan {
            entries: vec![
                TimelinePlanEntry {
                    text: text.clone(),
                    status: TimelinePlanStatus::Completed
                };
                200
            ],
        },
        TimelineBody::Notice {
            kind: TimelineNoticeKind::Error,
            text: text.clone(),
        },
        TimelineBody::TurnEnd {
            duration_ms: u64::MAX,
            input_tokens: Some(u64::MAX),
            output_tokens: Some(u64::MAX),
        },
        TimelineBody::Unsupported,
    ];
    for body in bodies {
        let value = TimelineItem {
            id: text.clone(),
            revision: u32::MAX,
            turn: Some(text.clone()),
            parent: Some(text.clone()),
            at: UnixMillis(u64::MAX),
            origin: TimelineOrigin::Agent,
            body,
        };
        let encoded = postcard::to_allocvec(&value).unwrap();
        assert!(
            encoded.len() <= item(&value),
            "wire {} exceeds cached {}",
            encoded.len(),
            item(&value)
        );
    }
}
