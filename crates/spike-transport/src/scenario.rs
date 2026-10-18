//! One measurement: daemon, optional shaped hop and client, each on its own runtime.

use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use anyhow::{Context, Result};
use iroh::EndpointAddr;
use tokio::runtime::Runtime;

use crate::client::{self, ClientConfig, ClientReport};
use crate::link::{LinkShape, ShapedLink};
use crate::net;
use crate::server::{self, FloodMode, Priorities, ServerConfig, ServerStats};
use crate::stats::Summary;

/// The network between client and daemon.
#[derive(Debug, Clone, Copy)]
pub enum Link {
    /// Straight over loopback.
    Loopback,
    /// Through a [`ShapedLink`].
    Shaped(LinkShape),
}

/// A scenario to measure.
#[derive(Debug, Clone, Copy)]
pub struct Scenario {
    /// Network.
    pub link: Link,
    /// Daemon behaviour.
    pub server: ServerConfig,
    /// Client behaviour.
    pub client: ClientConfig,
}

/// Results of one scenario.
#[derive(Debug)]
pub struct Outcome {
    /// Keystroke → echo latency.
    pub latency: Option<Summary>,
    /// Everything the client measured.
    pub client: ClientReport,
    /// Flood PTY bytes produced by the fake `cat` over the whole run.
    pub produced: u64,
    /// Flood PTY bytes forwarded as `Bytes` over the whole run.
    pub forwarded: u64,
    /// The daemon's view of the selected path (it is the side sending the flood).
    pub server_path: String,
}

fn runtime(workers: usize) -> Result<Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(workers)
        .enable_all()
        .build()
        .context("building runtime")
}

/// Runs one scenario to completion.
///
/// The daemon, the shaped hop and the client get separate runtimes so that a busy flood task
/// cannot delay the client's timers through a shared scheduler (they still share CPU cores).
pub fn run(s: &Scenario) -> Result<Outcome> {
    let server_rt = runtime(2)?;
    let client_rt = runtime(2)?;
    let link_rt = runtime(1)?;

    let loopback4: SocketAddr = (Ipv4Addr::LOCALHOST, 0).into();
    let loopback6: SocketAddr = (Ipv6Addr::LOCALHOST, 0).into();

    let server_ep = server_rt.block_on(net::bind_server(loopback4))?;
    let server_addr = *server_ep
        .bound_sockets()
        .first()
        .context("server bound no socket")?;
    let server_id = server_ep.id();
    let stats = Arc::new(ServerStats::default());
    let serving = server_rt.spawn(server::serve(
        server_ep.clone(),
        s.server,
        Arc::clone(&stats),
    ));

    // Over the shaped hop the client lives on IPv6 and the daemon on IPv4, so the only way
    // between them is the hop: iroh's in-band hole punching learns the daemon's real address
    // but the client has no IPv4 socket to reach it with.
    let (client_bind, dial, link) = match s.link {
        Link::Loopback => (loopback4, server_addr, None),
        Link::Shaped(shape) => {
            let link = link_rt.block_on(ShapedLink::start(loopback6, server_addr, shape))?;
            (loopback6, link.addr, Some(link))
        }
    };

    let report = client_rt.block_on(async {
        let ep = net::bind_client(client_bind).await?;
        let report = client::run(
            &ep,
            EndpointAddr::new(server_id).with_ip_addr(dial),
            s.client,
        )
        .await;
        ep.close().await;
        report
    })?;

    let _ =
        server_rt.block_on(async { tokio::time::timeout(Duration::from_secs(5), serving).await });
    server_rt.block_on(server_ep.close());
    if let Some(link) = link {
        link_rt.block_on(async { link.stop() });
    }
    for rt in [server_rt, client_rt, link_rt] {
        rt.shutdown_timeout(Duration::from_secs(1));
    }

    Ok(Outcome {
        latency: Summary::new(report.latencies.clone()),
        produced: stats.produced.load(Ordering::Relaxed),
        forwarded: stats.forwarded.load(Ordering::Relaxed),
        server_path: stats.path.lock().unwrap().clone(),
        client: report,
    })
}

/// Default daemon configuration: a 100 MB/s `cat`, 32 KB visible budget, 48 KB snapshot.
pub fn server_config(flood: FloodMode, priorities: Priorities) -> ServerConfig {
    ServerConfig {
        flood,
        priorities,
        pty_rate: 100_000_000,
        visible_budget: 32 * 1024,
        snapshot_len: 48 * 1024,
    }
}
