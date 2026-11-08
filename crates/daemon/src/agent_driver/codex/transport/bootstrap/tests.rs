use super::*;

#[test]
fn bootstrap_preserves_post_login_environment_bytes_and_requires_the_exact_pane() {
    use std::os::unix::ffi::OsStringExt;
    let expected: Vec<(String, OsString)> = vec![
        ("GUDO_PANE_ID".to_string(), "pane-one".into()),
        ("GUDO_TOKEN".to_string(), "fixture-only-token".into()),
    ];
    let mut captured = agents::CodexPaneEnvironment {
        version: 1,
        variables: expected
            .iter()
            .map(|(name, value)| (name.clone().into(), value.clone()))
            .collect(),
        cwd: "/fixture/project".into(),
    };
    captured
        .variables
        .push(("FROM_LOGIN".into(), "resolved-by-the-pane".into()));
    captured
        .variables
        .push(("BYTE_VALUE".into(), OsString::from_vec(vec![128, 129])));
    let bytes = serde_json::to_vec(&captured).unwrap();
    let decoded = decode(&bytes, &expected).unwrap();
    assert_eq!(decoded.variables, captured.variables);
    captured.variables[0].1 = "different-pane".into();
    let error = decode(&serde_json::to_vec(&captured).unwrap(), &expected)
        .err()
        .unwrap();
    assert_eq!(error.to_string(), "invalid Codex pane environment");
}

#[test]
fn duplicate_environment_names_unknown_versions_and_relative_cwd_are_rejected() {
    let mut captured = agents::CodexPaneEnvironment {
        version: 2,
        variables: Vec::new(),
        cwd: "/fixture".into(),
    };
    assert!(decode(&serde_json::to_vec(&captured).unwrap(), &[]).is_err());
    captured.version = 1;
    captured.cwd = "relative".into();
    assert!(decode(&serde_json::to_vec(&captured).unwrap(), &[]).is_err());
    captured.cwd = "/fixture".into();
    captured.variables = vec![
        ("HOME".into(), "/first".into()),
        ("HOME".into(), "/second".into()),
    ];
    assert!(decode(&serde_json::to_vec(&captured).unwrap(), &[]).is_err());
}
