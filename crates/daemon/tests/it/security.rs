//! Transport, pairing and grant hardening end to end: device removal reaches live
//! connections and the invites a device signed, new pairings are announced, silent strangers
//! are dropped, a damaged grant store fails closed, and every guest role is held to the
//! enforcement table (docs/DAEMON.md §6.3).

use std::time::{Duration, Instant};

use client_core::grants::GrantSpec;
use client_core::proto::{
    ApprovalPolicy, ForwardTarget, GrantId, KnockId, LayoutOp, MpError, OpError, OpOutcome, PaneId,
    PaneLaunch, RevokeTarget, Roles, Scope, UnixMillis, WorkspaceRequest, WriteTarget, WsError,
};
use client_core::{ClientConfig, MultiplayerEvent, now_millis};

use crate::support::{TestClient, config, start, start_with, ticket};

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn spec(roles: Roles, label: &str) -> GrantSpec {
    let mut spec = GrantSpec::new(roles, Scope::Daemon);
    spec.label = label.into();
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    spec
}

async fn guest_of(owner: &TestClient, roles: Roles, label: &str) -> TestClient {
    let invite = owner
        .client
        .create_invite(spec(roles, label), "owner".into())
        .await
        .expect("invite");
    let mut guest = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    guest.client.attach(None);
    guest.until("guest attached", |c| c.layout.is_some()).await;
    guest
}

fn revoked(c: &TestClient) -> bool {
    c.mp.iter().any(|e| matches!(e, MultiplayerEvent::Revoked))
}

/// `hostd unpair` on a lost phone: its live connection closes, and so do the guests it
/// invited, without a daemon restart; the other owner device is untouched.
#[tokio::test(flavor = "multi_thread")]
async fn unpairing_from_the_cli_closes_the_device_and_its_invites() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut lost = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = lost.attach_and_follow().await;
    let mut kept = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    kept.follow(pane).await;
    let mut guest = guest_of(&lost, Roles::VIEWER, "guest").await;

    let device = lost.client.me().unwrap().actor.device;
    daemon::unpair_device(dir.path(), &hex(&device.0)[..16]).expect("unpair");

    lost.until("lost device closed", revoked).await;
    guest.until("its guest closed", revoked).await;
    kept.type_line(pane, "echo still-kept");
    kept.wait_text(pane, "still-kept").await;
    assert!(!revoked(&kept));
    // It cannot come back on its old pairing.
    lost.until("lost device refused", |c| !c.refused.is_empty())
        .await;
    drop((lost, kept, guest));
    daemon.shutdown().await;
}

/// Revoking an owner device from the app also closes the guests whose invites it signed.
#[tokio::test(flavor = "multi_thread")]
async fn revoking_an_owner_device_closes_the_guests_it_invited() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut phone = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    phone.attach_and_follow().await;
    let mut ipad = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    ipad.attach_and_follow().await;
    let mut from_phone = guest_of(&phone, Roles::DRIVER, "from-phone").await;
    let mut from_ipad = guest_of(&ipad, Roles::VIEWER, "from-ipad").await;

    let device = phone.client.me().unwrap().actor.device;
    ipad.client
        .revoke(RevokeTarget::Device(device))
        .await
        .expect("revoke");
    phone.until("phone closed", revoked).await;
    from_phone.until("its guest closed", revoked).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!revoked(&from_ipad), "invites from other devices stand");
    assert!(from_ipad.client.me().is_some());
    from_ipad
        .until("still served", |c| c.layout.is_some())
        .await;
    drop((phone, ipad, from_phone, from_ipad));
    daemon.shutdown().await;
}

/// A pairing is announced to the other owner devices, so one the owner did not make (a
/// phished ticket) is noticed.
#[tokio::test(flavor = "multi_thread")]
async fn a_new_pairing_is_announced_to_the_other_owner_devices() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut first = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    first.attach_and_follow().await;
    let mut second = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    second.attach_and_follow().await;
    let device = second.client.me().unwrap().actor.device;
    first
        .until("pairing announced", |c| {
            c.mp.iter().any(
                |e| matches!(e, MultiplayerEvent::DevicePaired { device: d } if d.device == device),
            )
        })
        .await;
    assert!(
        !second
            .mp
            .iter()
            .any(|e| matches!(e, MultiplayerEvent::DevicePaired { .. })),
        "the new device is not told about itself"
    );
    drop((first, second));
    daemon.shutdown().await;
}

/// A peer that completes the QUIC handshake but never says `Hello` is closed.
#[tokio::test(flavor = "multi_thread")]
async fn a_connection_that_never_says_hello_is_closed() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |c| c.hello_timeout = Duration::from_millis(500)).await;
    let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::Minimal)
        .clear_ip_transports()
        .bind_addr("127.0.0.1:0".parse::<std::net::SocketAddr>().unwrap())
        .unwrap()
        .bind()
        .await
        .unwrap();
    let id = iroh::EndpointId::from_bytes(&daemon.daemon_id().0).unwrap();
    let mut addr = iroh::EndpointAddr::new(id);
    for socket in daemon.bound_sockets() {
        addr = addr.with_ip_addr(socket);
    }
    let conn = endpoint
        .connect(addr, client_core::proto::ALPN)
        .await
        .unwrap();
    let start = Instant::now();
    tokio::time::timeout(Duration::from_secs(10), conn.closed())
        .await
        .expect("the daemon closes a silent connection");
    assert!(start.elapsed() < Duration::from_secs(5));
    endpoint.close().await;
    daemon.shutdown().await;
}

/// A grant store that cannot be read stops the daemon instead of starting it with every
/// revocation forgotten.
#[tokio::test(flavor = "multi_thread")]
async fn a_damaged_grant_store_fails_closed() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("grants.json"), b"{ not json").unwrap();
    let started = daemon::Daemon::start(config(dir.path())).await;
    let Err(e) = started else {
        panic!("the daemon started with a damaged grant store");
    };
    assert!(e.to_string().contains("grants.json"), "{e}");
    assert!(
        dir.path().join("grants.json").exists(),
        "the file is kept for the owner"
    );
}

/// What a guest role was refused for, if it was refused for its role.
fn role_refusal(result: Result<(), String>) -> bool {
    result.is_err_and(|e| e.contains("needs "))
}

fn ws<T>(r: Result<T, WsError>) -> Result<(), String> {
    r.map(drop).map_err(|e| match e {
        WsError::Denied(m) => m,
        other => format!("{other:?}"),
    })
}

fn mp<T>(r: Result<T, MpError>) -> Result<(), String> {
    r.map(drop).map_err(|e| match e {
        MpError::Forbidden(m) => m,
        other => format!("{other:?}"),
    })
}

fn op(outcome: OpOutcome) -> Result<(), String> {
    match outcome {
        OpOutcome::Failed {
            code: OpError::Forbidden,
            message,
        } => Err(message),
        _ => Ok(()),
    }
}

/// Every guest role against requests across the enforcement table: each is refused for its
/// role exactly when the table says so (other failures, such as a shell pane refusing a
/// prompt, do not count as a role refusal).
#[tokio::test(flavor = "multi_thread")]
async fn each_guest_role_gets_exactly_what_the_table_allows() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane: PaneId = owner.attach_and_follow().await;
    let session = owner.layout.as_ref().unwrap().session_id;
    let scratch = dir.path().join("scratch");
    std::fs::create_dir_all(&scratch).unwrap();

    #[derive(Clone, Copy, PartialEq, Debug)]
    enum Level {
        Prompt,
        Drive,
        Own,
    }
    for roles in [
        Roles::VIEWER,
        Roles::PROMPTER,
        Roles::APPROVER,
        Roles::DRIVER,
    ] {
        let mut g = guest_of(&owner, roles, "matrix").await;
        let c = &g.client;
        let file = scratch.join(format!("{}.txt", roles.names()));
        let target = WriteTarget {
            path: file.display().to_string(),
            if_match: None,
            create_new: false,
            mkdirs: false,
            mode: None,
        };
        let mut checks: Vec<(&str, Level, Result<(), String>)> = vec![
            (
                "prompt",
                Level::Prompt,
                mp(c.prompt(pane, "hi".into(), false).await),
            ),
            (
                "fs list",
                Level::Drive,
                ws(c.workspace(WorkspaceRequest::FsList {
                    path: scratch.display().to_string(),
                    show_hidden: false,
                })
                .await),
            ),
            (
                "fs write",
                Level::Drive,
                ws(c.fs_write(target.clone(), b"x".to_vec()).await),
            ),
            (
                "upload",
                Level::Drive,
                ws(c.upload_bytes(b"x".to_vec(), target).await),
            ),
            (
                "forward",
                Level::Drive,
                ws(c.forward_io(
                    ForwardTarget::Tcp { port: 1 },
                    tokio::io::empty(),
                    tokio::io::sink(),
                )
                .await),
            ),
            (
                "editor status",
                Level::Drive,
                ws(c.workspace(WorkspaceRequest::EditorStatus).await),
            ),
            (
                "take control",
                Level::Drive,
                mp(c.take_control(pane, false).await),
            ),
            (
                "push status",
                Level::Own,
                ws(c.workspace(WorkspaceRequest::PushStatus).await),
            ),
            (
                "usage watch off",
                Level::Own,
                ws(c.workspace(WorkspaceRequest::UsageUnwatch).await),
            ),
            ("list grants", Level::Own, mp(c.list_grants().await)),
            ("list devices", Level::Own, mp(c.list_devices().await)),
            ("audit", Level::Own, mp(c.audit(None, 10).await)),
            (
                "revoke",
                Level::Own,
                mp(c.revoke(RevokeTarget::Grant(GrantId([9; 16]))).await),
            ),
            (
                "answer knock",
                Level::Own,
                mp(c.answer_knock(KnockId(1), None).await),
            ),
            (
                "approval rules",
                Level::Own,
                mp(c.set_approval_policy(session, ApprovalPolicy::default())
                    .await),
            ),
        ];
        for (name, layout_op, level) in [
            (
                "split",
                LayoutOp::Split {
                    pane_id: pane,
                    axis: client_core::proto::Axis::Horizontal,
                    launch: PaneLaunch::Shell { cwd: None },
                },
                Level::Drive,
            ),
            (
                "close pane",
                LayoutOp::ClosePane { pane_id: pane },
                Level::Own,
            ),
            (
                "new session",
                LayoutOp::CreateSession {
                    name: String::new(),
                    launch: PaneLaunch::Shell { cwd: None },
                },
                Level::Own,
            ),
        ] {
            checks.push((name, level, op(g.op(layout_op).await)));
        }
        for (name, level, result) in checks {
            let allowed = match level {
                Level::Prompt => {
                    roles.allows_any(Roles::PROMPTER | Roles::DRIVER | Roles::APPROVER)
                }
                Level::Drive => roles.allows_any(Roles::DRIVER),
                Level::Own => false,
            };
            assert_eq!(
                role_refusal(result.clone()),
                !allowed,
                "{} {name}: {result:?}",
                roles.names()
            );
        }
        drop(g);
    }
    // Nothing a guest did closed the owner's pane or session.
    assert!(owner.layout.as_ref().is_some());
    drop(owner);
    daemon.shutdown().await;
}
