//! Liveness: a host that stops answering is noticed within seconds of a probe, and a slow one
//! is not mistaken for a dead one.

use std::time::Duration;

use client_core::proto::{
    self, ClientCtl, DaemonId, PairingSecret, PrincipalId, ResumeToken, Roles, ServerCtl,
    SessionEpoch, Ticket, UnixMillis, Welcome,
};
use client_core::{ClientEvent, PROBE_DEADLINE};
use iroh::endpoint::{RecvStream, presets};
use tokio::sync::oneshot;

/// A daemon stand-in on its own single-threaded runtime: it welcomes a client and answers its
/// pings after `pong_delay`. Sending on the returned channel freezes the whole runtime (its QUIC
/// stack included), as a stopped or hung host would be.
fn host(pong_delay: Duration) -> (Ticket, oneshot::Sender<()>) {
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (freeze_tx, freeze_rx) = oneshot::channel::<()>();
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async move {
            let endpoint = iroh::Endpoint::builder(presets::Minimal)
                .alpns(vec![proto::ALPN.to_vec()])
                .clear_ip_transports()
                .bind_addr("127.0.0.1:0".parse::<std::net::SocketAddr>().unwrap())
                .unwrap()
                .bind()
                .await
                .unwrap();
            let ticket = Ticket {
                v: Ticket::VERSION,
                daemon_id: DaemonId(*endpoint.id().as_bytes()),
                addrs: endpoint.bound_sockets(),
                relay_url: None,
                principal: PrincipalId([2; 16]),
                secret: PairingSecret([3; 16]),
                expires: UnixMillis(0),
            };
            let daemon_id = ticket.daemon_id;
            ready_tx.send(ticket).unwrap();
            tokio::spawn(async move {
                if freeze_rx.await.is_ok() {
                    // Blocks the only thread: nothing on this runtime runs, nothing is acked.
                    std::thread::sleep(Duration::from_secs(60));
                }
            });
            while let Some(incoming) = endpoint.accept().await {
                tokio::spawn(async move {
                    let Ok(connection) = incoming.await else {
                        return;
                    };
                    let Ok((mut tx, mut rx)) = connection.accept_bi().await else {
                        return;
                    };
                    read(&mut rx).await;
                    let welcome = ServerCtl::Welcome(Welcome {
                        daemon_id,
                        session_epoch: SessionEpoch(1),
                        roles: Roles::OWNER,
                        snapshot_format: u32::from(ghostty_vt::snapshot_format()),
                        panes: vec![],
                        resume_token: ResumeToken(vec![1]),
                    });
                    tx.write_all(&proto::frame::to_vec(&welcome).unwrap())
                        .await
                        .unwrap();
                    let _input = connection.accept_uni().await;
                    while let Some(ctl) = read(&mut rx).await {
                        if let ClientCtl::Ping { nonce } = ctl {
                            tokio::time::sleep(pong_delay).await;
                            let pong = proto::frame::to_vec(&ServerCtl::Pong { nonce }).unwrap();
                            if tx.write_all(&pong).await.is_err() {
                                return;
                            }
                        }
                    }
                });
            }
        });
    });
    (ready_rx.recv().unwrap(), freeze_tx)
}

async fn read(rx: &mut RecvStream) -> Option<ClientCtl> {
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    rx.read_exact(&mut prefix).await.ok()?;
    let len = proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).ok()?;
    let mut body = vec![0; len];
    rx.read_exact(&mut body).await.ok()?;
    proto::frame::decode_body(&body).ok()
}

/// Whether a `Disconnected` arrives within `within`.
async fn disconnects(
    events: &mut tokio::sync::mpsc::UnboundedReceiver<ClientEvent>,
    within: Duration,
) -> bool {
    tokio::time::timeout(within, async {
        while let Some(event) = events.recv().await {
            if matches!(event, ClientEvent::Disconnected { .. }) {
                return;
            }
        }
    })
    .await
    .is_ok()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_host_that_stops_answering_is_dropped_within_seconds_of_a_probe() {
    let (ticket, freeze) = host(Duration::ZERO);
    let (client, mut events) = super::connect(&ticket.to_string(), false);
    super::next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Connected { .. })
    })
    .await;
    // A healthy host answers: nothing happens.
    client.probe();
    assert!(!disconnects(&mut events, PROBE_DEADLINE + Duration::from_secs(1)).await);

    freeze.send(()).unwrap();
    let asked = tokio::time::Instant::now();
    client.probe();
    // Well before the QUIC idle timeout would have noticed.
    assert!(
        disconnects(&mut events, PROBE_DEADLINE + Duration::from_secs(2)).await,
        "the frozen host still counts as connected after {:?}",
        asked.elapsed()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_slow_host_is_not_mistaken_for_a_dead_one() {
    // Answers after the first deadline, while its QUIC stack keeps acknowledging.
    let (ticket, _freeze) = host(PROBE_DEADLINE + Duration::from_secs(2));
    let (client, mut events) = super::connect(&ticket.to_string(), false);
    super::next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Connected { .. })
    })
    .await;
    client.probe();
    assert!(!disconnects(&mut events, PROBE_DEADLINE + Duration::from_secs(4)).await);
}
