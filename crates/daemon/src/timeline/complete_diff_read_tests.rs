use super::*;
use serde_json::{Value, json};

fn record() -> Value {
    json!({"type": "user", "sessionId": "fixture", "timestamp": "2000-01-01T00:00:00Z",
        "message": {"content": [{"type": "tool_result", "tool_use_id": "tool", "content": "result"}]},
        "toolUseResult": {"filePath": "/fixture/file", "structuredPatch": [
            {"oldStart": 0, "oldLines": 0, "newStart": 1, "newLines": 20, "lines": vec!["+line"; 20]}]}})
}

fn opened(record: Value) -> (tempfile::TempDir, Transcript) {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("fixture.jsonl");
    std::fs::write(&path, format!("{record}\n")).unwrap();
    let transcript = Transcript::open(path, "fixture".into(), 7).unwrap();
    (root, transcript)
}

#[test]
fn the_result_handle_reads_complete_changes_not_the_cached_preview() {
    let (_root, mut transcript) = opened(record());
    let snapshot = transcript.snapshot(60, None);
    let TimelineBody::Tool(tool) = &snapshot.items[0].body else {
        panic!("tool result")
    };
    assert_eq!(tool.diff[0].hunks[0].lines.len(), 6);
    assert!(tool.diff[0].hunks_omitted);
    let handle = tool.output.as_ref().unwrap().handle.to_string();
    let full = transcript.tool_diff(&handle, None).unwrap();
    assert_eq!(full[0].hunks[0].lines.len(), 20);
    assert!(!full[0].hunks_omitted);
}

#[test]
fn result_identity_and_since_join_rules_apply_before_reading_changes() {
    let (_root, mut transcript) = opened(record());
    assert!(matches!(
        transcript.tool_diff("7:0:other", None),
        Err(WsError::Unavailable(_))
    ));
    assert!(matches!(
        transcript.tool_diff("7:1:tool", None),
        Err(WsError::Invalid(_))
    ));
    assert!(matches!(
        transcript.tool_diff("8:0:tool", None),
        Err(WsError::Conflict(_))
    ));
    assert!(matches!(
        transcript.tool_diff("7:0:tool", Some(UnixMillis(1_000_000_000_000))),
        Err(WsError::Denied(_))
    ));
}

#[test]
fn hidden_and_foreign_records_cannot_be_used_as_diff_handles() {
    for (kind, sidechain, session) in [
        ("user", true, "fixture"),
        ("future-record", false, "fixture"),
        ("assistant", false, "fixture"),
        ("user", false, "foreign"),
    ] {
        let mut value = record();
        value["type"] = json!(kind);
        value["isSidechain"] = json!(sidechain);
        value["sessionId"] = json!(session);
        let (_root, mut transcript) = opened(value);
        assert!(matches!(
            transcript.tool_diff("7:0:tool", None),
            Err(WsError::Denied(_))
        ));
    }
}

#[test]
fn shared_rich_metadata_never_selects_between_multiple_tool_results() {
    let mut value = record();
    value["message"]["content"]
        .as_array_mut()
        .unwrap()
        .push(json!({"type": "tool_result", "tool_use_id": "other", "content": "other result"}));
    let (_root, mut transcript) = opened(value);
    assert!(matches!(
        transcript.tool_diff("7:0:tool", None),
        Err(WsError::Unavailable(_))
    ));
    assert!(matches!(
        transcript.tool_diff("7:0:other", None),
        Err(WsError::Unavailable(_))
    ));
}

#[test]
fn replacing_the_transcript_cannot_retarget_an_old_result_handle() {
    let (_root, mut transcript) = opened(record());
    std::fs::write(
        &transcript.path,
        "{\"type\":\"user\",\"message\":{\"content\":\"replaced\"}}\n",
    )
    .unwrap();
    assert!(matches!(
        transcript.tool_diff("7:0:tool", None),
        Err(WsError::Conflict(_))
    ));
}
