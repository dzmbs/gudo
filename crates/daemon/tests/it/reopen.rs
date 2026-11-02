//! Recently closed tabs: closing a session's last tab keeps the session (empty), and
//! `PaneLaunch::Reopen` brings a closed pane back in its directory, resuming its agent's
//! session, also after a daemon restart. Claude is faked by a script that prints its arguments.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::{AgentKind, LayoutOp, OpOutcome, PaneId, PaneLaunch};

use crate::support::{TIMEOUT, TestClient, leaves, start_with, ticket};

const FAKE_CLAUDE: &str = "#!/bin/sh\necho \"fake claude $*\"\nexec sleep 600\n";

/// A `PATH` with the fake `claude` first.
fn fake_claude(tools: &Path) -> Vec<(String, String)> {
    let bin = tools.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let claude = bin.join("claude");
    std::fs::write(&claude, FAKE_CLAUDE).unwrap();
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    vec![("PATH".to_owned(), path)]
}

fn configure(env: Vec<(String, String)>) -> impl FnOnce(&mut daemon::Config) {
    move |config: &mut daemon::Config| config.pane_env.extend(env)
}

/// The session id the daemon pinned for `pane`'s Claude, read from its launch line.
async fn pinned_session(client: &mut TestClient, pane: PaneId) -> String {
    client.wait_flat(pane, "--session-id ").await;
    let text = client.flat_text(pane);
    let after = text.split("--session-id ").nth(1).unwrap();
    after.split_whitespace().next().unwrap().to_owned()
}

async fn new_tab(client: &mut TestClient, launch: PaneLaunch) -> PaneId {
    let session_id = client.layout.as_ref().unwrap().session_id;
    match client
        .op(LayoutOp::NewTab {
            session_id,
            name: String::new(),
            launch,
        })
        .await
    {
        OpOutcome::TabCreated { pane_id, .. } => pane_id,
        other => panic!("new tab: {other:?}"),
    }
}

fn reopen(pane_id: PaneId) -> PaneLaunch {
    PaneLaunch::Reopen { pane_id, cwd: None }
}

#[tokio::test(flavor = "multi_thread")]
async fn closing_the_last_tab_keeps_the_session_and_reopen_brings_it_back() {
    let dir = tempfile::tempdir().unwrap();
    let work = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |_| {}).await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let shell = client.attach_and_follow().await;
    let session = client.layout.as_ref().unwrap().session_id;
    let cwd = work.path().canonicalize().unwrap().display().to_string();
    let leaf = work
        .path()
        .file_name()
        .unwrap()
        .to_str()
        .unwrap()
        .to_owned();
    let first = new_tab(&mut client, PaneLaunch::Shell { cwd: Some(cwd) }).await;
    assert_eq!(
        client.op(LayoutOp::ClosePane { pane_id: shell }).await,
        OpOutcome::Done
    );

    assert_eq!(
        client.op(LayoutOp::ClosePane { pane_id: first }).await,
        OpOutcome::Done
    );
    client
        .until("empty layout", |client| {
            client
                .layout
                .as_ref()
                .is_some_and(|layout| layout.session_id == session && layout.tabs.is_empty())
        })
        .await;

    let back = new_tab(&mut client, reopen(first)).await;
    assert_eq!(client.layout.as_ref().unwrap().session_id, session);
    client.follow(back).await;
    client.type_line(back, "pwd");
    client.wait_flat(back, &leaf).await;
    drop(client);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reopened_agent_resumes_its_session_also_after_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let env = fake_claude(tools.path());
    let daemon = start_with(dir.path(), configure(env.clone())).await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    client.attach_and_follow().await;
    let claude = PaneLaunch::Agent {
        agent: AgentKind::Claude,
        resume: None,
        cwd: None,
    };

    // Closed and reopened while the daemon runs.
    let agent = new_tab(&mut client, claude.clone()).await;
    client.follow(agent).await;
    let id = pinned_session(&mut client, agent).await;
    assert_eq!(
        client.op(LayoutOp::ClosePane { pane_id: agent }).await,
        OpOutcome::Done
    );
    let back = new_tab(&mut client, reopen(agent)).await;
    client.follow(back).await;
    client.wait_flat(back, &format!("--resume {id}")).await;

    // Reopening uses the record up: a second reopen of the same pane is a plain shell.
    let again = new_tab(&mut client, reopen(agent)).await;
    client.follow(again).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        !client.flat_text(again).contains("fake claude"),
        "{}",
        client.flat_text(again)
    );

    // Closed, then the daemon restarts: the record is kept with the layout.
    let other = new_tab(&mut client, claude).await;
    client.follow(other).await;
    let other_id = pinned_session(&mut client, other).await;
    assert_eq!(
        client.op(LayoutOp::ClosePane { pane_id: other }).await,
        OpOutcome::Done
    );
    let layout = dir.path().join("layout.json");
    let deadline = Instant::now() + TIMEOUT;
    while !std::fs::read_to_string(&layout)
        .is_ok_and(|saved| saved.contains("\"closed\"") && saved.contains(&other_id))
    {
        assert!(Instant::now() < deadline, "closed pane never persisted");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    drop(client);
    daemon.shutdown().await;

    let daemon = start_with(dir.path(), configure(env)).await;
    let mut client = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    client.client.attach(None);
    client
        .until("layout", |client| client.layout.is_some())
        .await;
    assert!(!leaves(&client.tab().root).contains(&other));
    let back = new_tab(&mut client, reopen(other)).await;
    client.follow(back).await;
    client
        .wait_flat(back, &format!("--resume {other_id}"))
        .await;
    drop(client);
    daemon.shutdown().await;
}
