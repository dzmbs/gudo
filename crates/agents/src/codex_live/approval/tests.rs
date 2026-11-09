use super::*;
use serde_json::json;

#[test]
fn simple_choices_do_not_invent_an_unoffered_decision_or_persistent_grant() {
    let details: CodexApprovalDetails = serde_json::from_value(json!({"availableDecisions":["accept","cancel",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["printf"]}}]})).unwrap();
    assert!(details.offers("accept"));
    assert!(!details.offers("acceptForSession"));
    assert!(!details.offers("decline"));
    assert_eq!(details.denial(), Some("cancel"));
    let details: CodexApprovalDetails =
        serde_json::from_value(json!({"availableDecisions":[]})).unwrap();
    assert!(!details.offers("accept"));
    assert_eq!(details.denial(), None);
}

#[test]
fn additional_permission_metadata_is_retained_and_cannot_match_a_plain_bash_rule() {
    let raw = json!({"command":"printf fixture","cwd":"/fixture","reason":"fixture reason","kind":"command","environmentId":"local","additionalPermissions":{"network":{"enabled":true}},"futurePermission":{"scope":"turn"}});
    let details: CodexApprovalDetails = serde_json::from_value(raw.clone()).unwrap();
    assert!(!details.is_plain_command());
    assert!(
        !details.is_supported_command(),
        "an unknown permission field cannot acquire an Allow action"
    );
    let mut known = raw.clone();
    known.as_object_mut().unwrap().remove("futurePermission");
    assert!(
        serde_json::from_value::<CodexApprovalDetails>(known)
            .unwrap()
            .is_supported_command()
    );
    let shown: Value = serde_json::from_str(&details.summary()).unwrap();
    assert_eq!(shown["command"], raw["command"]);
    assert_eq!(shown["cwd"], raw["cwd"]);
    assert_eq!(shown["reason"], raw["reason"]);
    assert_eq!(
        shown["context"]["additionalPermissions"],
        raw["additionalPermissions"]
    );
    assert_eq!(
        shown["context"]["futurePermission"],
        raw["futurePermission"]
    );
}

#[test]
fn the_full_official_fixture_preserves_the_command_context_and_offered_choices() {
    let recording: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/codex-live/pane-approval-0.166.0.json"
    ))
    .unwrap();
    let params = recording["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|event| event["method"] == "item/commandExecution/requestApproval")
        .unwrap()["params"]
        .as_object()
        .unwrap();
    let mut params = params.clone();
    for key in ["threadId", "turnId", "itemId"] {
        params.remove(key);
    }
    let details: CodexApprovalDetails = serde_json::from_value(Value::Object(params)).unwrap();
    assert!(details.is_plain_command());
    assert!(details.command.as_ref().unwrap().contains("printf fixture"));
    assert_eq!(details.cwd.as_deref(), Some("/fixture/project"));
    assert_eq!(details.denial(), Some("cancel"));
}

#[test]
fn remote_execution_requires_explicit_context_and_unknown_command_kinds_stay_unsupported() {
    let mut details: CodexApprovalDetails = serde_json::from_value(
        json!({"command":"printf fixture", "kind":"command", "environmentId":"local"}),
    )
    .unwrap();
    assert!(details.is_supported_command());
    assert!(details.is_plain_command());
    details
        .context
        .insert("environmentId".into(), json!("remote-executor"));
    assert!(details.is_supported_command());
    assert!(
        !details.is_plain_command(),
        "a remote environment must not inherit local Bash rules"
    );
    details.context.insert("kind".into(), json!("script"));
    assert!(!details.is_supported_command());
}

#[test]
fn file_changes_offer_no_persistent_grant_and_unknown_metadata_stays_unsupported() {
    let mut details: CodexApprovalDetails =
        serde_json::from_value(json!({"reason":"A fixture edit", "grantRoot":"/fixture"})).unwrap();
    assert!(details.is_file_change());
    assert!(details.offers("accept"));
    assert!(details.offers("decline"));
    assert!(!details.offers("acceptForSession"));
    details
        .context
        .insert("futurePermission".into(), json!(true));
    assert!(!details.is_file_change());
}
