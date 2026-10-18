//! Port forwarding: a client's bidirectional stream spliced onto a TCP connection to the
//! daemon host's loopback interface (in-app browser, VS Code server).

use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};

use iroh::endpoint::{RecvStream, SendStream};
use proto::ForwardReply;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;

use crate::net;

/// Connects to `localhost:port` and copies bytes both ways until both directions finish.
pub(crate) async fn serve(port: u16, mut send: SendStream, mut recv: RecvStream) {
    let tcp = match connect(port).await {
        Ok(tcp) => tcp,
        Err(e) => {
            let reply = ForwardReply::Refused {
                reason: format!("connect to localhost:{port}: {e}"),
            };
            let _ = net::send(&mut send, &reply).await;
            let _ = send.finish();
            return;
        }
    };
    let _ = tcp.set_nodelay(true);
    if net::send(&mut send, &ForwardReply::Connected)
        .await
        .is_err()
    {
        return;
    }
    let (mut tcp_read, mut tcp_write) = tcp.into_split();
    let upstream = async {
        let copied = tokio::io::copy(&mut recv, &mut tcp_write).await;
        let _ = tcp_write.shutdown().await;
        copied
    };
    let downstream = async {
        let copied = tokio::io::copy(&mut tcp_read, &mut send).await;
        let _ = send.finish();
        copied
    };
    let (up, down) = tokio::join!(upstream, downstream);
    tracing::debug!(port, ?up, ?down, "port forward closed");
}

async fn connect(port: u16) -> std::io::Result<TcpStream> {
    match TcpStream::connect(SocketAddr::from((Ipv4Addr::LOCALHOST, port))).await {
        Ok(tcp) => Ok(tcp),
        Err(v4) => TcpStream::connect(SocketAddr::from((Ipv6Addr::LOCALHOST, port)))
            .await
            .map_err(|_| v4),
    }
}
