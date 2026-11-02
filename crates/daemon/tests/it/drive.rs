//! An agent asking the owner before it drives one of the user's panes (`proto::drive`): the
//! owner's signed answer unlocks exactly one action, guests cannot answer, a password prompt
//! is never typed into; and agents keep the panes they opened across a restart.

use std::path::{Path, PathBuf};
use std::time::Duration;

use client_core::proto::{
    AgentState, AuditKind, Axis, Blocker, DriveAction, DriveAsk, DrivePush, LayoutOp, OpOutcome,
    PaneId, PaneLaunch, Roles, Scope, UnixMillis,
};
use client_core::{
    ApprovalEvent, ApprovalEventQueue, ClientConfig, GrantSpec, MultiplayerEvent, now_millis,
};
use daemon::{Daemon, TERM_VERSION, TermAsk, TermCall, TermErrorCode, TermReply};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::task::JoinHandle;

use crate::support::{TestClient, start_with, ticket};

/// A program in pane `pane` calling the terminal tools.
#[derive(Clone)]
struct Caller {
    socket: PathBuf,
    token: String,
    pane: PaneId,
}

impl Caller {
    fn new(dir: &Path, daemon: &Daemon, pane: PaneId) -> Self {
        Self {
            socket: daemon.hook_socket().to_owned(),
            token: std::fs::read_to_string(dir.join("hook.token")).unwrap(),
            pane,
        }
    }

    /// Starts a call; the handle ends with its reply.
    fn spawn(&self, tool: &str, args: Value) -> JoinHandle<TermReply> {
        let call = TermCall {
            v: TERM_VERSION,
            token: self.token.clone(),
            pane: self.pane.0.to_string(),
            term: TermAsk {
                tool: tool.into(),
                args,
            },
        };
        let socket = self.socket.clone();
        tokio::spawn(async move {
            let mut stream = UnixStream::connect(socket).await.unwrap();
            let mut line = serde_json::to_vec(&call).unwrap();
            line.push(b'\n');
            stream.write_all(&line).await.unwrap();
            let mut answer = String::new();
            BufReader::new(stream).read_line(&mut answer).await.unwrap();
            serde_json::from_str(&answer).unwrap()
        })
    }

    async fn call(&self, tool: &str, args: Value) -> TermReply {
        reply(self.spawn(tool, args)).await
    }
}

async fn reply(call: JoinHandle<TermReply>) -> TermReply {
    tokio::time::timeout(Duration::from_secs(20), call)
        .await
        .expect("the call answered")
        .unwrap()
}

fn ok(reply: TermReply) -> Value {
    match reply {
        TermReply::Ok(value) => value,
        TermReply::Error(error) => panic!("refused: {error:?}"),
    }
}

fn refused(reply: TermReply) -> daemon::ToolError {
    match reply {
        TermReply::Error(error) => error,
        TermReply::Ok(value) => panic!("allowed: {value}"),
    }
}

fn blocker(client: &TestClient, pane: PaneId) -> Option<Blocker> {
    match client.metas.get(&pane)?.agent.clone()?.state {
        AgentState::Blocked(blocked) => Some(blocked),
        _ => None,
    }
}

/// Waits until `pane` is blocked on a drive request other than `not`, and returns it.
async fn asked(client: &mut TestClient, pane: PaneId, not: Option<u64>) -> Blocker {
    client
        .until("a drive request", |client| {
            blocker(client, pane).is_some_and(|blocked| Some(blocked.request_id.0) != not)
        })
        .await;
    blocker(client, pane).unwrap()
}

/// An owner attached to a session of two shells: the user's pane and the agent's.
async fn setup(dir: &Path, wait: Duration) -> (Daemon, TestClient, PaneId, PaneId) {
    setup_with(dir, wait, None).await
}

async fn setup_with(
    dir: &Path,
    wait: Duration,
    shell: Option<PathBuf>,
) -> (Daemon, TestClient, PaneId, PaneId) {
    let daemon = start_with(dir, |config| {
        config.drive_ask_wait = wait;
        if shell.is_some() {
            config.shell = shell;
        }
    })
    .await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let user = owner.attach_and_follow().await;
    let OpOutcome::PaneCreated { pane_id: agent } = owner
        .op(LayoutOp::Split {
            pane_id: user,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split")
    };
    (daemon, owner, user, agent)
}

#[tokio::test(flavor = "multi_thread")]
async fn the_owners_answer_unlocks_exactly_one_action() {
    let dir = tempfile::tempdir().unwrap();
    let (daemon, mut owner, user, agent) = setup(dir.path(), Duration::from_secs(15)).await;
    let (listener, mut drive_events) = ApprovalEventQueue::channel();
    owner.client.set_approval_listener(listener);
    let caller = Caller::new(dir.path(), &daemon, agent);

    // The user's pane is listed as one to ask about.
    let list = ok(caller.call("pane_list", json!({})).await);
    let theirs = list["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["id"] == format!("p{}", user.0))
        .unwrap()
        .clone();
    assert_eq!(theirs["scopes"], json!(["read", "ask"]), "{theirs}");

    // Typing into it waits for the owner, who sees exactly what would be typed.
    let typing = caller.spawn(
        "pane_send",
        json!({ "pane": format!("p{}", user.0), "text": "echo drive-once", "submit": true }),
    );
    let first = asked(&mut owner, agent, None).await;
    assert!(
        first.summary.contains("wants to type into") && first.summary.contains("echo drive-once"),
        "{first:?}"
    );
    let labels: Vec<&str> = first
        .options
        .iter()
        .map(|option| option.label.as_str())
        .collect();
    assert_eq!(
        labels,
        ["Allow once", "Allow for this pane until it closes", "Deny"]
    );
    owner
        .until("the exact action", |client| {
            client
                .client
                .drive_asks()
                .iter()
                .any(|ask| ask.request_id == first.request_id)
        })
        .await;
    let shown = owner.client.drive_asks().remove(0);
    assert_eq!(shown.target, user);
    assert_eq!(
        shown.action,
        DriveAction::Type {
            text: Some("echo drive-once".into()),
            keys: vec![],
            submit: true,
        }
    );
    assert!(
        !typing.is_finished(),
        "nothing happens before the owner answers"
    );

    owner.client.decide(first.request_id, DriveAsk::ALLOW_ONCE);
    ok(reply(typing).await);
    owner.wait_text(user, "drive-once").await;
    owner
        .until("the card cleared", |client| {
            blocker(client, agent).is_none()
        })
        .await;

    // The answer is used up: the next action asks again, and replaying the old answer
    // decides nothing.
    let again = caller.spawn(
        "pane_send",
        json!({ "pane": format!("p{}", user.0), "text": "echo replayed" }),
    );
    let second = asked(&mut owner, agent, Some(first.request_id.0)).await;
    owner.client.decide(first.request_id, DriveAsk::ALLOW_ONCE);
    owner
        .until("the replay refused", |client| {
            client.mp.iter()
                .any(|event| matches!(event, MultiplayerEvent::Forbidden { what, .. } if what == "Decide"))
        })
        .await;
    assert!(
        !again.is_finished(),
        "a replayed answer unlocked another action"
    );
    assert_eq!(
        blocker(&owner, agent).unwrap().request_id,
        second.request_id
    );

    // Deny refuses the call.
    owner.client.decide(second.request_id, DriveAsk::DENY);
    let denied = refused(reply(again).await);
    assert_eq!(denied.code, TermErrorCode::Forbidden);
    assert!(denied.message.contains("said no"), "{denied:?}");
    assert!(!owner.text(user).contains("replayed"));

    // "For this pane": this action and later ones, without asking.
    let run = caller.spawn(
        "pane_send",
        json!({ "pane": format!("p{}", user.0), "text": "echo granted-1", "submit": true }),
    );
    let third = asked(&mut owner, agent, Some(second.request_id.0)).await;
    owner.client.decide(third.request_id, DriveAsk::ALLOW_PANE);
    ok(reply(run).await);
    ok(caller
        .call(
            "pane_send",
            json!({ "pane": format!("p{}", user.0), "text": "echo granted-2", "submit": true }),
        )
        .await);
    owner.wait_text(user, "granted-2").await;

    // A password prompt is never typed into, whatever was allowed.
    owner.type_line(user, "read -s secret");
    tokio::time::sleep(Duration::from_millis(500)).await;
    let secret = refused(
        caller
            .call(
                "pane_send",
                json!({ "pane": format!("p{}", user.0), "text": "hunter2" }),
            )
            .await,
    );
    assert_eq!(secret.code, TermErrorCode::SecretPrompt);
    owner.type_line(user, "");

    // Every answer is in the audit log, signed by the owner's device.
    let page = owner.client.audit(None, 100).await.unwrap();
    assert!(page.chain_ok);
    let answers: Vec<_> = page
        .records
        .iter()
        .filter(|record| record.kind == AuditKind::Approval)
        .filter_map(|record| record.approval.as_ref())
        .collect();
    let options: Vec<&str> = answers
        .iter()
        .map(|answer| answer.option.as_str())
        .collect();
    assert_eq!(
        options,
        ["Allow once", "Deny", "Allow for this pane until it closes"]
    );
    assert!(answers[0].summary.contains("echo drive-once"));
    assert_eq!(answers[0].tool.as_deref(), Some("pane_send"));

    // The request reached the approval listener, opened and closed.
    let mut opened = 0;
    let mut closed = 0;
    while let Ok(event) = drive_events.try_recv() {
        match event {
            ApprovalEvent::Drive(DrivePush::Open(_)) => opened += 1,
            ApprovalEvent::Drive(DrivePush::Closed { .. }) => closed += 1,
            _ => {}
        }
    }
    assert_eq!((opened, closed), (3, 3));
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn guests_cannot_answer_and_unanswered_requests_lapse() {
    let dir = tempfile::tempdir().unwrap();
    let (daemon, mut owner, user, agent) = setup(dir.path(), Duration::from_secs(3)).await;
    let caller = Caller::new(dir.path(), &daemon, agent);

    // A guest who may approve agents' tool calls still cannot let an agent drive.
    let mut spec = GrantSpec::new(Roles::DRIVER | Roles::APPROVER, Scope::Daemon);
    spec.label = "bob".into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "alice".into())
        .await
        .unwrap();
    let mut guest = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    guest.client.attach(None);
    guest
        .until("guest layout", |client| client.layout.is_some())
        .await;

    let closing = caller.spawn("pane_close", json!({ "pane": format!("p{}", user.0) }));
    let ask = asked(&mut owner, agent, None).await;
    guest
        .until("the guest sees the card", |client| {
            blocker(client, agent).is_some()
        })
        .await;
    assert!(
        guest.client.drive_asks().is_empty(),
        "guests are not sent the request"
    );
    guest.client.decide(ask.request_id, DriveAsk::ALLOW_ONCE);
    guest
        .until("the guest refused", |client| {
            client.mp.iter()
                .any(|event| matches!(event, MultiplayerEvent::Forbidden { what, .. } if what == "Decide"))
        })
        .await;
    assert!(!closing.is_finished());

    // Unanswered, it lapses: refused, retryable, and the card goes away.
    let lapsed = refused(reply(closing).await);
    assert_eq!(lapsed.code, TermErrorCode::Forbidden);
    assert!(lapsed.retryable, "{lapsed:?}");
    owner
        .until("the card cleared", |client| {
            blocker(client, agent).is_none()
        })
        .await;
    assert!(owner.client.drive_asks().is_empty());
    assert!(
        crate::support::leaves(&owner.tab().root).contains(&user),
        "the pane was not closed"
    );

    // A caller that hangs up withdraws its request.
    let hanging = caller.spawn(
        "cmd_run",
        json!({ "pane": format!("p{}", user.0), "command": "echo never" }),
    );
    asked(&mut owner, agent, Some(ask.request_id.0)).await;
    hanging.abort();
    owner
        .until("the request withdrawn", |client| {
            blocker(client, agent).is_none()
        })
        .await;
    drop((guest, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_agent_keeps_the_panes_it_opened_across_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let wait = Duration::from_millis(500);
    let (daemon, owner, user, agent) = setup(dir.path(), wait).await;
    let caller = Caller::new(dir.path(), &daemon, agent);
    let split = ok(caller.call("pane_split", json!({})).await);
    let worker = split["pane"]["id"].as_str().unwrap().to_owned();
    drop(owner);
    daemon.shutdown().await;

    let daemon = start_with(dir.path(), |config| config.drive_ask_wait = wait).await;
    let caller = Caller::new(dir.path(), &daemon, agent);
    let list = ok(caller.call("pane_list", json!({})).await);
    let mine = list["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["id"] == worker)
        .cloned()
        .expect("the worker came back");
    assert_eq!(mine["createdByYou"], true, "{mine}");
    // Its own pane: no question asked.
    ok(caller
        .call(
            "pane_send",
            json!({ "pane": worker, "text": "echo still-mine" }),
        )
        .await);
    // The user's pane is still the user's.
    let theirs = refused(
        caller
            .call(
                "pane_send",
                json!({ "pane": format!("p{}", user.0), "text": "x" }),
            )
            .await,
    );
    assert_eq!(theirs.code, TermErrorCode::Forbidden);

    // Closing the worker ends the agent's claim on its id.
    ok(caller.call("pane_close", json!({ "pane": worker })).await);
    daemon.shutdown().await;
    let saved = std::fs::read_to_string(dir.path().join("layout.json")).unwrap();
    let saved: Value = serde_json::from_str(&saved).unwrap();
    assert!(saved.get("creators").is_none(), "{saved}");
}

#[tokio::test(flavor = "multi_thread")]
async fn events_come_to_subscribers_of_their_own_session_only() {
    let Some(zsh) = ["/bin/zsh", "/usr/bin/zsh"]
        .into_iter()
        .map(PathBuf::from)
        .find(|path| path.exists())
    else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let (daemon, mut owner, user, agent) =
        setup_with(dir.path(), Duration::from_secs(1), Some(zsh)).await;
    let caller = Caller::new(dir.path(), &daemon, agent);
    let start = ok(caller.call("events_wait", json!({ "timeoutMs": 0 })).await)["cursor"]
        .as_u64()
        .unwrap();

    // Another session's pane: not this subscriber's business.
    let OpOutcome::SessionCreated {
        pane_id: elsewhere, ..
    } = owner
        .op(LayoutOp::CreateSession {
            name: "other".into(),
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("session")
    };
    // In its own session: a pane opens, a command runs, the pane closes.
    let run = ok(caller
        .call("cmd_run", json!({ "command": "(exit 7)" }))
        .await);
    assert_eq!(run["command"]["exitCode"], 7, "{run}");
    let worker = run["pane"].as_str().unwrap().to_owned();
    ok(caller.call("pane_close", json!({ "pane": worker })).await);

    let mut seen = Vec::new();
    let mut cursor = start;
    while !seen
        .iter()
        .any(|event: &Value| event["type"] == "pane.closed")
    {
        let page = ok(caller
            .call("events_wait", json!({ "since": cursor, "timeoutMs": 5000 }))
            .await);
        let events = page["events"].as_array().unwrap();
        assert!(!events.is_empty(), "no events after {seen:?}");
        cursor = page["cursor"].as_u64().unwrap();
        seen.extend(events.iter().cloned());
    }
    let opened: Vec<&Value> = seen
        .iter()
        .filter(|event| event["type"] == "pane.opened")
        .collect();
    assert_eq!(opened.len(), 1, "{seen:?}");
    assert_eq!(opened[0]["pane"], worker);
    assert_eq!(opened[0]["v"], 1);
    assert!(
        seen.iter()
            .all(|event| event["pane"] != format!("p{}", elsewhere.0)),
        "another session's pane leaked: {seen:?}"
    );
    assert!(seen.iter().any(|event| event["type"] == "layout.changed"));
    let finished = seen
        .iter()
        .find(|event| event["type"] == "command.finished" && event["pane"] == worker)
        .unwrap_or_else(|| panic!("no command.finished in {seen:?}"));
    assert_eq!(finished["exitCode"], 7, "{finished}");
    assert!(
        seen.iter()
            .any(|event| event["type"] == "command.started" && event["pane"] == worker),
        "{seen:?}"
    );

    // Filtered by type, and a cursor from the far past says what it missed.
    let only = ok(caller
        .call(
            "events_wait",
            json!({ "since": start, "types": ["pane.closed"], "timeoutMs": 0 }),
        )
        .await);
    let types: Vec<&str> = only["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|event| event["type"].as_str().unwrap())
        .collect();
    assert_eq!(types, ["pane.closed"]);
    let bad = refused(
        caller
            .call("events_wait", json!({ "types": ["pane.exploded"] }))
            .await,
    );
    assert_eq!(bad.code, TermErrorCode::InvalidArgs);
    let _ = user;
    drop(owner);
    daemon.shutdown().await;
}

/// `gudo events`: a client's stream holds only what its grant shows it.
#[tokio::test(flavor = "multi_thread")]
async fn a_clients_event_stream_follows_its_scope() {
    let Some(zsh) = ["/bin/zsh", "/usr/bin/zsh"]
        .into_iter()
        .map(PathBuf::from)
        .find(|path| path.exists())
    else {
        eprintln!("skipping: zsh not installed");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let (daemon, mut owner, user, agent) =
        setup_with(dir.path(), Duration::from_secs(1), Some(zsh)).await;
    let mut spec = GrantSpec::new(Roles::VIEWER, Scope::Pane(user));
    spec.label = "vic".into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "alice".into())
        .await
        .unwrap();
    let mut guest = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    guest.client.attach(None);
    guest
        .until("guest layout", |client| client.layout.is_some())
        .await;

    owner.type_line(user, "true");
    owner.type_line(agent, "(exit 4)");
    let OpOutcome::PaneCreated { pane_id: third } = owner
        .op(LayoutOp::Split {
            pane_id: agent,
            axis: Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split")
    };
    let finished = |client: &TestClient, pane: PaneId| {
        client.script_events.iter().any(|event| {
            event.pane.as_deref() == Some(&format!("p{}", pane.0))
                && matches!(
                    event.kind,
                    client_core::proto::ScriptEventKind::CommandFinished { .. }
                )
        })
    };
    owner
        .until("both commands", |client| {
            finished(client, user) && finished(client, agent)
        })
        .await;
    assert!(owner.script_events.iter().any(|event| {
        event.pane.as_deref() == Some(&format!("p{}", third.0))
            && matches!(
                event.kind,
                client_core::proto::ScriptEventKind::PaneOpened { .. }
            )
    }));
    // A later command in its pane: anything sent before it has arrived by then.
    owner.type_line(user, "true");
    let in_user = |client: &TestClient| {
        client
            .script_events
            .iter()
            .filter(|event| {
                event.pane.as_deref() == Some(&format!("p{}", user.0))
                    && matches!(
                        event.kind,
                        client_core::proto::ScriptEventKind::CommandFinished { .. }
                    )
            })
            .count()
    };
    guest
        .until("its pane's commands", |client| in_user(client) >= 2)
        .await;
    let leaked: Vec<_> = guest
        .script_events
        .iter()
        .filter(|event| {
            event.pane.is_some() && event.pane.as_deref() != Some(&format!("p{}", user.0))
        })
        .collect();
    assert!(leaked.is_empty(), "outside the guest's scope: {leaked:?}");
    drop((guest, owner));
    daemon.shutdown().await;
}

/// The TypeScript client (`sdk/typescript`) against a real daemon: a command's exit code, its
/// `command.finished` event, and the user's pane refused when nobody answers.
#[tokio::test(flavor = "multi_thread")]
async fn the_typescript_client_drives_a_real_daemon() {
    let node_works = std::process::Command::new("node")
        .args(["-e", "process.exit(0)"])
        .status()
        .is_ok_and(|status| status.success());
    let zsh = ["/bin/zsh", "/usr/bin/zsh"]
        .into_iter()
        .map(PathBuf::from)
        .find(|path| path.exists());
    let (true, Some(zsh)) = (node_works, zsh) else {
        eprintln!("skipping: node or zsh not installed");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let (daemon, owner, user, agent) =
        setup_with(dir.path(), Duration::from_secs(1), Some(zsh)).await;
    let sdk = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../sdk/typescript/gudo.ts")
        .canonicalize()
        .unwrap();
    let script = dir.path().join("drive.mjs");
    std::fs::write(
        &script,
        format!(
            r#"import {{ Terminal }} from {sdk:?};
const term = Terminal.fromEnv();
const events = term.events({{ types: ["command.finished"] }});
const first = events.next();
await new Promise((r) => setTimeout(r, 300));
const run = await term.run("(exit 5)");
const event = (await first).value;
let refused = "";
try {{ await term.panes.send("p{user}", {{ text: "x" }}); }} catch (e) {{ refused = e.code; }}
console.log(JSON.stringify({{ exit: run.command?.exitCode, event: event.type, eventExit: event.exitCode, samePane: event.pane === run.pane, refused }}));
process.exit(0);
"#,
            user = user.0,
        ),
    )
    .unwrap();
    let out = tokio::process::Command::new("node")
        .arg(&script)
        .env("GUDO_SOCK", daemon.hook_socket())
        .env(
            "GUDO_TOKEN",
            std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        )
        .env("GUDO_PANE_ID", agent.0.to_string())
        .env_remove("GUDO_ENDPOINT_FILE")
        .output();
    let out = tokio::time::timeout(Duration::from_secs(60), out)
        .await
        .expect("the script finished")
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{stdout}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let result: Value = serde_json::from_str(stdout.trim()).unwrap();
    assert_eq!(
        result,
        json!({ "exit": 5, "event": "command.finished", "eventExit": 5, "samePane": true, "refused": "forbidden" })
    );
    drop(owner);
    daemon.shutdown().await;
}
