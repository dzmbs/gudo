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

use crate::Connection;

pub struct Plan {
    pub secs: u64,
    /// Freeze the daemon this often (0: never) ...
    pub every: u64,
    /// ... for this long.
    pub outage_secs: u64,
    pub pid: u32,
    /// One numbered line every `interval_ms`.
    pub interval_ms: u64,
    pub file: PathBuf,
}

fn freeze(pid: u32, frozen: bool) {
    let signal = if frozen { "-STOP" } else { "-CONT" };
    let _ = std::process::Command::new("kill")
        .args([signal, &pid.to_string()])
        .status();
}

pub async fn run(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    plan: Plan,
) -> Result<()> {
    let mut conn = Connection::open(handle, key, ticket, false)?;
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
                    if let Some(down_at) = down_since.take() {
                        gaps.push(down_at.elapsed());
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
        if text.lines().any(|line| line.trim_end_matches('\r') == last) || Instant::now() > settle {
            break;
        }
        tokio::select! {
            () = tokio::time::sleep(Duration::from_millis(200)) => {}
            _ = conn.next() => {}
        }
    }
    let text = std::fs::read_to_string(&plan.file).unwrap_or_default();
    let received: Vec<u64> = text
        .lines()
        .filter_map(|line| line.trim_end_matches('\r').parse().ok())
        .collect();
    let mut seen = vec![0u32; sent as usize + 1];
    let mut out_of_order = 0;
    let mut previous = 0;
    for &line_number in &received {
        if let Some(count) = seen.get_mut(line_number as usize) {
            *count += 1;
        }
        if line_number < previous {
            out_of_order += 1;
        }
        previous = line_number;
    }
    let lost: Vec<u64> = (1..=sent)
        .filter(|&line_number| seen[line_number as usize] == 0)
        .collect();
    let duplicated = seen.iter().filter(|&&count| count > 1).count();
    println!(
        "outages: sent {sent} lines, pane got {} (lost {}, duplicated {duplicated}, out of order \
         {out_of_order}); {drops} disconnects, {resumes} resumes; back after {}",
        received.len(),
        lost.len(),
        crate::percentiles(gaps),
    );
    if !lost.is_empty() {
        println!("  first lost lines: {:?}", &lost[..lost.len().min(10)]);
    }
    let _ = conn.op(LayoutOp::ClosePane { pane_id: pane }).await;
    Ok(())
}
