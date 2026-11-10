//! A connection a daemon admitted only for its upgrade stays up through foreground probes,
//! though that daemon never answers a ping.

use std::time::Duration;

use client_core::ClientEvent;
use client_core::proto::{
    self, DaemonId, PairingSecret, PrincipalId, ResumeToken, Roles, ServerCtl, SessionEpoch,
    Ticket, UnixMillis, Welcome,
};
use iroh::endpoint::presets;

use super::panes::read_frame;
use super::{connect, next_matching};

/// A daemon stand-in with another snapshot format: it welcomes the client for an upgrade
/// and reads, but never answers, whatever it sends.
async fn incompatible_host() -> (iroh::Endpoint, Ticket) {
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
    let server = endpoint.clone();
    let daemon_id = ticket.daemon_id;
    tokio::spawn(async move {
        while let Some(incoming) = server.accept().await {
            tokio::spawn(async move {
                let Ok(connection) = incoming.await else {
                    return;
                };
                let Ok((mut control_tx, mut control_rx)) = connection.accept_bi().await else {
                    return;
                };
                read_frame(&mut control_rx).await;
                let welcome = ServerCtl::Welcome(Welcome {
                    daemon_id,
                    session_epoch: SessionEpoch(1),
                    roles: Roles::OWNER,
                    snapshot_format: u32::from(ghostty_vt::snapshot_format()) + 1,
                    panes: vec![],
                    resume_token: ResumeToken(vec![1]),
                });
                let welcome = proto::frame::to_vec(&welcome).unwrap();
                if control_tx.write_all(&welcome).await.is_err() {
                    return;
                }
                while read_frame(&mut control_rx).await.is_some() {}
                connection.closed().await;
            });
        }
    });
    (endpoint, ticket)
}

#[tokio::test(flavor = "multi_thread")]
async fn probing_an_upgrade_only_connection_keeps_it() {
    let (endpoint, ticket) = incompatible_host().await;
    let (client, mut events) = connect(&ticket.to_string(), false);
    next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Incompatible { .. })
    })
    .await;
    for _ in 0..3 {
        client.resume_now();
        client.probe();
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    tokio::time::sleep(Duration::from_secs(10)).await;
    while let Ok(event) = events.try_recv() {
        assert!(
            !matches!(event, ClientEvent::Disconnected { .. }),
            "a probe dropped the connection: {event:?}"
        );
    }
    drop(client);
    endpoint.close().await;
}
