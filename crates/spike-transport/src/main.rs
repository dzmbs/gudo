//!
//! ```text
//!     [--delay-ms D] [--queue-kb Q] [--pty-mbyte P]
//!     [--budget-kb B] [--snapshot-kb S] [--link loopback|shaped|both]
//! ```

use std::time::Duration;

use anyhow::{Context, Result, bail};
use spike_transport::client::ClientConfig;
use spike_transport::link::LinkShape;
use spike_transport::scenario::{self, Link, Outcome, Scenario};
use spike_transport::server::{FloodMode, Priorities};

struct Args {
    keys: usize,
    interval: Duration,
    shape: LinkShape,
    pty_rate: u64,
    budget: usize,
    snapshot_len: usize,
    links: Vec<&'static str>,
}

fn parse_args() -> Result<Args> {
    let mut args = Args {
        keys: 500,
        interval: Duration::from_millis(20),
        shape: LinkShape {
            rate: 20_000_000 / 8,
            one_way_delay: Duration::from_millis(20),
            queue_limit: 256 * 1024,
        },
        pty_rate: 100_000_000,
        budget: 32 * 1024,
        snapshot_len: 48 * 1024,
        links: vec!["loopback", "shaped"],
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let value = it.next().with_context(|| format!("{flag} needs a value"))?;
        let num = || {
            value
                .parse::<u64>()
                .with_context(|| format!("bad value for {flag}"))
        };
        match flag.as_str() {
            "--keys" => args.keys = num()? as usize,
            "--interval-ms" => args.interval = Duration::from_millis(num()?),
            "--rate-mbit" => args.shape.rate = num()? * 1_000_000 / 8,
            "--delay-ms" => args.shape.one_way_delay = Duration::from_millis(num()?),
            "--queue-kb" => args.shape.queue_limit = num()? as usize * 1024,
            "--pty-mbyte" => args.pty_rate = num()? * 1_000_000,
            "--budget-kb" => args.budget = num()? as usize * 1024,
            "--snapshot-kb" => args.snapshot_len = num()? as usize * 1024,
            "--link" => {
                args.links = match value.as_str() {
                    "loopback" => vec!["loopback"],
                    "shaped" => vec!["shaped"],
                    "both" => vec!["loopback", "shaped"],
                    other => bail!("unknown link {other}"),
                }
            }
            other => bail!("unknown flag {other}"),
        }
    }
    Ok(args)
}

fn ms(d: Duration) -> String {
    format!("{:.2}", d.as_secs_f64() * 1000.0)
}

fn row(link: &str, flood: FloodMode, prio: Priorities, o: &Outcome) -> String {
    let c = &o.client;
    let secs = c.window.as_secs_f64();
    let (p50, p90, p99, max) = o
        .latency
        .map(|l| (ms(l.p50), ms(l.p90), ms(l.p99), ms(l.max)))
        .unwrap_or_default();
    format!(
        "| {link} | {flood:?} | {prio:?} | {} | {p50} | {p90} | {p99} | {max} | {} | {:.1} | {:.1} | {} |",
        c.latencies.len(),
        c.lost,
        c.flood_wire as f64 / secs / 1e6,
        c.flood_applied as f64 / secs / 1e6,
        c.snapshots,
    )
}

fn main() -> Result<()> {
    let args = parse_args()?;
    let cases = [
        (FloodMode::Off, Priorities::Spec),
        (FloodMode::Naive, Priorities::Flat),
        (FloodMode::Naive, Priorities::Spec),
        (FloodMode::Budgeted, Priorities::Spec),
    ];
    println!(
        "keys={} interval={:?} pty_rate={} MB/s shaped={} Mbit/s, {:?} one-way, {} KB queue",
        args.keys,
        args.interval,
        args.pty_rate / 1_000_000,
        args.shape.rate * 8 / 1_000_000,
        args.shape.one_way_delay,
        args.shape.queue_limit / 1024,
    );
    println!();
    println!(
        "| link | flood | priorities | n | p50 ms | p90 ms | p99 ms | max ms | lost | flood wire MB/s | flood applied MB/s | snapshots |"
    );
    println!("|---|---|---|---|---|---|---|---|---|---|---|---|");
    let mut paths = Vec::new();
    for link_name in &args.links {
        let link = match *link_name {
            "loopback" => Link::Loopback,
            _ => Link::Shaped(args.shape),
        };
        for (flood, prio) in cases {
            let mut server = scenario::server_config(flood, prio);
            server.pty_rate = args.pty_rate;
            server.visible_budget = args.budget;
            server.snapshot_len = args.snapshot_len;
            let client = ClientConfig {
                keys: args.keys,
                key_interval: args.interval,
                warmup: Duration::from_secs(1),
                priorities: prio,
            };
            let outcome = scenario::run(&Scenario {
                link,
                server,
                client,
            })?;
            println!("{}", row(link_name, flood, prio, &outcome));
            paths.push(format!(
                "{link_name}/{flood:?}/{prio:?}: connect {} ms; produced {} MB, forwarded {} MB\n  - client: {}\n  - daemon: {}",
                ms(outcome.client.connect),

                outcome.produced / 1_000_000,
                outcome.forwarded / 1_000_000,
                outcome.client.path,
                outcome.server_path,
            ));
        }
    }
    println!();
    for p in paths {
        println!("- {p}");
    }
    Ok(())
}
