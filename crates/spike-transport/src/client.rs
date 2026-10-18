//! Fake client: types into the focused pane, applies every pane's output, acks every 20 ms.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use iroh::endpoint::{Connection, RecvStream, SendStream};
use iroh::{Endpoint, EndpointAddr};
use proto::frame::FrameDecoder;
use proto::{
    Caps, ClientCtl, ClientInput, DeviceId, GrantId, Hello, Input, InputPayload, InputSeq,
    LinkClass, PaneId, PaneOutput, PrincipalId, Seq, ServerCtl, SignedGrant, StreamHeader,
};
use tokio::sync::{mpsc, watch};
use tokio::task::JoinSet;

use crate::server::{Priorities, priority};
use crate::{FLOOD_PANE, FOCUSED_PANE, net};

/// Fake client configuration.
#[derive(Debug, Clone, Copy)]
pub struct ClientConfig {
    /// Keystrokes to send.
    pub keys: usize,
    /// Gap between keystrokes.
    pub key_interval: Duration,
    /// Time to let the flood build up before typing.
    pub warmup: Duration,
    /// Stream priorities.
    pub priorities: Priorities,
}

/// What the client measured.
#[derive(Debug)]
pub struct ClientReport {
    /// Time from `connect` to an established connection.
    pub connect: Duration,
    /// Keystroke → `InputAck` latency for each acknowledged keystroke.
    pub latencies: Vec<Duration>,
    /// Keystrokes never acknowledged.
    pub lost: usize,
    /// Flood-pane PTY bytes the client applied while typing (snapshots count as the range they
    /// skipped).
    pub flood_applied: u64,
    /// Flood-pane wire bytes received while typing.
    pub flood_wire: u64,
    /// Snapshots received while typing.
    pub snapshots: u64,
    /// Length of the typing window.
    pub window: Duration,
    /// The selected network path when typing ended.
    pub path: String,
}

/// Per-pane progress, published by the pane readers.
#[derive(Debug, Default, Clone, Copy)]
struct PaneProgress {
    applied: Seq,
    wire: u64,
    snapshots: u64,
}

/// Dials `server`, runs the typing test and closes the connection.
pub async fn run(
    endpoint: &Endpoint,
    server: EndpointAddr,
    cfg: ClientConfig,
) -> Result<ClientReport> {
    let start = Instant::now();
    let conn = endpoint
        .connect(server, proto::ALPN)
        .await
        .context("connect")?;
    let connect = start.elapsed();

    let (mut ctl_tx, mut ctl_rx) = conn.open_bi().await?;
    ctl_tx.set_priority(cfg.priorities.pick(priority::CTL))?;
    let principal = PrincipalId([1; 16]);
    let hello = Hello {
        device_id: DeviceId(*endpoint.id().as_bytes()),
        principal_id: principal,
        grant: SignedGrant {
            v: 0,
            grant_id: GrantId([0; 16]),
            token: vec![],
        },
        snapshot_format: 1,
        resume: vec![],
        caps: Caps::EMPTY,
        link: LinkClass::Normal,
        resume_token: None,
    };
    net::send(&mut ctl_tx, &ClientCtl::Hello(hello)).await?;
    let Some(ServerCtl::Welcome(_)) = net::recv(&mut ctl_rx).await? else {
        bail!("expected Welcome");
    };

    let mut input = conn.open_uni().await?;
    input.set_priority(cfg.priorities.pick(priority::INPUT))?;
    net::send(&mut input, &StreamHeader::Input).await?;

    let (ack_tx, mut ack_rx) = mpsc::unbounded_channel();
    let mut progress = HashMap::new();
    let mut readers = HashMap::new();
    for pane in [FOCUSED_PANE, FLOOD_PANE] {
        let (tx, rx) = watch::channel(PaneProgress::default());
        progress.insert(pane, tx);
        readers.insert(pane, rx);
    }

    let mut tasks = JoinSet::new();
    tasks.spawn(accept_panes(conn.clone(), progress, ack_tx));
    tasks.spawn(ack_loop(ctl_tx, readers.clone()));

    tokio::time::sleep(cfg.warmup).await;
    let flood = &readers[&FLOOD_PANE];
    let before = *flood.borrow();
    let window_start = Instant::now();

    let mut sent_at = Vec::with_capacity(cfg.keys);
    let mut latencies = Vec::with_capacity(cfg.keys);
    let mut tick = tokio::time::interval(cfg.key_interval);
    for i in 0..cfg.keys {
        tick.tick().await;
        sent_at.push(Instant::now());
        let key = ClientInput::Input(Input {
            pane_id: FOCUSED_PANE,
            input_seq: InputSeq(i as u64),
            principal,
            payload: InputPayload::Bytes(vec![b'a' + (i % 26) as u8]),
        });
        // No Nagle in QUIC: the frame leaves as soon as noq's connection task runs.
        net::send(&mut input, &key).await?;
        while let Ok((seq, at)) = ack_rx.try_recv() {
            latencies.push(at - sent_at[seq.0 as usize]);
        }
    }
    let deadline = tokio::time::sleep(Duration::from_secs(5));
    tokio::pin!(deadline);
    while latencies.len() < cfg.keys {
        tokio::select! {
            Some((seq, at)) = ack_rx.recv() => latencies.push(at - sent_at[seq.0 as usize]),
            _ = &mut deadline => break,
        }
    }
    let window = window_start.elapsed();
    let after = *flood.borrow();

    let path = net::describe_path(&conn);
    conn.close(0u32.into(), b"done");
    tasks.abort_all();

    Ok(ClientReport {
        connect,
        lost: cfg.keys - latencies.len(),
        latencies,
        flood_applied: after.applied.0 - before.applied.0,
        flood_wire: after.wire - before.wire,
        snapshots: after.snapshots - before.snapshots,
        window,
        path,
    })
}

async fn accept_panes(
    conn: Connection,
    progress: HashMap<PaneId, watch::Sender<PaneProgress>>,
    acks: mpsc::UnboundedSender<(InputSeq, Instant)>,
) -> Result<()> {
    let mut readers = JoinSet::new();
    loop {
        let mut stream = conn.accept_uni().await?;
        let Some(StreamHeader::Pane { pane_id }) = net::recv(&mut stream).await? else {
            bail!("expected pane stream header");
        };
        let tx = progress.get(&pane_id).context("unknown pane")?.clone();
        readers.spawn(read_pane(stream, tx, acks.clone()));
    }
}

/// Applies a pane's output. A real client would feed `Bytes` into libghostty-vt here.
async fn read_pane(
    mut stream: RecvStream,
    progress: watch::Sender<PaneProgress>,
    acks: mpsc::UnboundedSender<(InputSeq, Instant)>,
) -> Result<()> {
    let mut decoder = FrameDecoder::new(proto::MAX_FRAME_LEN);
    let mut state = PaneProgress::default();
    while let Some(chunk) = stream.read_chunk(64 * 1024).await? {
        state.wire += chunk.len() as u64;
        decoder.extend(&chunk);
        while let Some(msg) = decoder.decode::<PaneOutput>()? {
            match msg {
                PaneOutput::Bytes { seq, data } => state.applied = Seq(seq.0 + data.len() as u64),
                PaneOutput::Snapshot { seq, .. } | PaneOutput::SnapshotZstd { seq, .. } => {
                    state.applied = seq;
                    state.snapshots += 1;
                }
                PaneOutput::InputAck { input_seq, .. } => {
                    let _ = acks.send((input_seq, Instant::now()));
                }
                PaneOutput::Resized { .. } => {}
            }
        }
        progress.send_replace(state);
    }
    Ok(())
}

async fn ack_loop(
    mut ctl: SendStream,
    mut panes: HashMap<PaneId, watch::Receiver<PaneProgress>>,
) -> Result<()> {
    let mut tick = tokio::time::interval(Duration::from_millis(20));
    let mut last: HashMap<PaneId, Seq> = HashMap::new();
    loop {
        tick.tick().await;
        for (&pane_id, rx) in &mut panes {
            let seq = rx.borrow_and_update().applied;
            if last.get(&pane_id) != Some(&seq) {
                last.insert(pane_id, seq);
                net::send(&mut ctl, &ClientCtl::Ack { pane_id, seq }).await?;
            }
        }
    }
}
