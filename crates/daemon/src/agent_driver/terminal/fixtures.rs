use std::sync::Arc;

use client_core::Client;
use proto::{ChatSendStatus, PaneId};
use serde_json::Value;

use crate::agent_driver::conformance::{AdapterFixture, FixtureFuture};
use crate::agent_input::chat_tests::{RawFixture, raw_fixture, relay};
use crate::core::{Core, lock};

const RECORDING: &str =
    include_str!("../../../../agents/tests/fixtures/codex/notify_agent_turn_complete.json");

pub(crate) struct Fixture {
    raw: RawFixture,
}

impl Fixture {
    pub async fn new() -> Self {
        let raw = raw_fixture().await;
        *lock(&raw.entry.agent) = Some(crate::agent::AgentRuntime::new(
            proto::AgentKind::Codex,
            raw.entry.pane.id,
            crate::agent::adapter(proto::AgentKind::Codex),
            false,
        ));
        raw.reset_input("terminal fixture");
        let fixture = Self { raw };
        fixture.acknowledge("previous").await;
        fixture
    }
}

impl AdapterFixture for Fixture {
    fn core(&self) -> &Core {
        &self.raw.daemon.core
    }
    fn pane(&self) -> PaneId {
        self.raw.entry.pane.id
    }
    fn client(&self) -> &Arc<Client> {
        &self.raw.client
    }
    fn received(&self) -> Vec<u8> {
        std::fs::read(&self.raw.captured).unwrap_or_default()
    }
    fn prompt_bytes(&self, text: &str) -> Vec<u8> {
        format!("\x1b[200~{text}\x1b[201~\r").into_bytes()
    }
    fn interrupt_bytes(&self) -> Vec<u8> {
        Vec::new()
    }
    fn unconfirmed_send(&self) -> ChatSendStatus {
        ChatSendStatus::SentNotConfirmed
    }

    fn type_draft<'a>(&'a self, text: &'a str) -> FixtureFuture<'a, ()> {
        Box::pin(self.raw.type_draft(text))
    }

    fn acknowledge<'a>(&'a self, text: &'a str) -> FixtureFuture<'a, ()> {
        Box::pin(async move {
            let mut payload: Value = serde_json::from_str(RECORDING).unwrap();
            payload["input-messages"] = serde_json::json!([text]);
            let request = crate::HookRequest {
                v: 1,
                token: std::fs::read_to_string(self.raw.root.path().join("hook.token")).unwrap(),
                pane: self.pane().0.to_string(),
                agent: "codex".into(),
                event: crate::CODEX_NOTIFY_EVENT.into(),
                seq: crate::hook_seq(),
                payload,
            };
            relay(&self.raw.daemon, &request).await;
        })
    }

    fn shutdown(self: Box<Self>) -> FixtureFuture<'static, ()> {
        Box::pin(async move { self.raw.daemon.shutdown().await })
    }
}
