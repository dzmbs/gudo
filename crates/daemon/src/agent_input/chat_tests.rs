use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use client_core::{Client, ClientConfig, ClientEvent, EventQueue};
use proto::{ChatSendStatus, PaneId, PaneLaunch};
use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use super::{AgentInputGate, lock};

async fn hook(daemon: &crate::Daemon, root: &Path, pane: PaneId, prompt: &str) {
    let request = crate::HookRequest {
        v: 1,
        token: std::fs::read_to_string(root.join("hook.token")).unwrap(),
        pane: pane.0.to_string(),
        agent: "claude".into(),
        event: "UserPromptSubmit".into(),
        seq: crate::hook_seq(),
        payload: json!({"session_id":"native", "hook_event_name":"UserPromptSubmit", "prompt":prompt}),
    };
    relay(daemon, &request).await;
}

async fn notify(daemon: &crate::Daemon, root: &Path, pane: PaneId, prompt: &str) {
    relay(daemon, &crate::HookRequest {
        v: 1, token: std::fs::read_to_string(root.join("hook.token")).unwrap(),
        pane: pane.0.to_string(), agent: "codex".into(), event: crate::CODEX_NOTIFY_EVENT.into(),
        seq: crate::hook_seq(), payload: json!({"type":"agent-turn-complete", "thread-id":"codex native", "input-messages":[prompt]}),
    }).await;
}

async fn relay(daemon: &crate::Daemon, request: &crate::HookRequest) {
    let mut stream = UnixStream::connect(daemon.hook_socket()).await.unwrap();
    let mut bytes = serde_json::to_vec(request).unwrap();
    bytes.push(b'\n');
    stream.write_all(&bytes).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
    assert!(serde_json::from_str::<crate::HookResponse>(&answer).is_ok());
}

async fn wait_until(mut check: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while !check() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn private_dev_daemon_sends_once_and_requires_hook_and_current_draft_confirmation() {
    let root = tempfile::tempdir().unwrap();
    let mut config = crate::Config::new(root.path());
    config.relay = crate::RelayMode::Disabled;
    config.bind = Some("127.0.0.1:0".parse().unwrap());
    config.shell = Some("/bin/sh".into());
    config.pane_env = vec![
        ("ENV".into(), String::new()),
        ("PS1".into(), "FIXTURE_READY ".into()),
    ];
    let daemon = crate::Daemon::start(config).await.unwrap();
    let (_, _, pane) = daemon
        .core
        .create_session("send fixture".into(), PaneLaunch::Shell { cwd: None })
        .unwrap();
    let entry = daemon.core.pane(pane).unwrap();
    wait_until(|| !entry.pane.screen_text().trim().is_empty()).await;
    let captured = root.path().join("received");
    // A raw, isolated fixture process records exactly what the PTY receives, not a real account.
    entry
        .pane
        .write(
            format!(
                "stty raw -echo; printf '\\033[?2004h'; /bin/cat > '{}'\n",
                captured.display()
            )
            .into_bytes(),
        )
        .await
        .unwrap();
    wait_until(|| {
        entry.pane.line_snapshot().bracketed
            && entry
                .pane
                .pty()
                .foreground_pgid()
                .is_some_and(|pid| pid != entry.pane.pty().pid())
    })
    .await;
    {
        let mut gate = lock(&entry.pane.agent_input_gate);
        *gate = AgentInputGate::pending("fixture".into());
        assert!(gate.arm("fixture"));
    }
    hook(&daemon, root.path(), pane, "previous").await;
    let (listener, mut events) = EventQueue::channel();
    let mut config = ClientConfig::new(ClientConfig::generate_key());
    config.relay = client_core::RelayMode::Disabled;
    let ticket = daemon
        .pairing_ticket(crate::PAIRING_TTL)
        .unwrap()
        .to_string();
    let client = Arc::new(
        Client::connect_with(
            &ticket,
            config,
            client_core::ConnectOptions::default(),
            listener,
        )
        .unwrap(),
    );
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(event) = events.recv().await {
            if matches!(event, ClientEvent::Connected { .. }) {
                return;
            }
        }
        panic!("client closed before connecting");
    })
    .await
    .unwrap();

    let ChatSendStatus::Prepared {
        ticket,
        needs_confirmation,
        ..
    } = client.chat_prepare(pane).await.unwrap()
    else {
        panic!("no ticket")
    };
    assert!(!needs_confirmation);
    let sender = Arc::clone(&client);
    let sent = tokio::spawn(async move {
        sender
            .chat_send(pane, ticket, "hello\nworld".into(), None)
            .await
            .unwrap()
    });
    let expected = b"\x1b[200~hello\nworld\x1b[201~\r";
    wait_until(|| std::fs::read(&captured).is_ok_and(|bytes| bytes == expected)).await;
    assert!(!sent.is_finished(), "PTY delivery alone must not confirm");
    let stale = lock(&entry.pane.agent_input_gate).last_user_input_seq;
    super::submitted(&entry.pane, "native", "hello world", stale);
    assert!(
        lock(&entry.pane.agent_input_gate).draft.is_pending(),
        "pre-write hook confirmed a newer send"
    );
    hook(&daemon, root.path(), pane, " hello  world ").await;
    assert_eq!(sent.await.unwrap(), ChatSendStatus::Confirmed);
    assert_eq!(
        client
            .chat_send(pane, ticket, "hello\nworld".into(), None)
            .await
            .unwrap(),
        ChatSendStatus::NotConfirmed
    );
    assert_eq!(std::fs::read(&captured).unwrap(), expected);
    let audit = daemon.core.mp.audit.query(proto::AuditQuery {
        after: None,
        limit: 1_000,
    });
    let prompts: Vec<_> = audit
        .records
        .iter()
        .filter(|record| record.kind == proto::AuditKind::Prompt)
        .collect();
    assert_eq!(
        prompts.len(),
        1,
        "native send must be audited once, never for replay"
    );
    assert_eq!(prompts[0].pane_id, Some(pane));
    assert!(prompts[0].actor.is_some());
    assert!(!prompts[0].detail.contains("hello"));

    entry.pane.write(b"draft\x1b".to_vec()).await.unwrap();
    let ChatSendStatus::Prepared {
        ticket,
        revision,
        needs_confirmation,
    } = client.chat_prepare(pane).await.unwrap()
    else {
        panic!("no dirty ticket")
    };
    assert!(needs_confirmation);
    assert_eq!(
        client
            .chat_send(pane, ticket, "next".into(), None)
            .await
            .unwrap(),
        ChatSendStatus::ConfirmationRequired { revision }
    );
    entry.pane.write(b"new".to_vec()).await.unwrap();
    let ChatSendStatus::ConfirmationRequired { revision: current } = client
        .chat_send(pane, ticket, "next".into(), Some(revision))
        .await
        .unwrap()
    else {
        panic!("stale confirmation admitted")
    };
    assert!(current > revision);
    let sender = Arc::clone(&client);
    let sent = tokio::spawn(async move {
        sender
            .chat_send(pane, ticket, "next".into(), Some(current))
            .await
            .unwrap()
    });
    wait_until(|| {
        std::fs::read(&captured).is_ok_and(|bytes| bytes.ends_with(b"\x1b[200~next\x1b[201~\r"))
    })
    .await;
    entry
        .pane
        .write(b"typing during send".to_vec())
        .await
        .unwrap();
    assert_eq!(sent.await.unwrap(), ChatSendStatus::NotConfirmed);
    hook(&daemon, root.path(), pane, "next").await;
    let ChatSendStatus::Prepared {
        needs_confirmation, ..
    } = client.chat_prepare(pane).await.unwrap()
    else {
        panic!("no post-race ticket")
    };
    assert!(
        needs_confirmation,
        "late hook must not erase uncertainty from concurrent typing"
    );

    hook(&daemon, root.path(), pane, "another local submission").await;
    for mismatch in [true, false] {
        let ChatSendStatus::Prepared { ticket, .. } = client.chat_prepare(pane).await.unwrap()
        else {
            panic!("no ticket")
        };
        let sender = Arc::clone(&client);
        let sent = tokio::spawn(async move {
            sender
                .chat_send(pane, ticket, "probe".into(), None)
                .await
                .unwrap()
        });
        wait_until(|| lock(&entry.pane.agent_input_gate).draft.is_pending()).await;
        if mismatch {
            hook(&daemon, root.path(), pane, "not probe").await;
        }
        assert_eq!(sent.await.unwrap(), ChatSendStatus::NotConfirmed);
    }
    hook(&daemon, root.path(), pane, "local submission before exit").await;
    let ChatSendStatus::Prepared { ticket, .. } = client.chat_prepare(pane).await.unwrap() else {
        panic!("no exit ticket")
    };
    let sender = Arc::clone(&client);
    let sent = tokio::spawn(async move {
        sender
            .chat_send(pane, ticket, "exit probe".into(), None)
            .await
            .unwrap()
    });
    wait_until(|| lock(&entry.pane.agent_input_gate).draft.is_pending()).await;
    assert!(lock(&entry.pane.agent_input_gate).close("fixture"));
    assert_eq!(sent.await.unwrap(), ChatSendStatus::NotConfirmed);
    assert!(client.chat_prepare(pane).await.is_err());
    // The raw PTY fixture also exercises Codex's deliberately unconfirmed fallback.
    *lock(&entry.agent) = Some(crate::agent::AgentRuntime::new(
        proto::AgentKind::Codex,
        pane,
        crate::agent::adapter(proto::AgentKind::Codex),
        false,
    ));
    {
        let mut gate = lock(&entry.pane.agent_input_gate);
        *gate = AgentInputGate::pending("codex fixture".into());
        assert!(gate.arm("codex fixture"));
    }
    let ChatSendStatus::Prepared {
        ticket,
        revision,
        needs_confirmation,
    } = client.chat_prepare(pane).await.unwrap()
    else {
        panic!("no Codex ticket")
    };
    assert!(needs_confirmation);
    assert_eq!(
        client
            .chat_send(pane, ticket, "Codex probe".into(), Some(revision))
            .await
            .unwrap(),
        ChatSendStatus::SentNotConfirmed
    );
    notify(&daemon, root.path(), pane, "previous Codex input").await;
    let ChatSendStatus::Prepared {
        ticket,
        needs_confirmation,
        ..
    } = client.chat_prepare(pane).await.unwrap()
    else {
        panic!("no correlated Codex ticket")
    };
    assert!(!needs_confirmation);
    let sender = Arc::clone(&client);
    let sent = tokio::spawn(async move {
        sender
            .chat_send(pane, ticket, "Codex confirmed".into(), None)
            .await
            .unwrap()
    });
    wait_until(|| lock(&entry.pane.agent_input_gate).draft.is_pending()).await;
    notify(&daemon, root.path(), pane, "Codex confirmed").await;
    assert_eq!(sent.await.unwrap(), ChatSendStatus::Confirmed);
    drop(client);
    daemon.shutdown().await;
}
