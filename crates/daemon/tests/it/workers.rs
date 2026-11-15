//! Worker agents started with agent_spawn: a turn ends only on the agent's own end-of-turn
//! signal, results carry the final message and outlive the pane, and the first prompt waits
//! until the agent is really ready for it.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::PaneId;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use crate::support::{TestClient, start_with, ticket};
use crate::term::{Caller, call, claude_hook, hook_payload, user_floats, zsh};

const THREAD: &str = "0199a213-81c0-7800-8aa1-bbab2a035a53";

/// A daemon whose panes find the given fake agents first on their `PATH`.
struct Host {
    _daemon: daemon::Daemon,
    user: TestClient,
    lead: Caller,
    codex_home: PathBuf,
    _dirs: Vec<tempfile::TempDir>,
}

async fn host(fakes: &[(&str, &str)]) -> Option<Host> {
    let zsh = zsh()?;
    let bin = tempfile::tempdir().unwrap();
    for (name, script) in fakes {
        let path = bin.path().join(name);
        std::fs::write(&path, script).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    // A hook shim that does nothing, so an agent that exits leaves its pane at the shell.
    let shim = bin.path().join("gudo-hook");
    std::fs::write(&shim, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
    let home = tempfile::tempdir().unwrap();
    let codex_home = home.path().join("codex-home");
    std::fs::create_dir_all(&codex_home).unwrap();
    let state = tempfile::tempdir().unwrap();
    let env = [
        ("PATH", format!("{}:/usr/bin:/bin", bin.path().display())),
        ("HOME", home.path().display().to_string()),
        ("CODEX_HOME", codex_home.display().to_string()),
    ];
    let daemon = start_with(state.path(), |config| {
        config.shell = Some(zsh);
        config.hook_bin = Some(shim);
        config.codex_chat = false;
        config.claude_chat_streaming = false;
        config.pane_env.extend(
            env.iter()
                .map(|(key, value)| ((*key).to_owned(), value.clone())),
        );
    })
    .await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = user.attach_and_follow().await;
    let lead = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(state.path().join("hook.token")).unwrap(),
        pane: agent_pane.0.to_string(),
    };
    Some(Host {
        _daemon: daemon,
        user,
        lead,
        codex_home,
        _dirs: vec![bin, home, state],
    })
}

/// A hook or notification the agent in `pane` would send.
async fn hook(lead: &Caller, pane: &str, agent: &str, event: &str, seq: u64, payload: Value) {
    let request = daemon::HookRequest {
        v: 1,
        token: lead.token.clone(),
        pane: pane.into(),
        agent: agent.into(),
        event: event.into(),
        seq,
        payload,
    };
    let mut stream = UnixStream::connect(&lead.socket).await.unwrap();
    let mut line = serde_json::to_vec(&request).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
}

/// Codex's `notify` for a finished turn, without the message when `message` is `None`.
fn codex_turn_complete(message: Option<&str>) -> Value {
    json!({
        "type": "agent-turn-complete",
        "thread-id": THREAD,
        "turn-id": "t1",
        "cwd": "/tmp",
        "input-messages": ["fix the parser"],
        "last-assistant-message": message,
    })
}

/// `agent_spawn`, which may wait out an agent's restart.
async fn spawn(lead: &Caller, args: Value) -> Value {
    let reply = tokio::time::timeout(
        Duration::from_secs(60),
        call(&lead.socket, &lead.token, &lead.pane, "agent_spawn", args),
    )
    .await
    .expect("agent_spawn hung");
    match reply {
        daemon::TermReply::Ok(value) => value,
        daemon::TermReply::Error(error) => panic!("agent_spawn: {error:?}"),
    }
}

fn pane_number(agent: &Value) -> String {
    agent["agent"]["pane"]
        .as_str()
        .unwrap()
        .trim_start_matches('p')
        .to_owned()
}

async fn eventually(what: &str, mut check: impl AsyncFnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while !check().await {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// A Codex that writes its rollout the way Codex does, shows helper activity (a spinner in
/// the title, OSC 7501 working then done, an OSC 9 notification) while it works on a line,
/// and records the turn's answer in its rollout. The turn's own end is the test's `notify`.
const CODEX_WITH_HELPERS: &str = r#"#!/bin/sh
dir="$CODEX_HOME/sessions/2026/11/15"
mkdir -p "$dir"
f="$dir/rollout-2026-11-15T12-00-00-__THREAD__.jsonl"
printf '{"type":"session_meta","payload":{"id":"__THREAD__","cwd":"%s"}}\n' "$PWD" > "$f"
printf '\033]0;app\007'
printf '\033]7501;state=idle:app=codex\033\\'
echo "codex ready"
while IFS= read -r line; do
  printf '\033]0;\342\240\213 app\007'
  printf '\033]7501;state=working:app=codex\033\\'
  echo "working on $line"
  sleep 0.3
  printf '\033]7501;state=done:app=codex\033\\'
  printf '\033]9;Agent turn complete\007'
  printf '\033]0;app\007'
  printf '{"timestamp":"t","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"Fixed the parser."}}\n' >> "$f"
done
"#;

#[tokio::test(flavor = "multi_thread")]
async fn a_codex_turn_ends_only_on_its_own_end_of_turn_signal() {
    let script = CODEX_WITH_HELPERS.replace("__THREAD__", THREAD);
    let Some(mut host) = host(&[("codex", &script)]).await else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let lead = &host.lead;
    let spawned = lead
        .ok(
            "agent_spawn",
            json!({ "kind": "codex", "prompt": "fix the parser", "float": true, "closeWhenDone": true, "timeoutMs": 15000 }),
        )
        .await;
    assert_eq!(spawned["promptDelivery"], "accepted", "{spawned}");
    let worker = pane_number(&spawned);
    let worker_ref = format!("p{worker}");
    let worker_id = PaneId(worker.parse().unwrap());
    host.user
        .until("the worker's window", |client| {
            user_floats(client)
                .iter()
                .any(|(panes, _)| panes.contains(&worker_id.0))
        })
        .await;
    let waited = lead
        .ok("pane_wait", json!({ "pane": worker_ref, "match": "working on fix the parser", "since": "c0", "timeoutMs": 5000 }))
        .await;
    assert_eq!(waited["status"], "matched", "{waited}");

    // Spinners, program reports and notifications are not the end of the turn: the window
    // stays well past its linger, and no turn is counted.
    tokio::time::sleep(Duration::from_secs(4)).await;
    let during = lead.ok("agent_result", json!({ "pane": worker_ref })).await;
    assert_eq!(during["agent"]["turns"], 0, "{during}");
    assert_eq!(during["agent"]["state"], "working", "{during}");
    assert!(during["result"].is_null(), "{during}");
    assert!(
        during["agent"].get("closed").is_none(),
        "the window closed before the turn ended: {during}"
    );

    // Codex's own notify ends it, once, however many times it arrives; its message comes
    // from the rollout when notify left it out.
    hook(
        lead,
        &worker,
        "codex",
        daemon::CODEX_NOTIFY_EVENT,
        1,
        codex_turn_complete(None),
    )
    .await;
    hook(
        lead,
        &worker,
        "codex",
        daemon::CODEX_NOTIFY_EVENT,
        2,
        codex_turn_complete(None),
    )
    .await;
    let finished = lead
        .ok(
            "agent_wait",
            json!({ "panes": [worker_ref], "timeoutMs": 5000 }),
        )
        .await;
    assert_eq!(finished["status"], "ok", "{finished}");
    assert!(
        matches!(
            finished["agents"][0]["state"].as_str(),
            Some("idle" | "done" | "exited")
        ),
        "{finished}"
    );
    let ended = Instant::now();
    host.user
        .until("the worker's window closing", |client| {
            !user_floats(client)
                .iter()
                .any(|(panes, _)| panes.contains(&worker_id.0))
        })
        .await;
    assert!(
        ended.elapsed() >= Duration::from_millis(1500),
        "closed {:?} after the turn ended",
        ended.elapsed()
    );
    let result = lead.ok("agent_result", json!({ "pane": worker_ref })).await;
    assert_eq!(result["agent"]["turns"], 1, "{result}");
    assert_eq!(result["result"]["outcome"], "completed", "{result}");
    assert_eq!(result["result"]["message"], "Fixed the parser.", "{result}");
    let transcript = result["result"]["transcriptPath"].as_str().unwrap_or("");
    assert!(
        transcript.starts_with(&host.codex_home.display().to_string())
            && transcript.ends_with(&format!("{THREAD}.jsonl")),
        "{result}"
    );
}

const CLAUDE_ECHO: &str = "#!/bin/sh\nwhile IFS= read -r line; do echo \"got: $line\"; done\n";

#[tokio::test(flavor = "multi_thread")]
async fn results_outlive_the_worker_pane() {
    let Some(host) = host(&[("claude", CLAUDE_ECHO)]).await else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let lead = &host.lead;
    let (socket, token) = (lead.socket.clone(), lead.token.clone());

    let finished = pane_number(&lead.ok("agent_spawn", json!({ "kind": "claude" })).await);
    for (seq, event, extra) in [
        (1, "SessionStart", json!({ "source": "startup" })),
        (2, "UserPromptSubmit", json!({ "prompt": "fix it" })),
        (
            3,
            "Stop",
            json!({ "stop_hook_active": false, "last_assistant_message": "Fixed." }),
        ),
    ] {
        claude_hook(
            &socket,
            &token,
            &finished,
            event,
            seq,
            hook_payload(event, extra),
        )
        .await;
    }
    let busy = pane_number(&lead.ok("agent_spawn", json!({ "kind": "claude" })).await);
    for (seq, event, extra) in [
        (1, "SessionStart", json!({ "source": "startup" })),
        (2, "UserPromptSubmit", json!({ "prompt": "refactor" })),
    ] {
        claude_hook(
            &socket,
            &token,
            &busy,
            event,
            seq,
            hook_payload(event, extra),
        )
        .await;
    }
    let busy_ref = format!("p{busy}");
    eventually("the second worker working", async || {
        let info = lead.ok("agent_result", json!({ "pane": busy_ref })).await;
        info["agent"]["state"] == "working"
    })
    .await;

    for pane in [&finished, &busy] {
        let closed = lead
            .ok("pane_close", json!({ "pane": format!("p{pane}") }))
            .await;
        assert_eq!(closed["closed"], true, "{closed}");
    }

    let result = lead
        .ok("agent_result", json!({ "pane": format!("p{finished}") }))
        .await;
    assert_eq!(result["agent"]["state"], "exited", "{result}");
    assert_eq!(result["agent"]["turns"], 1, "{result}");
    assert_eq!(result["result"]["message"], "Fixed.", "{result}");
    assert_eq!(result["result"]["outcome"], "completed", "{result}");

    let cancelled = lead.ok("agent_result", json!({ "pane": busy_ref })).await;
    assert_eq!(cancelled["result"]["outcome"], "cancelled", "{cancelled}");
    assert_eq!(cancelled["result"]["reason"], "pane_closed", "{cancelled}");
    assert_eq!(
        cancelled["result"]["messageUnavailable"], "pane_closed",
        "{cancelled}"
    );

    let waited = lead
        .ok(
            "agent_wait",
            json!({ "panes": [format!("p{finished}"), busy_ref], "all": true, "timeoutMs": 2000 }),
        )
        .await;
    assert_eq!(waited["status"], "ok", "{waited}");
    assert_eq!(waited["agents"][0]["state"], "exited", "{waited}");
    assert_eq!(waited["agents"][1]["state"], "exited", "{waited}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_finished_turn_always_carries_its_message_or_why_not() {
    let Some(host) = host(&[("claude", CLAUDE_ECHO)]).await else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let lead = &host.lead;
    let (socket, token) = (lead.socket.clone(), lead.token.clone());
    let worker = pane_number(&lead.ok("agent_spawn", json!({ "kind": "claude" })).await);
    let worker_ref = format!("p{worker}");
    // A Stop hook without the message, and a transcript that has it.
    let transcript = host._dirs[1].path().join("w1.jsonl");
    std::fs::write(
        &transcript,
        concat!(
            r#"{"type":"user","message":{"role":"user","content":"fix it"}}"#,
            "\n",
            r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fixed it, tests pass."}]}}"#,
            "\n",
        ),
    )
    .unwrap();
    let with_transcript = |event: &str, extra: Value| {
        let mut payload = hook_payload(event, extra);
        payload["transcript_path"] = json!(transcript.display().to_string());
        payload
    };
    for (seq, event, extra) in [
        (1, "SessionStart", json!({ "source": "startup" })),
        (2, "UserPromptSubmit", json!({ "prompt": "fix it" })),
        (3, "Stop", json!({ "stop_hook_active": false })),
    ] {
        claude_hook(
            &socket,
            &token,
            &worker,
            event,
            seq,
            with_transcript(event, extra),
        )
        .await;
    }
    eventually("the message read from the transcript", async || {
        let result = lead.ok("agent_result", json!({ "pane": worker_ref })).await;
        result["result"]["message"] == "Fixed it, tests pass."
    })
    .await;
    let result = lead.ok("agent_result", json!({ "pane": worker_ref })).await;
    assert_eq!(result["agent"]["state"], "idle", "{result}");
    assert!(
        result["result"].get("messageUnavailable").is_none(),
        "{result}"
    );

    // A turn whose message is nowhere says why.
    for (seq, event, extra) in [
        (4, "UserPromptSubmit", json!({ "prompt": "again" })),
        (5, "Stop", json!({ "stop_hook_active": false })),
    ] {
        let mut payload = hook_payload(event, extra);
        payload["transcript_path"] = json!("/nonexistent/w1.jsonl");
        claude_hook(&socket, &token, &worker, event, seq, payload).await;
    }
    eventually("the second turn", async || {
        let result = lead.ok("agent_result", json!({ "pane": worker_ref })).await;
        result["agent"]["turns"] == 2 && result["result"]["messageUnavailable"].is_string()
    })
    .await;
    let result = lead.ok("agent_result", json!({ "pane": worker_ref })).await;
    assert!(result["result"]["message"].is_null(), "{result}");
}

/// A Codex that updates itself and exits, as `codex` does when the user picks "Update now".
const CODEX_UPDATING: &str = r#"#!/bin/sh
echo "Updating Codex via npm install -g @openai/codex"
sleep 0.3
echo "Update ran successfully! Please restart Codex."
"#;

#[tokio::test(flavor = "multi_thread")]
async fn a_codex_that_exits_to_update_fails_its_first_prompt_with_the_reason() {
    let Some(host) = host(&[("codex", CODEX_UPDATING)]).await else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let lead = &host.lead;
    let spawned = spawn(
        lead,
        json!({ "kind": "codex", "prompt": "fix the parser", "timeoutMs": 45000 }),
    )
    .await;
    assert_eq!(spawned["promptDelivery"], "failed", "{spawned}");
    assert_eq!(
        spawned["promptFailure"]["reason"], "agent_exited",
        "{spawned}"
    );
    let message = spawned["promptFailure"]["message"].as_str().unwrap_or("");
    assert!(message.contains("restart Codex"), "{spawned}");
    let worker_ref = spawned["agent"]["pane"].as_str().unwrap().to_owned();
    let read = lead
        .ok("pane_read", json!({ "pane": worker_ref, "since": "c0" }))
        .await;
    assert!(
        !read.to_string().contains("fix the parser"),
        "the prompt went to the shell: {read}"
    );
}

/// A Codex that exits to update on its first run and works on the next, named `codex` in
/// the process table as the real one is.
const CODEX_UPDATING_ONCE: &str = r#"#!/usr/bin/env zsh
if [[ "$1" == serve ]]; then
  sleep 1
  printf '\033]0;app\007'
  printf '\033]7501;state=idle:app=codex\033\\'
  echo "codex ready"
  while IFS= read -r line; do echo "got: $line"; done
  exit 0
fi
if [[ ! -e "$HOME/updated" ]]; then
  touch "$HOME/updated"
  echo "Update ran successfully! Please restart Codex."
  exit 0
fi
exec -a codex zsh "$0" serve
"#;

#[tokio::test(flavor = "multi_thread")]
async fn the_first_prompt_waits_for_codex_run_again_after_an_update() {
    let Some(host) = host(&[("codex", CODEX_UPDATING_ONCE)]).await else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let lead = &host.lead;
    let spawning = {
        let lead = lead.clone_as(lead.pane.clone());
        tokio::spawn(async move {
            spawn(
                &lead,
                json!({ "kind": "codex", "prompt": "fix the parser", "timeoutMs": 45000 }),
            )
            .await
        })
    };
    let worker = loop {
        let list = lead.ok("pane_list", json!({})).await;
        if let Some(pane) = list["panes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|pane| pane["id"] != format!("p{}", lead.pane))
        {
            break pane["id"].as_str().unwrap().to_owned();
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let exited = lead
        .ok(
            "pane_wait",
            json!({ "pane": worker, "match": "restart Codex", "since": "c0", "timeoutMs": 15000 }),
        )
        .await;
    assert_eq!(exited["status"], "matched", "{exited}");
    let prompt = lead
        .ok(
            "pane_wait",
            json!({ "pane": worker, "prompt": true, "timeoutMs": 15000 }),
        )
        .await;
    assert_ne!(prompt["status"], "timeout", "{prompt}");
    let worker_id = PaneId(worker.trim_start_matches('p').parse().unwrap());
    host.user.type_line(worker_id, "codex");
    let spawned = spawning.await.unwrap();
    assert_eq!(spawned["promptDelivery"], "accepted", "{spawned}");
    let delivered = lead
        .ok("pane_wait", json!({ "pane": worker, "match": "got: fix the parser", "since": "c0", "timeoutMs": 15000 }))
        .await;
    assert_eq!(delivered["status"], "matched", "{delivered}");
}

/// A Codex that asks whether to trust the folder before it starts.
const CODEX_ASKING_TRUST: &str = r#"#!/bin/sh
printf '\033[2J\033[H'
printf '> You are in %s\n\n  Do you trust the contents of this directory?\n\n  \342\200\272 1. Yes, continue\n    2. No, quit\n\n  Press enter to continue' "$PWD"
IFS= read -r answer
printf '\033[2J\033[H'
printf '\033]0;app\007'
printf '\033]7501;state=idle:app=codex\033\\'
echo "codex ready"
while IFS= read -r line; do echo "got: $line"; done
"#;

#[tokio::test(flavor = "multi_thread")]
async fn the_first_prompt_waits_behind_a_trust_dialog_until_the_user_answers() {
    let Some(host) = host(&[("codex", CODEX_ASKING_TRUST)]).await else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let lead = &host.lead;
    let spawned = lead
        .ok(
            "agent_spawn",
            json!({ "kind": "codex", "prompt": "fix the parser", "timeoutMs": 20000 }),
        )
        .await;
    assert_eq!(spawned["promptDelivery"], "queued", "{spawned}");
    assert_eq!(spawned["agent"]["state"], "blocked", "{spawned}");
    assert_eq!(spawned["agent"]["status"]["kind"], "trust", "{spawned}");
    let waits_on = spawned["agent"]["status"]["message"].as_str().unwrap_or("");
    assert!(waits_on.contains("trust"), "{spawned}");

    let worker = pane_number(&spawned);
    let worker_ref = format!("p{worker}");
    host.user.type_line(PaneId(worker.parse().unwrap()), "");
    let delivered = lead
        .ok("pane_wait", json!({ "pane": worker_ref, "match": "got: fix the parser", "since": "c0", "timeoutMs": 10000 }))
        .await;
    assert_eq!(delivered["status"], "matched", "{delivered}");
    let after = lead.ok("agent_result", json!({ "pane": worker_ref })).await;
    assert_eq!(after["agent"]["promptDelivery"], "accepted", "{after}");
}

/// A Codex waiting on approval says what it waits on.
const CODEX_ASKING_APPROVAL: &str = r#"#!/bin/sh
printf '\033]0;app\007'
printf '\033]7501;state=idle:app=codex\033\\'
echo "codex ready"
IFS= read -r line
printf '\033]0;[ ! ] Action Required\007'
printf '\033]9;Approval requested: cargo test --workspace\007'
exec sleep 600
"#;

#[tokio::test(flavor = "multi_thread")]
async fn a_blocked_codex_says_what_it_waits_on() {
    let Some(host) = host(&[("codex", CODEX_ASKING_APPROVAL)]).await else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let lead = &host.lead;
    let spawned = lead
        .ok(
            "agent_spawn",
            json!({ "kind": "codex", "prompt": "run the tests", "timeoutMs": 15000 }),
        )
        .await;
    assert_eq!(spawned["promptDelivery"], "accepted", "{spawned}");
    let worker_ref = spawned["agent"]["pane"].as_str().unwrap().to_owned();
    let blocked = lead
        .ok(
            "agent_wait",
            json!({ "panes": [worker_ref], "until": ["blocked"], "timeoutMs": 10000 }),
        )
        .await;
    assert_eq!(blocked["status"], "ok", "{blocked}");
    let status = &blocked["agents"][0]["status"];
    assert_eq!(status["kind"], "permission", "{blocked}");
    assert_eq!(status["message"], "cargo test --workspace", "{blocked}");
}
