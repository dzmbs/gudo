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
            (
                "PI_CODING_AGENT_SESSION_DIR".into(),
                home.join(".pi-sessions").to_string_lossy().into_owned(),
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
        owner.type_line(plain, "pi --mode json");
        let typed = up_line(&mut owner, plain, "PI-UP").await;
        assert_eq!(typed.trim(), "PI-UP --mode json", "{shell:?}");
        daemon.shutdown().await;
    }
}

/// A Claude Code as the real one shows itself to the process table, `claude` with its options
/// as given, which a script run by its interpreter does not. It prints its options, reports the
/// session it runs on, turns bracketed paste on as Claude Code does, and prints each line it
/// reads.
const RUNNING_CLAUDE: &str = r#"#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--version")) {
        printf("2.1.331 (Claude Code)\n");
        return 0;
    }
    if (argc > 1 && !strcmp(argv[1], "--help")) {
        return 0;
    }
    const char *session = "";
    printf("AGENT-UP");
    for (int i = 1; i < argc; i++) {
        printf(" %s", argv[i]);
        if ((!strcmp(argv[i], "--session-id") || !strcmp(argv[i], "--resume")) && i + 1 < argc) {
            session = argv[i + 1];
        }
    }
    printf("\n");
    fflush(stdout);
    char hook[8192];
    snprintf(hook, sizeof hook,
        "printf '%%s' '{\"session_id\":\"%s\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}' | '%s' claude SessionStart",
        session, HOOK);
    system(hook);
    printf("\033[?2004h");
    fflush(stdout);
    char line[8192];
    while (fgets(line, sizeof line, stdin)) {
        printf("GOT: %s", line);
        fflush(stdout);
    }
    return 0;
}
"#;

/// A Claude Code started by hand before the shell integration wrapped it (or with `command`):
/// the first Chat send restarts it through its launch on the conversation it was writing, with
/// its options, says so in the pane, and the message arrives once.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_first_send_takes_over_a_claude_started_by_hand() {
    let dir = tempfile::tempdir().unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let daemon = start_daemon(dir.path(), Path::new("/bin/zsh")).await;
    let source = dir.path().join("claude.c");
    std::fs::write(&source, RUNNING_CLAUDE).unwrap();
    let built = std::process::Command::new("cc")
        .arg(format!("-DHOOK=\"{}\"", env!("CARGO_BIN_EXE_gudo-hook")))
        .arg("-o")
        .arg(dir.path().join("programs/claude"))
        .arg(&source)
        .output()
        .unwrap();
    assert!(built.status.success(), "{built:?}");
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let pane = shell_pane(&mut owner, &work).await;
    const SESSION: &str = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d";
    owner.type_line(
        pane,
        &format!("command claude --session-id {SESSION} --dangerously-skip-permissions"),
    );
    started_with(&mut owner, pane, SESSION).await;
    is_agent(&mut owner, pane).await;
    let deadline = Instant::now() + TIMEOUT;
    let capabilities = loop {
        if let Ok(watch) = owner.client.timeline_watch_capabilities(pane).await
            && watch
                .capabilities
                .contains(client_core::proto::AgentCapabilities::SEND_AFTER_TAKEOVER)
        {
            break watch.capabilities;
        }
        assert!(
            Instant::now() < deadline,
            "never offered a send after takeover"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    assert!(
        !capabilities.contains(client_core::proto::AgentCapabilities::SEND),
        "a client that does not know takeover keeps Chat read-only: {capabilities:?}"
    );

    let prepared = owner.client.chat_prepare(pane).await.unwrap();
    let client_core::proto::ChatSendStatus::Prepared { ticket, .. } = prepared else {
        panic!("{prepared:?}")
    };
    let restarted = started_with(&mut owner, pane, "--resume").await;
    assert!(
        restarted.contains(SESSION) && restarted.contains("--dangerously-skip-permissions"),
        "{restarted}"
    );
    assert!(
        owner
            .flat_text(pane)
            .contains("Restarted here so Chat can send to it."),
        "{}",
        owner.text(pane)
    );
    let sent = owner
        .client
        .chat_send(pane, ticket, "hello there".into(), None)
        .await;
    let deadline = Instant::now() + TIMEOUT;
    while !owner.flat_text(pane).contains("hello there") {
        assert!(
            Instant::now() < deadline,
            "{sent:?}: the message never arrived:\n{}",
            owner.text(pane)
        );
        owner.until("pane output", |_| true).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    owner.until("pending output", |_| true).await;
    let arrived = owner
        .text(pane)
        .lines()
        .filter(|line| line.starts_with("GOT:") && line.contains("hello there"))
        .count();
    assert_eq!(arrived, 1, "{}", owner.text(pane));
    daemon.shutdown().await;
}

const CODEX_FIRST: &str = "0199a213-1111-7800-8aa1-bbab2a035a53";
const PI_FIRST: &str = "0199b000-aaaa";
const PI_SWITCHED: &str = "0199b000-bbbb";

/// Codex or pi as the real ones show themselves to the process table (`codex …`, `pi …`),
/// writing their conversation where they do: Codex holds its rollout open, pi appends to its
/// session file. Each prints its options, turns bracketed paste on and prints each line it
/// reads; a line `switch` makes pi write another session, as its `/resume` does.
const RUNNING_AGENT: &str = r#"#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    const char *name = strrchr(argv[0], '/') ? strrchr(argv[0], '/') + 1 : argv[0];
    int codex = !strcmp(name, "codex");
    if (argc > 1 && !strcmp(argv[1], "--version")) {
        printf(codex ? "codex-cli 0.1.0\n" : "0.1.0\n");
        return 0;
    }
    const char *session = codex ? CODEX_FIRST : PI_FIRST;
    printf("AGENT-UP");
    for (int i = 1; i < argc; i++) {
        printf(" %s", argv[i]);
        if (i + 1 < argc && !strcmp(argv[i], codex ? "resume" : "--session")) {
            session = argv[i + 1];
        }
    }
    printf("\n");
    fflush(stdout);
    char path[4096], command[8192];
    FILE *written;
    if (codex) {
        snprintf(path, sizeof path, "%s/sessions/2026/11/25", getenv("CODEX_HOME"));
        snprintf(command, sizeof command, "mkdir -p '%s'", path);
        system(command);
        snprintf(path + strlen(path), sizeof path - strlen(path),
            "/rollout-2026-11-25T10-00-00-%s.jsonl", session);
        written = fopen(path, "a");
        fprintf(written, "{\"type\":\"session_meta\",\"payload\":{\"id\":\"%s\",\"history_mode\":\"paginated\"}}\n", session);
    } else {
        const char *folder = getenv("PI_CODING_AGENT_SESSION_DIR");
        snprintf(command, sizeof command, "mkdir -p '%s'", folder);
        system(command);
        snprintf(path, sizeof path, "%s/2026-11-25T10-00-00-000Z_%s.jsonl", folder, session);
        written = fopen(path, "a");
        fprintf(written, "{\"type\":\"session\",\"version\":3,\"id\":\"%s\"}\n", session);
    }
    fflush(written);
    printf("\033[?2004h");
    fflush(stdout);
    char line[8192];
    while (fgets(line, sizeof line, stdin)) {
        printf("GOT: %s", line);
        fflush(stdout);
        if (!codex && !strncmp(line, "switch", 6)) {
            fclose(written);
            snprintf(path, sizeof path, "%s/2026-11-25T10-00-00-000Z_%s.jsonl",
                getenv("PI_CODING_AGENT_SESSION_DIR"), PI_SWITCHED);
            written = fopen(path, "a");
            printf("PI-SWITCHED\n");
            fflush(stdout);
        }
        fprintf(written, "{\"type\":\"message\"}\n");
        fflush(written);
    }
    return 0;
}
"#;

/// Builds `RUNNING_AGENT` as `codex` and `pi` in the daemon's programs folder, over the scripts.
fn build_running_agents(dir: &Path) {
    let source = dir.join("agent.c");
    std::fs::write(&source, RUNNING_AGENT).unwrap();
    for name in ["codex", "pi"] {
        let built = std::process::Command::new("cc")
            .arg(format!("-DCODEX_FIRST=\"{CODEX_FIRST}\""))
            .arg(format!("-DPI_FIRST=\"{PI_FIRST}\""))
            .arg(format!("-DPI_SWITCHED=\"{PI_SWITCHED}\""))
            .arg("-o")
            .arg(dir.join("programs").join(name))
            .arg(&source)
            .output()
            .unwrap();
        assert!(built.status.success(), "{built:?}");
    }
}

/// Waits until Chat offers the pane a send that takes its agent over.
async fn offers_takeover(owner: &TestClient, pane: PaneId) {
    let deadline = Instant::now() + TIMEOUT;
    loop {
        let watch = owner.client.timeline_watch_capabilities(pane).await;
        if let Ok(watch) = &watch
            && watch
                .capabilities
                .contains(client_core::proto::AgentCapabilities::SEND_AFTER_TAKEOVER)
        {
            assert!(
                !watch
                    .capabilities
                    .contains(client_core::proto::AgentCapabilities::SEND),
                "{:?}",
                watch.capabilities
            );
            return;
        }
        assert!(
            Instant::now() < deadline,
            "pane {pane} never offered a send after takeover ({:?}):\n{}",
            watch.as_ref().map(|watch| watch.capabilities),
            owner.text(pane)
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Sends `text` from Chat and waits for the agent to print it, once.
async fn sends_once(owner: &mut TestClient, pane: PaneId, text: &str) {
    let prepared = owner.client.chat_prepare(pane).await.unwrap();
    let client_core::proto::ChatSendStatus::Prepared { ticket, .. } = prepared else {
        panic!("{prepared:?}\n{}", owner.text(pane))
    };
    let sent = owner
        .client
        .chat_send(pane, ticket, text.into(), None)
        .await;
    let deadline = Instant::now() + TIMEOUT;
    while !owner.flat_text(pane).contains(text) {
        assert!(
            Instant::now() < deadline,
            "{sent:?}: never arrived:\n{}",
            owner.text(pane)
        );
        owner.until("pane output", |_| true).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    owner.until("pending output", |_| true).await;
    let arrived = owner
        .text(pane)
        .lines()
        .filter(|line| line.starts_with("GOT:") && line.contains(text))
        .count();
    assert_eq!(arrived, 1, "{}", owner.text(pane));
}

/// A Codex and a pi started by hand with their own options: the first Chat send restarts each
/// through its launch on its conversation, with those options, and the message arrives once.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_first_send_takes_over_a_codex_and_a_pi_started_by_hand() {
    let dir = tempfile::tempdir().unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let daemon = start_daemon(dir.path(), Path::new("/bin/zsh")).await;
    build_running_agents(dir.path());
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    for (typed, kept, session) in [
        (
            "command codex -m o3",
            "--model o3",
            format!("resume {CODEX_FIRST}"),
        ),
        (
            "command pi --model sonnet",
            "--model sonnet",
            format!("--session {PI_FIRST}"),
        ),
    ] {
        let pane = shell_pane(&mut owner, &work).await;
        owner.type_line(pane, typed);
        started_with(&mut owner, pane, "").await;
        offers_takeover(&owner, pane).await;
        sends_once(&mut owner, pane, "hello there").await;
        let restarted = started_with(&mut owner, pane, kept).await;
        assert!(restarted.contains(&session), "{typed}: {restarted}");
        assert!(
            owner
                .flat_text(pane)
                .contains("Restarted here so Chat can send to it."),
            "{}",
            owner.text(pane)
        );
    }
    daemon.shutdown().await;
}

/// A pi that resumes another session inside itself is followed: a cold restart brings back the
/// one it writes, with the options it was typed with.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_pi_that_switched_sessions_comes_back_on_the_one_it_writes() {
    let dir = tempfile::tempdir().unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let daemon = start_daemon(dir.path(), Path::new("/bin/zsh")).await;
    build_running_agents(dir.path());
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let pane = shell_pane(&mut owner, &work).await;
    owner.type_line(pane, "command pi --model sonnet --thinking high");
    started_with(&mut owner, pane, "").await;
    let layout = dir.path().join("state/layout.json");
    let saved = |session: &str| {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let text = std::fs::read_to_string(&layout).unwrap_or_default();
            if text.contains(&format!("\"session_id\": \"{session}\"")) {
                return;
            }
            assert!(Instant::now() < deadline, "{session} never saved:\n{text}");
            std::thread::sleep(Duration::from_millis(100));
        }
    };
    saved(PI_FIRST);
    // pi writes the other session once it takes a message there.
    std::thread::sleep(Duration::from_millis(50));
    owner.type_line(pane, "switch");
    owner.wait_text(pane, "PI-SWITCHED").await;
    owner.type_line(pane, "on the other one");
    saved(PI_SWITCHED);
    daemon.shutdown().await;

    let daemon = start_daemon(dir.path(), Path::new("/bin/zsh")).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.client.attach(None);
    owner.until("layout", |owner| owner.layout.is_some()).await;
    owner.follow(pane).await;
    let restored = started_with(&mut owner, pane, "--session").await;
    assert!(
        restored.contains(PI_SWITCHED) && restored.contains("--model sonnet --thinking high"),
        "{restored}"
    );
    daemon.shutdown().await;
}

/// A Codex typed with options runs through its launch with them, and a restore brings it back
/// with the same options on its conversation; the prompt it was typed with is not sent again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_typed_codex_keeps_its_options_across_a_restore() {
    let dir = tempfile::tempdir().unwrap();
    let work = dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let daemon = start_daemon(dir.path(), Path::new("/bin/zsh")).await;
    build_running_agents(dir.path());
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let pane = shell_pane(&mut owner, &work).await;
    owner.type_line(pane, "codex -m o3 --search 'fix the parser'");
    let first = started_with(&mut owner, pane, "--model o3").await;
    assert!(
        first.contains("--search") && first.contains("fix the parser") && first.contains("tui."),
        "{first}"
    );
    let layout = dir.path().join("state/layout.json");
    let deadline = Instant::now() + Duration::from_secs(30);
    while !std::fs::read_to_string(&layout)
        .unwrap_or_default()
        .contains(&format!("\"session_id\": \"{CODEX_FIRST}\""))
    {
        assert!(Instant::now() < deadline, "the rollout never saved");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    daemon.shutdown().await;

    let daemon = start_daemon(dir.path(), Path::new("/bin/zsh")).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.client.attach(None);
    owner.until("layout", |owner| owner.layout.is_some()).await;
    owner.follow(pane).await;
    let restored = started_with(&mut owner, pane, "resume").await;
    assert!(
        restored.contains("--model o3")
            && restored.contains("--search")
            && restored.contains(CODEX_FIRST)
            && !restored.contains("fix the parser"),
        "{restored}"
    );
    daemon.shutdown().await;
}
