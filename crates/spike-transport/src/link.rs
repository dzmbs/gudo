//! A shaped UDP hop: a poor man's `netem` so loopback has a bottleneck.
//!
//! Each direction serialises packets at `rate`, then delays them by `one_way_delay`. Packets
//! arriving while more than `queue_limit` bytes wait for serialisation are dropped (drop-tail),
//! which is how a cellular uplink or home router buffer behaves. Delivery times come from
//! tokio's timer, so expect about 1 ms of jitter.

use std::io;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio::task::JoinSet;
use tokio::time::Instant;

/// Bottleneck parameters, applied independently to each direction.
#[derive(Debug, Clone, Copy)]
pub struct LinkShape {
    /// Serialisation rate in bytes per second.
    pub rate: u64,
    /// Propagation delay added after serialisation.
    pub one_way_delay: Duration,
    /// Bytes allowed to wait for serialisation before packets are dropped.
    pub queue_limit: usize,
}

/// Serialisation schedule for one direction.
struct Shaper {
    shape: LinkShape,
    /// When the bottleneck finishes sending everything accepted so far.
    busy_until: Instant,
    dropped: u64,
}

impl Shaper {
    fn new(shape: LinkShape) -> Self {
        Self {
            shape,
            busy_until: Instant::now(),
            dropped: 0,
        }
    }

    /// Returns when a packet of `len` bytes arriving now is delivered, or `None` to drop it.
    fn admit(&mut self, len: usize) -> Option<Instant> {
        let now = Instant::now();
        let start = self.busy_until.max(now);
        let backlog = (start - now).as_secs_f64() * self.shape.rate as f64;
        if backlog as usize + len > self.shape.queue_limit {
            self.dropped += 1;
            return None;
        }
        self.busy_until = start + Duration::from_secs_f64(len as f64 / self.shape.rate as f64);
        Some(self.busy_until + self.shape.one_way_delay)
    }
}

/// A running shaped hop. Dropping it stops forwarding.
pub struct ShapedLink {
    /// Address clients dial instead of the upstream.
    pub addr: SocketAddr,
    tasks: JoinSet<()>,
}

impl ShapedLink {
    /// Starts forwarding between a single client (whoever sends to `listen` first) and
    /// `upstream`.
    ///
    /// stop iroh's in-band hole punching from finding a path around the hop.
    ///
    /// # Errors
    ///
    /// Returns an error if a socket cannot be bound.
    pub async fn start(
        listen: SocketAddr,
        upstream: SocketAddr,
        shape: LinkShape,
    ) -> io::Result<Self> {
        let front = Arc::new(UdpSocket::bind(listen).await?);
        let unspecified: SocketAddr = if upstream.is_ipv4() {
            ([127, 0, 0, 1], 0).into()
        } else {
            (std::net::Ipv6Addr::LOCALHOST, 0).into()
        };
        let back = Arc::new(UdpSocket::bind(unspecified).await?);
        let addr = front.local_addr()?;
        let client: Arc<Mutex<Option<SocketAddr>>> = Arc::default();

        let mut tasks = JoinSet::new();
        // client -> upstream
        let (up_tx, up_rx) = mpsc::unbounded_channel();
        tasks.spawn(receive(
            Arc::clone(&front),
            Shaper::new(shape),
            up_tx,
            Some(Arc::clone(&client)),
        ));
        tasks.spawn(deliver(Arc::clone(&back), up_rx, Target::Fixed(upstream)));
        // upstream -> client
        let (down_tx, down_rx) = mpsc::unbounded_channel();
        tasks.spawn(receive(back, Shaper::new(shape), down_tx, None));
        tasks.spawn(deliver(front, down_rx, Target::Learned(client)));
        Ok(Self { addr, tasks })
    }

    /// Stops forwarding.
    pub fn stop(mut self) {
        self.tasks.abort_all();
    }
}

enum Target {
    Fixed(SocketAddr),
    Learned(Arc<Mutex<Option<SocketAddr>>>),
}

async fn receive(
    socket: Arc<UdpSocket>,
    mut shaper: Shaper,
    tx: mpsc::UnboundedSender<(Instant, Vec<u8>)>,
    learn_peer: Option<Arc<Mutex<Option<SocketAddr>>>>,
) {
    let mut buf = vec![0; 65_536];
    loop {
        let Ok((len, from)) = socket.recv_from(&mut buf).await else {
            continue;
        };
        if let Some(peer) = &learn_peer {
            peer.lock().unwrap().get_or_insert(from);
        }
        if let Some(at) = shaper.admit(len)
            && tx.send((at, buf[..len].to_vec())).is_err()
        {
            return;
        }
    }
}

async fn deliver(
    socket: Arc<UdpSocket>,
    mut rx: mpsc::UnboundedReceiver<(Instant, Vec<u8>)>,
    target: Target,
) {
    // Delivery times are monotonic per direction (FIFO bottleneck, constant delay).
    while let Some((at, packet)) = rx.recv().await {
        tokio::time::sleep_until(at).await;
        let to = match &target {
            Target::Fixed(addr) => Some(*addr),
            Target::Learned(peer) => *peer.lock().unwrap(),
        };
        if let Some(to) = to {
            // Loss is fine here: QUIC recovers, and the shaper already models drops.
            let _ = socket.send_to(&packet, to).await;
        }
    }
}
