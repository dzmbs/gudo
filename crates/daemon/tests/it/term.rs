//! Agents driving the terminal through the hook socket's term tools: running commands with
//! their exit codes, waiting, reading on from a cursor, and the limits on what a pane may do.

use std::path::{Path, PathBuf};

use client_core::ClientConfig;
use client_core::proto::{LayoutOp, OpOutcome, PaneLaunch};
use daemon::{TERM_VERSION, TermAsk, TermCall, TermErrorCode, TermReply};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use crate::support::{TestClient, start_with, ticket};

fn zsh() -> Option<PathBuf> {
    ["/bin/zsh", "/usr/bin/zsh", "/opt/homebrew/bin/zsh"]
        .into_iter()
        .map(PathBuf::from)
        .find(|path| path.exists())
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
            TermReply::Ok(value) => value,
            TermReply::Error(error) => panic!("{tool} {args}: {error:?}"),
        }
    }

    async fn refused(&self, tool: &str, args: Value) -> TermErrorCode {
        match self.call(tool, args.clone()).await {
            TermReply::Error(error) => error.code,
            TermReply::Ok(value) => panic!("{tool} {args} was allowed: {value}"),
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
    let daemon = start_with(dir.path(), |config| {
        config.shell = Some(zsh);
        // Driving the user's panes asks the owner, who never answers here.
        config.drive_ask_wait = std::time::Duration::from_millis(500);
    })
    .await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = user.attach_and_follow().await;
    let agent = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        pane: agent_pane.0.to_string(),
    };

    let who = agent.ok("whoami", json!({})).await;
    assert_eq!(who["pane"]["id"], format!("p{}", agent_pane.0));
    assert_eq!(who["pane"]["isSelf"], true);

    // A command in a pane of its own: exit code and output, and the user keeps focus.
    let run = agent
        .ok("cmd_run", json!({ "command": "echo hello; (exit 3)" }))
        .await;
    assert_eq!(run["status"], "exited", "{run}");
    assert_eq!(run["command"]["exitCode"], 3, "{run}");
    assert_eq!(run["output"]["text"], "hello", "{run}");
    let worker = run["pane"].as_str().unwrap().to_owned();
    user.until("the split", |client| {
        client.tab().root != client_core::proto::LayoutNode::Leaf(agent_pane)
    })
    .await;
    assert_eq!(
        user.focused(),
        agent_pane,
        "the agent's pane did not take focus"
    );

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
        .find(|pane| pane["id"] == worker)
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
        .ok("cmd_run", json!({ "command": "echo $GUDO_TOKEN" }))
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
        ..agent.clone_as(agent_pane.0.to_string())
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
    // And it may not drive the pane that created it without the owner's yes (none comes).
    assert_eq!(
        itself
            .refused(
                "pane_send",
                json!({ "pane": format!("p{}", agent_pane.0), "text": "x" })
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
    let daemon = start_with(dir.path(), |config| config.shell = Some(zsh)).await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = user.attach_and_follow().await;
    let agent = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        pane: agent_pane.0.to_string(),
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
        .find(|pane| pane["id"] == worker)
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

#[tokio::test(flavor = "multi_thread")]
async fn an_agent_drives_a_full_screen_program_by_what_it_shows() {
    let Some(zsh) = zsh() else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let menu = dir.path().join("menu.zsh");
    std::fs::write(
        &menu,
        "printf '\\e[?1049h\\e[H  apples\\r\\n\\e[7m> pears\\e[0m\\r\\n  plums'\n\
         read -k1\n\
         printf '\\e[2;1H  pears \\e[3;1H\\e[7m> plums\\e[0m\\e[?25l'\n\
         read -k1\n\
         printf '\\e[?25h\\e[?1049l'\n",
    )
    .unwrap();
    let daemon = start_with(dir.path(), |config| config.shell = Some(zsh)).await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = user.attach_and_follow().await;
    let agent = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        pane: agent_pane.0.to_string(),
    };
    let worker = agent.ok("cmd_run", json!({ "command": "true" })).await["pane"]
        .as_str()
        .unwrap()
        .to_owned();

    assert_eq!(
        agent
            .refused(
                "pane_wait",
                json!({ "pane": worker, "match": "x", "gone": true })
            )
            .await,
        TermErrorCode::InvalidArgs
    );

    agent
        .ok(
            "pane_send",
            json!({ "pane": worker, "text": format!("zsh {}", menu.display()), "submit": true }),
        )
        .await;
    let shown = agent
        .ok(
            "pane_wait",
            json!({ "pane": worker, "screen": true, "match": "^> (\\w+)", "timeoutMs": 5000 }),
        )
        .await;
    assert_eq!(shown["status"], "matched", "{shown}");
    assert_eq!(shown["match"]["groups"][0], "pears");
    // What is already on the screen counts: no new output is needed.
    let again = agent
        .ok(
            "pane_wait",
            json!({ "pane": worker, "screen": true, "match": "^> pears", "timeoutMs": 1000 }),
        )
        .await;
    assert_eq!(again["status"], "matched", "{again}");

    let read = agent.ok("pane_read", json!({ "pane": worker })).await;
    assert_eq!(read["altScreen"], true, "{read}");
    let screen = &read["screen"];
    assert_eq!(screen["highlights"][0]["text"], "> pears", "{read}");
    assert_eq!(screen["highlights"][0]["row"], 1);
    assert_eq!(screen["highlights"][0]["inverse"], true);
    assert_eq!(screen["cursor"]["row"], 2);

    agent
        .ok("pane_send", json!({ "pane": worker, "keys": ["x"] }))
        .await;
    let moved = agent
        .ok(
            "pane_wait",
            json!({ "pane": worker, "screen": true, "gone": true, "match": "^> pears", "timeoutMs": 5000 }),
        )
        .await;
    assert_eq!(moved["status"], "gone", "{moved}");
    assert_eq!(
        moved["screen"]["highlights"][0]["text"], "> plums",
        "{moved}"
    );
    assert_eq!(moved["screen"]["cursor"]["visible"], false, "{moved}");

    agent
        .ok("pane_send", json!({ "pane": worker, "keys": ["x"] }))
        .await;
    let back = agent
        .ok(
            "pane_wait",
            json!({ "pane": worker, "prompt": true, "timeoutMs": 5000 }),
        )
        .await;
    assert_eq!(back["status"], "prompt", "{back}");
    let list = agent.ok("pane_list", json!({})).await;
    let listed = list["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["id"] == worker)
        .unwrap();
    assert!(listed["multiplexer"].is_null(), "{listed}");
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
    let daemon = start_with(dir.path(), |config| {
        config.shell = Some(zsh);
        config.pane_env.push(("PATH".into(), path));
        config.pane_env.push(("HOME".into(), home_dir));
    })
    .await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = user.attach_and_follow().await;
    let lead = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        pane: agent_pane.0.to_string(),
    };
    let (socket, token) = (lead.socket.clone(), lead.token.clone());

    // Spawned with a prompt: delivered once the worker's session has started.
    let spawning = {
        let lead = lead.clone_as(agent_pane.0.to_string());
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
        if let Some(pane) = list["panes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|pane| pane["kind"] == "agent")
        {
            break pane["id"]
                .as_str()
                .unwrap()
                .trim_start_matches('p')
                .to_owned();
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
        let lead = lead.clone_as(agent_pane.0.to_string());
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

/// The floating windows of `pane`'s session as the user last heard them, by their panes.
fn user_floats(user: &TestClient) -> Vec<(Vec<u64>, bool)> {
    user.floats
        .last()
        .map(|update| {
            update
                .floats
                .iter()
                .map(|window| {
                    (
                        window.panes.iter().map(|pane| pane.0).collect(),
                        window.minimized,
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

fn id_of(pane: &Value) -> u64 {
    pane["id"]
        .as_str()
        .unwrap()
        .trim_start_matches('p')
        .parse()
        .unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn an_agent_floats_its_panes_and_never_takes_the_users_focus() {
    let Some(zsh) = zsh() else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |config| config.shell = Some(zsh)).await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = user.attach_and_follow().await;
    let agent = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        pane: agent_pane.0.to_string(),
    };

    // A log window over the tab, where the agent asked for it.
    let opened = agent
        .ok(
            "pane_split",
            json!({ "float": true, "frame": { "x": 0.55, "y": 0.05, "w": 0.4, "h": 0.5 } }),
        )
        .await;
    let log = id_of(&opened["pane"]);
    assert_eq!(opened["pane"]["float"]["panes"], json!([format!("p{log}")]));
    assert_eq!(opened["pane"]["float"]["frame"]["x"], 0.55);
    user.until("the float", |client| {
        user_floats(client) == [(vec![log], false)]
    })
    .await;
    assert_eq!(user.focused(), agent_pane, "the float did not take focus");

    // Its frame and closing only make sense on a float.
    assert_eq!(
        agent
            .refused("pane_split", json!({ "closeWhenDone": true }))
            .await,
        TermErrorCode::InvalidArgs
    );
    // The user's panes, and its own, are not its to float.
    assert_eq!(
        agent.refused("pane_float", json!({ "pane": "self" })).await,
        TermErrorCode::Forbidden
    );
    let OpOutcome::PaneCreated { pane_id: theirs } = user
        .op(LayoutOp::Split {
            pane_id: agent_pane,
            axis: client_core::proto::Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("no split");
    };
    user.op(LayoutOp::Focus {
        pane_id: agent_pane,
    })
    .await;
    assert_eq!(
        agent
            .refused("pane_float", json!({ "pane": format!("p{}", theirs.0) }))
            .await,
        TermErrorCode::Forbidden
    );
    assert_eq!(
        agent
            .refused("pane_minimize", json!({ "pane": format!("p{}", theirs.0) }))
            .await,
        TermErrorCode::Forbidden
    );

    // To the tray and back to the front, the keyboard staying with the user.
    let log_ref = format!("p{log}");
    agent.ok("pane_minimize", json!({ "pane": log_ref })).await;
    user.until("the chip", |client| {
        user_floats(client) == [(vec![log], true)]
    })
    .await;
    let raised = agent.ok("pane_raise", json!({ "pane": log_ref })).await;
    assert_eq!(raised["pane"]["float"]["minimized"], false, "{raised}");
    user.until("restored", |client| {
        user_floats(client) == [(vec![log], false)]
    })
    .await;
    assert_eq!(user.focused(), agent_pane);

    // Docked beside the user's pane: in the layout, the user's focus where it was.
    let docked = agent
        .ok(
            "pane_dock",
            json!({ "pane": log_ref, "beside": format!("p{}", theirs.0), "side": "down" }),
        )
        .await;
    assert!(docked["pane"]["float"].is_null(), "{docked}");
    user.until("docked", |client| user_floats(client).is_empty())
        .await;
    assert_eq!(user.focused(), agent_pane, "docking gave the focus back");
    assert_eq!(
        agent
            .refused("pane_raise", json!({ "pane": log_ref }))
            .await,
        TermErrorCode::InvalidArgs,
        "not floating any more"
    );

    // tab_new with float opens over the agent's own tab.
    let over = agent.ok("tab_new", json!({ "float": true })).await;
    assert_eq!(over["tab"], format!("t{}", user.tab().tab_id.0), "{over}");
    assert!(!over["pane"]["float"].is_null());

    // A run window closes by itself once its command finishes.
    let run = agent
        .ok(
            "pane_split",
            json!({ "float": true, "closeWhenDone": true }),
        )
        .await;
    let runner = id_of(&run["pane"]);
    assert_eq!(run["pane"]["float"]["closeWhenDone"], true);
    let gone = |client: &TestClient| {
        !crate::support::leaves(&client.tab().root).contains(&client_core::proto::PaneId(runner))
    };
    user.until("the run window", |client| !gone(client)).await;
    let ran = agent
        .ok(
            "cmd_run",
            json!({ "pane": format!("p{runner}"), "command": "echo built" }),
        )
        .await;
    assert_eq!(ran["status"], "exited", "{ran}");
    let ended = std::time::Instant::now();
    user.until("the run window closing", gone).await;
    assert!(
        ended.elapsed() >= std::time::Duration::from_secs(2),
        "it stays a moment to be read"
    );
    assert_eq!(user.focused(), agent_pane);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_floating_worker_closes_when_its_turn_ends_and_leaves_its_answer() {
    let Some(zsh) = zsh() else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let bin = tempfile::tempdir().unwrap();
    let fake = bin.path().join("claude");
    std::fs::write(
        &fake,
        "#!/bin/sh\nwhile IFS= read -r line; do echo \"got: $line\"; done\n",
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let path = format!("{}:/usr/bin:/bin", bin.path().display());
    let home = tempfile::tempdir().unwrap();
    let home_dir = home.path().to_string_lossy().into_owned();
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |config| {
        config.shell = Some(zsh);
        config.pane_env.push(("PATH".into(), path));
        config.pane_env.push(("HOME".into(), home_dir));
    })
    .await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = user.attach_and_follow().await;
    let lead = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        pane: agent_pane.0.to_string(),
    };

    let spawned = lead
        .ok(
            "agent_spawn",
            json!({ "kind": "claude", "float": true, "closeWhenDone": true }),
        )
        .await;
    let worker = spawned["agent"]["pane"]
        .as_str()
        .unwrap()
        .trim_start_matches('p')
        .to_owned();
    let worker_id: u64 = worker.parse().unwrap();
    user.until("the worker's window", |client| {
        user_floats(client) == [(vec![worker_id], false)]
    })
    .await;
    assert_eq!(user.focused(), agent_pane);

    let (socket, token) = (lead.socket.clone(), lead.token.clone());
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
            &worker,
            event,
            seq,
            hook_payload(event, extra),
        )
        .await;
    }
    user.until("the worker's window closing", |client| {
        !crate::support::leaves(&client.tab().root).contains(&client_core::proto::PaneId(worker_id))
    })
    .await;
    let result = lead
        .ok("agent_result", json!({ "pane": format!("p{worker}") }))
        .await;
    assert_eq!(result["result"]["message"], "Fixed.", "{result}");
    assert_eq!(result["agent"]["state"], "exited");
}

/// What a program in a pane can reach with what its environment holds (a guest Driver, a
/// misled agent): never the daemon's token, never another pane's calls, and a bounded number
/// of panes.
#[tokio::test(flavor = "multi_thread")]
async fn a_panes_environment_reaches_only_that_pane() {
    let Some(zsh) = zsh() else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |config| config.shell = Some(zsh)).await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = user.attach_and_follow().await;
    let hook_token = std::fs::read_to_string(dir.path().join("hook.token")).unwrap();
    let agent = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: hook_token.clone(),
        pane: agent_pane.0.to_string(),
    };

    let run = agent
        .ok(
            "cmd_run",
            json!({ "command": "env; echo $GUDO_TOKEN", "maxBytes": 262_144 }),
        )
        .await;
    let text = run["output"]["text"].as_str().unwrap();
    assert!(
        !text.contains(hook_token.trim()),
        "the daemon's token is in a pane's environment"
    );
    let token = text.lines().last().unwrap().trim().to_owned();
    assert_eq!(token.len(), 64, "{run}");
    let pane = run["pane"].as_str().unwrap().trim_start_matches('p');
    let worker = Caller {
        token: token.clone(),
        ..agent.clone_as(pane.to_owned())
    };

    // Its token does not speak for the pane that opened it on the other channels either.
    let pull = raw(
        &agent.socket,
        json!({ "v": 1, "token": token, "pane": agent_pane.0.to_string(), "pull": { "op": "list" } }),
    )
    .await;
    assert!(pull.contains("bad token"), "{pull}");
    let browser = raw(
        &agent.socket,
        json!({ "v": 1, "token": token, "pane": agent_pane.0.to_string(),
                "browser": { "open": { "url": "https://example.com" } } }),
    )
    .await;
    assert!(browser.contains("bad token"), "{browser}");

    // The agent's tree, worker included, opens at most 32 panes.
    let mut opened = 1;
    loop {
        match worker.call("tab_new", json!({})).await {
            TermReply::Ok(_) => opened += 1,
            TermReply::Error(error) => {
                assert_eq!(error.code, TermErrorCode::Forbidden, "{error:?}");
                break;
            }
        }
        assert!(opened <= 32, "no limit on panes");
    }
    assert_eq!(opened, 32);
    assert_eq!(
        agent.refused("cmd_run", json!({ "command": "true" })).await,
        TermErrorCode::Forbidden,
        "the agent that started the worker shares its limit"
    );
}

async fn raw(socket: &Path, call: Value) -> String {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(&call).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
    answer
}

/// Text in a pane a multiplayer guest can type into may be the guest's, not the user's: every
/// read says so, so the agent does not take it as the user's words.
#[tokio::test(flavor = "multi_thread")]
async fn reads_of_a_pane_a_guest_can_type_into_say_so() {
    use client_core::grants::GrantSpec;
    use client_core::proto::{Roles, Scope, UnixMillis};

    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |_| {}).await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = user.attach_and_follow().await;
    let agent = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        pane: agent_pane.0.to_string(),
    };
    let source = |value: &Value| {
        value["output"]["source"]
            .as_str()
            .unwrap_or_default()
            .to_owned()
    };
    let plain = source(&agent.ok("pane_read", json!({})).await);
    assert!(!plain.contains("guest"), "{plain}");

    let join = |roles, name: &'static str| {
        let mut spec = GrantSpec::new(roles, Scope::Daemon);
        spec.label = name.into();
        spec.expires = Some(UnixMillis(client_core::now_millis().0 + 3_600_000));
        let client = &user.client;
        async move {
            let invite = client.create_invite(spec, name.into()).await.unwrap();
            let mut guest = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
            guest.client.attach(None);
            guest
                .until("guest layout", |client| client.layout.is_some())
                .await;
            guest
        }
    };
    // A viewer cannot type: nothing changes.
    let _carol = join(Roles::VIEWER, "carol").await;
    assert_eq!(source(&agent.ok("pane_read", json!({})).await), plain);

    // A driver can: reads and waits are marked.
    let _bob = join(Roles::DRIVER, "bob").await;
    let read = agent.ok("pane_read", json!({})).await;
    assert_eq!(source(&read), daemon::TERM_SOURCE_SHARED, "{read}");
    let waited = agent
        .ok("pane_wait", json!({ "quietMs": 100, "timeoutMs": 2000 }))
        .await;
    assert_eq!(source(&waited), daemon::TERM_SOURCE_SHARED, "{waited}");
}

/// Splitting the agent's pane for every new pane would nest one level deeper each time and hit
/// the layout's 16-level limit ("too many nested splits") long before the 32-pane budget, so
/// once that deep, panes open in a background tab instead.
#[tokio::test(flavor = "multi_thread")]
async fn panes_past_the_nesting_limit_open_in_a_tab() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |_| {}).await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = user.attach_and_follow().await;
    let agent = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        pane: agent_pane.0.to_string(),
    };
    for _ in 0..20 {
        agent.ok("pane_split", json!({})).await;
    }
    user.until("a second tab", |client| {
        client
            .layout
            .as_ref()
            .is_some_and(|layout| layout.tabs.len() > 1)
    })
    .await;
    assert_eq!(user.focused(), agent_pane, "the user's tab stays in front");
}

/// Parallel calls must not all pass the open-pane count before any pane exists, or an agent
/// asking for many panes at once would end up with more than its 32.
#[tokio::test(flavor = "multi_thread")]
async fn parallel_opens_stay_within_the_pane_budget() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |_| {}).await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = user.attach_and_follow().await;
    let token = std::fs::read_to_string(dir.path().join("hook.token")).unwrap();
    let socket = daemon.hook_socket().to_owned();
    let TermReply::Ok(first) = call(
        &socket,
        &token,
        &agent_pane.0.to_string(),
        "tab_new",
        json!({}),
    )
    .await
    else {
        panic!("no first tab")
    };
    let worker = first["pane"]["id"]
        .as_str()
        .unwrap()
        .trim_start_matches('p')
        .to_owned();
    // The agent and its worker both ask, more at once than one pane may call.
    let calls: Vec<_> = [agent_pane.0.to_string(), worker]
        .into_iter()
        .flat_map(|pane| std::iter::repeat_n(pane, 32))
        .map(|pane| {
            let (socket, token) = (socket.clone(), token.clone());
            tokio::spawn(async move { call(&socket, &token, &pane, "tab_new", json!({})).await })
        })
        .collect();
    let mut opened = 1;
    for pending in calls {
        if matches!(pending.await.unwrap(), TermReply::Ok(_)) {
            opened += 1;
        }
    }
    assert_eq!(opened, 32);
}
