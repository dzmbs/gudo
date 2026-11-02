//! Load and chaos driver for a running daemon. It reads the device key and ticket `un pair`
//! saved (`$XDG_CONFIG_HOME/unnamed`) and drives the daemon over the real protocol. The
//! scenarios in `scripts/stress/` start the daemon and call this; results go to stdout.

mod outages;
mod raw;
mod sink;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use client_core::{Client, ClientConfig, ClientEvent, EventQueue, RelayMode};
use proto::{Axis, LayoutNode, LayoutOp, OpOutcome, PaneId, PaneLaunch, PaneSize, SessionLayout};
use tokio::sync::mpsc::UnboundedReceiver;

#[derive(Parser)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Create and close panes as fast as the daemon answers, `concurrency` ops in flight.
    Churn {
        #[arg(long, default_value_t = 10)]
        secs: u64,
        #[arg(long, default_value_t = 16)]
        concurrency: usize,
        /// Command for the new panes (default: the daemon's shell).
        #[arg(long)]
        command: Option<String>,
    },
    /// Split the focused pane `depth` times, each time splitting the new pane.
    Deep {
        #[arg(long)]
        depth: usize,
        /// Canvas panes (no process), to go past the PTY limit.
        #[arg(long)]
        canvas: bool,
    },
    /// Open `count` tabs (canvas panes without a process with `--canvas`, else running
    /// `command` or the shell), 16 ops in flight, and keep them; prints op latency, the time a
    /// new client takes to get the layout, and the layout's encoded size.
    Tabs {
        #[arg(long)]
        count: usize,
        #[arg(long)]
        canvas: bool,
        #[arg(long)]
        command: Option<String>,
    },
    /// Open a tab running `command` and print its pane id.
    Spawn { command: Vec<String> },
    /// Echo latency of a pane running `cat` (created here), sampled every `interval_ms`.
    Latency {
        #[arg(long, default_value_t = 10)]
        secs: u64,
        #[arg(long, default_value_t = 20)]
        interval_ms: u64,
    },
    /// `n` clients, each with its own key and ticket from `tickets` (one per line), attached
    /// to the session and following its focused pane, for `secs`.
    Clients {
        #[arg(long)]
        tickets: PathBuf,
        #[arg(long, default_value_t = 30)]
        secs: u64,
        /// Each client resizes the focused pane to its own size this many times a second.
        #[arg(long, default_value_t = 0)]
        resize_hz: u64,
    },
    /// Clients that pair with a ticket each, attach, subscribe to every pane and then never
    /// read anything again.
    Slow {
        #[arg(long)]
        tickets: PathBuf,
        #[arg(long, default_value_t = 30)]
        secs: u64,
    },
    /// Connect, attach, subscribe and drop the connection after 0..`max_ms`, over and over.
    Reconnect {
        #[arg(long, default_value_t = 10)]
        secs: u64,
        #[arg(long, default_value_t = 50)]
        max_ms: u64,
        #[arg(long, default_value_t = 4)]
        parallel: usize,
    },
    /// Raw connections whose `Hello` resumes garbage: unknown panes, future and past offsets,
    /// stale generations, thousands of points.
    StaleResume {
        #[arg(long, default_value_t = 10)]
        secs: u64,
    },
    /// Send keys to the focused pane at `rate` per second.
    Keys {
        #[arg(long, default_value_t = 10_000)]
        rate: u64,
        #[arg(long, default_value_t = 10)]
        secs: u64,
    },
    /// Paste `mb` MiB into the focused pane in one paste.
    Paste {
        #[arg(long, default_value_t = 100)]
        mb: usize,
    },
    /// Layout ops (focus, resize, zoom, rename, tab moves) at `rate` per second.
    Layout {
        #[arg(long, default_value_t = 1000)]
        rate: u64,
        #[arg(long, default_value_t = 10)]
        secs: u64,
    },
    /// Numbered lines typed into a pane that writes them to `file` while the daemon (`pid`)
    /// is frozen every `every` seconds for `outage_secs`; checks each arrived exactly once.
    Outages {
        #[arg(long)]
        pid: u32,
        #[arg(long)]
        file: PathBuf,
        #[arg(long, default_value_t = 60)]
        secs: u64,
        #[arg(long, default_value_t = 30)]
        every: u64,
        #[arg(long, default_value_t = 20)]
        outage_secs: u64,
        #[arg(long, default_value_t = 20)]
        interval_ms: u64,
    },
    /// Registers for pushes with a local fake relay answering `status`, stays in the
    /// background for `secs` and counts the pushes.
    PushSink {
        #[arg(long, default_value_t = 60)]
        secs: u64,
        #[arg(long, default_value_t = 200)]
        status: u16,
    },
    /// Fresh devices knocking on the knock invite in `invite_file`, `parallel` at a time.
    Knocks {
        #[arg(long)]
        invite_file: PathBuf,
        #[arg(long, default_value_t = 30)]
        secs: u64,
        #[arg(long, default_value_t = 16)]
        parallel: usize,
        #[arg(long, default_value_t = 500)]
        hold_ms: u64,
    },
    /// Project definitions and tab memberships at `rate` per second.
    Projects {
        #[arg(long, default_value_t = 1000)]
        rate: u64,
        #[arg(long, default_value_t = 10)]
        secs: u64,
    },
}

fn config_dir() -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config")
        })
        .join("unnamed")
}

fn saved() -> Result<(Vec<u8>, String)> {
    let dir = config_dir();
    let key = std::fs::read(dir.join("un.key")).context("un.key: run `un pair` first")?;
    let ticket = std::fs::read_to_string(dir.join("un.ticket"))?
        .trim()
        .to_owned();
    Ok((key, ticket))
}

/// A connected client and its events.
struct Conn {
    client: Client,
    events: UnboundedReceiver<ClientEvent>,
    layout: Option<SessionLayout>,
}

impl Conn {
    fn open(
        handle: &tokio::runtime::Handle,
        key: Vec<u8>,
        ticket: &str,
        mirror: bool,
    ) -> Result<Self> {
        let (listener, events) = EventQueue::channel();
        let mut config = ClientConfig::new(key);
        config.relay = RelayMode::Disabled;
        config.mirror_vt = mirror;
        // A line from `un invite` joins as a guest; anything else is a pairing ticket.
        let client = if ticket.contains("join") {
            Client::join_on(handle, ticket, config, listener)?
        } else {
            Client::connect_on(handle, ticket, config, listener)?
        };
        client.attach(None);
        Ok(Self {
            client,
            events,
            layout: None,
        })
    }

    async fn next(&mut self) -> Result<ClientEvent> {
        let event = self.events.recv().await.context("client stopped")?;
        match &event {
            ClientEvent::Layout { layout } => self.layout = Some(layout.clone()),
            ClientEvent::Refused { reason } => bail!("refused: {reason}"),
            _ => {}
        }
        Ok(event)
    }

    async fn layout(&mut self) -> Result<SessionLayout> {
        let deadline = Instant::now() + Duration::from_secs(20);
        while self.layout.is_none() {
            tokio::time::timeout_at(deadline.into(), self.next())
                .await
                .context("timed out waiting for the layout")??;
        }
        Ok(self.layout.clone().expect("checked"))
    }

    async fn op(&mut self, op: LayoutOp) -> Result<OpOutcome> {
        let id = self.client.op(op);
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let event = tokio::time::timeout_at(deadline.into(), self.next())
                .await
                .context("timed out waiting for an op result")??;
            if let ClientEvent::OpResult { op_id, outcome } = event
                && op_id == id
            {
                return Ok(outcome);
            }
        }
    }
}

fn focused(layout: &SessionLayout) -> Option<(proto::TabId, PaneId)> {
    let tab = layout
        .tabs
        .iter()
        .find(|t| Some(t.tab_id) == layout.active_tab)?;
    Some((tab.tab_id, tab.focused))
}

fn leaves(node: &LayoutNode, out: &mut Vec<PaneId>) {
    let mut stack = vec![node];
    while let Some(node) = stack.pop() {
        match node {
            LayoutNode::Leaf(p) => out.push(*p),
            LayoutNode::Split { first, second, .. } => {
                stack.push(second);
                stack.push(first);
            }
        }
    }
}

fn all_panes(layout: &SessionLayout) -> Vec<PaneId> {
    let mut out = Vec::new();
    for tab in &layout.tabs {
        leaves(&tab.root, &mut out);
    }
    out
}

fn launch(command: &Option<String>) -> PaneLaunch {
    match command {
        Some(c) => PaneLaunch::Command {
            argv: vec!["/bin/sh".into(), "-c".into(), c.clone()],
            cwd: None,
        },
        None => PaneLaunch::Shell { cwd: None },
    }
}

fn percentiles(mut v: Vec<Duration>) -> String {
    if v.is_empty() {
        return "no samples".into();
    }
    v.sort();
    let at = |q: f64| v[((v.len() - 1) as f64 * q) as usize].as_secs_f64() * 1000.0;
    format!(
        "n={} p50={:.2}ms p99={:.2}ms max={:.2}ms",
        v.len(),
        at(0.5),
        at(0.99),
        at(1.0)
    )
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()?;
    let handle = runtime.handle().clone();
    runtime.block_on(run(cli, handle))
}

async fn run(cli: Cli, handle: tokio::runtime::Handle) -> Result<()> {
    let (key, ticket) = saved()?;
    match cli.cmd {
        Cmd::Churn {
            secs,
            concurrency,
            command,
        } => churn(&handle, key, &ticket, secs, concurrency, command).await,
        Cmd::Deep { depth, canvas } => deep(&handle, key, &ticket, depth, canvas).await,
        Cmd::Tabs {
            count,
            canvas,
            command,
        } => tabs(&handle, key, &ticket, count, canvas, command).await,
        Cmd::Spawn { command } => {
            let mut conn = Conn::open(&handle, key, &ticket, false)?;
            let layout = conn.layout().await?;
            let outcome = conn
                .op(LayoutOp::NewTab {
                    session_id: layout.session_id,
                    name: String::new(),
                    launch: launch(&Some(command.join(" "))),
                })
                .await?;
            match outcome {
                OpOutcome::TabCreated { pane_id, .. } => println!("{}", pane_id.0),
                other => bail!("{other:?}"),
            }
            Ok(())
        }
        Cmd::Latency { secs, interval_ms } => {
            let report = latency(&handle, key, &ticket, secs, interval_ms).await?;
            println!("echo latency: {report}");
            Ok(())
        }
        Cmd::Clients {
            tickets,
            secs,
            resize_hz,
        } => clients(&handle, &tickets, secs, resize_hz).await,
        Cmd::Slow { tickets, secs } => raw::slow(&tickets, secs).await,
        Cmd::Reconnect {
            secs,
            max_ms,
            parallel,
        } => reconnect(&handle, key, &ticket, secs, max_ms, parallel).await,
        Cmd::StaleResume { secs } => raw::stale_resume(&key, &ticket, secs).await,
        Cmd::Keys { rate, secs } => keys(&handle, key, &ticket, rate, secs).await,
        Cmd::Paste { mb } => paste(&handle, key, &ticket, mb).await,
        Cmd::Layout { rate, secs } => layout_storm(&handle, key, &ticket, rate, secs).await,
        Cmd::Projects { rate, secs } => projects(&handle, key, &ticket, rate, secs).await,
        Cmd::PushSink { secs, status } => {
            sink::push_sink(&handle, key, &ticket, secs, status).await
        }
        Cmd::Knocks {
            invite_file,
            secs,
            parallel,
            hold_ms,
        } => sink::knocks(&sink::read_invite(&invite_file)?, secs, parallel, hold_ms).await,
        Cmd::Outages {
            pid,
            file,
            secs,
            every,
            outage_secs,
            interval_ms,
        } => {
            let plan = outages::Plan {
                secs,
                every,
                outage_secs,
                pid,
                interval_ms,
                file,
            };
            outages::run(&handle, key, &ticket, plan).await
        }
    }
}

async fn churn(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    secs: u64,
    concurrency: usize,
    command: Option<String>,
) -> Result<()> {
    let mut conn = Conn::open(handle, key, ticket, false)?;
    let layout = conn.layout().await?;
    let session = layout.session_id;
    let mut pending: HashMap<u64, (Instant, bool)> = HashMap::new();
    let (mut created, mut closed, mut failed) = (0u64, 0u64, 0u64);
    let mut lat = Vec::new();
    let mut errors: HashMap<String, u64> = HashMap::new();
    let end = Instant::now() + Duration::from_secs(secs);
    let start = Instant::now();
    let new_tab = |c: &Conn| {
        c.client.op(LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch: launch(&command),
        })
    };
    for _ in 0..concurrency {
        pending.insert(new_tab(&conn), (Instant::now(), true));
    }
    while !pending.is_empty() {
        let event = tokio::time::timeout(Duration::from_secs(30), conn.next())
            .await
            .context("no answer to an op for 30 s")??;
        let ClientEvent::OpResult { op_id, outcome } = event else {
            continue;
        };
        let Some((at, create)) = pending.remove(&op_id) else {
            continue;
        };
        lat.push(at.elapsed());
        let running = Instant::now() < end;
        match outcome {
            OpOutcome::TabCreated { pane_id, .. } => {
                created += 1;
                let id = conn.client.op(LayoutOp::ClosePane { pane_id });
                pending.insert(id, (Instant::now(), false));
            }
            OpOutcome::Failed { code, message } => {
                failed += 1;
                *errors.entry(format!("{code:?}: {message}")).or_default() += 1;
                if running {
                    pending.insert(new_tab(&conn), (Instant::now(), true));
                }
            }
            _ => {
                if !create {
                    closed += 1;
                }
                if running {
                    pending.insert(new_tab(&conn), (Instant::now(), true));
                }
            }
        }
    }
    let wall = start.elapsed().as_secs_f64();
    println!(
        "churn: created {created} closed {closed} failed {failed} in {wall:.1} s ({:.0} panes/s); op latency {}",
        created as f64 / wall,
        percentiles(lat)
    );
    for (e, n) in errors {
        println!("  {n}x {e}");
    }
    Ok(())
}

async fn deep(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    depth: usize,
    canvas: bool,
) -> Result<()> {
    let mut conn = Conn::open(handle, key, ticket, false)?;
    let layout = conn.layout().await?;
    let (_, mut pane) = focused(&layout).context("no focused pane")?;
    let start = Instant::now();
    for i in 0..depth {
        let launch = if canvas {
            PaneLaunch::Canvas { artifact_id: None }
        } else {
            PaneLaunch::Shell { cwd: None }
        };
        let axis = if i % 2 == 0 {
            Axis::Horizontal
        } else {
            Axis::Vertical
        };
        match conn
            .op(LayoutOp::Split {
                pane_id: pane,
                axis,
                launch,
            })
            .await?
        {
            OpOutcome::PaneCreated { pane_id } => pane = pane_id,
            other => {
                println!("deep: split {i} refused: {other:?}");
                break;
            }
        }
    }
    let layout = conn.layout().await?;
    println!(
        "deep: {} panes in the session after {:.1} s",
        all_panes(&layout).len(),
        start.elapsed().as_secs_f64()
    );
    Ok(())
}

async fn tabs(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    count: usize,
    canvas: bool,
    command: Option<String>,
) -> Result<()> {
    let mut conn = Conn::open(handle, key.clone(), ticket, false)?;
    let session = conn.layout().await?.session_id;
    let new_tab = |c: &Conn| {
        c.client.op(LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch: if canvas {
                PaneLaunch::Canvas { artifact_id: None }
            } else {
                launch(&command)
            },
        })
    };
    let mut pending: HashMap<u64, Instant> = HashMap::new();
    let (mut asked, mut created) = (0, 0);
    let mut errors: HashMap<String, u64> = HashMap::new();
    let mut lat = Vec::new();
    let start = Instant::now();
    while asked < count.min(16) {
        pending.insert(new_tab(&conn), Instant::now());
        asked += 1;
    }
    while !pending.is_empty() {
        let event = tokio::time::timeout(Duration::from_secs(60), conn.next())
            .await
            .context("no answer to an op for 60 s")??;
        let ClientEvent::OpResult { op_id, outcome } = event else {
            continue;
        };
        let Some(at) = pending.remove(&op_id) else {
            continue;
        };
        lat.push(at.elapsed());
        match outcome {
            OpOutcome::TabCreated { .. } => created += 1,
            OpOutcome::Failed { code, message } => {
                *errors.entry(format!("{code:?}: {message}")).or_default() += 1;
            }
            _ => {}
        }
        if asked < count {
            pending.insert(new_tab(&conn), Instant::now());
            asked += 1;
        }
    }
    println!(
        "tabs: {created} of {count} created in {:.1} s; op latency {}",
        start.elapsed().as_secs_f64(),
        percentiles(lat)
    );
    for (e, n) in errors {
        println!("  {n}x {e}");
    }
    let at = Instant::now();
    let mut fresh = Conn::open(handle, key, ticket, false)?;
    let layout = fresh.layout().await?;
    println!(
        "tabs: a new client had the layout ({} panes, {} KiB encoded) after {:.0} ms",
        all_panes(&layout).len(),
        proto::frame::to_vec(&layout)?.len() / 1024,
        at.elapsed().as_secs_f64() * 1000.0
    );
    Ok(())
}

/// Opens a `cat` pane and measures send → echo for `secs`.
async fn latency(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    secs: u64,
    interval_ms: u64,
) -> Result<String> {
    let mut conn = Conn::open(handle, key, ticket, false)?;
    let layout = conn.layout().await?;
    let pane = match conn
        .op(LayoutOp::NewTab {
            session_id: layout.session_id,
            name: "probe".into(),
            launch: PaneLaunch::Command {
                argv: vec!["cat".into()],
                cwd: None,
            },
        })
        .await?
    {
        OpOutcome::TabCreated { pane_id, .. } => pane_id,
        other => bail!("probe pane: {other:?}"),
    };
    conn.client.subscribe(pane);
    conn.client.set_view(Some(pane), vec![]);
    tokio::time::sleep(Duration::from_millis(500)).await;
    let mut samples = Vec::new();
    let mut lost = 0;
    let end = Instant::now() + Duration::from_secs(secs);
    let mut n = 0u64;
    while Instant::now() < end {
        n += 1;
        let token = format!("<{n:07}>");
        let sent = Instant::now();
        conn.client.send_input(pane, token.clone().into_bytes());
        let seen = tokio::time::timeout(Duration::from_secs(5), async {
            let mut tail = Vec::new();
            loop {
                if let ClientEvent::PaneBytes { pane_id, data, .. } = conn.next().await?
                    && pane_id == pane
                {
                    tail.extend_from_slice(&data);
                    if tail.windows(token.len()).any(|w| w == token.as_bytes()) {
                        return Ok::<_, anyhow::Error>(());
                    }
                    let keep = tail.len().saturating_sub(64);
                    tail.drain(..keep);
                }
            }
        })
        .await;
        match seen {
            Ok(r) => {
                r?;
                samples.push(sent.elapsed());
            }
            Err(_) => lost += 1,
        }
        if n.is_multiple_of(50) {
            conn.client.send_input(pane, b"\n".to_vec());
        }
        tokio::time::sleep(Duration::from_millis(interval_ms)).await;
    }
    let _ = conn.op(LayoutOp::ClosePane { pane_id: pane }).await;
    Ok(format!("{} lost(>5s)={lost}", percentiles(samples)))
}

async fn clients(
    handle: &tokio::runtime::Handle,
    tickets: &PathBuf,
    secs: u64,
    resize_hz: u64,
) -> Result<()> {
    let tickets: Vec<String> = std::fs::read_to_string(tickets)?
        .lines()
        .filter(|l| !l.is_empty())
        .map(str::to_owned)
        .collect();
    let connected = Arc::new(AtomicU64::new(0));
    let bytes = Arc::new(AtomicU64::new(0));
    let snapshots = Arc::new(AtomicU64::new(0));
    let disconnects = Arc::new(AtomicU64::new(0));
    let mut tasks = tokio::task::JoinSet::new();
    let end = Instant::now() + Duration::from_secs(secs);
    for (i, ticket) in tickets.into_iter().enumerate() {
        let handle = handle.clone();
        let (connected, bytes, snapshots, disconnects) = (
            Arc::clone(&connected),
            Arc::clone(&bytes),
            Arc::clone(&snapshots),
            Arc::clone(&disconnects),
        );
        tasks.spawn(async move {
            let mut conn = Conn::open(&handle, ClientConfig::generate_key(), &ticket, false)?;
            let mut followed = None;
            let mut resize = tokio::time::interval(Duration::from_millis(
                1000 / resize_hz.max(1),
            ));
            let size = PaneSize {
                cols: 60 + (i % 100) as u16,
                rows: 20 + (i % 40) as u16,
                width_px: 0,
                height_px: 0,
            };
            let mut flip = false;
            while Instant::now() < end {
                tokio::select! {
                    event = conn.next() => match event? {
                        ClientEvent::Connected { .. } => { connected.fetch_add(1, Ordering::Relaxed); }
                        ClientEvent::Disconnected { reason } => {
                            if disconnects.fetch_add(1, Ordering::Relaxed) < 5 {
                                println!("  disconnected: {reason}");
                            }
                        }
                        ClientEvent::PaneBytes { data, .. } => { bytes.fetch_add(data.len() as u64, Ordering::Relaxed); }
                        ClientEvent::PaneSnapshot { .. } => { snapshots.fetch_add(1, Ordering::Relaxed); }
                        ClientEvent::Layout { layout } => {
                            let f = focused(&layout).map(|(_, p)| p);
                            if f != followed && let Some(p) = f {
                                conn.client.subscribe(p);
                                conn.client.set_view(Some(p), vec![]);
                                conn.client.resize(p, size);
                                followed = Some(p);
                            }
                        }
                        _ => {}
                    },
                    _ = resize.tick(), if resize_hz > 0 => {
                        if let Some(p) = followed {
                            flip = !flip;
                            let mut s = size;
                            s.cols += u16::from(flip);
                            conn.client.resize(p, s);
                        }
                    }
                    () = tokio::time::sleep_until(end.into()) => break,
                }
            }
            Ok::<_, anyhow::Error>(())
        });
    }
    let mut errors = 0;
    while let Some(r) = tasks.join_next().await {
        if let Ok(Err(e)) | Err(e) = r.map_err(anyhow::Error::from) {
            errors += 1;
            if errors < 5 {
                println!("  client error: {e:#}");
            }
        }
    }
    println!(
        "clients: connected {} disconnects {} errors {errors}; received {:.1} MB in bytes frames, {} snapshots",
        connected.load(Ordering::Relaxed),
        disconnects.load(Ordering::Relaxed),
        bytes.load(Ordering::Relaxed) as f64 / 1e6,
        snapshots.load(Ordering::Relaxed)
    );
    Ok(())
}

async fn reconnect(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    secs: u64,
    max_ms: u64,
    parallel: usize,
) -> Result<()> {
    let end = Instant::now() + Duration::from_secs(secs);
    let count = Arc::new(AtomicU64::new(0));
    let mut tasks = tokio::task::JoinSet::new();
    for w in 0..parallel {
        let (handle, key, ticket, count) = (
            handle.clone(),
            key.clone(),
            ticket.to_owned(),
            Arc::clone(&count),
        );
        tasks.spawn(async move {
            let mut i = w as u64;
            while Instant::now() < end {
                let mut conn = Conn::open(&handle, key.clone(), &ticket, true)?;
                if let Ok(Ok(layout)) =
                    tokio::time::timeout(Duration::from_secs(5), conn.layout()).await
                {
                    for p in all_panes(&layout).into_iter().take(8) {
                        conn.client.subscribe(p);
                    }
                }
                i = i
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                tokio::time::sleep(Duration::from_millis((i >> 33) % max_ms.max(1))).await;
                drop(conn);
                count.fetch_add(1, Ordering::Relaxed);
            }
            Ok::<_, anyhow::Error>(())
        });
    }
    while let Some(r) = tasks.join_next().await {
        r??;
    }
    println!(
        "reconnect: {} connections dropped mid-stream",
        count.load(Ordering::Relaxed)
    );
    Ok(())
}

async fn keys(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    rate: u64,
    secs: u64,
) -> Result<()> {
    let mut conn = Conn::open(handle, key, ticket, false)?;
    let layout = conn.layout().await?;
    let (_, pane) = focused(&layout).context("no focused pane")?;
    let start = Instant::now();
    let total = rate * secs;
    let per_tick = (rate / 1000).max(1);
    let mut tick = tokio::time::interval(Duration::from_millis(1));
    let mut sent = 0;
    while sent < total {
        tick.tick().await;
        for _ in 0..per_tick {
            let ch = (b'a' + (sent % 26) as u8) as char;
            conn.client.send_key(
                pane,
                proto::FullKeyEvent {
                    key: 0,
                    mods: 0,
                    consumed_mods: 0,
                    action: proto::KeyAction::Press,
                    text: Some(ch.to_string()),
                    unshifted_codepoint: Some(ch as u32),
                    composing: false,
                },
            );
            sent += 1;
        }
    }
    println!(
        "keys: sent {sent} in {:.1} s",
        start.elapsed().as_secs_f64()
    );
    Ok(())
}

async fn paste(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    mb: usize,
) -> Result<()> {
    let mut conn = Conn::open(handle, key, ticket, false)?;
    let layout = conn.layout().await?;
    let (_, pane) = focused(&layout).context("no focused pane")?;
    let line = "paste paste paste paste paste paste paste paste paste paste paste paste paste\n";
    let text = line.repeat(mb * 1024 * 1024 / line.len());
    let start = Instant::now();
    conn.client.send_paste(pane, text);
    println!(
        "paste: queued {mb} MiB in {:.2} s",
        start.elapsed().as_secs_f64()
    );
    // Give the client time to put it on the wire.
    tokio::time::sleep(Duration::from_secs(3)).await;
    Ok(())
}

async fn layout_storm(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    rate: u64,
    secs: u64,
) -> Result<()> {
    let mut conn = Conn::open(handle, key, ticket, false)?;
    let layout = conn.layout().await?;
    let panes = all_panes(&layout);
    let tabs: Vec<_> = layout.tabs.iter().map(|t| t.tab_id).collect();
    let session = layout.session_id;
    let mut tick = tokio::time::interval(Duration::from_millis(1));
    let per_tick = (rate / 1000).max(1);
    let end = Instant::now() + Duration::from_secs(secs);
    let mut i = 0usize;
    while Instant::now() < end {
        tick.tick().await;
        for _ in 0..per_tick {
            i += 1;
            let pane = panes[i % panes.len()];
            let tab = tabs[i % tabs.len()];
            let op = match i % 7 {
                0 => LayoutOp::Focus { pane_id: pane },
                1 => LayoutOp::Resize {
                    pane_id: pane,
                    axis: Axis::Horizontal,
                    delta: if i.is_multiple_of(2) { 0.05 } else { -0.05 },
                },
                2 => LayoutOp::ToggleZoom { pane_id: pane },
                3 => LayoutOp::RenameTab {
                    tab_id: tab,
                    name: format!("t{i}"),
                },
                4 => LayoutOp::MoveTab {
                    tab_id: tab,
                    index: (i % 7) as u32,
                },
                5 => LayoutOp::SelectTab { tab_id: tab },
                _ => LayoutOp::RenameSession {
                    session_id: session,
                    name: format!("s{}", i % 3),
                },
            };
            conn.client.op(op);
        }
        while let Ok(_event) = conn.events.try_recv() {}
    }
    // The last op's answer arrives once everything before it was applied.
    let outcome = conn.op(LayoutOp::Focus { pane_id: panes[0] }).await?;
    println!("layout: {i} ops, last answered {outcome:?}");
    Ok(())
}

async fn projects(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    rate: u64,
    secs: u64,
) -> Result<()> {
    let mut conn = Conn::open(handle, key, ticket, false)?;
    let layout = conn.layout().await?;
    let tabs: Vec<_> = layout.tabs.iter().map(|t| t.tab_id).collect();
    let session = layout.session_id;
    let mut tick = tokio::time::interval(Duration::from_millis(1));
    let per_tick = (rate / 1000).max(1);
    let end = Instant::now() + Duration::from_secs(secs);
    let mut i = 0usize;
    while Instant::now() < end {
        tick.tick().await;
        for _ in 0..per_tick {
            i += 1;
            let id = format!("p{}", i % 40);
            let op = match i % 3 {
                0 => LayoutOp::PutProject {
                    session_id: session,
                    project: proto::Project {
                        id,
                        name: format!("project {i}"),
                        color: (i % 8) as u8,
                        order: i as i64,
                        updated: proto::UnixMillis(i as u64),
                    },
                },
                1 => LayoutOp::SetTabProject {
                    tab_id: tabs[i % tabs.len()],
                    project: Some(id),
                    rank: i as i64,
                },
                _ => LayoutOp::RemoveProject {
                    session_id: session,
                    project: id,
                },
            };
            conn.client.op(op);
        }
        while let Ok(_event) = conn.events.try_recv() {}
    }
    let outcome = conn
        .op(LayoutOp::RemoveProject {
            session_id: session,
            project: "p0".into(),
        })
        .await?;
    println!("projects: {i} ops, last answered {outcome:?}");
    Ok(())
}
