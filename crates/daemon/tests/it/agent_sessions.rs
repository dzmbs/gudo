//! An agent the daemon notices only well after it started (as the build a hot upgrade hands
//! a pane to does) still has its session found from what it wrote since its process started,
//! not only from what it writes after the daemon noticed it.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::{LayoutOp, OpOutcome, PaneLaunch};

use crate::support::{TestClient, start_with, ticket};

const CLAUDE_ID: &str = "7e1f0c2a-3b4d-4e5f-8a9b-0c1d2e3f4a5b";
const PI_ID: &str = "019a0b1c-2d3e-7f40-8a5b-6c7d8e9f0a1b";

/// Writes its session file at once, stays unnoticed long enough that a lookup from when the
/// daemon notices it misses the file, then waits idle as the agent.
const LATE_CLAUDE: &str = r#"#!/bin/bash
dir="$CLAUDE_CONFIG_DIR/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$dir"
printf '{"sessionId":"__ID__"}\n' > "$dir/__ID__.jsonl"
echo written
sleep 9; echo running
exec -a claude /bin/sleep 600
"#;

const LATE_PI: &str = r#"#!/bin/bash
mkdir -p "$PI_CODING_AGENT_SESSION_DIR"
printf '{"type":"session","id":"__ID__"}\n' > "$PI_CODING_AGENT_SESSION_DIR/2026-11-17T10-00-00-000Z___ID__.jsonl"
echo written
sleep 9; echo running
exec -a pi /bin/sleep 600
"#;

fn install(bin: &Path, name: &str, script: &str) {
    let path = bin.join(name);
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn wait_persisted(state: &Path, needle: &str, within: Duration) {
    let layout = state.join("layout.json");
    let deadline = Instant::now() + within;
    loop {
        let text = std::fs::read_to_string(&layout).unwrap_or_default();
        if text.contains(needle) {
            return;
        }
        assert!(Instant::now() < deadline, "never found {needle}:\n{text}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn an_agent_noticed_late_finds_the_session_it_wrote_at_its_start() {
    let state = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let bin = tools.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    install(&bin, "claude", &LATE_CLAUDE.replace("__ID__", CLAUDE_ID));
    install(&bin, "pi", &LATE_PI.replace("__ID__", PI_ID));
    let work = tools.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let work = work.canonicalize().unwrap();
    let env = vec![
        (
            "PATH".to_owned(),
            format!(
                "{}:{}",
                bin.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        ),
        (
            "CLAUDE_CONFIG_DIR".to_owned(),
            tools.path().join("claude-config").display().to_string(),
        ),
        (
            "PI_CODING_AGENT_SESSION_DIR".to_owned(),
            tools.path().join("pi-sessions").display().to_string(),
        ),
    ];
    let daemon = start_with(state.path(), |config| config.pane_env.extend(env)).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let session_id = owner.layout.as_ref().unwrap().session_id;
    let mut panes = Vec::new();
    for _ in 0..2 {
        let OpOutcome::TabCreated { pane_id, .. } = owner
            .op(LayoutOp::NewTab {
                session_id,
                name: String::new(),
                launch: PaneLaunch::Shell {
                    cwd: Some(work.display().to_string()),
                },
            })
            .await
        else {
            panic!("new tab");
        };
        owner.follow(pane_id).await;
        panes.push(pane_id);
    }
    owner.type_line(panes[0], "claude");
    owner.type_line(panes[1], "pi");
    owner.wait_text(panes[0], "written").await;
    owner.wait_text(panes[1], "written").await;
    wait_persisted(state.path(), CLAUDE_ID, Duration::from_secs(30));
    wait_persisted(state.path(), PI_ID, Duration::from_secs(30));
}
