//! Port forwarding: a client's bidirectional stream spliced onto a TCP connection to the
//! daemon host's loopback interface, or onto a Unix socket (in-app browser, editor server,
//! a Docker socket).
//!
//! Each direction is copied with a 64 KiB buffer and only reads more once the previous chunk
//! was written, so a slow reader on either side stops the other through QUIC flow control or
//! the TCP window: nothing buffers without bound. When one side finishes its half (QUIC FIN or
//! TCP EOF), the other side's write half is shut down and the opposite direction keeps
//! running (half-close). When either side fails midway (the link died, a reset), both are
//! reset at once: a local TCP peer sees a reset, not a clean end.

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
    let moved = match conn {
        Conn::Tcp(tcp) => {
            let _ = tcp.set_nodelay(true);
            let (mut r, mut w) = tcp.into_split();
            let moved = splice(recv, &mut w, &mut r, send).await;
            if moved.broken {
                // A reset, not an orderly close: the server must not take it for the client's
                // goodbye.
                if let Ok(tcp) = r.reunite(w) {
                    let _ = tcp.set_zero_linger();
                }
            }
            moved
        }
        Conn::Unix(unix) => {
            let (r, w) = unix.into_split();
            splice(recv, w, r, send).await
        }
    };
    tracing::debug!(moved.up, moved.down, moved.broken, "forward closed");
}

/// What a splice moved, and how it ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Moved {
    /// Bytes from the peer to the local side.
    pub up: u64,
    /// Bytes from the local side to the peer.
    pub down: u64,
    /// The link or a side failed midway (the other side was reset, not finished).
    pub broken: bool,
}

/// One direction's end: bytes moved, and whether it finished cleanly.
type Half = (u64, bool);

/// Copies `quic_rx → local_w` and `local_r → quic_tx` concurrently with half-close. A failure
/// either way ends both at once and resets the stream.
pub(crate) async fn splice<LR, LW>(
    mut quic_rx: RecvStream,
    mut local_w: LW,
    mut local_r: LR,
    mut quic_tx: SendStream,
) -> Moved
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
                        return (total, false);
                    }
                    total += n as u64;
                }
                Ok(None) => {
                    let _ = local_w.shutdown().await;
                    return (total, true);
                }
                Err(_) => return (total, false),
            }
        }
    };
    let down = async {
        let mut buf = vec![0; BUF];
        let mut total = 0u64;
        loop {
            match local_r.read(&mut buf).await {
                Ok(0) => {
                    let _ = quic_tx.finish();
                    return (total, true);
                }
                Ok(n) => {
                    if quic_tx.write_all(&buf[..n]).await.is_err() {
                        return (total, false);
                    }
                    total += n as u64;
                }
                Err(_) => return (total, false),
            }
        }
    };
    let moved = both_or_first_failure(up, down).await;
    if moved.broken {
        let _ = quic_tx.reset(1u32.into());
        let _ = quic_rx.stop(0u32.into());
    }
    moved
}

/// Both halves when they finish cleanly; as soon as one fails, what was moved so far.
async fn both_or_first_failure(
    up: impl Future<Output = Half>,
    down: impl Future<Output = Half>,
) -> Moved {
    tokio::pin!(up, down);
    let (mut up_end, mut down_end): (Option<u64>, Option<u64>) = (None, None);
    loop {
        tokio::select! {
            (n, clean) = &mut up, if up_end.is_none() => {
                if !clean {
                    return Moved { up: n, down: down_end.unwrap_or(0), broken: true };
                }
                up_end = Some(n);
            }
            (n, clean) = &mut down, if down_end.is_none() => {
                if !clean {
                    return Moved { up: up_end.unwrap_or(0), down: n, broken: true };
                }
                down_end = Some(n);
            }
        }
        if let (Some(up), Some(down)) = (up_end, down_end) {
            return Moved {
                up,
                down,
                broken: false,
            };
        }
    }
}

async fn connect(port: u16) -> std::io::Result<TcpStream> {
    match TcpStream::connect(SocketAddr::from((Ipv4Addr::LOCALHOST, port))).await {
        Ok(tcp) => Ok(tcp),
        Err(v4) => TcpStream::connect(SocketAddr::from((Ipv6Addr::LOCALHOST, port)))
            .await
            .map_err(|_| v4),
    }
}
