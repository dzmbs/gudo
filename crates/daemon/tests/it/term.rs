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
