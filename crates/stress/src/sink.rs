//! Push budget and knock floods.
//!
//! `push_sink` registers this device for pushes with a local fake relay and counts what the
//! daemon sends it while something else (approval spam from fake agents) runs; `knocks` knocks
//! on a knock invite from many fresh devices at once.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use client_core::ClientConfig;
use proto::{PushPrefs, PushRegistration};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

use crate::Conn;

/// A fake relay answering `status` to every POST; returns its URL and the request count.
async fn fake_relay(status: u16) -> Result<(String, Arc<AtomicU64>)> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let url = format!("http://{}", listener.local_addr()?);
    let count = Arc::new(AtomicU64::new(0));
    let seen = Arc::clone(&count);
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let seen = Arc::clone(&seen);
            tokio::spawn(async move {
                let mut reader = BufReader::new(stream);
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).await.unwrap_or(0) == 0 {
                        return;
                    }
                    let mut len = 0;
                    loop {
                        let mut header = String::new();
                        if reader.read_line(&mut header).await.unwrap_or(0) == 0 {
                            return;
                        }
                        let header = header.trim_end();
                        if header.is_empty() {
                            break;
                        }
                        if let Some((name, value)) = header.split_once(':')
                            && name.eq_ignore_ascii_case("content-length")
                        {
                            len = value.trim().parse().unwrap_or(0);
                        }
                    }
                    let mut body = vec![0; len];
                    if reader.read_exact(&mut body).await.is_err() {
                        return;
                    }
                    seen.fetch_add(1, Ordering::Relaxed);
                    let reply = format!(
                        "HTTP/1.1 {status} X\r\ncontent-length: 2\r\nretry-after: 30\r\n\r\nok"
                    );
                    if reader.get_mut().write_all(reply.as_bytes()).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    Ok((url, count))
}

/// Registers for every push kind with a fake relay, stays in the background for `secs` and
/// prints how many pushes arrived each 10 s.
pub async fn push_sink(
    handle: &tokio::runtime::Handle,
    key: Vec<u8>,
    ticket: &str,
    secs: u64,
    status: u16,
) -> Result<()> {
    let (url, count) = fake_relay(status).await?;
    let mut conn = Conn::open(handle, key, ticket, false)?;
    conn.layout().await?;
    let (_secret, public) = client_core::push::x25519_keypair();
    let reg = PushRegistration {
        cap: "stress".into(),
        seal_key: public,
        relay_url: Some(url),
        prefs: PushPrefs {
            approvals: true,
            blocked: true,
            done: true,
            failed: true,
            commands: true,
        },
        activity_cap: None,
    };
    conn.client
        .push_register(reg)
        .await
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;
    // In the background: nothing on screen, so everything is pushed.
    conn.client.set_view(None, vec![]);
    let start = Instant::now();
    let mut last = 0;
    let mut tick = tokio::time::interval(Duration::from_secs(10));
    tick.tick().await;
    while start.elapsed() < Duration::from_secs(secs) {
        tokio::select! {
            _ = tick.tick() => {
                let now = count.load(Ordering::Relaxed);
                println!("  push sink: t={:>4}s pushes {now} (+{})", start.elapsed().as_secs(), now - last);
                last = now;
            }
            event = conn.next() => { event?; }
        }
    }
    let attention = conn
        .client
        .attention_list()
        .await
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;
    println!(
        "push sink: {} pushes in {secs} s; inbox holds {} items ({} unseen)",
        count.load(Ordering::Relaxed),
        attention.items.len(),
        attention.unseen
    );
    let _ = conn.client.push_unregister().await;
    Ok(())
}

/// `parallel` fresh devices at a time knock on `invite`, each hanging up after `hold_ms`
/// (or when refused), for `secs`.
pub async fn knocks(invite: &str, secs: u64, parallel: usize, hold_ms: u64) -> Result<()> {
    let end = Instant::now() + Duration::from_secs(secs);
    let counts: Arc<[AtomicU64; 4]> = Arc::default();
    let mut tasks = tokio::task::JoinSet::new();
    for _ in 0..parallel {
        let (invite, counts) = (invite.to_owned(), Arc::clone(&counts));
        tasks.spawn(async move {
            while Instant::now() < end {
                let mut config = ClientConfig::new(ClientConfig::generate_key());
                config.relay = client_core::RelayMode::Disabled;
                let waiting = || counts[0].fetch_add(1, Ordering::Relaxed);
                let knock = client_core::knock::knock(
                    &invite,
                    config,
                    client_core::ConnectOptions::default(),
                    Some("stress".into()),
                    |_| {
                        waiting();
                    },
                );
                let slot = match tokio::time::timeout(Duration::from_millis(hold_ms), knock).await {
                    Err(_) => 1,
                    Ok(Err(client_core::knock::KnockError::Refused(_))) => 2,
                    Ok(_) => 3,
                };
                counts[slot].fetch_add(1, Ordering::Relaxed);
            }
        });
    }
    while tasks.join_next().await.is_some() {}
    let [waiting, hung_up, refused, other] = &*counts;
    println!(
        "knocks: {} reached the owner, {} hung up after {hold_ms} ms, {} refused, {} failed",
        waiting.load(Ordering::Relaxed),
        hung_up.load(Ordering::Relaxed),
        refused.load(Ordering::Relaxed),
        other.load(Ordering::Relaxed)
    );
    Ok(())
}

/// The invite in `path` (the `un invite` output's link line).
pub fn read_invite(path: &std::path::Path) -> Result<String> {
    std::fs::read_to_string(path)?
        .split_whitespace()
        .find(|w| w.contains("join"))
        .map(str::to_owned)
        .context("no join link in the invite file")
}
