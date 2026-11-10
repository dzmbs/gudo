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
async fn output_that_mentions_a_restart_comes_back_whole() {
    let state = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let daemon = start_with(state.path(), configure(home.path())).await;
    let (mut owner, pane) = restored_pane(&daemon).await;
    owner.type_line(pane, "echo \"Restored after restart by hand $((6 * 7))\"");
    owner
        .wait_text(pane, "Restored after restart by hand 42")
        .await;
    drop(owner);
    daemon.shutdown().await;

    let daemon = start_with(state.path(), configure(home.path())).await;
    let (mut owner, _) = restored_pane(&daemon).await;
    owner
        .wait_text(pane, "Restored after restart \u{b7} ")
        .await;
    owner.type_line(pane, "echo \"after the restart $((6 * 8))\"");
    owner.wait_text(pane, "after the restart 48").await;
    assert_in_order(
        &owner.text(pane),
        &[
            "Restored after restart by hand 42",
            "Restored after restart \u{b7} ",
            "after the restart 48",
        ],
    );
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_screen_restored_twice_says_so_once() {
    let state = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let daemon = start_with(state.path(), configure(home.path())).await;
    let (mut owner, pane) = restored_pane(&daemon).await;
    owner.type_line(pane, "echo \"before the restarts $((6 * 7))\"");
    owner.wait_text(pane, "before the restarts 42").await;
    drop(owner);
    daemon.shutdown().await;

    for _ in 0..2 {
        let daemon = start_with(state.path(), configure(home.path())).await;
        let (mut owner, _) = restored_pane(&daemon).await;
        owner
            .wait_text(pane, "Restored after restart \u{b7} ")
            .await;
        drop(owner);
        daemon.shutdown().await;
    }

    let daemon = start_with(state.path(), configure(home.path())).await;
    let (mut owner, _) = restored_pane(&daemon).await;
    owner
        .wait_text(pane, "Restored after restart \u{b7} ")
        .await;
    owner.type_line(pane, "echo \"after the restarts $((6 * 8))\"");
    owner.wait_text(pane, "after the restarts 48").await;
    let text = owner.text(pane);
    assert_in_order(&text, &["before the restarts 42", "after the restarts 48"]);
    assert_eq!(text.matches("Restored after restart").count(), 1, "{text}");
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

/// A reboot can end a pane's shell a moment before the daemon: the pane comes back with its
/// screen, even after the layout was saved without it in between.
#[tokio::test(flavor = "multi_thread")]
async fn a_pane_whose_shell_ended_just_before_shutdown_keeps_its_screen() {
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
    owner.type_line(second, "echo \"ended by the reboot $((6 * 7))\"");
    owner.wait_text(second, "ended by the reboot 42").await;
    let screen = state.path().join(format!("screens/{}.zst", second.0));
    wait_for_file(&screen);
    owner.type_line(second, "exit");
    let pane_key = format!("\"{}\":", second.0);
    wait_layout(
        state.path(),
        |text| text.contains("\"panes\"") && !text.contains(&pane_key),
        "dropped the ended pane",
    );
    drop(owner);
    daemon.shutdown().await;

    let daemon = start_with(state.path(), configure(home.path())).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    owner.follow(second).await;
    owner.wait_text(second, "ended by the reboot 42").await;
    owner.wait_text(second, "Restored after restart").await;
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

const PI_ID: &str = "019a5f2e-7d3c-7b21-9c4e-1f2a3b4c5d6e";

/// Writes its session file where pi does and keeps running as `pi`.
const FAKE_PI: &str = r#"#!/bin/bash
echo "fake pi $* in $(pwd -P)"
case " $* " in *" --session "*) exec -a pi /bin/sleep 600 ;; esac
dir="$PI_CODING_AGENT_DIR/sessions/--$(pwd -P | sed 's|^/||; s|[/:]|-|g')--"
mkdir -p "$dir"
printf '{"type":"session"}\n' > "$dir/2026-11-08T10-00-00-000Z___ID__.jsonl"
exec -a pi /bin/sleep 600
"#;

/// pi has no hooks: the daemon finds its session file and resumes it with pi's own flag.
#[tokio::test(flavor = "multi_thread")]
async fn a_pi_session_started_by_hand_resumes() {
    use std::os::unix::fs::PermissionsExt;
    let state = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let mut env = agent_env(tools.path());
    let pi = tools.path().join("bin/pi");
    std::fs::write(&pi, FAKE_PI.replace("__ID__", PI_ID)).unwrap();
    std::fs::set_permissions(&pi, std::fs::Permissions::from_mode(0o755)).unwrap();
    env.push((
        "PI_CODING_AGENT_DIR".to_owned(),
        tools.path().join("pi-agent").display().to_string(),
    ));
    let work = tools.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let work = work.canonicalize().unwrap();

    let daemon = start_with(state.path(), configure_env(env.clone())).await;
    let (mut owner, pane) = restored_pane(&daemon).await;
    owner.type_line(pane, &format!("cd '{}' && pi", work.display()));
    owner.wait_text(pane, "fake pi").await;
    wait_layout(
        state.path(),
        |text| text.contains(PI_ID),
        "named the pi session",
    );
    drop(owner);
    daemon.shutdown().await;

    let daemon = start_with(state.path(), configure_env(env)).await;
    let (mut owner, restored) = restored_pane(&daemon).await;
    assert_eq!(restored, pane);
    owner
        .wait_flat(
            pane,
            &format!("fake pi --session {PI_ID} in {}", work.display()),
        )
        .await;
    owner.wait_text(pane, "Restored after restart").await;
    drop(owner);
    daemon.shutdown().await;
}

/// Writes its session file only once continued, as pi does when a continued session goes on.
const FAKE_PI_WRITING_WHEN_CONTINUED: &str = r#"#!/bin/bash
echo "fake pi $* in $(pwd -P)"
case " $* " in *" --continue "*)
  dir="$PI_CODING_AGENT_DIR/sessions/--$(pwd -P | sed 's|^/||; s|[/:]|-|g')--"
  mkdir -p "$dir"
  printf '{"type":"session"}\n' > "$dir/2026-11-08T10-00-00-000Z___ID__.jsonl"
  ;;
esac
exec -a pi /bin/sleep 600
"#;

/// A pi session whose id was never learned comes back with `--continue`; the daemon then
/// learns the id, so the next restart resumes that session rather than the newest one.
#[tokio::test(flavor = "multi_thread")]
async fn a_continued_pi_session_learns_its_id() {
    use std::os::unix::fs::PermissionsExt;
    let state = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let mut env = agent_env(tools.path());
    let pi = tools.path().join("bin/pi");
    std::fs::write(&pi, FAKE_PI_WRITING_WHEN_CONTINUED.replace("__ID__", PI_ID)).unwrap();
    std::fs::set_permissions(&pi, std::fs::Permissions::from_mode(0o755)).unwrap();
    env.push((
        "PI_CODING_AGENT_DIR".to_owned(),
        tools.path().join("pi-agent").display().to_string(),
    ));
    let work = tools.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let work = work.canonicalize().unwrap();

    let daemon = start_with(state.path(), configure_env(env.clone())).await;
    let (mut owner, pane) = restored_pane(&daemon).await;
    owner.type_line(pane, &format!("cd '{}' && pi", work.display()));
    owner.wait_text(pane, "fake pi").await;
    wait_layout(
        state.path(),
        |text| text.contains("\"program\": \"pi\""),
        "recorded the pi agent",
    );
    drop(owner);
    daemon.shutdown().await;

    let daemon = start_with(state.path(), configure_env(env)).await;
    let (mut owner, restored) = restored_pane(&daemon).await;
    assert_eq!(restored, pane);
    owner.wait_flat(pane, "fake pi --continue").await;
    wait_layout(
        state.path(),
        |text| text.contains(PI_ID),
        "named the continued pi session",
    );
    drop(owner);
    daemon.shutdown().await;
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

/// A dev server, a watcher, `tail -f`: never started again by itself (it could do anything),
/// but offered, and typed on request.
#[tokio::test(flavor = "multi_thread")]
async fn a_running_command_is_offered_again_and_never_run_by_itself() {
    let state = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let daemon = start_with(state.path(), configure(home.path())).await;
    let (owner, pane) = restored_pane(&daemon).await;
    owner.type_line(pane, "sleep 599");
    wait_layout(
        state.path(),
        |text| text.contains("sleep 599"),
        "kept the command",
    );
    drop(owner);
    daemon.shutdown().await;

    let daemon = start_with(state.path(), configure(home.path())).await;
    let (mut owner, restored) = restored_pane(&daemon).await;
    assert_eq!(restored, pane);
    owner
        .until("the offer", |owner| owner.run_again.is_some())
        .await;
    let offers = owner.run_again.clone().unwrap();
    assert_eq!(
        offers,
        vec![client_core::proto::RunAgainOffer {
            pane_id: pane,
            command: "sleep 599".into(),
        }]
    );
    owner.type_line(pane, "echo \"the shell is free $((6 * 7))\"");
    owner.wait_text(pane, "the shell is free 42").await;

    owner.client.run_again(&offers[0]);
    owner
        .until("the offer withdrawn", |owner| {
            owner.run_again.as_ref().is_some_and(Vec::is_empty)
        })
        .await;
    drop(owner);
    daemon.shutdown().await;
}

/// Output can carry command marks (`tail -f` of someone else's data, a hostile host over ssh):
/// a command started inside the running one is never what Run again offers.
#[tokio::test(flavor = "multi_thread")]
async fn a_command_planted_by_output_is_never_offered_again() {
    let state = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let daemon = start_with(state.path(), configure(home.path())).await;
    let (mut owner, pane) = restored_pane(&daemon).await;
    let shell_marks = r"printf '\033]133;A\007$ \033]133;B\007\033]133;C;cmdline=sleep 598\007'";
    let planted = r"printf '\033]133;A\007host$ \033]133;B\007\033]133;C;cmdline=echo planted\007'";
    owner.type_line(pane, &format!("{shell_marks}; {planted}; sleep 598"));
    owner.wait_text(pane, "host$").await;
    wait_layout(
        state.path(),
        |text| text.contains("sleep 598") || text.contains("echo planted"),
        "kept a command",
    );
    drop(owner);
    daemon.shutdown().await;

    let daemon = start_with(state.path(), configure(home.path())).await;
    let (mut owner, restored) = restored_pane(&daemon).await;
    assert_eq!(restored, pane);
    owner
        .until("the offer", |owner| owner.run_again.is_some())
        .await;
    assert_eq!(
        owner.run_again.clone().unwrap(),
        vec![client_core::proto::RunAgainOffer {
            pane_id: pane,
            command: "sleep 598".into(),
        }]
    );
    drop(owner);
    daemon.shutdown().await;
}

/// A `layout.json` from before screens, resumable agents and Run again still loads, and one
/// from a newer daemon (fields and agents this build does not know) does too.
#[tokio::test(flavor = "multi_thread")]
async fn older_and_newer_layout_files_load() {
    let state = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let daemon = start_with(state.path(), configure(home.path())).await;
    let (owner, pane) = restored_pane(&daemon).await;
    drop(owner);
    daemon.shutdown().await;
    let layout = state.path().join("layout.json");
    let mut saved: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&layout).unwrap()).unwrap();

    let mut older = saved.clone();
    older.as_object_mut().unwrap().remove("saved_at");
    for record in older["panes"].as_object_mut().unwrap().values_mut() {
        let record = record.as_object_mut().unwrap();
        record.remove("resumable");
        record.remove("last_command");
    }
    std::fs::write(&layout, serde_json::to_vec(&older).unwrap()).unwrap();
    let daemon = start_with(state.path(), configure(home.path())).await;
    let (owner, restored) = restored_pane(&daemon).await;
    assert_eq!(restored, pane);
    drop(owner);
    daemon.shutdown().await;

    saved["from_the_future"] = serde_json::json!(true);
    let record = saved["panes"][pane.0.to_string()].as_object_mut().unwrap();
    record.insert(
        "resumable".into(),
        serde_json::json!({"program": "an-agent-from-later", "session_id": "x"}),
    );
    record.insert("also_later".into(), serde_json::json!({"any": 1}));
    std::fs::write(&layout, serde_json::to_vec(&saved).unwrap()).unwrap();
    let daemon = start_with(state.path(), configure(home.path())).await;
    let (owner, restored) = restored_pane(&daemon).await;
    assert_eq!(restored, pane);
    drop(owner);
    daemon.shutdown().await;
    let backups = std::fs::read_dir(state.path())
        .unwrap()
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().contains(".bad-"))
        .count();
    assert_eq!(backups, 0, "a layout file was set aside");
}
