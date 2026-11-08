//! A reboot ends every process: the daemon gets SIGTERM (a clean shutdown) or nothing at all
//! (power loss, `kill -9`). Either way each pane comes back showing what it showed, above a
//! dim line saying it was restored, with a fresh shell below.

use std::path::Path;
use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::PaneId;

use crate::support::{TIMEOUT, TestClient, start_with, ticket};

fn configure(home: &Path) -> impl FnOnce(&mut daemon::Config) + use<> {
    let home = home.display().to_string();
    move |config: &mut daemon::Config| {
        config.screen_save_delay = Duration::from_millis(100);
        config.pane_env.push(("HOME".into(), home));
    }
}

fn wait_for_file(path: &Path) {
    let deadline = Instant::now() + TIMEOUT;
    while !path.exists() {
        assert!(
            Instant::now() < deadline,
            "{} never written",
            path.display()
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Copies the regular files of `from` into `to`, as a crash would leave them.
fn copy_state(from: &Path, to: &Path) {
    for entry in std::fs::read_dir(from).unwrap().flatten() {
        let source = entry.path();
        let target = to.join(entry.file_name());
        let kind = entry.file_type().unwrap();
        if kind.is_dir() {
            std::fs::create_dir_all(&target).unwrap();
            copy_state(&source, &target);
        } else if kind.is_file() {
            std::fs::copy(&source, &target).unwrap();
        }
    }
}

async fn restored_pane(daemon: &daemon::Daemon) -> (TestClient, PaneId) {
    let mut owner = TestClient::connect(&ticket(daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    (owner, pane)
}

fn assert_in_order(text: &str, parts: &[&str]) {
    let mut from = 0;
    for part in parts {
        let found = text[from..]
            .find(part)
            .unwrap_or_else(|| panic!("{part:?} missing or out of order in:\n{text}"));
        from += found + part.len();
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn screens_come_back_after_a_clean_shutdown() {
    let state = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let daemon = start_with(state.path(), configure(home.path())).await;
    let (mut owner, pane) = restored_pane(&daemon).await;
    owner.type_line(pane, "echo \"before the restart $((6 * 7))\"");
    owner.wait_text(pane, "before the restart 42").await;
    drop(owner);
    daemon.shutdown().await;
    assert!(
        state
            .path()
            .join(format!("screens/{}.zst", pane.0))
            .exists()
    );

    let daemon = start_with(state.path(), configure(home.path())).await;
    let (mut owner, restored) = restored_pane(&daemon).await;
    assert_eq!(restored, pane);
    owner
        .wait_text(pane, "Restored after restart \u{b7} ")
        .await;
    owner.type_line(pane, "echo \"after the restart $((6 * 8))\"");
    owner.wait_text(pane, "after the restart 48").await;
    assert_in_order(
        &owner.text(pane),
        &[
            "before the restart 42",
            "Restored after restart",
            "after the restart 48",
        ],
    );
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn screens_saved_while_running_survive_a_crash() {
    let state = tempfile::tempdir().unwrap();
    let crashed = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let daemon = start_with(state.path(), configure(home.path())).await;
    let (mut owner, pane) = restored_pane(&daemon).await;
    owner.type_line(pane, "echo \"saved while running $((6 * 7))\"");
    owner.wait_text(pane, "saved while running 42").await;
    let screen = state.path().join(format!("screens/{}.zst", pane.0));
    wait_for_file(&screen);
    let deadline = Instant::now() + TIMEOUT;
    loop {
        copy_state(state.path(), crashed.path());
        let restored = std::fs::read(crashed.path().join(format!("screens/{}.zst", pane.0)))
            .map(|compressed| zstd::decode_all(&compressed[..]).unwrap_or_default())
            .unwrap_or_default();
        if String::from_utf8_lossy(&restored).contains("saved while running 42") {
            break;
        }
        assert!(Instant::now() < deadline, "the screen was never saved");
        std::thread::sleep(Duration::from_millis(50));
    }

    let after_crash = start_with(crashed.path(), configure(home.path())).await;
    let (mut restored_owner, restored) = restored_pane(&after_crash).await;
    assert_eq!(restored, pane);
    restored_owner
        .wait_text(pane, "saved while running 42")
        .await;
    restored_owner
        .wait_text(pane, "Restored after restart")
        .await;
    drop(restored_owner);
    after_crash.shutdown().await;
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_closed_pane_takes_its_screen_with_it() {
    let state = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let daemon = start_with(state.path(), configure(home.path())).await;
    let (mut owner, first) = restored_pane(&daemon).await;
    let client_core::proto::OpOutcome::PaneCreated { pane_id: second } = owner
        .op(client_core::proto::LayoutOp::Split {
            pane_id: first,
            axis: client_core::proto::Axis::Horizontal,
            launch: client_core::proto::PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split failed");
    };
    owner.follow(second).await;
    owner.type_line(second, "echo second pane");
    owner.wait_text(second, "second pane").await;
    let screen = state.path().join(format!("screens/{}.zst", second.0));
    wait_for_file(&screen);
    owner
        .op(client_core::proto::LayoutOp::ClosePane { pane_id: second })
        .await;
    let deadline = Instant::now() + TIMEOUT;
    while screen.exists() {
        assert!(Instant::now() < deadline, "the closed pane's screen stayed");
        std::thread::sleep(Duration::from_millis(20));
    }
    drop(owner);
    daemon.shutdown().await;
}

const CLAUDE_ID: &str = "7a1c2e3f-4b5d-4e6f-8a9b-0c1d2e3f4a5b";

/// Writes its transcript as Claude Code does and its pid next to it, then runs as `claude`.
const FAKE_CLAUDE: &str = r#"#!/bin/bash
echo "fake claude $* in $(pwd -P)"
case " $* " in *" --resume "*) exec -a claude /bin/sleep 600 ;; esac
dir="$CLAUDE_CONFIG_DIR/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$dir"
printf '{"sessionId":"__ID__"}\n' > "$dir/__ID__.jsonl"
echo $$ > "$CLAUDE_CONFIG_DIR/pid"
exec -a claude /bin/sleep 600
"#;

fn wait_layout(state: &Path, holds: impl Fn(&str) -> bool, what: &str) {
    let deadline = Instant::now() + TIMEOUT;
    loop {
        let text = std::fs::read_to_string(state.join("layout.json")).unwrap_or_default();
        if holds(&text) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "layout.json never {what}:\n{text}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn agent_env(tools: &Path) -> Vec<(String, String)> {
    use std::os::unix::fs::PermissionsExt;
    let bin = tools.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let claude = bin.join("claude");
    std::fs::write(&claude, FAKE_CLAUDE.replace("__ID__", CLAUDE_ID)).unwrap();
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    vec![
        ("PATH".to_owned(), path),
        (
            "CLAUDE_CONFIG_DIR".to_owned(),
            tools.join("claude-config").display().to_string(),
        ),
        ("HOME".to_owned(), tools.display().to_string()),
    ]
}

fn configure_env(env: Vec<(String, String)>) -> impl FnOnce(&mut daemon::Config) {
    move |config: &mut daemon::Config| {
        config.screen_save_delay = Duration::from_millis(100);
        config.pane_env.extend(env);
    }
}

/// At a reboot the system stops the programs in the panes too, sometimes a moment before the
/// daemon: what they lose by dying then is not lost.
#[tokio::test(flavor = "multi_thread")]
async fn an_agent_killed_just_before_shutdown_still_resumes() {
    let state = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let env = agent_env(tools.path());

    let daemon = start_with(state.path(), configure_env(env.clone())).await;
    let (mut owner, pane) = restored_pane(&daemon).await;
    owner.type_line(pane, "claude");
    owner.wait_text(pane, "fake claude").await;
    wait_layout(
        state.path(),
        |text| text.contains(CLAUDE_ID),
        "named the session",
    );
    let pid: i32 = std::fs::read_to_string(tools.path().join("claude-config/pid"))
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    // SAFETY: sends SIGTERM to the stand-in agent this test started.
    unsafe { libc::kill(pid, libc::SIGTERM) };
    wait_layout(
        state.path(),
        |text| !text.contains(CLAUDE_ID),
        "forgot the ended agent",
    );
    drop(owner);
    daemon.shutdown().await;

    let daemon = start_with(state.path(), configure_env(env)).await;
    let (mut owner, restored) = restored_pane(&daemon).await;
    assert_eq!(restored, pane);
    owner
        .wait_flat(pane, &format!("--resume {CLAUDE_ID}"))
        .await;
    drop(owner);
    daemon.shutdown().await;
}
