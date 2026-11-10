//! A directory on a network mount that stops answering (its server stopped): panes and a
//! repository there, next to a healthy repository and a quiet pane. Measures what the user
//! feels elsewhere while the mount hangs: echo latency, how long opening a tab takes, and how
//! late the sidebar shows a change in the healthy repository.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use client_core::WorkspaceEventQueue;
use client_core::{Client, ClientConfig, ClientEvent, EventQueue, RelayMode, WorkspaceEvent};
use proto::{LayoutOp, OpOutcome, PaneId, PaneLaunch, RepoSnapshot};
use tokio::sync::mpsc::UnboundedReceiver;

use crate::{Connection, percentiles};

pub(crate) struct Plan {
    pub healthy: PathBuf,
    pub dead: PathBuf,
    pub secs: u64,
    /// Shell commands that stop and restart the mount's server.
    pub stall: String,
    pub resume: String,
}

pub(crate) async fn run(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    plan: Plan,
) -> Result<()> {
    let mut config = ClientConfig::new(key);
    config.relay = RelayMode::Disabled;
    config.repo_status = true;
    let (listener, events) = EventQueue::channel();
    let client = Client::connect_on(handle, ticket, config, listener)?;
    let (workspace_listener, mut repos) = WorkspaceEventQueue::channel();
    client.set_workspace_listener(workspace_listener);
    client.attach(None);
    let mut conn = Connection {
        client,
        events,
        layout: None,
    };
    let session = conn.layout().await?.session_id;

    let (dead_pane, opened) = tab(&mut conn, session, Some(&plan.dead), None).await?;
    println!("tab in the mount before the stall: {opened:?}");
    tab(&mut conn, session, Some(&plan.healthy), None).await?;
    let (probe, _) = tab(&mut conn, session, None, Some("cat")).await?;
    conn.client.subscribe(probe);
    conn.client.set_view(Some(probe), vec![]);
    let both = |snapshot: &RepoSnapshot| {
        [&plan.healthy, &plan.dead].iter().all(|dir| {
            snapshot
                .worktrees
                .iter()
                .any(|worktree| same_dir(&worktree.path, dir))
        })
    };
    let listed = wait_for_snapshot(&mut repos, Duration::from_secs(30), both).await;
    println!(
        "sidebar lists both repositories before the stall: {}",
        listed.is_some()
    );

    shell(&plan.stall)?;
    println!("mount stalled (pane p{} is in it)", dead_pane.0);
    let (_, opened) = tab(&mut conn, session, Some(&plan.dead), None).await?;
    println!("tab in the stalled mount: {opened:?}");

    let mut echoes = Vec::new();
    let mut repo_lags = Vec::new();
    let mut lost_echoes = 0;
    let mut missed_updates = 0;
    let end = Instant::now() + Duration::from_secs(plan.secs);
    let mut round = 0u64;
    while Instant::now() < end {
        round += 1;
        match echo(&mut conn, probe, round).await? {
            Some(latency) => echoes.push(latency),
            None => lost_echoes += 1,
        }
        let marker = plan.healthy.join("stress-deadmount.txt");
        let line = format!("round {round}\n");
        let mut text = std::fs::read_to_string(&marker).unwrap_or_default();
        text.push_str(&line);
        std::fs::write(&marker, text)?;
        let changed = Instant::now();
        let added = |snapshot: &RepoSnapshot| {
            snapshot.worktrees.iter().any(|worktree| {
                same_dir(&worktree.path, &plan.healthy) && u64::from(worktree.added) >= round
            })
        };
        match wait_for_snapshot(&mut repos, Duration::from_secs(10), added).await {
            Some(_) => repo_lags.push(changed.elapsed()),
            None => missed_updates += 1,
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    let (_, opened) = tab(&mut conn, session, Some(&plan.healthy), None).await?;
    println!("tab in the healthy repository during the stall: {opened:?}");
    println!(
        "echo during the stall: {} (lost {lost_echoes})",
        percentiles(echoes)
    );
    println!(
        "healthy repository change → sidebar: {} (missed {missed_updates})",
        percentiles(repo_lags)
    );
    shell(&plan.resume)?;
    Ok(())
}

fn same_dir(reported: &str, dir: &Path) -> bool {
    let canonical = dir.canonicalize().unwrap_or_else(|_| dir.to_owned());
    Path::new(reported) == canonical || Path::new(reported) == dir
}

fn shell(command: &str) -> Result<()> {
    let status = std::process::Command::new("/bin/sh")
        .args(["-c", command])
        .status()?;
    if !status.success() {
        bail!("{command}: {status}");
    }
    Ok(())
}

/// Opens a tab in `cwd` (running `command`, or a shell); its pane and how long the op took.
async fn tab(
    conn: &mut Connection,
    session: proto::SessionId,
    cwd: Option<&Path>,
    command: Option<&str>,
) -> Result<(PaneId, Duration)> {
    let cwd = cwd.map(|dir| dir.to_string_lossy().into_owned());
    let launch = match command {
        Some(command) => PaneLaunch::Command {
            argv: vec![command.into()],
            cwd,
        },
        None => PaneLaunch::Shell { cwd },
    };
    let started = Instant::now();
    match conn
        .op(LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch,
        })
        .await?
    {
        OpOutcome::TabCreated { pane_id, .. } => Ok((pane_id, started.elapsed())),
        other => bail!("opening a tab: {other:?}"),
    }
}

async fn echo(conn: &mut Connection, probe: PaneId, round: u64) -> Result<Option<Duration>> {
    let token = format!("<{round:07}>");
    let sent = Instant::now();
    conn.client.send_input(probe, token.clone().into_bytes());
    let seen = tokio::time::timeout(Duration::from_secs(5), async {
        let mut tail = Vec::new();
        loop {
            if let ClientEvent::PaneBytes { pane_id, data, .. } = conn.next().await?
                && pane_id == probe
            {
                tail.extend_from_slice(&data);
                if tail
                    .windows(token.len())
                    .any(|window| window == token.as_bytes())
                {
                    return Ok::<_, anyhow::Error>(());
                }
                let keep = tail.len().saturating_sub(64);
                tail.drain(..keep);
            }
        }
    })
    .await;
    match seen {
        Ok(result) => {
            result.context("echo probe")?;
            Ok(Some(sent.elapsed()))
        }
        Err(_) => Ok(None),
    }
}

async fn wait_for_snapshot(
    repos: &mut UnboundedReceiver<WorkspaceEvent>,
    within: Duration,
    mut wanted: impl FnMut(&RepoSnapshot) -> bool,
) -> Option<RepoSnapshot> {
    tokio::time::timeout(within, async {
        loop {
            if let WorkspaceEvent::Repos { snapshot } = repos.recv().await?
                && wanted(&snapshot)
            {
                return Some(snapshot);
            }
        }
    })
    .await
    .ok()
    .flatten()
}
