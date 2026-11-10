//! Recovery: a dead path is given up on quickly, the foreground redials at once whatever the
//! backoff, and a network change never throws away a dial that is about to finish.

use std::net::UdpSocket;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use client_core::ClientEvent;
use client_core::proto::{
    self, ClientCtl, DaemonId, PairingSecret, PrincipalId, ResumeToken, Roles, ServerCtl,
    SessionEpoch, Ticket, UnixMillis, Welcome,
};
use iroh::endpoint::presets;

fn ticket_for(daemon_id: DaemonId, addrs: Vec<std::net::SocketAddr>) -> Ticket {
    Ticket {
        v: Ticket::VERSION,
        daemon_id,
        addrs,
        relay_url: None,
        principal: PrincipalId([2; 16]),
        secret: PairingSecret([3; 16]),
        expires: UnixMillis(0),
    }
}

/// A daemon stand-in that welcomes each client after `welcome_delay`. Returns its ticket and
/// the number of QUIC connections it has accepted.
async fn welcoming_daemon(welcome_delay: Duration) -> (iroh::Endpoint, Ticket, Arc<AtomicUsize>) {
    let endpoint = iroh::Endpoint::builder(presets::Minimal)
        .alpns(vec![proto::ALPN.to_vec()])
        .clear_ip_transports()
        .bind_addr("127.0.0.1:0".parse::<std::net::SocketAddr>().unwrap())
        .unwrap()
        .bind()
        .await
        .unwrap();
    let ticket = ticket_for(
        DaemonId(*endpoint.id().as_bytes()),
        endpoint.bound_sockets(),
    );
    let accepted = Arc::new(AtomicUsize::new(0));
    let server = endpoint.clone();
    let accepted_count = Arc::clone(&accepted);
    let daemon_id = ticket.daemon_id;
    tokio::spawn(async move {
        while let Some(incoming) = server.accept().await {
            accepted_count.fetch_add(1, Ordering::SeqCst);
            tokio::spawn(async move {
                let Ok(connection) = incoming.await else {
                    return;
                };
                let Ok((mut control_tx, mut control_rx)) = connection.accept_bi().await else {
                    return;
                };
                let mut prefix = [0; proto::frame::LEN_PREFIX];
                if control_rx.read_exact(&mut prefix).await.is_err() {
                    return;
                }
                let length = proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).unwrap();
                let mut hello_bytes = vec![0; length];
                if control_rx.read_exact(&mut hello_bytes).await.is_err() {
                    return;
                }
                let _: ClientCtl = proto::frame::decode_body(&hello_bytes).unwrap();
                tokio::time::sleep(welcome_delay).await;
                let welcome = ServerCtl::Welcome(Welcome {
                    daemon_id,
                    session_epoch: SessionEpoch(1),
                    roles: Roles::OWNER,
                    snapshot_format: u32::from(ghostty_vt::snapshot_format()),
                    panes: vec![],
                    resume_token: ResumeToken(vec![1]),
                });
                if control_tx
                    .write_all(&proto::frame::to_vec(&welcome).unwrap())
                    .await
                    .is_err()
                {
                    return;
                }
                connection.closed().await;
            });
        }
    });
    (endpoint, ticket, accepted)
}

async fn wait_for(
    events: &mut tokio::sync::mpsc::UnboundedReceiver<ClientEvent>,
    within: Duration,
    mut predicate: impl FnMut(&ClientEvent) -> bool,
) -> bool {
    tokio::time::timeout(within, async {
        while let Some(event) = events.recv().await {
            if predicate(&event) {
                return;
            }
        }
    })
    .await
    .is_ok()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_dial_to_a_silent_address_is_given_up_long_before_the_idle_timeout() {
    let silent_socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    let unreachable_daemon = iroh::SecretKey::from_bytes(&[7; 32]).public();
    let ticket = ticket_for(
        DaemonId(*unreachable_daemon.as_bytes()),
        vec![silent_socket.local_addr().unwrap()],
    );
    let started = Instant::now();
    let (_client, mut events) = super::connect(&ticket.to_string(), false);
    let gave_up = wait_for(&mut events, Duration::from_secs(15), |event| {
        matches!(event, ClientEvent::Disconnected { .. })
    })
    .await;
    assert!(gave_up, "the dial never ended");
    let elapsed = started.elapsed();
    assert!(
        elapsed < Duration::from_secs(6),
        "a dead path held the dial for {elapsed:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn resuming_in_the_foreground_redials_at_once_whatever_the_backoff() {
    let (endpoint, ticket, admitted) = super::redial::flaky_daemon().await;
    let (client, _events) = super::connect(&ticket.to_string(), false);
    tokio::time::sleep(Duration::from_secs(3)).await;
    let before = admitted.load(Ordering::SeqCst);
    let redialled = tokio::time::timeout(Duration::from_secs(5), async {
        while admitted.load(Ordering::SeqCst) == before {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;
    assert!(redialled.is_ok(), "the client stopped dialling");
    let after_a_backed_off_dial = admitted.load(Ordering::SeqCst);
    client.suspend();
    client.resume_now();
    let resumed_at_once = tokio::time::timeout(Duration::from_millis(600), async {
        while admitted.load(Ordering::SeqCst) == after_a_backed_off_dial {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;
    assert!(
        resumed_at_once.is_ok(),
        "the foreground waited out the backoff"
    );
    drop(client);
    endpoint.close().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_network_change_during_a_dial_lets_it_finish() {
    let (endpoint, ticket, accepted) = welcoming_daemon(Duration::from_millis(800)).await;
    let (client, mut events) = super::connect(&ticket.to_string(), false);
    let network_changes = async {
        for _ in 0..5 {
            tokio::time::sleep(Duration::from_millis(150)).await;
            client.network_changed();
        }
    };
    let connected = async {
        wait_for(&mut events, Duration::from_secs(10), |event| {
            matches!(event, ClientEvent::Connected { .. })
        })
        .await
    };
    let ((), connected) = tokio::join!(network_changes, connected);
    assert!(connected, "the client never connected");
    assert_eq!(
        accepted.load(Ordering::SeqCst),
        1,
        "network changes restarted the dial"
    );
    drop(client);
    endpoint.close().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_host_frozen_while_away_is_redialled_soon_after_the_app_returns() {
    let (ticket, freeze) = super::liveness::host(Duration::ZERO);
    let (client, mut events) = super::connect(&ticket.to_string(), false);
    assert!(
        wait_for(&mut events, Duration::from_secs(10), |event| {
            matches!(event, ClientEvent::Connected { .. })
        })
        .await
    );
    freeze.send(()).unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;
    let returned = Instant::now();
    client.resume_now();
    assert!(
        wait_for(&mut events, Duration::from_secs(10), |event| {
            matches!(event, ClientEvent::Disconnected { .. })
        })
        .await
    );
    let elapsed = returned.elapsed();
    assert!(
        elapsed < client_core::PROBE_DEADLINE,
        "the frozen link looked live for {elapsed:?} after the app returned"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn an_idle_pane_reports_its_stream_open_after_a_reconnect() {
    let state_directory = tempfile::tempdir().unwrap();
    let daemon = super::daemon(state_directory.path()).await;
    let ticket = daemon
        .pairing_ticket(daemon::PAIRING_TTL)
        .unwrap()
        .to_string();
    let (client, mut events) = super::connect(&ticket, true);
    client.attach(None);
    let ClientEvent::Layout { layout } = super::next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Layout { .. })
    })
    .await
    else {
        unreachable!()
    };
    let pane = layout.tabs[0].focused;
    client.subscribe(pane);
    super::next_matching(
        &mut events,
        |event| matches!(event, ClientEvent::PaneSnapshot { pane_id, .. } if *pane_id == pane),
    )
    .await;
    tokio::time::sleep(Duration::from_millis(300)).await;

    client.reconnect();
    super::next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Connected { .. })
    })
    .await;
    super::next_matching(
        &mut events,
        |event| matches!(event, ClientEvent::PaneStreaming { pane_id } if *pane_id == pane),
    )
    .await;
    drop(client);
    daemon.shutdown().await;
}

/// A daemon stand-in that collects what a client sends after its Hello for `listen_for`, then
/// welcomes it, and reports what arrived before the Welcome.
async fn listening_daemon(
    listen_for: Duration,
) -> (
    iroh::Endpoint,
    Ticket,
    tokio::sync::oneshot::Receiver<Vec<ClientCtl>>,
) {
    let endpoint = iroh::Endpoint::builder(presets::Minimal)
        .alpns(vec![proto::ALPN.to_vec()])
        .clear_ip_transports()
        .bind_addr("127.0.0.1:0".parse::<std::net::SocketAddr>().unwrap())
        .unwrap()
        .bind()
        .await
        .unwrap();
    let ticket = ticket_for(
        DaemonId(*endpoint.id().as_bytes()),
        endpoint.bound_sockets(),
    );
    let (report_tx, report_rx) = tokio::sync::oneshot::channel();
    let server = endpoint.clone();
    let daemon_id = ticket.daemon_id;
    tokio::spawn(async move {
        let incoming = server.accept().await.unwrap();
        let connection = incoming.await.unwrap();
        let (mut control_tx, mut control_rx) = connection.accept_bi().await.unwrap();
        let _hello = super::liveness::read(&mut control_rx).await.unwrap();
        let mut before_welcome = Vec::new();
        let deadline = tokio::time::Instant::now() + listen_for;
        while let Ok(Some(request)) =
            tokio::time::timeout_at(deadline, super::liveness::read(&mut control_rx)).await
        {
            before_welcome.push(request);
        }
        let welcome = ServerCtl::Welcome(Welcome {
            daemon_id,
            session_epoch: SessionEpoch(1),
            roles: Roles::OWNER,
            snapshot_format: u32::from(ghostty_vt::snapshot_format()),
            panes: vec![],
            resume_token: ResumeToken(vec![1]),
        });
        let _ = report_tx.send(before_welcome);
        let _ = control_tx
            .write_all(&proto::frame::to_vec(&welcome).unwrap())
            .await;
        connection.closed().await;
    });
    (endpoint, ticket, report_rx)
}

#[tokio::test(flavor = "multi_thread")]
async fn session_requests_reach_the_daemon_without_waiting_for_its_welcome() {
    let (endpoint, ticket, before_welcome) = listening_daemon(Duration::from_millis(500)).await;
    let (client, _events) = super::connect(&ticket.to_string(), false);
    client.attach(None);
    let requests = tokio::time::timeout(Duration::from_secs(10), before_welcome)
        .await
        .expect("the daemon heard the client")
        .unwrap();
    assert!(
        requests
            .iter()
            .any(|request| matches!(request, ClientCtl::Attach { .. })),
        "the attach waited for the welcome: {requests:?}"
    );
    drop(client);
    endpoint.close().await;
}

/// A daemon stand-in that welcomes each client after `welcome_delay` and reports the link
/// class of every Hello it reads.
async fn link_reporting_daemon(
    welcome_delay: Duration,
) -> (
    iroh::Endpoint,
    Ticket,
    tokio::sync::mpsc::UnboundedReceiver<proto::LinkClass>,
) {
    let endpoint = iroh::Endpoint::builder(presets::Minimal)
        .alpns(vec![proto::ALPN.to_vec()])
        .clear_ip_transports()
        .bind_addr("127.0.0.1:0".parse::<std::net::SocketAddr>().unwrap())
        .unwrap()
        .bind()
        .await
        .unwrap();
    let ticket = ticket_for(
        DaemonId(*endpoint.id().as_bytes()),
        endpoint.bound_sockets(),
    );
    let (links_tx, links_rx) = tokio::sync::mpsc::unbounded_channel();
    let server = endpoint.clone();
    let daemon_id = ticket.daemon_id;
    tokio::spawn(async move {
        while let Some(incoming) = server.accept().await {
            let links_tx = links_tx.clone();
            tokio::spawn(async move {
                let Ok(connection) = incoming.await else {
                    return;
                };
                let Ok((mut control_tx, mut control_rx)) = connection.accept_bi().await else {
                    return;
                };
                let Some(ClientCtl::Hello(hello)) = super::liveness::read(&mut control_rx).await
                else {
                    return;
                };
                let _ = links_tx.send(hello.link);
                tokio::time::sleep(welcome_delay).await;
                let welcome = ServerCtl::Welcome(Welcome {
                    daemon_id,
                    session_epoch: SessionEpoch(1),
                    roles: Roles::OWNER,
                    snapshot_format: u32::from(ghostty_vt::snapshot_format()),
                    panes: vec![],
                    resume_token: ResumeToken(vec![1]),
                });
                let _ = control_tx
                    .write_all(&proto::frame::to_vec(&welcome).unwrap())
                    .await;
                connection.closed().await;
            });
        }
    });
    (endpoint, ticket, links_rx)
}

#[tokio::test(flavor = "multi_thread")]
async fn low_data_mode_turned_on_during_a_dial_reaches_the_daemon() {
    let (endpoint, ticket, mut hello_links) =
        link_reporting_daemon(Duration::from_millis(500)).await;
    let (client, _events) = super::connect(&ticket.to_string(), false);
    let first_link = tokio::time::timeout(Duration::from_secs(10), hello_links.recv())
        .await
        .expect("the client dialled")
        .unwrap();
    assert_eq!(first_link, proto::LinkClass::Normal);
    client.set_link(proto::LinkClass::Constrained);
    let next_link = tokio::time::timeout(Duration::from_secs(10), hello_links.recv())
        .await
        .expect("the client redialled with the link it was told")
        .unwrap();
    assert_eq!(next_link, proto::LinkClass::Constrained);
    drop(client);
    endpoint.close().await;
}

/// A daemon stand-in that announces `features`, welcomes each client and reports every
/// control message after the Hello with the number of the connection it came on.
async fn recording_daemon(
    features: proto::DaemonFeatures,
) -> (
    iroh::Endpoint,
    Ticket,
    tokio::sync::mpsc::UnboundedReceiver<(usize, ClientCtl)>,
) {
    let endpoint = iroh::Endpoint::builder(presets::Minimal)
        .alpns(vec![proto::ALPN.to_vec()])
        .clear_ip_transports()
        .bind_addr("127.0.0.1:0".parse::<std::net::SocketAddr>().unwrap())
        .unwrap()
        .bind()
        .await
        .unwrap();
    let ticket = ticket_for(
        DaemonId(*endpoint.id().as_bytes()),
        endpoint.bound_sockets(),
    );
    let (requests_tx, requests_rx) = tokio::sync::mpsc::unbounded_channel();
    let server = endpoint.clone();
    let daemon_id = ticket.daemon_id;
    tokio::spawn(async move {
        let mut connection_number = 0;
        while let Some(incoming) = server.accept().await {
            connection_number += 1;
            let requests_tx = requests_tx.clone();
            tokio::spawn(async move {
                let Ok(connection) = incoming.await else {
                    return;
                };
                let Ok((mut control_tx, mut control_rx)) = connection.accept_bi().await else {
                    return;
                };
                let Some(ClientCtl::Hello(_)) = super::liveness::read(&mut control_rx).await else {
                    return;
                };
                let info = ServerCtl::DaemonInfo(proto::DaemonInfo {
                    version: "0.0.0".into(),
                    build: "test".into(),
                    built_unix: 0,
                    protocol: proto::PROTOCOL_LEVEL,
                    min_client_protocol: 0,
                    features,
                    hostname: String::new(),
                    os: "linux".into(),
                    os_name: String::new(),
                    arch: "aarch64".into(),
                });
                let welcome = ServerCtl::Welcome(Welcome {
                    daemon_id,
                    session_epoch: SessionEpoch(1),
                    roles: Roles::OWNER,
                    snapshot_format: u32::from(ghostty_vt::snapshot_format()),
                    panes: vec![],
                    resume_token: ResumeToken(vec![1]),
                });
                for message in [info, welcome] {
                    if control_tx
                        .write_all(&proto::frame::to_vec(&message).unwrap())
                        .await
                        .is_err()
                    {
                        return;
                    }
                }
                while let Some(request) = super::liveness::read(&mut control_rx).await {
                    let _ = requests_tx.send((connection_number, request));
                }
            });
        }
    });
    (endpoint, ticket, requests_rx)
}

#[tokio::test(flavor = "multi_thread")]
async fn colors_set_while_away_reach_the_next_connection_once() {
    let (endpoint, ticket, mut requests) =
        recording_daemon(proto::DaemonFeatures::TERMINAL_COLORS).await;
    let (client, mut events) = super::connect(&ticket.to_string(), false);
    let is_connected = |event: &ClientEvent| matches!(event, ClientEvent::Connected { .. });
    assert!(wait_for(&mut events, Duration::from_secs(10), is_connected).await);
    client.suspend();
    assert!(
        wait_for(&mut events, Duration::from_secs(10), |event| {
            matches!(event, ClientEvent::Disconnected { .. })
        })
        .await
    );
    client.set_terminal_colors(proto::TerminalColors {
        foreground: [220, 220, 220],
        background: [20, 20, 20],
        cursor: None,
        palette: Vec::new(),
    });
    client.resume_now();
    assert!(wait_for(&mut events, Duration::from_secs(10), is_connected).await);
    let mut colors_sent = 0;
    while let Ok(Some((connection_number, request))) =
        tokio::time::timeout(Duration::from_secs(1), requests.recv()).await
    {
        if connection_number == 2 && matches!(request, ClientCtl::TerminalColors(_)) {
            colors_sent += 1;
        }
    }
    assert_eq!(colors_sent, 1);
    drop(client);
    endpoint.close().await;
}
