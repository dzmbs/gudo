//! Redialling: a daemon that admits a client and then drops it at once is backed off, not
//! hammered.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use client_core::proto::{
    self, ClientCtl, DaemonId, PairingSecret, PrincipalId, ResumeToken, Roles, ServerCtl,
    SessionEpoch, Ticket, UnixMillis, Welcome,
};
use iroh::endpoint::presets;

/// A daemon stand-in that welcomes every client, waits for its input stream (so the client
/// counts the connection as up) and closes the connection. Returns the endpoint, a ticket
/// for it and the number of connections admitted so far.
async fn flaky_daemon() -> (iroh::Endpoint, Ticket, Arc<AtomicUsize>) {
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
    let admitted = Arc::new(AtomicUsize::new(0));
    let server = endpoint.clone();
    let count = Arc::clone(&admitted);
    let daemon_id = ticket.daemon_id;
    tokio::spawn(async move {
        while let Some(incoming) = server.accept().await {
            let count = Arc::clone(&count);
            tokio::spawn(async move {
                let Ok(connection) = incoming.await else {
                    return;
                };
                let Ok((mut tx, mut rx)) = connection.accept_bi().await else {
                    return;
                };
                let mut prefix = [0; proto::frame::LEN_PREFIX];
                if rx.read_exact(&mut prefix).await.is_err() {
                    return;
                }
                let len = proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).unwrap();
                let mut body = vec![0; len];
                rx.read_exact(&mut body).await.unwrap();
                let _: ClientCtl = proto::frame::decode_body(&body).unwrap();
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
                if connection.accept_uni().await.is_ok() {
                    count.fetch_add(1, Ordering::SeqCst);
                }
                connection.close(0u32.into(), b"go away");
            });
        }
    });
    (endpoint, ticket, admitted)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_daemon_that_drops_every_connection_is_backed_off() {
    let (endpoint, ticket, admitted) = flaky_daemon().await;
    let (client, _events) = super::connect(&ticket.to_string(), false);
    tokio::time::sleep(Duration::from_secs(4)).await;
    let dials = admitted.load(Ordering::SeqCst);
    // 100 ms doubling up to 5 s is about six dials in four seconds; a tight loop makes hundreds.
    assert!((2..=10).contains(&dials), "{dials} connections in 4 s");
    drop(client);
    endpoint.close().await;
}
