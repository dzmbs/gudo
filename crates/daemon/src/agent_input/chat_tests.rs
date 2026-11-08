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

async fn relay(daemon: &crate::Daemon, request: &crate::HookRequest) -> crate::HookResponse {
    relay_at(daemon.hook_socket(), request).await
}

async fn relay_at(socket: &Path, request: &crate::HookRequest) -> crate::HookResponse {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut bytes = serde_json::to_vec(request).unwrap();
    bytes.push(b'\n');
    stream.write_all(&bytes).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
    serde_json::from_str(&answer).unwrap()
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

struct RawFixture {
    root: tempfile::TempDir,
    daemon: crate::Daemon,
    client: Arc<Client>,
    entry: Arc<crate::core::PaneEntry>,
    captured: std::path::PathBuf,
    _events: tokio::sync::mpsc::UnboundedReceiver<ClientEvent>,
}

async fn raw_fixture() -> RawFixture {
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
    let (entry, captured) = raw_pane(&daemon, root.path()).await;
    {
        let mut gate = lock(&entry.pane.agent_input_gate);
        *gate = AgentInputGate::pending("fixture".into());
        assert!(gate.arm("fixture"));
    }
    hook(&daemon, root.path(), entry.pane.id, "previous").await;
    let (client, events) = owner_client(&daemon).await;
    RawFixture {
        root,
        daemon,
        client,
        entry,
        captured,
        _events: events,
    }
}

async fn raw_pane(
    daemon: &crate::Daemon,
    root: &Path,
) -> (Arc<crate::core::PaneEntry>, std::path::PathBuf) {
    let (_, _, pane) = daemon
        .core
        .create_session("send fixture".into(), PaneLaunch::Shell { cwd: None })
        .unwrap();
    let entry = daemon.core.pane(pane).unwrap();
    wait_until(|| !entry.pane.screen_text().trim().is_empty()).await;
    let captured = root.join("received");
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
    (entry, captured)
}

async fn owner_client(
    daemon: &crate::Daemon,
) -> (
    Arc<Client>,
    tokio::sync::mpsc::UnboundedReceiver<ClientEvent>,
) {
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

    (client, events)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_known_approval_dialog_cannot_be_answered_through_native_prompt_input() {
    let fixture = raw_fixture().await;
    let pane = fixture.entry.pane.id;
    let ChatSendStatus::Prepared { ticket, .. } = fixture.client.chat_prepare(pane).await.unwrap()
    else {
        panic!("no prompt ticket")
    };
    let request = crate::HookRequest {
        v: 1,
        token: std::fs::read_to_string(fixture.root.path().join("hook.token")).unwrap(),
        pane: pane.0.to_string(),
        agent: "claude".into(),
        event: "PermissionRequest".into(),
        seq: crate::hook_seq(),
        payload: json!({"session_id":"native", "hook_event_name":"PermissionRequest", "tool_name":"Bash",
                        "tool_input":{"command":"private fixture"}, "permission_suggestions":[]}),
    };
    let socket = fixture.daemon.hook_socket().to_owned();
    let waiting = tokio::spawn(async move { relay_at(&socket, &request).await });
    wait_until(|| {
        lock(&fixture.entry.agent)
            .as_ref()
            .is_some_and(|agent| agent.is_blocked())
    })
    .await;
    let sent = fixture
        .client
        .chat_send(pane, ticket, "yes".into(), None)
        .await;
    let prepared = fixture.client.chat_prepare(pane).await;
    let captured = std::fs::read(&fixture.captured).unwrap_or_default();
    let approval = lock(&fixture.entry.agent)
        .as_mut()
        .unwrap()
        .blocked_wire()
        .unwrap()
        .0;
    fixture.client.decide(approval, proto::OptionId(0));
    let response = tokio::time::timeout(Duration::from_secs(10), waiting)
        .await
        .unwrap()
        .unwrap();
    let response: serde_json::Value =
        serde_json::from_str(response.stdout.as_deref().unwrap()).unwrap();
    fixture.daemon.shutdown().await;
    assert!(
        sent.is_err(),
        "blocked prompt admission returned {sent:?}; PTY bytes: {captured:?}"
    );
    assert!(
        prepared.is_err(),
        "a known approval cannot mint a prompt ticket"
    );
    assert!(
        captured.is_empty(),
        "approval choices must use signed decisions, not PTY input"
    );
    assert_eq!(
        response["hookSpecificOutput"]["decision"]["behavior"],
        "allow"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_late_preinterrupt_submission_cannot_renew_native_interrupt_eligibility() {
    let fixture = raw_fixture().await;
    let pane = fixture.entry.pane.id;
    let ChatSendStatus::Prepared { ticket, .. } =
        fixture.client.chat_interrupt_prepare(pane).await.unwrap()
    else {
        panic!("no interrupt ticket")
    };
    assert_eq!(
        fixture
            .client
            .chat_interrupt(pane, ticket, None)
            .await
            .unwrap(),
        ChatSendStatus::InterruptRequested
    );
    let request = crate::HookRequest {
        v: 1,
        token: std::fs::read_to_string(fixture.root.path().join("hook.token")).unwrap(),
        pane: pane.0.to_string(),
        agent: "claude".into(),
        event: "UserPromptSubmit".into(),
        seq: lock(&fixture.entry.pane.agent_input_gate).last_user_input_seq - 1,
        payload: json!({"session_id":"native", "hook_event_name":"UserPromptSubmit", "prompt":"late"}),
    };
    relay(&fixture.daemon, &request).await;
    let late = fixture.client.chat_interrupt_prepare(pane).await;
    hook(
        &fixture.daemon,
        fixture.root.path(),
        pane,
        "fresh post-interrupt prompt",
    )
    .await;
    let fresh = fixture.client.chat_interrupt_prepare(pane).await;
    fixture.daemon.shutdown().await;
    assert!(
        late.is_err(),
        "a pre-interrupt hook renewed eligibility: {late:?}"
    );
    assert!(matches!(fresh, Ok(ChatSendStatus::Prepared { .. })));
}

#[tokio::test(flavor = "multi_thread")]
async fn private_dev_interrupt_is_one_escape_bound_to_the_live_hook_turn_and_current_draft() {
    let fixture = raw_fixture().await;
    fixture.interrupt_clean_once().await;
    fixture.interrupt_cannot_cross_a_turn().await;
    fixture.interrupt_requires_current_confirmation().await;
    fixture.interrupt_stops_after_hook_or_exit_fence().await;
    fixture.daemon.shutdown().await;
}

impl RawFixture {
    async fn interrupt_offer(&self) -> super::draft::Offer {
        match self
            .client
            .chat_interrupt_prepare(self.entry.pane.id)
            .await
            .unwrap()
        {
            ChatSendStatus::Prepared {
                ticket,
                revision,
                needs_confirmation,
            } => super::draft::Offer {
                ticket,
                revision,
                needs_confirmation,
            },
            status => panic!("expected interrupt ticket, got {status:?}"),
        }
    }

    async fn interrupt_clean_once(&self) {
        let pane = self.entry.pane.id;
        let offer = self.interrupt_offer().await;
        assert!(!offer.needs_confirmation);
        assert_eq!(
            self.client
                .chat_interrupt(pane, offer.ticket, None)
                .await
                .unwrap(),
            ChatSendStatus::InterruptRequested
        );
        wait_until(|| std::fs::read(&self.captured).is_ok_and(|bytes| bytes == b"\x1b")).await;
        assert_eq!(
            self.client
                .chat_interrupt(pane, offer.ticket, None)
                .await
                .unwrap(),
            ChatSendStatus::NotConfirmed
        );
        assert!(self.client.chat_interrupt_prepare(pane).await.is_err());
        assert!(matches!(
            self.client.chat_prepare(pane).await.unwrap(),
            ChatSendStatus::Prepared {
                needs_confirmation: true,
                ..
            }
        ));
    }

    async fn interrupt_cannot_cross_a_turn(&self) {
        let pane = self.entry.pane.id;
        hook(&self.daemon, self.root.path(), pane, "first active turn").await;
        let offer = self.interrupt_offer().await;
        hook(&self.daemon, self.root.path(), pane, "new active turn").await;
        assert_eq!(
            self.client
                .chat_interrupt(pane, offer.ticket, None)
                .await
                .unwrap(),
            ChatSendStatus::NotConfirmed
        );
    }

    async fn interrupt_requires_current_confirmation(&self) {
        let pane = self.entry.pane.id;
        self.entry.pane.write(b"draft".to_vec()).await.unwrap();
        let offer = self.interrupt_offer().await;
        assert!(offer.needs_confirmation);
        assert_eq!(
            self.client
                .chat_interrupt(pane, offer.ticket, None)
                .await
                .unwrap(),
            ChatSendStatus::ConfirmationRequired {
                revision: offer.revision
            }
        );
        self.entry.pane.write(b"x".to_vec()).await.unwrap();
        let ChatSendStatus::ConfirmationRequired { revision } = self
            .client
            .chat_interrupt(pane, offer.ticket, Some(offer.revision))
            .await
            .unwrap()
        else {
            panic!("stale draft confirmation admitted Escape")
        };
        assert!(revision > offer.revision);
        assert_eq!(
            self.client
                .chat_interrupt(pane, offer.ticket, Some(revision))
                .await
                .unwrap(),
            ChatSendStatus::InterruptRequested
        );
        wait_until(|| std::fs::read(&self.captured).is_ok_and(|bytes| bytes == b"\x1bdraftx\x1b"))
            .await;
    }

    async fn interrupt_stops_after_hook_or_exit_fence(&self) {
        let pane = self.entry.pane.id;
        hook(&self.daemon, self.root.path(), pane, "another active turn").await;
        let offer = self.interrupt_offer().await;
        relay(
            &self.daemon,
            &crate::HookRequest {
                v: 1,
                token: std::fs::read_to_string(self.root.path().join("hook.token")).unwrap(),
                pane: pane.0.to_string(),
                agent: "claude".into(),
                event: "Stop".into(),
                seq: crate::hook_seq(),
                payload: json!({"session_id":"native", "hook_event_name":"Stop"}),
            },
        )
        .await;
        assert!(self.client.chat_interrupt_prepare(pane).await.is_err());
        assert!(
            self.client
                .chat_interrupt(pane, offer.ticket, None)
                .await
                .is_err()
        );
        hook(&self.daemon, self.root.path(), pane, "live before exit").await;
        let offer = self.interrupt_offer().await;
        assert!(lock(&self.entry.pane.agent_input_gate).close("fixture"));
        assert!(self.client.chat_interrupt_prepare(pane).await.is_err());
        assert!(
            self.client
                .chat_interrupt(pane, offer.ticket, None)
                .await
                .is_err()
        );
        assert_eq!(std::fs::read(&self.captured).unwrap(), b"\x1bdraftx\x1b");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn private_dev_daemon_sends_once_and_requires_hook_and_current_draft_confirmation() {
    let RawFixture {
        root,
        daemon,
        client,
        entry,
        captured,
        _events,
    } = raw_fixture().await;
    let pane = entry.pane.id;
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
