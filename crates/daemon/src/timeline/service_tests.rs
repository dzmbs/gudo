use super::*;
use notify::Watcher;
use proto::{TimelineBody, TimelineField, TimelineItem, TimelineOrigin};
use std::io::Write;

fn test_source(root: &std::path::Path) -> Source {
    Source {
        native_session: "test".into(),
        path: None,
        config_directory: root.into(),
        working_directory: root.into(),
        watch_directory: root.into(),
    }
}

#[test]
fn a_runtime_watch_failure_is_terminal_instead_of_a_stale_live_session() {
    let root = tempfile::tempdir().unwrap();
    let source = test_source(root.path());
    let (wake, _wakes) = mpsc::channel(1);
    let mut state = LiveState::new(source.clone(), 7, wake).unwrap();
    state.watcher.failed.store(true, Ordering::Release);
    assert!(matches!(
        state.refresh(source),
        Err(WsError::Unavailable(_))
    ));
}

#[test]
fn known_backlog_reschedules_itself_without_another_native_file_event() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("test.jsonl");
    std::fs::write(
        &path,
        "{\"type\":\"user\",\"uuid\":\"first\",\"message\":{\"content\":\"Hello\"}}\n",
    )
    .unwrap();
    let mut source = test_source(root.path());
    source.path = Some(path.clone());
    let (wake, mut wakes) = mpsc::channel(1);
    let mut state = LiveState::new(source.clone(), 7, wake).unwrap();
    // Deliberately detach the real backend to isolate the bounded reader's continuation.
    state.watcher._watcher.unwatch(root.path()).unwrap();
    while wakes.try_recv().is_ok() {}
    let mut writer = std::fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap();
    writer
        .write_all(&vec![b'x'; record_stream::RECORD_BYTES_LIMIT + 1024])
        .unwrap();
    writer
        .write_all(b"\n{\"type\":\"user\",\"uuid\":\"last\",\"message\":{\"content\":\"Done\"}}\n")
        .unwrap();
    assert!(state.refresh(source.clone()).unwrap().is_empty());
    assert!(state.transcript.as_ref().unwrap().has_backlog());
    assert!(
        wakes.try_recv().is_ok(),
        "known bytes require a continuation, not a future file event"
    );
    let operations = state.refresh(source).unwrap();
    assert!(
        matches!(operations.as_slice(), [TimelineOp::Upsert { item, .. }] if item.id == "last")
    );
    assert!(!state.transcript.as_ref().unwrap().has_backlog());
    assert!(matches!(
        wakes.try_recv(),
        Err(mpsc::error::TryRecvError::Empty)
    ));
}

#[tokio::test]
async fn only_matching_agent_events_or_native_wakes_refresh_a_pane() {
    let (wake, mut wakes) = mpsc::channel(1);
    let (events, mut receiver) = broadcast::channel(4);
    events.send(Event::PaneMeta(PaneId(2))).unwrap();
    assert!(
        tokio::time::timeout(
            Duration::from_millis(20),
            wait_for_wake(PaneId(1), &mut wakes, &mut receiver)
        )
        .await
        .is_err()
    );
    events.send(Event::PaneMeta(PaneId(1))).unwrap();
    assert!(wait_for_wake(PaneId(1), &mut wakes, &mut receiver).await);
    wake.try_send(()).unwrap();
    assert!(wait_for_wake(PaneId(1), &mut wakes, &mut receiver).await);
}

#[test]
fn coalescing_drains_are_bounded_and_leave_later_events_pending() {
    let (wake, mut wakes) = mpsc::channel(1);
    let (events, mut receiver) = broadcast::channel(128);
    wake.try_send(()).unwrap();
    for _ in 0..MAX_COALESCED_EVENTS + 2 {
        events.send(Event::PaneMeta(PaneId(1))).unwrap();
    }
    drain_pending(&mut wakes, &mut receiver);
    assert!(matches!(
        wakes.try_recv(),
        Err(mpsc::error::TryRecvError::Empty)
    ));
    assert_eq!(receiver.len(), 2);
}

#[tokio::test]
async fn an_idle_timeline_does_not_refresh_on_a_periodic_clock() {
    let (_wake, mut wakes) = mpsc::channel(1);
    let (_events, mut events) = broadcast::channel(4);
    let result = tokio::time::timeout(
        Duration::from_millis(850),
        wait_for_wake(PaneId(1), &mut wakes, &mut events),
    )
    .await;
    assert!(
        result.is_err(),
        "an idle timeline must wait for native or agent events, not a clock tick"
    );
}

#[test]
fn a_missing_native_watch_is_unavailable_instead_of_silently_polling() {
    let root = tempfile::tempdir().unwrap();
    let mut source = test_source(root.path());
    source.watch_directory = root.path().join("missing");
    let (wake, _wakes) = mpsc::channel(1);
    assert!(matches!(
        LiveState::new(source, 7, wake),
        Err(WsError::Unavailable(_))
    ));
}

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

fn push(
    mailbox: &Mailbox,
    watch: u64,
    update: TimelineUpdate,
    snapshot: impl FnOnce() -> TimelineSnapshot,
) -> Delivery {
    let pane_id = update.pane_id;
    match mailbox.offer(watch, update) {
        Delivery::NeedsSnapshot => mailbox.replace(
            watch,
            TimelineUpdate {
                pane_id,
                operations: vec![TimelineOp::Snapshot(snapshot())],
            },
        ),
        delivery => delivery,
    }
}

fn last_cursor(update: &TimelineUpdate) -> Option<TimelineCursor> {
    match update.operations.last()? {
        TimelineOp::Checkpoint { cursor } => Some(*cursor),
        TimelineOp::Snapshot(snapshot) => Some(snapshot.cursor),
        _ => None,
    }
}

#[test]
fn a_slow_reader_keeps_one_bounded_update_instead_of_an_unbounded_delta_queue() {
    let mailbox = Mailbox::default();
    mailbox.register(PaneId(1), 42);
    for sequence in 1..10_000 {
        push(&mailbox, 42, update(sequence), || snapshot(sequence));
    }
    let messages = mailbox.take();
    assert_eq!(messages.len(), 1);
    let ServerCtl::Timeline(received) = &messages[0] else {
        panic!()
    };
    assert!(matches!(&received.operations[0], TimelineOp::Snapshot(_)));
    assert_eq!(last_cursor(received), Some(cursor(9999)));
    assert!(value_weight::update(received) <= MAX_PUSH_BYTES);
    assert!(mailbox.take().is_empty());
    push(&mailbox, 42, update(10_000), || panic!("no pending update"));
    assert_eq!(mailbox.take(), vec![ServerCtl::Timeline(update(10_000))]);
}

#[test]
fn a_slow_link_appends_small_updates_instead_of_resending_the_whole_timeline() {
    let mailbox = Mailbox::default();
    mailbox.register(PaneId(1), 42);
    for sequence in 1..=3 {
        assert_eq!(
            push(&mailbox, 42, update(sequence), || panic!(
                "fits in one push"
            )),
            Delivery::Queued
        );
    }
    let expected = TimelineUpdate {
        pane_id: PaneId(1),
        operations: (1..=3)
            .map(|sequence| TimelineOp::Checkpoint {
                cursor: cursor(sequence),
            })
            .collect(),
    };
    assert_eq!(mailbox.take(), vec![ServerCtl::Timeline(expected)]);
}

#[test]
fn a_snapshot_supersedes_pending_updates_without_growing_them() {
    let mailbox = Mailbox::default();
    mailbox.register(PaneId(1), 42);
    push(&mailbox, 42, update(1), || panic!("fits"));
    let fresh = TimelineUpdate {
        pane_id: PaneId(1),
        operations: vec![TimelineOp::Snapshot(snapshot(2))],
    };
    push(&mailbox, 42, fresh.clone(), || panic!("fits"));
    assert_eq!(mailbox.take(), vec![ServerCtl::Timeline(fresh)]);
}

#[test]
fn old_forwarders_cannot_publish_after_unwatch_or_replace_the_current_watch() {
    let mailbox = Mailbox::default();
    mailbox.register(PaneId(1), 10);
    push(&mailbox, 10, update(1), || snapshot(1));
    mailbox.remove(PaneId(1));
    assert_eq!(
        push(&mailbox, 10, update(2), || panic!("unwatched")),
        Delivery::Closed
    );
    assert!(mailbox.take().is_empty());
    mailbox.register(PaneId(1), 11);
    assert_eq!(
        push(&mailbox, 10, update(3), || panic!("replaced")),
        Delivery::Closed
    );
    assert!(mailbox.take().is_empty());
    push(&mailbox, 11, update(4), || snapshot(4));
    assert_eq!(mailbox.take(), vec![ServerCtl::Timeline(update(4))]);
    mailbox.clear();
    assert_eq!(
        push(&mailbox, 11, update(5), || panic!("disconnected")),
        Delivery::Closed
    );
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
            item: Box::new(item),
        });
    }
    push(
        &mailbox,
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
fn an_oversized_coalescing_snapshot_becomes_a_bounded_terminal_failure_that_ends_the_watch() {
    let mailbox = Mailbox::default();
    mailbox.register(PaneId(1), 42);
    push(&mailbox, 42, update(1), || snapshot(1));
    let mut oversized = snapshot(2);
    oversized.session.title = Some("x".repeat(MAX_PUSH_BYTES + 1));
    let delivery = mailbox.replace(
        42,
        TimelineUpdate {
            pane_id: PaneId(1),
            operations: vec![TimelineOp::Snapshot(oversized)],
        },
    );
    assert_eq!(delivery, Delivery::Closed);
    let messages = mailbox.take();
    let ServerCtl::Timeline(received) = &messages[0] else {
        panic!("timeline update")
    };
    assert!(
        matches!(received.operations.as_slice(), [TimelineOp::Unavailable { message }] if message.contains("Terminal"))
    );
    assert!(postcard::to_allocvec(received).unwrap().len() < MAX_PUSH_BYTES);
}

#[test]
fn oversized_failure_text_cannot_bypass_the_mailbox_byte_allowance() {
    let mailbox = Mailbox::default();
    mailbox.register(PaneId(1), 42);
    let delivery = push(
        &mailbox,
        42,
        TimelineUpdate {
            pane_id: PaneId(1),
            operations: vec![TimelineOp::Unavailable {
                message: "x".repeat(MAX_PUSH_BYTES + 1),
            }],
        },
        || panic!("failure must not become a successful snapshot"),
    );
    assert_eq!(delivery, Delivery::Closed);
    let messages = mailbox.take();
    let ServerCtl::Timeline(received) = &messages[0] else {
        panic!("timeline update")
    };
    assert!(postcard::to_allocvec(received).unwrap().len() < MAX_PUSH_BYTES);
    assert!(
        matches!(received.operations.as_slice(), [TimelineOp::Unavailable { message }] if message.contains("Terminal"))
    );
}

#[test]
fn failure_notes_are_not_hidden_by_backpressure_coalescing() {
    let mailbox = Mailbox::default();
    mailbox.register(PaneId(1), 42);
    push(&mailbox, 42, update(1), || snapshot(1));
    let failure = TimelineUpdate {
        pane_id: PaneId(1),
        operations: vec![TimelineOp::Unavailable {
            message: "Open Terminal".into(),
        }],
    };
    push(&mailbox, 42, failure.clone(), || panic!("preserve failure"));
    assert_eq!(mailbox.take(), vec![ServerCtl::Timeline(failure)]);
}

#[test]
fn since_join_filtering_advances_the_cursor_without_exposing_hidden_items() {
    let operations = vec![
        TimelineOp::Upsert {
            cursor: cursor(1),
            item: Box::new(item("old", 1)),
        },
        TimelineOp::Upsert {
            cursor: cursor(2),
            item: Box::new(item("new", 11)),
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
fn unknown_original_times_are_hidden_even_at_a_zero_since_boundary() {
    let mut page = snapshot(3);
    page.items = vec![item("unknown", 0), item("known", 1)];
    let operations = vec![
        TimelineOp::Upsert {
            cursor: cursor(1),
            item: Box::new(item("unknown", 0)),
        },
        TimelineOp::Append {
            cursor: cursor(2),
            id: "unknown".into(),
            field: TimelineField::Text,
            text: "private".into(),
        },
        TimelineOp::Snapshot(page),
    ];
    let mut visible = HashSet::new();
    let filtered = filter(operations, Some(UnixMillis(0)), &mut visible);
    assert_eq!(filtered[0], TimelineOp::Checkpoint { cursor: cursor(1) });
    assert_eq!(filtered[1], TimelineOp::Checkpoint { cursor: cursor(2) });
    let TimelineOp::Snapshot(page) = &filtered[2] else {
        panic!()
    };
    assert_eq!(
        page.items
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["known"]
    );
    assert_eq!(visible, HashSet::from(["known".into()]));
}

#[test]
fn withdrawing_a_visible_items_time_also_withdraws_append_visibility() {
    let mut visible = HashSet::from(["changed".into()]);
    let operations = vec![
        TimelineOp::Upsert {
            cursor: cursor(1),
            item: Box::new(item("changed", 0)),
        },
        TimelineOp::Append {
            cursor: cursor(2),
            id: "changed".into(),
            field: TimelineField::Text,
            text: "private".into(),
        },
    ];
    let filtered = filter(operations, Some(UnixMillis(10)), &mut visible);
    assert_eq!(
        filtered[0],
        TimelineOp::Remove {
            cursor: cursor(1),
            id: "changed".into()
        }
    );
    assert_eq!(filtered[1], TimelineOp::Checkpoint { cursor: cursor(2) });
    assert!(visible.is_empty());
}

#[test]
fn a_new_agent_pane_can_open_chat_before_its_first_transcript_exists() {
    let root = tempfile::tempdir().unwrap();
    let source = test_source(root.path());
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

fn test_timeline(root: &std::path::Path) -> Arc<Timeline> {
    let source = test_source(root);
    let (wake, _) = mpsc::channel(1);
    Arc::new(Timeline {
        state: Mutex::new(Box::new(LiveState::new(source, 7, wake).unwrap())),
        updates: broadcast::channel(8).0,
        worker: Mutex::default(),
    })
}

#[tokio::test]
async fn cancellation_marks_a_worker_dead_before_notifying_its_subscribers() {
    let root = tempfile::tempdir().unwrap();
    let timeline = test_timeline(root.path());
    let mut updates = timeline.updates.subscribe();
    let lifetime = WorkerLifetime(Arc::downgrade(&timeline));
    let task = {
        let mut worker = lock(&timeline.worker);
        let task = tokio::spawn(async move {
            let _lifetime = lifetime;
            std::future::pending::<()>().await;
        });
        *worker = Some(task.abort_handle());
        task
    };
    assert!(timeline.is_running());
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    assert!(matches!(
        &updates.recv().await.unwrap()[0],
        TimelineOp::Unavailable { .. }
    ));
    assert!(!timeline.is_running());
    assert!(lock(&timeline.worker).is_none());
}

#[test]
fn only_transient_failures_consume_the_bounded_io_retry_budget() {
    let mut failures = 0;
    for error in [
        WsError::Denied("scope".into()),
        WsError::Invalid("input".into()),
        WsError::NotFound("pane".into()),
    ] {
        assert!(!retry_io(&mut failures, &error));
        assert_eq!(failures, 0);
    }
    for attempt in 1..=MAX_IO_RETRIES {
        assert!(retry_io(
            &mut failures,
            &WsError::Failed("temporary I/O".into())
        ));
        assert_eq!(failures, attempt);
    }
    assert!(!retry_io(
        &mut failures,
        &WsError::Failed("persistent I/O".into())
    ));
}

#[test]
fn unrelated_workspace_results_do_not_release_a_timeline_reply_budget() {
    assert!(bulk_request(&WorkspaceRequest::TimelineWatch {
        pane_id: PaneId(1)
    }));
    assert!(bulk_request(&WorkspaceRequest::TimelineWatchVersioned {
        pane_id: PaneId(1),
        version: proto::TimelineVersion::CURRENT.as_u16(),
    }));
    assert!(!bulk_request(&WorkspaceRequest::ListPorts));
    assert!(bulk_reply(&Ok(WorkspaceResponse::Timeline(snapshot(0)))));
    assert!(!bulk_reply(&Ok(WorkspaceResponse::Done)));
    assert!(!bulk_reply(&Err(WsError::Denied("not this pane".into()))));
}

fn forwarder(timeline: Arc<Timeline>, mailbox: Arc<Mailbox>) -> Forwarder {
    Forwarder {
        pane_id: PaneId(1),
        watch_token: 42,
        since: Some(UnixMillis(10)),
        visible: HashSet::new(),
        timeline,
        mailbox,
    }
}

#[tokio::test]
async fn a_since_join_watch_over_its_visible_allowance_starts_over_from_a_snapshot() {
    let root = tempfile::tempdir().unwrap();
    let mut forwarder = forwarder(test_timeline(root.path()), Arc::default());
    forwarder.visible = (0..=MAX_VISIBLE_ITEMS)
        .map(|index| format!("item-{index}"))
        .collect();
    let operations = forwarder
        .visible_operations(vec![TimelineOp::Append {
            cursor: cursor(1),
            id: "item-0".into(),
            field: TimelineField::Text,
            text: "more".into(),
        }])
        .await;
    assert!(matches!(operations.as_slice(), [TimelineOp::Snapshot(_)]));
    assert!(forwarder.visible.len() <= MAX_VISIBLE_ITEMS);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn building_a_snapshot_never_holds_the_mailbox_the_ctl_writer_needs() {
    let root = tempfile::tempdir().unwrap();
    let timeline = test_timeline(root.path());
    let mailbox = Arc::new(Mailbox::default());
    mailbox.register(PaneId(1), 42);
    let (held, holding) = std::sync::mpsc::channel();
    let holder = {
        let timeline = Arc::clone(&timeline);
        std::thread::spawn(move || {
            let _state = lock(&timeline.state);
            held.send(()).unwrap();
            std::thread::sleep(Duration::from_millis(600));
        })
    };
    holding.recv().unwrap();
    let mut operations = Vec::new();
    for sequence in 1..=5 {
        let mut item = item(&format!("item-{sequence}"), 20);
        item.body = TimelineBody::Assistant {
            text: "a".repeat(256 * 1024),
            streaming: false,
        };
        operations.push(TimelineOp::Upsert {
            cursor: cursor(sequence),
            item: Box::new(item),
        });
    }
    let mut forwarder = forwarder(Arc::clone(&timeline), Arc::clone(&mailbox));
    let delivering = tokio::spawn(async move { forwarder.deliver(operations).await });
    tokio::time::sleep(Duration::from_millis(100)).await;
    let writer = Arc::clone(&mailbox);
    let started = std::time::Instant::now();
    tokio::task::spawn_blocking(move || writer.take())
        .await
        .unwrap();
    assert!(started.elapsed() < Duration::from_millis(300));
    holder.join().unwrap();
    assert!(delivering.await.unwrap());
    assert!(matches!(
        &mailbox.take()[..],
        [ServerCtl::Timeline(TimelineUpdate { operations, .. })]
            if matches!(operations.as_slice(), [TimelineOp::Snapshot(_)])
    ));
}

#[test]
fn reopened_timelines_never_reuse_an_epoch_from_before_a_hand_off() {
    let started = crate::identity::now_millis();
    seed_epochs(1);
    assert!(next_epoch() > started);
}
