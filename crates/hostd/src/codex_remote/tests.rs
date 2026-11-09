use super::*;
use std::os::unix::fs::PermissionsExt;
use std::time::Instant;

fn executable(directory: &std::path::Path, body: &str) -> std::path::PathBuf {
    let path = directory.join("codex");
    std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    path
}

#[test]
fn terminal_fallback_reapplies_account_pins_and_credential_removals() {
    let mut command = Command::new("codex");
    command
        .env("CODEX_HOME", "/wrong-account")
        .env("OPENAI_API_KEY", "fixture-ambient-value");
    apply_terminal(
        &mut command,
        agents::CodexTerminalLaunch {
            arguments: vec!["resume".into(), "exact-recorded-thread".into()],
            env_remove: vec!["OPENAI_API_KEY".into()],
            env_pinned: vec![("CODEX_HOME".into(), "/selected-account".into())],
        },
    );
    assert_eq!(
        command.get_args().collect::<Vec<_>>(),
        ["resume", "exact-recorded-thread"]
    );
    let environment = command
        .get_envs()
        .collect::<std::collections::BTreeMap<_, _>>();
    assert_eq!(
        environment[OsStr::new("CODEX_HOME")],
        Some(OsStr::new("/selected-account"))
    );
    assert_eq!(environment[OsStr::new("OPENAI_API_KEY")], None);
}

#[test]
fn only_the_verified_successful_version_selects_native_launch() {
    let directory = tempfile::tempdir().unwrap();
    for (body, expected) in [
        ("printf 'codex-cli 0.166.0\\n'", true),
        ("printf 'codex-cli 0.167.0\\n'", false),
        ("printf 'codex-cli 0.166.0\\n'; exit 1", false),
        ("printf 'codex-cli 0.166.0\\nextra'", false),
        ("printf '%0128d' 0", false),
    ] {
        let path = executable(directory.path(), body);
        assert_eq!(supports_native(path.as_os_str()).unwrap(), expected);
    }
}

#[test]
fn closed_output_does_not_turn_a_hung_version_query_into_an_unbounded_wait() {
    let directory = tempfile::tempdir().unwrap();
    let path = executable(directory.path(), "exec 1>&-; exec /bin/sleep 10");
    let started = Instant::now();
    assert!(!supports_native(path.as_os_str()).unwrap());
    assert!(started.elapsed() < Duration::from_secs(5));
}
