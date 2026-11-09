use super::super::*;
use serde_json::{Value, json};

fn resume(state: &mut State, turns: Value) {
    state.observe(
        &json!({"id":9,"method":"thread/resume","params":{"threadId":"primary"}}).to_string(),
        Direction::FromTui,
    );
    state.observe(
        &json!({"id":9,"result":{"thread":{"id":"primary","turns":turns}}}).to_string(),
        Direction::FromServer,
    );
}

fn turn(id: &str, status: &str, text: &str) -> Value {
    json!({"id":id,"status":status,"items":[{"id":"message","type":"agentMessage","text":text}]})
}

#[test]
fn resumed_history_is_complete_and_does_not_recount_old_turns() {
    let mut state = State::new();
    resume(
        &mut state,
        json!([
            turn("old", "completed", "remembered"),
            turn("new", "completed", "continued")
        ]),
    );
    assert!(state.is_bound());
    let snapshot = state
        .projection
        .snapshot(super::super::projection::SNAPSHOT_ITEMS, None);
    assert_eq!(snapshot.items.len(), 2);
    assert_ne!(snapshot.items[0].id, snapshot.items[1].id);
    assert!(
        matches!(&snapshot.items[0].body, proto::TimelineBody::Assistant { text, streaming: false } if text == "remembered")
    );
    assert_eq!(
        state.operations.len(),
        1,
        "one hydrated snapshot, not duplicate incremental appends"
    );
    assert!(matches!(
        state.operations.front(),
        Some(TimelineOp::Snapshot(_))
    ));
    assert_eq!(
        state.effects.len(),
        1,
        "historical completions do not count or notify again"
    );
}

#[test]
fn active_history_accepts_subsequent_deltas_without_restarting_the_turn() {
    let mut state = State::new();
    resume(&mut state, json!([turn("active", "inProgress", "first")]));
    state.observe(&json!({"method":"item/agentMessage/delta","params":{"threadId":"primary","turnId":"active","itemId":"message","delta":" tail"}}).to_string(), Direction::FromServer);
    assert!(
        matches!(&state.projection.snapshot(super::super::projection::SNAPSHOT_ITEMS, None).items[0].body, proto::TimelineBody::Assistant { text, streaming: true } if text == "first tail")
    );
    state.observe(&json!({"method":"turn/completed","params":{"threadId":"primary","turn":{"id":"active","status":"completed"}}}).to_string(), Direction::FromServer);
    assert!(matches!(
        &state
            .projection
            .snapshot(super::super::projection::SNAPSHOT_ITEMS, None)
            .items[0]
            .body,
        proto::TimelineBody::Assistant {
            streaming: false,
            ..
        }
    ));
    assert!(!state.closed);
}

#[test]
fn missing_resume_history_closes_chat_and_ambiguous_items_fail_closed() {
    let mut state = State::new();
    state.observe(
        r#"{"id":9,"method":"thread/resume","params":{"threadId":"primary"}}"#,
        Direction::FromTui,
    );
    state.observe(r#"{"id":10,"method":"thread/start","params":{"threadSource":"thread_title","ephemeral":true}}"#, Direction::FromTui);
    state.observe(
        r#"{"id":9,"result":{"thread":{"id":"primary"}}}"#,
        Direction::FromServer,
    );
    assert!(
        !state.is_chat_ready(),
        "a title helper cannot waive resume history requirements"
    );
    assert!(state.operations.is_empty());
    assert!(state.is_bound(), "status keeps flowing without Chat");
    state.observe(r#"{"method":"turn/started","params":{"threadId":"primary","turn":{"id":"live","status":"inProgress"}}}"#, Direction::FromServer);
    assert!(
        state
            .effects
            .iter()
            .any(|effect| matches!(effect, super::Effect::Started))
    );
    assert!(state.operations.is_empty());
    let mut state = State::new();
    let mut duplicate = turn("old", "completed", "remembered");
    let item = duplicate["items"][0].clone();
    duplicate["items"].as_array_mut().unwrap().push(item);
    resume(&mut state, json!([duplicate]));
    assert!(state.closed);
}

#[test]
fn read_baseline_merges_new_live_turns_without_duplicating_snapshot_text() {
    let mut state = State::new();
    state.observe(
        r#"{"id":9,"method":"thread/resume","params":{"threadId":"primary","excludeTurns":true}}"#,
        Direction::FromTui,
    );
    state.observe(
        r#"{"id":9,"result":{"thread":{"id":"primary","turns":[]}}}"#,
        Direction::FromServer,
    );
    assert!(state.is_bound());
    assert!(!state.is_ready());
    state.observe(r#"{"method":"turn/started","params":{"threadId":"primary","turn":{"id":"live","status":"inProgress"}}}"#, Direction::FromServer);
    state.observe(r#"{"method":"item/agentMessage/delta","params":{"threadId":"primary","turnId":"live","itemId":"message","delta":"prefix"}}"#, Direction::FromServer);
    let frame = json!({"result":{"thread":{"id":"primary","turns":[turn("old", "completed", "remembered"),turn("live", "inProgress", "prefix tail")]}}});
    super::install(&mut state, &frame.to_string()).unwrap();
    assert!(state.is_ready());
    state.observe(r#"{"method":"item/agentMessage/delta","params":{"threadId":"primary","turnId":"live","itemId":"message","delta":" tail"}}"#, Direction::FromServer);
    let snapshot = state
        .projection
        .snapshot(super::super::projection::SNAPSHOT_ITEMS, None);
    assert_eq!(snapshot.items.len(), 2);
    assert!(
        matches!(&snapshot.items[1].body, proto::TimelineBody::Assistant { text, .. } if text == "prefix tail")
    );
    let cursor = state.projection.cursor();
    state.observe(r#"{"method":"turn/started","params":{"threadId":"primary","turn":{"id":"old","status":"inProgress"}}}"#, Direction::FromServer);
    state.observe(r#"{"method":"item/agentMessage/delta","params":{"threadId":"primary","turnId":"old","itemId":"message","delta":"duplicate"}}"#, Direction::FromServer);
    assert_eq!(state.projection.cursor(), cursor);
}

#[test]
fn unsupported_rollback_cannot_leave_an_authoritative_stale_timeline() {
    let mut state = State::new();
    state.observe(r#"{"id":1,"method":"thread/start"}"#, Direction::FromTui);
    state.observe(
        r#"{"id":1,"result":{"thread":{"id":"primary"}}}"#,
        Direction::FromServer,
    );
    state.observe(
        r#"{"id":2,"method":"thread/rollback","params":{"threadId":"foreign","numTurns":1}}"#,
        Direction::FromTui,
    );
    assert!(
        state.is_ready(),
        "foreign rollback must not retire the primary"
    );
    state.observe(
        r#"{"id":3,"method":"thread/rollback","params":{"threadId":"primary","numTurns":1}}"#,
        Direction::FromTui,
    );
    assert!(
        !state.is_chat_ready(),
        "unsupported history mutation must disable Chat"
    );
    assert!(state.is_bound(), "status keeps flowing without Chat");
}

#[test]
fn a_read_snapshot_of_an_unobserved_active_turn_is_not_a_safe_baseline() {
    let mut state = State::new();
    state.observe(
        r#"{"id":9,"method":"thread/resume","params":{"threadId":"primary","excludeTurns":true}}"#,
        Direction::FromTui,
    );
    state.observe(
        r#"{"id":9,"result":{"thread":{"id":"primary","turns":[]}}}"#,
        Direction::FromServer,
    );
    let frame = json!({"result":{"thread":{"id":"primary","turns":[turn("unobserved", "inProgress", "partial")]}}});
    assert!(super::install(&mut state, &frame.to_string()).is_err());
    assert!(!state.is_ready());
}

#[test]
fn terminal_thread_changes_keep_old_rows_until_the_exact_new_reply() {
    let mut state = State::new();
    resume(
        &mut state,
        json!([turn("old", "completed", "old conversation")]),
    );
    let original = state
        .projection
        .snapshot(super::super::projection::SNAPSHOT_ITEMS, None);
    state.observe(
        r#"{"id":20,"method":"thread/fork","params":{"threadId":"primary"}}"#,
        Direction::FromTui,
    );
    assert!(!state.is_bound());
    assert_eq!(
        state
            .projection
            .snapshot(super::super::projection::SNAPSHOT_ITEMS, None),
        original
    );
    state.observe(
        r#"{"id":21,"result":{"thread":{"id":"unrelated","turns":[]}}}"#,
        Direction::FromServer,
    );
    assert_eq!(
        state
            .projection
            .snapshot(super::super::projection::SNAPSHOT_ITEMS, None),
        original
    );
    state.observe(&json!({"id":20,"result":{"thread":{"id":"forked","turns":[turn("new", "completed", "new conversation")]}}}).to_string(), Direction::FromServer);
    assert!(state.is_bound());
    let snapshot = state
        .projection
        .snapshot(super::super::projection::SNAPSHOT_ITEMS, None);
    assert_ne!(snapshot.cursor.epoch, original.cursor.epoch);
    assert_eq!(snapshot.items.len(), 1);
    assert!(
        matches!(&snapshot.items[0].body, proto::TimelineBody::Assistant { text, .. } if text == "new conversation")
    );
}
