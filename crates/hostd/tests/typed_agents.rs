//! A Claude Code the user types in a shell pane (zsh, bash or fish with the shell integration)
//! runs through the pane's launch, through the real hook shim: the same options, in the same
//! terminal, with a pinned session and Chat's controls, and a restore that keeps how it was
//! typed. `command claude`, and what the daemon cannot start that way, run as typed.

#[allow(dead_code)]
#[path = "../../daemon/tests/it/support.rs"]
mod support;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::{AgentConfigSupport, AgentConfigValues, LayoutOp, OpOutcome, PaneId};
use daemon::Daemon;
use support::{TIMEOUT, TestClient, start_with, ticket};

/// A `claude` that prints its arguments and reports the session it starts on, then waits.
fn fake_claude(hook: &str) -> String {
    format!(
        r#"#!/bin/sh
case "$1" in
  --help) printf 'Options:\n  --model <model>  Model (e.g. '"'"'opus'"'"' or '"'"'sonnet'"'"')\n'; exit 0 ;;
  --version) echo "2.1.331 (Claude Code)"; exit 0 ;;
esac
if [ -n "$STARTED_AT" ]; then
  perl -MTime::HiRes=time -e 'printf "STARTED %.6f\n", time'
  exit 0
fi
echo "AGENT-UP $*"
session=""
previous=""
for argument in "$@"; do
  case "$previous" in --session-id|--resume) session="$argument" ;; esac
  previous="$argument"
done
trap 'echo AGENT-TERM; exit 0' TERM
printf '%s' '{{"session_id":"'"$session"'","hook_event_name":"SessionStart","source":"startup"}}' | '{hook}' claude SessionStart
while IFS= read -r line; do :; done
"#
    )
}

/// A Codex too old for its live Chat, so the helper starts it in Terminal: it prints its
/// arguments and waits.
const FAKE_CODEX: &str = r#"#!/bin/sh
case "$1" in --version) echo "codex-cli 0.1.0"; exit 0 ;; esac
if [ -n "$STARTED_AT" ]; then
  perl -MTime::HiRes=time -e 'printf "STARTED %.6f\n", time'
  exit 0
fi
echo "CODEX-UP $*"
while IFS= read -r line; do :; done
"#;

/// pi: prints its arguments and waits.
const FAKE_PI: &str = r#"#!/bin/sh
if [ -n "$STARTED_AT" ]; then
  perl -MTime::HiRes=time -e 'printf "STARTED %.6f\n", time'
  exit 0
fi
echo "PI-UP $*"
while IFS= read -r line; do :; done
"#;

/// The shells with an integration this host has.
fn shells() -> Vec<PathBuf> {
    [
        "/bin/zsh",
        "/usr/bin/zsh",
        "/opt/homebrew/bin/fish",
        "/usr/bin/fish",
    ]
    .into_iter()
    .chain(
        [
            "/opt/homebrew/bin/bash",
            "/usr/local/bin/bash",
            "/usr/bin/bash",
        ]
        .into_iter()
        .filter(|bash| !(cfg!(target_os = "macos") && *bash == "/bin/bash")),
    )
    .map(PathBuf::from)
    .filter(|shell| shell.is_file())
    .collect()
}

async fn start_daemon(dir: &Path, shell: &Path) -> Daemon {
    let home = dir.join("home");
    let bin = dir.join("programs");
    let program = bin.join("claude");
    if !program.exists() {
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(&program, fake_claude(env!("CARGO_BIN_EXE_gudo-hook"))).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
        for (name, script) in [("codex", FAKE_CODEX), ("pi", FAKE_PI)] {
            let path = bin.join(name);
            std::fs::write(&path, script).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
    }
    let path = format!("{}:/usr/bin:/bin", bin.display());
    let shell = shell.to_owned();
    start_with(&dir.join("state"), |config| {
        config.hook_bin = Some(env!("CARGO_BIN_EXE_gudo-hook").into());
        config.shell = Some(shell);
        config.pane_env.extend([
            ("HOME".into(), home.to_string_lossy().into_owned()),
            ("PATH".into(), path),
            (
                "CLAUDE_CONFIG_DIR".into(),
                home.join(".claude").to_string_lossy().into_owned(),
            ),
            (
                "CODEX_HOME".into(),
                home.join(".codex").to_string_lossy().into_owned(),
            ),
            (
                "PI_CODING_AGENT_DIR".into(),
                home.join(".pi").to_string_lossy().into_owned(),
            ),
        ]);
    })
    .await
}

async fn shell_pane(owner: &mut TestClient, cwd: &Path) -> PaneId {
    let session_id = owner.layout.as_ref().unwrap().session_id;
    let OpOutcome::TabCreated { pane_id, .. } = owner
        .op(LayoutOp::NewTab {
            session_id,
            name: String::new(),
            launch: client_core::proto::PaneLaunch::Shell {
                cwd: Some(cwd.to_string_lossy().into_owned()),
            },
        })
        .await
    else {
        panic!("new tab")
    };
    owner.follow(pane_id).await;
    pane_id
}

/// The last `AGENT-UP` line that contains `needle`, once the fake prints one.
async fn started_with(owner: &mut TestClient, pane: PaneId, needle: &str) -> String {
    owner
        .until(&format!("AGENT-UP with {needle}"), |client| {
            client
                .flat_text(pane)
                .split("AGENT-UP")
                .skip(1)
                .any(|line| line.contains(needle))
        })
        .await;
    owner
        .flat_text(pane)
        .rsplit("AGENT-UP")
        .find(|line| line.contains(needle))
        .expect("waited for above")
        .to_owned()
}

async fn controls_supported(owner: &TestClient, pane: PaneId) {
    let deadline = Instant::now() + TIMEOUT;
    loop {
        if let Ok(controls) = owner.client.agent_controls_watch(pane).await
            && controls.config.support == AgentConfigSupport::Supported
        {
            return;
        }
        assert!(Instant::now() < deadline, "no controls for pane {pane}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_typed_claude_runs_through_its_launch_with_its_options_kept() {
    let shells = shells();
    assert!(!shells.is_empty(), "no shell with an integration here");
    for shell in shells {
        let dir = tempfile::tempdir().unwrap();
        let work = dir.path().join("work");
        std::fs::create_dir_all(&work).unwrap();
        let daemon = start_daemon(dir.path(), &shell).await;
        let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
        owner.attach_and_follow().await;
        let pane = shell_pane(&mut owner, &work).await;
        owner.type_line(pane, "claude --dangerously-skip-permissions");
        let first = started_with(&mut owner, pane, "--session-id").await;
        assert!(
            first.contains("--dangerously-skip-permissions") && first.contains("--settings"),
            "{shell:?}: {first}"
        );
        let session = first
            .split("--session-id ")
            .nth(1)
            .and_then(|rest| rest.split_whitespace().next())
            .unwrap()
            .to_owned();
        controls_supported(&owner, pane).await;
        owner
            .client
            .set_agent_config(
                pane,
                AgentConfigValues {
                    model: Some("sonnet".into()),
                    mode: None,
                    effort: None,
                },
            )
            .await
            .unwrap();
        let again = started_with(&mut owner, pane, "--model sonnet").await;
        assert!(
            again.contains(&session) && again.contains("--dangerously-skip-permissions"),
            "{shell:?}: {again}"
        );

        let plain = shell_pane(&mut owner, &work).await;
        owner.type_line(plain, "command claude --verbose");
        let typed = started_with(&mut owner, plain, "--verbose").await;
        assert!(!typed.contains("--settings"), "{shell:?}: {typed}");
        let other = shell_pane(&mut owner, &work).await;
        owner.type_line(other, "claude -p hello");
        let printed = started_with(&mut owner, other, "-p hello").await;
        assert!(!printed.contains("--settings"), "{shell:?}: {printed}");
        daemon.shutdown().await;

        let daemon = start_daemon(dir.path(), &shell).await;
        let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
        owner.client.attach(None);
        owner.until("layout", |owner| owner.layout.is_some()).await;
        owner.follow(pane).await;
        let restored = started_with(&mut owner, pane, "--resume").await;
        assert!(
            restored.contains(&session)
                && restored.contains("--model sonnet")
                && restored.contains("--dangerously-skip-permissions"),
            "{shell:?}: {restored}"
        );
        daemon.shutdown().await;
    }
}

/// What the launch adds to a typed Claude Code's start: the time from the line running to the
/// program's first instruction, through the launch and as typed (`command claude`), in zsh.
/// A measurement, run on a quiet machine: `cargo test -p hostd --test typed_agents -- --ignored
/// --nocapture`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a measurement for a quiet machine"]
async fn typed_launch_start_latency() {
    let dir = tempfile::tempdir().unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let daemon = start_daemon(dir.path(), Path::new("/bin/zsh")).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let pane = shell_pane(&mut owner, &work).await;
    owner.type_line(pane, "zmodload zsh/datetime; export STARTED_AT=1; clear");
    const RUNS: usize = 20;
    for (label, program, options) in [
        ("claude as typed", "command claude", "--verbose"),
        ("claude through its launch", "claude", "--verbose"),
        ("codex as typed", "command codex", ""),
        ("codex through its launch", "codex", ""),
        ("pi as typed", "command pi", ""),
        ("pi through its launch", "pi", ""),
    ] {
        let mut samples = Vec::with_capacity(RUNS);
        for run in 0..RUNS {
            owner.type_line(
                pane,
                &format!("clear; printf 'BEGAN %s\\n' $EPOCHREALTIME; {program} {options}; echo DONE-{run}"),
            );
            owner
                .until("a run", |client| {
                    client
                        .text(pane)
                        .lines()
                        .any(|line| line.trim() == format!("DONE-{run}"))
                })
                .await;
            let text = owner.text(pane);
            let number = |key: &str| -> f64 {
                text.lines()
                    .find_map(|line| line.trim().strip_prefix(key))
                    .and_then(|value| value.trim().parse().ok())
                    .unwrap_or_else(|| panic!("{key} in {text}"))
            };
            samples.push((number("STARTED ") - number("BEGAN ")) * 1000.0);
        }
        samples.sort_by(f64::total_cmp);
        println!(
            "{label}: median {:.1} ms, p90 {:.1} ms over {RUNS} runs",
            samples[RUNS / 2],
            samples[RUNS * 9 / 10]
        );
    }
    daemon.shutdown().await;
}

/// The last line from a fake agent that starts with `marker`, once one prints.
async fn up_line(owner: &mut TestClient, pane: PaneId, marker: &str) -> String {
    owner
        .until(&format!("{marker} in pane {pane}"), |client| {
            client
                .text(pane)
                .lines()
                .any(|line| line.starts_with(marker))
        })
        .await;
    owner
        .text(pane)
        .lines()
        .rfind(|line| line.starts_with(marker))
        .expect("waited for above")
        .to_owned()
}

async fn is_agent(owner: &mut TestClient, pane: PaneId) {
    owner
        .until("the pane runs an agent", |client| {
            client
                .metas
                .get(&pane)
                .is_some_and(|meta| meta.agent.is_some())
        })
        .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn typed_codex_and_pi_run_through_their_launch() {
    for shell in shells() {
        let dir = tempfile::tempdir().unwrap();
        let work = dir.path().join("work");
        std::fs::create_dir_all(&work).unwrap();
        let daemon = start_daemon(dir.path(), &shell).await;
        let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
        owner.attach_and_follow().await;

        let codex = shell_pane(&mut owner, &work).await;
        owner.type_line(codex, "codex");
        let started = up_line(&mut owner, codex, "CODEX-UP").await;
        assert!(started.contains("tui.notification"), "{shell:?}: {started}");
        is_agent(&mut owner, codex).await;
        let plain = shell_pane(&mut owner, &work).await;
        owner.type_line(plain, "command codex");
        let typed = up_line(&mut owner, plain, "CODEX-UP").await;
        assert!(!typed.contains("tui.notification"), "{shell:?}: {typed}");
        let exec = shell_pane(&mut owner, &work).await;
        owner.type_line(exec, "codex exec hello");
        let typed = up_line(&mut owner, exec, "CODEX-UP").await;
        assert_eq!(typed.trim(), "CODEX-UP exec hello", "{shell:?}");

        let pi = shell_pane(&mut owner, &work).await;
        owner.type_line(pi, "pi");
        let started = up_line(&mut owner, pi, "PI-UP").await;
        assert!(started.contains("--extension"), "{shell:?}: {started}");
        let plain = shell_pane(&mut owner, &work).await;
        owner.type_line(plain, "pi --model x");
        let typed = up_line(&mut owner, plain, "PI-UP").await;
        assert_eq!(typed.trim(), "PI-UP --model x", "{shell:?}");
        daemon.shutdown().await;
    }
}
