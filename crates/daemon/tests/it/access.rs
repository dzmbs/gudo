//! Device removal and re-pairing, a damaged grant store, and the pre-`Hello` limits, against a
//! real daemon.

use std::time::Duration;

use client_core::grants::GrantSpec;
use client_core::proto::{RevokeTarget, Roles, Scope, UnixMillis};
use client_core::{ClientConfig, MultiplayerEvent, now_millis};

use crate::support::{TestClient, start, start_with, ticket};

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

async fn invite(owner: &TestClient, roles: Roles) -> String {
    let mut spec = GrantSpec::new(roles, Scope::Daemon);
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    owner
        .client
        .create_invite(spec, "owner".into())
        .await
        .expect("invite")
        .to_string()
}

async fn joined(invite: &str, key: Vec<u8>) -> TestClient {
    let mut guest = TestClient::join(invite, key);
    guest.client.attach(None);
    guest
        .until("guest attached", |client| client.layout.is_some())
        .await;
    guest
}

async fn refused(invite: &str, key: Vec<u8>) -> TestClient {
    let mut guest = TestClient::join(invite, key);
    guest
        .until("refused", |client| !client.refused.is_empty())
        .await;
    assert!(guest.layout.is_none());
    guest
}

fn is_revoked(client: &TestClient) -> bool {
    client
        .mp
        .iter()
        .any(|event| matches!(event, MultiplayerEvent::Revoked))
}

/// Removing an owner device from the app is like removing it from an Apple ID's device list:
/// it is signed out, every invite it made stops working, and only a fresh pairing ticket
/// brings it back, without those invites.
#[tokio::test(flavor = "multi_thread")]
async fn a_removed_device_returns_only_by_a_new_ticket_and_without_its_invites() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let key = ClientConfig::generate_key();
    let mut phone = TestClient::connect(&ticket(&daemon), key.clone());
    phone.attach_and_follow().await;
    let mut ipad = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    ipad.attach_and_follow().await;
    let old_invite = invite(&phone, Roles::VIEWER).await;
    let unused_invite = invite(&phone, Roles::VIEWER).await;
    let guest_key = ClientConfig::generate_key();
    let mut guest = joined(&old_invite, guest_key.clone()).await;

    let device = phone.client.me().unwrap().actor.device;
    ipad.client
        .revoke(RevokeTarget::Device(device))
        .await
        .expect("remove");
    phone.until("phone signed out", is_revoked).await;
    guest.until("its guest signed out", is_revoked).await;
    drop((phone, guest));

    // A fresh ticket from the owner brings the same key back as an owner…
    let mut phone = TestClient::connect(&ticket(&daemon), key.clone());
    phone.attach_and_follow().await;
    assert!(phone.client.me().is_some());
    // …but not the invites it signed before: neither the redeemed one nor one never used.
    drop(refused(&old_invite, guest_key.clone()).await);
    drop(refused(&unused_invite, ClientConfig::generate_key()).await);
    // What it signs now works.
    let fresh = invite(&phone, Roles::VIEWER).await;
    let guest = joined(&fresh, guest_key).await;
    drop((phone, ipad, guest));
    daemon.shutdown().await;
}

/// `hostd unpair` (the CLI) is the same removal: re-pairing the key does not bring back the
/// invites it signed before.
#[tokio::test(flavor = "multi_thread")]
async fn re_pairing_after_cli_unpair_does_not_revive_old_invites() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let key = ClientConfig::generate_key();
    let mut phone = TestClient::connect(&ticket(&daemon), key.clone());
    phone.attach_and_follow().await;
    let old_invite = invite(&phone, Roles::VIEWER).await;
    let device = phone.client.me().unwrap().actor.device;
    daemon::unpair_device(dir.path(), &hex(&device.0)[..16]).expect("unpair");
    phone.until("signed out", is_revoked).await;
    drop(phone);

    let mut phone = TestClient::connect(&ticket(&daemon), key);
    phone.attach_and_follow().await;
    drop(refused(&old_invite, ClientConfig::generate_key()).await);
    drop(phone);
    daemon.shutdown().await;
}

/// The old pairing of a removed device is refused as revoked; its key alone gets nothing.
#[tokio::test(flavor = "multi_thread")]
async fn a_removed_device_cannot_reconnect_on_its_old_pairing() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut phone = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    phone.attach_and_follow().await;
    let mut ipad = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    ipad.attach_and_follow().await;
    let device = phone.client.me().unwrap().actor.device;
    ipad.client
        .revoke(RevokeTarget::Device(device))
        .await
        .expect("remove");
    phone.until("signed out", is_revoked).await;
    // The client keeps redialling with its device grant: every attempt is refused.
    phone
        .until("reconnect refused", |client| {
            client
                .refused
                .iter()
                .any(|reason| reason.contains("Revoked"))
        })
        .await;
    assert_eq!(phone.connected, 1, "never admitted again");
    drop((phone, ipad));
    daemon.shutdown().await;
}

/// A revoked guest cannot use any invite from before the revocation, but a new invite the
/// owner makes afterwards lets them back (as re-inviting someone removed from a share).
#[tokio::test(flavor = "multi_thread")]
async fn a_revoked_guest_returns_only_by_a_newer_invite() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let mut multi = GrantSpec::new(Roles::VIEWER, Scope::Daemon);
    multi.max_uses = Some(5);
    let shared = owner
        .client
        .create_invite(multi, "owner".into())
        .await
        .unwrap()
        .to_string();
    let key = ClientConfig::generate_key();
    let mut guest = joined(&shared, key.clone()).await;
    let device = guest.client.me().unwrap().actor.device;
    owner
        .client
        .revoke(RevokeTarget::Device(device))
        .await
        .expect("revoke");
    guest.until("signed out", is_revoked).await;
    drop(guest);
    drop(refused(&shared, key.clone()).await);
    // Others still use the shared link.
    drop(joined(&shared, ClientConfig::generate_key()).await);
    tokio::time::sleep(Duration::from_millis(5)).await;
    let fresh = invite(&owner, Roles::VIEWER).await;
    drop(joined(&fresh, key).await);
    drop(owner);
    daemon.shutdown().await;
}

/// A grant store that cannot be read neither stops the daemon (that would lock the owner out
/// of a remote machine) nor forgets revocations: the file is kept aside, every guest invite
/// from before is refused, owner devices work and are told, and new invites work.
#[tokio::test(flavor = "multi_thread")]
async fn a_damaged_grant_store_fails_closed_for_guests_only() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let owner_key = ClientConfig::generate_key();
    let mut owner = TestClient::connect(&ticket(&daemon), owner_key.clone());
    owner.attach_and_follow().await;
    let link = invite(&owner, Roles::VIEWER).await;
    let guest_key = ClientConfig::generate_key();
    drop(joined(&link, guest_key.clone()).await);
    drop(owner);
    daemon.shutdown().await;

    let damaged = b"{ \"grants\": [ not json";
    std::fs::write(dir.path().join("grants.json"), damaged).unwrap();
    let daemon = start(dir.path()).await;
    let kept: Vec<_> = std::fs::read_dir(dir.path())
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("grants.json.unreadable-")
        })
        .collect();
    assert_eq!(kept.len(), 1, "the damaged file is kept aside");
    assert_eq!(std::fs::read(kept[0].path()).unwrap(), damaged);

    let mut owner = TestClient::connect(&ticket(&daemon), owner_key);
    owner.attach_and_follow().await;
    owner
        .until("owner alerted", |client| {
            client
                .mp
                .iter()
                .any(|event| matches!(event, MultiplayerEvent::HostAlert { .. }))
        })
        .await;
    drop(refused(&link, guest_key.clone()).await);
    let fresh = invite(&owner, Roles::VIEWER).await;
    drop(joined(&fresh, guest_key).await);
    drop(owner);
    daemon.shutdown().await;

    // The reset survives a restart: the old invite stays refused.
    let daemon = start(dir.path()).await;
    drop(refused(&link, ClientConfig::generate_key()).await);
    daemon.shutdown().await;
}

/// Strangers holding every pre-`Hello` slot do not lock out a paired device, which the
/// handshake identifies before its `Hello`.
#[tokio::test(flavor = "multi_thread")]
async fn a_paired_device_connects_while_strangers_fill_the_pre_hello_slots() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |config| {
        config.hello_timeout = Duration::from_secs(30);
        config.pre_auth = daemon::PreAuthLimits {
            handshakes: 64,
            handshakes_per_addr: 64,
            strangers: 4,
            strangers_per_addr: 4,
        };
    })
    .await;
    let key = ClientConfig::generate_key();
    let pairing = ticket(&daemon);
    let mut phone = TestClient::connect(&pairing, key.clone());
    phone.attach_and_follow().await;
    drop(phone);

    let id = iroh::EndpointId::from_bytes(&daemon.daemon_id().0).unwrap();
    let mut address = iroh::EndpointAddr::new(id);
    for socket in daemon.bound_sockets() {
        address = address.with_ip_addr(socket);
    }
    let mut strangers = Vec::new();
    for _ in 0..4 {
        let endpoint = stranger().await;
        let connection = endpoint
            .connect(address.clone(), client_core::proto::ALPN)
            .await
            .expect("a stranger gets a slot");
        strangers.push((endpoint, connection));
    }
    // The next stranger is turned away…
    let endpoint = stranger().await;
    let fifth = endpoint
        .connect(address.clone(), client_core::proto::ALPN)
        .await;
    if let Ok(connection) = fifth {
        tokio::time::timeout(Duration::from_secs(5), connection.closed())
            .await
            .expect("a stranger over the limit is closed");
    }
    // …while the paired device still connects (its ticket is spent: it dials as paired).
    let mut phone = TestClient::connect(&pairing, key);
    phone.attach_and_follow().await;
    assert!(
        strangers
            .iter()
            .all(|(_, connection)| connection.close_reason().is_none()),
        "the strangers are still waiting"
    );
    drop(phone);
    for (endpoint, _) in strangers {
        endpoint.close().await;
    }
    daemon.shutdown().await;
}

async fn stranger() -> iroh::Endpoint {
    iroh::Endpoint::builder(iroh::endpoint::presets::Minimal)
        .clear_ip_transports()
        .bind_addr("127.0.0.1:0".parse::<std::net::SocketAddr>().unwrap())
        .unwrap()
        .bind()
        .await
        .unwrap()
}
