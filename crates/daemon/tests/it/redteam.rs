//! Attacks on pairing, grants and roles against a real daemon: each performs the attack and
//! asserts it is blocked.

use std::time::Duration;

use client_core::grants::{DeviceKey, GrantSpec, issue};
use client_core::knock::knock;
use client_core::proto::{
    AttentionKind, AttentionList, AttentionSeen, AuditKind, Axis, History, Invite, InviteTerms,
    LayoutOp, OpOutcome, PaneId, PaneLaunch, Roles, Scope, UnixMillis,
};
use client_core::{ClientConfig, ConnectOptions, MultiplayerEvent, RelayMode, now_millis};
use daemon::{Daemon, HookRequest};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use crate::support::{TestClient, start, start_with, ticket};

async fn invite_with(owner: &TestClient, spec: GrantSpec, terms: InviteTerms) -> String {
    owner
        .client
        .create_invite_with_terms(spec, "owner".into(), terms)
        .await
        .expect("invite")
        .to_string_with_terms(terms)
}

fn spec(roles: Roles) -> GrantSpec {
    let mut spec = GrantSpec::new(roles, Scope::Daemon);
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    spec
}

/// Pumps `clients` until each was either admitted or refused; returns how many were admitted.
async fn admitted(clients: &mut [TestClient]) -> usize {
    for client in clients.iter_mut() {
        client
            .until("admitted or refused", |c| {
                c.client.me().is_some() || !c.refused.is_empty()
            })
            .await;
    }
    clients
        .iter()
        .filter(|client| client.client.me().is_some())
        .count()
}

/// One pairing ticket raced by several devices at once pairs exactly one of them.
#[tokio::test(flavor = "multi_thread")]
async fn a_raced_pairing_ticket_pairs_one_device() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let link = ticket(&daemon);
    let mut racers: Vec<TestClient> = (0..6)
        .map(|_| TestClient::connect(&link, ClientConfig::generate_key()))
        .collect();
    assert_eq!(admitted(&mut racers).await, 1);
    assert_eq!(daemon.paired_devices(), 1);
    drop(racers);
    // Replayed after use, the ticket pairs nothing.
    let mut late = vec![TestClient::connect(&link, ClientConfig::generate_key())];
    assert_eq!(admitted(&mut late).await, 0);
    drop(late);
    daemon.shutdown().await;
}

/// A reusable demo-host ticket raced by more devices than it has uses pairs exactly its uses;
/// each new device is announced to the owner devices already connected, and revoking it stops
/// later devices.
#[tokio::test(flavor = "multi_thread")]
async fn a_raced_reusable_ticket_pairs_its_uses_and_announces_each() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let (link, id) =
        daemon::mint_reusable_ticket_text(dir.path(), daemon::PAIRING_TTL, 4).expect("mint");
    let mut first = TestClient::connect(&link, ClientConfig::generate_key());
    first.attach_and_follow().await;
    let mut racers: Vec<TestClient> = (0..6)
        .map(|_| TestClient::connect(&link, ClientConfig::generate_key()))
        .collect();
    assert_eq!(admitted(&mut racers).await, 3);
    assert_eq!(daemon.paired_devices(), 4);
    for racer in racers.iter().filter(|racer| racer.client.me().is_some()) {
        let device = racer.client.me().unwrap().actor.device;
        first
            .until("pairing announced", |client| {
                client.mp.iter().any(|event| {
                    matches!(event, MultiplayerEvent::DevicePaired { device: paired } if paired.device == device)
                })
            })
            .await;
    }
    drop(racers);

    let (revoked_link, revoked_id) =
        daemon::mint_reusable_ticket_text(dir.path(), daemon::PAIRING_TTL, 4).expect("mint");
    assert_ne!(revoked_id, id);
    daemon::revoke_pairing_tickets(dir.path(), Some(&revoked_id)).expect("revoke");
    let mut late = vec![
        TestClient::connect(&link, ClientConfig::generate_key()),
        TestClient::connect(&revoked_link, ClientConfig::generate_key()),
    ];
    assert_eq!(admitted(&mut late).await, 0);
    drop((first, late));
    daemon.shutdown().await;
}

/// A single-use invite redeemed by several devices at the same moment admits one.
#[tokio::test(flavor = "multi_thread")]
async fn a_raced_single_use_invite_admits_one_device() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let link = invite_with(&owner, spec(Roles::VIEWER), InviteTerms::default()).await;
    let mut racers: Vec<TestClient> = (0..6)
        .map(|_| TestClient::join(&link, ClientConfig::generate_key()))
        .collect();
    assert_eq!(admitted(&mut racers).await, 1);
    drop((owner, racers));
    daemon.shutdown().await;
}

/// An invite stops working when it expires, and a guest already in is closed then.
#[tokio::test(flavor = "multi_thread")]
async fn an_expired_invite_admits_nobody_and_ends_its_sessions() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let mut short = spec(Roles::VIEWER);
    short.max_uses = None;
    short.expires = Some(UnixMillis(now_millis().0 + 2_000));
    let link = invite_with(&owner, short, InviteTerms::default()).await;
    let mut inside = TestClient::join(&link, ClientConfig::generate_key());
    inside.client.attach(None);
    inside.until("joined", |c| c.layout.is_some()).await;
    tokio::time::sleep(Duration::from_millis(2_200)).await;
    inside
        .until("closed at expiry", |c| {
            c.mp.iter()
                .any(|event| matches!(event, MultiplayerEvent::Revoked))
        })
        .await;
    let mut late = vec![TestClient::join(&link, ClientConfig::generate_key())];
    assert_eq!(admitted(&mut late).await, 0);
    drop((owner, inside, late));
    daemon.shutdown().await;
}

/// A chain whose root a stranger signed (not the daemon or an owner device) is refused, even
/// when it is otherwise a well-formed invite for this daemon.
#[tokio::test(flavor = "multi_thread")]
async fn a_chain_rooted_at_a_stranger_key_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let real = invite_with(&owner, spec(Roles::VIEWER), InviteTerms::default()).await;
    let mut forged = Invite::parse_with_terms(&real).unwrap().0;
    let attacker = ClientConfig::generate_key();
    let key = DeviceKey::from_seed(&attacker).unwrap();
    let mut wide = GrantSpec::new(Roles::OWNER, Scope::Daemon);
    wide.max_uses = None;
    wide.delegate = true;
    forged.chain = issue(&key, forged.daemon_id, &wide, now_millis());
    let mut guest = vec![TestClient::join(&forged.to_string(), attacker)];
    assert_eq!(admitted(&mut guest).await, 0);
    drop((owner, guest));
    daemon.shutdown().await;
}

/// A stranger retrying made-up invites from one address spends a small budget and is then
/// turned away before its `Hello`: no more grant checks and no more audit records, while the
/// owner still gets in.
#[tokio::test(flavor = "multi_thread")]
async fn refused_joins_spend_a_budget_and_are_audited_sparingly() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = crate::support::start_with(dir.path(), |config| {
        config.pre_auth.failures = 4;
        config.pre_auth.failure_every = Duration::from_secs(3600);
    })
    .await;
    let owner_key = ClientConfig::generate_key();
    let pairing = ticket(&daemon);
    let mut owner = TestClient::connect(&pairing, owner_key.clone());
    owner.attach_and_follow().await;
    let real = invite_with(&owner, spec(Roles::VIEWER), InviteTerms::default()).await;
    let base = Invite::parse_with_terms(&real).unwrap().0;

    let mut refusals = 0;
    for _ in 0..10 {
        let attacker = ClientConfig::generate_key();
        let key = DeviceKey::from_seed(&attacker).unwrap();
        let mut forged = base.clone();
        forged.chain = issue(&key, forged.daemon_id, &spec(Roles::OWNER), now_millis());
        let mut guest = TestClient::join(&forged.to_string(), attacker);
        let answered = tokio::time::timeout(
            Duration::from_secs(2),
            guest.until("refused", |c| !c.refused.is_empty()),
        )
        .await;
        refusals += usize::from(answered.is_ok());
        assert!(guest.client.me().is_none());
    }
    // A refused client may retry once on its own; each retry spends the budget too.
    assert!(
        (1..=4).contains(&refusals),
        "past the budget nothing is checked or answered: {refusals}"
    );

    let page = owner.client.audit(None, 200).await.unwrap();
    let denials = page
        .records
        .iter()
        .filter(|record| record.kind == AuditKind::Denied)
        .count();
    assert!((1..=4).contains(&denials), "{denials} denials audited");
    drop(owner);
    let mut owner = TestClient::connect(&pairing, owner_key);
    owner.attach_and_follow().await;
    drop(owner);
    daemon.shutdown().await;
}

/// A leaked knock link cannot flood the owner: past the cap, more knocks are refused.
#[tokio::test(flavor = "multi_thread")]
async fn knock_spam_is_capped_per_invite() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let mut knocky = spec(Roles::VIEWER);
    knocky.max_uses = None;
    let terms = InviteTerms {
        knock: true,
        history: History::Full,
    };
    let link = invite_with(&owner, knocky, terms).await;
    let mut tasks = Vec::new();
    for i in 0..12 {
        let mut config = ClientConfig::new(ClientConfig::generate_key());
        config.relay = RelayMode::Disabled;
        let link = link.clone();
        tasks.push(tokio::spawn(async move {
            knock(
                &link,
                config,
                ConnectOptions::default(),
                Some(format!("spam {i}")),
                |_| {},
            )
            .await
        }));
    }
    owner
        .until("knocks arrive", |c| c.client.pending_knocks().len() >= 8)
        .await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    owner.until("settled", |_| true).await;
    assert_eq!(owner.client.pending_knocks().len(), 8);
    for task in tasks {
        task.abort();
    }
    drop(owner);
    daemon.shutdown().await;
}

/// Raw keystrokes (the `input` stream) need the driver role: a viewer's, prompter's or
/// approver's typing never reaches the shell.
#[tokio::test(flavor = "multi_thread")]
async fn only_drivers_type_into_a_pane() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane: PaneId = owner.attach_and_follow().await;
    for (roles, mark) in [
        (Roles::VIEWER, "viewer"),
        (Roles::PROMPTER, "prompter"),
        (Roles::APPROVER, "approver"),
        (Roles::DRIVER, "driver"),
    ] {
        let link = invite_with(&owner, spec(roles), InviteTerms::default()).await;
        let mut guest = TestClient::join(&link, ClientConfig::generate_key());
        guest.client.attach(None);
        guest.until("joined", |c| c.layout.is_some()).await;
        guest.follow(pane).await;
        guest.type_line(pane, &format!("echo typed-by-{mark}"));
        if roles == Roles::DRIVER {
            owner.wait_text(pane, "typed-by-driver").await;
        } else {
            guest
                .until("input rejected", |c| {
                    c.mp.iter()
                        .any(|event| matches!(event, MultiplayerEvent::InputRejected { .. }))
                })
                .await;
        }
    }
    let text = owner.text(pane);
    for mark in ["viewer", "prompter", "approver"] {
        assert!(!text.contains(&format!("typed-by-{mark}")), "{text}");
    }
    drop(owner);
    daemon.shutdown().await;
}

async fn claude_hook(
    daemon: &Daemon,
    state: &std::path::Path,
    pane: PaneId,
    event: &str,
    payload: serde_json::Value,
) {
    let request = HookRequest {
        v: 1,
        token: std::fs::read_to_string(state.join("hook.token")).unwrap(),
        pane: pane.0.to_string(),
        agent: "claude".into(),
        event: event.into(),
        seq: now_millis().0,
        payload,
    };
    let mut stream = UnixStream::connect(daemon.hook_socket()).await.unwrap();
    let mut line = serde_json::to_vec(&request).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
}

async fn pane_guest(owner: &TestClient, pane: PaneId, label: &str) -> TestClient {
    let mut spec = GrantSpec::new(Roles::VIEWER, Scope::Pane(pane));
    spec.label = label.into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "owner".into())
        .await
        .unwrap();
    let mut guest = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    guest.client.attach(None);
    guest.until("guest layout", |c| c.layout.is_some()).await;
    guest
}

fn blocked_seen(list: &AttentionList, pane: PaneId) -> Option<bool> {
    list.items
        .iter()
        .find(|item| {
            item.pane_id == pane && matches!(item.kind, AttentionKind::AgentBlocked { .. })
        })
        .map(|item| item.seen)
}

/// A guest's "seen" (marking, focusing, merely watching) is its own: it never clears the
/// owner's unseen items, which would silence the owner's notifications and pushes.
#[tokio::test(flavor = "multi_thread")]
async fn a_guest_cannot_mark_the_owners_attention_seen() {
    let state = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(home.path().join(".config")).unwrap();
    let daemon = start_with(state.path(), |config| {
        config.pane_env.insert(
            0,
            ("HOME".into(), home.path().to_string_lossy().into_owned()),
        );
    })
    .await;

    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.until("connected", |c| c.connected > 0).await;
    let shown = owner.attach_and_follow().await;
    let OpOutcome::PaneCreated { pane_id: blocked } = owner
        .op(LayoutOp::Split {
            pane_id: shown,
            axis: Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("split")
    };
    owner.client.set_view(Some(shown), vec![shown]);

    let elsewhere = pane_guest(&owner, shown, "elsewhere").await;
    let watcher = pane_guest(&owner, blocked, "watcher").await;
    watcher.client.set_view(Some(blocked), vec![blocked]);
    tokio::time::sleep(Duration::from_millis(300)).await;

    let cwd = home.path().to_string_lossy().into_owned();
    claude_hook(
        &daemon,
        state.path(),
        blocked,
        "UserPromptSubmit",
        serde_json::json!({
            "session_id": "s", "cwd": cwd, "hook_event_name": "UserPromptSubmit", "prompt": "go",
        }),
    )
    .await;
    claude_hook(
        &daemon,
        state.path(),
        blocked,
        "Notification",
        serde_json::json!({
            "session_id": "s", "cwd": cwd, "hook_event_name": "Notification",
            "message": "Claude needs your permission to use Bash",
            "notification_type": "permission_prompt",
        }),
    )
    .await;
    tokio::time::sleep(Duration::from_millis(300)).await;

    let list = owner.client.attention_list().await.unwrap();
    assert_eq!(
        blocked_seen(&list, blocked),
        Some(false),
        "a guest watching the pane does not make it seen for the owner: {list:#?}"
    );
    assert_eq!(list.unseen, 1);
    let watcher_list = watcher.client.attention_list().await.unwrap();
    assert_eq!(
        blocked_seen(&watcher_list, blocked),
        Some(true),
        "{watcher_list:#?}"
    );
    assert_eq!(watcher_list.unseen, 0);

    let everything = AttentionSeen {
        ids: vec![],
        up_to: Some(u64::MAX),
        pane_id: None,
    };
    let by_pane = AttentionSeen {
        ids: vec![],
        up_to: None,
        pane_id: Some(blocked),
    };
    let elsewhere_list = elsewhere
        .client
        .attention_seen(everything.clone())
        .await
        .unwrap();
    assert_eq!(
        blocked_seen(&elsewhere_list, blocked),
        None,
        "{elsewhere_list:#?}"
    );
    elsewhere
        .client
        .attention_seen(by_pane.clone())
        .await
        .unwrap();
    watcher
        .client
        .attention_seen(everything.clone())
        .await
        .unwrap();
    watcher.client.attention_seen(by_pane).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;

    let list = owner.client.attention_list().await.unwrap();
    assert_eq!(
        blocked_seen(&list, blocked),
        Some(false),
        "guests' marks stay their own: {list:#?}"
    );
    assert_eq!(list.unseen, 1);

    let list = owner.client.attention_seen(everything).await.unwrap();
    assert_eq!(list.unseen, 0, "the owner's own mark still works");

    drop(owner);
    drop(elsewhere);
    drop(watcher);
    daemon.shutdown().await;
}

/// Names reach other people's screens (participants, ballots, prompts "Bob is driving"), so
/// bidi and format characters that could make one name pass for another are dropped.
#[tokio::test(flavor = "multi_thread")]
async fn names_cannot_hide_or_reorder_text() {
    let state = tempfile::tempdir().unwrap();
    let daemon = start(state.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.until("connected", |c| c.connected > 0).await;
    let mut invite = spec(Roles::VIEWER);
    invite.label = "alice\u{202e}evad\u{200b}".into();
    let link = invite_with(&owner, invite, InviteTerms::default()).await;
    let mut guest = TestClient::join(&link, ClientConfig::generate_key());
    guest.until("joined", |c| c.connected > 0).await;

    let names = |participants: Vec<client_core::proto::Participant>| {
        participants
            .into_iter()
            .map(|participant| participant.name)
            .collect::<Vec<_>>()
    };
    let listed = names(owner.client.participants().await.unwrap());
    assert!(listed.contains(&"aliceevad".to_owned()), "{listed:?}");
    let labels: Vec<String> = owner
        .client
        .list_grants()
        .await
        .unwrap()
        .into_iter()
        .map(|info| info.grant.label)
        .collect();
    assert!(labels.contains(&"aliceevad".to_owned()), "{labels:?}");

    guest
        .client
        .set_name("bob\u{2067}\u{7} \t\n x\u{e0041}".into())
        .await
        .unwrap();
    let listed = names(owner.client.participants().await.unwrap());
    assert!(listed.contains(&"bob x".to_owned()), "{listed:?}");
    assert!(
        listed
            .iter()
            .all(|name| !name.chars().any(client_core::proto::is_invisible_format)),
        "{listed:?}"
    );

    drop(owner);
    drop(guest);
    daemon.shutdown().await;
}
