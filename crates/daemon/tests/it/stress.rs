//! Load the daemon must stay bounded under: peers that stop reading, output that floods
//! metadata. The heavy versions live in `scripts/stress` (docs/STRESS.md).

use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::{LayoutOp, OpOutcome, PaneLaunch};
use iroh::endpoint::presets;
use iroh::{Endpoint, EndpointAddr, EndpointId};
use proto::{
    Caps, ClientCtl, ClientInput, DeviceId, GrantId, Hello, Input, InputPayload, InputSeq,
    LinkClass, PaneId, PrincipalId, ResumeToken, ServerCtl, SignedGrant, StreamHeader, Ticket,
    Welcome,
};

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
async fn raw_dial(ticket: &str, key: &[u8], pairing: bool) -> Raw {
    dial_with(ticket, key, pairing, Caps::ATTACH_RESULT, None)
        .await
        .0
}

/// [`raw_dial`] announcing `caps` and presenting `token`; also returns the `Welcome`.
async fn dial_with(
    ticket: &str,
    key: &[u8],
    pairing: bool,
    caps: Caps,
    token: Option<ResumeToken>,
) -> (Raw, Welcome) {
    let (ticket, _) = Ticket::parse_with_extras(ticket).unwrap();
    let secret = iroh::SecretKey::from_bytes(key.try_into().unwrap());
    let device = DeviceId(*secret.public().as_bytes());
    let endpoint = Endpoint::builder(presets::Minimal)
        .secret_key(secret)
        .bind()
        .await
        .unwrap();
    let mut addr = EndpointAddr::new(EndpointId::from_bytes(&ticket.daemon_id.0).unwrap());
    for address in &ticket.addrs {
        addr = addr.with_ip_addr(*address);
    }
    let connection = endpoint.connect(addr, proto::ALPN).await.unwrap();
    let (mut tx, mut rx) = connection.open_bi().await.unwrap();
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
        caps,
        link: LinkClass::Normal,
        resume_token: token,
    };
    tx.write_all(&proto::frame::to_vec(&ClientCtl::Hello(hello)).unwrap())
        .await
        .unwrap();
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    rx.read_exact(&mut prefix).await.unwrap();
    let mut body = vec![0; proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).unwrap()];
    rx.read_exact(&mut body).await.unwrap();
    let first: ServerCtl = proto::frame::decode_body(&body).unwrap();
    let ServerCtl::Welcome(welcome) = first else {
        panic!("{first:?}")
    };
    // Nothing the daemon sends is read from here on.
    ((endpoint, connection, tx, rx), welcome)
}

#[tokio::test(flavor = "multi_thread")]
async fn welcome_downgrades_existing_panes_for_old_sizing_clients() {
    let directory = tempfile::tempdir().unwrap();
    let daemon = support::start(directory.path()).await;
    let mut owner = TestClient::connect(&support::ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    for (caps, expected) in [
        (Caps::default(), proto::SizePolicy::LastInput),
        (Caps::ACTIVE_SIZING, proto::SizePolicy::LastActive),
    ] {
        let ((endpoint, connection, _, _), welcome) = dial_with(
            &support::ticket(&daemon),
            &ClientConfig::generate_key(),
            true,
            caps,
            None,
        )
        .await;
        let meta = welcome
            .panes
            .iter()
            .find(|meta| meta.pane_id == pane)
            .expect("existing pane in Welcome");
        assert_eq!(meta.size_policy, expected);
        connection.close(0u32.into(), b"done");
        endpoint.close().await;
    }
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn sizing_identity_requires_its_own_capability_and_old_policies_stay_decodable() {
    let directory = tempfile::tempdir().unwrap();
    let daemon = support::start(directory.path()).await;
    for (extra_caps, wants_sizing, policy) in [
        (Caps::default(), false, proto::SizePolicy::LastInput),
        (Caps::ACTIVE_SIZING, false, proto::SizePolicy::LastActive),
        (Caps::PANE_SIZING, true, proto::SizePolicy::LastInput),
        (
            Caps::PANE_SIZING | Caps::ACTIVE_SIZING,
            true,
            proto::SizePolicy::LastActive,
        ),
    ] {
        let caps = Caps::ATTACH_RESULT | extra_caps;
        let ((endpoint, connection, mut tx, mut rx), _) = dial_with(
            &support::ticket(&daemon),
            &ClientConfig::generate_key(),
            true,
            caps,
            None,
        )
        .await;
        for message in [
            ClientCtl::Attach { session_id: None },
            ClientCtl::Ping { nonce: 99 },
        ] {
            tx.write_all(&proto::frame::to_vec(&message).unwrap())
                .await
                .unwrap();
        }
        let (mut saw_meta, mut saw_sizing) = (false, false);
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let mut prefix = [0; proto::frame::LEN_PREFIX];
                rx.read_exact(&mut prefix).await.unwrap();
                let mut body =
                    vec![0; proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).unwrap()];
                rx.read_exact(&mut body).await.unwrap();
                match proto::frame::decode_body::<ServerCtl>(&body).unwrap() {
                    ServerCtl::PaneMeta(meta) => {
                        assert_eq!(meta.size_policy, policy);
                        saw_meta = true;
                    }
                    ServerCtl::PaneSizing(_) => saw_sizing = true,
                    ServerCtl::Pong { nonce: 99 } => break,
                    _ => {}
                }
            }
        })
        .await
        .unwrap();
        assert!(saw_meta);
        assert_eq!(saw_sizing, wants_sizing);
        connection.close(0u32.into(), b"done");
        endpoint.close().await;
    }
}

/// A peer that keeps asking but never reads must not grow the daemon's queue for it without
/// bound: it is disconnected, and everyone else carries on.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_client_that_stops_reading_is_disconnected() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start(dir.path()).await;
    let (_endpoint, connection, mut tx, _rx) = raw_pair(&support::ticket(&daemon)).await;

    // Each request is answered on `ctl`; the answers pile up once flow control stops them.
    let ask = proto::frame::to_vec(&ClientCtl::ListSessions).unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut sent = 0;
    while connection.close_reason().is_none() {
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
    tokio::time::timeout(Duration::from_secs(10), connection.closed())
        .await
        .expect("closed by the daemon");

    let mut other = TestClient::connect(&support::ticket(&daemon), ClientConfig::generate_key());
    let pane = other.attach_and_follow().await;
    other.type_line(pane, "echo still-here");
    other.wait_text(pane, "still-here").await;
}

/// A paste bigger than one frame is split rather than failing to encode on the client (which
/// would drop the connection and lose the paste).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_paste_larger_than_a_frame_arrives_whole() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start(dir.path()).await;
    let mut client = TestClient::connect(&support::ticket(&daemon), ClientConfig::generate_key());
    let pane = client.attach_and_follow().await;
    const LEN: usize = 6 << 20;
    client.type_line(
        pane,
        &format!("stty raw -echo; head -c {LEN} | wc -c | tr -d ' '; stty sane"),
    );
    tokio::time::sleep(Duration::from_millis(500)).await;
    client.client.send_paste(pane, "a".repeat(LEN));
    client.wait_text(pane, &LEN.to_string()).await;
    assert_eq!(client.connected, 1, "the connection held");
}

/// One device holding many connections (a reconnect loop that never closes the old ones)
/// keeps a bounded number, each with what its streams hold in flight: the oldest are closed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_device_keeps_a_bounded_number_of_connections() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start(dir.path()).await;
    let key = ClientConfig::generate_key();
    let ticket = support::ticket(&daemon);
    let mut connections = vec![raw_dial(&ticket, &key, true).await];
    for _ in 0..20 {
        connections.push(raw_dial(&ticket, &key, false).await);
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let open = connections
            .iter()
            .filter(|(_, connection, ..)| connection.close_reason().is_none())
            .count();
        if open <= 16 {
            break;
        }
        assert!(Instant::now() < deadline, "{open} connections still open");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        connections[0].1.close_reason().is_some(),
        "the oldest went first"
    );
    assert!(
        connections[20].1.close_reason().is_none(),
        "the newest stays"
    );
}

/// A program that ignores SIGHUP would outlive its closed pane forever, with the pane's wait
/// thread; it is killed after a short grace period.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_process_ignoring_hangup_dies_with_its_pane() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start(dir.path()).await;
    let mut client = TestClient::connect(&support::ticket(&daemon), ClientConfig::generate_key());
    client.attach_and_follow().await;
    let session = client.layout.as_ref().unwrap().session_id;
    let marker = format!("{}", 900_000 + std::process::id() % 99_999);
    let OpOutcome::TabCreated { pane_id, .. } = client
        .op(LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch: PaneLaunch::Command {
                argv: vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    format!("trap '' HUP; exec sleep {marker}"),
                ],
                cwd: None,
            },
        })
        .await
    else {
        panic!("no tab")
    };
    let running = || {
        std::process::Command::new("pgrep")
            .args(["-f", &format!("sleep {marker}")])
            .output()
            .is_ok_and(|output| !output.stdout.is_empty())
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    while !running() {
        assert!(Instant::now() < deadline, "the program never started");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    client.op(LayoutOp::ClosePane { pane_id }).await;
    let deadline = Instant::now() + Duration::from_secs(10);
    while running() {
        assert!(
            Instant::now() < deadline,
            "still running after its pane closed"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Connections to the hook socket that never send a request would otherwise use up the
/// daemon's descriptors; they are closed, and hooks keep working.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn idle_hook_connections_are_closed() {
    use tokio::io::AsyncReadExt;
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start(dir.path()).await;
    let mut idle = Vec::new();
    for _ in 0..50 {
        idle.push(
            tokio::net::UnixStream::connect(daemon.hook_socket())
                .await
                .unwrap(),
        );
    }
    for mut stream in idle {
        let mut byte = [0u8; 1];
        let read = tokio::time::timeout(Duration::from_secs(20), stream.read(&mut byte)).await;
        assert!(
            matches!(read, Ok(Ok(0) | Err(_))),
            "an idle connection stayed open"
        );
    }
}

/// A program setting its title in a tight loop does not push every title to every client: the
/// pushes are coalesced, and the last title always arrives.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn title_floods_are_coalesced() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start(dir.path()).await;
    let mut client = TestClient::connect(&support::ticket(&daemon), ClientConfig::generate_key());
    let first = client.attach_and_follow().await;
    let session = client.layout.as_ref().unwrap().session_id;
    let script = "i=0; while [ $i -lt 3000 ]; do printf '\\033]0;t%d\\007' $i; i=$((i+1)); \
                  done; printf '\\033]0;final\\007'; exec sleep 100";
    let OpOutcome::TabCreated { pane_id, .. } = client
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
    let before = client.meta_events;
    client
        .until("the final title", |client| {
            client
                .metas
                .get(&pane_id)
                .is_some_and(|meta| meta.title == "final")
        })
        .await;
    let pushes = client.meta_events - before;
    assert!(pushes < 300, "{pushes} metadata pushes for 3001 titles");
    let _ = first;
}

/// Writes lines `seqs` to `pane` on a new input stream of `raw`, numbered as given.
async fn type_numbered(
    raw: &Raw,
    pane: PaneId,
    principal: PrincipalId,
    seqs: std::ops::RangeInclusive<u64>,
) {
    let mut input = raw.1.open_uni().await.unwrap();
    let mut bytes = proto::frame::to_vec(&StreamHeader::Input).unwrap();
    for seq in seqs {
        let frame = ClientInput::Input(Input {
            pane_id: pane,
            input_seq: InputSeq(seq),
            principal,
            payload: InputPayload::Bytes(format!("line {seq}\n").into_bytes()),
        });
        bytes.extend(proto::frame::to_vec(&frame).unwrap());
    }
    input.write_all(&bytes).await.unwrap();
    input.finish().unwrap();
}

/// The file's text once it contains `needle` (or after 10 s).
async fn file_with(path: &std::path::Path, needle: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        if text.contains(needle) || Instant::now() > deadline {
            return text;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Keystrokes written to a connection that then died (a frozen host) are sent again on the
/// next one, and the daemon applies each one once, although some of them had arrived over the
/// old connection.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn input_sent_again_after_a_reconnect_is_applied_once() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = support::start(dir.path()).await;
    let ticket = support::ticket(&daemon);
    let typed_file = dir.path().join("typed.txt");
    let mut client = TestClient::connect(&ticket, ClientConfig::generate_key());
    client.attach_and_follow().await;
    let session = client.layout.as_ref().unwrap().session_id;
    let OpOutcome::TabCreated { pane_id, .. } = client
        .op(LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch: PaneLaunch::Command {
                argv: vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    format!("stty raw -echo; exec cat > '{}'", typed_file.display()),
                ],
                cwd: None,
            },
        })
        .await
    else {
        panic!("no tab")
    };
    tokio::time::sleep(Duration::from_millis(500)).await;
    let ticket = support::ticket(&daemon);
    let principal = Ticket::parse_with_extras(&ticket).unwrap().0.principal;
    let key = ClientConfig::generate_key();
    let caps = Caps::INPUT_RESUME;

    let (first, welcome) = dial_with(&ticket, &key, true, caps, None).await;
    type_numbered(&first, pane_id, principal, 1..=5).await;
    file_with(&typed_file, "line 5").await;
    first.1.close(0u32.into(), b"link died");
    // The client cannot know 3..=5 arrived: it sends them again with what came after.
    let token = Some(welcome.resume_token);
    let (second, _) = dial_with(&ticket, &key, false, caps, token).await;
    type_numbered(&second, pane_id, principal, 3..=7).await;
    let text = file_with(&typed_file, "line 7").await;
    let lines: Vec<&str> = text
        .lines()
        .map(|line| line.trim_end_matches('\r'))
        .collect();
    let want: Vec<String> = (1..=7).map(|seq| format!("line {seq}")).collect();
    assert_eq!(lines, want);

    // Without the token it is another input stream, applied as it comes.
    let (third, _) = dial_with(&ticket, &key, false, caps, None).await;
    type_numbered(&third, pane_id, principal, 1..=1).await;
    let text = file_with(&typed_file, "line 7\nline 1").await;
    assert!(text.ends_with("line 7\nline 1\n"), "{text}");
}
