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
    move |c: &mut daemon::Config| c.pane_env.extend(env)
}

/// The session id the daemon pinned for `pane`'s Claude, read from its launch line.
async fn pinned_session(c: &mut TestClient, pane: PaneId) -> String {
    c.wait_flat(pane, "--session-id ").await;
    let text = c.flat_text(pane);
    let after = text.split("--session-id ").nth(1).unwrap();
    after.split_whitespace().next().unwrap().to_owned()
}

async fn new_tab(c: &mut TestClient, launch: PaneLaunch) -> PaneId {
    let session_id = c.layout.as_ref().unwrap().session_id;
    match c
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
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let shell = c.attach_and_follow().await;
    let session = c.layout.as_ref().unwrap().session_id;
    let cwd = work.path().canonicalize().unwrap().display().to_string();
    let leaf = work
        .path()
        .file_name()
        .unwrap()
        .to_str()
        .unwrap()
        .to_owned();
    let first = new_tab(&mut c, PaneLaunch::Shell { cwd: Some(cwd) }).await;
    assert_eq!(
        c.op(LayoutOp::ClosePane { pane_id: shell }).await,
        OpOutcome::Done
    );

    assert_eq!(
        c.op(LayoutOp::ClosePane { pane_id: first }).await,
        OpOutcome::Done
    );
    c.until("empty layout", |c| {
        c.layout
            .as_ref()
            .is_some_and(|l| l.session_id == session && l.tabs.is_empty())
    })
    .await;

    let back = new_tab(&mut c, reopen(first)).await;
    assert_eq!(c.layout.as_ref().unwrap().session_id, session);
    c.follow(back).await;
    c.type_line(back, "pwd");
    c.wait_flat(back, &leaf).await;
    drop(c);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reopened_agent_resumes_its_session_also_after_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let tools = tempfile::tempdir().unwrap();
    let env = fake_claude(tools.path());
    let daemon = start_with(dir.path(), configure(env.clone())).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;
    let claude = PaneLaunch::Agent {
        agent: AgentKind::Claude,
        resume: None,
        cwd: None,
    };

    // Closed and reopened while the daemon runs.
    let agent = new_tab(&mut c, claude.clone()).await;
    c.follow(agent).await;
    let id = pinned_session(&mut c, agent).await;
    assert_eq!(
        c.op(LayoutOp::ClosePane { pane_id: agent }).await,
        OpOutcome::Done
    );
    let back = new_tab(&mut c, reopen(agent)).await;
    c.follow(back).await;
    c.wait_flat(back, &format!("--resume {id}")).await;

    // Reopening uses the record up: a second reopen of the same pane is a plain shell.
    let again = new_tab(&mut c, reopen(agent)).await;
    c.follow(again).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        !c.flat_text(again).contains("fake claude"),
        "{}",
        c.flat_text(again)
    );

    // Closed, then the daemon restarts: the record is kept with the layout.
    let other = new_tab(&mut c, claude).await;
    c.follow(other).await;
    let other_id = pinned_session(&mut c, other).await;
    assert_eq!(
        c.op(LayoutOp::ClosePane { pane_id: other }).await,
        OpOutcome::Done
    );
    let layout = dir.path().join("layout.json");
    let deadline = Instant::now() + TIMEOUT;
    while !std::fs::read_to_string(&layout)
        .is_ok_and(|s| s.contains("\"closed\"") && s.contains(&other_id))
    {
        assert!(Instant::now() < deadline, "closed pane never persisted");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    drop(c);
    daemon.shutdown().await;

    let daemon = start_with(dir.path(), configure(env)).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.client.attach(None);
    c.until("layout", |c| c.layout.is_some()).await;
    assert!(!leaves(&c.tab().root).contains(&other));
    let back = new_tab(&mut c, reopen(other)).await;
    c.follow(back).await;
    c.wait_flat(back, &format!("--resume {other_id}")).await;
    drop(c);
    daemon.shutdown().await;
}
