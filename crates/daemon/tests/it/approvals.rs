//! Approval extras end to end (`proto::approve`): approving with an edited command, and
//! "approve all like this for this task" rules scoped by pane, match, turns, time and role.

use std::time::Duration;

use client_core::proto::{
    AgentState, ApprovalError, AuditKind, Blocker, OptionId, PaneId, RequestId, Roles, RuleMatch,
    Scope, UnixMillis,
};
use client_core::{ApprovalEvent, ApprovalEventQueue, ClientConfig, GrantSpec, now_millis};
use daemon::{Daemon, HookRequest, HookResponse};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::task::JoinHandle;

use crate::support::{TestClient, start, ticket};

async fn hook(socket: std::path::PathBuf, request: HookRequest) -> HookResponse {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(&request).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
    serde_json::from_str(&answer).unwrap()
}

/// Sends Claude hook events for one pane, with increasing sequence numbers.
struct Agent {
    dir: std::path::PathBuf,
    socket: std::path::PathBuf,
    pane: PaneId,
    seq: u64,
}

impl Agent {
    fn new(dir: &std::path::Path, daemon: &Daemon, pane: PaneId) -> Self {
        Self {
            dir: dir.to_owned(),
            socket: daemon.hook_socket().to_owned(),
            pane,
            seq: 0,
        }
    }

    fn request(&mut self, event: &str, payload: Value) -> HookRequest {
        self.seq += 1;
        HookRequest {
            v: 1,
            token: std::fs::read_to_string(self.dir.join("hook.token")).unwrap(),
            pane: self.pane.0.to_string(),
            agent: "claude".into(),
            event: event.into(),
            seq: self.seq,
            payload,
        }
    }

    /// Asks to run `tool` with `input`; the task ends when the hook is answered.
    fn ask(&mut self, tool: &str, input: Value) -> JoinHandle<HookResponse> {
        let request = self.request(
            "PermissionRequest",
            json!({
                "session_id": "s1",
                "hook_event_name": "PermissionRequest",
                "cwd": "/tmp",
                "tool_name": tool,
                "tool_input": input,
            }),
        );
        tokio::spawn(hook(self.socket.clone(), request))
    }

    fn bash(&mut self, command: &str) -> JoinHandle<HookResponse> {
        self.ask(
            "Bash",
            json!({ "command": command, "description": "a test" }),
        )
    }

    /// The turn ends and the next prompt starts one.
    async fn turn(&mut self) {
        self.event("Stop").await;
        self.event("UserPromptSubmit").await;
    }

    async fn event(&mut self, event: &str) {
        let request = self.request(
            event,
            json!({ "session_id": "s1", "hook_event_name": event, "cwd": "/tmp" }),
        );
        hook(self.socket.clone(), request).await;
    }
}

fn blocked(client: &TestClient, pane: PaneId) -> Option<Blocker> {
    match client.metas.get(&pane)?.agent.clone()?.state {
        AgentState::Blocked(blocker) => Some(blocker),
        _ => None,
    }
}

async fn answered(waiting: JoinHandle<HookResponse>) -> Value {
    let response = tokio::time::timeout(Duration::from_secs(10), waiting)
        .await
        .expect("hook answered")
        .unwrap();
    serde_json::from_str(&response.stdout.expect("an answer")).unwrap()
}

/// Waits for the daemon's extras for the open request `request`.
async fn info(
    client: &mut TestClient,
    pane: PaneId,
    request: RequestId,
) -> client_core::proto::ApprovalInfo {
    client
        .until("approval info", |client| {
            client
                .client
                .approval_info(pane)
                .is_some_and(|open| open.request_id == request)
        })
        .await;
    client.client.approval_info(pane).unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn an_edited_command_runs_instead_and_is_audited() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let mut agent = Agent::new(dir.path(), &daemon, pane);

    let waiting = agent.bash("rm -rf node_modules");
    owner
        .until("blocked", |owner| blocked(owner, pane).is_some())
        .await;
    let blocker = blocked(&owner, pane).unwrap();
    let info = info(&mut owner, pane, blocker.request_id).await;
    assert_eq!(info.tool, "Bash");
    assert_eq!(info.input.as_deref(), Some("rm -rf node_modules"));
    assert_eq!(
        info.like,
        Some(RuleMatch {
            tool: "Bash".into(),
            prefix: "rm".into()
        })
    );

    // Only the allow option may carry an edit.
    let deny = OptionId(blocker.options.len() as u32 - 1);
    assert!(matches!(
        owner
            .client
            .approve_edited(blocker.request_id, deny, "rm -rf build".into())
            .await,
        Err(ApprovalError::Invalid(_))
    ));
    owner
        .client
        .approve_edited(blocker.request_id, OptionId(0), "rm -rf build".into())
        .await
        .expect("edited approval");
    let answer = answered(waiting).await;
    let decision = &answer["hookSpecificOutput"]["decision"];
    assert_eq!(decision["behavior"], "allow", "{answer}");
    assert_eq!(decision["updatedInput"]["command"], "rm -rf build");
    assert_eq!(decision["updatedInput"]["description"], "a test");

    let page = owner.client.audit(None, 100).await.unwrap();
    let record = page
        .records
        .iter()
        .find(|record| record.kind == AuditKind::Approval)
        .expect("audited");
    assert!(
        record.detail.contains("rm -rf node_modules") && record.detail.contains("rm -rf build"),
        "{}",
        record.detail
    );

    // A tool without editable input says so.
    let waiting = agent.ask("Edit", json!({ "file_path": "/tmp/x", "old_string": "a" }));
    owner
        .until("blocked on Edit", |owner| {
            blocked(owner, pane).is_some_and(|held| held.request_id != blocker.request_id)
        })
        .await;
    let edit = blocked(&owner, pane).unwrap();
    let info = self::info(&mut owner, pane, edit.request_id).await;
    assert_eq!(info.input, None);
    assert_eq!(
        owner
            .client
            .approve_edited(edit.request_id, OptionId(0), "x".into())
            .await,
        Err(ApprovalError::NotEditable)
    );
    owner.client.decide(edit.request_id, OptionId(0));
    answered(waiting).await;
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_rule_approves_requests_like_this_until_revoked() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let (listener, mut events) = ApprovalEventQueue::channel();
    owner.client.set_approval_listener(listener);
    let pane = owner.attach_and_follow().await;
    let mut agent = Agent::new(dir.path(), &daemon, pane);

    // "Approve all like this": the rule answers the open request too.
    let waiting = agent.bash("cargo test -p proto");
    owner
        .until("blocked", |owner| blocked(owner, pane).is_some())
        .await;
    let first = blocked(&owner, pane).unwrap();
    let info = info(&mut owner, pane, first.request_id).await;
    let like = info.like.expect("a rule is offered");
    assert_eq!(like.prefix, "cargo test");
    let rule = owner
        .client
        .add_auto_approve(
            pane,
            Some(first.request_id),
            like,
            Duration::from_secs(600),
            5,
        )
        .await
        .expect("rule added");
    assert_eq!(
        answered(waiting).await["hookSpecificOutput"]["decision"]["behavior"],
        "allow"
    );

    // The next request like it is answered with nobody deciding.
    let answer = answered(agent.bash("cargo test --workspace")).await;
    assert_eq!(
        answer["hookSpecificOutput"]["decision"]["behavior"],
        "allow"
    );
    owner
        .until("two uses", |owner| {
            owner
                .client
                .auto_approve_rules(pane)
                .first()
                .is_some_and(|rule| rule.uses == 2)
        })
        .await;
    let mut saw_rules = false;
    while let Ok(event) = events.try_recv() {
        saw_rules |= matches!(event, ApprovalEvent::Rules { pane_id, rules } if pane_id == pane && !rules.is_empty());
    }
    assert!(saw_rules, "the listener heard about the rule");

    // Not like it: another command, or this one chained with something else.
    let mut seen = vec![first.request_id];
    for command in ["cargo build", "cargo test && rm -rf ~"] {
        let waiting = agent.bash(command);
        // The daemon tells clients about a request only once no rule answered it.
        owner
            .until("blocked again", |owner| {
                owner.client.approval_info(pane).is_some_and(|open| {
                    !seen.contains(&open.request_id)
                        && blocked(owner, pane)
                            .is_some_and(|held| held.request_id == open.request_id)
                })
            })
            .await;
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(!waiting.is_finished(), "{command} was approved by the rule");
        let held = blocked(&owner, pane).unwrap();
        seen.push(held.request_id);
        owner
            .client
            .decide(held.request_id, OptionId(held.options.len() as u32 - 1));
        assert_eq!(
            answered(waiting).await["hookSpecificOutput"]["decision"]["behavior"],
            "deny"
        );
    }

    // The auto-approvals are in the audit log with the rule's signature.
    let page = owner.client.audit(None, 100).await.unwrap();
    let auto = page
        .records
        .iter()
        .find(|record| {
            record.kind == AuditKind::Approval && record.detail.starts_with("auto-approved")
        })
        .expect("auto-approval audited");
    let approval = auto.approval.as_ref().unwrap();
    assert!(client_core::grants::verify_signature(
        auto.actor.unwrap().device,
        &approval.signed,
        &approval.sig
    ));

    // Revoked, it approves nothing.
    owner
        .client
        .revoke_auto_approve(rule)
        .await
        .expect("revoked");
    owner
        .until("no rules", |owner| {
            owner.client.auto_approve_rules(pane).is_empty()
        })
        .await;
    assert_eq!(
        owner.client.revoke_auto_approve(rule).await,
        Err(ApprovalError::NotFound)
    );
    let waiting = agent.bash("cargo test");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!waiting.is_finished(), "a revoked rule approved");
    owner
        .until("asked again", |owner| {
            owner
                .client
                .approval_info(pane)
                .is_some_and(|open| !seen.contains(&open.request_id))
        })
        .await;
    let asked = owner.client.approval_info(pane).unwrap();
    owner.client.decide(asked.request_id, OptionId(0));
    answered(waiting).await;
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn rules_end_with_their_turns_time_and_session() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let mut agent = Agent::new(dir.path(), &daemon, pane);
    agent.event("UserPromptSubmit").await;
    let ls = RuleMatch {
        tool: "Bash".into(),
        prefix: "ls".into(),
    };

    // One turn: the next prompt ends it.
    owner
        .client
        .add_auto_approve(pane, None, ls.clone(), Duration::from_secs(600), 1)
        .await
        .unwrap();
    owner
        .until("rule", |owner| {
            !owner.client.auto_approve_rules(pane).is_empty()
        })
        .await;
    agent.turn().await;
    owner
        .until("turn limit", |owner| {
            owner.client.auto_approve_rules(pane).is_empty()
        })
        .await;

    // Two turns: still there after one more prompt, with the count.
    owner
        .client
        .add_auto_approve(pane, None, ls.clone(), Duration::from_secs(600), 2)
        .await
        .unwrap();
    agent.turn().await;
    owner
        .until("second turn counted", |owner| {
            owner
                .client
                .auto_approve_rules(pane)
                .first()
                .is_some_and(|rule| rule.turns_used == 2)
        })
        .await;
    // The agent session ending ends it.
    agent.event("SessionEnd").await;
    owner
        .until("session over", |owner| {
            owner.client.auto_approve_rules(pane).is_empty()
        })
        .await;

    // Expired, it approves nothing.
    agent.event("SessionStart").await;
    agent.event("UserPromptSubmit").await;
    owner
        .client
        .add_auto_approve(pane, None, ls, Duration::from_millis(800), 5)
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(1200)).await;
    let waiting = agent.bash("ls -la");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!waiting.is_finished(), "an expired rule approved");
    owner
        .until("asked", |owner| owner.client.approval_info(pane).is_some())
        .await;
    let asked = owner.client.approval_info(pane).unwrap();
    owner.client.decide(asked.request_id, OptionId(0));
    answered(waiting).await;

    // Wider than allowed: refused.
    assert!(matches!(
        owner
            .client
            .add_auto_approve(
                pane,
                None,
                RuleMatch {
                    tool: "Bash".into(),
                    prefix: String::new()
                },
                Duration::from_secs(60),
                1
            )
            .await,
        Err(ApprovalError::Invalid(_))
    ));
    assert!(matches!(
        owner
            .client
            .add_auto_approve(
                pane,
                None,
                RuleMatch {
                    tool: "Bash".into(),
                    prefix: "ls".into()
                },
                Duration::from_secs(9 * 3600),
                1
            )
            .await,
        Err(ApprovalError::Invalid(_))
    ));
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_viewer_cannot_add_or_revoke_rules() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let mut agent = Agent::new(dir.path(), &daemon, pane);
    agent.event("UserPromptSubmit").await;

    let mut spec = GrantSpec::new(Roles::VIEWER, Scope::Daemon);
    spec.label = "vic".into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "alice".into())
        .await
        .unwrap();
    let mut viewer = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    viewer.client.attach(None);
    viewer
        .until("guest layout", |owner| owner.layout.is_some())
        .await;

    let ls = RuleMatch {
        tool: "Bash".into(),
        prefix: "ls".into(),
    };
    assert!(matches!(
        viewer
            .client
            .add_auto_approve(pane, None, ls.clone(), Duration::from_secs(60), 1)
            .await,
        Err(ApprovalError::Forbidden(_))
    ));
    // The owner's rule is visible to the viewer but not revocable by them.
    let rule = owner
        .client
        .add_auto_approve(pane, None, ls, Duration::from_secs(60), 1)
        .await
        .unwrap();
    viewer
        .until("rule pushed", |owner| {
            !owner.client.auto_approve_rules(pane).is_empty()
        })
        .await;
    assert!(matches!(
        viewer.client.revoke_auto_approve(rule).await,
        Err(ApprovalError::Forbidden(_))
    ));
    assert_eq!(owner.client.auto_approve_rules(pane).len(), 1);
    drop((viewer, owner));
    daemon.shutdown().await;
}
