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
