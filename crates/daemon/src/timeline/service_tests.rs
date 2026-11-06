use super::*;
use proto::{TimelineBody, TimelineField, TimelineItem, TimelineOrigin};

fn session() -> TimelineSession {
    TimelineSession {
        agent: AgentKind::Claude,
        native_session: "test".into(),
        title: None,
        model: None,
        permission_mode: None,
        commands: Vec::new(),
    }
}

fn cursor(sequence: u64) -> TimelineCursor {
    TimelineCursor { epoch: 7, sequence }
}

fn snapshot(sequence: u64) -> TimelineSnapshot {
    TimelineSnapshot {
        cursor: cursor(sequence),
        session: session(),
        items: Vec::new(),
        before: None,
    }
}

fn item(id: &str, at: u64) -> TimelineItem {
    TimelineItem {
        id: id.into(),
        revision: 1,
        turn: None,
        parent: None,
        at: UnixMillis(at),
        origin: TimelineOrigin::Agent,
        body: TimelineBody::Assistant {
            text: "Text".into(),
            streaming: false,
        },
    }
}

fn update(sequence: u64) -> TimelineUpdate {
    TimelineUpdate {
        pane_id: PaneId(1),
        operations: vec![TimelineOp::Checkpoint {
            cursor: cursor(sequence),
        }],
    }
}

#[test]
fn a_slow_reader_keeps_one_current_snapshot_instead_of_an_unbounded_delta_queue() {
    let mailbox = Mailbox::default();
    mailbox.register(PaneId(1), 42);
    for sequence in 1..10_000 {
        mailbox.push(42, update(sequence), || snapshot(sequence));
    }
    let messages = mailbox.take();
    assert_eq!(messages.len(), 1);
    let ServerCtl::Timeline(received) = &messages[0] else {
        panic!()
    };
    assert!(
        matches!(&received.operations[0], TimelineOp::Snapshot(snapshot) if snapshot.cursor == cursor(9999))
    );
    assert!(mailbox.take().is_empty());
    mailbox.push(42, update(10_000), || panic!("no pending update"));
    assert_eq!(mailbox.take(), vec![ServerCtl::Timeline(update(10_000))]);
}

#[test]
fn old_forwarders_cannot_publish_after_unwatch_or_replace_the_current_watch() {
    let mailbox = Mailbox::default();
    mailbox.register(PaneId(1), 10);
    mailbox.push(10, update(1), || snapshot(1));
    mailbox.remove(PaneId(1));
    mailbox.push(10, update(2), || panic!("unwatched"));
    assert!(mailbox.take().is_empty());
    mailbox.register(PaneId(1), 11);
    mailbox.push(10, update(3), || panic!("replaced"));
    assert!(mailbox.take().is_empty());
    mailbox.push(11, update(4), || snapshot(4));
    assert_eq!(mailbox.take(), vec![ServerCtl::Timeline(update(4))]);
    mailbox.clear();
    mailbox.push(11, update(5), || panic!("disconnected"));
    assert!(mailbox.take().is_empty());
}

#[test]
fn a_large_push_is_replaced_by_a_bounded_snapshot_before_encoding_on_ctl() {
    let mailbox = Mailbox::default();
    mailbox.register(PaneId(1), 42);
    let mut operations = Vec::new();
    for sequence in 1..=10 {
        let mut item = item(&format!("item-{sequence}"), 0);
        item.body = TimelineBody::Assistant {
            text: "a".repeat(256 * 1024),
            streaming: false,
        };
        operations.push(TimelineOp::Upsert {
            cursor: cursor(sequence),
            item,
        });
    }
    mailbox.push(
        42,
        TimelineUpdate {
            pane_id: PaneId(1),
            operations,
        },
        || snapshot(10),
    );
    let messages = mailbox.take();
    assert!(
        matches!(&messages[0], ServerCtl::Timeline(TimelineUpdate { operations, .. }) if matches!(&operations[0], TimelineOp::Snapshot(snapshot) if snapshot.cursor == cursor(10)))
    );
    let mut encoded = Vec::new();
    proto::frame::encode(&messages[0], &mut encoded).unwrap();
    assert!(encoded.len() < MAX_PUSH_BYTES);
}

#[test]
fn failure_notes_are_not_hidden_by_backpressure_coalescing() {
    let mailbox = Mailbox::default();
    mailbox.register(PaneId(1), 42);
    mailbox.push(42, update(1), || snapshot(1));
    let failure = TimelineUpdate {
        pane_id: PaneId(1),
        operations: vec![TimelineOp::Unavailable {
            message: "Open Terminal".into(),
        }],
    };
    mailbox.push(42, failure.clone(), || panic!("preserve failure"));
    assert_eq!(mailbox.take(), vec![ServerCtl::Timeline(failure)]);
}

#[test]
fn since_join_filtering_advances_the_cursor_without_exposing_hidden_items() {
    let operations = vec![
        TimelineOp::Upsert {
            cursor: cursor(1),
            item: item("old", 1),
        },
        TimelineOp::Upsert {
            cursor: cursor(2),
            item: item("new", 11),
        },
        TimelineOp::Append {
            cursor: cursor(3),
            id: "old".into(),
            field: TimelineField::Text,
            text: "private".into(),
        },
        TimelineOp::Append {
            cursor: cursor(4),
            id: "new".into(),
            field: TimelineField::Text,
            text: "visible".into(),
        },
    ];
    let mut visible = HashSet::new();
    let filtered = filter(operations, Some(UnixMillis(10)), &mut visible);
    assert_eq!(filtered[0], TimelineOp::Checkpoint { cursor: cursor(1) });
    assert!(matches!(&filtered[1], TimelineOp::Upsert { item, .. } if item.id == "new"));
    assert_eq!(filtered[2], TimelineOp::Checkpoint { cursor: cursor(3) });
    assert!(matches!(&filtered[3], TimelineOp::Append { text, .. } if text == "visible"));
    assert_eq!(visible, HashSet::from(["new".into()]));
    assert!(
        !serde_json::to_string(&filtered)
            .unwrap()
            .contains("private")
    );
    let filtered = filter(
        vec![TimelineOp::Remove {
            cursor: cursor(5),
            id: "old".into(),
        }],
        Some(UnixMillis(10)),
        &mut visible,
    );
    assert_eq!(filtered, vec![TimelineOp::Checkpoint { cursor: cursor(5) }]);
}

#[test]
fn a_new_agent_pane_can_open_chat_before_its_first_transcript_exists() {
    let root = tempfile::tempdir().unwrap();
    let source = Source {
        native_session: "test".into(),
        path: None,
        config_directory: root.path().into(),
        working_directory: root.path().into(),
        watch_directory: root.path().into(),
    };
    let (wake, _) = mpsc::channel(1);
    let mut state = LiveState::new(source.clone(), 7, wake).unwrap();
    assert!(state.snapshot(None).items.is_empty());
    assert!(!state.snapshot(None).session.commands.is_empty());
    let path = root.path().join("test.jsonl");
    std::fs::write(
        &path,
        "{\"type\":\"user\",\"uuid\":\"first\",\"message\":{\"content\":\"Hello\"}}\n",
    )
    .unwrap();
    let mut ready = source;
    ready.path = Some(path);
    let operations = state.refresh(ready).unwrap();
    let TimelineOp::Snapshot(snapshot) = &operations[0] else {
        panic!()
    };
    assert_eq!(snapshot.cursor.epoch, 8);
    assert_eq!(snapshot.items[0].id, "first");
    assert!(!snapshot.session.commands.is_empty());
}

#[test]
fn bulk_replies_keep_their_budget_until_written_even_with_reused_request_ids() {
    let mailbox = Mailbox::default();
    for _ in 0..MAX_BULK_REQUESTS {
        mailbox.hold_reply(1, mailbox.reserve_reply().unwrap());
    }
    assert!(mailbox.reserve_reply().is_err());
    mailbox.reply_sent(99);
    assert!(mailbox.reserve_reply().is_err());
    mailbox.reply_sent(1);
    let permit = mailbox.reserve_reply().unwrap();
    assert!(mailbox.reserve_reply().is_err());
    mailbox.hold_reply(1, permit);
    mailbox.clear();
    let permits: Vec<_> = (0..MAX_BULK_REQUESTS)
        .map(|_| mailbox.reserve_reply().unwrap())
        .collect();
    assert!(mailbox.reserve_reply().is_err());
    drop(permits);
    assert!(mailbox.reserve_reply().is_ok());
}

#[test]
fn unrelated_workspace_results_do_not_release_a_timeline_reply_budget() {
    assert!(bulk_request(&WorkspaceRequest::TimelineWatch {
        pane_id: PaneId(1)
    }));
    assert!(!bulk_request(&WorkspaceRequest::ListPorts));
    assert!(bulk_reply(&Ok(WorkspaceResponse::Timeline(snapshot(0)))));
    assert!(!bulk_reply(&Ok(WorkspaceResponse::Done)));
    assert!(!bulk_reply(&Err(WsError::Denied("not this pane".into()))));
}
