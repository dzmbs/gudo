//! Agents driving the terminal through the hook socket's term tools: running commands with
//! their exit codes, waiting, reading on from a cursor, and the limits on what a pane may do.

use std::path::{Path, PathBuf};

use client_core::ClientConfig;
use daemon::{TERM_VERSION, TermAsk, TermCall, TermErrorCode, TermReply};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use crate::support::{TestClient, start_with, ticket};

fn zsh() -> Option<PathBuf> {
    ["/bin/zsh", "/usr/bin/zsh", "/opt/homebrew/bin/zsh"]
        .into_iter()
        .map(PathBuf::from)
        .find(|p| p.exists())
}

struct Caller {
    socket: PathBuf,
    token: String,
    pane: String,
}

impl Caller {
    async fn call(&self, tool: &str, args: Value) -> TermReply {
        tokio::time::timeout(
            std::time::Duration::from_secs(20),
            call(&self.socket, &self.token, &self.pane, tool, args),
        )
        .await
        .unwrap_or_else(|_| panic!("{tool} hung"))
    }

    async fn ok(&self, tool: &str, args: Value) -> Value {
        match self.call(tool, args.clone()).await {
            TermReply::Ok(v) => v,
            TermReply::Error(e) => panic!("{tool} {args}: {e:?}"),
        }
    }

    async fn refused(&self, tool: &str, args: Value) -> TermErrorCode {
        match self.call(tool, args.clone()).await {
            TermReply::Error(e) => e.code,
            TermReply::Ok(v) => panic!("{tool} {args} was allowed: {v}"),
        }
    }
}

async fn call(socket: &Path, token: &str, pane: &str, tool: &str, args: Value) -> TermReply {
    let call = TermCall {
        v: TERM_VERSION,
        token: token.into(),
        pane: pane.into(),
        term: TermAsk {
            tool: tool.into(),
            args,
        },
    };
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(&call).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
    serde_json::from_str(&answer).unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn an_agent_runs_waits_reads_and_stays_in_its_lane() {
    let Some(zsh) = zsh() else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |c| c.shell = Some(zsh)).await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let me = user.attach_and_follow().await;
    let agent = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        pane: me.0.to_string(),
    };

    let who = agent.ok("whoami", json!({})).await;
    assert_eq!(who["pane"]["id"], format!("p{}", me.0));
    assert_eq!(who["pane"]["isSelf"], true);

    // A command in a pane of its own: exit code and output, and the user keeps focus.
    let run = agent
        .ok("cmd_run", json!({ "command": "echo hello; (exit 3)" }))
        .await;
    assert_eq!(run["status"], "exited", "{run}");
    assert_eq!(run["command"]["exitCode"], 3, "{run}");
    assert_eq!(run["output"]["text"], "hello", "{run}");
    let worker = run["pane"].as_str().unwrap().to_owned();
    user.until("the split", |c| {
        c.tab().root != client_core::proto::LayoutNode::Leaf(me)
    })
    .await;
    assert_eq!(user.focused(), me, "the agent's pane did not take focus");

    // The same pane again, and its listing.
    let run = agent
        .ok(
            "cmd_run",
            json!({ "command": "printf 'a\\nb\\n'", "pane": worker }),
        )
        .await;
    assert_eq!(run["output"]["text"], "a\nb", "{run}");
    let list = agent.ok("pane_list", json!({})).await;
    let mine = list["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["id"] == worker)
        .unwrap();
    assert_eq!(mine["createdByYou"], true);
    assert_eq!(mine["lastCommand"]["exitCode"], 0);

    // Its own pane is not its to type into.
    assert_eq!(
        agent
            .refused("pane_send", json!({ "pane": "self", "text": "x" }))
            .await,
        TermErrorCode::Forbidden
    );

    // Wait for a line and its value, then read on from the cursor.
    let cursor = agent.ok("pane_read", json!({ "pane": worker })).await["output"]["cursor"]
        .as_str()
        .unwrap()
        .to_owned();
    agent
        .ok(
            "pane_send",
            json!({ "pane": worker, "text": "sleep 0.3; echo ready-42", "submit": true }),
        )
        .await;
    let waited = agent
        .ok("pane_wait", json!({ "pane": worker, "match": "^ready-(\\d+)$", "since": cursor, "timeoutMs": 5000 }))
        .await;
    assert_eq!(waited["status"], "matched", "{waited}");
    assert_eq!(waited["match"]["groups"][0], "42");
    let read = agent
        .ok("pane_read", json!({ "pane": worker, "since": cursor }))
        .await;
    assert!(
        read["output"]["text"]
            .as_str()
            .unwrap()
            .contains("ready-42"),
        "{read}"
    );
    let quiet = agent
        .ok(
            "pane_wait",
            json!({ "pane": worker, "prompt": true, "timeoutMs": 5000 }),
        )
        .await;
    assert_eq!(quiet["status"], "prompt", "{quiet}");

    // A password prompt is the user's.
    let run = agent
        .ok(
            "cmd_run",
            json!({ "command": "read -s secret", "pane": worker, "timeoutMs": 500 }),
        )
        .await;
    assert_eq!(run["status"], "timeout", "{run}");
    assert_eq!(
        agent
            .refused("pane_send", json!({ "pane": worker, "text": "hunter2" }))
            .await,
        TermErrorCode::SecretPrompt
    );
    agent.ok("pane_close", json!({ "pane": worker })).await;

    // A pane's own token speaks for that pane only.
    let run = agent
        .ok("cmd_run", json!({ "command": "echo $UN_TOKEN" }))
        .await;
    let other_token = run["output"]["text"].as_str().unwrap().trim().to_owned();
    let other_pane = run["pane"]
        .as_str()
        .unwrap()
        .trim_start_matches('p')
        .to_owned();
    assert_eq!(other_token.len(), 64, "{run}");
    let posing = Caller {
        token: other_token.clone(),
        ..agent.clone_as(me.0.to_string())
    };
    assert_eq!(
        posing.refused("whoami", json!({})).await,
        TermErrorCode::Forbidden
    );
    let itself = agent.clone_as(other_pane.clone());
    let itself = Caller {
        token: other_token,
        ..itself
    };
    assert_eq!(
        itself.ok("whoami", json!({})).await["pane"]["id"],
        format!("p{other_pane}")
    );
    // And it may not drive the pane that created it.
    assert_eq!(
        itself
            .refused(
                "pane_send",
                json!({ "pane": format!("p{}", me.0), "text": "x" })
            )
            .await,
        TermErrorCode::Forbidden
    );
}

impl Caller {
    fn clone_as(&self, pane: String) -> Self {
        Self {
            socket: self.socket.clone(),
            token: self.token.clone(),
            pane,
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn any_program_reports_its_status_and_agents_wait_for_it() {
    let Some(zsh) = zsh() else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |c| c.shell = Some(zsh)).await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let me = user.attach_and_follow().await;
    let agent = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        pane: me.0.to_string(),
    };

    // A worker (any program, no agent integration) says it is blocked on a question.
    let run = agent
        .ok(
            "cmd_run",
            json!({ "command": "printf '\\e]7501;state=blocked:kind=question:app=pi\\e\\\\'" }),
        )
        .await;
    let worker = run["pane"].as_str().unwrap().to_owned();
    let list = agent.ok("pane_list", json!({})).await;
    let pane = list["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["id"] == worker)
        .unwrap();
    assert_eq!(pane["status"]["state"], "blocked", "{pane}");
    assert_eq!(pane["status"]["kind"], "question");
    assert_eq!(pane["status"]["app"], "pi");

    // Then finishes while the orchestrator waits for it.
    agent
        .ok("pane_send", json!({ "pane": worker, "text": "sleep 0.3; printf '\\e]7501;state=done:app=pi\\e\\\\'", "submit": true }))
        .await;
    let waited = agent
        .ok(
            "pane_wait",
            json!({ "pane": worker, "status": ["done", "error"], "timeoutMs": 5000 }),
        )
        .await;
    assert_eq!(waited["status"], "status", "{waited}");
    assert_eq!(waited["programStatus"]["state"], "done");

    // An agent that cannot print OSC 7501 reports through the tool.
    agent
        .ok(
            "status_set",
            json!({ "state": "working", "message": "Running tests", "progress": 40 }),
        )
        .await;
    let who = agent.ok("whoami", json!({})).await;
    assert_eq!(who["pane"]["status"]["message"], "Running tests", "{who}");
    // Its words are shown to people and agents as they print, and bounded.
    let hostile = format!(
        "Running\u{202e}stset\u{202c}\r\n\x1b[2Jok{}",
        "x".repeat(4096)
    );
    agent
        .ok(
            "status_set",
            json!({ "state": "working", "message": hostile }),
        )
        .await;
    let who = agent.ok("whoami", json!({})).await;
    let shown = who["pane"]["status"]["message"].as_str().unwrap();
    assert!(shown.starts_with("Runningstset [2Jokxx"), "{shown:?}");
    assert_eq!(shown.chars().count(), 513, "{shown:?}");
    agent.ok("status_set", json!({ "state": "clear" })).await;
    assert!(agent.ok("whoami", json!({})).await["pane"]["status"].is_null());
}

/// Hooks a worker's Claude would send, stamped for `pane`.
async fn claude_hook(
    socket: &Path,
    token: &str,
    pane: &str,
    event: &str,
    seq: u64,
    payload: Value,
) {
    let request = daemon::HookRequest {
        v: 1,
        token: token.into(),
        pane: pane.into(),
        agent: "claude".into(),
        event: event.into(),
        seq,
        payload,
    };
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(&request).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
}

fn hook_payload(event: &str, extra: Value) -> Value {
    let mut payload = json!({
        "session_id": "w1", "transcript_path": "/tmp/w1.jsonl", "cwd": "/tmp",
        "permission_mode": "default", "hook_event_name": event,
    });
    payload
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    payload
}

#[tokio::test(flavor = "multi_thread")]
async fn an_agent_runs_a_worker_agent_and_reads_its_answers() {
    let Some(zsh) = zsh() else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    // A stand-in for Claude Code: it echoes what it is given; the test sends its hooks.
    let bin = tempfile::tempdir().unwrap();
    let fake = bin.path().join("claude");
    std::fs::write(
        &fake,
        "#!/bin/sh\nwhile IFS= read -r line; do echo \"got: $line\"; done\n",
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let path = format!("{}:/usr/bin:/bin", bin.path().display());
    // A home of its own: the user's rc files would put the real agent first on the PATH.
    let home = tempfile::tempdir().unwrap();
    let home_dir = home.path().to_string_lossy().into_owned();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |c| {
        c.shell = Some(zsh);
        c.pane_env.push(("PATH".into(), path));
        c.pane_env.push(("HOME".into(), home_dir));
    })
    .await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let me = user.attach_and_follow().await;
    let lead = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        pane: me.0.to_string(),
    };
    let (socket, token) = (lead.socket.clone(), lead.token.clone());

    // Spawned with a prompt: delivered once the worker's session has started.
    let spawning = {
        let lead = lead.clone_as(me.0.to_string());
        tokio::spawn(async move {
            lead.ok(
                "agent_spawn",
                json!({ "kind": "claude", "prompt": "fix the tests", "direction": "down" }),
            )
            .await
        })
    };
    let worker = loop {
        let list = lead.ok("pane_list", json!({})).await;
        if let Some(p) = list["panes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["kind"] == "agent")
        {
            break p["id"].as_str().unwrap().trim_start_matches('p').to_owned();
        }
        assert!(
            !spawning.is_finished(),
            "the spawn ended before its pane opened"
        );
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    };
    claude_hook(
        &socket,
        &token,
        &worker,
        "SessionStart",
        1,
        hook_payload("SessionStart", json!({ "source": "startup" })),
    )
    .await;
    let spawned = spawning.await.unwrap();
    assert_eq!(spawned["agent"]["kind"], "claude", "{spawned}");
    let worker_ref = format!("p{worker}");
    let waited = lead
        .ok("pane_wait", json!({ "pane": worker_ref, "match": "got: .*fix the tests", "since": "c0", "timeoutMs": 5000 }))
        .await;
    assert_eq!(
        waited["status"], "matched",
        "the prompt reached the worker: {waited}"
    );

    // Working: a second prompt is refused until it is done.
    claude_hook(
        &socket,
        &token,
        &worker,
        "UserPromptSubmit",
        2,
        hook_payload("UserPromptSubmit", json!({ "prompt": "fix the tests" })),
    )
    .await;
    assert_eq!(
        lead.refused(
            "agent_prompt",
            json!({ "pane": worker_ref, "text": "and lint" })
        )
        .await,
        TermErrorCode::AgentBusy
    );
    claude_hook(
        &socket,
        &token,
        &worker,
        "Stop",
        3,
        hook_payload(
            "Stop",
            json!({ "stop_hook_active": false, "last_assistant_message": "All 12 tests pass." }),
        ),
    )
    .await;
    let done = lead
        .ok(
            "agent_wait",
            json!({ "panes": [worker_ref], "timeoutMs": 5000 }),
        )
        .await;
    assert_eq!(done["status"], "ok", "{done}");
    assert_eq!(done["agents"][0]["state"], "idle", "{done}");
    let result = lead.ok("agent_result", json!({ "pane": worker_ref })).await;
    assert_eq!(
        result["result"]["message"], "All 12 tests pass.",
        "{result}"
    );
    assert_eq!(result["result"]["outcome"], "completed");

    // Prompt and wait for that turn's answer in one call.
    let prompting = {
        let lead = lead.clone_as(me.0.to_string());
        let worker_ref = worker_ref.clone();
        tokio::spawn(async move {
            lead.ok(
                "agent_prompt",
                json!({ "pane": worker_ref, "text": "now lint", "wait": true, "timeoutMs": 10000 }),
            )
            .await
        })
    };
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    claude_hook(
        &socket,
        &token,
        &worker,
        "UserPromptSubmit",
        4,
        hook_payload("UserPromptSubmit", json!({ "prompt": "now lint" })),
    )
    .await;
    claude_hook(
        &socket,
        &token,
        &worker,
        "Stop",
        5,
        hook_payload(
            "Stop",
            json!({ "stop_hook_active": false, "last_assistant_message": "Lint is clean." }),
        ),
    )
    .await;
    let answered = prompting.await.unwrap();
    assert_eq!(answered["status"], "finished", "{answered}");
    assert_eq!(
        answered["result"]["message"], "Lint is clean.",
        "{answered}"
    );
}
