use proto::{
    AgentKind, PaneId, TimelineBody, TimelineCursor, TimelineItem, TimelineNoticeKind, TimelineOp,
    TimelineOrigin, TimelineSession, TimelineSnapshot, TimelineToolKind, TimelineVersion,
    UnixMillis,
};

fn unsupported() -> TimelineItem {
    TimelineItem {
        id: "future-item".into(),
        revision: 3,
        turn: Some("turn".into()),
        parent: None,
        at: UnixMillis(42),
        origin: TimelineOrigin::Agent,
        body: TimelineBody::Unsupported,
    }
}

fn snapshot() -> TimelineSnapshot {
    TimelineSnapshot {
        cursor: TimelineCursor {
            epoch: 7,
            sequence: 9,
        },
        session: TimelineSession {
            agent: AgentKind::Claude,
            native_session: "fixture".into(),
            title: None,
            model: None,
            permission_mode: None,
            commands: Vec::new(),
        },
        items: vec![unsupported()],
        before: Some(12),
    }
}

#[test]
fn unsupported_body_is_appended_but_only_the_frozen_notice_goes_to_v1() {
    let mut item = unsupported();
    assert_eq!(postcard::to_allocvec(&item.body).unwrap(), [7]);
    TimelineVersion::V1.item(&mut item);
    let TimelineBody::Notice { kind, text } = &item.body else {
        panic!("Missing notice")
    };
    assert_eq!(*kind, TimelineNoticeKind::Error);
    assert_eq!(text, "This Chat item is not supported. Open Terminal.");
    let mut frozen = vec![5, 4, 47];
    frozen.extend_from_slice(b"This Chat item is not supported. Open Terminal.");
    assert_eq!(postcard::to_allocvec(&item.body).unwrap(), frozen);
    assert_eq!(item.id, "future-item");
    assert_eq!(item.revision, 3);
    assert_eq!(item.at, UnixMillis(42));
    assert_eq!(
        postcard::to_allocvec(&TimelineToolKind::Other).unwrap(),
        [9]
    );
}

#[test]
fn snapshot_upsert_and_recovery_keep_identity_and_cursor_while_degrading() {
    let canonical = snapshot();
    let adapted = TimelineVersion::V1.snapshot(canonical.clone());
    assert_eq!(adapted.cursor, canonical.cursor);
    assert_eq!(adapted.before, canonical.before);
    let operations = TimelineVersion::V1.operations(vec![
        TimelineOp::Snapshot(canonical.clone()),
        TimelineOp::Upsert {
            cursor: canonical.cursor,
            item: Box::new(unsupported()),
        },
    ]);
    let TimelineOp::Snapshot(recovery) = &operations[0] else {
        panic!("Missing snapshot")
    };
    assert_eq!(*recovery, adapted);
    let TimelineOp::Upsert { cursor, item } = &operations[1] else {
        panic!("Missing upsert")
    };
    assert_eq!(*cursor, canonical.cursor);
    assert_eq!(**item, adapted.items[0]);
    let update = proto::TimelineUpdate {
        pane_id: PaneId(7),
        operations,
    };
    let json = serde_json::to_string(&update).unwrap();
    assert!(!json.contains("Unsupported"));
}
