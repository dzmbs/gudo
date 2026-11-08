use super::*;
use serde_json::{Value, json};

fn start(binding: &mut CodexBinding, id: Value) {
    binding
        .observe_tui(&json!({"id": id, "method": "thread/start", "params": {}}).to_string())
        .unwrap();
}

fn reply(binding: &mut CodexBinding, id: Value, thread: &str) -> Result<(), CodexBindingError> {
    binding.observe_server(
        &json!({"id": id, "result": {"thread": {"id": thread, "cwd": "/same"}}}).to_string(),
    )
}

#[test]
fn ambiguous_duplicate_identity_fields_never_bind() {
    for frame in [
        r#"{"id":1,"id":2,"method":"thread/start"}"#,
        r#"{"id":1,"method":"thread/resume","params":{"threadId":"first","threadId":"second"}}"#,
    ] {
        let mut binding = CodexBinding::default();
        assert_eq!(
            binding.observe_tui(frame),
            Err(CodexBindingError::InvalidFrame)
        );
        assert!(binding.binding().is_none());
    }
    let mut binding = CodexBinding::default();
    start(&mut binding, json!(1));
    assert_eq!(
        binding.observe_server(r#"{"id":1,"result":{"thread":{"id":"first","id":"second"}}}"#),
        Err(CodexBindingError::InvalidFrame)
    );
    assert!(binding.binding().is_none());
}

#[test]
fn oversized_and_control_bearing_ids_never_enter_the_binding() {
    for id in [
        "x".repeat(MAX_ID_BYTES + 1),
        "line\nnext".into(),
        String::new(),
    ] {
        let mut binding = CodexBinding::default();
        let frame = json!({"id": id, "method": "thread/start"}).to_string();
        assert!(binding.observe_tui(&frame).is_err());
        assert!(binding.binding().is_none());
    }
}

#[test]
fn fixture_response_binds_without_a_bootstrap_turn_or_second_client() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../daemon/tests/fixtures/timeline/codex-0.166.0.json"
    ))
    .unwrap();
    let frames = fixture["clients"][0].as_array().unwrap();
    let response = frames.iter().find(|frame| frame["id"] == 2).unwrap();
    let notification = frames
        .iter()
        .find(|frame| frame["method"] == "thread/started")
        .unwrap();
    let mut binding = CodexBinding::default();
    binding.observe_server(&notification.to_string()).unwrap();
    assert!(binding.binding().is_none());
    start(&mut binding, json!(2));
    binding.observe_server(&notification.to_string()).unwrap();
    assert!(binding.binding().is_none());
    binding.observe_server(&response.to_string()).unwrap();
    assert_eq!(
        binding.binding().unwrap().thread_id(),
        response["result"]["thread"]["id"]
    );
}

#[test]
fn wrong_rpc_and_superseded_responses_do_not_bind_even_at_the_same_cwd() {
    let mut binding = CodexBinding::default();
    start(&mut binding, json!(1));
    start(&mut binding, json!(2));
    reply(&mut binding, json!(1), "first").unwrap();
    reply(&mut binding, json!(99), "unrelated").unwrap();
    assert!(binding.binding().is_none());
    reply(&mut binding, json!(2), "current").unwrap();
    assert_eq!(binding.binding().unwrap().thread_id(), "current");
}

#[test]
fn same_thread_round_trip_and_another_connection_cannot_revive_a_snapshot() {
    let mut first = CodexBinding::default();
    start(&mut first, json!(1));
    reply(&mut first, json!(1), "same").unwrap();
    let snapshot = first.binding().unwrap().clone();
    assert!(first.is_current(&snapshot));
    first
        .observe_tui(r#"{"id":2,"method":"thread/resume","params":{"threadId":"same"}}"#)
        .unwrap();
    assert!(!first.is_current(&snapshot));
    reply(&mut first, json!(2), "same").unwrap();
    assert!(!first.is_current(&snapshot));
    let mut second = CodexBinding::default();
    start(&mut second, json!(1));
    reply(&mut second, json!(1), "same").unwrap();
    assert!(!second.is_current(first.binding().unwrap()));
}

#[test]
fn mismatched_resume_closes_irreversibly_and_never_keeps_the_old_binding() {
    let mut binding = CodexBinding::default();
    start(&mut binding, json!(1));
    reply(&mut binding, json!(1), "previous").unwrap();
    binding
        .observe_tui(r#"{"id":2,"method":"thread/resume","params":{"threadId":"requested"}}"#)
        .unwrap();
    assert_eq!(
        reply(&mut binding, json!(2), "another"),
        Err(CodexBindingError::ThreadMismatch)
    );
    assert!(binding.binding().is_none());
    assert_eq!(
        reply(&mut binding, json!(2), "requested"),
        Err(CodexBindingError::Closed)
    );
}

#[test]
fn numeric_and_string_ids_are_distinct_but_reused_binding_ids_close() {
    let mut binding = CodexBinding::default();
    start(&mut binding, json!(1));
    start(&mut binding, json!("1"));
    reply(&mut binding, json!(1), "old").unwrap();
    assert!(binding.binding().is_none());
    reply(&mut binding, json!("1"), "current").unwrap();
    assert_eq!(binding.binding().unwrap().thread_id(), "current");
    assert_eq!(
        binding.observe_tui(r#"{"id":1,"method":"thread/start"}"#),
        Err(CodexBindingError::InvalidFrame)
    );
    assert!(binding.binding().is_none());
}

#[test]
fn malformed_change_and_pending_id_collision_retire_native_binding() {
    for frame in [
        r#"{"id":2,"method":"thread/resume","params":{}}"#,
        r#"{"id":2,"method":"thread/start","params":{}}"#,
    ] {
        let mut binding = CodexBinding::default();
        start(&mut binding, json!(1));
        reply(&mut binding, json!(1), "previous").unwrap();
        if frame.contains("thread/start") {
            binding.observe_tui(frame).unwrap();
            assert_eq!(
                binding.observe_tui(r#"{"id":2,"method":"models/list"}"#),
                Err(CodexBindingError::InvalidFrame)
            );
        } else {
            assert!(binding.observe_tui(frame).is_err());
        }
        assert!(binding.binding().is_none());
    }
}

#[test]
fn allowance_does_not_shrink_terminal_transport_but_fails_closed_for_pending_identity() {
    let oversized = "x".repeat(MAX_FRAME_BYTES + 1);
    let mut binding = CodexBinding::default();
    start(&mut binding, json!(1));
    reply(&mut binding, json!(1), "current").unwrap();
    let snapshot = binding.binding().unwrap().clone();
    binding.observe_server(&oversized).unwrap();
    assert!(binding.is_current(&snapshot));
    start(&mut binding, json!(2));
    assert_eq!(
        binding.observe_server(&oversized),
        Err(CodexBindingError::TooLarge)
    );
    assert!(!binding.is_current(&snapshot));
    assert_eq!(oversized.len(), MAX_FRAME_BYTES + 1);
}

#[test]
fn request_identity_storage_is_bounded() {
    let mut binding = CodexBinding::default();
    for id in 0..MAX_BINDING_REQUESTS {
        start(&mut binding, json!(id));
    }
    assert_eq!(binding.seen.len(), MAX_BINDING_REQUESTS);
    let frame = json!({"id": MAX_BINDING_REQUESTS, "method": "thread/start"}).to_string();
    assert_eq!(
        binding.observe_tui(&frame),
        Err(CodexBindingError::Exhausted)
    );
    assert!(binding.seen.is_empty());
    assert!(binding.binding().is_none());
}

#[test]
fn rpc_error_keeps_no_binding_and_a_fresh_request_can_succeed() {
    let mut binding = CodexBinding::default();
    start(&mut binding, json!(1));
    binding
        .observe_server(r#"{"id":1,"error":{"code":-32000,"message":"no rollout"}}"#)
        .unwrap();
    assert!(binding.binding().is_none());
    start(&mut binding, json!(2));
    reply(&mut binding, json!(2), "fresh").unwrap();
    assert_eq!(binding.binding().unwrap().thread_id(), "fresh");
    binding.close();
    assert!(binding.binding().is_none());
}
