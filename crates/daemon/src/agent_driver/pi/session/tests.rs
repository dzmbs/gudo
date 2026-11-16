use super::*;
use proto::FileChange;
use serde_json::{Value, json};
use std::io::Write;

pub(crate) const SESSION: &str = "019a7f3c-5e10-7742-b6b3-2764bf9990b4";
pub(crate) const CWD: &str = "/fixture/project";
const EPOCH: u64 = 7;

/// A pi agent folder with one session, written in the format pi 1.4 records.
pub(crate) struct Fixture {
    pub agent_dir: tempfile::TempDir,
    pub path: PathBuf,
    next: std::cell::Cell<u32>,
    last: std::cell::RefCell<Option<String>>,
}

impl Fixture {
    pub fn new() -> Self {
        Self::with_header(json!({"type": "session", "version": 3, "id": SESSION, "timestamp": "2026-11-08T19:38:29.000Z", "cwd": CWD}))
    }

    pub fn with_header(header: Value) -> Self {
        let agent_dir = tempfile::tempdir().unwrap();
        let folder = agent_dir
            .path()
            .join("sessions/--fixture-project--");
        std::fs::create_dir_all(&folder).unwrap();
        let path = folder.join(format!("2026-11-08T19-38-29-000Z_{SESSION}.jsonl"));
        let fixture = Self {
            agent_dir,
            path,
            next: std::cell::Cell::new(0),
            last: std::cell::RefCell::new(None),
        };
        fixture.append(&header);
        fixture
    }

    pub fn root(&self) -> PathBuf {
        self.agent_dir.path().join("sessions")
    }

    pub fn append(&self, record: &Value) -> u64 {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .unwrap();
        let offset = file.metadata().unwrap().len();
        writeln!(file, "{record}").unwrap();
        if record["type"] != "session"
            && let Some(id) = record["id"].as_str()
        {
            *self.last.borrow_mut() = Some(id.to_owned());
        }
        offset
    }

    /// Appends a message entry whose parent is the entry before it, returning its id.
    pub fn message(&self, message: Value) -> String {
        let index = self.next.get();
        self.next.set(index + 1);
        let id = format!("e{index:07x}");
        let parent = self.last.borrow().clone();
        self.append(&json!({
            "type": "message", "id": id, "parentId": parent,
            "timestamp": "2026-11-08T19:40:00.000Z", "message": message,
        }));
        id
    }

    pub fn user(&self, text: &str) -> String {
        self.message(json!({"role": "user", "content": [{"type": "text", "text": text}], "timestamp": 1_794_166_800_000_u64}))
    }

    pub fn reply(&self, text: &str) -> String {
        self.message(json!({
            "role": "assistant", "content": [{"type": "text", "text": text}],
            "api": "anthropic-messages", "provider": "anthropic", "model": "claude-opus-4-5",
            "usage": {}, "stopReason": "stop", "timestamp": 1_794_166_801_000_u64,
        }))
    }

    pub fn open(&self) -> PiSession {
        PiSession::open(&self.root(), &self.path, SESSION).unwrap()
    }
}

fn shaped(fixture: &Fixture) -> Shaped {
    let session = fixture.open();
    session.newest(session.end().unwrap(), EPOCH).unwrap()
}

fn bodies(shaped: &Shaped) -> Vec<&TimelineBody> {
    shaped.items.iter().map(|(_, item)| &item.body).collect()
}

fn tool_of(body: &TimelineBody) -> &TimelineTool {
    match body {
        TimelineBody::Tool(tool) => tool,
        body => panic!("expected a tool, got {body:?}"),
    }
}

#[test]
fn messages_thinking_and_tools_become_the_rows_chat_shows() {
    let fixture = Fixture::new();
    fixture.message(json!({"role": "system", "content": "", "sections": {}, "timestamp": 1}));
    fixture.user("Fix the test");
    fixture.message(json!({
        "role": "assistant", "durationMs": 4200, "model": "claude-opus-4-5", "stopReason": "toolUse",
        "content": [
            {"type": "thinking", "thinking": "Look at it first.", "thinkingSignature": "opaque"},
            {"type": "text", "text": "Reading it."},
            {"type": "toolCall", "id": "call-1", "name": "read", "arguments": {"path": "src/lib.rs"}},
            {"type": "toolCall", "id": "call-2", "name": "bash", "arguments": {"command": "cargo test", "timeout": 60}},
        ],
        "timestamp": 1_794_166_801_000_u64,
    }));
    fixture.message(json!({"role": "toolResult", "toolCallId": "call-1", "toolName": "read", "content": [{"type": "text", "text": "fn main() {}"}], "isError": false, "durationMs": 3, "timestamp": 2}));
    fixture.message(json!({"role": "toolResult", "toolCallId": "call-2", "toolName": "bash", "content": [{"type": "text", "text": "1 failed"}], "isError": true, "timestamp": 3}));
    fixture.append(&json!({"type": "session_info", "id": "info", "parentId": null, "timestamp": "x", "name": "Fix tests"}));

    let shaped = shaped(&fixture);
    assert_eq!(shaped.title.as_deref(), Some("Fix tests"));
    assert_eq!(shaped.model.as_deref(), Some("claude-opus-4-5"));
    let bodies = bodies(&shaped);
    assert_eq!(bodies.len(), 5, "{bodies:?}");
    assert!(matches!(bodies[0], TimelineBody::User { text, .. } if text == "Fix the test"));
    assert_eq!(shaped.items[0].1.origin, TimelineOrigin::Terminal);
    assert_eq!(
        bodies[1],
        &TimelineBody::Thinking {
            text: Some("Look at it first.".into()),
            duration_ms: Some(4200)
        }
    );
    assert!(matches!(bodies[2], TimelineBody::Assistant { text, .. } if text == "Reading it."));
    let read = tool_of(bodies[3]);
    assert_eq!(read.kind, TimelineToolKind::Read);
    assert_eq!(read.title, "/fixture/project/src/lib.rs");
    assert!(read.input.contains("\"path\":\"/fixture/project/src/lib.rs\""));
    assert_eq!(read.status, TimelineToolStatus::Done);
    assert_eq!(read.duration_ms, Some(3));
    assert_eq!(read.output.as_ref().unwrap().preview, "fn main() {}");
    let shell = tool_of(bodies[4]);
    assert_eq!((shell.kind, shell.title.as_str()), (TimelineToolKind::Shell, "cargo test"));
    assert_eq!(shell.status, TimelineToolStatus::Failed);
    assert!(shaped.results.is_empty());
}

#[test]
fn compaction_errors_interruptions_and_model_changes_are_notices() {
    let fixture = Fixture::new();
    fixture.user("one");
    fixture.append(&json!({"type": "compaction", "id": "c1", "parentId": "e0000000", "timestamp": "x", "summary": "s", "firstKeptEntryId": "e0000000", "tokensBefore": 260445}));
    fixture.append(&json!({"type": "model_change", "id": "m1", "parentId": "c1", "timestamp": "x", "provider": "openai", "modelId": "gpt-5"}));
    fixture.message(json!({"role": "assistant", "content": [], "stopReason": "error", "errorMessage": "overloaded", "timestamp": 5}));
    fixture.message(json!({"role": "assistant", "content": [], "stopReason": "aborted", "timestamp": 6}));
    let shaped = shaped(&fixture);
    let notices: Vec<_> = bodies(&shaped)
        .into_iter()
        .filter_map(|body| match body {
            TimelineBody::Notice { kind, text } => Some((*kind, text.as_str())),
            _ => None,
        })
        .collect();
    assert_eq!(
        notices,
        [
            (TimelineNoticeKind::Compacted, "Context compacted from 260,445 tokens"),
            (TimelineNoticeKind::ModelChanged, "Model changed to gpt-5"),
            (TimelineNoticeKind::Error, "overloaded"),
            (TimelineNoticeKind::Interrupted, "Interrupted"),
        ]
    );
    assert_eq!(shaped.model.as_deref(), Some("gpt-5"));
}

#[test]
fn going_back_in_the_tree_is_said_where_the_new_branch_starts() {
    let fixture = Fixture::new();
    let first = fixture.user("first");
    fixture.reply("one");
    fixture.append(&json!({"type": "message", "id": "late", "parentId": first, "timestamp": "x", "message": {"role": "user", "content": "again", "timestamp": 9}}));
    let shaped = shaped(&fixture);
    assert!(matches!(
        bodies(&shaped)[2],
        TimelineBody::Notice { kind: TimelineNoticeKind::Cleared, .. }
    ));
    assert!(matches!(bodies(&shaped)[3], TimelineBody::User { text, .. } if text == "again"));
}

#[test]
fn an_edit_shows_the_start_of_its_change() {
    let fixture = Fixture::new();
    fixture.message(json!({"role": "assistant", "stopReason": "toolUse", "timestamp": 1, "content": [
        {"type": "toolCall", "id": "edit-1", "name": "edit", "arguments": {"path": "/w/a.rs", "edits": [{"oldText": "old", "newText": "new"}]}}
    ]}));
    fixture.message(json!({"role": "toolResult", "toolCallId": "edit-1", "toolName": "edit", "isError": false, "timestamp": 2,
        "content": [{"type": "text", "text": "Edited /w/a.rs"}],
        "details": {"diff": "...", "firstChangedLine": 2, "patch": "--- /w/a.rs\n+++ /w/a.rs\n@@ -2,1 +2,1 @@\n-old\n+new\n"}}));
    let shaped = shaped(&fixture);
    let edit = tool_of(bodies(&shaped)[0]);
    assert_eq!(edit.kind, TimelineToolKind::Edit);
    assert_eq!(edit.diff.len(), 1);
    assert_eq!(edit.diff[0].change, FileChange::Modified);
    assert_eq!((edit.diff[0].additions, edit.diff[0].deletions), (1, 1));
}

#[test]
fn a_result_after_its_call_record_comes_as_a_result() {
    let fixture = Fixture::new();
    fixture.message(json!({"role": "assistant", "stopReason": "toolUse", "timestamp": 1, "content": [
        {"type": "toolCall", "id": "slow", "name": "bash", "arguments": {"command": "sleep 9"}}
    ]}));
    let session = fixture.open();
    let end = session.end().unwrap();
    let shaped = session.newest(end, EPOCH).unwrap();
    assert_eq!(tool_of(bodies(&shaped)[0]).status, TimelineToolStatus::Running);

    fixture.message(json!({"role": "toolResult", "toolCallId": "slow", "toolName": "bash", "content": [{"type": "text", "text": "done"}], "isError": false, "timestamp": 2}));
    let mut stream = RecordStream::at_boundary(end);
    let (appended, more) = session.appended(&mut stream, EPOCH).unwrap();
    assert!(!more);
    assert!(appended.items.is_empty());
    assert_eq!(appended.results.len(), 1);
    let mut item = shaped.items[0].1.clone();
    finish(&mut item, &appended.results[0], EPOCH);
    assert_eq!(tool_of(&item.body).status, TimelineToolStatus::Done);
}

#[test]
fn pages_continue_below_without_repeating_and_find_later_results() {
    let fixture = Fixture::new();
    for index in 0..150 {
        fixture.reply(&format!("reply {index}"));
    }
    let call = fixture.append(&json!({"type": "message", "id": "call", "parentId": null, "timestamp": "x", "message": {
        "role": "assistant", "stopReason": "toolUse", "timestamp": 1,
        "content": [{"type": "toolCall", "id": "late", "name": "bash", "arguments": {"command": "ls"}}]}}));
    let after = fixture.append(&json!({"type": "message", "id": "result", "parentId": "call", "timestamp": "x", "message": {
        "role": "toolResult", "toolCallId": "late", "toolName": "bash", "content": [{"type": "text", "text": "a b"}], "isError": false, "timestamp": 2}}));
    let session = fixture.open();
    let page = session.page(after, 100, EPOCH).unwrap();
    assert_eq!(page.items.len(), 100);
    let last = page.items.last().unwrap();
    assert_eq!(tool_of(&last.body).status, TimelineToolStatus::Done);
    let older = session.page(page.before.unwrap(), 100, EPOCH).unwrap();
    assert_eq!(older.items.len(), 51);
    assert_eq!(older.before, None);
    let texts: Vec<_> = older
        .items
        .iter()
        .chain(&page.items)
        .filter_map(|item| match &item.body {
            TimelineBody::Assistant { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect();
    let expected: Vec<_> = (0..150).map(|index| format!("reply {index}")).collect();
    assert_eq!(texts, expected);
    assert!(session.page(call + 1, 10, EPOCH).is_err());
}

#[test]
fn long_text_and_tool_output_read_back_in_full() {
    let fixture = Fixture::new();
    let long = "line\n".repeat(20_000);
    fixture.reply(&long);
    fixture.message(json!({"role": "assistant", "stopReason": "toolUse", "timestamp": 1, "content": [
        {"type": "toolCall", "id": "out", "name": "bash", "arguments": {"command": "yes"}}
    ]}));
    let output = "y\n".repeat(10_000);
    fixture.message(json!({"role": "toolResult", "toolCallId": "out", "toolName": "bash", "content": [{"type": "text", "text": output}], "isError": false, "timestamp": 2}));
    let session = fixture.open();
    let shaped = session.newest(session.end().unwrap(), EPOCH).unwrap();
    let TimelineBody::LongText { role, content } = bodies(&shaped)[0] else {
        panic!("expected long text");
    };
    assert_eq!(*role, TimelineTextRole::Assistant);
    assert_eq!(content.bytes, long.len() as u64);
    let page = session.text(&content.handle, 0, 256 * 1024).unwrap();
    assert_eq!(page.text, long);
    let tool = tool_of(bodies(&shaped)[1]);
    let handle = &tool.output.as_ref().unwrap().handle;
    assert_eq!(session.text(handle, 0, 256 * 1024).unwrap().text, output);
}

#[test]
fn an_unknown_format_or_another_session_says_so() {
    let refusal = |header: Value| {
        let fixture = Fixture::with_header(header);
        match PiSession::open(&fixture.root(), &fixture.path, SESSION) {
            Err(error) => error,
            Ok(_) => panic!("opened"),
        }
    };
    let older = refusal(json!({"type": "session", "version": 2, "id": SESSION, "cwd": CWD}));
    assert!(matches!(older, WsError::Unavailable(message) if message.contains("older format")));
    let newer = refusal(json!({"type": "session", "version": 4, "id": SESSION, "cwd": CWD}));
    assert!(matches!(newer, WsError::Unavailable(message) if message.contains("Update the helper")));
    let other = refusal(json!({"type": "session", "version": 3, "id": "someone-else", "cwd": CWD}));
    assert!(matches!(other, WsError::Denied(_)));
    let headless = refusal(json!({"type": "message", "id": "x"}));
    assert!(matches!(headless, WsError::Unavailable(message) if message.contains("session record")));
}

#[test]
fn a_file_outside_the_sessions_folder_or_a_link_is_refused() {
    let fixture = Fixture::new();
    let elsewhere = tempfile::tempdir().unwrap();
    let outside = elsewhere.path().join(format!("x_{SESSION}.jsonl"));
    std::fs::copy(&fixture.path, &outside).unwrap();
    assert!(matches!(
        PiSession::open(&fixture.root(), &outside, SESSION),
        Err(WsError::Denied(_))
    ));
    let link = fixture.path.with_file_name(format!("link_{SESSION}.jsonl"));
    std::os::unix::fs::symlink(&outside, &link).unwrap();
    assert!(PiSession::open(&fixture.root(), &link, SESSION).is_err());
}
