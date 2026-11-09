use super::*;
use crate::agent_input::chat_tests::{RawFixture, raw_fixture_with_claude_streaming, relay};
use serde_json::{Value, json};
use std::io::Write;

pub(crate) const SESSION: &str = "11111111-1111-4111-8111-111111111111";
pub(crate) const PROMPT: &str = "22222222-2222-4222-8222-222222222222";

pub(crate) struct Fixture {
    pub raw: RawFixture,
    pub path: PathBuf,
}

impl Fixture {
    pub async fn new() -> Self {
        let raw = raw_fixture_with_claude_streaming(SESSION, true).await;
        lock(&raw.entry.record).cwd = Some(raw.root.path().display().to_string());
        let directory =
            crate::claude_session::project_dir(&raw.root.path().join("agent"), raw.root.path());
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join(format!("{SESSION}.jsonl"));
        let fixture = Self { raw, path };
        fixture.append(json!({"type":"user","sessionId":SESSION,"uuid":"canonical-user","promptId":PROMPT,"timestamp":"2026-01-01T00:00:00Z","message":{"content":"fixture prompt"}}));
        fixture.hook("UserPromptSubmit", PROMPT).await;
        assert!(fixture.snapshot().is_some());
        fixture
    }

    pub fn capture(&self) -> &Capture {
        &self.raw.daemon.core.hooks.display
    }

    pub fn append(&self, record: Value) {
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .unwrap();
        writeln!(file, "{record}").unwrap();
    }

    pub async fn hook(&self, event: &str, prompt: &str) {
        let request = crate::HookRequest {
            v: 1,
            token: std::fs::read_to_string(self.raw.root.path().join("hook.token")).unwrap(),
            pane: self.raw.entry.pane.id.0.to_string(),
            agent: "claude".into(),
            event: event.into(),
            seq: crate::hook_seq(),
            payload: json!({"session_id":SESSION,"prompt_id":prompt,"transcript_path":self.path,"cwd":self.raw.root.path(),"hook_event_name":event,"prompt":"fixture prompt"}),
        };
        relay(&self.raw.daemon, &request).await;
    }

    pub fn batch(&self, index: u64, delta: &str, is_final: bool) -> Value {
        json!({"session_id":SESSION,"prompt_id":PROMPT,"transcript_path":self.path,"cwd":self.raw.root.path(),"hook_event_name":"MessageDisplay","turn_id":"33333333-3333-4333-8333-333333333333","message_id":"44444444-4444-4444-8444-444444444444","index":index,"delta":delta,"final":is_final})
    }

    pub fn feed(&self, batch: Value) {
        let pane = self.raw.entry.pane.id;
        self.capture().receive(
            &self.raw.daemon.core,
            pane,
            &self.capture().token(pane),
            &serde_json::to_vec(&batch).unwrap(),
        );
    }

    pub async fn feed_http(&self, batch: Value) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let port =
            std::fs::read_to_string(self.raw.root.path().join("claude-display.port")).unwrap();
        let host = format!("127.0.0.1:{}", port.trim());
        let pane = self.raw.entry.pane.id;
        let token = self.capture().token(pane);
        let body = serde_json::to_vec(&batch).unwrap();
        let before = self.snapshot().unwrap().revision;
        let mut stream = tokio::net::TcpStream::connect(&host).await.unwrap();
        stream.write_all(format!("POST /claude/message-display HTTP/1.1\r\nHost: {host}\r\nAuthorization: Bearer {token}\r\nX-Gudo-Pane: {}\r\nContent-Length: {}\r\n\r\n", pane.0, body.len()).as_bytes()).await.unwrap();
        stream.write_all(&body).await.unwrap();
        let mut response = Vec::new();
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            stream.read_to_end(&mut response),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(response.starts_with(b"HTTP/1.1 200 OK\r\n"));
        assert!(response.ends_with(b"\r\n\r\n{}"));
        assert!(!String::from_utf8_lossy(&response).contains("displayContent"));
        crate::agent_input::chat_tests::wait_until(|| self.snapshot().unwrap().revision > before)
            .await;
    }

    pub fn snapshot(&self) -> Option<Snapshot> {
        self.capture()
            .snapshot(self.raw.entry.pane.id, &self.raw.entry, "fixture", SESSION)
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn admitted_prompt_is_required_and_display_never_changes_input_authority() {
    let fixture = Fixture::new().await;
    let revision = lock(&fixture.raw.entry.pane.agent_input_gate).control_revision();
    let ordinary = std::fs::read_to_string(fixture.raw.root.path().join("hook.token")).unwrap();
    fixture.capture().receive(
        &fixture.raw.daemon.core,
        fixture.raw.entry.pane.id,
        &ordinary,
        &serde_json::to_vec(&fixture.batch(0, "First line.\n", false)).unwrap(),
    );
    assert!(fixture.snapshot().unwrap().messages.is_empty());
    fixture.feed(fixture.batch(0, "First line.\n", false));
    assert_eq!(
        fixture.snapshot().unwrap().messages[0].text,
        "First line.\n"
    );
    assert_eq!(
        lock(&fixture.raw.entry.pane.agent_input_gate).control_revision(),
        revision
    );
    fixture.hook("UserPromptSubmit", "").await;
    assert!(fixture.snapshot().is_none());
    fixture.feed(fixture.batch(1, "Tail", true));
    assert!(fixture.snapshot().is_none());
    fixture.raw.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn context_mismatches_cannot_replace_the_admitted_scope() {
    let fixture = Fixture::new().await;
    for (field, value) in [
        ("session_id", json!("55555555-5555-4555-8555-555555555555")),
        ("prompt_id", json!("55555555-5555-4555-8555-555555555555")),
        ("transcript_path", json!("/fixture/other.jsonl")),
        ("cwd", json!("/fixture/other")),
    ] {
        let mut batch = fixture.batch(0, "wrong context\n", false);
        batch[field] = value;
        fixture.feed(batch);
        let snapshot = fixture.snapshot().unwrap();
        assert!(snapshot.is_usable);
        assert_eq!(snapshot.revision, 0);
        assert!(snapshot.messages.is_empty());
    }
    fixture.feed(fixture.batch(0, "right context\n", false));
    assert_eq!(
        fixture.snapshot().unwrap().messages[0].text,
        "right context\n"
    );
    fixture.raw.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn replacement_prompt_fences_late_batches_and_restarts_display_ordinals() {
    let fixture = Fixture::new().await;
    fixture.feed(fixture.batch(0, "old prompt\n", false));
    let prompt = "55555555-5555-4555-8555-555555555555";
    fixture.hook("UserPromptSubmit", prompt).await;
    fixture.feed(fixture.batch(1, "old tail", true));
    assert!(fixture.snapshot().unwrap().messages.is_empty());
    let mut batch = fixture.batch(0, "new prompt\n", false);
    batch["prompt_id"] = json!(prompt);
    fixture.feed(batch);
    let snapshot = fixture.snapshot().unwrap();
    assert_eq!(snapshot.prompt, prompt);
    assert_eq!(snapshot.messages[0].ordinal, 0);
    assert_eq!(snapshot.messages[0].text, "new prompt\n");
    fixture.raw.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn duplicates_are_idempotent_and_conflicts_disable_only_display() {
    let fixture = Fixture::new().await;
    let revision = lock(&fixture.raw.entry.pane.agent_input_gate).control_revision();
    let batch = fixture.batch(0, "First line.\n", false);
    fixture.feed(batch.clone());
    fixture.feed(batch);
    assert_eq!(fixture.snapshot().unwrap().revision, 1);
    fixture.feed(fixture.batch(0, "conflicting line\n", false));
    assert!(!fixture.snapshot().unwrap().is_usable);
    fixture.feed(fixture.batch(1, "Tail", true));
    assert_eq!(fixture.snapshot().unwrap().revision, 2);
    assert_eq!(
        lock(&fixture.raw.entry.pane.agent_input_gate).control_revision(),
        revision
    );
    fixture.raw.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn stop_is_not_a_display_lifetime_fence_but_launch_exit_is() {
    let fixture = Fixture::new().await;
    fixture.feed(fixture.batch(0, "First line.\n", false));
    fixture.hook("Stop", PROMPT).await;
    fixture.feed(fixture.batch(1, "Last line.", true));
    let snapshot = fixture.snapshot().unwrap();
    assert!(snapshot.messages[0].is_final);
    assert_eq!(snapshot.messages[0].text, "First line.\nLast line.");
    let core = &fixture.raw.daemon.core;
    let pane = fixture.raw.entry.pane.id;
    let call = crate::agent_input::AgentInputCall::Close {
        token: fixture.capture().token(pane),
        pane,
        launch: "fixture".into(),
    };
    assert_eq!(
        crate::agent_input::serve(core, call).await,
        crate::agent_input::AgentInputReply::Refused
    );
    let call = crate::agent_input::AgentInputCall::Close {
        token: core.hooks.pane_token(pane),
        pane,
        launch: "fixture".into(),
    };
    assert_eq!(
        crate::agent_input::serve(core, call).await,
        crate::agent_input::AgentInputReply::Closed
    );
    fixture.feed(fixture.batch(2, "unreachable", true));
    assert_eq!(fixture.snapshot().unwrap().revision, snapshot.revision);
    *lock(&fixture.raw.entry.pane.agent_input_gate) =
        crate::agent_input::AgentInputGate::pending("replacement".into());
    let call = crate::agent_input::AgentInputCall::Arm {
        token: core.hooks.pane_token(pane),
        pane,
        launch: "replacement".into(),
    };
    assert_eq!(
        crate::agent_input::serve(core, call).await,
        crate::agent_input::AgentInputReply::Ready
    );
    fixture.feed(fixture.batch(2, "unreachable in replacement", true));
    assert_eq!(fixture.snapshot().unwrap().revision, snapshot.revision);
    fixture.raw.daemon.shutdown().await;
}
