//! Clients written against the wire protocol directly, for behaviour client-core never shows:
//! a peer that stops reading, or one that resumes from nonsense.

use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use iroh::endpoint::{Connection, RecvStream, SendStream, presets};
use iroh::{Endpoint, EndpointAddr, EndpointId};
use proto::{
    BlobReply, Caps, ClientCtl, DeviceId, GrantId, Hello, LinkClass, PaneId, ResumePoint, Seq,
    ServerCtl, SignedGrant, SnapGen, StreamHeader, SubscribeMode, Ticket,
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

/// Sends a `Ping` and a `ListSessions` and waits for both answers; the time it took.
async fn ctl_round_trip(raw: &mut RawClient, nonce: u64, limit: Duration) -> Result<Duration> {
    let started = Instant::now();
    send(&mut raw.tx, &ClientCtl::Ping { nonce }).await?;
    send(&mut raw.tx, &ClientCtl::ListSessions).await?;
    let (mut pong, mut sessions) = (false, false);
    tokio::time::timeout(limit, async {
        while !(pong && sessions) {
            match recv(&mut raw.rx).await? {
                Some(ServerCtl::Pong { nonce: answered }) if answered == nonce => pong = true,
                Some(ServerCtl::Sessions { .. }) => sessions = true,
                Some(_) => {}
                None => bail!("ctl closed"),
            }
        }
        Ok(())
    })
    .await
    .with_context(|| format!("no pong and session list within {} ms", limit.as_millis()))??;
    Ok(started.elapsed())
}

fn subscriptions(panes: &[PaneId]) -> Vec<ClientCtl> {
    panes
        .iter()
        .map(|&pane_id| ClientCtl::Subscribe {
            pane_id,
            mode: SubscribeMode::Live,
            rows_hint: 50,
        })
        .collect()
}

/// One raw client (QUIC's default of 100 incoming streams, never accepting one, as an older
/// app at its limit) follows every pane, then reconnects resuming all of them; after each,
/// a ping and an op must be answered within `limit_ms`.
pub async fn subs(key: &[u8], ticket: &str, limit_ms: u64) -> Result<()> {
    let limit = Duration::from_millis(limit_ms);
    let mut raw = dial(key, ticket, false, Vec::new()).await?;
    let panes = raw.panes.clone();
    for message in subscriptions(&panes) {
        send(&mut raw.tx, &message).await?;
    }
    let following = ctl_round_trip(&mut raw, 1, limit).await?;
    println!(
        "subs: following {} panes, ping and op answered in {:.1} ms",
        panes.len(),
        following.as_secs_f64() * 1000.0
    );
    let epoch = raw.epoch;
    raw.conn.close(0u32.into(), b"reconnecting");
    drop(raw);
    let resume = panes
        .iter()
        .map(|&pane_id| ResumePoint {
            pane_id,
            last_seq: Seq(0),
            snap_gen: SnapGen(epoch),
        })
        .collect();
    let mut raw = dial(key, ticket, false, resume).await?;
    let resuming = ctl_round_trip(&mut raw, 2, limit).await?;
    println!(
        "subs: resuming {} panes, ping and op answered in {:.1} ms",
        panes.len(),
        resuming.as_secs_f64() * 1000.0
    );
    Ok(())
}

/// A PNG header padded to `size` bytes: all the daemon checks of a blob.
fn padded_png(size: usize) -> Vec<u8> {
    let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR\0\0\0\x10\0\0\0\x10".to_vec();
    png.resize(size, 0);
    png
}

async fn open_stream(conn: &Connection, header: &StreamHeader) -> Result<(SendStream, RecvStream)> {
    let (mut tx, rx) = conn.open_bi().await?;
    tx.write_all(&proto::frame::to_vec(header)?).await?;
    Ok((tx, rx))
}

async fn recv_frame<T: serde::de::DeserializeOwned>(stream: &mut RecvStream) -> Result<T> {
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    stream.read_exact(&mut prefix).await?;
    let mut body = vec![0; proto::frame::body_len(prefix, proto::MAX_FRAME_LEN)?];
    stream.read_exact(&mut body).await?;
    Ok(proto::frame::decode_body(&body)?)
}

/// Stores a padded PNG of `size` bytes in the attached session; its hash.
async fn put_blob(raw: &mut RawClient, size: usize) -> Result<proto::BlobHash> {
    send(&mut raw.tx, &ClientCtl::Attach { session_id: None }).await?;
    let session_id = loop {
        match recv(&mut raw.rx).await? {
            Some(ServerCtl::AttachResult(Ok(attachment))) => break attachment.session_id,
            Some(ServerCtl::AttachResult(Err(failure))) => bail!("attach: {failure:?}"),
            Some(_) => {}
            None => bail!("closed before attaching"),
        }
    };
    let image = padded_png(size);
    let header = StreamHeader::Blob(proto::BlobHeader::Put {
        session_id,
        size: image.len() as u64,
        media: proto::MediaType::Png,
    });
    let (mut tx, mut rx) = open_stream(&raw.conn, &header).await?;
    let ready: BlobReply = recv_frame(&mut rx).await?;
    if ready != BlobReply::Ready {
        bail!("blob put: {ready:?}");
    }
    tx.write_all(&image).await?;
    match recv_frame(&mut rx).await? {
        BlobReply::Stored(image) => Ok(image.hash),
        other => bail!("blob put: {other:?}"),
    }
}

/// What one hoarding connection holds open: streams the daemon must not let pile up.
struct Hoard {
    _streams: Vec<(SendStream, RecvStream)>,
    raw: RawClient,
}

/// `connections` raw connections of the paired device each open `streams` blob downloads they
/// never read, 4 uploads that stop after one byte and 4 streams without a header, and keep
/// asking for links and history pages of every pane without reading the answers. Every 5 s a
/// fresh connection follows a pane and times its first frame, and its ping.
pub async fn hoard(
    key: &[u8],
    ticket: &str,
    connections: usize,
    streams: usize,
    blob_mib: usize,
    secs: u64,
) -> Result<()> {
    let mut setup = dial(key, ticket, false, Vec::new()).await?;
    let hash = put_blob(&mut setup, blob_mib << 20).await?;
    let panes = setup.panes.clone();
    setup.conn.close(0u32.into(), b"done");
    let home = std::env::var("HOME").context("HOME")?;
    let mut hoards = Vec::new();
    for connection in 0..connections {
        let raw = dial(key, ticket, false, Vec::new()).await?;
        let mut held = Vec::new();
        let get = StreamHeader::Blob(proto::BlobHeader::Get { hash });
        for _ in 0..streams {
            held.push(open_stream(&raw.conn, &get).await?);
        }
        for upload in 0..4 {
            let header = StreamHeader::Upload(proto::UploadHeader {
                target: proto::WriteTarget {
                    path: format!("{home}/hoard-{connection}-{upload}.bin"),
                    if_match: None,
                    create_new: false,
                    mkdirs: true,
                    mode: None,
                },
                size: 1 << 30,
            });
            let (mut tx, rx) = open_stream(&raw.conn, &header).await?;
            tx.write_all(&[0]).await?;
            held.push((tx, rx));
        }
        for _ in 0..4 {
            let (mut tx, rx) = raw.conn.open_bi().await?;
            tx.write_all(&[0]).await?;
            held.push((tx, rx));
        }
        hoards.push(Hoard {
            _streams: held,
            raw,
        });
    }
    println!(
        "hoard: {connections} connections, each {streams} unread {blob_mib} MiB blob downloads, \
         4 stalled uploads, 4 streams without a header"
    );
    let end = Instant::now() + Duration::from_secs(secs);
    let mut requests = 0u64;
    let mut probes = Vec::new();
    let mut next_probe = Instant::now();
    while Instant::now() < end {
        for hoard in &mut hoards {
            for &pane_id in &panes {
                requests += 1;
                send(
                    &mut hoard.raw.tx,
                    &ClientCtl::Links {
                        req_id: requests,
                        pane_id,
                        commands: 1000,
                    },
                )
                .await?;
                send(
                    &mut hoard.raw.tx,
                    &ClientCtl::FetchHistory {
                        pane_id,
                        snapshot_seq: Seq(0),
                        offset: 0,
                        max_bytes: 2 << 20,
                    },
                )
                .await?;
            }
        }
        if Instant::now() >= next_probe {
            next_probe = Instant::now() + Duration::from_secs(5);
            probes.push(probe_snapshot(key, ticket, panes[0]).await?);
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let closed = hoards
        .iter()
        .filter(|hoard| hoard.raw.conn.close_reason().is_some())
        .count();
    println!("hoard: {requests} links and history requests sent; {closed} connections closed");
    for (snapshot, ping) in &probes {
        println!(
            "hoard probe: first frame of a fresh subscription {:.1} ms, ping {:.1} ms",
            snapshot.as_secs_f64() * 1000.0,
            ping.as_secs_f64() * 1000.0
        );
    }
    Ok(())
}

/// A fresh connection follows `pane`: the time to its stream's first frame, and to a pong.
async fn probe_snapshot(key: &[u8], ticket: &str, pane: PaneId) -> Result<(Duration, Duration)> {
    let mut raw = dial(key, ticket, false, Vec::new()).await?;
    let started = Instant::now();
    for message in subscriptions(&[pane]) {
        send(&mut raw.tx, &message).await?;
    }
    let first_frame = tokio::time::timeout(Duration::from_secs(30), async {
        let mut stream = raw.conn.accept_uni().await?;
        let _header: StreamHeader = recv_frame(&mut stream).await?;
        let _frame: proto::PaneOutput = recv_frame(&mut stream).await?;
        Ok::<_, anyhow::Error>(started.elapsed())
    })
    .await
    .context("no snapshot within 30 s")??;
    let ping = ctl_round_trip(&mut raw, 3, Duration::from_secs(30)).await?;
    raw.conn.close(0u32.into(), b"done");
    Ok((first_frame, ping))
}
