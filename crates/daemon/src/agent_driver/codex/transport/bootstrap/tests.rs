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
        mode: agents::CodexPaneMode::Native,
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
    assert!(
        serde_json::from_slice::<serde_json::Value>(&bytes)
            .unwrap()
            .get("mode")
            .is_none(),
        "native bootstrap preserves the old private frame"
    );
    captured.mode = agents::CodexPaneMode::Terminal;
    assert_eq!(
        decode(&serde_json::to_vec(&captured).unwrap(), &expected)
            .unwrap()
            .mode,
        agents::CodexPaneMode::Terminal
    );
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
        mode: agents::CodexPaneMode::Native,
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

#[test]
fn the_codex_home_is_the_one_the_app_server_is_started_with() {
    let mut spec = agents::LaunchSpec {
        program: "codex".into(),
        args: Vec::new(),
        env: Vec::new(),
        cwd: "/fixture/project".into(),
        files: Vec::new(),
        env_remove: Vec::new(),
        env_pinned: Vec::new(),
    };
    let variables: Vec<(OsString, OsString)> = vec![
        ("HOME".into(), "/home/fixture".into()),
        ("CODEX_HOME".into(), "/home/fixture/.codex-login".into()),
    ];
    assert_eq!(
        codex_home(&variables, &spec),
        Some("/home/fixture/.codex-login".into())
    );
    spec.env_pinned
        .push(("CODEX_HOME".into(), "/accounts/work".into()));
    assert_eq!(codex_home(&variables, &spec), Some("/accounts/work".into()));
    spec.env_pinned.clear();
    spec.env_remove.push("CODEX_HOME".into());
    assert_eq!(
        codex_home(&variables, &spec),
        Some("/home/fixture/.codex".into())
    );
    assert_eq!(codex_home(&[], &spec), None);
}
