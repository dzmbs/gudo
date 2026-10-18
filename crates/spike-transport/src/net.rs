//! iroh endpoints with every n0 service off (no relays, no address lookup, no portmapper),
//! plus framed reads and writes over iroh streams.

use std::net::SocketAddr;

use anyhow::{Context, Result};
use iroh::Endpoint;
use iroh::endpoint::{Builder, Connection, ReadExactError, RecvStream, SendStream, presets};
use serde::Serialize;
use serde::de::DeserializeOwned;

/// `presets::Minimal` only sets the ring crypto provider. The empty builder underneath already
/// means `RelayMode::Disabled` and no address lookup, so the endpoint never talks to n0
/// infrastructure. Clearing the IP transports drops the default `0.0.0.0` / `[::]` sockets so
/// only `addr` is bound.
fn builder(addr: SocketAddr) -> Result<Builder> {
    Ok(Endpoint::builder(presets::Minimal)
        .clear_ip_transports()
        .bind_addr(addr)?)
}

/// Binds a daemon endpoint on `addr` that accepts our ALPN.
pub async fn bind_server(addr: SocketAddr) -> Result<Endpoint> {
    builder(addr)?
        .alpns(vec![proto::ALPN.to_vec()])
        .bind()
        .await
        .context("binding server endpoint")
}

/// Binds a client endpoint on `addr` (dial only).
pub async fn bind_client(addr: SocketAddr) -> Result<Endpoint> {
    builder(addr)?
        .bind()
        .await
        .context("binding client endpoint")
}

/// Writes one framed message.
pub async fn send<T: Serialize>(stream: &mut SendStream, msg: &T) -> Result<()> {
    let buf = proto::frame::to_vec(msg)?;
    stream.write_all(&buf).await?;
    Ok(())
}

/// Reads one framed message; `None` at a clean end of stream.
pub async fn recv<T: DeserializeOwned>(stream: &mut RecvStream) -> Result<Option<T>> {
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    match stream.read_exact(&mut prefix).await {
        Ok(()) => {}
        Err(ReadExactError::FinishedEarly(0)) => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    let mut body = vec![0; proto::frame::body_len(prefix, proto::MAX_FRAME_LEN)?];
    stream.read_exact(&mut body).await?;
    Ok(Some(proto::frame::decode_body(&body)?))
}

/// One line describing the connection's selected path, with this side's send statistics.
pub fn describe_path(conn: &Connection) -> String {
    let paths = conn.paths();
    let selected: Vec<_> = paths
        .iter()
        .filter(|p| p.is_selected())
        .map(|p| {
            let kind = if p.is_ip() { "direct" } else { "relay" };
            let s = p.stats();
            format!(
                "{kind} {:?}, rtt {:.2} ms, cwnd {} KB, sent {} pkts, lost {} pkts, {} congestion events",
                p.remote_addr(),
                p.rtt().as_secs_f64() * 1000.0,
                s.cwnd / 1024,
                s.udp_tx.datagrams,
                s.lost_packets,
                s.congestion_events,
            )
        })
        .collect();
    format!("{} path(s), selected: {}", paths.len(), selected.join("; "))
}
