//! Port forwarding: a client's bidirectional stream spliced onto a TCP connection to the
//! daemon host's loopback interface, or onto a Unix socket (in-app browser, editor server,
//! a Docker socket).
//!
//! Each direction is copied with a 64 KiB buffer and only reads more once the previous chunk
//! was written, so a slow reader on either side stops the other through QUIC flow control or
//! the TCP window: nothing buffers without bound. When one side finishes its half (QUIC FIN or
//! TCP EOF), the other side's write half is shut down and the opposite direction keeps
//! running (half-close).

use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};

use iroh::endpoint::{RecvStream, SendStream};
use proto::{ForwardReply, ForwardTarget};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpStream, UnixStream};

use crate::net;
use crate::ws::Policy;

const BUF: usize = 64 << 10;

/// Connects to `localhost:port` and copies bytes both ways until both directions finish.
pub(crate) async fn serve(port: u16, send: SendStream, recv: RecvStream) {
    let tcp = connect(port)
        .await
        .map_err(|e| format!("connect to localhost:{port}: {e}"));
    splice_reply(tcp.map(Conn::Tcp), send, recv).await;
}

/// Serves a [`proto::StreamHeader::Forward`] stream.
pub(crate) async fn serve_target(
    target: ForwardTarget,
    policy: Policy,
    send: SendStream,
    recv: RecvStream,
) {
    let conn = match &target {
        ForwardTarget::Tcp { port } => connect(*port)
            .await
            .map(Conn::Tcp)
            .map_err(|e| format!("connect to localhost:{port}: {e}")),
        ForwardTarget::Unix { path } => match policy.resolve_followed(path) {
            Ok(path) => UnixStream::connect(&path)
                .await
                .map(Conn::Unix)
                .map_err(|e| format!("connect to {}: {e}", path.display())),
            Err(e) => Err(e.to_string()),
        },
    };
    splice_reply(conn, send, recv).await;
}

enum Conn {
    Tcp(TcpStream),
    Unix(UnixStream),
}

async fn splice_reply(conn: Result<Conn, String>, mut send: SendStream, recv: RecvStream) {
    let conn = match conn {
        Ok(c) => c,
        Err(reason) => {
            let _ = net::send(&mut send, &ForwardReply::Refused { reason }).await;
            let _ = send.finish();
            return;
        }
    };
    if net::send(&mut send, &ForwardReply::Connected)
        .await
        .is_err()
    {
        return;
    }
    let (up, down) = match conn {
        Conn::Tcp(tcp) => {
            let _ = tcp.set_nodelay(true);
            let (r, w) = tcp.into_split();
            splice(recv, w, r, send).await
        }
        Conn::Unix(unix) => {
            let (r, w) = unix.into_split();
            splice(recv, w, r, send).await
        }
    };
    tracing::debug!(up, down, "forward closed");
}

/// Copies `quic_rx → local_w` and `local_r → quic_tx` concurrently with half-close. Returns
/// the bytes moved each way.
pub(crate) async fn splice<LR, LW>(
    mut quic_rx: RecvStream,
    mut local_w: LW,
    mut local_r: LR,
    mut quic_tx: SendStream,
) -> (u64, u64)
where
    LR: AsyncRead + Unpin,
    LW: AsyncWrite + Unpin,
{
    let up = async {
        let mut buf = vec![0; BUF];
        let mut total = 0u64;
        loop {
            match quic_rx.read(&mut buf).await {
                Ok(Some(n)) => {
                    if local_w.write_all(&buf[..n]).await.is_err() {
                        // The local side is gone: tell the peer to stop sending.
                        let _ = quic_rx.stop(0u32.into());
                        break;
                    }
                    total += n as u64;
                }
                Ok(None) => break,
                Err(_) => break,
            }
        }
        let _ = local_w.shutdown().await;
        total
    };
    let down = async {
        let mut buf = vec![0; BUF];
        let mut total = 0u64;
        loop {
            match local_r.read(&mut buf).await {
                Ok(0) => {
                    let _ = quic_tx.finish();
                    break;
                }
                Ok(n) => {
                    if quic_tx.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                    total += n as u64;
                }
                Err(_) => {
                    // A reset local connection: reset the stream so the peer sees an error,
                    // not a clean end.
                    let _ = quic_tx.reset(1u32.into());
                    break;
                }
            }
        }
        total
    };
    tokio::join!(up, down)
}

async fn connect(port: u16) -> std::io::Result<TcpStream> {
    match TcpStream::connect(SocketAddr::from((Ipv4Addr::LOCALHOST, port))).await {
        Ok(tcp) => Ok(tcp),
        Err(v4) => TcpStream::connect(SocketAddr::from((Ipv6Addr::LOCALHOST, port)))
            .await
            .map_err(|_| v4),
    }
}
