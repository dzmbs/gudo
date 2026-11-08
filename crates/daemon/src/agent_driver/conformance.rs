use std::collections::HashSet;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use agents::ApprovalChoice;
use client_core::Client;
use proto::{
    AgentKind, ChatSendStatus, PaneId, TimelineBody, TimelineOp, TimelineSnapshot,
    WorkspaceResponse,
};

use super::{AgentCapabilities, AgentSession, TimelineRead, driver};
use crate::agent_input::chat_tests::wait_until;
use crate::core::Core;

pub(super) type FixtureFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

pub(super) trait AdapterFixture: Send + Sync {
    fn core(&self) -> &Core;
    fn pane(&self) -> PaneId;
    fn client(&self) -> &Arc<Client>;
    fn received(&self) -> Vec<u8>;
    fn prompt_bytes(&self, text: &str) -> Vec<u8>;
    fn interrupt_bytes(&self) -> Vec<u8>;
    fn unconfirmed_send(&self) -> ChatSendStatus;
    fn type_draft<'a>(&'a self, text: &'a str) -> FixtureFuture<'a, ()>;
    fn append_bad_records(&self) {
        panic!("read capability needs malformed-record fixtures")
    }
    fn append_message(&self) {
        panic!("read capability needs append fixtures")
    }
    fn rotate(&self) {
        panic!("read capability needs rotation fixtures")
    }
    fn change_session(&self) {
        panic!("read capability needs identity fixtures")
    }
    fn acknowledge<'a>(&'a self, text: &'a str) -> FixtureFuture<'a, ()>;
    fn decide(&self, _: ApprovalChoice) -> FixtureFuture<'_, ApprovalChoice> {
        panic!("approval capability needs decision fixtures")
    }
    fn shutdown(self: Box<Self>) -> FixtureFuture<'static, ()>;
}

#[tokio::test(flavor = "multi_thread")]
async fn every_adapter_conforms_with_its_recorded_fixture() {
    for kind in [AgentKind::Claude, AgentKind::Codex] {
        let adapter = driver(kind);
        let fixture: Box<dyn AdapterFixture> = match kind {
            AgentKind::Claude => Box::new(super::claude::fixtures::Fixture::new().await),
            AgentKind::Codex => Box::new(super::terminal::fixtures::Fixture::new().await),
        };
        let (wake, _wakes) = tokio::sync::mpsc::channel(1);
        if !adapter.capabilities().contains(AgentCapabilities::READ) {
            assert!(
                adapter
                    .open(fixture.core(), fixture.pane(), 70, wake)
                    .is_err()
            );
            controls(fixture.as_ref(), adapter.capabilities()).await;
            fixture.shutdown().await;
            continue;
        }
        let mut session = adapter
            .open(fixture.core(), fixture.pane(), 70, wake)
            .unwrap();
        let snapshot = history(session.as_mut(), kind).await;
        updates(session.as_mut(), fixture.as_ref(), &snapshot);
        let output_handle = output(session.as_mut(), &snapshot).await;
        if adapter.capabilities().contains(AgentCapabilities::DIFFS) {
            recorded_diff(session.as_mut(), &snapshot).await;
        }
        rotation(session.as_mut(), fixture.as_ref(), output_handle).await;
        controls(fixture.as_ref(), adapter.capabilities()).await;
        identity_change(session.as_mut(), fixture.as_ref());
        drop(session);
        fixture.shutdown().await;
    }
}

async fn history(session: &mut dyn AgentSession, kind: AgentKind) -> TimelineSnapshot {
    let snapshot = session.snapshot(None);
    assert!(!snapshot.items.is_empty());
    assert!(snapshot.items.len() <= 100);
    assert_eq!(snapshot, session.snapshot(None));
    assert_eq!(snapshot.session.agent, kind);
    let before = snapshot.before.expect("fixture includes older history");
    let response = session
        .read(TimelineRead::ItemsBefore { before, limit: 100 }, None)
        .await
        .unwrap();
    let WorkspaceResponse::Timeline(page) = response else {
        panic!("history response")
    };
    assert_eq!(page.cursor.epoch, snapshot.cursor.epoch);
    assert!(!page.items.is_empty());
    let visible: HashSet<_> = snapshot.items.iter().map(|item| &item.id).collect();
    assert!(page.items.iter().all(|item| !visible.contains(&item.id)));
    assert!(
        session
            .snapshot(Some(proto::UnixMillis(u64::MAX)))
            .items
            .is_empty()
    );
    snapshot
}

fn updates(
    session: &mut dyn AgentSession,
    fixture: &dyn AdapterFixture,
    snapshot: &TimelineSnapshot,
) {
    fixture.append_bad_records();
    assert!(
        session
            .refresh(fixture.core(), fixture.pane())
            .unwrap()
            .is_empty()
    );
    assert_eq!(*snapshot, session.snapshot(None));
    fixture.append_message();
    let operations = session.refresh(fixture.core(), fixture.pane()).unwrap();
    assert!(
        operations
            .iter()
            .any(|operation| matches!(operation, TimelineOp::Upsert { .. }))
    );
    assert_eq!(session.cursor().epoch, snapshot.cursor.epoch);
    assert!(session.cursor().sequence > snapshot.cursor.sequence);
}

async fn output(session: &mut dyn AgentSession, snapshot: &TimelineSnapshot) -> String {
    let reference = snapshot
        .items
        .iter()
        .find_map(|item| match &item.body {
            TimelineBody::Tool(tool) => tool.output.as_ref(),
            _ => None,
        })
        .expect("fixture contains recorded tool output");
    let handle = reference.handle.to_string();
    let response = session
        .read(
            TimelineRead::ToolOutput {
                handle: handle.clone(),
                offset: 0,
                length: 4096,
            },
            None,
        )
        .await
        .unwrap();
    let WorkspaceResponse::TimelineOutput(page) = response else {
        panic!("output response")
    };
    assert!(!page.text.is_empty());
    handle
}

async fn recorded_diff(session: &mut dyn AgentSession, snapshot: &TimelineSnapshot) {
    let change = snapshot
        .items
        .iter()
        .find_map(|item| match &item.body {
            TimelineBody::Tool(tool) if !tool.diff.is_empty() => tool.output.as_ref(),
            _ => None,
        })
        .expect("diff capability requires a recorded change");
    let response = session
        .read(
            TimelineRead::ToolDiff {
                handle: change.handle.to_string(),
            },
            None,
        )
        .await
        .unwrap();
    let WorkspaceResponse::TimelineDiff(changes) = response else {
        panic!("diff response")
    };
    assert!(!changes.is_empty());
}

async fn rotation(
    session: &mut dyn AgentSession,
    fixture: &dyn AdapterFixture,
    old_handle: String,
) {
    let previous = session.cursor();
    let pending = session.read(
        TimelineRead::ToolOutput {
            handle: old_handle.clone(),
            offset: 0,
            length: 4096,
        },
        None,
    );
    fixture.rotate();
    let operations = session.refresh(fixture.core(), fixture.pane()).unwrap();
    assert!(matches!(operations.as_slice(), [TimelineOp::Snapshot(_)]));
    assert_ne!(session.cursor().epoch, previous.epoch);
    assert!(pending.await.is_ok());
    assert!(
        crate::timeline::validate_read(session, fixture.core(), fixture.pane(), previous.epoch)
            .is_err()
    );
    assert!(
        session
            .read(
                TimelineRead::ToolOutput {
                    handle: old_handle,
                    offset: 0,
                    length: 4096
                },
                None
            )
            .await
            .is_err()
    );
}

fn identity_change(session: &mut dyn AgentSession, fixture: &dyn AdapterFixture) {
    let previous = session.snapshot(None);
    fixture.change_session();
    assert!(
        session
            .check_current(fixture.core(), fixture.pane())
            .is_err()
    );
    let operations = session.refresh(fixture.core(), fixture.pane()).unwrap();
    assert!(matches!(operations.as_slice(), [TimelineOp::Snapshot(_)]));
    assert_ne!(
        session.snapshot(None).session.native_session,
        previous.session.native_session
    );
    assert_ne!(session.cursor().epoch, previous.cursor.epoch);
}

async fn controls(fixture: &dyn AdapterFixture, capabilities: AgentCapabilities) {
    if capabilities.contains(AgentCapabilities::SEND) {
        send(fixture, capabilities).await;
        draft_checks(fixture).await;
        send_without_receipt(fixture).await;
    }
    if capabilities.contains(AgentCapabilities::STOP) {
        fixture.acknowledge("working turn").await;
        stop(fixture).await;
    } else {
        let previous = fixture.received();
        assert!(
            fixture
                .client()
                .chat_interrupt_prepare(fixture.pane())
                .await
                .is_err()
        );
        assert_eq!(fixture.received(), previous);
    }
    if capabilities.contains(AgentCapabilities::APPROVALS) {
        for choice in [ApprovalChoice::AllowOnce, ApprovalChoice::Deny] {
            let previous = fixture.received();
            assert_eq!(fixture.decide(choice).await, choice);
            assert_eq!(
                fixture.received(),
                previous,
                "signed choices must not become terminal text"
            );
        }
    }
}

async fn send(fixture: &dyn AdapterFixture, capabilities: AgentCapabilities) {
    let pane = fixture.pane();
    let text = "conformance prompt";
    let ChatSendStatus::Prepared {
        ticket,
        revision,
        needs_confirmation,
    } = fixture.client().chat_prepare(pane).await.unwrap()
    else {
        panic!("prompt ticket")
    };
    let previous = fixture.received().len();
    let client = Arc::clone(fixture.client());
    let pending = tokio::spawn(async move {
        client
            .chat_send(
                pane,
                ticket,
                text.into(),
                needs_confirmation.then_some(revision),
            )
            .await
    });
    wait_until(|| fixture.received().len() > previous).await;
    fixture.acknowledge(text).await;
    let result = pending.await.unwrap().unwrap();
    if capabilities.contains(AgentCapabilities::ACKNOWLEDGED_SEND) {
        assert_eq!(result, ChatSendStatus::Confirmed);
    }
    assert_eq!(&fixture.received()[previous..], fixture.prompt_bytes(text));
    let replay = fixture
        .client()
        .chat_send(pane, ticket, text.into(), None)
        .await;
    assert!(matches!(replay, Err(_) | Ok(ChatSendStatus::NotConfirmed)));
    assert_eq!(&fixture.received()[previous..], fixture.prompt_bytes(text));
}

async fn draft_checks(fixture: &dyn AdapterFixture) {
    let pane = fixture.pane();
    fixture.type_draft("unsent draft").await;
    let ChatSendStatus::Prepared {
        ticket,
        revision,
        needs_confirmation,
    } = fixture.client().chat_prepare(pane).await.unwrap()
    else {
        panic!("draft ticket")
    };
    assert!(needs_confirmation);
    let before = fixture.received();
    assert_eq!(
        fixture
            .client()
            .chat_send(pane, ticket, "pending".into(), None)
            .await
            .unwrap(),
        ChatSendStatus::ConfirmationRequired { revision }
    );
    assert_eq!(fixture.received(), before);
    fixture.type_draft("more input").await;
    let before = fixture.received();
    let ChatSendStatus::ConfirmationRequired { revision: current } = fixture
        .client()
        .chat_send(pane, ticket, "pending".into(), Some(revision))
        .await
        .unwrap()
    else {
        panic!("stale consent admitted")
    };
    assert!(current > revision);
    assert_eq!(fixture.received(), before);
}

async fn send_without_receipt(fixture: &dyn AdapterFixture) {
    let pane = fixture.pane();
    let text = "prompt without acknowledgement";
    let ChatSendStatus::Prepared {
        ticket,
        revision,
        needs_confirmation,
    } = fixture.client().chat_prepare(pane).await.unwrap()
    else {
        panic!("prompt ticket")
    };
    let previous = fixture.received().len();
    let result = fixture
        .client()
        .chat_send(
            pane,
            ticket,
            text.into(),
            needs_confirmation.then_some(revision),
        )
        .await
        .unwrap();
    assert_eq!(result, fixture.unconfirmed_send());
    assert_eq!(&fixture.received()[previous..], fixture.prompt_bytes(text));
}

async fn stop(fixture: &dyn AdapterFixture) {
    let pane = fixture.pane();
    let ChatSendStatus::Prepared {
        ticket,
        revision,
        needs_confirmation,
    } = fixture.client().chat_interrupt_prepare(pane).await.unwrap()
    else {
        panic!("interrupt ticket")
    };
    let previous = fixture.received().len();
    assert_eq!(
        fixture
            .client()
            .chat_interrupt(pane, ticket, needs_confirmation.then_some(revision))
            .await
            .unwrap(),
        ChatSendStatus::InterruptRequested
    );
    wait_until(|| fixture.received().len() > previous).await;
    assert_eq!(&fixture.received()[previous..], fixture.interrupt_bytes());
    assert_eq!(
        fixture
            .client()
            .chat_interrupt(pane, ticket, None)
            .await
            .unwrap(),
        ChatSendStatus::NotConfirmed
    );
    assert_eq!(&fixture.received()[previous..], fixture.interrupt_bytes());
}
