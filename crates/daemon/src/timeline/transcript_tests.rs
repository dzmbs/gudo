use super::*;
use std::io::Write;

use serde_json::json;

fn message(index: usize) -> String {
    format!(
        "{}\n",
        json!({"type":"assistant","uuid":format!("message-{index}"),"timestamp":"2026-01-01T00:00:00Z","message":{"id":format!("api-{index}"),"model":"test-model","content":[{"type":"text","text":format!("Entry {index}")}]}})
    )
}

fn open(path: &Path) -> Transcript {
    Transcript::open(path.to_owned(), "test".into(), 7).unwrap()
}

#[test]
fn opens_only_the_tail_and_pages_without_gaps_or_duplicates() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("test.jsonl");
    let mut file = File::create(&path).unwrap();
    for index in 0..2000 {
        file.write_all(message(index).as_bytes()).unwrap();
    }
    let mut transcript = open(&path);
    let snapshot = transcript.snapshot(60, None);
    assert_eq!(snapshot.items.len(), 60);
    assert_eq!(snapshot.items.first().unwrap().id, "message-1940:0");
    assert_eq!(snapshot.items.last().unwrap().id, "message-1999:0");
    assert!(transcript.items.len() <= 120);
    let mut before = snapshot.before;
    let mut seen: std::collections::HashSet<_> =
        snapshot.items.iter().map(|item| item.id.clone()).collect();
    while let Some(cursor) = before {
        let page = transcript.page(cursor, 100, None).unwrap();
        assert!(page.items.len() <= 100);
        for item in page.items {
            assert!(seen.insert(item.id));
        }
        assert!(page.before.is_none_or(|older| older < cursor));
        before = page.before;
    }
    assert_eq!(seen.len(), 2000);
}

#[test]
fn appended_records_are_published_once_and_partial_lines_wait() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("test.jsonl");
    std::fs::write(&path, message(0)).unwrap();
    let mut transcript = open(&path);
    let mut writer = OpenOptions::new().append(true).open(&path).unwrap();
    let next = message(1);
    writer.write_all(&next.as_bytes()[..20]).unwrap();
    assert!(transcript.refresh().unwrap().is_empty());
    assert!(transcript.refresh().unwrap().is_empty());
    writer.write_all(&next.as_bytes()[20..]).unwrap();
    let operations = transcript.refresh().unwrap();
    assert_eq!(operations.len(), 1);
    assert!(
        matches!(&operations[0], TimelineOp::Upsert { item, cursor } if item.id == "message-1:0" && cursor.sequence == 1)
    );
    assert!(transcript.refresh().unwrap().is_empty());
    assert_eq!(transcript.snapshot(60, None).items.len(), 2);
}

#[test]
fn rewrites_and_replacement_files_reset_the_epoch() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("test.jsonl");
    std::fs::write(&path, message(0)).unwrap();
    let mut transcript = open(&path);
    std::fs::write(&path, message(1)).unwrap();
    let operations = transcript.refresh().unwrap();
    assert!(
        matches!(&operations[0], TimelineOp::Snapshot(snapshot) if snapshot.cursor.epoch == 8 && snapshot.items[0].id == "message-1:0")
    );
    let replacement = root.path().join("replacement.jsonl");
    std::fs::write(&replacement, message(2)).unwrap();
    std::fs::rename(&replacement, &path).unwrap();
    let operations = transcript.refresh().unwrap();
    assert!(
        matches!(&operations[0], TimelineOp::Snapshot(snapshot) if snapshot.cursor.epoch == 9 && snapshot.items[0].id == "message-2:0")
    );
}

#[test]
fn command_metadata_survives_a_transcript_rewrite() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("test.jsonl");
    std::fs::write(&path, message(0)).unwrap();
    let mut transcript = open(&path);
    let commands = vec![proto::TimelineCommand {
        name: "test".into(),
        description: "Run tests".into(),
        source: "Project".into(),
    }];
    transcript.set_commands(commands.clone());
    std::fs::write(&path, message(1)).unwrap();
    let operations = transcript.refresh().unwrap();
    let TimelineOp::Snapshot(snapshot) = &operations[0] else {
        panic!()
    };
    assert_eq!(snapshot.session.commands, commands);
}

#[test]
fn live_cache_is_bounded_and_revisions_advance_for_plan_updates() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("test.jsonl");
    std::fs::write(&path, "").unwrap();
    let mut transcript = open(&path);
    let mut writer = OpenOptions::new().append(true).open(&path).unwrap();
    for index in 0..1000 {
        writer.write_all(message(index).as_bytes()).unwrap();
        transcript.refresh().unwrap();
    }
    assert_eq!(transcript.items.len(), CACHE_ITEMS);
    assert_eq!(transcript.order.len(), CACHE_ITEMS);
    let first = TimelineItem {
        id: "plan".into(),
        revision: 1,
        turn: Some("turn".into()),
        parent: None,
        at: UnixMillis(0),
        origin: proto::TimelineOrigin::Agent,
        body: proto::TimelineBody::Plan {
            entries: vec![proto::TimelinePlanEntry {
                text: "Build".into(),
                status: proto::TimelinePlanStatus::Pending,
            }],
        },
    };
    let mut second = first.clone();
    second.body = proto::TimelineBody::Plan {
        entries: vec![proto::TimelinePlanEntry {
            text: "Build".into(),
            status: proto::TimelinePlanStatus::Completed,
        }],
    };
    assert_eq!(transcript.store(first, 1).unwrap().revision, 1);
    assert_eq!(transcript.store(second.clone(), 2).unwrap().revision, 2);
    assert!(transcript.store(second, 2).is_none());
}

#[test]
fn full_output_is_paged_on_utf8_boundaries_and_history_since_join_is_enforced() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("test.jsonl");
    let text = "🦀output\n".repeat(2000);
    let record = json!({"type":"user","timestamp":"2026-01-01T00:00:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"tool","content":text}]}});
    std::fs::write(&path, format!("{record}\n")).unwrap();
    let mut transcript = open(&path);
    let snapshot = transcript.snapshot(60, None);
    let proto::TimelineBody::Tool(tool) = &snapshot.items[0].body else {
        panic!()
    };
    let handle = tool.output.as_ref().unwrap().handle.clone();
    assert_eq!(handle, "7:0:tool");
    let mut output = String::new();
    let mut offset = 0;
    loop {
        let page = transcript.output(&handle, offset, 17, None).unwrap();
        assert!(!page.text.is_empty());
        output.push_str(&page.text);
        let Some(next) = page.next_offset else { break };
        assert!(next > offset);
        offset = next;
    }
    assert_eq!(output, text);
    assert!(matches!(
        transcript.output(&handle, 1, 17, None),
        Err(WsError::Invalid(_))
    ));
    assert!(matches!(
        transcript.output("8:0:tool", 0, 17, None),
        Err(WsError::Conflict(_))
    ));
    assert!(matches!(
        transcript.output("7:1:tool", 0, 17, None),
        Err(WsError::Invalid(_))
    ));
    let since = Some(UnixMillis(1767225600001));
    assert!(transcript.snapshot(60, since).items.is_empty());
    assert!(matches!(
        transcript.output(&handle, 0, 17, since),
        Err(WsError::Denied(_))
    ));
}

#[test]
fn stale_output_handles_cannot_read_a_rewritten_file_before_the_next_watch_tick() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("test.jsonl");
    let record = json!({"type":"user","timestamp":"2026-01-01T00:00:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"tool","content":"old"}]}});
    std::fs::write(&path, format!("{record}\n")).unwrap();
    let mut transcript = open(&path);
    std::fs::write(
        &path,
        format!("{}\n", record.to_string().replace("old", "new")),
    )
    .unwrap();
    assert!(matches!(
        transcript.output("7:0:tool", 0, 64, None),
        Err(WsError::Conflict(_))
    ));
}

#[test]
fn output_pages_must_make_progress_even_with_multibyte_text() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("test.jsonl");
    let record = json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool","content":"🦀"}]}});
    std::fs::write(&path, format!("{record}\n")).unwrap();
    let mut transcript = open(&path);
    assert!(matches!(
        transcript.output("7:0:tool", 0, 1, None),
        Err(WsError::Invalid(_))
    ));
    let output = transcript.output("7:0:tool", 0, 4, None).unwrap();
    assert_eq!(output.text, "🦀");
    assert_eq!(output.next_offset, None);
}

#[test]
fn snapshots_are_bounded_in_bytes_as_well_as_item_count() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("test.jsonl");
    let mut file = File::create(&path).unwrap();
    for index in 0..80 {
        let record = json!({"type":"assistant","uuid":format!("message-{index}"),"message":{"content":[{"type":"text","text":"a".repeat(24*1024)}]}});
        writeln!(file, "{record}").unwrap();
    }
    let transcript = open(&path);
    let snapshot = transcript.snapshot(60, None);
    assert!(!snapshot.items.is_empty());
    assert!(snapshot.items.len() < 60);
    assert!(snapshot.before.is_some());
    assert!(postcard::to_allocvec(&snapshot).unwrap().len() < SNAPSHOT_BYTES + 1024);
}

#[test]
fn path_validation_refuses_another_session_and_symlink_escapes() {
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let path = root.path().join("test.jsonl");
    std::fs::write(&path, "{}\n").unwrap();
    assert_eq!(
        validate_path(root.path(), &path, "test").unwrap(),
        path.canonicalize().unwrap()
    );
    assert!(matches!(
        validate_path(root.path(), &path, "other"),
        Err(WsError::Denied(_))
    ));
    let secret = outside.path().join("test.jsonl");
    std::fs::write(&secret, "{}\n").unwrap();
    let linked = root.path().join("linked");
    std::os::unix::fs::symlink(outside.path(), &linked).unwrap();
    assert!(matches!(
        validate_path(root.path(), &linked.join("test.jsonl"), "test"),
        Err(WsError::Denied(_))
    ));
    let direct_link = root.path().join("direct.jsonl");
    std::os::unix::fs::symlink(&secret, &direct_link).unwrap();
    assert!(Transcript::open(direct_link, "test".into(), 7).is_err());
}
