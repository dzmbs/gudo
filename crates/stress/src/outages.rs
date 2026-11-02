//! Input across outages: numbered lines typed into a pane that writes what it receives to a
//! file, while the daemon is frozen (SIGSTOP / SIGCONT) now and then. The file must hold every
//! line exactly once, in order.
//!
//! The outage freezes the daemon rather than dropping datagrams in a proxy: on one host, QUIC
//! multipath opens a direct loopback path around any user-space proxy, so only the operating
//! system (pf, dummynet: root) or a second machine can cut or degrade the link itself.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Result, bail};
use client_core::ClientEvent;
use proto::{LayoutOp, OpOutcome, PaneLaunch};

use crate::Conn;

/// The run's settings.
pub struct Plan {
    pub secs: u64,
    /// Freeze the daemon this often (0: never) ...
    pub every: u64,
    /// ... for this long.
    pub outage_secs: u64,
    /// The daemon's process.
    pub pid: u32,
    /// One numbered line every `interval_ms`.
    pub interval_ms: u64,
    /// Where the pane writes what it receives.
    pub file: PathBuf,
}

fn freeze(pid: u32, frozen: bool) {
    let signal = if frozen { "-STOP" } else { "-CONT" };
    let _ = std::process::Command::new("kill")
        .args([signal, &pid.to_string()])
        .status();
}

/// Types numbered lines across outages and checks the pane got each exactly once.
pub async fn run(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    plan: Plan,
) -> Result<()> {
    let mut conn = Conn::open(handle, key, ticket, false)?;
    let layout = conn.layout().await?;
    let _ = std::fs::remove_file(&plan.file);
    let command = format!("stty raw -echo; exec cat > '{}'", plan.file.display());
    let pane = match conn
        .op(LayoutOp::NewTab {
            session_id: layout.session_id,
            name: "outages".into(),
            launch: PaneLaunch::Command {
                argv: vec!["/bin/sh".into(), "-c".into(), command],
                cwd: None,
            },
        })
        .await?
    {
        OpOutcome::TabCreated { pane_id, .. } => pane_id,
        other => bail!("pane: {other:?}"),
    };
    conn.client.subscribe(pane);
    conn.client.set_view(Some(pane), vec![pane]);
    tokio::time::sleep(Duration::from_millis(500)).await;

    let start = Instant::now();
    let end = start + Duration::from_secs(plan.secs);
    let mut tick = tokio::time::interval(Duration::from_millis(plan.interval_ms.max(1)));
    let (mut sent, mut drops, mut resumes) = (0u64, 0u64, 0u64);
    let mut down_since: Option<Instant> = None;
    let mut gaps = Vec::new();
    let mut cycle = start;
    let mut frozen = false;
    while Instant::now() < end {
        tokio::select! {
            _ = tick.tick() => {
                sent += 1;
                conn.client.send_input(pane, format!("{sent:08}\n").into_bytes());
                if plan.every > 0 {
                    let since = cycle.elapsed().as_secs();
                    if since >= plan.every + plan.outage_secs {
                        cycle = Instant::now();
                    }
                    let down = (plan.every..plan.every + plan.outage_secs).contains(&since);
                    if down != frozen {
                        frozen = down;
                        freeze(plan.pid, down);
                    }
                }
            }
            event = conn.next() => match event? {
                ClientEvent::Disconnected { reason } => {
                    drops += 1;
                    down_since.get_or_insert_with(Instant::now);
                    if drops <= 3 {
                        println!("  disconnected at {:.1} s: {reason}", start.elapsed().as_secs_f64());
                    }
                }
                ClientEvent::Connected { resumed: true, .. } => {
                    resumes += 1;
                    if let Some(at) = down_since.take() {
                        gaps.push(at.elapsed());
                    }
                }
                _ => {}
            },
        }
    }
    if frozen {
        freeze(plan.pid, false);
    }
    let last = format!("{sent:08}");
    let settle = Instant::now() + Duration::from_secs(40);
    loop {
        let text = std::fs::read_to_string(&plan.file).unwrap_or_default();
        if text.lines().any(|l| l.trim_end_matches('\r') == last) || Instant::now() > settle {
            break;
        }
        tokio::select! {
            () = tokio::time::sleep(Duration::from_millis(200)) => {}
            _ = conn.next() => {}
        }
    }
    let text = std::fs::read_to_string(&plan.file).unwrap_or_default();
    let got: Vec<u64> = text
        .lines()
        .filter_map(|l| l.trim_end_matches('\r').parse().ok())
        .collect();
    let mut seen = vec![0u32; sent as usize + 1];
    let mut out_of_order = 0;
    let mut prev = 0;
    for &n in &got {
        if let Some(c) = seen.get_mut(n as usize) {
            *c += 1;
        }
        if n < prev {
            out_of_order += 1;
        }
        prev = n;
    }
    let lost: Vec<u64> = (1..=sent).filter(|&n| seen[n as usize] == 0).collect();
    let dup = seen.iter().filter(|&&c| c > 1).count();
    println!(
        "outages: sent {sent} lines, pane got {} (lost {}, duplicated {dup}, out of order \
         {out_of_order}); {drops} disconnects, {resumes} resumes; back after {}",
        got.len(),
        lost.len(),
        crate::percentiles(gaps),
    );
    if !lost.is_empty() {
        println!("  first lost lines: {:?}", &lost[..lost.len().min(10)]);
    }
    let _ = conn.op(LayoutOp::ClosePane { pane_id: pane }).await;
    Ok(())
}
