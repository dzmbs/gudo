//! Multiplayer end to end: an owner and guests on one daemon (relays off).
//!
//! Roles are enforced on input, prompts, decisions, layout ops, workspace requests and
//! streams; the control lease admits one driver at a time; approvals are signed and audited;
//! revocation disconnects at once; expired, forged, escalated or widened grants are refused.

use std::time::Duration;

use client_core::grants::{self, DeviceKey, GrantSpec};
use client_core::proto::{
    AgentState, AuditKind, InputRejectReason, Invite, LayoutOp, LeaseMode, LeaseOutcome, MpError,
    MpResponse, OpError, OpOutcome, OptionId, PaneId, PaneLaunch, ReviewNote, ReviewRequest,
    RevokeTarget, Roles, Scope, UnixMillis, WorkspaceRequest, WsError,
};
use client_core::{ClientConfig, MultiplayerEvent, now_millis};
use daemon::{Daemon, HookRequest, HookResponse};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use crate::support::{TestClient, start_with, ticket};

const PERMISSION: &str =
    include_str!("../../../agents/tests/fixtures/claude/permission_request.json");
const SESSION_START: &str =
    include_str!("../../../agents/tests/fixtures/claude/session_start_resume.json");

async fn daemon(dir: &std::path::Path) -> Daemon {
    start_with(dir, |config| config.lease_idle = Duration::from_secs(3)).await
}

fn spec(roles: Roles, label: &str) -> GrantSpec {
    let mut spec = GrantSpec::new(roles, Scope::Daemon);
    spec.label = label.into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    spec
}

async fn invite(owner: &TestClient, spec: GrantSpec) -> Invite {
    owner
        .client
        .create_invite(spec, "alice".into())
        .await
        .expect("invite")
}

/// A guest joined, attached and following `pane`.
async fn guest(invite: &Invite, pane: PaneId) -> TestClient {
    let mut joined = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    joined.client.attach(None);
    joined.until("guest layout", |c| c.layout.is_some()).await;
    joined.follow(pane).await;
    joined
}

fn rejected(client: &TestClient, pane: PaneId, reason: InputRejectReason) -> bool {
    client.mp.iter().any(|event| {
        matches!(event, MultiplayerEvent::InputRejected { pane_id, reason: rejected }
            if *pane_id == pane && *rejected == reason)
    })
}

fn lease_holder(client: &TestClient, pane: PaneId) -> Option<client_core::proto::PrincipalId> {
    client.mp.iter().rev().find_map(|event| match event {
        MultiplayerEvent::Lease { lease } if lease.pane_id == pane => Some(lease.holder),
        _ => None,
    })?
}

async fn hook(socket: &std::path::Path, request: &HookRequest) -> HookResponse {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut line = serde_json::to_vec(request).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
    serde_json::from_str(&answer).unwrap()
}

fn hook_request(dir: &std::path::Path, pane: PaneId, event: &str, payload: &str) -> HookRequest {
    HookRequest {
        v: 1,
        token: std::fs::read_to_string(dir.join("hook.token")).unwrap(),
        pane: pane.0.to_string(),
        agent: "claude".into(),
        event: event.into(),
        seq: 1,
        payload: serde_json::from_str(payload).unwrap(),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn viewer_cannot_type_and_one_driver_holds_the_lease() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let owner_principal = owner.client.me().unwrap().actor.principal;

    let driver_invite = invite(&owner, spec(Roles::DRIVER, "bob")).await;
    let viewer_invite = invite(&owner, spec(Roles::VIEWER, "carol")).await;
    let mut bob = guest(&driver_invite, pane).await;
    let mut carol = guest(&viewer_invite, pane).await;
    let bob_principal = bob.client.me().unwrap().actor.principal;
    assert_eq!(bob.client.me().unwrap().roles, Roles::DRIVER);
    assert_eq!(
        bob_principal,
        grants::guest_principal(bob.client.me().unwrap().actor.device)
    );

    // Presence: everyone sees three participants, by name.
    carol
        .until("three participants", |c| {
            c.client.participant_list().len() == 3
        })
        .await;
    let names: Vec<String> = carol
        .client
        .participant_list()
        .into_iter()
        .map(|participant| participant.name)
        .collect();
    assert_eq!(names, ["owner", "bob", "carol"]);

    // The viewer's keystrokes are refused, never written.
    carol.type_line(pane, "echo viewer-typed");
    carol
        .until("viewer refused", |c| {
            rejected(c, pane, InputRejectReason::Role)
        })
        .await;
    assert!(carol.mp.iter().any(
        |event| matches!(event, MultiplayerEvent::Forbidden { reason, .. } if reason.contains("driver"))
    ));

    // The owner types first and takes the free lease; everyone is told.
    owner.type_line(pane, "echo owner-one");
    carol.wait_text(pane, "owner-one").await;
    carol
        .until("lease shown to the viewer", |c| {
            lease_holder(c, pane) == Some(owner_principal)
        })
        .await;
    assert!(!carol.text(pane).contains("viewer-typed"));

    // Bob is a driver but does not hold the lease.
    bob.type_line(pane, "echo bob-early");
    bob.until("no lease", |c| {
        rejected(c, pane, InputRejectReason::NoLease)
    })
    .await;

    // Bob asks; the owner is active, so the owner is asked and gives it.
    let asked = bob.client.take_control(pane, false).await.unwrap();
    assert_eq!(
        asked,
        LeaseOutcome::Pending {
            holder: owner_principal
        }
    );
    owner
        .until("lease request", |c| {
            c.mp.iter().any(
                |event| matches!(event, MultiplayerEvent::LeaseRequested { name, .. } if name == "bob"),
            )
        })
        .await;
    let given = owner.client.answer_control(pane, true).await.unwrap();
    assert!(
        matches!(given, LeaseOutcome::Granted(lease) if lease.holder == Some(bob_principal) && lease.mode == LeaseMode::Leased)
    );
    bob.type_line(pane, "echo bob-drives");
    carol.wait_text(pane, "bob-drives").await;
    assert!(!carol.text(pane).contains("bob-early"));

    // Now the owner's raw input is refused until it takes control back.
    let before = owner.mp.len();
    owner.type_line(pane, "echo owner-blocked");
    owner
        .until("owner refused", |c| {
            c.mp[before..].iter().any(|event| {
                matches!(
                    event,
                    MultiplayerEvent::InputRejected {
                        reason: InputRejectReason::NoLease,
                        ..
                    }
                )
            })
        })
        .await;
    // The owner can force it.
    let forced = owner.client.take_control(pane, true).await.unwrap();
    assert!(
        matches!(forced, LeaseOutcome::Granted(lease) if lease.holder == Some(owner_principal))
    );
    // A driver cannot force.
    assert!(matches!(
        bob.client.take_control(pane, true).await,
        Err(MpError::Forbidden(_))
    ));

    // Handoff after idle: bob asks, the owner stays quiet, the lease moves by itself.
    let asked = bob.client.take_control(pane, false).await.unwrap();
    assert!(matches!(asked, LeaseOutcome::Pending { .. }));
    bob.until("lease after idle", |c| {
        lease_holder(c, pane) == Some(bob_principal)
    })
    .await;
    bob.type_line(pane, "echo bob-again");
    owner.wait_text(pane, "bob-again").await;
    bob.client.release_control(pane).await.unwrap();
    owner
        .until("lease released", |c| {
            c.mp.iter().rev().find_map(|event| match event {
                MultiplayerEvent::Lease { lease } if lease.pane_id == pane => Some(lease.holder),
                _ => None,
            }) == Some(None)
        })
        .await;

    // Typing indicator reaches the others with bob's actor.
    bob.client.set_typing(pane, true);
    carol
        .until("typing indicator", |c| {
            c.mp.iter().any(|event| {
                matches!(event, MultiplayerEvent::Presence { presence }
                    if presence.typing && presence.actor.principal == bob_principal
                        && presence.focus == Some(pane))
            })
        })
        .await;

    // The viewer cannot change the layout, take control, read files or forward ports.
    let outcome = carol
        .op(LayoutOp::Split {
            pane_id: pane,
            axis: client_core::proto::Axis::Horizontal,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await;
    assert!(matches!(
        outcome,
        OpOutcome::Failed {
            code: OpError::Forbidden,
            ..
        }
    ));
    assert!(matches!(
        carol.client.take_control(pane, false).await,
        Err(MpError::Forbidden(_))
    ));
    let listing = carol
        .client
        .workspace(WorkspaceRequest::FsList {
            path: "~".into(),
            show_hidden: false,
        })
        .await;
    assert!(matches!(listing, Err(WsError::Denied(_))), "{listing:?}");
    assert!(matches!(
        carol.client.list_grants().await,
        Err(MpError::Forbidden(_))
    ));
    // The driver may read host files.
    assert!(
        bob.client
            .workspace(WorkspaceRequest::FsList {
                path: "~".into(),
                show_hidden: false,
            })
            .await
            .is_ok()
    );

    drop((bob, carol));
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn prompter_only_composes_to_agent_panes() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = owner.attach_and_follow().await;
    // A Claude hook marks the pane as an agent pane; a line reader stands in for the agent.
    hook(
        daemon.hook_socket(),
        &hook_request(dir.path(), agent_pane, "SessionStart", SESSION_START),
    )
    .await;
    start_fake_agent(
        &mut owner,
        agent_pane,
        "while read line; do echo \"agent-read:$line\"; done",
    )
    .await;
    let OpOutcome::PaneCreated {
        pane_id: shell_pane,
    } = owner
        .op(LayoutOp::Split {
            pane_id: agent_pane,
            axis: client_core::proto::Axis::Horizontal,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split failed")
    };
    let mut pat = guest(
        &invite(&owner, spec(Roles::PROMPTER, "pat")).await,
        agent_pane,
    )
    .await;

    // Raw keystrokes are refused, even into the agent pane.
    pat.type_line(agent_pane, "echo raw-keys");
    pat.until("raw refused", |c| {
        rejected(c, agent_pane, InputRejectReason::Role)
    })
    .await;

    // The composer path writes a prompt (here `sh` runs it, which shows it arrived).
    let chars = pat
        .client
        .prompt(agent_pane, "echo prompted-ok".into(), true)
        .await
        .unwrap();
    assert_eq!(chars, 16);
    owner.wait_text(agent_pane, "prompted-ok").await;
    assert!(!owner.text(agent_pane).contains("raw-keys"));

    // Not into a shell pane, and no shell escapes, agent commands or control bytes.
    assert!(matches!(
        pat.client.prompt(shell_pane, "ls".into(), true).await,
        Err(MpError::Forbidden(message)) if message.contains("agent panes only")
    ));
    for bad in [
        "!rm -rf ~",
        "/permissions allow Bash",
        "hi\x1b[201~",
        "x\x03",
        "# memo",
    ] {
        let result = pat.client.prompt(agent_pane, bad.into(), true).await;
        assert!(
            matches!(result, Err(MpError::Invalid(_))),
            "{bad:?}: {result:?}"
        );
    }
    // Viewers cannot prompt at all.
    let vic = guest(
        &invite(&owner, spec(Roles::VIEWER, "vic")).await,
        agent_pane,
    )
    .await;
    assert!(matches!(
        vic.client.prompt(agent_pane, "hello".into(), true).await,
        Err(MpError::Forbidden(_))
    ));

    // The audit log records the prompt by length and hash, never the text.
    let page = owner.client.audit(None, 100).await.unwrap();
    let prompt = page
        .records
        .iter()
        .find(|record| record.kind == AuditKind::Prompt)
        .expect("prompt audited");
    assert!(prompt.detail.contains("16 chars"), "{}", prompt.detail);
    assert!(!prompt.detail.contains("prompted-ok"));
    drop((pat, vic, owner));
    daemon.shutdown().await;
}

/// Runs `script` as the pane's foreground job in place of an agent, once it is up.
async fn start_fake_agent(owner: &mut TestClient, pane: PaneId, script: &str) {
    owner.type_line(pane, &format!("sh -c 'echo AGENT\"\"-UP; {script}'"));
    owner.wait_text(pane, "AGENT-UP").await;
}

/// The agent quits and the pane is back at its shell before the daemon notices: a prompter's
/// next prompt or review is refused at the moment of writing, and nothing reaches the shell.
#[tokio::test(flavor = "multi_thread")]
async fn text_for_an_agent_that_just_exited_reaches_nobody() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    hook(
        daemon.hook_socket(),
        &hook_request(dir.path(), pane, "SessionStart", SESSION_START),
    )
    .await;
    start_fake_agent(&mut owner, pane, "read line; echo \"agent-read:$line\"").await;
    let pat = guest(&invite(&owner, spec(Roles::PROMPTER, "pat")).await, pane).await;

    pat.client.prompt(pane, "first".into(), true).await.unwrap();
    owner.wait_text(pane, "agent-read:first").await;
    tokio::time::sleep(Duration::from_millis(200)).await;

    let leaked = pat
        .client
        .prompt(pane, "echo LEAKED-$((6*7))".into(), true)
        .await;
    assert!(
        matches!(&leaked, Err(MpError::Forbidden(message)) if message.contains("agent panes only")),
        "{leaked:?}"
    );
    let reviewed = pat
        .client
        .send_review(review(pane, None, "echo REVIEW-$((6*7))"))
        .await;
    assert!(matches!(&reviewed, Err(WsError::Denied(_))), "{reviewed:?}");
    owner.type_line(pane, "echo shell-$((1+1))");
    owner.wait_text(pane, "shell-2").await;
    let text = owner.text(pane);
    assert!(
        !text.contains("LEAKED") && !text.contains("REVIEW"),
        "{text}"
    );
    drop((pat, owner));
    daemon.shutdown().await;
}

fn review(pane_id: PaneId, preamble: Option<&str>, note: &str) -> ReviewRequest {
    ReviewRequest {
        pane_id,
        preamble: preamble.map(str::to_owned),
        notes: vec![ReviewNote {
            path: "src/a.rs".into(),
            start_line: 1,
            end_line: 1,
            old_side: false,
            quote: Some("fn a() {}\r\x1b[201~".into()),
            note: note.into(),
        }],
        submit: true,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn review_notes_obey_the_prompt_rules() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = owner.attach_and_follow().await;
    hook(
        daemon.hook_socket(),
        &hook_request(dir.path(), agent_pane, "SessionStart", SESSION_START),
    )
    .await;
    start_fake_agent(
        &mut owner,
        agent_pane,
        "while read line; do echo \"agent-read:$line\"; done",
    )
    .await;
    let marker = dir.path().join("pwned");
    let shell_escape = format!("!touch {}", marker.display());

    for (roles, name) in [
        (Roles::PROMPTER, "pat"),
        (Roles::APPROVER | Roles::VIEWER, "ann"),
    ] {
        let mut guest = guest(&invite(&owner, spec(roles, name)).await, agent_pane).await;
        let note = format!("note from {name}");
        let prompt = guest
            .client
            .send_review(review(agent_pane, Some(&shell_escape), &note))
            .await
            .unwrap();
        assert!(!prompt.contains("touch"), "{prompt}");
        assert!(
            !prompt.contains('\x1b') && !prompt.contains('\r'),
            "{prompt:?}"
        );
        guest.wait_text(agent_pane, &note).await;
        for bad in ["fine\x1b[201~\r!sh", "x\x03"] {
            let result = guest
                .client
                .send_review(review(agent_pane, None, bad))
                .await;
            assert!(
                matches!(result, Err(WsError::Invalid(_))),
                "{bad:?}: {result:?}"
            );
        }
    }

    for bad in [
        shell_escape.as_str(),
        "# remember this",
        "/permissions allow Bash",
    ] {
        let result = owner
            .client
            .send_review(review(agent_pane, Some(bad), "a note"))
            .await;
        assert!(
            matches!(result, Err(WsError::Invalid(_))),
            "{bad:?}: {result:?}"
        );
    }
    let own = owner
        .client
        .send_review(review(agent_pane, Some("Please look again:"), "owner note"))
        .await
        .unwrap();
    assert!(own.starts_with("Please look again:"), "{own}");
    owner.wait_text(agent_pane, "owner note").await;
    assert!(!marker.exists(), "a review note ran a shell command");
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn approvals_are_signed_single_flight_and_audited() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let ann = guest(
        &invite(&owner, spec(Roles::APPROVER | Roles::VIEWER, "ann")).await,
        pane,
    )
    .await;
    let mut vic = guest(&invite(&owner, spec(Roles::VIEWER, "vic")).await, pane).await;

    let socket = daemon.hook_socket().to_owned();
    let request = hook_request(dir.path(), pane, "PermissionRequest", PERMISSION);
    let waiting = tokio::spawn(async move { hook(&socket, &request).await });
    let blocked = |c: &TestClient| {
        c.metas
            .get(&pane)
            .and_then(|meta| meta.agent.clone())
            .and_then(|agent| match agent.state {
                AgentState::Blocked(prompt) => Some(prompt),
                _ => None,
            })
    };
    vic.until("blocked", |c| blocked(c).is_some()).await;
    let blocker = blocked(&vic).unwrap();

    // A viewer's decision is refused and the agent stays blocked.
    vic.client.decide(blocker.request_id, OptionId(0));
    vic.until("decision refused", |c| {
        c.mp.iter().any(
            |event| matches!(event, MultiplayerEvent::Forbidden { what, .. } if what == "Decide"),
        )
    })
    .await;
    assert!(!waiting.is_finished());

    // The approver's signed decision answers the hook; everyone sees who decided.
    let ann_actor = ann.client.me().unwrap().actor;
    ann.client.decide(blocker.request_id, OptionId(0));
    let response = tokio::time::timeout(Duration::from_secs(10), waiting)
        .await
        .expect("hook answered")
        .unwrap();
    let stdout: serde_json::Value = serde_json::from_str(&response.stdout.unwrap()).unwrap();
    assert_eq!(
        stdout["hookSpecificOutput"]["decision"]["behavior"],
        "allow"
    );
    vic.until("decided broadcast", |c| {
        c.mp.iter().any(|event| matches!(event, MultiplayerEvent::Decided { decided } if decided.decided_by == ann_actor))
    })
    .await;
    // The owner is told a guest answered, whatever it has seen; other guests are not.
    owner
        .until("guest answer alert", |c| {
            c.mp.iter().any(|event| {
                matches!(event, MultiplayerEvent::GuestAnswered { answer }
                    if answer.by == ann_actor && answer.name == "ann" && answer.answer == "Yes"
                        && answer.pane_id == pane)
            })
        })
        .await;
    assert!(
        !vic.mp
            .iter()
            .any(|event| matches!(event, MultiplayerEvent::GuestAnswered { .. }))
    );
    // A late second decision loses.
    owner.client.decide(blocker.request_id, OptionId(1));
    owner
        .until("already decided", |c| {
            c.mp.iter().any(
                |event| matches!(event, MultiplayerEvent::AlreadyDecided { by, .. } if *by == ann_actor),
            )
        })
        .await;

    // The audit log holds the approval with the approver's verifiable signature.
    let page = owner.client.audit(None, 100).await.unwrap();
    assert!(page.chain_ok);
    let record = page
        .records
        .iter()
        .find(|record| record.kind == AuditKind::Approval)
        .expect("approval audited");
    assert_eq!(record.actor, Some(ann_actor));
    let approval = record.approval.as_ref().unwrap();
    assert_eq!(approval.request_id, blocker.request_id);
    assert_eq!(approval.option, "Yes");
    assert_eq!(approval.tool.as_deref(), Some("Bash"));
    assert!(!approval.agent_request.is_empty());
    assert!(grants::verify_signature(
        ann_actor.device,
        &approval.signed,
        &approval.sig
    ));
    assert_eq!(
        approval.signed,
        client_core::proto::approval_signing_bytes(
            daemon.daemon_id(),
            blocker.request_id,
            OptionId(0),
            ann_actor
        )
    );
    // Refusals are audited too, and the file on disk is the same chain.
    assert!(
        page.records
            .iter()
            .any(|record| record.kind == AuditKind::Join)
    );
    let on_disk = std::fs::read_to_string(dir.path().join("audit/audit.jsonl")).unwrap();
    assert!(on_disk.contains("\"Approval\""));
    drop((ann, vic, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn revocation_kicks_at_once_and_reaches_delegated_grants() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;

    let mut bob_spec = spec(Roles::DRIVER | Roles::VIEWER, "bob");
    bob_spec.delegate = true;
    let bob_invite = invite(&owner, bob_spec).await;
    let mut bob = guest(&bob_invite, pane).await;

    // Bob shares a viewer-only link with dave; he cannot share a wider one.
    let dave_invite = bob
        .client
        .create_invite(spec(Roles::VIEWER, "dave"), "bob".into())
        .await
        .unwrap();
    assert_eq!(dave_invite.chain.links.len(), 2);
    assert!(matches!(
        bob.client.create_invite(spec(Roles::OWNER, "eve"), "bob".into()).await,
        Err(MpError::Invalid(message)) if message.contains("roles")
    ));
    let mut dave = guest(&dave_invite, pane).await;
    assert_eq!(dave.client.me().unwrap().roles, Roles::VIEWER);

    let mut carol = guest(&invite(&owner, spec(Roles::VIEWER, "carol")).await, pane).await;

    let grants_list = owner.client.list_grants().await.unwrap();
    assert!(
        grants_list.iter().any(|grant| grant.grant.label == "dave"
            && grant.parent == Some(bob_invite.chain.grant_id()))
    );
    let devices = owner.client.list_devices().await.unwrap();
    assert_eq!(
        devices.iter().filter(|device| device.connected > 0).count(),
        4
    );

    // Revoking bob's grant disconnects bob and dave (attenuated from it) at once.
    let revoked = owner
        .client
        .revoke(RevokeTarget::Grant(bob_invite.chain.grant_id()))
        .await
        .unwrap();
    let MpResponse::Revoked {
        grants: hit,
        disconnected,
        ..
    } = revoked
    else {
        unreachable!()
    };
    assert_eq!(disconnected, 2);
    assert!(hit.contains(&dave_invite.chain.grant_id()));
    for (name, kicked) in [("bob", &mut bob), ("dave", &mut dave)] {
        kicked
            .until(&format!("{name} kicked"), |c| {
                c.mp.iter()
                    .any(|event| matches!(event, MultiplayerEvent::Revoked))
                    && c.refused.iter().any(|reason| reason.contains("Revoked"))
            })
            .await;
    }
    // Carol is unaffected; then her device is revoked.
    owner.type_line(pane, "echo still-here");
    carol.wait_text(pane, "still-here").await;
    let carol_device = carol.client.me().unwrap().actor.device;
    owner
        .client
        .revoke(RevokeTarget::Device(carol_device))
        .await
        .unwrap();
    carol
        .until("carol kicked", |c| {
            c.refused.iter().any(|reason| reason.contains("Revoked"))
        })
        .await;
    // The owner cannot revoke the device it is using.
    let own = owner.client.me().unwrap().actor.device;
    assert!(matches!(
        owner.client.revoke(RevokeTarget::Device(own)).await,
        Err(MpError::Conflict(_))
    ));
    let grants_list = owner.client.list_grants().await.unwrap();
    assert!(grants_list.iter().filter(|grant| grant.revoked).count() >= 2);
    let page = owner.client.audit(None, 200).await.unwrap();
    assert!(
        page.records
            .iter()
            .any(|record| record.kind == AuditKind::Revoked)
    );
    drop((bob, dave, carol, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn expired_forged_escalated_and_used_up_grants_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let owner_key = ClientConfig::generate_key();
    let mut owner = TestClient::connect(&ticket(&daemon), owner_key.clone());
    let pane = owner.attach_and_follow().await;
    let owner_device = DeviceKey::from_seed(&owner_key).unwrap();
    let base = invite(&owner, spec(Roles::VIEWER, "base")).await;
    let with_chain = |chain| Invite {
        chain,
        ..base.clone()
    };
    let refused = |invite: Invite| async move {
        let mut client = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
        client
            .until("refusal", |client| !client.refused.is_empty())
            .await;
        client.refused[0].clone()
    };
    let now = now_millis();

    // Expired.
    let mut expired = spec(Roles::VIEWER, "late");
    expired.expires = Some(UnixMillis(now.0 - 1));
    let chain = grants::issue(&owner_device, daemon.daemon_id(), &expired, now);
    assert!(refused(with_chain(chain)).await.contains("InvalidGrant"));

    // Forged: signed by a key the daemon does not trust.
    let stranger = DeviceKey::generate();
    let chain = grants::issue(&stranger, daemon.daemon_id(), &spec(Roles::OWNER, "x"), now);
    assert!(refused(with_chain(chain)).await.contains("InvalidGrant"));

    // Tampered: roles raised after signing.
    let mut chain = grants::issue(
        &owner_device,
        daemon.daemon_id(),
        &spec(Roles::VIEWER, "t"),
        now,
    );
    chain.links[0].grant.roles = Roles::OWNER;
    assert!(refused(with_chain(chain)).await.contains("InvalidGrant"));

    // Escalated: a viewer who may delegate signs a driver child by hand.
    let mut deleg = spec(Roles::VIEWER, "v");
    deleg.delegate = true;
    let holder = DeviceKey::generate();
    deleg.bind = Some(holder.device_id());
    let parent = grants::issue(&owner_device, daemon.daemon_id(), &deleg, now);
    assert!(grants::attenuate(&parent, &holder, &spec(Roles::DRIVER, "d"), now).is_err());
    let mut forged = parent.clone();
    let mut child = parent.links[0].grant.clone();
    child.grant_id = client_core::proto::GrantId(grants::random());
    child.issuer = holder.device_id();
    child.roles = Roles::DRIVER;
    child.bind = None;
    let sig = holder.sign(&child.signing_bytes());
    forged
        .links
        .push(client_core::proto::GrantLink { grant: child, sig });
    assert!(refused(with_chain(forged)).await.contains("InvalidGrant"));

    // Scope widening: a pane-scoped grant cannot be attenuated to the whole daemon.
    let mut narrow = spec(Roles::VIEWER, "p");
    narrow.scope = Scope::Pane(pane);
    narrow.delegate = true;
    narrow.bind = Some(holder.device_id());
    let parent = grants::issue(&owner_device, daemon.daemon_id(), &narrow, now);
    assert_eq!(
        grants::attenuate(&parent, &holder, &spec(Roles::VIEWER, "w"), now).unwrap_err(),
        grants::GrantError::ScopeWidened(1)
    );

    // Used up: single use, second device refused; the first can still reconnect.
    let mut first = TestClient::join(&base.to_string(), ClientConfig::generate_key());
    first.client.attach(None);
    first.until("first joined", |c| c.layout.is_some()).await;
    assert!(refused(base.clone()).await.contains("InvalidGrant"));
    first.client.reconnect();
    first.until("rejoined", |c| c.connected >= 2).await;

    // All of it is in the audit log as denials.
    let page = owner.client.audit(None, 200).await.unwrap();
    let denials = page
        .records
        .iter()
        .filter(|record| record.kind == AuditKind::Denied)
        .count();
    assert!(denials >= 5, "{denials} denials");
    drop((first, owner));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn pane_scoped_guest_sees_only_its_pane() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let shared = owner.attach_and_follow().await;
    let OpOutcome::PaneCreated { pane_id: private } = owner
        .op(LayoutOp::Split {
            pane_id: shared,
            axis: client_core::proto::Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split failed")
    };
    let mut scoped = spec(Roles::DRIVER, "pam");
    scoped.scope = Scope::Pane(shared);
    let mut pam = guest(&invite(&owner, scoped).await, shared).await;
    let layout = pam.layout.clone().unwrap();
    assert_eq!(layout.tabs.len(), 1);
    assert_eq!(
        crate::support::leaves(&layout.tabs[0].root),
        vec![shared],
        "the private pane is hidden"
    );
    // Its own pane works; the other pane is out of reach.
    pam.type_line(shared, "echo pam-was-here");
    owner.wait_text(shared, "pam-was-here").await;
    pam.client.subscribe(private);
    pam.until("subscribe refused", |c| {
        c.mp.iter()
            .any(|event| matches!(event, MultiplayerEvent::Forbidden { what, .. } if what == "Subscribe"))
    })
    .await;
    pam.type_line(private, "echo leak");
    pam.until("input refused", |c| {
        rejected(c, private, InputRejectReason::UnknownPane)
    })
    .await;
    // Host-wide requests need a daemon- or session-wide grant.
    assert!(matches!(
        pam.client
            .workspace(WorkspaceRequest::FsList {
                path: "~".into(),
                show_hidden: false
            })
            .await,
        Err(WsError::Denied(_))
    ));
    drop((pam, owner));
    daemon.shutdown().await;
}

/// The owner's sharing list: every link with its terms and uses, its link again for copying,
/// and revoking one refuses it at once while the others keep working.
#[tokio::test(flavor = "multi_thread")]
async fn links_are_listed_shared_again_and_revoked() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let once = invite(&owner, spec(Roles::VIEWER, "once")).await;
    let mut open = spec(Roles::DRIVER | Roles::VIEWER, "open");
    open.max_uses = None;
    let open = invite(&owner, open).await;
    let mut ann = guest(&once, pane).await;

    let grants = owner.client.list_grants().await.unwrap();
    let listed = |id| {
        grants
            .iter()
            .find(|grant| grant.grant.grant_id == id)
            .unwrap()
    };
    let (single_use, reusable) = (listed(once.chain.grant_id()), listed(open.chain.grant_id()));
    assert_eq!(
        (single_use.grant.max_uses, single_use.bound.len()),
        (Some(1), 1)
    );
    assert_eq!((reusable.grant.max_uses, reusable.bound.len()), (None, 0));
    assert!(reusable.grant.roles.contains(Roles::DRIVER) && !reusable.revoked);

    // Its link again, the same invite the creator shared.
    let again = owner
        .client
        .invite_link(open.chain.grant_id(), "alice".into())
        .await
        .unwrap();
    assert_eq!(again.parse::<Invite>().unwrap(), open);
    assert!(matches!(
        owner
            .client
            .invite_link(client_core::proto::GrantId([9; 16]), "alice".into())
            .await,
        Err(MpError::NotFound(_))
    ));
    assert!(matches!(
        ann.client
            .invite_link(open.chain.grant_id(), "ann".into())
            .await,
        Err(MpError::Forbidden(_))
    ));

    // Revoked: whoever used it is out now and the link is refused; the other link works.
    owner
        .client
        .revoke(RevokeTarget::Grant(once.chain.grant_id()))
        .await
        .unwrap();
    ann.until("ann kicked", |c| {
        c.refused.iter().any(|reason| reason.contains("Revoked"))
    })
    .await;
    let mut late = TestClient::join(&once.to_string(), ClientConfig::generate_key());
    late.until("revoked link refused", |c| !c.refused.is_empty())
        .await;
    let mut bob = guest(&open, pane).await;
    owner.type_line(pane, "echo after-revoke");
    bob.wait_text(pane, "after-revoke").await;
    let grants = owner.client.list_grants().await.unwrap();
    assert!(
        grants
            .iter()
            .any(|grant| grant.grant.grant_id == once.chain.grant_id() && grant.revoked)
    );
    drop((ann, bob, late, owner));
    daemon.shutdown().await;
}

/// Removing one person disconnects their device at once and keeps them out, while others who
/// joined with the same link stay.
#[tokio::test(flavor = "multi_thread")]
async fn removing_a_person_keeps_the_link_for_everyone_else() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let mut team = spec(Roles::VIEWER, "team");
    team.max_uses = None;
    let link = invite(&owner, team).await;
    let ann_key = ClientConfig::generate_key();
    let mut ann = TestClient::join(&link.to_string(), ann_key.clone());
    ann.client.attach(None);
    ann.until("ann in", |c| c.layout.is_some()).await;
    let mut bob = guest(&link, pane).await;
    owner
        .until("both listed", |c| c.client.participant_list().len() == 3)
        .await;

    let ann_device = ann.client.me().unwrap().actor.device;
    let MpResponse::Revoked { disconnected, .. } = owner
        .client
        .revoke(RevokeTarget::Device(ann_device))
        .await
        .unwrap()
    else {
        unreachable!()
    };
    assert_eq!(disconnected, 1);
    ann.until("ann removed", |c| {
        c.mp.iter()
            .any(|event| matches!(event, MultiplayerEvent::Revoked))
    })
    .await;
    owner
        .until("ann gone", |c| {
            c.client
                .participant_list()
                .iter()
                .all(|participant| participant.actor.device != ann_device)
        })
        .await;
    // The same device cannot come back with the link; Bob is still here.
    drop(ann);
    let mut again = TestClient::join(&link.to_string(), ann_key);
    again
        .until("ann refused", |c| {
            c.refused.iter().any(|reason| reason.contains("Revoked"))
        })
        .await;
    owner.type_line(pane, "echo bob-stays");
    bob.wait_text(pane, "bob-stays").await;
    assert!(
        !owner
            .client
            .list_grants()
            .await
            .unwrap()
            .iter()
            .any(|grant| grant.revoked)
    );
    drop((again, bob, owner));
    daemon.shutdown().await;
}

/// A prompter pasting at line rate would burn the owner's agent quota and grow the audit log:
/// past a short burst it is refused, and the refusals are audited once, with a count.
#[tokio::test(flavor = "multi_thread")]
async fn a_prompt_flood_is_cut_and_audited_once() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = owner.attach_and_follow().await;
    hook(
        daemon.hook_socket(),
        &hook_request(dir.path(), agent_pane, "SessionStart", SESSION_START),
    )
    .await;
    start_fake_agent(
        &mut owner,
        agent_pane,
        "while read line; do echo \"agent-read:$line\"; done",
    )
    .await;
    let pat = guest(
        &invite(&owner, spec(Roles::PROMPTER, "pat")).await,
        agent_pane,
    )
    .await;

    let mut sent = 0;
    let mut refused = 0;
    for round in 0..30 {
        match pat
            .client
            .prompt(agent_pane, format!("echo flood-{round}"), false)
            .await
        {
            Ok(_) => sent += 1,
            Err(MpError::Failed(message)) => {
                assert!(message.contains("Wait a few seconds"), "{message}");
                refused += 1;
            }
            Err(other) => panic!("{other:?}"),
        }
    }
    assert_eq!((sent, refused), (5, 25));
    for round in 0..10 {
        owner
            .client
            .prompt(agent_pane, format!("echo owner-{round}"), false)
            .await
            .expect("the owner is not limited");
    }

    let page = owner.client.audit(None, 200).await.unwrap();
    let denied: Vec<_> = page
        .records
        .iter()
        .filter(|record| record.kind == AuditKind::Denied && record.detail.contains("prompt"))
        .collect();
    assert_eq!(denied.len(), 1, "{denied:#?}");
    let prompts = page
        .records
        .iter()
        .filter(|record| record.kind == AuditKind::Prompt)
        .count();
    assert_eq!(prompts, 15);
    drop((pat, owner));
    daemon.shutdown().await;
}

/// A guest reconnecting in a loop is recorded a few times, then counted, not written per visit.
#[tokio::test(flavor = "multi_thread")]
async fn a_reconnect_loop_does_not_grow_the_audit_log() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = daemon(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let link = invite(&owner, spec(Roles::VIEWER, "loop")).await;
    let key = ClientConfig::generate_key();
    for _ in 0..15 {
        let mut visit = TestClient::join(&link.to_string(), key.clone());
        visit.client.attach(None);
        visit.until("guest layout", |c| c.layout.is_some()).await;
        drop(visit);
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    let page = owner.client.audit(None, 500).await.unwrap();
    let visits = page
        .records
        .iter()
        .filter(|record| {
            matches!(record.kind, AuditKind::Join | AuditKind::Leave)
                && record.detail.starts_with("loop")
        })
        .count();
    assert!(visits <= 12, "{visits} join and leave records");
    drop(owner);
    daemon.shutdown().await;
}
