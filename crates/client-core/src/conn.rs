//! The connection supervisor: dial, handshake, replay wanted state, pump streams, redial.

use std::net::TcpListener as StdTcpListener;
use std::str::FromStr;
use std::sync::Arc;
use std::time::Duration;

use iroh::endpoint::{Connection, ReadExactError, RecvStream, SendStream, presets};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayUrl};
use proto::{
    AttachFailure, AttachVia, Attachment, Bulk, Caps, ClientCtl, ClientInput, ForwardReply, Hello,
    Input, InputSeq, LinkClass, OpOutcome, PaneId, PaneOutput, ResumePoint, Seq, ServerCtl,
    SignedGrant, StreamHeader,
};
use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::io::AsyncWriteExt;
use tokio::sync::{Notify, mpsc};
use tokio::task::JoinSet;

use crate::mirror::{Applied, Mirror};
use crate::{ClientEvent, Inner, Outgoing, RelayMode, device_id, lock};

const MAX_BACKOFF: Duration = Duration::from_secs(5);
const ACK_INTERVAL: Duration = Duration::from_millis(5);

#[derive(Debug, thiserror::Error)]
pub(crate) enum ConnError {
    #[error("{0}")]
    Net(String),
    #[error("refused: {0:?}")]
    Refused(proto::RefuseReason),
}

fn net(e: impl std::fmt::Display) -> ConnError {
    ConnError::Net(e.to_string())
}

pub(crate) async fn send<T: Serialize>(stream: &mut SendStream, msg: &T) -> Result<(), ConnError> {
    let buf = proto::frame::to_vec(msg).map_err(net)?;
    stream.write_all(&buf).await.map_err(net)
}

pub(crate) async fn recv<T: DeserializeOwned>(
    stream: &mut RecvStream,
) -> Result<Option<T>, ConnError> {
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    match stream.read_exact(&mut prefix).await {
        Ok(()) => {}
        Err(ReadExactError::FinishedEarly(0)) => return Ok(None),
        Err(e) => return Err(net(e)),
    }
    let len = proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).map_err(net)?;
    let mut body = vec![0; len];
    stream.read_exact(&mut body).await.map_err(net)?;
    proto::frame::decode_body(&body).map(Some).map_err(net)
}

async fn bind(inner: &Inner) -> Result<Endpoint, ConnError> {
    let key: [u8; 32] = inner.config.secret_key.as_slice().try_into().map_err(net)?;
    endpoint_builder(inner.config.relay, &inner.relays, &inner.options)?
        .secret_key(iroh::SecretKey::from_bytes(&key))
        .bind()
        .await
        .map_err(net)
}

/// An endpoint builder for dialling a daemon whose ticket says `relays`. The client's own
/// `Disabled` wins (the app's local-only switch); otherwise the daemon's choice does.
pub(crate) fn endpoint_builder(
    mode: RelayMode,
    relays: &proto::TicketRelays,
    options: &crate::ConnectOptions,
) -> Result<iroh::endpoint::Builder, ConnError> {
    use proto::TicketRelays;
    let mut builder = match (mode, relays) {
        (RelayMode::Disabled, _) | (_, TicketRelays::Disabled) => {
            Endpoint::builder(presets::Minimal)
        }
        (RelayMode::Default, TicketRelays::Default) => Endpoint::builder(presets::N0),
        (RelayMode::Default, TicketRelays::Custom { urls, auth_token }) => {
            let map = iroh::RelayMap::try_from_iter(urls.iter().map(String::as_str))
                .map_err(|e| ConnError::Net(format!("relay urls in the ticket: {e}")))?;
            let map = match auth_token {
                Some(token) => map.with_auth_token(token.clone()),
                None => map,
            };
            Endpoint::builder(presets::Minimal).relay_mode(iroh::RelayMode::Custom(map))
        }
    };
    if !options.relay_ca_der.is_empty() {
        let roots = options
            .relay_ca_der
            .iter()
            .map(|der| rustls_pki_types::CertificateDer::from(der.clone()));
        builder = builder.ca_tls_config(iroh::tls::CaTlsConfig::embedded().with_extra_roots(roots));
    }
    Ok(builder)
}

fn daemon_addr(inner: &Inner) -> Result<EndpointAddr, ConnError> {
    ticket_addr(&inner.ticket, inner.config.relay, &inner.relays)
}

/// Where to dial the ticket's daemon: its direct addresses, plus its home relay (and, for
/// self-hosted relays, the others it may move to) unless relays are off.
pub(crate) fn ticket_addr(
    ticket: &proto::Ticket,
    mode: RelayMode,
    relays: &proto::TicketRelays,
) -> Result<EndpointAddr, ConnError> {
    let id = EndpointId::from_bytes(&ticket.daemon_id.0).map_err(net)?;
    let mut addr = EndpointAddr::new(id);
    for a in &ticket.addrs {
        addr = addr.with_ip_addr(*a);
    }
    if mode == RelayMode::Disabled || *relays == proto::TicketRelays::Disabled {
        return Ok(addr);
    }
    let mut urls: Vec<&str> = ticket.relay_url.as_deref().into_iter().collect();
    if let proto::TicketRelays::Custom { urls: custom, .. } = relays {
        urls.extend(custom.iter().map(String::as_str));
    }
    for url in urls {
        if let Ok(url) = RelayUrl::from_str(url) {
            addr = addr.with_relay_url(url);
        }
    }
    Ok(addr)
}

/// Keeps a connection up for the client's lifetime.
pub(crate) async fn supervise(inner: Arc<Inner>) {
    let endpoint = loop {
        match bind(&inner).await {
            Ok(ep) => break ep,
            Err(e) => {
                inner.emit(ClientEvent::Disconnected {
                    reason: format!("binding endpoint: {e}"),
                });
                tokio::time::sleep(MAX_BACKOFF).await;
            }
        }
    };
    *lock(&inner.endpoint) = Some(endpoint.clone());
    let mut backoff = Duration::from_millis(100);
    loop {
        if *lock(&inner.paused) {
            inner.reconnect.notified().await;
            continue;
        }
        match connect_once(&inner, &endpoint).await {
            Ok(conn) => {
                backoff = Duration::from_millis(100);
                let reason = run(&inner, conn).await;
                *lock(&inner.connection) = None;
                inner.ws.fail_pending();
                inner.mp.fail_pending();
                inner.art.fail_pending();
                inner.assist.fail_pending();
                inner.emit(ClientEvent::Disconnected { reason });
                if *lock(&inner.paused) {
                    continue;
                }
                // A dropped connection is retried at once; backoff only applies to failures.
                continue;
            }
            Err(ConnError::Refused(reason)) => {
                inner.emit(ClientEvent::Refused {
                    reason: format!("{reason:?}"),
                });
                inner.reconnect.notified().await;
                continue;
            }
            Err(e) => {
                inner.emit(ClientEvent::Disconnected {
                    reason: e.to_string(),
                });
            }
        }
        // Wait out the backoff, or less if asked to reconnect now.
        let _ = tokio::time::timeout(backoff, inner.reconnect.notified()).await;
        backoff = (backoff * 2).min(MAX_BACKOFF);
    }
}

struct Live {
    conn: Connection,
    ctl_tx: SendStream,
    ctl_rx: RecvStream,
    epoch: u64,
    /// Admitted for an upgrade only (the daemon's snapshot format differs).
    incompatible: bool,
}

async fn connect_once(inner: &Arc<Inner>, endpoint: &Endpoint) -> Result<Live, ConnError> {
    let result = dial(inner, endpoint).await;
    // What the daemon said about itself, once per dial (not per grant tried), whenever it
    // answered at all.
    if let Ok(_) | Err(ConnError::Refused(_)) = &result {
        let info = lock(&inner.daemon_info).clone();
        inner.emit(ClientEvent::DaemonInfo { info });
    }
    if let Err(ConnError::Refused(
        reason @ (proto::RefuseReason::SnapshotFormat { .. }
        | proto::RefuseReason::WireVersion { .. }),
    )) = &result
    {
        *lock(&inner.incompatible) = true;
        inner.emit(ClientEvent::Incompatible {
            reason: incompatible_words(reason),
        });
    }
    result
}

async fn dial(inner: &Arc<Inner>, endpoint: &Endpoint) -> Result<Live, ConnError> {
    let addr = daemon_addr(inner)?;
    // Try as a paired device first; fall back to the ticket's one-time secret.
    let paired = *lock(&inner.paired);
    let grants: &[u16] = if crate::mp::is_guest(inner) {
        &[SignedGrant::CHAIN]
    } else if paired {
        &[SignedGrant::DEVICE]
    } else {
        &[SignedGrant::DEVICE, SignedGrant::PAIRING]
    };
    let mut last = ConnError::Net("no grant tried".into());
    for &v in grants {
        let conn = endpoint
            .connect(addr.clone(), proto::ALPN)
            .await
            .map_err(net)?;
        match handshake(inner, conn, v).await {
            Ok(live) => {
                *lock(&inner.paired) = true;
                return Ok(live);
            }
            Err(ConnError::Refused(proto::RefuseReason::InvalidGrant)) => {
                last = ConnError::Refused(proto::RefuseReason::InvalidGrant);
            }
            Err(e) => return Err(e),
        }
    }
    Err(last)
}

async fn handshake(inner: &Arc<Inner>, conn: Connection, v: u16) -> Result<Live, ConnError> {
    let (mut ctl_tx, mut ctl_rx) = conn.open_bi().await.map_err(net)?;
    let _ = ctl_tx.set_priority(100);
    let (token, grant_id) = match (&inner.mp.invite, v) {
        (Some(invite), SignedGrant::CHAIN) => (invite.chain.to_token(), invite.chain.grant_id()),
        (_, SignedGrant::PAIRING) => (inner.ticket.secret.0.to_vec(), proto::GrantId([0; 16])),
        _ => (Vec::new(), proto::GrantId([0; 16])),
    };
    let resume = resume_points(inner);
    let hello = Hello {
        device_id: device_id(&inner.config),
        principal_id: inner.ticket.principal,
        grant: SignedGrant { v, grant_id, token },
        snapshot_format: u32::from(ghostty_vt::snapshot_format()),
        resume,
        caps: Caps::ECHO_PREDICTION
            | Caps::ARTIFACTS
            | Caps::ATTACH_RESULT
            | Caps::DAEMON_INFO
            | Caps::AGENT_USAGE,
        link: LinkClass::Normal,
        resume_token: lock(&inner.resume_token).clone(),
    };
    send(&mut ctl_tx, &ClientCtl::Hello(hello)).await?;
    // Daemons that know `Caps::DAEMON_INFO` describe themselves first; older ones answer
    // with `Welcome` or `Refused` straight away.
    let mut first = recv::<ServerCtl>(&mut ctl_rx).await?;
    let info = match first {
        Some(ServerCtl::DaemonInfo(info)) => {
            first = recv::<ServerCtl>(&mut ctl_rx).await?;
            Some(info)
        }
        _ => None,
    };
    *lock(&inner.daemon_info) = info;
    let ours = u32::from(ghostty_vt::snapshot_format());
    match first {
        Some(ServerCtl::Welcome(welcome)) => {
            let incompatible = welcome.snapshot_format != ours;
            *lock(&inner.incompatible) = incompatible;
            if !incompatible {
                *lock(&inner.resume_token) = Some(welcome.resume_token);
            }
            Ok(Live {
                conn,
                ctl_tx,
                ctl_rx,
                epoch: welcome.session_epoch.0,
                incompatible,
            })
        }
        Some(ServerCtl::Refused { reason }) => Err(ConnError::Refused(reason)),
        other => Err(ConnError::Net(format!("expected Welcome, got {other:?}"))),
    }
}

/// Why a daemon and this client cannot work together, in words.
fn incompatible_words(reason: &proto::RefuseReason) -> String {
    match reason {
        proto::RefuseReason::WireVersion { supported } => format!(
            "the host's helper speaks protocol version {supported}, this app {}",
            proto::WIRE_VERSION
        ),
        _ => "the host's helper draws terminals in a format this app does not read".into(),
    }
}

/// Resume points for followed panes, focused first.
fn resume_points(inner: &Inner) -> Vec<ResumePoint> {
    let wanted = lock(&inner.wanted);
    let mirrors = lock(&inner.mirrors);
    let mut panes = wanted.subscribed.clone();
    panes.sort_by_key(|&p| Some(p) != wanted.focus);
    panes
        .into_iter()
        .filter_map(|p| {
            mirrors.get(&p).map(|m| ResumePoint {
                pane_id: p,
                last_seq: Seq(m.seq()),
                snap_gen: m.snap_gen,
            })
        })
        .collect()
}

/// Runs one live connection; returns why it ended.
async fn run(inner: &Arc<Inner>, live: Live) -> String {
    if live.incompatible {
        return run_incompatible(inner, live).await;
    }
    let Live {
        conn,
        mut ctl_tx,
        ctl_rx,
        epoch,
        incompatible: _,
    } = live;
    let resumed = {
        let mut e = lock(&inner.epoch);
        let resumed = e.is_some();
        *e = Some(epoch);
        resumed
    };
    lock(&inner.stats).connections += 1;
    // History requests in flight died with the previous connection.
    for m in lock(&inner.mirrors).values_mut() {
        m.history.in_flight = false;
    }
    *lock(&inner.connection) = Some(conn.clone());
    inner.emit(ClientEvent::Connected { epoch, resumed });

    let mut input = match conn.open_uni().await {
        Ok(s) => s,
        Err(e) => return e.to_string(),
    };
    let _ = input.set_priority(90);
    if let Err(e) = send(&mut input, &StreamHeader::Input).await {
        return e.to_string();
    }

    // Replay what the client wants. Panes in the Hello's resume list are already streaming.
    let replay: Vec<ClientCtl> = {
        let wanted = lock(&inner.wanted);
        let mut msgs = Vec::new();
        if wanted.attach_requested {
            msgs.push(ClientCtl::Attach {
                session_id: wanted.session,
            });
        }
        msgs.push(ClientCtl::Visible {
            pane_ids: wanted.visible.clone(),
        });
        msgs.push(ClientCtl::Focus {
            pane_id: wanted.focus,
        });
        for (&pane_id, &size) in &wanted.sizes {
            msgs.push(ClientCtl::Resize { pane_id, size });
        }
        for &pane_id in &wanted.subscribed {
            msgs.push(ClientCtl::Subscribe {
                pane_id,
                mode: proto::SubscribeMode::Live,
                rows_hint: 0,
            });
        }
        msgs
    };
    for msg in &replay {
        if let Err(e) = send(&mut ctl_tx, msg).await {
            return e.to_string();
        }
    }

    // Catch cached drawings up with what changed while away (queued behind the replay).
    inner.art.on_connected(inner);

    let (ctl_out, ctl_out_rx) = mpsc::unbounded_channel();
    let ack_notify = Arc::new(Notify::new());
    let mut tasks = JoinSet::new();
    tasks.spawn(write_ctl(ctl_tx, ctl_out_rx));
    tasks.spawn(read_ctl(Arc::clone(inner), ctl_rx));
    tasks.spawn(accept_panes(
        Arc::clone(inner),
        conn.clone(),
        Arc::clone(&ack_notify),
        ctl_out.clone(),
    ));
    tasks.spawn(send_acks(Arc::clone(inner), ack_notify, ctl_out.clone()));

    let mut outgoing = inner.outgoing_rx.lock().await;
    let mut input_seq: u64 = 0;
    let principal = inner.ticket.principal;
    let reason = loop {
        tokio::select! {
            msg = outgoing.recv() => {
                let Some(msg) = msg else { break "client dropped".to_owned() };
                match msg {
                    Outgoing::Ctl(ctl) => {
                        let _ = ctl_out.send(ctl);
                    }
                    Outgoing::Input { pane_id, payload } => {
                        input_seq += 1;
                        let frame = ClientInput::Input(Input {
                            pane_id,
                            input_seq: InputSeq(input_seq),
                            principal,
                            payload,
                        });
                        if let Err(e) = send(&mut input, &frame).await {
                            break e.to_string();
                        }
                    }
                }
            }
            done = tasks.join_next() => {
                break match done {
                    Some(Ok(reason)) => reason,
                    Some(Err(e)) => e.to_string(),
                    None => "connection tasks ended".to_owned(),
                };
            }
            closed = conn.closed() => break closed.to_string(),
        }
    };
    tasks.abort_all();
    conn.close(0u32.into(), b"");
    reason
}

/// Holds a connection the daemon admitted for an upgrade only: requests are dropped, the
/// connection stays up for [`Client::upgrade_daemon`](crate::Client::upgrade_daemon).
async fn run_incompatible(inner: &Arc<Inner>, live: Live) -> String {
    let Live { conn, ctl_tx, .. } = live;
    *lock(&inner.connection) = Some(conn.clone());
    inner.emit(ClientEvent::Incompatible {
        reason: incompatible_words(&proto::RefuseReason::SnapshotFormat { daemon: 0 }),
    });
    let mut outgoing = inner.outgoing_rx.lock().await;
    let reason = loop {
        tokio::select! {
            msg = outgoing.recv() => if msg.is_none() { break "client dropped".to_owned() },
            closed = conn.closed() => break closed.to_string(),
        }
    };
    drop(ctl_tx);
    conn.close(0u32.into(), b"");
    reason
}

async fn write_ctl(
    mut send_stream: SendStream,
    mut rx: mpsc::UnboundedReceiver<ClientCtl>,
) -> String {
    let mut buf = Vec::new();
    while let Some(msg) = rx.recv().await {
        buf.clear();
        let mut next = Some(msg);
        while let Some(msg) = next {
            if let Err(e) = proto::frame::encode(&msg, &mut buf) {
                tracing::warn!("encoding ctl: {e}");
            }
            next = rx.try_recv().ok();
        }
        if let Err(e) = send_stream.write_all(&buf).await {
            return e.to_string();
        }
    }
    "ctl writer closed".into()
}

async fn read_ctl(inner: Arc<Inner>, mut rx: RecvStream) -> String {
    loop {
        let msg = match recv::<ServerCtl>(&mut rx).await {
            Ok(Some(msg)) => msg,
            Ok(None) => return "daemon closed ctl".into(),
            Err(e) => return e.to_string(),
        };
        let Some(msg) = inner.ws.dispatch(msg) else {
            continue;
        };
        let Some(msg) = inner.mp.dispatch(msg) else {
            continue;
        };
        let Some(msg) = inner.art.dispatch(&inner, msg) else {
            continue;
        };
        let Some(msg) = inner.assist.dispatch(msg) else {
            continue;
        };
        let event = match msg {
            ServerCtl::Sessions { sessions } => ClientEvent::Sessions { sessions },
            ServerCtl::Attached { session_id } => {
                lock(&inner.wanted).session = Some(session_id);
                ClientEvent::Attached {
                    session_id,
                    via: AttachVia::Requested,
                    missing: None,
                }
            }
            ServerCtl::AttachResult(Ok(Attachment {
                session_id,
                via,
                missing,
            })) => {
                lock(&inner.wanted).session = Some(session_id);
                ClientEvent::Attached {
                    session_id,
                    via,
                    missing,
                }
            }
            ServerCtl::AttachResult(Err(AttachFailure { code, message }))
            | ServerCtl::OpResult {
                op_id: 0,
                outcome: OpOutcome::Failed { code, message },
            } => ClientEvent::AttachFailed { code, message },
            ServerCtl::LayoutChanged(layout) => ClientEvent::Layout { layout },
            ServerCtl::PaneMeta(meta) => ClientEvent::PaneMeta { meta },
            ServerCtl::PaneClosed { pane_id } => {
                lock(&inner.mirrors).remove(&pane_id);
                lock(&inner.wanted).subscribed.retain(|&p| p != pane_id);
                ClientEvent::PaneClosed { pane_id }
            }
            ServerCtl::EchoHintAt(hint) => ClientEvent::EchoHint { hint },
            ServerCtl::AgentEvent { pane_id, json } => ClientEvent::AgentEvent { pane_id, json },
            ServerCtl::OpResult { op_id, outcome } => ClientEvent::OpResult { op_id, outcome },
            ServerCtl::CommandMark(mark) => ClientEvent::CommandMark { mark },
            ServerCtl::CommandFinishedUnseen(mark) => ClientEvent::CommandFinishedUnseen { mark },
            ServerCtl::SearchResult {
                req_id,
                pane_id,
                result,
            } => ClientEvent::SearchResult {
                req_id,
                pane_id,
                result,
            },
            ServerCtl::LinksResult {
                req_id,
                pane_id,
                result,
            } => ClientEvent::Links {
                req_id,
                pane_id,
                result,
            },
            ServerCtl::CommandsResult {
                req_id,
                pane_id,
                result,
            } => ClientEvent::Commands {
                req_id,
                pane_id,
                result,
            },
            ServerCtl::CommandOutputResult {
                req_id,
                pane_id,
                result,
            } => ClientEvent::CommandOutput {
                req_id,
                pane_id,
                result,
            },
            ServerCtl::Refused { reason } => {
                return format!("refused: {reason:?}");
            }
            ServerCtl::Revoked { .. } => return "grant revoked".into(),
            other => {
                tracing::trace!("ctl message not surfaced: {other:?}");
                continue;
            }
        };
        inner.emit(event);
    }
}

async fn accept_panes(
    inner: Arc<Inner>,
    conn: Connection,
    acks: Arc<Notify>,
    ctl: mpsc::UnboundedSender<ClientCtl>,
) -> String {
    loop {
        let mut stream = match conn.accept_uni().await {
            Ok(s) => s,
            Err(e) => return e.to_string(),
        };
        let inner = Arc::clone(&inner);
        let acks = Arc::clone(&acks);
        let ctl = ctl.clone();
        tokio::spawn(async move {
            match recv(&mut stream).await {
                Ok(Some(StreamHeader::Pane { pane_id })) => {
                    while let Ok(Some(out)) = recv::<PaneOutput>(&mut stream).await {
                        apply_output(&inner, pane_id, out, &ctl);
                        acks.notify_one();
                    }
                }
                Ok(Some(StreamHeader::Bulk)) => {
                    while let Ok(Some(msg)) = recv::<Bulk>(&mut stream).await {
                        apply_bulk(&inner, msg);
                    }
                }
                other => tracing::debug!("unexpected stream header: {other:?}"),
            }
        });
    }
}

fn apply_output(
    inner: &Inner,
    pane_id: PaneId,
    out: PaneOutput,
    ctl: &mpsc::UnboundedSender<ClientCtl>,
) {
    let keep_vt = inner.config.mirror_vt;
    let event = match out {
        PaneOutput::Bytes { seq, data } => {
            lock(&inner.stats).byte_frames += 1;
            let applied = lock(&inner.mirrors)
                .get_mut(&pane_id)
                .map_or(Applied::Gap, |m| m.apply(seq.0, &data));
            match applied {
                Applied::New { seq, start } => ClientEvent::PaneBytes {
                    pane_id,
                    seq,
                    data: if start == 0 {
                        data
                    } else {
                        data[start..].to_vec()
                    },
                },
                Applied::Duplicate => return,
                Applied::Gap => {
                    // Lost continuity (should not happen on one stream): start over.
                    tracing::warn!(%pane_id, "output gap; resubscribing");
                    let _ = ctl.send(ClientCtl::Unsubscribe { pane_id });
                    let _ = ctl.send(ClientCtl::Subscribe {
                        pane_id,
                        mode: proto::SubscribeMode::Live,
                        rows_hint: 0,
                    });
                    return;
                }
            }
        }
        PaneOutput::SnapshotZstd {
            seq,
            snap_gen,
            raw_len,
            data,
        } => match zstd::bulk::decompress(&data, raw_len as usize) {
            Ok(raw) => snapshot_event(inner, pane_id, seq, snap_gen, raw, keep_vt),
            Err(e) => {
                tracing::warn!(%pane_id, "bad snapshot: {e}");
                return;
            }
        },
        PaneOutput::Snapshot {
            seq,
            snap_gen,
            data,
        } => snapshot_event(inner, pane_id, seq, snap_gen, data, keep_vt),
        PaneOutput::Resized { seq, size } => {
            if let Some(m) = lock(&inner.mirrors).get_mut(&pane_id) {
                m.resize(size);
            }
            ClientEvent::PaneResized {
                pane_id,
                seq: seq.0,
                size,
            }
        }
        PaneOutput::InputAck { input_seq, at_seq } => ClientEvent::InputAck {
            pane_id,
            input_seq: input_seq.0,
            at_seq: at_seq.0,
        },
    };
    inner.emit(event);
}

fn apply_bulk(inner: &Inner, msg: Bulk) {
    let event = match msg {
        Bulk::HistoryPage {
            pane_id,
            snapshot_seq,
            offset,
            next_offset,
            raw_len,
            done,
            data,
            ..
        } => {
            let records = match zstd::bulk::decompress(&data, raw_len as usize) {
                Ok(r) => r,
                Err(e) => {
                    tracing::warn!(%pane_id, "bad history page: {e}");
                    return;
                }
            };
            let applied = lock(&inner.mirrors)
                .get_mut(&pane_id)
                .and_then(|m| m.apply_history(snapshot_seq.0, offset, next_offset, done, &records));
            let Some(rows) = applied else {
                // A page for an older snapshot, or a repeat: nothing to continue.
                return;
            };
            ClientEvent::PaneHistory {
                pane_id,
                snapshot_seq: snapshot_seq.0,
                data: records,
                rows,
                done,
            }
        }
        Bulk::HistoryGone {
            pane_id,
            snapshot_seq,
        } => {
            if let Some(m) = lock(&inner.mirrors).get_mut(&pane_id)
                && m.history.snapshot_seq == snapshot_seq.0
            {
                m.history.in_flight = false;
                m.history.done = true;
            }
            ClientEvent::PaneHistoryGone { pane_id }
        }
        Bulk::History { .. } => return,
    };
    inner.emit(event);
}

fn snapshot_event(
    inner: &Inner,
    pane_id: PaneId,
    seq: Seq,
    snap_gen: proto::SnapGen,
    raw: Vec<u8>,
    keep_vt: bool,
) -> ClientEvent {
    lock(&inner.stats).snapshots += 1;
    let mirror = Mirror::from_snapshot(snap_gen, seq.0, &raw, keep_vt);
    lock(&inner.mirrors).insert(pane_id, mirror);
    ClientEvent::PaneSnapshot {
        pane_id,
        seq: seq.0,
        data: raw,
    }
}

async fn send_acks(
    inner: Arc<Inner>,
    notify: Arc<Notify>,
    ctl: mpsc::UnboundedSender<ClientCtl>,
) -> String {
    loop {
        notify.notified().await;
        let acks: Vec<(PaneId, u64)> = lock(&inner.mirrors)
            .iter_mut()
            .filter(|(_, m)| m.seq() > m.acked)
            .map(|(&p, m)| {
                m.acked = m.seq();
                (p, m.seq())
            })
            .collect();
        for (pane_id, seq) in acks {
            if ctl
                .send(ClientCtl::Ack {
                    pane_id,
                    seq: Seq(seq),
                })
                .is_err()
            {
                return "ctl closed".into();
            }
        }
        tokio::time::sleep(ACK_INTERVAL).await;
    }
}

/// Accepts local TCP connections and splices each onto a port-forward stream.
pub(crate) async fn serve_forward(inner: Arc<Inner>, listener: StdTcpListener, remote_port: u16) {
    let listener = match tokio::net::TcpListener::from_std(listener) {
        Ok(l) => l,
        Err(e) => {
            tracing::warn!("port forward listener: {e}");
            return;
        }
    };
    // Splices live in this set, so stopping this task (dropping the client) ends them too.
    let mut splices = JoinSet::new();
    loop {
        let Ok((tcp, _)) = listener.accept().await else {
            continue;
        };
        while splices.try_join_next().is_some() {}
        let inner = Arc::clone(&inner);
        splices.spawn(async move {
            if let Err(e) = forward_one(&inner, tcp, remote_port).await {
                tracing::debug!("port forward: {e}");
            }
        });
    }
}

async fn forward_one(
    inner: &Inner,
    tcp: tokio::net::TcpStream,
    remote_port: u16,
) -> Result<(), ConnError> {
    // Wait for a connection if the client is between reconnects.
    let conn = loop {
        if let Some(c) = lock(&inner.connection).clone() {
            break c;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let (mut send_stream, mut recv_stream) = conn.open_bi().await.map_err(net)?;
    send(
        &mut send_stream,
        &StreamHeader::PortForward { port: remote_port },
    )
    .await?;
    match recv::<ForwardReply>(&mut recv_stream).await? {
        Some(ForwardReply::Connected) => {}
        Some(ForwardReply::Refused { reason }) => return Err(ConnError::Net(reason)),
        None => return Err(ConnError::Net("forward stream closed".into())),
    }
    let _ = tcp.set_nodelay(true);
    let (mut tcp_read, mut tcp_write) = tcp.into_split();
    let up = async {
        let r = tokio::io::copy(&mut tcp_read, &mut send_stream).await;
        let _ = send_stream.finish();
        r
    };
    let down = async {
        let r = tokio::io::copy(&mut recv_stream, &mut tcp_write).await;
        let _ = tcp_write.shutdown().await;
        r
    };
    let _ = tokio::join!(up, down);
    Ok(())
}
