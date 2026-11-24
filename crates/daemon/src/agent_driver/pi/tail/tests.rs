use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use client_core::{Client, WorkspaceEvent, WorkspaceEventQueue};
use proto::{
    AgentCapabilities, AgentKind, ChatSendStatus, PaneLaunch, TimelineBody, TimelineOp,
    WorkspaceRequest, WsError,
};

use super::super::session::tests::{Fixture, SESSION};
use crate::agent_input::chat_tests::{owner_client, wait_until};
use crate::core::{PaneEntry, lock};
use crate::resumable::ResumableProgram;

/// Runs as `pi` and keeps what the pane types into it in `$PI_CAPTURE`.
const FAKE_PI: &str = r#"#!/bin/bash
stty raw -echo
printf '\033[?2004h'
exec -a pi /bin/cat > "$PI_CAPTURE"
"#;

struct PiPane {
    _root: tempfile::TempDir,
    daemon: crate::Daemon,
    client: Arc<Client>,
    entry: Arc<PaneEntry>,
    captured: std::path::PathBuf,
    _events: tokio::sync::mpsc::UnboundedReceiver<client_core::ClientEvent>,
}

/// A daemon whose pane launched pi in session `fixture`, with pi's agent folder `fixture`'s.
async fn pi_pane(fixture: &mut Fixture, launched: bool) -> PiPane {
    pi_pane_resuming(fixture, launched, Some(SESSION)).await
}

/// As `pi_pane`, with pi started in `resume`, or fresh with no session written yet.
async fn pi_pane_resuming(fixture: &mut Fixture, launched: bool, resume: Option<&str>) -> PiPane {
    let root = tempfile::tempdir().unwrap();
    let bin = root.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(bin.join("pi"), FAKE_PI).unwrap();
    std::fs::set_permissions(bin.join("pi"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let work = root.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let work = work.canonicalize().unwrap();
    move_into_folder_of(fixture, &work);
    if resume.is_none() {
        std::fs::remove_file(&fixture.path).unwrap();
    }
    let captured = root.path().join("received");
    let mut config = crate::Config::new(root.path());
    config.relay = crate::RelayMode::Disabled;
    config.bind = Some("127.0.0.1:0".parse().unwrap());
    config.shell = Some("/bin/sh".into());
    config.pane_env = vec![
        ("ENV".into(), String::new()),
        (
            "PATH".into(),
            format!(
                "{}:{}",
                bin.display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        ),
        (
            agents::PI_DIR_VAR.into(),
            fixture.agent_dir.path().display().to_string(),
        ),
        ("PI_CAPTURE".into(), captured.display().to_string()),
    ];
    let daemon = crate::Daemon::start(config).await.unwrap();
    let (_, _, pane) = daemon
        .core
        .create_session(
            "pi".into(),
            PaneLaunch::Agent {
                agent: AgentKind::Pi,
                resume: resume.map(str::to_owned),
                cwd: Some(work.display().to_string()),
            },
        )
        .unwrap();
    let entry = daemon.core.pane(pane).unwrap();
    wait_until(|| {
        entry.pane.line_snapshot().bracketed
            && entry
                .pane
                .pty()
                .foreground_process()
                .is_some_and(|process| ResumableProgram::of(&process) == Some(ResumableProgram::Pi))
    })
    .await;
    if launched {
        *lock(&entry.pane.agent_input_gate) = crate::agent_input::armed_for_tests("fixture");
    } else {
        *lock(&entry.pane.agent_input_gate) = crate::agent_input::AgentInputGate::default();
    }
    let (client, events) = owner_client(&daemon).await;
    PiPane {
        _root: root,
        daemon,
        client,
        entry,
        captured,
        _events: events,
    }
}

fn move_into_folder_of(fixture: &mut Fixture, cwd: &Path) {
    let env = |name: &str| {
        (name == agents::PI_DIR_VAR).then(|| fixture.agent_dir.path().display().to_string())
    };
    let folder = crate::resumable::pi_session_dir(&env, Path::new("/"), cwd).folder;
    std::fs::create_dir_all(&folder).unwrap();
    let moved = folder.join(fixture.path.file_name().unwrap());
    std::fs::rename(&fixture.path, &moved).unwrap();
    fixture.path = moved;
}

fn text(body: &TimelineBody) -> &str {
    match body {
        TimelineBody::User { text, .. } | TimelineBody::Assistant { text, .. } => text,
        body => panic!("expected text, got {body:?}"),
    }
}

async fn next_upserts(
    events: &mut tokio::sync::mpsc::UnboundedReceiver<WorkspaceEvent>,
    until: &str,
) -> Vec<String> {
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut seen = Vec::new();
        loop {
            if let WorkspaceEvent::Timeline { update } = events.recv().await.unwrap() {
                for operation in update.operations {
                    if let TimelineOp::Upsert { item, .. } = operation {
                        seen.push(text(&item.body).to_owned());
                    }
                }
                if seen.iter().any(|shown| shown == until) {
                    return seen;
                }
            }
        }
    })
    .await
    .expect("the timeline update")
}

#[tokio::test(flavor = "multi_thread")]
async fn a_launched_pi_shows_its_session_follows_it_and_takes_prompts() {
    let mut fixture = Fixture::new();
    for index in 0..70 {
        fixture.reply(&format!("reply {index}"));
    }
    let pi = pi_pane(&mut fixture, true).await;
    let pane = pi.entry.pane.id;
    let meta = pi.daemon.core.pane_meta(pane).unwrap();
    assert_eq!(meta.agent.unwrap().kind, "pi");
    let (listener, mut events) = WorkspaceEventQueue::channel();
    pi.client.set_workspace_listener(listener);

    let watched = pi.client.timeline_watch_capabilities(pane).await.unwrap();
    assert_eq!(watched.snapshot.session.agent, AgentKind::Pi);
    assert_eq!(watched.snapshot.session.native_session, SESSION);
    assert_eq!(
        watched.snapshot.session.model.as_deref(),
        Some("claude-opus-4-5")
    );
    assert!(
        watched
            .capabilities
            .contains(AgentCapabilities::READ | AgentCapabilities::SEND)
    );
    assert!(!watched.capabilities.contains(AgentCapabilities::STOP));
    let shown: Vec<_> = watched
        .snapshot
        .items
        .iter()
        .map(|item| text(&item.body))
        .collect();
    let expected: Vec<_> = (10..70).map(|index| format!("reply {index}")).collect();
    assert_eq!(shown, expected);
    let older = pi
        .client
        .timeline_items_before(pane, watched.snapshot.before.unwrap(), 100)
        .await
        .unwrap();
    let shown: Vec<_> = older.items.iter().map(|item| text(&item.body)).collect();
    let expected: Vec<_> = (0..10).map(|index| format!("reply {index}")).collect();
    assert_eq!(shown, expected);

    fixture.user("And now?");
    fixture.reply("Done.");
    assert_eq!(
        next_upserts(&mut events, "Done.").await,
        ["And now?", "Done."]
    );

    let ChatSendStatus::Prepared {
        ticket, revision, ..
    } = pi.client.chat_prepare(pane).await.unwrap()
    else {
        panic!("expected a ticket");
    };
    let status = pi
        .client
        .chat_send(pane, ticket, "run the tests".into(), Some(revision))
        .await
        .unwrap();
    assert_eq!(status, ChatSendStatus::SentNotConfirmed);
    let captured = pi.captured.clone();
    wait_until(move || {
        std::fs::read(&captured).is_ok_and(|bytes| bytes == b"\x1b[200~run the tests\x1b[201~\r")
    })
    .await;
    pi.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pi_started_by_hand_is_read_only() {
    let mut fixture = Fixture::new();
    fixture.reply("hello");
    let pi = pi_pane(&mut fixture, false).await;
    let pane = pi.entry.pane.id;
    let watched = pi.client.timeline_watch_capabilities(pane).await.unwrap();
    assert_eq!(watched.capabilities, AgentCapabilities::READ);
    assert!(pi.client.chat_prepare(pane).await.is_err());
    pi.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_app_that_cannot_name_pi_is_told_to_update() {
    let mut fixture = Fixture::new();
    fixture.reply("hello");
    let pi = pi_pane(&mut fixture, true).await;
    let refusal = pi
        .client
        .workspace(WorkspaceRequest::TimelineWatchCapabilities {
            pane_id: pi.entry.pane.id,
            version: 2,
        })
        .await
        .unwrap_err();
    assert_eq!(
        refusal,
        WsError::Unavailable("Update the app to use Chat with pi.".into())
    );
    pi.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn without_a_sessions_folder_chat_says_where_it_looked() {
    let mut fixture = Fixture::new();
    fixture.reply("hello");
    let pi = pi_pane(&mut fixture, true).await;
    std::fs::remove_dir_all(fixture.agent_dir.path().join("sessions")).unwrap();
    let refusal = pi
        .client
        .timeline_watch_capabilities(pi.entry.pane.id)
        .await
        .unwrap_err();
    let WsError::Unavailable(message) = refusal else {
        panic!("expected unavailable, got {refusal:?}");
    };
    assert!(
        message.starts_with("Chat can't find pi's sessions folder."),
        "{message}"
    );
    pi.daemon.shutdown().await;
}

async fn prepared(pi: &PiPane) -> (u64, bool) {
    let ChatSendStatus::Prepared {
        ticket,
        needs_confirmation,
        ..
    } = pi.client.chat_prepare(pi.entry.pane.id).await.unwrap()
    else {
        panic!("expected a ticket");
    };
    (ticket, needs_confirmation)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_launched_pi_takes_chat_prompts_without_asking_until_someone_types() {
    let mut fixture = Fixture::new();
    fixture.user("Hello");
    fixture.reply("Hi.");
    let pi = pi_pane(&mut fixture, true).await;
    let pane = pi.entry.pane.id;
    pi.client.timeline_watch_capabilities(pane).await.unwrap();

    let (ticket, needs_confirmation) = prepared(&pi).await;
    assert!(!needs_confirmation, "nothing was typed in Terminal");
    let client = Arc::clone(&pi.client);
    let sending = tokio::spawn(async move {
        client
            .chat_send(pane, ticket, "run the tests".into(), None)
            .await
    });
    let captured = pi.captured.clone();
    wait_until(move || {
        std::fs::read(&captured).is_ok_and(|bytes| bytes == b"\x1b[200~run the tests\x1b[201~\r")
    })
    .await;
    fixture.user("run the tests");
    assert_eq!(sending.await.unwrap().unwrap(), ChatSendStatus::Confirmed);
    fixture.reply("All green.");

    let (_, needs_confirmation) = prepared(&pi).await;
    assert!(
        !needs_confirmation,
        "pi took the last send, so its field is empty"
    );

    pi.client.send_input(pane, b"half a thought".to_vec());
    let captured = pi.captured.clone();
    wait_until(move || {
        std::fs::read(&captured).is_ok_and(|bytes| bytes.ends_with(b"half a thought"))
    })
    .await;
    let (_, needs_confirmation) = prepared(&pi).await;
    assert!(
        needs_confirmation,
        "text typed in Terminal would be sent with it"
    );
    pi.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_message_sent_in_terminal_leaves_pi_clean_for_chat() {
    let mut fixture = Fixture::new();
    fixture.reply("Ready.");
    let pi = pi_pane(&mut fixture, true).await;
    let pane = pi.entry.pane.id;
    pi.client.timeline_watch_capabilities(pane).await.unwrap();

    pi.client.send_input(pane, b"look at the logs\r".to_vec());
    let captured = pi.captured.clone();
    wait_until(move || std::fs::read(&captured).is_ok_and(|bytes| bytes.ends_with(b"logs\r")))
        .await;
    assert!(prepared(&pi).await.1, "pi has not taken the message yet");
    fixture.user("look at the logs");
    let entry = Arc::clone(&pi.entry);
    let client = Arc::clone(&pi.client);
    tokio::time::timeout(Duration::from_secs(10), async move {
        loop {
            if let Ok(ChatSendStatus::Prepared {
                needs_confirmation: false,
                ..
            }) = client.chat_prepare(entry.pane.id).await
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("pi recorded the message, so its field is empty");
    pi.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_fresh_pi_takes_its_first_chat_prompt_without_asking() {
    let mut fixture = Fixture::new();
    let pi = pi_pane_resuming(&mut fixture, true, None).await;
    let (_, needs_confirmation) = prepared(&pi).await;
    assert!(
        !needs_confirmation,
        "a pi with no conversation yet has an empty field"
    );
    pi.daemon.shutdown().await;
}

/// Stands in for pi's bridge extension on the pane's hook socket.
struct FakeBridge {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    write: tokio::net::unix::OwnedWriteHalf,
}

impl FakeBridge {
    async fn connect(pi: &PiPane) -> Self {
        use tokio::io::AsyncBufReadExt;
        let core = &pi.daemon.core;
        let context = core.hooks.launch_context(
            pi.entry.pane.id,
            "/".into(),
            agents::AccountContext::system(),
        );
        let stream = tokio::net::UnixStream::connect(core.hooks.socket())
            .await
            .unwrap();
        let (read, write) = stream.into_split();
        let mut bridge = Self {
            lines: tokio::io::BufReader::new(read).lines(),
            write,
        };
        bridge
            .send(serde_json::json!({"pi_bridge": {
                "v": 1, "token": context.token, "pane": pi.entry.pane.id.0.to_string(), "pid": 1,
            }}))
            .await;
        assert_eq!(bridge.next().await["type"], "ready");
        bridge
    }

    async fn send(&mut self, message: serde_json::Value) {
        use tokio::io::AsyncWriteExt;
        self.write
            .write_all(format!("{message}\n").as_bytes())
            .await
            .unwrap();
    }

    async fn next(&mut self) -> serde_json::Value {
        let line = tokio::time::timeout(Duration::from_secs(10), self.lines.next_line())
            .await
            .expect("a request from the helper")
            .unwrap()
            .expect("the helper kept the bridge open");
        serde_json::from_str(&line).unwrap()
    }

    async fn reply_to(&mut self, kind: &str) -> serde_json::Value {
        let request = self.next().await;
        assert_eq!(request["type"], kind);
        self.send(
            serde_json::json!({"type": "reply", "id": request["id"], "ok": true, "data": {}}),
        )
        .await;
        request
    }
}

/// Folds the timeline into rows by id until `done` holds for them.
async fn rows_until(
    events: &mut tokio::sync::mpsc::UnboundedReceiver<WorkspaceEvent>,
    done: impl Fn(&std::collections::BTreeMap<String, TimelineBody>) -> bool,
) -> std::collections::BTreeMap<String, TimelineBody> {
    let mut rows = std::collections::BTreeMap::new();
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if let WorkspaceEvent::Timeline { update } = events.recv().await.unwrap() {
                for operation in update.operations {
                    match operation {
                        TimelineOp::Upsert { item, .. } => {
                            rows.insert(item.id, item.body);
                        }
                        TimelineOp::Append { id, text, .. } => match rows.get_mut(&id) {
                            Some(TimelineBody::Assistant { text: shown, .. }) => {
                                shown.push_str(&text);
                            }
                            Some(TimelineBody::Thinking {
                                text: Some(shown), ..
                            }) => shown.push_str(&text),
                            _ => panic!("an append to {id} without its row"),
                        },
                        TimelineOp::Remove { id, .. } => {
                            rows.remove(&id);
                        }
                        _ => {}
                    }
                }
                if done(&rows) {
                    return;
                }
            }
        }
    })
    .await
    .expect("the timeline reached the expected rows");
    rows
}

#[tokio::test(flavor = "multi_thread")]
async fn a_connected_pi_streams_its_reply_until_its_session_records_it() {
    let mut fixture = Fixture::new();
    fixture.reply("Ready.");
    let pi = pi_pane(&mut fixture, true).await;
    let pane = pi.entry.pane.id;
    let mut bridge = FakeBridge::connect(&pi).await;
    bridge
        .send(serde_json::json!({"type": "session", "session_id": SESSION, "session_file": null,
            "cwd": null, "model": {"provider": "anthropic", "id": "claude-opus-4-5", "name": "Opus", "reasoning": true},
            "thinking": "medium", "thinking_levels": ["off", "low", "medium", "high"]}))
        .await;
    bridge
        .send(serde_json::json!({"type": "commands", "commands": [
            {"name": "review", "description": "Review the diff", "source": "prompt", "scope": "project"}]}))
        .await;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    pi.client.set_workspace_listener(listener);
    let watched = pi.client.timeline_watch_capabilities(pane).await.unwrap();
    assert!(watched.capabilities.contains(
        AgentCapabilities::STOP | AgentCapabilities::STREAMING_DELTAS | AgentCapabilities::SEND
    ));
    assert_eq!(watched.snapshot.session.model.as_deref(), Some("Opus"));
    assert_eq!(watched.snapshot.session.commands[0].name, "/review");

    let started = 1_794_166_900_000_u64;
    bridge
        .send(serde_json::json!({"type": "busy", "busy": true}))
        .await;
    bridge
        .send(serde_json::json!({"type": "message_start", "timestamp": started}))
        .await;
    for (kind, text) in [
        ("thinking", "Looking"),
        ("text", "All "),
        ("text", "green."),
    ] {
        let index = u32::from(kind == "text");
        bridge
            .send(serde_json::json!({"type": "delta", "timestamp": started, "index": index, "kind": kind, "text": text}))
            .await;
    }
    let live = format!("live:{started}:1");
    let rows = rows_until(&mut events, |rows| {
        matches!(rows.get(&live), Some(TimelineBody::Assistant { text, streaming: true }) if text == "All green.")
    })
    .await;
    assert!(matches!(rows.get(&format!("live:{started}:0")),
        Some(TimelineBody::Thinking { text: Some(text), .. }) if text == "Looking"));

    bridge
        .send(
            serde_json::json!({"type": "message_end", "timestamp": started, "stop_reason": "stop"}),
        )
        .await;
    fixture.message(serde_json::json!({"role": "assistant", "content": [
        {"type": "thinking", "thinking": "Looking"}, {"type": "text", "text": "All green."}],
        "usage": {}, "stopReason": "stop", "timestamp": started}));
    let rows = rows_until(&mut events, |rows| {
        !rows.contains_key(&live)
            && rows
                .values()
                .any(|body| matches!(body, TimelineBody::Assistant { text, streaming: false } if text == "All green."))
    })
    .await;
    assert!(rows.keys().all(|id| !id.starts_with("live:")));
    pi.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_connected_pi_confirms_chat_prompts_and_stops_without_terminal_keys() {
    let mut fixture = Fixture::new();
    fixture.reply("Ready.");
    let pi = pi_pane(&mut fixture, true).await;
    let pane = pi.entry.pane.id;
    let mut bridge = FakeBridge::connect(&pi).await;
    pi.client.timeline_watch_capabilities(pane).await.unwrap();

    let (ticket, _) = prepared(&pi).await;
    let client = Arc::clone(&pi.client);
    let sending = tokio::spawn(async move {
        client
            .chat_send(pane, ticket, "run the tests".into(), None)
            .await
    });
    let request = bridge.reply_to("prompt").await;
    assert_eq!(request["text"], "run the tests");
    assert_eq!(sending.await.unwrap().unwrap(), ChatSendStatus::Confirmed);

    bridge
        .send(serde_json::json!({"type": "busy", "busy": true}))
        .await;
    let client = Arc::clone(&pi.client);
    let ChatSendStatus::Prepared { ticket, .. } =
        tokio::time::timeout(Duration::from_secs(10), async move {
            loop {
                if let Ok(prepared) = client.chat_interrupt_prepare(pane).await {
                    return prepared;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("a running pi can be interrupted")
    else {
        panic!("expected an interrupt ticket");
    };
    let client = Arc::clone(&pi.client);
    let stopping = tokio::spawn(async move { client.chat_interrupt(pane, ticket, None).await });
    bridge.reply_to("abort").await;
    assert_eq!(
        stopping.await.unwrap().unwrap(),
        ChatSendStatus::InterruptRequested
    );
    assert!(
        std::fs::read(&pi.captured).unwrap_or_default().is_empty(),
        "nothing reached pi's terminal"
    );
    pi.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_bridge_with_another_panes_token_is_refused() {
    let mut fixture = Fixture::new();
    fixture.reply("Ready.");
    let pi = pi_pane(&mut fixture, true).await;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let stream = tokio::net::UnixStream::connect(pi.daemon.core.hooks.socket())
        .await
        .unwrap();
    let (read, mut write) = stream.into_split();
    let hello = serde_json::json!({"pi_bridge": {"v": 1, "token": "00", "pane": pi.entry.pane.id.0.to_string()}});
    write
        .write_all(format!("{hello}\n").as_bytes())
        .await
        .unwrap();
    let mut lines = tokio::io::BufReader::new(read).lines();
    assert!(lines.next_line().await.unwrap().is_none());
    assert!(lock(&pi.entry.pi).is_none());
    pi.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_connected_pi_lists_and_changes_its_model_and_thinking_level() {
    use crate::agent_driver::pi::config::{AgentConfigDriver, PiConfig};
    let mut fixture = Fixture::new();
    fixture.reply("Ready.");
    let pi = pi_pane(&mut fixture, true).await;
    let pane = pi.entry.pane.id;
    let core = Arc::clone(&pi.daemon.core);
    assert!(PiConfig.config(&core, pane).is_err());
    let mut bridge = FakeBridge::connect(&pi).await;
    bridge
        .send(serde_json::json!({"type": "session", "session_id": SESSION,
            "model": {"provider": "anthropic", "id": "claude-opus-4-5", "name": "Opus", "reasoning": true},
            "thinking": "medium", "thinking_levels": ["off", "low", "medium", "high"]}))
        .await;
    bridge
        .send(serde_json::json!({"type": "models", "models": [
            {"provider": "anthropic", "id": "claude-opus-4-5", "name": "Opus", "reasoning": true},
            {"provider": "openai", "id": "gpt-5.5", "name": "GPT-5.5", "reasoning": true}]}))
        .await;
    bridge
        .send(serde_json::json!({"type": "usage", "tokens": 1200, "context_window": 200000}))
        .await;
    let config = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if let Ok(config) = PiConfig.config(&core, pane)
                && config.models.len() == 2
                && config.context.is_some()
            {
                return config;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("pi reported its models");
    assert_eq!(config.model.as_deref(), Some("anthropic/claude-opus-4-5"));
    assert_eq!(config.models[1].id, "openai/gpt-5.5");
    assert_eq!(config.effort.as_deref(), Some("medium"));
    assert_eq!(config.context, Some((1200, 200_000)));
    assert!(PiConfig.set_effort(&core, pane, "extreme").is_err());

    let changing = PiConfig.set_effort(&core, pane, "high").unwrap();
    let request = bridge.reply_to("set_thinking").await;
    assert_eq!(request["level"], "high");
    changing.await.unwrap();
    let changing = PiConfig.set_model(&core, pane, "openai/gpt-5.5").unwrap();
    let request = bridge.reply_to("set_model").await;
    assert_eq!(
        (request["provider"].as_str(), request["model"].as_str()),
        (Some("openai"), Some("gpt-5.5"))
    );
    changing.await.unwrap();
    pi.daemon.shutdown().await;
}
