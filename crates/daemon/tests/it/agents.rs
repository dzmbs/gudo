//! Agent hooks reach clients, and a client's decision reaches the waiting hook.

use std::time::Duration;

use client_core::ClientConfig;
use client_core::proto::{AgentState, OptionId};
use daemon::{HookRequest, HookResponse};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use crate::support::{TestClient, start, ticket};

const PERMISSION: &str =
    include_str!("../../../agents/tests/fixtures/claude/permission_request.json");

async fn hook(socket: &std::path::Path, request: &HookRequest) -> HookResponse {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(request).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
    serde_json::from_str(&answer).unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn permission_request_is_answered_from_a_client() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;

    let token = std::fs::read_to_string(dir.path().join("hook.token")).unwrap();
    let request = HookRequest {
        v: 1,
        token,
        pane: pane.0.to_string(),
        agent: "claude".into(),
        event: "PermissionRequest".into(),
        seq: 1,
        payload: serde_json::from_str(PERMISSION).unwrap(),
    };
    let socket = daemon.hook_socket().to_owned();
    let waiting = tokio::spawn(async move { hook(&socket, &request).await });

    // The client sees the agent blocked, with the hook's options.
    owner
        .until("blocked agent", |owner| {
            owner
                .metas
                .get(&pane)
                .and_then(|meta| meta.agent.as_ref())
                .is_some_and(|agent| matches!(agent.state, AgentState::Blocked(_)))
        })
        .await;
    assert!(
        owner
            .agent_events
            .iter()
            .any(|event| event.contains("rm -rf node_modules"))
    );
    let AgentState::Blocked(blocker) = owner.metas[&pane].agent.clone().unwrap().state else {
        unreachable!()
    };
    assert_eq!(blocker.options[0].label, "Yes");

    owner.client.decide(blocker.request_id, OptionId(0));
    let response = tokio::time::timeout(Duration::from_secs(10), waiting)
        .await
        .expect("hook answered")
        .unwrap();
    let stdout: serde_json::Value = serde_json::from_str(&response.stdout.unwrap()).unwrap();
    assert_eq!(
        stdout["hookSpecificOutput"]["decision"]["behavior"], "allow",
        "{stdout}"
    );
    drop(owner);
    daemon.shutdown().await;
}

/// An agent run by hand is tracked while it runs and forgotten once it exits back to the shell,
/// with no SessionEnd hook.
#[tokio::test(flavor = "multi_thread")]
async fn an_agent_that_exits_leaves_a_shell() {
    let dir = tempfile::tempdir().unwrap();
    let fake = dir.path().join("claude");
    std::os::unix::fs::symlink("/bin/sleep", &fake).unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;

    owner.type_line(pane, &format!("{} 60", fake.display()));
    owner
        .until("agent tracked", |owner| {
            owner
                .metas
                .get(&pane)
                .is_some_and(|meta| meta.agent.is_some())
        })
        .await;
    owner.client.send_input(pane, b"\x03".to_vec());
    owner
        .until("agent gone", |owner| {
            owner
                .metas
                .get(&pane)
                .is_some_and(|meta| meta.agent.is_none())
        })
        .await;
    drop(owner);
    daemon.shutdown().await;
}
