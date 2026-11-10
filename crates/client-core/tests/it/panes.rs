//! A followed pane whose stream stops, or whose first snapshot is unreadable, is followed
//! again: it never freezes until the next reconnect.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use client_core::ClientEvent;
use client_core::proto::{
    self, ClientCtl, DaemonId, PairingSecret, PaneId, PaneOutput, PrincipalId, ResumeToken, Roles,
    Seq, ServerCtl, SessionEpoch, SnapGen, StreamHeader, Ticket, UnixMillis, Welcome,
};
use iroh::endpoint::{RecvStream, presets};

use super::{connect, next_matching};

/// What the stand-in sends on each pane stream it opens.
#[derive(Clone, Copy)]
enum PaneStream {
    /// The header, then the end of the stream.
    EndsAtOnce,
    /// The header and a snapshot that does not decompress; the stream stays open.
    UnreadableSnapshot,
}

pub(super) async fn read_frame(stream: &mut RecvStream) -> Option<ClientCtl> {
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    stream.read_exact(&mut prefix).await.ok()?;
    let length = proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).ok()?;
    let mut body = vec![0; length];
    stream.read_exact(&mut body).await.ok()?;
    proto::frame::decode_body(&body).ok()
}

/// A daemon stand-in that welcomes a client and answers each `Subscribe` with a stream that
/// behaves as `pane_stream` says. Returns its ticket and the number of subscribes it got.
async fn pane_host(pane_stream: PaneStream) -> (iroh::Endpoint, Ticket, Arc<AtomicUsize>) {
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
    let subscribes = Arc::new(AtomicUsize::new(0));
    let server = endpoint.clone();
    let counted = Arc::clone(&subscribes);
    let daemon_id = ticket.daemon_id;
    tokio::spawn(async move {
        while let Some(incoming) = server.accept().await {
            let counted = Arc::clone(&counted);
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
                    snapshot_format: u32::from(ghostty_vt::snapshot_format()),
                    panes: vec![],
                    resume_token: ResumeToken(vec![1]),
                });
                let welcome = proto::frame::to_vec(&welcome).unwrap();
                if control_tx.write_all(&welcome).await.is_err() {
                    return;
                }
                while let Some(control) = read_frame(&mut control_rx).await {
                    let ClientCtl::Subscribe { pane_id, .. } = control else {
                        continue;
                    };
                    counted.fetch_add(1, Ordering::SeqCst);
                    let Ok(mut stream) = connection.open_uni().await else {
                        return;
                    };
                    let header = proto::frame::to_vec(&StreamHeader::Pane { pane_id }).unwrap();
                    let _ = stream.write_all(&header).await;
                    match pane_stream {
                        PaneStream::EndsAtOnce => {
                            let _ = stream.finish();
                        }
                        PaneStream::UnreadableSnapshot => {
                            let snapshot = PaneOutput::SnapshotZstd {
                                seq: Seq(0),
                                snap_gen: SnapGen(1),
                                raw_len: 1000,
                                data: vec![0xab; 64],
                            };
                            let snapshot = proto::frame::to_vec(&snapshot).unwrap();
                            let _ = stream.write_all(&snapshot).await;
                            tokio::spawn(async move {
                                tokio::time::sleep(Duration::from_secs(60)).await;
                                drop(stream);
                            });
                        }
                    }
                }
            });
        }
    });
    (endpoint, ticket, subscribes)
}

async fn followed_again_after(pane_stream: PaneStream) {
    let (endpoint, ticket, subscribes) = pane_host(pane_stream).await;
    let (client, mut events) = connect(&ticket.to_string(), true);
    next_matching(&mut events, |event| {
        matches!(event, ClientEvent::Connected { .. })
    })
    .await;
    client.subscribe(PaneId(1));
    let followed_again = tokio::time::timeout(Duration::from_secs(10), async {
        while subscribes.load(Ordering::SeqCst) < 3 {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await;
    assert!(
        followed_again.is_ok(),
        "the pane was followed {} times",
        subscribes.load(Ordering::SeqCst)
    );
    tokio::time::sleep(Duration::from_secs(2)).await;
    let followed = subscribes.load(Ordering::SeqCst);
    assert!(followed < 10, "followed {followed} times in a few seconds");
    drop(client);
    endpoint.close().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pane_stream_that_ends_is_followed_again() {
    followed_again_after(PaneStream::EndsAtOnce).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_unreadable_snapshot_is_asked_for_again() {
    followed_again_after(PaneStream::UnreadableSnapshot).await;
}
