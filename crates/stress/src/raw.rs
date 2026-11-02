//! Clients written against the wire protocol directly, for behaviour client-core never shows:
//! a peer that stops reading, or one that resumes from nonsense.

use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use iroh::endpoint::{Connection, RecvStream, SendStream, presets};
use iroh::{Endpoint, EndpointAddr, EndpointId};
use proto::{
    Caps, ClientCtl, DeviceId, GrantId, Hello, LinkClass, PaneId, ResumePoint, Seq, ServerCtl,
    SignedGrant, SnapGen, SubscribeMode, Ticket,
};

async fn send(stream: &mut SendStream, message: &ClientCtl) -> Result<()> {
    stream.write_all(&proto::frame::to_vec(message)?).await?;
    Ok(())
}

async fn recv(stream: &mut RecvStream) -> Result<Option<ServerCtl>> {
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    if stream.read_exact(&mut prefix).await.is_err() {
        return Ok(None);
    }
    let len = proto::frame::body_len(prefix, proto::MAX_FRAME_LEN)?;
    let mut body = vec![0; len];
    stream.read_exact(&mut body).await?;
    Ok(Some(proto::frame::decode_body(&body)?))
}

struct RawClient {
    _endpoint: Endpoint,
    conn: Connection,
    tx: SendStream,
    rx: RecvStream,
    epoch: u64,
    panes: Vec<PaneId>,
}

/// Dials and says `Hello`: with the ticket's pairing secret, or as an already paired device.
async fn dial(
    key: &[u8],
    ticket: &str,
    pairing: bool,
    resume: Vec<ResumePoint>,
) -> Result<RawClient> {
    let (ticket, _) = Ticket::parse_with_extras(ticket)?;
    let secret = iroh::SecretKey::from_bytes(key.try_into().context("32-byte key")?);
    let device = DeviceId(*secret.public().as_bytes());
    let endpoint = Endpoint::builder(presets::Minimal)
        .secret_key(secret)
        .bind()
        .await?;
    let mut addr = EndpointAddr::new(EndpointId::from_bytes(&ticket.daemon_id.0)?);
    for ip in &ticket.addrs {
        addr = addr.with_ip_addr(*ip);
    }
    let conn = endpoint.connect(addr, proto::ALPN).await?;
    let (mut tx, mut rx) = conn.open_bi().await?;
    let (grant_version, token) = if pairing {
        (SignedGrant::PAIRING, ticket.secret.0.to_vec())
    } else {
        (SignedGrant::DEVICE, Vec::new())
    };
    let hello = Hello {
        device_id: device,
        principal_id: ticket.principal,
        grant: SignedGrant {
            v: grant_version,
            grant_id: GrantId([0; 16]),
            token,
        },
        snapshot_format: u32::from(ghostty_vt::snapshot_format()),
        resume,
        caps: Caps::ECHO_PREDICTION | Caps::ATTACH_RESULT | Caps::PRESENCE | Caps::APPROVALS,
        link: LinkClass::Normal,
        resume_token: None,
    };
    send(&mut tx, &ClientCtl::Hello(hello)).await?;
    loop {
        match recv(&mut rx).await? {
            Some(ServerCtl::Welcome(welcome)) => {
                return Ok(RawClient {
                    _endpoint: endpoint,
                    conn,
                    tx,
                    rx,
                    epoch: welcome.session_epoch.0,
                    panes: welcome.panes.iter().map(|pane| pane.pane_id).collect(),
                });
            }
            Some(ServerCtl::Refused { reason }) => bail!("refused: {reason:?}"),
            Some(_) => {}
            None => bail!("closed before Welcome"),
        }
    }
}

/// Pairs one raw client per ticket, attaches, subscribes to every pane live, then holds the
/// connection open without reading a byte for `secs`.
pub async fn slow(tickets: &Path, secs: u64) -> Result<()> {
    let tickets = std::fs::read_to_string(tickets)?;
    let mut held = Vec::new();
    for ticket in tickets.lines().filter(|line| !line.is_empty()) {
        let key = client_core::ClientConfig::generate_key();
        let mut raw = dial(&key, ticket, true, Vec::new()).await?;
        send(&mut raw.tx, &ClientCtl::Attach { session_id: None }).await?;
        for &pane_id in &raw.panes {
            send(
                &mut raw.tx,
                &ClientCtl::Subscribe {
                    pane_id,
                    mode: SubscribeMode::Live,
                    rows_hint: 50,
                },
            )
            .await?;
        }
        send(
            &mut raw.tx,
            &ClientCtl::Visible {
                pane_ids: raw.panes.clone(),
            },
        )
        .await?;
        held.push(raw);
    }
    println!(
        "slow: {} clients subscribed and no longer reading",
        held.len()
    );
    let end = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < end {
        tokio::time::sleep(Duration::from_secs(1)).await;
        let closed = held
            .iter()
            .filter(|client| client.conn.close_reason().is_some())
            .count();
        if closed == held.len() {
            println!("slow: the daemon closed every stuck client");
            return Ok(());
        }
    }
    let closed = held
        .iter()
        .filter(|client| client.conn.close_reason().is_some())
        .count();
    println!(
        "slow: {closed}/{} closed by the daemon after {secs} s",
        held.len()
    );
    Ok(())
}

/// Reconnects as the paired device with nonsense resume points, checking each time that the
/// daemon still answers.
pub async fn stale_resume(key: &[u8], ticket: &str, secs: u64) -> Result<()> {
    let end = Instant::now() + Duration::from_secs(secs);
    let first = dial(key, ticket, false, Vec::new()).await?;
    let (epoch, panes) = (first.epoch, first.panes.clone());
    drop(first);
    let mut rounds = 0u64;
    let mut rng = 1u64;
    while Instant::now() < end {
        rng = rng
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let mut points = Vec::new();
        let point_count = match rounds % 4 {
            0 => 5000,
            _ => 20,
        };
        for index in 0..point_count {
            let pane = match index % 3 {
                0 => PaneId(rng >> 20),
                _ => panes[(index as usize) % panes.len().max(1)],
            };
            let seq = match index % 4 {
                0 => Seq(u64::MAX),
                1 => Seq(rng >> 8),
                2 => Seq(0),
                _ => Seq(1),
            };
            let generation = if index % 2 == 0 {
                SnapGen(epoch)
            } else {
                SnapGen(rng)
            };
            points.push(ResumePoint {
                pane_id: pane,
                last_seq: seq,
                snap_gen: generation,
            });
        }
        let mut raw = dial(key, ticket, false, points).await?;
        send(&mut raw.tx, &ClientCtl::ListSessions).await?;
        let answered = tokio::time::timeout(Duration::from_secs(5), async {
            while let Some(message) = recv(&mut raw.rx).await? {
                if matches!(message, ServerCtl::Sessions { .. }) {
                    return Ok::<_, anyhow::Error>(true);
                }
            }
            Ok(false)
        })
        .await;
        if !matches!(answered, Ok(Ok(true))) {
            bail!("round {rounds}: no session list after a garbage resume");
        }
        rounds += 1;
    }
    println!("stale-resume: {rounds} rounds, daemon answered every time");
    Ok(())
}
