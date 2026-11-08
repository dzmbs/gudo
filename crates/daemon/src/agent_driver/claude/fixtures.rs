use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;

use agents::ApprovalChoice;
use client_core::Client;
use proto::PaneId;
use serde_json::Value;

use crate::agent_driver::conformance::{AdapterFixture, FixtureFuture};
use crate::agent_input::chat_tests::{
    RawFixture, raw_fixture_with_session, relay, relay_at, wait_until,
};
use crate::core::{Core, lock};

const SESSION: &str = "0b3bb01e-c7ff-4c07-b983-2dc15e6e1755";
const REPLACEMENT: &str = "0b3bb01e-c7ff-4c07-b983-2dc15e6e1756";
const RECORDING: &str = include_str!("../../../tests/fixtures/timeline/claude-2.1.318.jsonl");
const PROMPT: &str = include_str!(
    "../../../../agents/tests/fixtures/claude/captured-2.1.302/user_prompt_submit.json"
);
const PERMISSION: &str =
    include_str!("../../../../agents/tests/fixtures/claude/permission_request.json");

pub(crate) struct Fixture {
    raw: RawFixture,
    path: PathBuf,
}

impl Fixture {
    pub async fn new() -> Self {
        let raw = raw_fixture_with_session(SESSION).await;
        let configuration = raw.root.path().join("agent");
        let working = lock(&raw.entry.record)
            .cwd
            .clone()
            .map(PathBuf::from)
            .unwrap_or_else(|| raw.daemon.core.cfg.home());
        let directory = crate::claude_session::project_dir(&configuration, &working);
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join(format!("{SESSION}.jsonl"));
        let mut data = String::new();
        let mut record: Value = serde_json::from_str(RECORDING.lines().next().unwrap()).unwrap();
        for index in 0..150 {
            record["uuid"] = format!("older-{index}").into();
            data.push_str(&record.to_string());
            data.push('\n');
        }
        data.push_str(RECORDING);
        std::fs::write(&path, data).unwrap();
        Self { raw, path }
    }

    fn hook(&self, event: &str, mut payload: Value) -> crate::HookRequest {
        payload["session_id"] = SESSION.into();
        payload["cwd"] = self.raw.root.path().display().to_string().into();
        payload["transcript_path"] = self.path.display().to_string().into();
        crate::HookRequest {
            v: 1,
            token: std::fs::read_to_string(self.raw.root.path().join("hook.token")).unwrap(),
            pane: self.pane().0.to_string(),
            agent: "claude".into(),
            event: event.into(),
            seq: crate::hook_seq(),
            payload,
        }
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
        vec![0x1b]
    }
    fn unconfirmed_send(&self) -> proto::ChatSendStatus {
        proto::ChatSendStatus::NotConfirmed
    }

    fn type_draft<'a>(&'a self, text: &'a str) -> FixtureFuture<'a, ()> {
        Box::pin(self.raw.type_draft(text))
    }

    fn append_bad_records(&self) {
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&self.path)
            .unwrap();
        file.write_all(b"{malformed\n{\"type\":\"unknown-future-record\"}\n")
            .unwrap();
    }

    fn append_message(&self) {
        let mut record: Value = serde_json::from_str(RECORDING.lines().next().unwrap()).unwrap();
        record["uuid"] = "appended-message".into();
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&self.path)
            .unwrap();
        writeln!(file, "{record}").unwrap();
    }

    fn rotate(&self) {
        std::fs::rename(&self.path, self.path.with_extension("rotated")).unwrap();
        std::fs::write(&self.path, RECORDING).unwrap();
    }

    fn change_session(&self) {
        std::fs::write(
            self.path.with_file_name(format!("{REPLACEMENT}.jsonl")),
            RECORDING,
        )
        .unwrap();
        let mut record = lock(&self.raw.entry.record);
        record.agent.as_mut().unwrap().session_id = Some(REPLACEMENT.into());
        drop(record);
        *lock(&self.raw.entry.agent) = Some(crate::agent::AgentRuntime::new(
            proto::AgentKind::Claude,
            self.pane(),
            crate::agent::adapter(proto::AgentKind::Claude),
            false,
        ));
    }

    fn acknowledge<'a>(&'a self, text: &'a str) -> FixtureFuture<'a, ()> {
        Box::pin(async move {
            let mut payload: Value = serde_json::from_str(PROMPT).unwrap();
            payload["prompt"] = text.into();
            relay(&self.raw.daemon, &self.hook("UserPromptSubmit", payload)).await;
        })
    }

    fn decide(&self, choice: ApprovalChoice) -> FixtureFuture<'_, ApprovalChoice> {
        Box::pin(async move {
            self.acknowledge("approval turn").await;
            let payload: Value = serde_json::from_str(PERMISSION).unwrap();
            let request = self.hook("PermissionRequest", payload);
            let socket = self.raw.daemon.hook_socket().to_owned();
            let waiting = tokio::spawn(async move { relay_at(&socket, &request).await });
            wait_until(|| {
                lock(&self.raw.entry.agent)
                    .as_ref()
                    .is_some_and(|runtime| runtime.is_blocked())
            })
            .await;
            let (approval, native, _) = lock(&self.raw.entry.agent)
                .as_mut()
                .unwrap()
                .blocked_wire()
                .unwrap();
            crate::agent_driver::conformance::pending_metadata(self.core(), self.pane(), &native);
            let option = match choice {
                ApprovalChoice::AllowOnce => 0,
                ApprovalChoice::AllowSession => 1,
                ApprovalChoice::Deny => 2,
            };
            self.raw.client.decide(approval, proto::OptionId(option));
            let response = tokio::time::timeout(std::time::Duration::from_secs(10), waiting)
                .await
                .unwrap()
                .unwrap();
            let response: Value =
                serde_json::from_str(response.stdout.as_deref().unwrap()).unwrap();
            assert!(!crate::agent_driver::approval_is_pending(
                self.core(),
                self.pane(),
                &native
            ));
            match response["hookSpecificOutput"]["decision"]["behavior"].as_str() {
                Some("allow") => ApprovalChoice::AllowOnce,
                Some("deny") => ApprovalChoice::Deny,
                _ => panic!("unexpected approval response"),
            }
        })
    }

    fn shutdown(self: Box<Self>) -> FixtureFuture<'static, ()> {
        Box::pin(async move { self.raw.daemon.shutdown().await })
    }
}
