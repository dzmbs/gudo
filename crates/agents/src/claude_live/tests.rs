use super::*;
use serde_json::{Value, json};

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../tests/fixtures/claude/message_display_2.1.319.json"
    ))
    .unwrap()
}

fn raw_batch() -> Value {
    fixture()["events"][1].clone()
}

fn decode(value: Value) -> ClaudeDisplayBatch {
    ClaudeDisplayBatch::decode(&serde_json::to_vec(&value).unwrap()).unwrap()
}

fn stream() -> ClaudeDisplayStream {
    let batch = decode(raw_batch());
    ClaudeDisplayStream::new(batch.session_id, batch.prompt_id)
}

#[test]
fn captured_batches_preserve_text_and_allow_final_flush_after_stop() {
    let recording = fixture();
    assert_eq!(recording["events"][2]["hook_event_name"], "Stop");
    let mut stream = stream();
    for event in recording["events"].as_array().unwrap() {
        if event["hook_event_name"] == "MessageDisplay" {
            stream.apply(decode(event.clone())).unwrap();
        }
    }
    let message = &stream.messages()[0];
    assert_eq!(
        message.text,
        recording["canonical"]["message"]["content"][0]["text"]
    );
    assert_ne!(message.id, recording["canonical"]["uuid"]);
    assert!(message.is_final);
    assert_eq!(message.ordinal, 0);
}

#[test]
fn read_round_trip_keeps_turn_and_resets_index_for_the_next_display_message() {
    let mut stream = stream();
    stream.apply(decode(raw_batch())).unwrap();
    let mut final_first = fixture()["events"][3].clone();
    final_first["delta"] = json!("");
    stream.apply(decode(final_first)).unwrap();
    let next_id = "66666666-6666-4666-8666-666666666666";
    let mut next = raw_batch();
    next["message_id"] = json!(next_id);
    next["delta"] = json!("Second fixture line.\n");
    stream.apply(decode(next)).unwrap();
    let mut final_next = fixture()["events"][3].clone();
    final_next["message_id"] = json!(next_id);
    stream.apply(decode(final_next)).unwrap();
    assert_eq!(stream.messages().len(), 2);
    assert_eq!(stream.messages()[0].text, "First fixture line.\n");
    assert_eq!(
        stream.messages()[1].text,
        "Second fixture line.\nSecond fixture line without newline."
    );
    assert!(stream.messages().iter().all(|message| message.is_final));
    assert_eq!(stream.messages()[1].ordinal, 1);
}

#[test]
fn exact_duplicate_is_ignored_but_conflicting_duplicate_and_gap_do_not_mutate_text() {
    let mut stream = stream();
    stream.apply(decode(raw_batch())).unwrap();
    assert_eq!(
        stream.apply(decode(raw_batch())),
        Ok(ClaudeDisplayChange::Duplicate)
    );
    for (index, delta) in [(0, "conflicting line\n"), (2, "missing batch\n")] {
        let mut batch = raw_batch();
        batch["index"] = json!(index);
        batch["delta"] = json!(delta);
        assert_eq!(stream.apply(decode(batch)), Err(ClaudeDisplayError::Order));
        assert_eq!(stream.messages()[0].text, "First fixture line.\n");
    }
}

#[test]
fn missing_first_batch_and_context_replacement_fail_closed() {
    let mut stream = stream();
    let mut gap = raw_batch();
    gap["index"] = json!(1);
    assert_eq!(stream.apply(decode(gap)), Err(ClaudeDisplayError::Order));
    assert!(stream.messages().is_empty());
    stream.apply(decode(raw_batch())).unwrap();
    for field in ["session_id", "prompt_id", "turn_id"] {
        let mut batch = fixture()["events"][3].clone();
        batch[field] = json!("99999999-9999-4999-8999-999999999999");
        assert_eq!(
            stream.apply(decode(batch)),
            Err(ClaudeDisplayError::Context)
        );
    }
    assert_eq!(stream.messages()[0].text, "First fixture line.\n");
}

#[test]
fn empty_final_flush_and_retired_late_frames_do_not_create_extra_rows() {
    let mut stream = stream();
    stream.apply(decode(raw_batch())).unwrap();
    let mut final_batch = fixture()["events"][3].clone();
    final_batch["delta"] = json!("");
    stream.apply(decode(final_batch)).unwrap();
    assert!(stream.messages()[0].is_final);
    let message_id = stream.messages()[0].id.clone();
    stream.retire(&message_id);
    assert_eq!(
        stream.apply(decode(fixture()["events"][3].clone())),
        Ok(ClaudeDisplayChange::Duplicate)
    );
    assert!(stream.messages().is_empty());
}

#[test]
fn retired_identity_bound_never_forgets_and_readmits_a_replay() {
    let mut stream = stream();
    for ordinal in 0..64 {
        let mut batch = raw_batch();
        let id = format!("{ordinal:08x}-1111-4111-8111-111111111111");
        batch["message_id"] = json!(id);
        stream.apply(decode(batch)).unwrap();
        stream.retire(&id);
    }
    assert!(stream.messages().is_empty());
    assert_eq!(stream.bytes, 0);
    assert_eq!(stream.retired.len(), 64);
    let mut replay = raw_batch();
    replay["message_id"] = json!("00000000-1111-4111-8111-111111111111");
    assert_eq!(
        stream.apply(decode(replay)),
        Ok(ClaudeDisplayChange::Duplicate)
    );
    assert_eq!(
        stream.apply(decode(raw_batch())),
        Err(ClaudeDisplayError::Limit)
    );
}

#[test]
fn batch_shape_and_size_are_bounded() {
    for (field, value) in [
        ("hook_event_name", json!("PermissionRequest")),
        ("agent_id", json!("subagent")),
        ("message_id", json!("../message")),
        ("cwd", json!("relative/project")),
        ("transcript_path", json!("relative/transcript")),
        ("delta", json!("unfinished non-final line")),
    ] {
        let mut batch = raw_batch();
        batch[field] = value;
        assert!(ClaudeDisplayBatch::decode(&serde_json::to_vec(&batch).unwrap()).is_err());
    }
    let mut oversized = raw_batch();
    oversized["delta"] = json!("x".repeat(CLAUDE_DISPLAY_BATCH_LIMIT));
    assert_eq!(
        ClaudeDisplayBatch::decode(&serde_json::to_vec(&oversized).unwrap()).unwrap_err(),
        ClaudeDisplayError::Limit
    );
}

#[test]
fn active_message_and_text_bounds_are_enforced() {
    let mut stream = stream();
    for ordinal in 0..MESSAGE_COUNT_LIMIT {
        let mut batch = raw_batch();
        batch["message_id"] = json!(format!("{ordinal:08x}-1111-4111-8111-111111111111"));
        stream.apply(decode(batch)).unwrap();
    }
    assert_eq!(
        stream.apply(decode(raw_batch())),
        Err(ClaudeDisplayError::Limit)
    );
    let mut stream = self::stream();
    for index in 0..4 {
        let mut batch = raw_batch();
        batch["index"] = json!(index);
        batch["delta"] = json!(format!("{}\n", "x".repeat(60 * 1024)));
        stream.apply(decode(batch)).unwrap();
    }
    let before = stream.messages()[0].text.len();
    let mut batch = raw_batch();
    batch["index"] = json!(4);
    batch["delta"] = json!(format!("{}\n", "x".repeat(60 * 1024)));
    assert_eq!(stream.apply(decode(batch)), Err(ClaudeDisplayError::Limit));
    assert_eq!(stream.messages()[0].text.len(), before);
}

#[test]
fn version_gate_accepts_supported_cli_versions_not_guessed_output() {
    for version in [
        "2.1.69 (Claude Code)\n",
        "2.1.319 (Claude Code)",
        "2.2.0 (Claude Code)",
    ] {
        assert!(claude_supports_message_display(version));
    }
    for version in [
        "2.1.68 (Claude Code)",
        "1.9.999 (Claude Code)",
        "2.1.319",
        "2.1.319-beta (Claude Code)",
        "02.1.319 (Claude Code)",
        "2.1.319.1 (Claude Code)",
        "+2.1.319 (Claude Code)",
    ] {
        assert!(!claude_supports_message_display(version));
    }
    assert!(!claude_supports_message_display(&"1".repeat(129)));
}
