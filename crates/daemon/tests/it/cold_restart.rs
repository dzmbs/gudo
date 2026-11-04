//! After a cold restart (the daemon stopped, its panes ended) every agent pane resumes its
//! session in the same directory, also one the user started by hand in a shell, and plain
//! shells come back as fresh shells where they were. Codex and Claude Code are faked by
//! scripts that write their session files the way the real ones do and keep running.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::{AgentKind, Axis, LayoutOp, OpOutcome, PaneId, PaneLaunch};

use crate::support::{TIMEOUT, TestClient, leaves, start_with, ticket};

const CODEX_ID: &str = "0199a213-81c0-7800-8aa1-bbab2a035a53";
const CLAUDE_ID: &str = "5d2c7f3a-1b4e-4c8d-9e6f-0a1b2c3d4e5f";
const LAUNCHED_CODEX_ID: &str = "0199a213-0000-7800-8aa1-bbab2a035a53";

/// Writes a rollout under `$CODEX_HOME` and keeps it open while running as `codex`.
const FAKE_CODEX: &str = r#"#!/bin/bash
echo "fake codex $* in $(pwd -P)"
case " $* " in *" resume "*) exec -a codex /bin/sleep 600 ;; esac
dir="$CODEX_HOME/sessions/2026/10/18"
mkdir -p "$dir"
case "$(basename "$PWD")" in work) id=__ID__ ;; *) id=__OTHER_ID__ ;; esac
f="$dir/rollout-2026-10-18T12-00-00-$id.jsonl"
printf '{"type":"session_meta","payload":{"id":"x","cwd":"%s"}}\n' "$PWD" > "$f"
exec 3>>"$f"
exec -a codex /bin/sleep 600
"#;

/// Writes a transcript under `$CLAUDE_CONFIG_DIR/projects/<directory>` while running as
/// `claude`, closing it as Claude Code does.
const FAKE_CLAUDE: &str = r#"#!/bin/bash
echo "fake claude $* in $(pwd -P)"
case " $* " in *" --resume "*) exec -a claude /bin/sleep 600 ;; esac
dir="$CLAUDE_CONFIG_DIR/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$dir"
printf '{"sessionId":"__ID__"}\n' > "$dir/__ID__.jsonl"
exec -a claude /bin/sleep 600
"#;

fn install(bin: &Path, name: &str, script: &str) {
    let path = bin.join(name);
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

async fn split(owner: &mut TestClient, from: PaneId, launch: PaneLaunch) -> PaneId {
    let OpOutcome::PaneCreated { pane_id } = owner
        .op(LayoutOp::Split {
            pane_id: from,
            axis: Axis::Horizontal,
            launch,
        })
        .await
    else {
        panic!("split failed");
    };
    owner.follow(pane_id).await;
    pane_id
}

fn wait_persisted(state: &Path, needles: &[&str]) {
    let layout = state.join("layout.json");
    let deadline = Instant::now() + TIMEOUT;
    loop {
        let text = std::fs::read_to_string(&layout).unwrap_or_default();
        if needles.iter().all(|needle| text.contains(needle)) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "never persisted {needles:?}:\n{text}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn agents_resume_their_sessions_after_a_cold_restart() {
    let state = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let bin = tools.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    install(
        &bin,
        "codex",
        &FAKE_CODEX
            .replace("__ID__", CODEX_ID)
            .replace("__OTHER_ID__", LAUNCHED_CODEX_ID),
    );
    install(&bin, "claude", &FAKE_CLAUDE.replace("__ID__", CLAUDE_ID));
    let work = tools.path().join("work");
    let elsewhere = tools.path().join("elsewhere");
    std::fs::create_dir_all(&work).unwrap();
    std::fs::create_dir_all(&elsewhere).unwrap();
    let work = work.canonicalize().unwrap();
    let elsewhere = elsewhere.canonicalize().unwrap();
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let env = vec![
        ("PATH".to_owned(), path),
        (
            "CODEX_HOME".to_owned(),
            tools.path().join("codex-home").display().to_string(),
        ),
        (
            "CLAUDE_CONFIG_DIR".to_owned(),
            tools.path().join("claude-config").display().to_string(),
        ),
    ];
    let configure =
        |env: Vec<(String, String)>| move |config: &mut daemon::Config| config.pane_env.extend(env);
    let shell_in = |dir: &Path| PaneLaunch::Shell {
        cwd: Some(dir.display().to_string()),
    };

    let daemon = start_with(state.path(), configure(env.clone())).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let first = owner.attach_and_follow().await;
    let shell = split(&mut owner, first, shell_in(&elsewhere)).await;
    let hand_codex = split(&mut owner, first, shell_in(&work)).await;
    let hand_claude = split(&mut owner, first, shell_in(&work)).await;
    let launched_codex = split(
        &mut owner,
        first,
        PaneLaunch::Agent {
            agent: AgentKind::Codex,
            resume: None,
            cwd: Some(elsewhere.display().to_string()),
        },
    )
    .await;
    owner.type_line(hand_codex, "codex");
    owner.wait_text(hand_codex, "fake codex").await;
    owner.type_line(hand_claude, "claude");
    owner.wait_text(hand_claude, "fake claude").await;
    owner.wait_text(launched_codex, "fake codex").await;
    // Saved as they become known, so a crash keeps them too.
    wait_persisted(state.path(), &[CODEX_ID, CLAUDE_ID, LAUNCHED_CODEX_ID]);
    drop(owner);
    daemon.shutdown().await;

    let daemon = start_with(state.path(), configure(env)).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.client.attach(None);
    owner.until("layout", |owner| owner.layout.is_some()).await;
    let panes = leaves(&owner.tab().root);
    for pane in [shell, hand_codex, hand_claude, launched_codex] {
        assert!(panes.contains(&pane), "pane {pane} restored");
        owner.follow(pane).await;
    }
    let work = work.display().to_string();
    owner
        .wait_flat(hand_codex, &format!("resume {CODEX_ID} in {work}"))
        .await;
    owner
        .wait_flat(hand_claude, &format!("--resume {CLAUDE_ID} "))
        .await;
    owner
        .wait_flat(hand_claude, &format!(".json in {work}"))
        .await;
    owner
        .wait_flat(
            launched_codex,
            &format!("resume {LAUNCHED_CODEX_ID} in {}", elsewhere.display()),
        )
        .await;
    for pane in [hand_codex, hand_claude, launched_codex] {
        owner.wait_text(pane, "Resumed after restart").await;
    }
    owner.type_line(shell, "pwd -P");
    owner
        .wait_text(shell, &elsewhere.display().to_string())
        .await;
    assert!(!owner.text(shell).contains("Resumed"));
    drop(owner);
    daemon.shutdown().await;
}
