use super::*;
use proto::*;

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
