use super::*;
use proto::{TimelineBody, TimelineTextRole};
use serde_json::{Value, json};
use std::io::Write;

pub(crate) const THREAD: &str = "01a1bcab-5e10-7742-b6b3-2764bf9990b4";
const EPOCH: u64 = 9;

/// A Codex home with one rollout, written in the format Codex 0.166.0 records.
pub(crate) struct Fixture {
    pub home: tempfile::TempDir,
    pub path: PathBuf,
}

impl Fixture {
    pub fn new() -> Self {
        Self::with_meta(json!({}))
    }

    pub fn with_meta(changes: Value) -> Self {
        let home = tempfile::tempdir().unwrap();
        let day = home.path().join("sessions/2026/11/08");
        std::fs::create_dir_all(&day).unwrap();
        let path = day.join(format!("rollout-2026-11-08T20-38-29-{THREAD}.jsonl"));
        let fixture = Self { home, path };
        let mut meta = json!({
            "id": THREAD,
            "session_id": THREAD,
            "cwd": "/fixture/project",
            "cli_version": "0.166.0",
            "base_instructions": {"text": "x".repeat(30_000)},
            "history_mode": "paginated",
        });
        for (key, value) in changes.as_object().unwrap() {
            meta[key] = value.clone();
        }
        fixture.append(&json!({
            "timestamp": "2026-11-08T19:38:29.000Z",
            "ordinal": 0,
            "type": "session_meta",
            "payload": meta,
        }));
        fixture.append(&json!({
            "timestamp": "2026-11-08T19:38:30.000Z",
            "type": "response_item",
            "payload": {
                "type": "message",
                "role": "developer",
                "content": [{"type": "input_text", "text": "{\"type\":\"event_msg\"} quoted"}],
            },
        }));
        fixture
    }

    pub fn append(&self, record: &Value) -> u64 {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .unwrap();
        let offset = file.metadata().unwrap().len();
        writeln!(file, "{record}").unwrap();
        offset
    }

    pub fn item(&self, turn: &str, item: Value) -> u64 {
        self.append(&json!({
            "timestamp": "2026-11-08T19:40:00.000Z",
            "type": "event_msg",
            "payload": {
                "type": "item_completed",
                "thread_id": THREAD,
                "turn_id": turn,
                "item": item,
                "started_at_ms": 1_794_166_800_000_i64,
                "completed_at_ms": 1_794_166_801_000_i64,
            },
        }))
    }

    pub fn reply(&self, turn: &str, id: &str, text: &str) -> u64 {
        self.item(
            turn,
            json!({"type": "AgentMessage", "id": id, "content": [{"type": "Text", "text": text}], "phase": "final_answer"}),
        )
    }

    pub fn open(&self) -> Rollout {
        Rollout::open(self.home.path(), &self.path, THREAD).unwrap()
    }
}

fn texts(items: &[TimelineItem]) -> Vec<String> {
    items
        .iter()
        .map(|item| match &item.body {
            TimelineBody::User { text, .. } | TimelineBody::Assistant { text, .. } => text.clone(),
            TimelineBody::Notice { text, .. } => format!("notice: {text}"),
            body => format!("{body:?}"),
        })
        .collect()
}

fn read_all(rollout: &Rollout, handle: &OutputHandle) -> (String, u64) {
    let mut text = String::new();
    let mut offset = 0;
    loop {
        let page = rollout.text(handle, offset, 256 * 1024).unwrap();
        text.push_str(&page.text);
        match page.next_offset {
            Some(next) => offset = next,
            None => return (text, page.total_bytes),
        }
    }
}

#[test]
fn pages_reach_back_to_the_first_item_well_beyond_what_memory_keeps() {
    let fixture = Fixture::new();
    for index in 0..1_200 {
        fixture.reply(
            &format!("turn-{}", index / 10),
            &format!("msg-{index}"),
            &format!("reply {index}"),
        );
    }
    let rollout = fixture.open();
    let mut before = rollout.end().unwrap();
    let mut seen = Vec::new();
    loop {
        let page = rollout.page(before, 100, EPOCH).unwrap();
        assert!(page.items.len() <= 100);
        let mut older = texts(&page.items);
        older.extend(seen);
        seen = older;
        match page.before {
            Some(next) => {
                assert!(next < before);
                before = next;
            }
            None => break,
        }
    }
    let expected: Vec<_> = (0..1_200).map(|index| format!("reply {index}")).collect();
    assert_eq!(seen, expected);
}

#[test]
fn a_two_megabyte_reply_pages_back_byte_for_byte() {
    let fixture = Fixture::new();
    let reply: String = (0..2 * 1024 * 1024 / 16)
        .map(|index| format!("line {index:>9}é\n"))
        .collect();
    assert!(reply.len() > 2 * 1024 * 1024);
    let offset = fixture.reply("turn", "huge", &reply);
    fixture.reply("turn", "after", "after");
    let rollout = fixture.open();
    let page = rollout.page(rollout.end().unwrap(), 100, EPOCH).unwrap();
    let TimelineBody::LongText { role, content } = &page.items[0].body else {
        panic!("expected long text, got {:?}", page.items[0].body);
    };
    assert_eq!(*role, TimelineTextRole::Assistant);
    assert_eq!(content.bytes, reply.len() as u64);
    assert!(reply.starts_with(&content.preview));
    assert_eq!(content.handle.offset(), offset);
    assert_eq!(content.handle.epoch(), EPOCH);
    assert_eq!(
        read_all(&rollout, &content.handle),
        (reply.clone(), reply.len() as u64)
    );

    let live = OutputHandle::new(EPOCH, 0, content.handle.id()).unwrap();
    assert_eq!(read_all(&rollout, &live).0, reply);
    let elsewhere =
        OutputHandle::new(EPOCH, page.before.unwrap_or(1), content.handle.id()).unwrap();
    assert_eq!(read_all(&rollout, &elsewhere).0, reply);
}

#[test]
fn command_output_pages_from_the_rollout() {
    let fixture = Fixture::new();
    let output: String = (0..60_000).map(|index| format!("{index}\n")).collect();
    fixture.item(
        "turn",
        json!({
            "type": "CommandExecution",
            "id": "call-1",
            "process_id": "92529",
            "command": ["/bin/zsh", "-lc", "seq 0 59999 | cat"],
            "cwd": "file:///fixture/project",
            "parsed_cmd": [],
            "source": "unified_exec_startup",
            "status": "completed",
            "aggregated_output": output,
            "exit_code": 0,
            "duration": {"secs": 1, "nanos": 500_000_000},
        }),
    );
    let rollout = fixture.open();
    let page = rollout.page(rollout.end().unwrap(), 100, EPOCH).unwrap();
    let TimelineBody::Tool(tool) = &page.items[0].body else {
        panic!("expected a command");
    };
    assert_eq!(tool.title, "/bin/zsh -lc 'seq 0 59999 | cat'");
    assert_eq!(tool.status, proto::TimelineToolStatus::Done);
    assert_eq!(tool.duration_ms, Some(1_500));
    let reference = tool.output.as_ref().unwrap();
    assert_eq!(reference.bytes, output.len() as u64);
    assert!(output.ends_with(&reference.preview));
    assert_eq!(read_all(&rollout, &reference.handle).0, output);
}

#[test]
fn context_codex_injects_is_not_a_user_row_and_status_notices_match_the_live_ones() {
    let fixture = Fixture::new();
    fixture.item(
        "turn",
        json!({"type": "UserMessage", "id": "context", "content": [{"type": "text", "text": "<environment_context>\n  <cwd>/project</cwd>\n</environment_context>", "text_elements": []}]}),
    );
    fixture.item(
        "turn",
        json!({"type": "UserMessage", "id": "typed", "content": [{"type": "text", "text": "What changed?", "text_elements": []}, {"type": "local_image", "path": "/tmp/shot.png"}]}),
    );
    fixture.item(
        "turn",
        json!({"type": "CollabAgentSpawn", "id": "spawn", "prompt": "Review it"}),
    );
    fixture.item(
        "turn",
        json!({"type": "Extension", "kind": "image_generation", "id": "drawn"}),
    );
    fixture.append(&json!({"type": "event_msg", "payload": {"type": "turn_aborted", "turn_id": "turn", "reason": "interrupted"}}));
    fixture.append(&json!({"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "other", "error": {"message": "boom"}}}));
    fixture.append(
        &json!({"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "fine"}}),
    );
    let rollout = fixture.open();
    let page = rollout.page(rollout.end().unwrap(), 100, EPOCH).unwrap();
    let ids: Vec<_> = page.items.iter().map(|item| item.id.as_str()).collect();
    assert_eq!(
        ids,
        [
            projection::item_id("turn", "typed").as_str(),
            projection::item_id("turn", "unsupported:turn").as_str(),
            "turn:turn:status",
            "turn:other:status",
        ]
    );
    assert!(
        matches!(&page.items[0].body, TimelineBody::User { attachments, .. }
        if attachments.len() == 1 && attachments[0].path == "/tmp/shot.png")
    );
    assert_eq!(
        texts(&page.items),
        [
            "What changed?".to_owned(),
            "notice: Additional agent details are available in Terminal.".into(),
            "notice: Turn interrupted.".into(),
            "notice: boom".into(),
        ]
    );
    assert_eq!(page.items[0].origin, proto::TimelineOrigin::Terminal);
    assert_eq!(page.before, None);
}

#[test]
fn tool_calls_mcp_edits_images_and_searches_are_tool_rows() {
    use proto::{TimelineToolKind, TimelineToolStatus};
    let fixture = Fixture::new();
    fixture.item(
        "turn",
        json!({
            "type": "McpToolCall", "id": "mcp-1", "server": "gudo", "tool": "pane_list",
            "arguments": {"all": true}, "readOnlyHint": true, "status": "completed",
            "result": {"content": [{"type": "text", "text": "3 panes"}], "structuredContent": {}},
            "duration": {"secs": 0, "nanos": 250_000_000},
        }),
    );
    fixture.item(
        "turn",
        json!({
            "type": "McpToolCall", "id": "mcp-2", "server": "gudo", "tool": "pane_send",
            "arguments": {}, "status": "failed", "error": {"message": "no such pane"},
        }),
    );
    let diff = "@@ -1 +1 @@\n-old\n+new\n";
    fixture.item(
        "turn",
        json!({
            "type": "FileChange", "id": "patch", "status": "completed", "stdout": "", "stderr": "",
            "changes": {
                "/p/src/main.rs": {"type": "update", "unified_diff": diff, "move_path": null},
                "/p/README.md": {"type": "add", "content": "hello\n"},
            },
        }),
    );
    fixture.item(
        "turn",
        json!({"type": "ImageView", "id": "view", "path": "/tmp/shot.png"}),
    );
    fixture.item(
        "turn",
        json!({
            "type": "Extension", "kind": "web_search", "id": "search", "query": "ghostty releases",
            "action": {"type": "search", "query": "ghostty releases", "queries": null}, "results": [],
        }),
    );
    let rollout = fixture.open();
    let page = rollout.page(rollout.end().unwrap(), 100, EPOCH).unwrap();
    let tools: Vec<_> = page
        .items
        .iter()
        .map(|item| match &item.body {
            TimelineBody::Tool(tool) => tool.clone(),
            body => panic!("expected a tool row, got {body:?}"),
        })
        .collect();
    let rows: Vec<_> = tools
        .iter()
        .map(|tool| {
            (
                tool.kind,
                tool.name.as_str(),
                tool.title.as_str(),
                tool.status,
            )
        })
        .collect();
    assert_eq!(
        rows,
        [
            (
                TimelineToolKind::Mcp,
                "mcp__gudo__pane_list",
                "gudo pane_list",
                TimelineToolStatus::Done
            ),
            (
                TimelineToolKind::Mcp,
                "mcp__gudo__pane_send",
                "gudo pane_send",
                TimelineToolStatus::Failed
            ),
            (
                TimelineToolKind::Edit,
                "Edit",
                "/p/README.md, /p/src/main.rs",
                TimelineToolStatus::Done
            ),
            (
                TimelineToolKind::Read,
                "View image",
                "/tmp/shot.png",
                TimelineToolStatus::Done
            ),
            (
                TimelineToolKind::WebSearch,
                "Web search",
                "ghostty releases",
                TimelineToolStatus::Done
            ),
        ]
    );
    assert_eq!(tools[0].input, r#"{"all":true}"#);
    assert_eq!(tools[0].duration_ms, Some(250));
    let read =
        |tool: &proto::TimelineTool| read_all(&rollout, &tool.output.as_ref().unwrap().handle).0;
    assert_eq!(read(&tools[0]), "3 panes");
    assert_eq!(read(&tools[1]), "no such pane");
    assert_eq!(
        read(&tools[2]),
        format!("/p/README.md\nhello\n\n/p/src/main.rs\n{diff}")
    );
    assert!(tools[3].output.is_none() && tools[4].output.is_none());
    assert_eq!(tools[2].diff.len(), 2);
    assert_eq!(tools[2].diff[0].change, proto::FileChange::Added);
    let recorded = rollout
        .diff(&tools[2].output.as_ref().unwrap().handle)
        .unwrap();
    assert_eq!(recorded.len(), 2);
    assert_eq!(
        (recorded[0].path.as_str(), recorded[0].additions),
        ("/p/README.md", 1)
    );
    assert_eq!(
        (
            recorded[1].change,
            recorded[1].additions,
            recorded[1].deletions
        ),
        (proto::FileChange::Modified, 1, 1)
    );
    assert!(
        rollout
            .diff(&tools[0].output.as_ref().unwrap().handle)
            .is_err()
    );
    assert_eq!(
        (tools[2].diff[1].additions, tools[2].diff[1].deletions),
        (1, 1)
    );
}

#[test]
fn history_shows_plans_agents_compaction_and_turn_endings_like_the_live_stream() {
    let fixture = Fixture::new();
    fixture.append(&json!({
        "timestamp": "2026-11-08T19:39:00.000Z",
        "type": "response_item",
        "payload": {
            "type": "function_call", "name": "update_plan", "call_id": "call_plan",
            "arguments": "{\"plan\":[{\"step\":\"Read\",\"status\":\"completed\"},{\"step\":\"Fix\",\"status\":\"in_progress\"}]}",
        },
    }));
    fixture.item(
        "turn",
        json!({
            "type": "CollabAgentToolCall", "id": "spawn", "tool": "spawn_agent",
            "status": "completed", "sender_thread_id": THREAD,
            "receiver_thread_ids": ["01a1bcab-6000-7000-8000-000000000001"],
            "prompt": "Check the tests", "model": "gpt-5.5",
            "agents_states": {"01a1bcab-6000-7000-8000-000000000001": {"completed": "All pass."}},
        }),
    );
    fixture.item(
        "turn",
        json!({
            "type": "WebSearch", "id": "hosted", "query": "",
            "action": {"type": "open_page", "url": "https://example.com/notes"},
        }),
    );
    fixture.item(
        "turn",
        json!({"type": "ContextCompaction", "id": "compact"}),
    );
    fixture.append(&json!({"type": "event_msg", "payload": {
        "type": "task_complete", "turn_id": "turn", "duration_ms": 3150,
        "error": {"message": "Usage limit reached."}, "completed_at": 1_794_166_802_i64,
    }}));
    let rollout = fixture.open();
    let page = rollout.page(rollout.end().unwrap(), 100, EPOCH).unwrap();
    assert!(matches!(&page.items[0].body, TimelineBody::Plan { entries }
        if entries.len() == 2 && entries[1].status == proto::TimelinePlanStatus::InProgress));
    assert!(matches!(&page.items[1].body, TimelineBody::Tool(tool)
        if tool.kind == proto::TimelineToolKind::Task && tool.title == "Check the tests"
            && tool.output.as_ref().is_some_and(|output| output.preview == "All pass.")));
    assert!(matches!(&page.items[2].body, TimelineBody::Tool(tool)
        if tool.kind == proto::TimelineToolKind::WebSearch && tool.title == "https://example.com/notes"));
    assert_eq!(
        texts(&page.items[3..5]),
        ["notice: Context compacted", "notice: Usage limit reached."]
    );
    assert!(matches!(
        page.items[5].body,
        TimelineBody::TurnEnd {
            duration_ms: 3150,
            ..
        }
    ));
    assert_eq!(page.items.len(), 6);
}

#[test]
fn a_snapshot_links_to_the_record_of_its_oldest_saved_item() {
    let fixture = Fixture::new();
    let mut offsets = Vec::new();
    for index in 0..80 {
        offsets.push(fixture.reply("turn", &format!("msg-{index}"), &format!("reply {index}")));
    }
    let rollout = fixture.open();
    let mut ids: Vec<_> = (20..80)
        .map(|index| projection::item_id("turn", &format!("msg-{index}")))
        .collect();
    ids.insert(0, "skipped:not-saved".into());
    ids.push(projection::item_id("turn", "still-streaming"));
    let before = rollout.before_items(&ids, EPOCH).unwrap();
    assert_eq!(before, Some(offsets[20]));
    let page = rollout.page(offsets[20], 100, EPOCH).unwrap();
    assert_eq!(page.items.len(), 20);
    assert!(page.items.iter().all(|item| !ids.contains(&item.id)));
    assert_eq!(page.before, None);

    assert_eq!(
        rollout.before_items(&[], EPOCH).unwrap(),
        Some(rollout.end().unwrap())
    );
    assert_eq!(
        rollout
            .before_items(&["item:4:none:missing".into()], EPOCH)
            .unwrap(),
        None
    );
}

#[test]
fn history_stops_at_a_recorded_rollback() {
    let fixture = Fixture::new();
    fixture.reply("old", "dropped", "rolled back");
    fixture.append(
        &json!({"type": "event_msg", "payload": {"type": "thread_rolled_back", "num_turns": 1}}),
    );
    fixture.reply("new", "kept", "kept");
    let rollout = fixture.open();
    let page = rollout.page(rollout.end().unwrap(), 100, EPOCH).unwrap();
    assert_eq!(texts(&page.items), ["kept"]);
    assert_eq!(page.before, None);
}

#[test]
fn only_a_regular_rollout_of_this_thread_inside_the_sessions_directory_opens() {
    let fixture = Fixture::new();
    fixture.reply("turn", "msg", "hello");
    assert!(Rollout::open(fixture.home.path(), &fixture.path, THREAD).is_ok());
    assert!(
        Rollout::open(
            fixture.home.path(),
            &fixture.path,
            "01a1bcab-0000-7742-b6b3-2764bf9990b4"
        )
        .is_err()
    );

    let link = fixture
        .path
        .with_file_name(format!("rollout-2026-11-08T20-38-30-{THREAD}.jsonl"));
    std::os::unix::fs::symlink(&fixture.path, &link).unwrap();
    assert!(Rollout::open(fixture.home.path(), &link, THREAD).is_err());

    let outside = tempfile::tempdir().unwrap();
    let copied = outside.path().join(fixture.path.file_name().unwrap());
    std::fs::copy(&fixture.path, &copied).unwrap();
    assert!(Rollout::open(fixture.home.path(), &copied, THREAD).is_err());
    let linked_outside = fixture
        .path
        .with_file_name(format!("rollout-2026-11-08T20-38-31-{THREAD}.jsonl"));
    std::os::unix::fs::symlink(&copied, &linked_outside).unwrap();
    assert!(Rollout::open(fixture.home.path(), &linked_outside, THREAD).is_err());

    for meta in [
        json!({"history_mode": "legacy"}),
        json!({"history_mode": "future"}),
        json!({"history_base": {"rollout_path": "/elsewhere.jsonl", "ordinal": 12}}),
    ] {
        let other = Fixture::with_meta(meta);
        assert!(Rollout::open(other.home.path(), &other.path, THREAD).is_err());
    }
}

#[test]
fn a_replaced_file_or_a_stale_cursor_is_refused() {
    let fixture = Fixture::new();
    let offset = fixture.reply("turn", "msg", "hello");
    let rollout = fixture.open();
    assert!(matches!(
        rollout.page(offset + 1, 10, EPOCH),
        Err(WsError::Invalid(_))
    ));
    assert!(matches!(
        rollout.page(0, 10, EPOCH),
        Err(WsError::Invalid(_))
    ));
    let contents = std::fs::read(&fixture.path).unwrap();
    std::fs::remove_file(&fixture.path).unwrap();
    std::fs::write(&fixture.path, contents).unwrap();
    assert!(matches!(
        rollout.page(offset, 10, EPOCH),
        Err(WsError::Conflict(_))
    ));
}
