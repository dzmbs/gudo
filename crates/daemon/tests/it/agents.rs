//! Agent hooks reach clients, and a client's decision reaches the waiting hook.

use std::time::Duration;

use client_core::ClientConfig;
use client_core::proto::{AgentState, Axis, LayoutOp, OpOutcome, OptionId, PaneLaunch};
use daemon::{HookRequest, HookResponse};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use crate::support::{TestClient, start, start_with, ticket};

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

#[tokio::test(flavor = "multi_thread")]
async fn pane_helpers_receive_their_own_host_boundary() {
    let directory = tempfile::tempdir().unwrap();
    let daemon = start_with(directory.path(), |config| {
        config
            .pane_env
            .push((brand::DAEMON_PID_ENV.into(), "private-stale-host".into()));
    })
    .await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    owner.type_line(
        pane,
        &format!(
            "printf 'HOST_BOUNDARY=%s\\n' \"${}\"",
            brand::DAEMON_PID_ENV
        ),
    );
    owner
        .wait_text(pane, &format!("HOST_BOUNDARY={}", std::process::id()))
        .await;
    drop(owner);
    daemon.shutdown().await;
}

async fn tracked_agent_kind(owner: &mut TestClient, pane: client_core::proto::PaneId) -> String {
    owner
        .until("tracked agent", |owner| {
            owner
                .metas
                .get(&pane)
                .is_some_and(|meta| meta.agent.is_some())
        })
        .await;
    owner.metas[&pane].agent.as_ref().unwrap().kind.clone()
}

async fn start_parent_agent(
    owner: &mut TestClient,
    executable: &std::path::Path,
) -> client_core::proto::PaneId {
    let source = owner.attach_and_follow().await;
    // Launch through an operation: terminal subscription does not prove the shell accepts input.
    let OpOutcome::PaneCreated { pane_id: pane } = owner
        .op(LayoutOp::Split {
            pane_id: source,
            axis: Axis::Vertical,
            launch: PaneLaunch::Command {
                argv: vec![executable.to_string_lossy().into_owned(), "60".into()],
                cwd: None,
            },
        })
        .await
    else {
        panic!("parent agent pane was not created")
    };
    owner.follow(pane).await;
    pane
}

#[tokio::test(flavor = "multi_thread")]
async fn nested_agent_hooks_do_not_replace_the_foreground_agent() {
    let directory = tempfile::tempdir().unwrap();
    let executable = directory.path().join("codex");
    std::os::unix::fs::symlink("/bin/sleep", &executable).unwrap();
    let daemon = start(directory.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = start_parent_agent(&mut owner, &executable).await;
    let mut request = HookRequest {
        v: 1,
        token: std::fs::read_to_string(directory.path().join("hook.token")).unwrap(),
        pane: pane.0.to_string(),
        agent: "codex".into(),
        event: daemon::CODEX_NOTIFY_EVENT.into(),
        seq: 1,
        payload: serde_json::json!({ "type": "agent-turn-complete", "thread-id": "parent" }),
    };
    hook(daemon.hook_socket(), &request).await;
    assert_eq!(tracked_agent_kind(&mut owner, pane).await, "codex");
    request.agent = "claude".into();
    for (index, event) in ["SessionStart", "SessionEnd"].into_iter().enumerate() {
        request.event = event.into();
        request.seq = index as u64 + 2;
        request.payload = serde_json::json!({ "hook_event_name": event, "session_id": "nested", "source": "startup" });
        hook(daemon.hook_socket(), &request).await;
        let mut probe = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
        assert_eq!(probe.attach_and_follow().await, pane);
        assert_eq!(
            tracked_agent_kind(&mut probe, pane).await,
            "codex",
            "{event}"
        );
    }
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
