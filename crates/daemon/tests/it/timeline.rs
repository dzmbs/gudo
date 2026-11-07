use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

use client_core::grants::GrantSpec;
use client_core::proto::{
    History, InviteTerms, PaneId, Roles, Scope, TimelineBody, TimelineOp, TimelineUpdate,
    WorkspaceRequest, WorkspaceResponse, WsError,
};
use client_core::{ClientConfig, WorkspaceEvent, WorkspaceEventQueue};
use daemon::{Daemon, HookRequest};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::mpsc::UnboundedReceiver;

use crate::support::{TestClient, start_with, ticket};

const SESSION: &str = "0b3bb01e-c7ff-4c07-b983-2dc15e6e1755";
const FIXTURE: &str = include_str!("../fixtures/timeline/claude-2.1.318.jsonl");

struct Harness {
    root: tempfile::TempDir,
    daemon: Daemon,
    owner: TestClient,
    pane: PaneId,
    transcript: PathBuf,
}

impl Harness {
    async fn start() -> Self {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let home = home.canonicalize().unwrap();
        let state = root.path().join("state");
        std::os::unix::fs::symlink("/bin/sleep", home.join("claude")).unwrap();
        let config_home = home.clone();
        let daemon = start_with(&state, move |config| {
            config
                .pane_env
                .push(("HOME".into(), config_home.to_string_lossy().into_owned()));
            config.fs_allow.push(config_home);
        })
        .await;
        let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
        let pane = owner.attach_and_follow().await;
        owner.type_line(pane, &format!("{} 120", home.join("claude").display()));
        owner
            .until("agent tracked", |owner| {
                owner
                    .metas
                    .get(&pane)
                    .is_some_and(|meta| meta.agent.is_some())
            })
            .await;
        let transcript = home
            .join(".claude/projects/test")
            .join(format!("{SESSION}.jsonl"));
        std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
        let mut file = std::fs::File::create(&transcript).unwrap();
        for line in FIXTURE.lines() {
            let mut record: Value = serde_json::from_str(line).unwrap();
            record["timestamp"] = json!("2000-01-01T00:00:00Z");
            writeln!(file, "{record}").unwrap();
        }
        let token = std::fs::read_to_string(state.join("hook.token")).unwrap();
        let request = HookRequest {
            v: 1,
            token,
            pane: pane.0.to_string(),
            agent: "claude".into(),
            event: "SessionStart".into(),
            seq: daemon::hook_seq(),
            payload: json!({"hook_event_name":"SessionStart","session_id":SESSION,"transcript_path":transcript,"cwd":home,"source":"startup"}),
        };
        let mut stream = UnixStream::connect(daemon.hook_socket()).await.unwrap();
        let mut bytes = serde_json::to_vec(&request).unwrap();
        bytes.push(b'\n');
        stream.write_all(&bytes).await.unwrap();
        let mut response = String::new();
        BufReader::new(stream)
            .read_line(&mut response)
            .await
            .unwrap();
        assert!(serde_json::from_str::<daemon::HookResponse>(&response).is_ok());
        Self {
            root,
            daemon,
            owner,
            pane,
            transcript,
        }
    }

    fn append(&self, id: &str, text: &str) {
        let record = json!({"type":"assistant","uuid":id,"sessionId":SESSION,"timestamp":"2099-01-01T00:00:00Z","message":{"id":id,"model":"claude-sonnet-4-6","content":[{"type":"text","text":text}]}});
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&self.transcript)
            .unwrap();
        writeln!(file, "{record}").unwrap();
    }

    async fn guest(&self, history: History) -> TestClient {
        let terms = InviteTerms {
            knock: false,
            history,
        };
        let invite = self
            .owner
            .client
            .create_invite_with_terms(
                GrantSpec::new(Roles::VIEWER, Scope::Pane(self.pane)),
                "owner".into(),
                terms,
            )
            .await
            .unwrap()
            .to_string_with_terms(terms);
        let mut guest = TestClient::join(&invite, ClientConfig::generate_key());
        guest
            .until("guest joined", |guest| guest.connected > 0)
            .await;
        guest
    }

    async fn shutdown(self) {
        drop(self.owner);
        self.daemon.shutdown().await;
        drop(self.root);
    }
}

async fn next_update(
    events: &mut UnboundedReceiver<WorkspaceEvent>,
    mut matches: impl FnMut(&TimelineUpdate) -> bool,
) -> TimelineUpdate {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            if let WorkspaceEvent::Timeline { update } = events.recv().await.unwrap()
                && matches(&update)
            {
                return update;
            }
        }
    })
    .await
    .expect("timeline update")
}

fn contains(update: &TimelineUpdate, text: &str) -> bool {
    update.operations.iter().any(|operation| match operation {
        TimelineOp::Upsert { item, .. } => matches!(&item.body, TimelineBody::Assistant { text: actual, .. } if actual == text),
        TimelineOp::Snapshot(snapshot) => snapshot.items.iter().any(|item| matches!(&item.body, TimelineBody::Assistant { text: actual, .. } if actual == text)),
        _ => false,
    })
}

#[tokio::test(flavor = "multi_thread")]
async fn two_clients_mirror_one_transcript_and_fetch_output_over_the_real_protocol() {
    let harness = Harness::start().await;
    let (listener, mut first_events) = WorkspaceEventQueue::channel();
    harness.owner.client.set_workspace_listener(listener);
    let first = harness
        .owner
        .client
        .timeline_watch(harness.pane)
        .await
        .unwrap();
    assert_eq!(first.items.len(), 8);
    assert_eq!(first.session.native_session, SESSION);
    let mut second = TestClient::connect(&ticket(&harness.daemon), ClientConfig::generate_key());
    second
        .until("second owner", |second| second.connected > 0)
        .await;
    let (listener, mut second_events) = WorkspaceEventQueue::channel();
    second.client.set_workspace_listener(listener);
    let snapshot = second.client.timeline_watch(harness.pane).await.unwrap();
    assert_eq!(first.cursor, snapshot.cursor);
    let shell = first
        .items
        .iter()
        .find(|item| item.id == "toolu_fixture_bash")
        .unwrap();
    let TimelineBody::Tool(tool) = &shell.body else {
        panic!()
    };
    let output = harness
        .owner
        .client
        .timeline_tool_output(
            harness.pane,
            tool.output.as_ref().unwrap().handle.to_string(),
            0,
            4096,
        )
        .await
        .unwrap();
    assert_eq!(output.text, "fixture output");
    harness.append("from-terminal", "Written in the same session");
    let first = next_update(&mut first_events, |update| {
        contains(update, "Written in the same session")
    })
    .await;
    let second_update = next_update(&mut second_events, |update| {
        contains(update, "Written in the same session")
    })
    .await;
    assert_eq!(first, second_update);
    second.client.timeline_unwatch(harness.pane).await.unwrap();
    assert!(matches!(
        second
            .client
            .timeline_items_before(harness.pane, 1, 100)
            .await,
        Err(WsError::Unavailable(_))
    ));
    harness.append("still-running", "The other view stays connected");
    next_update(&mut first_events, |update| {
        contains(update, "The other view stays connected")
    })
    .await;
    drop(second);
    harness.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_scoped_viewer_can_read_only_its_pane_and_since_join_history() {
    let harness = Harness::start().await;
    let owner_snapshot = harness
        .owner
        .client
        .timeline_watch(harness.pane)
        .await
        .unwrap();
    let shell = owner_snapshot
        .items
        .iter()
        .find(|item| item.id == "toolu_fixture_bash")
        .unwrap();
    let TimelineBody::Tool(tool) = &shell.body else {
        panic!()
    };
    let old_output = tool.output.as_ref().unwrap().handle.to_string();
    let guest = harness.guest(History::SinceJoin).await;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    guest.client.set_workspace_listener(listener);
    let snapshot = guest.client.timeline_watch(harness.pane).await.unwrap();
    assert!(snapshot.items.is_empty());
    assert!(matches!(
        guest
            .client
            .timeline_tool_output(harness.pane, old_output, 0, 4096)
            .await,
        Err(WsError::Denied(_))
    ));
    assert!(matches!(
        guest
            .client
            .timeline_watch(PaneId(harness.pane.0 + 1000))
            .await,
        Err(WsError::Denied(_))
    ));
    assert!(matches!(
        guest
            .client
            .workspace(WorkspaceRequest::TimelineUnwatch {
                pane_id: PaneId(harness.pane.0 + 1000)
            })
            .await,
        Err(WsError::Denied(_))
    ));
    harness.append("new-visible", "Visible after joining");
    let update = next_update(&mut events, |update| {
        contains(update, "Visible after joining")
    })
    .await;
    assert_eq!(update.pane_id, harness.pane);
    if let WorkspaceResponse::Timeline(snapshot) = guest
        .client
        .workspace(WorkspaceRequest::TimelineWatch {
            pane_id: harness.pane,
        })
        .await
        .unwrap()
    {
        assert_eq!(snapshot.items.len(), 1);
        assert_eq!(snapshot.items[0].id, "new-visible:0");
    } else {
        panic!("timeline snapshot");
    }
    drop(guest);
    harness.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_full_history_viewer_receives_the_same_window_as_the_owner() {
    let harness = Harness::start().await;
    let guest = harness.guest(History::Full).await;
    let owner = harness
        .owner
        .client
        .timeline_watch(harness.pane)
        .await
        .unwrap();
    let viewer = guest.client.timeline_watch(harness.pane).await.unwrap();
    assert_eq!(owner, viewer);
    drop(guest);
    harness.shutdown().await;
}
