use proto::*;
use serde::{Serialize, de::DeserializeOwned};

fn frozen<T>(value: T, expected: &[u8])
where
    T: Serialize + DeserializeOwned + PartialEq + std::fmt::Debug,
{
    let encoded = postcard::to_allocvec(&value).unwrap();
    assert_eq!(encoded, expected);
    assert_eq!(postcard::from_bytes::<T>(&encoded).unwrap(), value);
}

fn session() -> TimelineSession {
    TimelineSession {
        agent: AgentKind::Claude,
        native_session: "s".into(),
        title: None,
        model: None,
        permission_mode: None,
        commands: Vec::new(),
    }
}

fn snapshot() -> TimelineSnapshot {
    TimelineSnapshot {
        cursor: TimelineCursor {
            epoch: 1,
            sequence: 2,
        },
        session: session(),
        items: Vec::new(),
        before: None,
    }
}

#[test]
fn timeline_requests_and_capabilities_keep_their_wire_bytes() {
    frozen(Caps::AGENT_TIMELINE, &[128, 128, 128, 64]);
    frozen(DaemonFeatures::AGENT_TIMELINE, &[128, 128, 128, 8]);
    frozen(
        WorkspaceRequest::TimelineWatch { pane_id: PaneId(7) },
        &[62, 7],
    );
    frozen(
        WorkspaceRequest::TimelineUnwatch { pane_id: PaneId(7) },
        &[63, 7],
    );
    frozen(
        WorkspaceRequest::TimelineItemsBefore {
            pane_id: PaneId(7),
            before: 900,
            limit: 100,
        },
        &[64, 7, 132, 7, 100],
    );
    frozen(
        WorkspaceRequest::TimelineToolOutput {
            pane_id: PaneId(7),
            handle: "x".into(),
            offset: 300,
            len: 64,
        },
        &[65, 7, 1, 120, 172, 2, 64],
    );
}

#[test]
fn timeline_responses_and_pushes_keep_their_wire_bytes() {
    frozen(
        WorkspaceResponse::Timeline(snapshot()),
        &[35, 1, 2, 0, 1, 115, 0, 0, 0, 0, 0, 0],
    );
    frozen(
        WorkspaceResponse::TimelineOutput(TimelineToolOutput {
            text: "x".into(),
            next_offset: None,
            total_bytes: 1,
        }),
        &[36, 1, 120, 0, 1],
    );
    frozen(
        ServerCtl::Timeline(TimelineUpdate {
            pane_id: PaneId(7),
            operations: vec![TimelineOp::Unavailable {
                message: "u".into(),
            }],
        }),
        &[63, 7, 1, 5, 1, 117],
    );
}

#[test]
fn timeline_operations_keep_their_wire_bytes() {
    let cursor = TimelineCursor {
        epoch: 1,
        sequence: 2,
    };
    frozen(
        TimelineOp::Snapshot(snapshot()),
        &[0, 1, 2, 0, 1, 115, 0, 0, 0, 0, 0, 0],
    );
    frozen(
        TimelineOp::Upsert {
            cursor,
            item: TimelineItem {
                id: "id".into(),
                revision: 1,
                turn: None,
                parent: None,
                at: UnixMillis(0),
                origin: TimelineOrigin::Agent,
                body: TimelineBody::Assistant {
                    text: "x".into(),
                    streaming: false,
                },
            },
        },
        &[1, 1, 2, 2, 105, 100, 1, 0, 0, 0, 2, 1, 1, 120, 0],
    );
    frozen(
        TimelineOp::Append {
            cursor,
            id: "id".into(),
            field: TimelineField::Text,
            text: "x".into(),
        },
        &[2, 1, 2, 2, 105, 100, 0, 1, 120],
    );
    frozen(
        TimelineOp::Remove {
            cursor,
            id: "id".into(),
        },
        &[3, 1, 2, 2, 105, 100],
    );
    frozen(
        TimelineOp::Session {
            cursor,
            session: session(),
        },
        &[4, 1, 2, 0, 1, 115, 0, 0, 0, 0],
    );
    frozen(TimelineOp::Checkpoint { cursor }, &[6, 1, 2]);
}

#[test]
fn timeline_bodies_keep_their_wire_bytes() {
    frozen(
        TimelineBody::User {
            text: String::new(),
            attachments: Vec::new(),
            queued: false,
        },
        &[0, 0, 0, 0],
    );
    frozen(
        TimelineBody::Assistant {
            text: "x".into(),
            streaming: true,
        },
        &[1, 1, 120, 1],
    );
    frozen(
        TimelineBody::Thinking {
            text: None,
            duration_ms: Some(12),
        },
        &[2, 0, 1, 12],
    );
    frozen(
        TimelineBody::Tool(TimelineTool {
            kind: TimelineToolKind::Shell,
            name: "run".into(),
            title: String::new(),
            input: "{}".into(),
            status: TimelineToolStatus::Done,
            output: None,
            diff: Vec::new(),
            exit: Some(0),
            duration_ms: None,
            command_mark: None,
        }),
        &[3, 0, 3, 114, 117, 110, 0, 2, 123, 125, 1, 0, 0, 1, 0, 0, 0],
    );
    frozen(
        TimelineBody::Plan {
            entries: vec![TimelinePlanEntry {
                text: "t".into(),
                status: TimelinePlanStatus::Completed,
            }],
        },
        &[4, 1, 1, 116, 2],
    );
    frozen(
        TimelineBody::Notice {
            kind: TimelineNoticeKind::Compacted,
            text: "c".into(),
        },
        &[5, 0, 1, 99],
    );
    frozen(
        TimelineBody::TurnEnd {
            duration_ms: 5,
            input_tokens: Some(7),
            output_tokens: Some(8),
        },
        &[6, 5, 1, 7, 1, 8],
    );
}
