//! A Codex pane's session id is learnt from its rollout file and survives a daemon restart:
//! the restored pane runs `codex resume <id>`. Codex is faked by a script that writes a rollout
//! the way Codex does and keeps it open.

use std::os::unix::fs::PermissionsExt;
use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::{AgentKind, Axis, LayoutOp, OpOutcome, PaneLaunch};

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
        |env: Vec<(String, String)>| move |c: &mut daemon::Config| c.pane_env.extend(env);

    let daemon = start_with(dir.path(), configure(env.clone())).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let shell = c.attach_and_follow().await;
    let OpOutcome::PaneCreated { pane_id: agent } = c
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
    c.follow(agent).await;
    c.wait_text(agent, "fake codex").await;

    // The id reaches the persisted layout.
    let layout = dir.path().join("layout.json");
    let deadline = Instant::now() + TIMEOUT;
    while !std::fs::read_to_string(&layout).is_ok_and(|s| s.contains(ID)) {
        assert!(Instant::now() < deadline, "session id never persisted");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    drop(c);
    daemon.shutdown().await;

    // After a restart the pane resumes that session.
    let daemon = start_with(dir.path(), configure(env)).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.client.attach(None);
    c.until("layout", |c| c.layout.is_some()).await;
    assert!(leaves(&c.tab().root).contains(&agent));
    c.follow(agent).await;
    c.wait_flat(agent, &format!("resume {ID}")).await;
    drop(c);
    daemon.shutdown().await;
}
