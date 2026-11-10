#[allow(dead_code)]
#[path = "../../daemon/tests/it/support.rs"]
mod support;

use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use client_core::ClientConfig;
use client_core::grants::GrantSpec;
use client_core::proto::{
    AgentKind, AuditKind, Axis, LayoutOp, MpError, OpOutcome, PaneId, PaneLaunch, Roles, Scope,
};
use daemon::Daemon;
use support::{TestClient, start_with, ticket};

async fn agent(dir: &Path, script: &str) -> (Daemon, TestClient, PaneId) {
    let home = dir.join("home");
    let bin = dir.join("programs");
    std::fs::create_dir(&home).unwrap();
    std::fs::write(
        home.join(".profile"),
        "PS1='FENCE-SHELL-READY> '; export PS1\n",
    )
    .unwrap();
    std::fs::create_dir(&bin).unwrap();
    let program = bin.join("claude");
    std::fs::write(&program, format!("#!/bin/sh\necho AGENT-UP\n{script}\n")).unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
    let daemon = start_with(&dir.join("state"), |config| {
        config.hook_bin = Some(env!("CARGO_BIN_EXE_gudo-hook").into());
        config.pane_env.extend([
            ("HOME".into(), home.to_string_lossy().into_owned()),
            ("PATH".into(), format!("{}:/usr/bin:/bin", bin.display())),
            (
                "CLAUDE_CONFIG_DIR".into(),
                home.join(".claude").to_string_lossy().into_owned(),
            ),
        ]);
    })
    .await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let first = owner.attach_and_follow().await;
    let outcome = owner
        .op(LayoutOp::Split {
            pane_id: first,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Agent {
                agent: AgentKind::Claude,
                cwd: Some(home.to_string_lossy().into_owned()),
                resume: None,
            },
        })
        .await;
    let OpOutcome::PaneCreated { pane_id } = outcome else {
        panic!("agent launch: {outcome:?}")
    };
    owner.follow(pane_id).await;
    owner.wait_text(pane_id, "AGENT-UP").await;
    (daemon, owner, pane_id)
}

async fn guest(owner: &TestClient, pane: PaneId, roles: Roles) -> TestClient {
    let invite = owner
        .client
        .create_invite(GrantSpec::new(roles, Scope::Daemon), "fixture".into())
        .await
        .unwrap();
    let mut guest = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    guest.client.attach(None);
    guest
        .until("guest layout", |client| client.layout.is_some())
        .await;
    guest.follow(pane).await;
    guest
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn fenced_prompts_remain_role_checked_rate_limited_and_audited() {
    let dir = tempfile::tempdir().unwrap();
    let (daemon, mut owner, pane) = agent(
        dir.path(),
        "while IFS= read -r line; do printf 'agent-read:%s\\n' \"$line\"; done",
    )
    .await;
    let pat = guest(&owner, pane, Roles::PROMPTER).await;
    assert_eq!(
        pat.client
            .prompt(pane, "echo prompted-ok".into(), true)
            .await
            .unwrap(),
        16
    );
    owner.wait_text(pane, "agent-read:echo prompted-ok").await;
    let viewer = guest(&owner, pane, Roles::VIEWER).await;
    assert!(matches!(
        viewer.client.prompt(pane, "hello".into(), true).await,
        Err(MpError::Forbidden(_))
    ));
    let mut sent = 0;
    let mut refused = 0;
    for round in 0..30 {
        match pat
            .client
            .prompt(pane, format!("flood-{round}"), false)
            .await
        {
            Ok(_) => sent += 1,
            Err(MpError::Failed(message)) => {
                assert!(message.contains("Wait a few seconds"), "{message}");
                refused += 1;
            }
            Err(error) => panic!("prompt flood: {error:?}"),
        }
    }
    assert_eq!((sent, refused), (4, 26));
    for round in 0..10 {
        owner
            .client
            .prompt(pane, format!("owner-{round}"), false)
            .await
            .unwrap();
    }
    let page = owner.client.audit(None, 200).await.unwrap();
    assert_eq!(
        page.records
            .iter()
            .filter(|record| record.kind == AuditKind::Prompt)
            .count(),
        15
    );
    let denied: Vec<_> = page
        .records
        .iter()
        .filter(|record| record.kind == AuditKind::Denied && record.detail.contains("prompt"))
        .collect();
    assert_eq!(denied.len(), 1);
    assert!(
        page.records
            .iter()
            .all(|record| !record.detail.contains("prompted-ok"))
    );
    drop((pat, viewer, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_fenced_agent_can_exit_to_a_shell_without_accepting_a_stale_prompt() {
    let dir = tempfile::tempdir().unwrap();
    let (daemon, mut owner, pane) = agent(
        dir.path(),
        "IFS= read -r line; printf 'agent-read:%s\\n' \"$line\"",
    )
    .await;
    let pat = guest(&owner, pane, Roles::PROMPTER).await;
    pat.client.prompt(pane, "first".into(), true).await.unwrap();
    owner.wait_text(pane, "agent-read:first").await;
    owner.wait_text(pane, "FENCE-SHELL-READY>").await;
    assert!(matches!(
        pat.client
            .prompt(pane, "echo LEAKED-$((6*7))".into(), true)
            .await,
        Err(MpError::Forbidden(_))
    ));
    owner.type_line(pane, "echo shell-$((1+1))");
    owner.wait_text(pane, "shell-2").await;
    assert!(!owner.text(pane).contains("LEAKED"));
    drop((pat, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_racing_the_agent_exit_never_reaches_the_shell() {
    let dir = tempfile::tempdir().unwrap();
    let (daemon, mut owner, pane) = agent(
        dir.path(),
        "IFS= read -r line; printf 'agent-read:%s\\n' \"$line\"",
    )
    .await;
    let pat = guest(&owner, pane, Roles::PROMPTER).await;
    pat.client.prompt(pane, "first".into(), true).await.unwrap();
    owner.wait_text(pane, "agent-read:first").await;
    let result = pat
        .client
        .prompt(pane, "echo LEAKED-$((6*7))".into(), true)
        .await;
    assert!(
        matches!(result, Ok(_) | Err(MpError::Forbidden(_))),
        "{result:?}"
    );
    owner.wait_text(pane, "FENCE-SHELL-READY>").await;
    owner.type_line(pane, "echo shell-$((1+1))");
    owner.wait_text(pane, "shell-2").await;
    assert!(!owner.text(pane).contains("LEAKED-42"));
    drop((pat, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn exit_during_a_native_paste_drains_the_payload_and_withholds_a_late_return() {
    let dir = tempfile::tempdir().unwrap();
    let (daemon, mut owner, pane) = agent(
        dir.path(),
        "stty raw -echo; echo RAW-READY; dd bs=1 count=1 of=/dev/null 2>/dev/null; echo AGENT-EXITED",
    ).await;
    owner.wait_text(pane, "RAW-READY").await;
    let pat = guest(&owner, pane, Roles::PROMPTER).await;
    let payload = "echo NATIVE-LEAK-$((6*7))\n".repeat(500);
    assert!(payload.len() < 16 * 1024);
    let result = pat.client.prompt(pane, payload, true).await;
    assert!(
        matches!(result, Ok(_) | Err(MpError::Forbidden(_))),
        "{result:?}"
    );
    owner.wait_text(pane, "FENCE-SHELL-READY>").await;
    owner.type_line(pane, "echo clean-fallback-$((3*7))");
    owner.wait_text(pane, "clean-fallback-21").await;
    let output = owner.text(pane);
    assert!(!output.contains("NATIVE-LEAK-42"), "{output}");
    drop((pat, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn fenced_reviewers_keep_sanitized_notes_and_cannot_supply_a_shell_preamble() {
    use client_core::proto::{ReviewNote, ReviewRequest, WsError};
    let dir = tempfile::tempdir().unwrap();
    let (daemon, mut owner, pane) = agent(
        dir.path(),
        "while IFS= read -r line; do printf 'agent-read:%s\\n' \"$line\"; done",
    )
    .await;
    for roles in [Roles::PROMPTER, Roles::APPROVER | Roles::VIEWER] {
        let reviewer = guest(&owner, pane, roles).await;
        let request = |note: &str| ReviewRequest {
            pane_id: pane,
            preamble: Some("!touch should-not-run".into()),
            notes: vec![ReviewNote {
                path: "src/a.rs".into(),
                start_line: 1,
                end_line: 1,
                old_side: false,
                quote: Some("fn a() {}\r\x1b[201~".into()),
                note: note.into(),
            }],
            submit: true,
        };
        let prompt = reviewer
            .client
            .send_review(request("a safe review note"))
            .await
            .unwrap();
        assert!(!prompt.contains("touch"), "{prompt}");
        assert!(
            !prompt.contains('\x1b') && !prompt.contains('\r'),
            "{prompt:?}"
        );
        owner.wait_text(pane, "a safe review note").await;
        for bad in ["fine\x1b[201~\r!sh", "x\x03"] {
            assert!(matches!(
                reviewer.client.send_review(request(bad)).await,
                Err(WsError::Invalid(_))
            ));
        }
    }
    drop(owner);
    daemon.shutdown().await;
}
