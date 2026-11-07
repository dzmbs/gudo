use proto::{AgentKind, TimelineCommand, TimelineSession};

fn session(mode: &str) -> TimelineSession {
    serde_json::from_value(serde_json::json!({
        "agent": serde_json::to_value(AgentKind::Claude).unwrap(),
        "native_session": "s", "title": null, "model": null,
        "permission_mode": mode, "commands": []
    }))
    .unwrap()
}

#[test]
fn timeline_operations_do_not_inline_an_entire_tool_item() {
    let overhead = size_of::<proto::TimelineCursor>() + size_of::<usize>();
    assert!(size_of::<proto::TimelineOp>() <= size_of::<proto::TimelineSnapshot>() + overhead);
}

#[test]
fn unknown_permission_modes_degrade_to_unknown() {
    let value = serde_json::to_value(session("future-permission-mode")).unwrap();
    assert_eq!(value["permission_mode"], "Unknown");
}

#[test]
fn unknown_command_sources_degrade_to_unknown() {
    let command: TimelineCommand = serde_json::from_value(serde_json::json!({
        "name": "review", "description": "", "source": "future-source"
    }))
    .unwrap();
    assert_eq!(serde_json::to_value(command).unwrap()["source"], "Unknown");
}

#[test]
fn known_permission_modes_retain_their_string_wire_encoding() {
    for mode in [
        "default",
        "acceptEdits",
        "plan",
        "dontAsk",
        "bypassPermissions",
        "auto",
    ] {
        let value = session(mode).permission_mode.unwrap();
        assert_eq!(
            serde_json::to_string(&value).unwrap(),
            serde_json::to_string(mode).unwrap()
        );
        assert_eq!(
            postcard::to_allocvec(&value).unwrap(),
            postcard::to_allocvec(mode).unwrap()
        );
    }
}
