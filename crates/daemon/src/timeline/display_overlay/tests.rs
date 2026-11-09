use super::*;
use serde_json::{Value, json};
use std::io::Write;

const SESSION: &str = "11111111-1111-4111-8111-111111111111";
const PROMPT: &str = "22222222-2222-4222-8222-222222222222";

fn user() -> Value {
    json!({"type":"user","sessionId":SESSION,"uuid":"canonical-user","promptId":PROMPT,"timestamp":"2026-01-01T00:00:00Z","message":{"content":"fixture prompt"}})
}

fn assistant(id: &str, api_id: &str, text: &str) -> Value {
    json!({"type":"assistant","sessionId":SESSION,"uuid":id,"requestRef":"request-1","timestamp":"2026-01-01T00:00:01Z","message":{"id":api_id,"content":[{"type":"text","text":text}]}})
}

fn transcript(records: &[Value]) -> (tempfile::TempDir, Transcript) {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join(format!("{SESSION}.jsonl"));
    let mut file = std::fs::File::create(&path).unwrap();
    for record in records {
        writeln!(file, "{record}").unwrap();
    }
    let transcript = Transcript::open(path, SESSION.into(), 7).unwrap();
    (root, transcript)
}

fn message(text: &str) -> Message {
    Message {
        id: "44444444-4444-4444-8444-444444444444".into(),
        ordinal: 0,
        text: text.into(),
        is_final: true,
    }
}

#[test]
fn partial_canonical_text_cannot_retire_a_longer_display_message() {
    let (_root, transcript) =
        transcript(&[user(), assistant("canonical-1", "api-1", "First line.\n")]);
    assert!(matches!(
        resolve(&transcript, PROMPT, &message("First line.\nLast line.")),
        Resolution::Pending(_)
    ));
}

#[test]
fn multiple_api_blocks_share_one_display_ordinal_without_aliasing_record_ids() {
    let (_root, transcript) = transcript(&[
        user(),
        assistant("canonical-1", "api-1", "First line.\n"),
        assistant("canonical-2", "api-1", "Last line."),
        assistant("canonical-3", "api-2", "Another model response."),
    ]);
    let prompt = transcript.display_prompt(PROMPT).unwrap();
    assert_eq!(prompt.groups.len(), 2);
    assert_eq!(prompt.groups[0].items, ["canonical-1:0", "canonical-2:0"]);
    assert!(matches!(
        resolve(&transcript, PROMPT, &message("First line.\nLast line.")),
        Resolution::Canonical
    ));
    let mut second = message("Another model response.");
    second.ordinal = 1;
    assert!(matches!(
        resolve(&transcript, PROMPT, &second),
        Resolution::Canonical
    ));
}

fn assistant_texts(snapshot: &TimelineSnapshot) -> Vec<&str> {
    snapshot
        .items
        .iter()
        .filter_map(|item| match &item.body {
            TimelineBody::Assistant { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn daemon_http_streams_before_canonical_text_and_reconciles_partial_blocks_in_order() {
    use super::super::claude_source::ClaudeSession;
    use crate::agent_driver::AgentSession;
    use crate::claude_display::tests::Fixture;
    let fixture = Fixture::new().await;
    let core = &fixture.raw.daemon.core;
    let pane = fixture.raw.entry.pane.id;
    let (wake, _receive) = tokio::sync::mpsc::channel(1);
    let mut session = ClaudeSession::open(core, pane, 7, wake.clone()).unwrap();
    let original = std::fs::read(&fixture.path).unwrap();
    fixture
        .feed_http(fixture.batch(0, "First line.\n", false))
        .await;
    AgentSession::refresh(&mut session, core, pane).unwrap();
    assert_eq!(assistant_texts(&session.snapshot(None)), ["First line.\n"]);
    assert!(
        session
            .snapshot(Some(UnixMillis(1)))
            .items
            .iter()
            .all(|item| !item.id.starts_with("claude-display:"))
    );
    fixture.feed(fixture.batch(1, "Second line.\n", false));
    let operations = AgentSession::refresh(&mut session, core, pane).unwrap();
    assert!(operations.iter().any(|operation| matches!(operation, TimelineOp::Append { field: TimelineField::Text, text, .. } if text == "Second line.\n")));
    fixture.hook("Stop", PROMPT).await;
    fixture.feed(fixture.batch(2, "Last line.", true));
    AgentSession::refresh(&mut session, core, pane).unwrap();
    assert_eq!(std::fs::read(&fixture.path).unwrap(), original);
    let complete = "First line.\nSecond line.\nLast line.";
    assert_eq!(assistant_texts(&session.snapshot(None)), [complete]);
    fixture.append(assistant("canonical-1", "api-1", "First line.\n"));
    fixture.append(json!({"type":"assistant","sessionId":SESSION,"uuid":"canonical-tool","requestRef":"request-1","timestamp":"2026-01-01T00:00:01Z","message":{"id":"api-1","content":[{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"/fixture/only"}}]}}));
    let operations = AgentSession::refresh(&mut session, core, pane).unwrap();
    assert!(matches!(operations.as_slice(), [TimelineOp::Snapshot(_)]));
    let partial = session.snapshot(None);
    assert_eq!(assistant_texts(&partial), [complete]);
    let live_position = partial
        .items
        .iter()
        .position(|item| item.id.starts_with("claude-display:"))
        .unwrap();
    let tool_position = partial
        .items
        .iter()
        .position(|item| matches!(item.body, TimelineBody::Tool(_)))
        .unwrap();
    assert!(live_position < tool_position);
    let prior_cursor = partial.cursor;
    fixture.append(assistant(
        "canonical-2",
        "api-1",
        "Second line.\nLast line.",
    ));
    let operations = AgentSession::refresh(&mut session, core, pane).unwrap();
    assert!(matches!(operations.as_slice(), [TimelineOp::Snapshot(_)]));
    let final_snapshot = session.snapshot(None);
    assert_eq!(
        assistant_texts(&final_snapshot),
        ["First line.\n", "Second line.\nLast line."]
    );
    assert!(
        final_snapshot
            .items
            .iter()
            .all(|item| !item.id.starts_with("claude-display:"))
    );
    let canonical_position = final_snapshot
        .items
        .iter()
        .position(|item| item.id == "canonical-1:0")
        .unwrap();
    let tool_position = final_snapshot
        .items
        .iter()
        .position(|item| matches!(item.body, TimelineBody::Tool(_)))
        .unwrap();
    let tail_position = final_snapshot
        .items
        .iter()
        .position(|item| item.id == "canonical-2:0")
        .unwrap();
    assert!(canonical_position < tool_position && tool_position < tail_position);
    assert_eq!(final_snapshot.cursor.epoch, prior_cursor.epoch);
    assert!(final_snapshot.cursor.sequence > prior_cursor.sequence);
    let reopened = ClaudeSession::open(core, pane, 8, wake).unwrap();
    assert_eq!(
        assistant_texts(&reopened.snapshot(None)),
        assistant_texts(&final_snapshot)
    );
    fixture.raw.daemon.shutdown().await;
}

#[test]
fn unknown_canonical_times_are_hidden_even_at_a_zero_since_boundary() {
    let mut record = assistant("unknown-date", "api-1", "Unknown original time.");
    record.as_object_mut().unwrap().remove("timestamp");
    let (_root, transcript) = transcript(&[user(), record]);
    assert!(assistant_texts(&transcript.snapshot(60, Some(UnixMillis(0)))).is_empty());
}

#[test]
fn tool_only_api_responses_do_not_consume_a_display_ordinal() {
    let tool = json!({"type":"assistant","sessionId":SESSION,"uuid":"canonical-tool","requestRef":"request-1","timestamp":"2026-01-01T00:00:01Z","message":{"id":"api-tool","content":[{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"/fixture/only"}}]}});
    let (_root, transcript) = transcript(&[
        user(),
        tool,
        assistant("canonical-text", "api-text", "After tool."),
    ]);
    assert_eq!(transcript.display_prompt(PROMPT).unwrap().groups.len(), 1);
    assert!(matches!(
        resolve(&transcript, PROMPT, &message("After tool.")),
        Resolution::Canonical
    ));
}
