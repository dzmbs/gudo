use super::*;
use client_core::{WorkspaceEvent, WorkspaceEventQueue};
use proto::{AgentKind, PaneLaunch};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(serde::Deserialize)]
struct Fixture {
    root: PathBuf,
    helper: PathBuf,
    codex: PathBuf,
    model_url: String,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "requires an explicit private loopback fixture and matching Debug helper"]
async fn real_cli_streams_through_the_owned_daemon_adapter() {
    let path = std::env::var_os("GUDO_CODEX_NATIVE_FIXTURE")
        .filter(|_| brand::IS_DEV)
        .expect("this probe requires a Dev build and an explicit private fixture");
    let fixture: Fixture = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert!(
        fixture
            .root
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("gudo-codex-daemon-owned-")
    );
    assert!(fixture.model_url.starts_with("http://127.0.0.1:"));
    let daemon = crate::Daemon::start(configuration(&fixture)).await.unwrap();
    let result = run(&daemon, &fixture.root, &fixture.model_url).await;
    daemon.shutdown().await;
    let conversation = result.unwrap();
    let daemon = crate::Daemon::start(configuration(&fixture)).await.unwrap();
    let result = recover(&daemon, &fixture.root, &conversation).await;
    daemon.shutdown().await;
    result.unwrap();
}

fn configuration(fixture: &Fixture) -> crate::Config {
    let mut config = crate::Config::new(fixture.root.join("daemon"));
    config.codex_chat = true;
    config.relay = crate::RelayMode::Disabled;
    config.bind = Some("127.0.0.1:0".parse().unwrap());
    config.shell = Some("/bin/sh".into());
    config.hook_bin = Some(fixture.helper.clone());
    config.cli_exe = Some(fixture.helper.clone());
    config.pane_env = vec![
        (
            "HOME".into(),
            fixture.root.join("home").display().to_string(),
        ),
        (
            "PATH".into(),
            format!(
                "{}:/usr/bin:/bin:/usr/sbin:/sbin",
                fixture.codex.parent().unwrap().display()
            ),
        ),
        ("ENV".into(), String::new()),
        ("NO_PROXY".into(), "127.0.0.1,localhost".into()),
        ("HTTP_PROXY".into(), String::new()),
        ("HTTPS_PROXY".into(), String::new()),
        ("ALL_PROXY".into(), String::new()),
    ];
    config.pane_env.extend(
        agents::CREDENTIAL_VARS
            .iter()
            .map(|name| ((*name).into(), String::new())),
    );
    config
}

struct Conversation {
    pane: PaneId,
    thread: String,
    account: String,
}

async fn run(daemon: &crate::Daemon, root: &Path, model_url: &str) -> Result<Conversation, String> {
    let account = daemon.core.ws.accounts.add(&proto::AccountAdd {
        agent: AgentKind::Codex,
        label: "Private loopback fixture".into(),
        color: 0,
    })?;
    let directory = daemon.core.ws.accounts.dir(AgentKind::Codex, &account.id);
    for name in ["config.toml", "auth.json"] {
        std::fs::copy(root.join("codex").join(name), directory.join(name))
            .map_err(|error| error.to_string())?;
    }
    let (_, _, pane) = daemon
        .core
        .create_session(
            "Codex private stream".into(),
            PaneLaunch::AccountAgent {
                agent: AgentKind::Codex,
                account: Some(account.id.clone()),
                resume: None,
                cwd: Some(root.join("project").display().to_string()),
            },
        )
        .map_err(|error| format!("launch: {error:?}"))?;
    let entry = daemon.core.pane(pane).ok_or("missing pane")?;
    let source = lock(&entry.codex)
        .clone()
        .ok_or("missing native producer")?;
    let ready = tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            if source.fault.load(std::sync::atomic::Ordering::Acquire) {
                return Err("native observation closed before input".to_string());
            }
            if lock(&source.state).current.is_some()
                && entry.pane.line_snapshot().bracketed
                && entry.pane.screen_text().contains('›')
            {
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .map_err(|_| "TUI startup timeout".to_string())
    .and_then(|result| result);
    std::fs::write(root.join("startup-screen.txt"), entry.pane.screen_text())
        .map_err(|error| error.to_string())?;
    ready?;
    let thread = lock(&source.state)
        .current
        .as_ref()
        .unwrap()
        .thread_id()
        .to_owned();
    crate::agent_input::chat_tests::wait_until(|| {
        lock(&entry.record)
            .agent
            .as_ref()
            .unwrap()
            .session_id
            .as_deref()
            == Some(thread.as_str())
    })
    .await;
    let recovered = daemon
        .core
        .ws
        .accounts
        .resolve(AgentKind::Codex, None, Some(&thread), None)
        .map_err(|error| error.to_string())?;
    if recovered.id != account.id {
        return Err("bound thread did not retain its named account".into());
    }
    if lock(&entry.agent).as_ref().unwrap().session().lane != agents::Lane::AppServer {
        return Err("runtime has no structured event authority".into());
    }
    let (client, _connection_events) = crate::agent_input::chat_tests::owner_client(daemon).await;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    client.set_workspace_listener(listener);
    let snapshot = client
        .timeline_watch_capabilities(pane)
        .await
        .map_err(|error| format!("watch: {error:?}"))?;
    if snapshot.capabilities != AgentCapabilities::READ | AgentCapabilities::STREAMING_DELTAS {
        return Err("wrong live capabilities".into());
    }
    if client.chat_prepare(pane).await.is_ok() {
        return Err("read-only source issued a Send ticket".into());
    }
    // Explicit user input through the actual Terminal PTY, never a native/bootstrap request.
    entry
        .pane
        .write(b"\x1b[200~Reply with a short fixture sentence.\x1b[201~\r".to_vec())
        .await
        .map_err(|error| error.to_string())?;
    let result = tokio::time::timeout(Duration::from_secs(30), async {
        let mut delta = false;
        loop {
            let WorkspaceEvent::Timeline { update } = events.recv().await.ok_or("event stream closed")? else { continue; };
            for operation in update.operations {
                match operation {
                    TimelineOp::Append { text, .. } if text.contains("same-process") && !delta => {
                        if lock(&entry.agent).as_ref().unwrap().state() != agents::AgentState::Working { return Err("streaming turn is not working".to_owned()); }
                        delta = true;
                        advance_model(model_url).await?;
                    }
                    TimelineOp::Upsert { item, .. } if matches!(&item.body, proto::TimelineBody::Assistant { text, streaming: false } if text == "A same-process live mirror.\n") => {
                        if !delta { return Err("no live append before final item".to_string()); }
                        return Ok(());
                    }
                    TimelineOp::Unavailable { .. } => return Err("native timeline became unavailable".to_string()),
                    _ => {}
                }
            }
        }
    }).await.map_err(|_| "stream timeout".to_string()).and_then(|result| result);
    std::fs::write(root.join("final-screen.txt"), entry.pane.screen_text())
        .map_err(|error| error.to_string())?;
    result?;
    crate::agent_input::chat_tests::wait_until(|| lock(&entry.meta).turns == 1).await;
    if lock(&entry.agent).as_ref().unwrap().state() != agents::AgentState::Idle
        || lock(&entry.meta).last_turn.as_ref().unwrap().outcome != agents::TurnOutcome::Completed
    {
        return Err("app-server completion did not complete the runtime turn".into());
    }
    client
        .timeline_unwatch(pane)
        .await
        .map_err(|error| format!("unwatch: {error:?}"))?;
    if source.fault.load(std::sync::atomic::Ordering::Acquire) || lock(&source.process).is_none() {
        return Err("unwatch ended the launch".into());
    }
    let snapshot = client
        .timeline_watch_capabilities(pane)
        .await
        .map_err(|error| format!("rewatch: {error:?}"))?;
    if !snapshot.snapshot.items.iter().any(|item| matches!(&item.body, proto::TimelineBody::Assistant { text, .. } if text == "A same-process live mirror.\n")) { return Err("late watch lost captured text".into()); }
    crate::agent_input::chat_tests::wait_until(|| {
        rollout_contains(
            &directory.join("sessions"),
            "A same-process live mirror.",
            0,
        )
    })
    .await;
    Ok(Conversation {
        pane,
        thread,
        account: account.id,
    })
}

async fn recover(
    daemon: &crate::Daemon,
    root: &Path,
    conversation: &Conversation,
) -> Result<(), String> {
    let (entry, source) = tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            if let Some(entry) = daemon.core.pane(conversation.pane) {
                let source = lock(&entry.codex).clone();
                if let Some(source) = source {
                    if source.fault.load(std::sync::atomic::Ordering::Acquire) {
                        let _ = std::fs::write(
                            root.join("recovered-screen.txt"),
                            entry.pane.screen_text(),
                        );
                        return Err("recovered native source failed".to_owned());
                    }
                    if lock(&source.state).is_ready() {
                        return Ok((entry, source));
                    }
                }
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .map_err(|_| "native recovery timeout".to_owned())??;
    std::fs::write(root.join("recovered-screen.txt"), entry.pane.screen_text())
        .map_err(|error| error.to_string())?;
    crate::agent_input::chat_tests::wait_until(|| {
        lock(&entry.agent)
            .as_ref()
            .unwrap()
            .session()
            .native_id
            .as_ref()
            .is_some_and(|id| id.as_str() == conversation.thread)
    })
    .await;
    if !lock(&source.state).requires_history {
        return Err("recovery did not observe an official resume".into());
    }
    if daemon
        .core
        .pane_account(conversation.pane)
        .as_ref()
        .map(|(_, account)| account.as_str())
        != Some(conversation.account.as_str())
    {
        return Err("recovery lost the named account".into());
    }
    let (client, _events) = crate::agent_input::chat_tests::owner_client(daemon).await;
    let snapshot = client
        .timeline_watch_capabilities(conversation.pane)
        .await
        .map_err(|error| format!("recovered watch: {error:?}"))?;
    if !snapshot.snapshot.items.iter().any(|item| matches!(&item.body, proto::TimelineBody::Assistant { text, streaming: false } if text == "A same-process live mirror.\n")) { return Err(format!("official resume did not hydrate history: {:?}", snapshot.snapshot.items)); }
    if lock(&entry.meta).turns != 0 {
        return Err("recovery recounted historical completion".into());
    }
    Ok(())
}

fn rollout_contains(directory: &Path, text: &str, depth: usize) -> bool {
    if depth > 4 {
        return false;
    }
    let Ok(entries) = std::fs::read_dir(directory) else {
        return false;
    };
    entries.filter_map(Result::ok).take(64).any(|entry| {
        let Ok(kind) = entry.file_type() else {
            return false;
        };
        if kind.is_dir() {
            rollout_contains(&entry.path(), text, depth + 1)
        } else if kind.is_file() {
            std::fs::read_to_string(entry.path()).is_ok_and(|body| body.contains(text))
        } else {
            false
        }
    })
}

async fn advance_model(model_url: &str) -> Result<(), String> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let address: std::net::SocketAddr = model_url
        .strip_prefix("http://")
        .ok_or("not a loopback model")?
        .parse()
        .map_err(|error: std::net::AddrParseError| error.to_string())?;
    if !address.ip().is_loopback() {
        return Err("not a loopback model".into());
    }
    tokio::time::timeout(Duration::from_secs(5), async {
        let mut connection = tokio::net::TcpStream::connect(address)
            .await
            .map_err(|error| error.to_string())?;
        connection
            .write_all(b"GET /continue HTTP/1.0\r\nHost: localhost\r\n\r\n")
            .await
            .map_err(|error| error.to_string())?;
        let mut response = Vec::new();
        connection
            .take(4096)
            .read_to_end(&mut response)
            .await
            .map_err(|error| error.to_string())?;
        if !response.starts_with(b"HTTP/1.0 200") {
            return Err("model did not acknowledge the delta".into());
        }
        Ok(())
    })
    .await
    .map_err(|_| "model acknowledgement timeout".to_owned())?
}
