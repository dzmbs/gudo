//! Load the daemon must stay bounded under: peers that stop reading, output that floods
//! metadata. The heavy versions live in `scripts/stress` (docs/STRESS.md).

use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::{LayoutOp, OpOutcome, PaneLaunch};
use iroh::endpoint::presets;
use iroh::{Endpoint, EndpointAddr, EndpointId};
use proto::{
    BlobReply, Caps, ClientCtl, ClientInput, DeviceId, GrantId, Hello, Input, InputPayload,
    InputSeq, LinkClass, PaneId, PrincipalId, ResumePoint, ResumeToken, ServerCtl, SignedGrant,
    SnapGen, StreamHeader, SubscribeMode, Ticket, TransferReply, Welcome,
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
    dial_resuming(ticket, key, pairing, caps, token, Vec::new()).await
}

/// [`dial_with`] resuming the panes in `resume`.
async fn dial_resuming(
    ticket: &str,
    key: &[u8],
    pairing: bool,
    caps: Caps,
    token: Option<ResumeToken>,
    resume: Vec<ResumePoint>,
) -> (Raw, Welcome) {
    let (ticket, _) = Ticket::parse_with_extras(ticket).unwrap();
    let secret = iroh::SecretKey::from_bytes(key.try_into().unwrap());
    let device = DeviceId(*secret.public().as_bytes());
    // A peer that reads nothing holds the daemon's bytes only as far as its window allows.
    let small_window = iroh::endpoint::QuicTransportConfig::builder()
        .stream_receive_window((256u32 << 10).into())
        .build();
    let endpoint = Endpoint::builder(presets::Minimal)
        .secret_key(secret)
        .transport_config(small_window)
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
        resume,
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

/// Sends `messages` on a raw connection's `ctl`.
async fn send_ctl(tx: &mut iroh::endpoint::SendStream, messages: &[ClientCtl]) {
    let mut bytes = Vec::new();
    for message in messages {
        bytes.extend(proto::frame::to_vec(message).unwrap());
    }
    tx.write_all(&bytes).await.unwrap();
}

/// Reads a raw connection's `ctl` until `done` holds for a message, for at most `limit`.
async fn read_ctl_until(
    rx: &mut iroh::endpoint::RecvStream,
    limit: Duration,
    mut done: impl FnMut(&ServerCtl) -> bool,
) -> bool {
    tokio::time::timeout(limit, async {
        loop {
            let mut prefix = [0; proto::frame::LEN_PREFIX];
            rx.read_exact(&mut prefix).await.unwrap();
            let mut body = vec![0; proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).unwrap()];
            rx.read_exact(&mut body).await.unwrap();
            if done(&proto::frame::decode_body::<ServerCtl>(&body).unwrap()) {
                return;
            }
        }
    })
    .await
    .is_ok()
}

/// An owner client and `count` panes (tabs running `sleep`, the first a shell).
async fn owner_with_panes(daemon: &daemon::Daemon, count: usize) -> (TestClient, Vec<PaneId>) {
    let mut owner = TestClient::connect(&support::ticket(daemon), ClientConfig::generate_key());
    let mut panes = vec![owner.attach_and_follow().await];
    let session = owner.layout.as_ref().unwrap().session_id;
    while panes.len() < count {
        let OpOutcome::TabCreated { pane_id, .. } = owner
            .op(LayoutOp::NewTab {
                session_id: session,
                name: String::new(),
                launch: PaneLaunch::Command {
                    argv: vec!["sleep".into(), "600".into()],
                    cwd: None,
                },
            })
            .await
        else {
            panic!("no tab")
        };
        panes.push(pane_id);
    }
    (owner, panes)
}

fn subscriptions(panes: &[PaneId]) -> Vec<ClientCtl> {
    panes
        .iter()
        .map(|&pane_id| ClientCtl::Subscribe {
            pane_id,
            mode: SubscribeMode::Live,
            rows_hint: 30,
        })
        .collect()
}

/// A client following more panes than it lets the daemon open streams for (QUIC allows 100
/// by default, and this raw client never accepts one) still has its `ctl` answered.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn following_more_panes_than_the_client_takes_streams_for_keeps_ctl_answering() {
    let directory = tempfile::tempdir().unwrap();
    let daemon = support::start(directory.path()).await;
    let (_owner, panes) = owner_with_panes(&daemon, 120).await;
    let ((endpoint, _connection, mut tx, mut rx), _) = dial_with(
        &support::ticket(&daemon),
        &ClientConfig::generate_key(),
        true,
        Caps::ATTACH_RESULT,
        None,
    )
    .await;
    let mut messages = subscriptions(&panes);
    messages.push(ClientCtl::Ping { nonce: 7 });
    send_ctl(&mut tx, &messages).await;
    let answered = read_ctl_until(&mut rx, Duration::from_secs(5), |message| {
        matches!(message, ServerCtl::Pong { nonce: 7 })
    })
    .await;
    assert!(answered, "no pong after 120 subscriptions");
    endpoint.close().await;
}

/// The same for a client reconnecting with more resume points than it takes streams for,
/// which are replayed before its `ctl` is read.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn resuming_more_panes_than_the_client_takes_streams_for_keeps_ctl_answering() {
    let directory = tempfile::tempdir().unwrap();
    let daemon = support::start(directory.path()).await;
    let (_owner, panes) = owner_with_panes(&daemon, 120).await;
    let resume = panes
        .iter()
        .map(|&pane_id| ResumePoint {
            pane_id,
            last_seq: proto::Seq(0),
            snap_gen: SnapGen(0),
        })
        .collect();
    let ((endpoint, _connection, mut tx, mut rx), _) = dial_resuming(
        &support::ticket(&daemon),
        &ClientConfig::generate_key(),
        true,
        Caps::ATTACH_RESULT,
        None,
        resume,
    )
    .await;
    send_ctl(&mut tx, &[ClientCtl::Ping { nonce: 8 }]).await;
    let answered = read_ctl_until(&mut rx, Duration::from_secs(5), |message| {
        matches!(message, ServerCtl::Pong { nonce: 8 })
    })
    .await;
    assert!(answered, "no pong after resuming 120 panes");
    endpoint.close().await;
}

/// The app follows more panes than QUIC's default stream limit, and every one streams.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_app_follows_more_panes_than_quics_default_stream_limit() {
    let directory = tempfile::tempdir().unwrap();
    let daemon = support::start(directory.path()).await;
    let (mut owner, panes) = owner_with_panes(&daemon, 120).await;
    for &pane in &panes {
        owner.client.subscribe(pane);
    }
    owner
        .until("a snapshot of every pane", |client| {
            panes
                .iter()
                .all(|&pane| client.client.pane_seq(pane).is_some())
        })
        .await;
}

/// Following panes past the per-connection cap is refused with a reason, and the connection
/// carries on.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn subscriptions_past_the_cap_are_refused() {
    let directory = tempfile::tempdir().unwrap();
    let daemon = support::start_with(directory.path(), |config| {
        config.connection.pane_streams = 4;
    })
    .await;
    let (_owner, panes) = owner_with_panes(&daemon, 6).await;
    let ((endpoint, _connection, mut tx, mut rx), _) = dial_with(
        &support::ticket(&daemon),
        &ClientConfig::generate_key(),
        true,
        Caps::ATTACH_RESULT,
        None,
    )
    .await;
    let mut messages = subscriptions(&panes);
    messages.push(ClientCtl::Ping { nonce: 9 });
    send_ctl(&mut tx, &messages).await;
    let mut refused = 0;
    let answered = read_ctl_until(&mut rx, Duration::from_secs(5), |message| {
        if let ServerCtl::Forbidden { what, reason } = message {
            assert_eq!(what, "Subscribe");
            assert!(reason.contains("at most 4"), "{reason}");
            refused += 1;
        }
        matches!(message, ServerCtl::Pong { nonce: 9 })
    })
    .await;
    assert!(answered);
    assert_eq!(refused, 2);
    endpoint.close().await;
}

/// Reads one frame from a raw stream.
async fn recv_frame<T: serde::de::DeserializeOwned>(rx: &mut iroh::endpoint::RecvStream) -> T {
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    rx.read_exact(&mut prefix).await.unwrap();
    let mut body = vec![0; proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).unwrap()];
    rx.read_exact(&mut body).await.unwrap();
    proto::frame::decode_body(&body).unwrap()
}

/// Opens a raw bidirectional stream with `header`.
async fn open_with(
    connection: &iroh::endpoint::Connection,
    header: &StreamHeader,
) -> (iroh::endpoint::SendStream, iroh::endpoint::RecvStream) {
    let (mut tx, rx) = connection.open_bi().await.unwrap();
    tx.write_all(&proto::frame::to_vec(header).unwrap())
        .await
        .unwrap();
    (tx, rx)
}

/// A stream that never sends its header holds up nobody: the next one is served.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stream_without_a_header_does_not_hold_up_the_next() {
    let directory = tempfile::tempdir().unwrap();
    let allowed = directory.path().canonicalize().unwrap();
    let daemon = support::start_with(directory.path(), |config| {
        config.fs_allow.push(allowed.clone());
    })
    .await;
    let file = allowed.join("hello.txt");
    std::fs::write(&file, "hello").unwrap();
    let (endpoint, connection, _tx, _rx) = raw_pair(&support::ticket(&daemon)).await;
    let (mut silent, _silent_rx) = connection.open_bi().await.unwrap();
    silent.write_all(&[0]).await.unwrap();
    let header = StreamHeader::Download(proto::DownloadHeader {
        path: file.to_string_lossy().into_owned(),
        offset: 0,
        len: None,
    });
    let (_download, mut replies) = open_with(&connection, &header).await;
    let reply = tokio::time::timeout(Duration::from_secs(5), recv_frame(&mut replies)).await;
    assert!(
        matches!(reply, Ok(TransferReply::Ready { len: 5, .. })),
        "{reply:?}"
    );
    endpoint.close().await;
}

/// An upload whose sender goes quiet (the connection itself kept alive) fails after the stall
/// timeout and leaves nothing behind, instead of holding a blocking thread forever.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_upload_that_stops_sending_fails_and_leaves_nothing() {
    let directory = tempfile::tempdir().unwrap();
    let allowed = directory.path().canonicalize().unwrap();
    let daemon = support::start_with(directory.path(), |config| {
        config.connection.stall = Duration::from_secs(1);
        config.fs_allow.push(allowed.clone());
    })
    .await;
    let target = allowed.join("uploads");
    std::fs::create_dir_all(&target).unwrap();
    let (endpoint, connection, _tx, _rx) = raw_pair(&support::ticket(&daemon)).await;
    let header = StreamHeader::Upload(proto::UploadHeader {
        target: proto::WriteTarget {
            path: target.join("big.bin").to_string_lossy().into_owned(),
            if_match: None,
            create_new: false,
            mkdirs: false,
            mode: None,
        },
        size: 1000,
    });
    let (mut upload, mut replies) = open_with(&connection, &header).await;
    let ready: TransferReply = recv_frame(&mut replies).await;
    assert!(matches!(ready, TransferReply::Ready { .. }), "{ready:?}");
    upload.write_all(&[7; 10]).await.unwrap();
    let reply = tokio::time::timeout(Duration::from_secs(10), recv_frame(&mut replies)).await;
    assert!(
        matches!(reply, Ok(TransferReply::Failed(_))),
        "the upload is still waiting: {reply:?}"
    );
    let left: Vec<_> = std::fs::read_dir(&target).unwrap().collect();
    assert!(left.is_empty(), "{left:?}");
    endpoint.close().await;
}

/// A PNG header followed by `size` bytes of padding: what the daemon checks of an image.
fn padded_png(size: usize) -> Vec<u8> {
    let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR\0\0\0\x10\0\0\0\x10".to_vec();
    png.resize(size, 0);
    png
}

/// Only a few blob streams run at once per connection, the rest wait their turn, and one
/// nobody reads gives its turn up.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_blob_download_nobody_reads_gives_up_its_turn() {
    let directory = tempfile::tempdir().unwrap();
    let daemon = support::start_with(directory.path(), |config| {
        config.connection.stall = Duration::from_secs(1);
        config.connection.transfers = 1;
    })
    .await;
    let (owner, _) = owner_with_panes(&daemon, 1).await;
    let session = owner.layout.as_ref().unwrap().session_id;
    let (endpoint, connection, _tx, _rx) = raw_pair(&support::ticket(&daemon)).await;
    let image = padded_png(31 << 20);
    let header = StreamHeader::Blob(proto::BlobHeader::Put {
        session_id: session,
        size: image.len() as u64,
        media: proto::MediaType::Png,
    });
    let (mut put, mut replies) = open_with(&connection, &header).await;
    assert_eq!(
        recv_frame::<BlobReply>(&mut replies).await,
        BlobReply::Ready
    );
    put.write_all(&image).await.unwrap();
    let BlobReply::Stored(stored) = recv_frame(&mut replies).await else {
        panic!("not stored")
    };
    assert_eq!(stored.size, image.len() as u64);

    let get = StreamHeader::Blob(proto::BlobHeader::Get { hash: stored.hash });
    let (_unread_tx, _unread) = open_with(&connection, &get).await;
    let (_waiting_tx, mut waiting) = open_with(&connection, &get).await;
    let found = tokio::time::timeout(Duration::from_secs(10), recv_frame(&mut waiting)).await;
    assert!(
        matches!(found, Ok(BlobReply::Found(_))),
        "the second download never got its turn: {found:?}"
    );
    endpoint.close().await;
}

/// Pane queries past the per-connection budget are refused at once rather than queued
/// without bound, and `ctl` keeps being answered.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pane_queries_past_the_budget_are_refused() {
    let directory = tempfile::tempdir().unwrap();
    let daemon = support::start_with(directory.path(), |config| {
        config.connection.requests_running = 1;
        config.connection.requests_waiting = 2;
    })
    .await;
    let (_owner, panes) = owner_with_panes(&daemon, 1).await;
    let ((endpoint, _connection, mut tx, mut rx), _) = dial_with(
        &support::ticket(&daemon),
        &ClientConfig::generate_key(),
        true,
        Caps::ATTACH_RESULT,
        None,
    )
    .await;
    let mut messages: Vec<ClientCtl> = (0..200)
        .map(|req_id| ClientCtl::Links {
            req_id,
            pane_id: panes[0],
            commands: 1000,
        })
        .collect();
    messages.push(ClientCtl::Ping { nonce: 11 });
    send_ctl(&mut tx, &messages).await;
    let (mut answered, mut busy) = (0, 0);
    let pong = read_ctl_until(&mut rx, Duration::from_secs(10), |message| {
        if let ServerCtl::LinksResult { result, .. } = message {
            answered += 1;
            if matches!(result, Err(proto::RpcError::Internal(why)) if why.starts_with("busy")) {
                busy += 1;
            }
        }
        matches!(message, ServerCtl::Pong { nonce: 11 })
    })
    .await;
    assert!(pong);
    assert!(busy > 0, "{answered} answered, none refused");
    endpoint.close().await;
}
