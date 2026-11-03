//! Device management from an owner device: a pairing ticket made over the connection pairs
//! one more device, once, and only paired owner devices may make one or rename a device.

use client_core::grants::GrantSpec;
use client_core::proto::{DaemonFeatures, DeviceKind, MpError, Roles, Scope, Ticket, UnixMillis};
use client_core::{ClientConfig, now_millis};

use crate::support::{TestClient, start, ticket};

#[tokio::test(flavor = "multi_thread")]
async fn owner_devices_pair_another_device_once_and_name_it() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    assert!(owner.client.can_manage_devices());
    assert!(
        daemon
            .info()
            .features
            .contains(DaemonFeatures::DEVICE_MANAGEMENT)
    );

    let (link, expires) = owner.client.pairing_ticket().await.unwrap();
    let parsed = Ticket::parse_with_extras(&link).unwrap().0;
    assert_eq!(parsed.expires, expires);
    let ttl = expires.0.saturating_sub(now_millis().0);
    assert!(
        (9 * 60_000..=10 * 60_000).contains(&ttl),
        "valid for ten minutes, not {ttl} ms"
    );

    let mut phone = TestClient::connect(&link, ClientConfig::generate_key());
    phone.attach_and_follow().await;
    let owners: Vec<_> = owner
        .client
        .list_devices()
        .await
        .unwrap()
        .into_iter()
        .filter(|device| device.kind == DeviceKind::Owner)
        .collect();
    assert_eq!(
        owners.len(),
        2,
        "the ticket paired the phone as an owner device"
    );

    let mut thief = TestClient::connect(&link, ClientConfig::generate_key());
    thief
        .until("a used ticket is refused", |client| {
            !client.refused.is_empty()
        })
        .await;

    let phone_device = phone.client.me().unwrap().actor.device;
    owner
        .client
        .rename_device(phone_device, "  Work\u{7}phone  ".into())
        .await
        .unwrap();
    phone.client.set_name("iPhone".into()).await.unwrap();
    let named = |devices: Vec<client_core::proto::DeviceInfo>| {
        devices
            .into_iter()
            .find(|device| device.device == phone_device)
            .map(|device| device.name)
    };
    assert_eq!(
        named(owner.client.list_devices().await.unwrap()).as_deref(),
        Some("Workphone"),
        "the owner's name stands over what the device says"
    );
    let listed = daemon::list_paired(dir.path()).unwrap();
    assert!(listed.iter().any(|device| device.name == "Workphone"));
    assert!(listed.iter().all(|device| device.last_seen > 0));

    owner
        .client
        .rename_device(phone_device, String::new())
        .await
        .unwrap();
    assert_eq!(
        named(owner.client.list_devices().await.unwrap()).as_deref(),
        Some("iPhone"),
        "an empty name goes back to the device's own"
    );
    assert!(matches!(
        owner
            .client
            .rename_device(client_core::proto::DeviceId([7; 32]), "x".into())
            .await,
        Err(MpError::NotFound(_))
    ));
    drop((owner, phone, thief));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn guests_never_pair_devices_whatever_their_roles() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let owner_device = owner.client.me().unwrap().actor.device;

    let mut spec = GrantSpec::new(Roles::VIEWER | Roles::DRIVER | Roles::OWNER, Scope::Daemon);
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "owner".into())
        .await
        .unwrap()
        .to_string();
    let mut guest = TestClient::join(&invite, ClientConfig::generate_key());
    guest.client.attach(None);
    guest
        .until("guest attached", |client| client.layout.is_some())
        .await;

    assert!(matches!(
        guest.client.pairing_ticket().await,
        Err(MpError::Forbidden(_))
    ));
    assert!(matches!(
        guest
            .client
            .rename_device(owner_device, "mine".into())
            .await,
        Err(MpError::Forbidden(_))
    ));
    assert_eq!(daemon::paired_devices(dir.path()).unwrap(), 1);
    let pending = std::fs::read_to_string(dir.path().join("pairing.json")).unwrap_or_default();
    assert!(
        pending.trim().is_empty() || pending.trim() == "[]",
        "a refused request mints nothing: {pending}"
    );
    drop((owner, guest));
    daemon.shutdown().await;
}
