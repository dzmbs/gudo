//! A Codex pane's session id is learnt from its rollout file and survives a daemon restart:
//! the restored pane runs `codex resume <id>`. Codex is faked by a script that writes a rollout
//! the way Codex does and keeps it open.

use std::os::unix::fs::PermissionsExt;
use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::{AgentKind, AgentState, Axis, LayoutOp, OpOutcome, PaneLaunch};

use crate::support::{TIMEOUT, TestClient, leaves, start_with, ticket};

const ID: &str = "0199a213-81c0-7800-8aa1-bbab2a035a53";

const FAKE_CODEX: &str = r#"#!/bin/sh
echo "fake codex $*"
dir="$CODEX_HOME/sessions/2026/10/18"
mkdir -p "$dir"
f="$dir/rollout-2026-10-18T12-00-00-__ID__.jsonl"
if [ ! -e "$f" ]; then
  printf '{"type":"session_meta","payload":{"id":"__ID__","cwd":"%s"}}\n' "$PWD" > "$f"
fi
exec 3>>"$f"
exec sleep 600
"#;

#[tokio::test(flavor = "multi_thread")]
async fn codex_session_id_is_captured_and_resumed_after_restart() {
    let dir = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let bin = tools.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let codex = bin.join("codex");
    std::fs::write(&codex, FAKE_CODEX.replace("__ID__", ID)).unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    let codex_home = tools.path().join("codex-home");
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let env = vec![
        ("PATH".to_owned(), path),
        ("CODEX_HOME".to_owned(), codex_home.display().to_string()),
    ];
    let configure =
        |env: Vec<(String, String)>| move |config: &mut daemon::Config| config.pane_env.extend(env);

    let daemon = start_with(dir.path(), configure(env.clone())).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let shell = owner.attach_and_follow().await;
    let OpOutcome::PaneCreated { pane_id: agent } = owner
        .op(LayoutOp::Split {
            pane_id: shell,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Agent {
                agent: AgentKind::Codex,
                resume: None,
                cwd: None,
            },
        })
        .await
    else {
        panic!("split failed");
    };
    owner.follow(agent).await;
    owner.wait_text(agent, "fake codex").await;

    // The id reaches the persisted layout.
    let layout = dir.path().join("layout.json");
    let deadline = Instant::now() + TIMEOUT;
    while !std::fs::read_to_string(&layout).is_ok_and(|text| text.contains(ID)) {
        assert!(Instant::now() < deadline, "session id never persisted");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    drop(owner);
    daemon.shutdown().await;

    // After a restart the pane resumes that session.
    let daemon = start_with(dir.path(), configure(env)).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.client.attach(None);
    owner.until("layout", |owner| owner.layout.is_some()).await;
    assert!(leaves(&owner.tab().root).contains(&agent));
    owner.follow(agent).await;
    owner.wait_flat(agent, &format!("resume {ID}")).await;
    drop(owner);
    daemon.shutdown().await;
}

const FAKE_CODEX_ASKING_BY_OSC_777: &str = r#"#!/bin/sh
printf '\033]777;notify;Codex;Approval requested: cargo test\033\\'
exec sleep 600
"#;

#[tokio::test(flavor = "multi_thread")]
async fn codex_desktop_notifications_block_the_agent() {
    let dir = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let bin = tools.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let codex = bin.join("codex");
    std::fs::write(&codex, FAKE_CODEX_ASKING_BY_OSC_777).unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let codex_home = tools.path().join("codex-home").display().to_string();
    let daemon = start_with(dir.path(), move |config| {
        config.pane_env.extend([
            ("PATH".to_owned(), path),
            ("CODEX_HOME".to_owned(), codex_home),
        ])
    })
    .await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let shell = owner.attach_and_follow().await;
    let OpOutcome::PaneCreated { pane_id: agent } = owner
        .op(LayoutOp::Split {
            pane_id: shell,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Agent {
                agent: AgentKind::Codex,
                resume: None,
                cwd: None,
            },
        })
        .await
    else {
        panic!("split failed");
    };
    owner.follow(agent).await;
    owner
        .until("agent blocked on the approval", |owner| {
            owner
                .metas
                .get(&agent)
                .and_then(|meta| meta.agent.as_ref())
                .is_some_and(|status| match &status.state {
                    AgentState::Blocked(blocker) => blocker.summary.contains("cargo test"),
                    _ => false,
                })
        })
        .await;
    drop(owner);
    daemon.shutdown().await;
}
