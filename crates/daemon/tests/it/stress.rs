//! Load the daemon must stay bounded under: peers that stop reading, output that floods
//! metadata. The heavy versions live in `scripts/stress` (docs/STRESS.md).

use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::{LayoutOp, OpOutcome, PaneLaunch};
use iroh::endpoint::presets;
use iroh::{Endpoint, EndpointAddr, EndpointId};
use proto::{Caps, ClientCtl, DeviceId, GrantId, Hello, LinkClass, ServerCtl, SignedGrant, Ticket};

use crate::support::{self, TestClient};

type Raw = (
    Endpoint,
    iroh::endpoint::Connection,
    iroh::endpoint::SendStream,
    iroh::endpoint::RecvStream,
);

/// Pairs a raw connection with `ticket` and returns it once welcomed.
async fn raw_pair(ticket: &str) -> Raw {
    raw_dial(ticket, &ClientConfig::generate_key(), true).await
}

/// Dials as device `key`, pairing with the ticket's secret or as an already paired device.
async fn raw_dial(
    ticket: &str,
    key: &[u8],
    pairing: bool,
) -> (
    Endpoint,
    iroh::endpoint::Connection,
    iroh::endpoint::SendStream,
    iroh::endpoint::RecvStream,
) {
    let (ticket, _) = Ticket::parse_with_extras(ticket).unwrap();
    let secret = iroh::SecretKey::from_bytes(key.try_into().unwrap());
    let device = DeviceId(*secret.public().as_bytes());
    let endpoint = Endpoint::builder(presets::Minimal)
        .secret_key(secret)
        .bind()
        .await
        .unwrap();
    let mut addr = EndpointAddr::new(EndpointId::from_bytes(&ticket.daemon_id.0).unwrap());
    for a in &ticket.addrs {
        addr = addr.with_ip_addr(*a);
    }
    let conn = endpoint.connect(addr, proto::ALPN).await.unwrap();
    let (mut tx, mut rx) = conn.open_bi().await.unwrap();
    let hello = Hello {
        device_id: device,
        principal_id: ticket.principal,
        grant: if pairing {
            SignedGrant {
                v: SignedGrant::PAIRING,
                grant_id: GrantId([0; 16]),
                token: ticket.secret.0.to_vec(),
            }
        } else {
            SignedGrant {
                v: SignedGrant::DEVICE,
                grant_id: GrantId([0; 16]),
                token: Vec::new(),
            }
        },
        snapshot_format: u32::from(ghostty_vt::snapshot_format()),
        resume: Vec::new(),
        caps: Caps::ATTACH_RESULT,
        link: LinkClass::Normal,
        resume_token: None,
    };
    tx.write_all(&proto::frame::to_vec(&ClientCtl::Hello(hello)).unwrap())
        .await
        .unwrap();
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    rx.read_exact(&mut prefix).await.unwrap();
    let mut body = vec![0; proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).unwrap()];
    rx.read_exact(&mut body).await.unwrap();
    let first: ServerCtl = proto::frame::decode_body(&body).unwrap();
    assert!(matches!(first, ServerCtl::Welcome(_)), "{first:?}");
    // Nothing the daemon sends is read from here on.
    (endpoint, conn, tx, rx)
}

/// A peer that keeps asking but never reads used to grow the daemon's queue for it without
/// bound. It is disconnected instead, and everyone else carries on.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_client_that_stops_reading_is_disconnected() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start(dir.path()).await;
    let (_endpoint, conn, mut tx, _rx) = raw_pair(&support::ticket(&daemon)).await;

    // Each request is answered on `ctl`; the answers pile up once flow control stops them.
    let ask = proto::frame::to_vec(&ClientCtl::ListSessions).unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut sent = 0;
    while conn.close_reason().is_none() {
        assert!(
            Instant::now() < deadline,
            "the daemon kept a stuck client after {sent} requests"
        );
        sent += 500;
        if tx.write_all(&ask.repeat(500)).await.is_err() {
            break;
        }
        tokio::task::yield_now().await;
    }
    tokio::time::timeout(Duration::from_secs(10), conn.closed())
        .await
        .expect("closed by the daemon");

    let mut other = TestClient::connect(&support::ticket(&daemon), ClientConfig::generate_key());
    let pane = other.attach_and_follow().await;
    other.type_line(pane, "echo still-here");
    other.wait_text(pane, "still-here").await;
}

/// A paste bigger than one frame used to fail to encode on the client, which dropped the
/// connection and lost the paste. It arrives whole.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_paste_larger_than_a_frame_arrives_whole() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start(dir.path()).await;
    let mut c = TestClient::connect(&support::ticket(&daemon), ClientConfig::generate_key());
    let pane = c.attach_and_follow().await;
    const LEN: usize = 6 << 20;
    c.type_line(
        pane,
        &format!("stty raw -echo; head -c {LEN} | wc -c | tr -d ' '; stty sane"),
    );
    tokio::time::sleep(Duration::from_millis(500)).await;
    c.client.send_paste(pane, "a".repeat(LEN));
    c.wait_text(pane, &LEN.to_string()).await;
    assert_eq!(c.connected, 1, "the connection held");
}

/// One device holding many connections (a reconnect loop that never closes the old ones)
/// used to keep them all, each with what its streams hold in flight. The oldest are closed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_device_keeps_a_bounded_number_of_connections() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start(dir.path()).await;
    let key = ClientConfig::generate_key();
    let ticket = support::ticket(&daemon);
    let mut conns = vec![raw_dial(&ticket, &key, true).await];
    for _ in 0..20 {
        conns.push(raw_dial(&ticket, &key, false).await);
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let open = conns
            .iter()
            .filter(|(_, c, ..)| c.close_reason().is_none())
            .count();
        if open <= 16 {
            break;
        }
        assert!(Instant::now() < deadline, "{open} connections still open");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(conns[0].1.close_reason().is_some(), "the oldest went first");
    assert!(conns[20].1.close_reason().is_none(), "the newest stays");
}

/// A program setting its title in a tight loop used to push every title to every client. The
/// pushes are coalesced, and the last title always arrives.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn title_floods_are_coalesced() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start(dir.path()).await;
    let mut c = TestClient::connect(&support::ticket(&daemon), ClientConfig::generate_key());
    let first = c.attach_and_follow().await;
    let session = c.layout.as_ref().unwrap().session_id;
    let script = "i=0; while [ $i -lt 3000 ]; do printf '\\033]0;t%d\\007' $i; i=$((i+1)); \
                  done; printf '\\033]0;final\\007'; exec sleep 100";
    let OpOutcome::TabCreated { pane_id, .. } = c
        .op(LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch: PaneLaunch::Command {
                argv: vec!["/bin/sh".into(), "-c".into(), script.into()],
                cwd: None,
            },
        })
        .await
    else {
        panic!("no tab")
    };
    let before = c.meta_events;
    c.until("the final title", |c| {
        c.metas.get(&pane_id).is_some_and(|m| m.title == "final")
    })
    .await;
    let pushes = c.meta_events - before;
    assert!(pushes < 300, "{pushes} metadata pushes for 3001 titles");
    let _ = first;
}
