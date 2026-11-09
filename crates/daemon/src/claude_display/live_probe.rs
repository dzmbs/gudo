use std::path::PathBuf;
use std::time::{Duration, Instant};

use client_core::{WorkspaceEvent, WorkspaceEventQueue};
use proto::{AgentKind, PaneLaunch, TimelineBody, TimelineOp};

use crate::core::lock;

mod metrics;

#[derive(serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
enum Scenario {
    Stream,
    Blocks,
    Fallback,
    OptOut,
    CaptureFailure,
    SettingsFailure,
    ListenerFailure,
}

#[derive(serde::Deserialize)]
struct Fixture {
    root: PathBuf,
    helper: PathBuf,
    model_url: String,
    scenario: Scenario,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "requires a private loopback model, installed Claude CLI and matching Debug helper"]
async fn real_claude_streams_through_the_daemon() {
    let path = std::env::var_os("GUDO_CLAUDE_NATIVE_FIXTURE")
        .filter(|_| brand::IS_DEV)
        .expect("explicit Dev fixture required");
    let fixture: Fixture = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert!(
        fixture
            .root
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("gudo-claude-daemon-owned-")
    );
    assert!(fixture.model_url.starts_with("http://127.0.0.1:"));
    let mut config = crate::Config::new(fixture.root.join("daemon"));
    assert!(config.claude_chat_streaming);
    if matches!(fixture.scenario, Scenario::OptOut) {
        config.claude_chat_streaming = false;
    }
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
                fixture.root.join("bin").display()
            ),
        ),
        ("ENV".into(), String::new()),
        (
            "CLAUDE_CONFIG_DIR".into(),
            fixture.root.join("config").display().to_string(),
        ),
        ("ANTHROPIC_BASE_URL".into(), fixture.model_url.clone()),
        (
            "ANTHROPIC_API_KEY".into(),
            "fixture-placeholder-not-a-credential".into(),
        ),
        (
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".into(),
            "1".into(),
        ),
        ("DISABLE_TELEMETRY".into(), "1".into()),
        ("DISABLE_ERROR_REPORTING".into(), "1".into()),
        ("DISABLE_AUTOUPDATER".into(), "1".into()),
        ("NO_PROXY".into(), "127.0.0.1,localhost".into()),
        ("HTTP_PROXY".into(), fixture.model_url.clone()),
        ("HTTPS_PROXY".into(), fixture.model_url.clone()),
        ("ALL_PROXY".into(), fixture.model_url.clone()),
    ];
    let occupied = if matches!(fixture.scenario, Scenario::ListenerFailure) {
        let listener = std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).unwrap();
        std::fs::create_dir_all(&config.state_dir).unwrap();
        std::fs::write(
            config.state_dir.join("claude-display.port"),
            listener.local_addr().unwrap().port().to_string(),
        )
        .unwrap();
        Some(listener)
    } else {
        None
    };
    let daemon = crate::Daemon::start(config).await.unwrap();
    let result = run(&daemon, &fixture).await;
    if result.is_err() {
        for (_, entry) in daemon.core.pane_entries() {
            std::fs::write(
                fixture.root.join("failure-screen.txt"),
                entry.pane.screen_text(),
            )
            .unwrap();
        }
    }
    daemon.shutdown().await;
    drop(occupied);
    result.unwrap();
}

async fn wait(mut condition: impl FnMut() -> bool) -> Result<(), String> {
    tokio::time::timeout(Duration::from_secs(30), async {
        while !condition() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .map_err(|_| "fixture condition timed out".to_owned())
}

async fn press(entry: &crate::core::PaneEntry, key: ghostty_vt::Key) -> Result<(), String> {
    let bytes = entry
        .pane
        .encode_input(proto::InputPayload::Key(proto::KeyEvent {
            key: key.0,
            mods: 0,
            action: proto::KeyAction::Press,
            text: None,
        }));
    eprintln!("fixture key {key:?}: {bytes:?}");
    entry
        .pane
        .write(bytes)
        .await
        .map(|_| ())
        .map_err(|error| error.to_string())
}

async fn run(daemon: &crate::Daemon, fixture: &Fixture) -> Result<(), String> {
    if matches!(fixture.scenario, Scenario::SettingsFailure) {
        std::fs::create_dir_all(
            fixture
                .root
                .join("daemon/claude/settings.v3.display.v1.json"),
        )
        .map_err(|error| error.to_string())?;
    }
    let (_, _, pane) = daemon
        .core
        .create_session(
            "Claude private stream".into(),
            PaneLaunch::Agent {
                agent: AgentKind::Claude,
                resume: None,
                cwd: Some(fixture.root.join("project").display().to_string()),
            },
        )
        .map_err(|error| format!("launch: {error:?}"))?;
    let entry = daemon.core.pane(pane).ok_or("missing pane")?;
    let mut accepted = false;
    let mut selected_manual = false;
    let mut manual_visible_since = None;
    let mut declined_auto = false;
    let startup = tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let screen = entry.pane.screen_text();
            if !accepted && screen.contains("ANTHROPIC_API_KEY") {
                press(&entry, ghostty_vt::Key::ARROW_UP).await?;
                press(&entry, ghostty_vt::Key::ENTER).await?;
                accepted = true;
            }
            if !selected_manual && screen.contains("Make auto mode your default permission mode?") {
                press(&entry, ghostty_vt::Key::ARROW_DOWN).await?;
                selected_manual = true;
                manual_visible_since = Some(Instant::now());
            }
            // Confirmation keys inside the official dialog's input boundary are ignored.
            if selected_manual
                && manual_visible_since
                    .is_some_and(|visible: Instant| visible.elapsed() >= Duration::from_secs(2))
                && !declined_auto
                && screen
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .contains("❯ No, keep manual mode")
            {
                press(&entry, ghostty_vt::Key::ENTER).await?;
                declined_auto = true;
            }
            if accepted
                && declined_auto
                && !screen.contains("Make auto mode")
                && screen.contains("/effort")
            {
                return Ok::<_, String>(());
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .map_err(|_| "Claude startup timeout".to_owned())
    .and_then(|result| result);
    std::fs::write(
        fixture.root.join("startup-screen.txt"),
        entry.pane.screen_text(),
    )
    .map_err(|error| error.to_string())?;
    startup?;
    let session = lock(&entry.record)
        .agent
        .as_ref()
        .unwrap()
        .session_id
        .clone()
        .unwrap();
    let (client, _connection_events) = crate::agent_input::chat_tests::owner_client(daemon).await;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    client.set_workspace_listener(listener);
    client
        .timeline_watch_capabilities(pane)
        .await
        .map_err(|error| format!("watch: {error:?}"))?;
    let started = Instant::now();
    entry
        .pane
        .write(entry.pane.encode_input(proto::InputPayload::Paste(
            "fixture-display-only: reply with two short lines.".into(),
        )))
        .await
        .map_err(|error| error.to_string())?;
    wait(|| entry.pane.screen_text().contains("fixture-display-only:")).await?;
    press(&entry, ghostty_vt::Key::ENTER).await?;
    let live = !matches!(
        fixture.scenario,
        Scenario::Fallback
            | Scenario::OptOut
            | Scenario::SettingsFailure
            | Scenario::ListenerFailure
    );
    if live {
        tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let Some(WorkspaceEvent::Timeline { update }) = events.recv().await else { continue; };
                for operation in update.operations {
                    let items = match operation {
                        TimelineOp::Upsert { item, .. } => vec![*item],
                        TimelineOp::Snapshot(snapshot) => snapshot.items,
                        TimelineOp::Unavailable { message } => return Err(format!("timeline unavailable: {message}")),
                        _ => Vec::new(),
                    };
                    if items.iter().any(|item| item.id.starts_with("claude-display:") && matches!(&item.body, TimelineBody::Assistant { text, streaming: true } if text == "First daemon fixture line.\n")) {
                        if fixture.root.join("stream-finished").exists() { return Err("live row arrived after stream completion".to_owned()); }
                        std::fs::write(fixture.root.join("early-live.json"), format!("{{\"before_model_finished\":true,\"milliseconds\":{}}}", started.elapsed().as_secs_f64() * 1000.0)).map_err(|error| error.to_string())?;
                        return Ok(());
                    }
                }
            }
        }).await.map_err(|_| "no live row before model release".to_owned())??;
        if !daemon.core.has_live_agent_chat() {
            return Err("missing active-source upgrade guard".into());
        }
    } else {
        wait(|| fixture.root.join("stream-paused").exists()).await?;
        let snapshot = client
            .timeline_watch_capabilities(pane)
            .await
            .map_err(|error| format!("fallback watch: {error:?}"))?;
        if snapshot
            .snapshot
            .items
            .iter()
            .any(|item| matches!(item.body, TimelineBody::Assistant { .. }))
        {
            return Err("fallback exposed provisional text".into());
        }
        let arguments: Vec<String> = serde_json::from_slice(
            &std::fs::read(fixture.root.join("launch-arguments.json"))
                .map_err(|error| error.to_string())?,
        )
        .map_err(|error| error.to_string())?;
        if arguments
            .last()
            .is_none_or(|path| !path.ends_with("settings.v3.json"))
        {
            return Err("fallback did not select legacy settings".into());
        }
    }
    metrics::record(daemon, fixture).await?;
    if matches!(fixture.scenario, Scenario::CaptureFailure) {
        let sequence = {
            let input = lock(&entry.pane.agent_input_gate);
            daemon
                .core
                .hooks
                .display
                .snapshot(
                    pane,
                    &entry,
                    input.active_launch().ok_or("closed launch")?,
                    &session,
                )
                .ok_or("missing capture scope")?
                .sequence
        };
        daemon.core.hooks.display.disable(pane, sequence);
    }
    std::fs::write(fixture.root.join("release-model"), b"continue")
        .map_err(|error| error.to_string())?;
    wait(|| fixture.root.join("stream-finished").exists()).await?;
    let expected = "First daemon fixture line.\nSecond daemon fixture line without newline.";
    let result = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let snapshot = client
                .timeline_watch_capabilities(pane)
                .await
                .map_err(|error| format!("final watch: {error:?}"))?;
            let mut text = String::new();
            let mut provisional = false;
            for item in &snapshot.snapshot.items {
                if let TimelineBody::Assistant { text: body, .. } = &item.body {
                    text.push_str(body);
                    provisional |= item.id.starts_with("claude-display:");
                }
            }
            if text == expected && !provisional {
                return Ok::<_, String>(snapshot);
            }
            tokio::time::sleep(Duration::from_millis(35)).await;
        }
    })
    .await
    .map_err(|_| "canonical reconciliation timeout".to_owned())??;
    std::fs::write(
        fixture.root.join("final-snapshot.json"),
        serde_json::to_vec_pretty(&result.snapshot).unwrap(),
    )
    .map_err(|error| error.to_string())?;
    wait(|| {
        entry
            .pane
            .screen_text()
            .contains("Second daemon fixture line without newline.")
    })
    .await?;
    std::fs::write(
        fixture.root.join("final-screen.txt"),
        entry.pane.screen_text(),
    )
    .map_err(|error| error.to_string())?;
    let transcript = crate::claude_session::project_dir(
        &fixture.root.join("config"),
        &fixture.root.join("project"),
    )
    .join(format!("{session}.jsonl"));
    let bytes = std::fs::read(&transcript).map_err(|error| error.to_string())?;
    if String::from_utf8_lossy(&bytes).contains("claude-display:") {
        return Err("provisional content reached the transcript".into());
    }
    client
        .timeline_unwatch(pane)
        .await
        .map_err(|error| format!("unwatch: {error:?}"))?;
    let reopened = client
        .timeline_watch_capabilities(pane)
        .await
        .map_err(|error| format!("rewatch: {error:?}"))?;
    let text = reopened
        .snapshot
        .items
        .iter()
        .filter_map(|item| match &item.body {
            TimelineBody::Assistant { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect::<String>();
    if text != expected {
        return Err("rewatch duplicated or lost canonical text".into());
    }
    Ok(())
}
