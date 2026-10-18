//! Fake daemon: echoes keystrokes on the focused pane and floods a second pane.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use iroh::Endpoint;
use iroh::endpoint::{RecvStream, SendStream};
use proto::{
    ClientCtl, ClientInput, DaemonId, Input, InputPayload, PaneId, PaneOutput, ResumeToken, Roles,
    Seq, ServerCtl, SessionEpoch, SnapGen, StreamHeader, Welcome,
};
use tokio::sync::watch;
use tokio::task::JoinSet;
use tokio::time::MissedTickBehavior;

use crate::budget::InFlight;
use crate::{FLOOD_PANE, FOCUSED_PANE, net};

pub mod priority {
    /// `ctl`, both directions.
    pub const CTL: i32 = 100;
    /// `input`, client → daemon.
    pub const INPUT: i32 = 90;
    /// `pane/<id>` of the focused pane.
    pub const FOCUSED: i32 = 80;
    /// `pane/<id>` of a visible, unfocused pane.
    pub const VISIBLE: i32 = 50;
}

/// What the flooding pane does when the client falls behind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FloodMode {
    /// No flood.
    Off,
    /// Forward every PTY byte; the PTY stalls when the stream is blocked (ssh / ET behaviour).
    Naive,
    /// Per-pane unacked budget; over budget, drop bytes and send a snapshot once caught up.
    Budgeted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Priorities {
    Spec,
    /// Everything at priority 0.
    Flat,
}

impl Priorities {
    /// The priority to use for a stream whose spec priority is `spec`.
    pub fn pick(self, spec: i32) -> i32 {
        match self {
            Self::Spec => spec,
            Self::Flat => 0,
        }
    }
}

/// Fake daemon configuration.
#[derive(Debug, Clone, Copy)]
pub struct ServerConfig {
    /// Flood behaviour of [`FLOOD_PANE`].
    pub flood: FloodMode,
    /// Stream priorities.
    pub priorities: Priorities,
    /// Rate at which the flooding `cat` produces PTY output, bytes per second.
    pub pty_rate: u64,
    pub visible_budget: usize,
    /// Size of the placeholder snapshot blob (S5 targets a READY section under 50 KB).
    pub snapshot_len: usize,
}

/// Counters the flood task updates, read after the run.
#[derive(Debug, Default)]
pub struct ServerStats {
    /// PTY bytes the fake `cat` produced.
    pub produced: AtomicU64,
    /// PTY bytes forwarded as `Bytes`.
    pub forwarded: AtomicU64,
    /// Snapshots sent.
    pub snapshots: AtomicU64,
    /// The daemon's view of the selected path, sampled every 50 ms.
    pub path: Mutex<String>,
}

/// PTY read size; a typical `read(2)` on a busy PTY master.
const CHUNK: usize = 16 * 1024;

/// Accepts one connection and serves it until the client closes it.
pub async fn serve(endpoint: Endpoint, cfg: ServerConfig, stats: Arc<ServerStats>) -> Result<()> {
    let incoming = endpoint.accept().await.context("endpoint closed")?;
    let conn = incoming.accept()?.await?;

    let (mut ctl_tx, mut ctl_rx) = conn.accept_bi().await?;
    ctl_tx.set_priority(cfg.priorities.pick(priority::CTL))?;
    let Some(ClientCtl::Hello(hello)) = net::recv(&mut ctl_rx).await? else {
        bail!("expected Hello");
    };
    if hello.device_id.0 != *conn.remote_id().as_bytes() {
        net::send(
            &mut ctl_tx,
            &ServerCtl::Refused {
                reason: proto::RefuseReason::DeviceMismatch,
            },
        )
        .await?;
        bail!("Hello.device_id does not match the handshake key");
    }
    let welcome = Welcome {
        daemon_id: DaemonId(*endpoint.id().as_bytes()),
        session_epoch: SessionEpoch(1),
        roles: Roles::OWNER,
        snapshot_format: 1,
        panes: vec![],
        resume_token: ResumeToken(vec![0; 16]),
    };
    net::send(&mut ctl_tx, &ServerCtl::Welcome(welcome)).await?;

    let mut input = conn.accept_uni().await?;
    let Some(StreamHeader::Input) = net::recv(&mut input).await? else {
        bail!("expected input stream header");
    };

    let focused = open_pane(&conn, FOCUSED_PANE, cfg.priorities.pick(priority::FOCUSED)).await?;
    let (flood_ack_tx, flood_ack_rx) = watch::channel(Seq(0));

    let mut tasks = JoinSet::new();
    tasks.spawn(ctl_loop(ctl_rx, flood_ack_tx));
    tasks.spawn(echo_loop(input, focused));
    if cfg.flood != FloodMode::Off {
        let flood = open_pane(&conn, FLOOD_PANE, cfg.priorities.pick(priority::VISIBLE)).await?;
        tasks.spawn(flood_loop(flood, flood_ack_rx, cfg, Arc::clone(&stats)));
    }
    // Path statistics vanish with the connection, so sample them while it is up.
    let mut sample = tokio::time::interval(Duration::from_millis(50));
    loop {
        tokio::select! {
            _ = conn.closed() => break,
            _ = sample.tick() => *stats.path.lock().unwrap() = net::describe_path(&conn),
        }
    }
    tasks.abort_all();
    Ok(())
}

async fn open_pane(
    conn: &iroh::endpoint::Connection,
    pane_id: PaneId,
    prio: i32,
) -> Result<SendStream> {
    let mut stream = conn.open_uni().await?;
    stream.set_priority(prio)?;
    net::send(&mut stream, &StreamHeader::Pane { pane_id }).await?;
    Ok(stream)
}

/// Routes the client's acks to the flood pane.
async fn ctl_loop(mut ctl_rx: RecvStream, flood_ack: watch::Sender<Seq>) -> Result<()> {
    while let Some(msg) = net::recv::<ClientCtl>(&mut ctl_rx).await? {
        if let ClientCtl::Ack {
            pane_id: FLOOD_PANE,
            seq,
        } = msg
        {
            flood_ack.send_replace(seq);
        }
    }
    Ok(())
}

/// The focused pane's "PTY" echoes each keystroke immediately, followed by `InputAck`.
///
/// No budget here: an echo-only pane never gets near the 256 KB focused budget.
async fn echo_loop(mut input: RecvStream, mut pane: SendStream) -> Result<()> {
    let mut seq = Seq(0);
    let mut buf = Vec::new();
    while let Some(ClientInput::Input(Input {
        input_seq, payload, ..
    })) = net::recv(&mut input).await?
    {
        let InputPayload::Bytes(data) = payload else {
            continue;
        };
        let at_seq = Seq(seq.0 + data.len() as u64);
        buf.clear();
        proto::frame::encode(&PaneOutput::Bytes { seq, data }, &mut buf)?;
        proto::frame::encode(&PaneOutput::InputAck { input_seq, at_seq }, &mut buf)?;
        pane.write_all(&buf).await?;
        seq = at_seq;
    }
    Ok(())
}

/// A `cat` producing `pty_rate` bytes per second into the flood pane.
async fn flood_loop(
    mut pane: SendStream,
    mut acks: watch::Receiver<Seq>,
    cfg: ServerConfig,
    stats: Arc<ServerStats>,
) -> Result<()> {
    let chunk: Vec<u8> = (0..CHUNK).map(|i| b'a' + (i % 26) as u8).collect();
    let mut tick = tokio::time::interval(Duration::from_millis(1));
    tick.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let per_tick = cfg.pty_rate as f64 / 1000.0;
    let mut credit = 0.0;

    let mut produced = Seq(0);
    let mut in_flight = InFlight::default();
    let mut dirty = false;
    let mut buf = Vec::with_capacity(CHUNK + 32);

    loop {
        tokio::select! {
            biased;
            changed = acks.changed() => {
                if changed.is_err() {
                    return Ok(());
                }
                in_flight.ack(*acks.borrow_and_update());
            }
            _ = tick.tick() => {
                credit += per_tick;
                while credit >= CHUNK as f64 {
                    credit -= CHUNK as f64;
                    let seq = produced;
                    produced = Seq(seq.0 + CHUNK as u64);
                    stats.produced.fetch_add(CHUNK as u64, Ordering::Relaxed);

                    if dirty {
                        // The daemon's own VT would parse this; the client gets a snapshot.
                        continue;
                    }
                    buf.clear();
                    let bytes = PaneOutput::Bytes { seq, data: chunk.clone() };
                    proto::frame::encode(&bytes, &mut buf)?;
                    let over = in_flight.bytes() + buf.len() > cfg.visible_budget;
                    if cfg.flood == FloodMode::Budgeted && over {
                        dirty = true;
                        continue;
                    }
                    pane.write_all(&buf).await?;
                    in_flight.push(produced, buf.len());
                    stats.forwarded.fetch_add(CHUNK as u64, Ordering::Relaxed);
                }
            }
        }

        if dirty && in_flight.is_empty() {
            buf.clear();
            let snapshot = PaneOutput::Snapshot {
                seq: produced,
                snap_gen: SnapGen(1),
                data: vec![0x5a; cfg.snapshot_len],
            };
            proto::frame::encode(&snapshot, &mut buf)?;
            pane.write_all(&buf).await?;
            in_flight.push(produced, buf.len());
            stats.snapshots.fetch_add(1, Ordering::Relaxed);
            dirty = false;
        }
    }
}
