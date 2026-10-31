//! Attacks on pairing, grants and roles against a real daemon: each performs the attack and
//! asserts it is blocked.

use std::time::Duration;

use client_core::grants::{DeviceKey, GrantSpec, issue};
use client_core::knock::knock;
use client_core::proto::{History, Invite, InviteTerms, PaneId, Roles, Scope, UnixMillis};
use client_core::{ClientConfig, ConnectOptions, MultiplayerEvent, RelayMode, now_millis};

use crate::support::{TestClient, start, ticket};

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
    for c in clients.iter_mut() {
        c.until("admitted or refused", |c| {
            c.client.me().is_some() || !c.refused.is_empty()
        })
        .await;
    }
    clients.iter().filter(|c| c.client.me().is_some()).count()
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
            c.mp.iter().any(|e| matches!(e, MultiplayerEvent::Revoked))
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
        let mut g = TestClient::join(&link, ClientConfig::generate_key());
        g.client.attach(None);
        g.until("joined", |c| c.layout.is_some()).await;
        g.follow(pane).await;
        g.type_line(pane, &format!("echo typed-by-{mark}"));
        if roles == Roles::DRIVER {
            owner.wait_text(pane, "typed-by-driver").await;
        } else {
            g.until("input rejected", |c| {
                c.mp.iter()
                    .any(|e| matches!(e, MultiplayerEvent::InputRejected { .. }))
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
