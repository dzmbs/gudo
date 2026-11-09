//! The connection supervisor: dial, handshake, replay wanted state, pump streams, redial.

use std::net::TcpListener as StdTcpListener;
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use iroh::endpoint::{Connection, ReadExactError, RecvStream, SendStream, presets};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayUrl};
use proto::{
    AttachFailure, AttachVia, Attachment, Bulk, Caps, ClientCtl, ClientInput, ForwardReply, Hello,
    Input, InputPayload, InputSeq, OpOutcome, PaneId, PaneOutput, ResumePoint, Seq, ServerCtl,
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
/// How long a connection must stay up for its end to count as a drop, redialled at once,
/// rather than a failure, backed off (a daemon that welcomes and then drops every connection
/// must not be redialled in a tight loop).
const STABLE_FOR: Duration = Duration::from_secs(5);
/// Acks are batched per pane at most this often: shorter than the usual ~20 ms keeps a
/// fast link's budgeted panes moving.
const ACK_INTERVAL: Duration = Duration::from_millis(5);
/// How long [`Client::probe`](crate::Client::probe) waits for its pong on a link that has
/// gone quiet: a live peer's QUIC stack acknowledges the ping at once, even when the daemon is
/// busy.
pub const PROBE_DEADLINE: Duration = Duration::from_secs(3);
/// How long it waits on a link that still carries packets but answers slowly (a congested
/// mobile network) before calling it dead.
pub const PROBE_SLOW_DEADLINE: Duration = Duration::from_secs(10);
/// By consecutive timeouts. Without them a dead path holds a dial for the whole idle timeout.
const DIAL_DEADLINES: [Duration; 3] = [
    Duration::from_secs(4),
    Duration::from_secs(8),
    proto::IDLE_TIMEOUT,
];
const MIN_BACKOFF: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, Copy)]
pub(crate) struct ProbeDeadlines {
    silent_link: Duration,
    /// Packets still arrive: a congested link, not a dead one.
    busy_link: Duration,
}

impl ProbeDeadlines {
    pub(crate) const TYPING: Self = Self {
        silent_link: PROBE_DEADLINE,
        busy_link: PROBE_SLOW_DEADLINE,
    };
    pub(crate) const FOREGROUND: Self = Self {
        silent_link: Duration::from_millis(1500),
        busy_link: Duration::from_secs(4),
    };
}

enum DialOutcome {
    Finished(Result<Live, ConnError>),
    TimedOut,
    Interrupted,
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum ConnError {
    #[error("{0}")]
    Net(String),
    #[error("refused: {0:?}")]
    Refused(proto::RefuseReason),
}

fn net_error(err: impl std::fmt::Display) -> ConnError {
    ConnError::Net(err.to_string())
}

/// Connects to the daemon at `addr`, also offering the ALPN of daemons installed before the
/// product's rename, so the app can still reach (and upgrade) them.
pub(crate) async fn connect_daemon(
    endpoint: &Endpoint,
    addr: EndpointAddr,
) -> Result<iroh::endpoint::Connection, String> {
    let options = iroh::endpoint::ConnectOptions::new()
        .with_additional_alpns(vec![proto::LEGACY_ALPN.to_vec()]);
    let connecting = endpoint
        .connect_with_opts(addr, proto::ALPN, options)
        .await
        .map_err(|err| err.to_string())?;
    connecting.await.map_err(|err| err.to_string())
}

pub(crate) async fn send<T: Serialize>(stream: &mut SendStream, msg: &T) -> Result<(), ConnError> {
    let frame = proto::frame::to_vec(msg).map_err(net_error)?;
    stream.write_all(&frame).await.map_err(net_error)
}

pub(crate) async fn recv<T: DeserializeOwned>(
    stream: &mut RecvStream,
) -> Result<Option<T>, ConnError> {
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    match stream.read_exact(&mut prefix).await {
        Ok(()) => {}
        Err(ReadExactError::FinishedEarly(0)) => return Ok(None),
        Err(err) => return Err(net_error(err)),
    }
    let len = proto::frame::body_len(prefix, proto::MAX_FRAME_LEN).map_err(net_error)?;
    let mut body = vec![0; len];
    stream.read_exact(&mut body).await.map_err(net_error)?;
    proto::frame::decode_body(&body)
        .map(Some)
        .map_err(net_error)
}

async fn bind(inner: &Inner) -> Result<Endpoint, ConnError> {
    let key: [u8; 32] = inner
        .config
        .secret_key
        .as_slice()
        .try_into()
        .map_err(net_error)?;
    let options = lock(&inner.net).1.clone();
    endpoint_builder(&route(inner), &options)?
        .secret_key(iroh::SecretKey::from_bytes(&key))
        .bind()
        .await
        .map_err(net_error)
}

/// Binds an endpoint, retrying until it works (a bad relay URL in the settings keeps failing
/// until they change).
async fn bind_until_ok(inner: &Inner) -> Endpoint {
    loop {
        inner.rebind.store(false, Ordering::SeqCst);
        match bind(inner).await {
            Ok(endpoint) => return endpoint,
            Err(err) => {
                inner.emit(ClientEvent::Disconnected {
                    reason: format!("binding endpoint: {err}"),
                });
                let _ = tokio::time::timeout(MAX_BACKOFF, inner.reconnect.notified()).await;
            }
        }
    }
}

fn route(inner: &Inner) -> Route {
    let network = lock(&inner.net);
    Route::new(network.0, &inner.relays, &network.1)
}

/// How to reach a daemon: what the client asks for (local only, its own relays) over what
/// the daemon's ticket says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Route {
    /// Direct addresses only: no relay, no address lookup.
    Direct,
    /// The default relay ([`brand::RELAY_URL`]) and the daemon's home relay.
    Default,
    /// Only these relays.
    Custom {
        urls: Vec<String>,
        auth_token: Option<String>,
        /// The client's own relays (`ConnectOptions::relay_urls`): the ticket's home relay
        /// is not dialled either.
        own: bool,
    },
}

impl Route {
    /// The client's `Disabled` wins (the app's local-only switch), then a local-only daemon,
    /// then the client's own relays, then the daemon's choice.
    pub(crate) fn new(
        mode: RelayMode,
        relays: &proto::TicketRelays,
        options: &crate::ConnectOptions,
    ) -> Self {
        use proto::TicketRelays;
        match (mode, relays) {
            (RelayMode::Disabled, _) | (_, TicketRelays::Disabled) => Self::Direct,
            _ if !options.relay_urls.is_empty() => Self::Custom {
                urls: options.relay_urls.clone(),
                auth_token: options.relay_auth_token.clone(),
                own: true,
            },
            (RelayMode::Default, TicketRelays::Default) => Self::Default,
            (RelayMode::Default, TicketRelays::Custom { urls, auth_token }) => Self::Custom {
                urls: urls.clone(),
                auth_token: auth_token.clone(),
                own: false,
            },
        }
    }
}

/// The product's own relay ([`brand::RELAY_URL`]), the default unless the app's relay settings or
/// the ticket name others.
fn default_relays() -> iroh::RelayMap {
    iroh::RelayMap::try_from_iter([brand::RELAY_URL])
        .expect("the default relay URL parses")
        .with_auth_token(brand::RELAY_TOKEN.to_owned())
}

/// An endpoint builder for dialling along `route`, trusting `options.relay_ca_der` too.
pub(crate) fn endpoint_builder(
    route: &Route,
    options: &crate::ConnectOptions,
) -> Result<iroh::endpoint::Builder, ConnError> {
    let mut builder = match route {
        Route::Direct => Endpoint::builder(presets::Minimal),
        Route::Default => {
            Endpoint::builder(presets::N0).relay_mode(iroh::RelayMode::Custom(default_relays()))
        }
        Route::Custom {
            urls,
            auth_token,
            own,
        } => {
            let whose = if *own { "relay settings" } else { "ticket" };
            let relay_map = iroh::RelayMap::try_from_iter(urls.iter().map(String::as_str))
                .map_err(|err| ConnError::Net(format!("relay urls in the {whose}: {err}")))?;
            let relay_map = match auth_token {
                Some(token) => relay_map.with_auth_token(token.clone()),
                None => relay_map,
            };
            Endpoint::builder(presets::Minimal).relay_mode(iroh::RelayMode::Custom(relay_map))
        }
    };
    let idle_timeout =
        iroh::endpoint::IdleTimeout::try_from(proto::IDLE_TIMEOUT).map_err(net_error)?;
    builder = builder.transport_config(
        iroh::endpoint::QuicTransportConfig::builder()
            .keep_alive_interval(proto::KEEP_ALIVE)
            .max_idle_timeout(Some(idle_timeout))
            .build(),
    );
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
    let ticket_address = ticket_addr(&inner.ticket, &route(inner))?;
    Ok(lock(&inner.last_direct_addresses)
        .iter()
        .fold(ticket_address, |address, &direct_address| {
            address.with_ip_addr(direct_address)
        }))
}

async fn remember_direct_addresses(inner: Arc<Inner>, connection: Connection) {
    use n0_future::StreamExt;
    let mut path_snapshots = connection.paths_stream();
    while let Some(paths) = path_snapshots.next().await {
        let direct_addresses: Vec<std::net::SocketAddr> = paths
            .iter()
            .filter_map(|path| match path.remote_addr() {
                iroh::TransportAddr::Ip(socket_address) => Some(*socket_address),
                _ => None,
            })
            .collect();
        if !direct_addresses.is_empty() {
            *lock(&inner.last_direct_addresses) = direct_addresses;
        }
    }
}

/// Where to dial the ticket's daemon: its direct addresses, plus the relays `route` allows
/// (the daemon's home relay, and for self-hosted relays the others it may move to).
pub(crate) fn ticket_addr(
    ticket: &proto::Ticket,
    route: &Route,
) -> Result<EndpointAddr, ConnError> {
    let endpoint_id = EndpointId::from_bytes(&ticket.daemon_id.0).map_err(net_error)?;
    let mut addr = EndpointAddr::new(endpoint_id);
    for ip_addr in &ticket.addrs {
        addr = addr.with_ip_addr(*ip_addr);
    }
    let home = ticket.relay_url.as_deref();
    let urls: Vec<&str> = match route {
        Route::Direct => vec![],
        Route::Default => home.into_iter().collect(),
        Route::Custom { urls, own, .. } => (!own)
            .then_some(home)
            .flatten()
            .into_iter()
            .chain(urls.iter().map(String::as_str))
            .collect(),
    };
    for url in urls {
        if let Ok(url) = RelayUrl::from_str(url) {
            addr = addr.with_relay_url(url);
        }
    }
    Ok(addr)
}

/// Keeps a connection up for the client's lifetime.
pub(crate) async fn supervise(inner: Arc<Inner>) {
    let mut endpoint = bind_until_ok(&inner).await;
    *lock(&inner.endpoint) = Some(endpoint.clone());
    let mut backoff = MIN_BACKOFF;
    let mut consecutive_timeouts = 0;
    loop {
        if *lock(&inner.paused) {
            inner.reconnect.notified().await;
            continue;
        }
        if inner.skips_backoff.swap(false, Ordering::SeqCst) {
            backoff = MIN_BACKOFF;
            consecutive_timeouts = 0;
        }
        if inner.rebind.load(Ordering::SeqCst) {
            endpoint.close().await;
            endpoint = bind_until_ok(&inner).await;
            *lock(&inner.endpoint) = Some(endpoint.clone());
        }
        let dial_deadline = DIAL_DEADLINES[consecutive_timeouts.min(DIAL_DEADLINES.len() - 1)];
        let result = match dial_within(&inner, &endpoint, dial_deadline).await {
            DialOutcome::Finished(result) => result,
            DialOutcome::Interrupted => continue,
            DialOutcome::TimedOut => {
                consecutive_timeouts += 1;
                inner.emit(ClientEvent::Disconnected {
                    reason: format!("no answer within {} s", dial_deadline.as_secs()),
                });
                endpoint.network_change().await;
                backoff = MIN_BACKOFF;
                continue;
            }
        };
        consecutive_timeouts = 0;
        match result {
            Ok(live) => {
                let connected_at = tokio::time::Instant::now();
                let reason = run(&inner, live).await;
                *lock(&inner.connection) = None;
                inner.ws.fail_pending();
                inner.mp.fail_pending();
                inner.art.fail_pending();
                inner.assist.fail_pending();
                inner.askpass.fail_pending();
                inner.approvals.fail_pending();
                forget_programs(&inner);
                inner.emit(ClientEvent::Disconnected { reason });
                if *lock(&inner.paused) {
                    continue;
                }
                if connected_at.elapsed() >= STABLE_FOR {
                    backoff = MIN_BACKOFF;
                    continue;
                }
            }
            Err(ConnError::Refused(reason)) => {
                inner.emit(ClientEvent::Refused {
                    reason: format!("{reason:?}"),
                });
                inner.reconnect.notified().await;
                continue;
            }
            Err(err) => {
                inner.emit(ClientEvent::Disconnected {
                    reason: err.to_string(),
                });
            }
        }
        let _ = tokio::time::timeout(backoff, inner.reconnect.notified()).await;
        backoff = (backoff * 2).min(MAX_BACKOFF);
    }
}

async fn dial_within(
    inner: &Arc<Inner>,
    endpoint: &Endpoint,
    dial_deadline: Duration,
) -> DialOutcome {
    inner.is_dialing.store(true, Ordering::SeqCst);
    // A redial asked for meanwhile starts over now: the daemon may have just come up where
    // this dial found nothing (the Mac app's own helper starting at launch).
    let outcome = tokio::select! {
        result = tokio::time::timeout(dial_deadline, connect_once(inner, endpoint)) => {
            result.map_or(DialOutcome::TimedOut, DialOutcome::Finished)
        }
        () = inner.reconnect.notified() => DialOutcome::Interrupted,
    };
    inner.is_dialing.store(false, Ordering::SeqCst);
    outcome
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
    let mut last_error = ConnError::Net("no grant tried".into());
    for &grant_version in grants {
        let conn = connect_daemon(endpoint, addr.clone())
            .await
            .map_err(net_error)?;
        match handshake(inner, conn, grant_version).await {
            Ok(live) => {
                *lock(&inner.paired) = true;
                return Ok(live);
            }
            // A removed device is refused as revoked, and may still pair again with a new
            // ticket's secret.
            Err(ConnError::Refused(
                reason @ (proto::RefuseReason::InvalidGrant | proto::RefuseReason::Revoked),
            )) => {
                last_error = ConnError::Refused(reason);
            }
            Err(err) => return Err(err),
        }
    }
    Err(last_error)
}

async fn handshake(
    inner: &Arc<Inner>,
    conn: Connection,
    grant_version: u16,
) -> Result<Live, ConnError> {
    let (mut ctl_tx, mut ctl_rx) = conn.open_bi().await.map_err(net_error)?;
    let _ = ctl_tx.set_priority(100);
    let (token, grant_id) = match (&inner.mp.invite, grant_version) {
        (Some(invite), SignedGrant::CHAIN) => (invite.chain.to_token(), invite.chain.grant_id()),
        (_, SignedGrant::PAIRING) => (inner.ticket.secret.0.to_vec(), proto::GrantId([0; 16])),
        _ => (Vec::new(), proto::GrantId([0; 16])),
    };
    let resume = resume_points(inner);
    let hello = Hello {
        device_id: device_id(&inner.config),
        principal_id: inner.ticket.principal,
        grant: SignedGrant {
            v: grant_version,
            grant_id,
            token,
        },
        snapshot_format: u32::from(ghostty_vt::snapshot_format()),
        resume,
        caps: Caps::ECHO_PREDICTION
            | Caps::ARTIFACTS
            | Caps::ATTACH_RESULT
            | Caps::DAEMON_INFO
            | Caps::AGENT_USAGE
            | Caps::APPROVAL_POLICY
            // Owner devices hear knocks; a guest dialling here never waits in the lobby (a
            // knock invite goes through `knock::knock` instead).
            | if crate::mp::is_guest(inner) {
                Caps::EMPTY
            } else {
                Caps::KNOCK
                    | Caps::DEVICE_ALERTS
                    | Caps::HOST_ALERTS
                    | Caps::DRIVE_ASKS
                    | Caps::ACCOUNTS
                    | Caps::ANSWER_ALERTS
            }
            | Caps::APPROVALS
            | Caps::WORKFLOWS
            | Caps::AGENT_TIMELINE
            | Caps::ACTIVE_SIZING
            | Caps::PANE_SIZING
            | Caps::PRESENCE
            | Caps::PROJECTS
            | Caps::FLOATS
            | Caps::TERMINAL_LIMITS
            | if crate::askpass::announces(&inner.options, crate::mp::is_guest(inner)) {
                Caps::ASKPASS | Caps::ASKPASS_DRIVER
            } else {
                Caps::EMPTY
            }
            | if crate::browser::announces(&inner.options, crate::mp::is_guest(inner)) {
                Caps::BROWSER
            } else {
                Caps::EMPTY
            }
            | if inner.options.program_status {
                Caps::PROGRAM_STATUS
            } else {
                Caps::EMPTY
            }
            | if inner.config.repo_status {
                Caps::REPO_STATUS
            } else {
                Caps::EMPTY
            }
            | if inner.options.clipboard {
                Caps::CLIPBOARD
            } else {
                Caps::EMPTY
            }
            | Caps::INPUT_RESUME
            | Caps::MORE_DAEMON_FEATURES
            | inner.options.extra_caps,
        link: *lock(&inner.link),
        resume_token: lock(&inner.resume_token).clone(),
    };
    send(&mut ctl_tx, &ClientCtl::Hello(hello)).await?;
    // Sent before the Welcome to save a round trip: every daemon that admits this Hello reads
    // them after it, and a refused connection drops them.
    for request in requests_every_daemon_reads(inner) {
        send(&mut ctl_tx, &request).await?;
    }
    // Daemons describe themselves before `Welcome` or `Refused` as far as the Hello's caps ask;
    // older ones answer straight away.
    let mut daemon_info = None;
    let mut more_daemon_features = proto::MoreDaemonFeatures::EMPTY;
    let mut image_storage_bytes = None;
    let first = loop {
        match recv::<ServerCtl>(&mut ctl_rx).await? {
            Some(ServerCtl::DaemonInfo(info)) => daemon_info = Some(info),
            Some(ServerCtl::MoreDaemonFeatures(features)) => more_daemon_features = features,
            Some(ServerCtl::TerminalLimits {
                image_storage_bytes: bytes,
            }) => image_storage_bytes = Some(bytes),
            other => break other,
        }
    };
    *lock(&inner.daemon_info) = daemon_info;
    *lock(&inner.more_daemon_features) = more_daemon_features;
    *lock(&inner.image_storage_bytes) = image_storage_bytes;
    let our_format = u32::from(ghostty_vt::snapshot_format());
    match first {
        Some(ServerCtl::Welcome(welcome)) => {
            let incompatible = welcome.snapshot_format != our_format;
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
    panes.sort_by_key(|&pane_id| Some(pane_id) != wanted.focus);
    panes
        .into_iter()
        .filter_map(|pane_id| {
            mirrors.get(&pane_id).map(|mirror| ResumePoint {
                pane_id,
                last_seq: Seq(mirror.seq()),
                snap_gen: mirror.snap_gen,
            })
        })
        .collect()
}

/// What the client wants, in requests any daemon decodes. Panes in the Hello's resume list are
/// already streaming.
fn requests_every_daemon_reads(inner: &Inner) -> Vec<ClientCtl> {
    let wanted = lock(&inner.wanted);
    let mut requests = Vec::new();
    if wanted.attach_requested {
        requests.push(ClientCtl::Attach {
            session_id: wanted.session,
        });
    }
    requests.push(ClientCtl::Visible {
        pane_ids: wanted.visible.clone(),
    });
    requests.push(ClientCtl::Focus {
        pane_id: wanted.focus,
    });
    for (&pane_id, &size) in &wanted.sizes {
        requests.push(ClientCtl::Resize { pane_id, size });
    }
    for &pane_id in &wanted.subscribed {
        requests.push(ClientCtl::Subscribe {
            pane_id,
            mode: proto::SubscribeMode::Live,
            rows_hint: 0,
        });
    }
    requests
}

fn requests_needing_features(inner: &Inner, features: proto::DaemonFeatures) -> Vec<ClientCtl> {
    let wanted = lock(&inner.wanted);
    let mut requests = Vec::new();
    if features.contains(proto::DaemonFeatures::ACTIVE_SIZING) {
        for (&pane_id, &activity) in &wanted.activities {
            requests.push(ClientCtl::PaneActivity { pane_id, activity });
        }
    }
    if let Some(colors) = &wanted.colors
        && features.contains(proto::DaemonFeatures::TERMINAL_COLORS)
    {
        requests.push(ClientCtl::TerminalColors(colors.clone()));
    }
    if lock(&inner.more_daemon_features).contains(proto::MoreDaemonFeatures::RUN_AGAIN) {
        requests.push(ClientCtl::WatchRunAgain);
    }
    requests
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
    let (resumed, same_run) = {
        let mut last_epoch = lock(&inner.epoch);
        let seen = (last_epoch.is_some(), *last_epoch == Some(epoch));
        *last_epoch = Some(epoch);
        seen
    };
    // Input is kept for sending again only for daemons that apply it once.
    let input_features = lock(&inner.daemon_info)
        .as_ref()
        .map_or(proto::DaemonFeatures::default(), |info| info.features);
    let resends = input_features.contains(proto::DaemonFeatures::INPUT_RESUME);
    lock(&inner.stats).connections += 1;
    inner.mp.reset_for_connection();
    // History requests in flight died with the previous connection.
    for mirror in lock(&inner.mirrors).values_mut() {
        mirror.history.in_flight = false;
    }
    *lock(&inner.connection) = Some(conn.clone());
    inner.emit(ClientEvent::Connected { epoch, resumed });

    let mut input = match conn.open_uni().await {
        Ok(stream) => stream,
        Err(err) => return err.to_string(),
    };
    let _ = input.set_priority(90);
    if let Err(err) = send(&mut input, &StreamHeader::Input).await {
        return err.to_string();
    }
    // What the last connection took but the daemon never confirmed: it may have died with it.
    let principal = inner.ticket.principal;
    let unconfirmed = lock(&inner.input).resend(resends && same_run);
    for sent in unconfirmed {
        let frame = ClientInput::Input(Input {
            pane_id: sent.pane_id,
            input_seq: InputSeq(sent.seq),
            principal,
            payload: compatible_input_payload(sent.payload, input_features),
        });
        if let Err(err) = send(&mut input, &frame).await {
            return err.to_string();
        }
    }

    for request in requests_needing_features(inner, input_features) {
        if let Err(err) = send(&mut ctl_tx, &request).await {
            return err.to_string();
        }
    }

    // Catch cached drawings up with what changed while away (queued behind the replay).
    inner.art.on_connected(inner);

    let (ctl_out, ctl_out_rx) = mpsc::unbounded_channel();
    let ack_notify = Arc::new(Notify::new());
    let mut tasks = JoinSet::new();
    tasks.spawn(write_ctl(Arc::clone(inner), ctl_tx, ctl_out_rx));
    tasks.spawn(read_ctl(Arc::clone(inner), ctl_rx));
    tasks.spawn(accept_panes(
        Arc::clone(inner),
        conn.clone(),
        Arc::clone(&ack_notify),
        ctl_out.clone(),
    ));
    tasks.spawn(send_acks(Arc::clone(inner), ack_notify, ctl_out.clone()));
    tasks.spawn(crate::peer::send_presence(
        Arc::clone(inner),
        ctl_out.clone(),
    ));

    let direct_address_watch =
        tokio::spawn(remember_direct_addresses(Arc::clone(inner), conn.clone()));
    let mut outgoing = inner.outgoing_rx.lock().await;
    let reason = loop {
        tokio::select! {
            msg = outgoing.recv() => {
                let Some(msg) = msg else { break "client dropped".to_owned() };
                match msg {
                    Outgoing::Ctl(ctl) => {
                        if control_supported(&ctl, input_features) && inner.ws.control_is_live(&ctl) { let _ = ctl_out.send(ctl); }
                    }
                    Outgoing::Input { pane_id, payload } => {
                        let input_seq = lock(&inner.input).send(pane_id, &payload, resends);
                        let payload = compatible_input_payload(payload, input_features);
                        let frame = ClientInput::Input(Input {
                            pane_id,
                            input_seq: InputSeq(input_seq),
                            principal,
                            payload,
                        });
                        // One write per keystroke frame: no batching delay.
                        if let Err(err) = send(&mut input, &frame).await {
                            break err.to_string();
                        }
                    }
                }
            }
            done = tasks.join_next() => {
                break match done {
                    Some(Ok(reason)) => reason,
                    Some(Err(err)) => err.to_string(),
                    None => "connection tasks ended".to_owned(),
                };
            }
            closed = conn.closed() => break closed.to_string(),
        }
    };
    tasks.abort_all();
    direct_address_watch.abort();
    conn.close(0u32.into(), b"");
    reason
}

fn control_supported(control: &ClientCtl, features: proto::DaemonFeatures) -> bool {
    match control {
        ClientCtl::Workspace {
            req: proto::WorkspaceRequest::TimelineWatchCapabilities { .. },
            ..
        } => features.contains(proto::DaemonFeatures::AGENT_CAPABILITIES),
        ClientCtl::Workspace {
            req:
                proto::WorkspaceRequest::ChatPrepare { .. } | proto::WorkspaceRequest::ChatSend { .. },
            ..
        } => features.contains(proto::DaemonFeatures::CHAT_SEND),
        ClientCtl::Workspace {
            req:
                proto::WorkspaceRequest::ChatInterruptPrepare { .. }
                | proto::WorkspaceRequest::ChatInterrupt { .. },
            ..
        } => features.contains(proto::DaemonFeatures::CHAT_INTERRUPT),
        ClientCtl::PaneActivity { .. }
        | ClientCtl::ClaimSize { .. }
        | ClientCtl::SetSizePolicy { .. } => {
            features.contains(proto::DaemonFeatures::ACTIVE_SIZING)
        }
        _ => true,
    }
}

fn compatible_input_payload(
    payload: InputPayload,
    features: proto::DaemonFeatures,
) -> InputPayload {
    match payload {
        InputPayload::GeneratedBytes(bytes)
            if !features.contains(proto::DaemonFeatures::GENERATED_INPUT) =>
        {
            InputPayload::Bytes(bytes)
        }
        payload => payload,
    }
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
    inner: Arc<Inner>,
    mut send_stream: SendStream,
    mut ctl_rx: mpsc::UnboundedReceiver<ClientCtl>,
) -> String {
    let mut batch = Vec::new();
    while let Some(msg) = ctl_rx.recv().await {
        batch.clear();
        let mut next = Some(msg);
        while let Some(msg) = next {
            if inner.ws.control_is_live(&msg)
                && let Err(err) = proto::frame::encode(&msg, &mut batch)
            {
                tracing::warn!("encoding ctl: {err}");
            }
            next = ctl_rx.try_recv().ok();
        }
        if let Err(err) = send_stream.write_all(&batch).await {
            return err.to_string();
        }
    }
    "ctl writer closed".into()
}

/// Pings the daemon on `conn` and closes `conn` if the answer does not come back in time
/// (see [`Client::probe`](crate::Client::probe)).
pub(crate) async fn probe(inner: Arc<Inner>, conn: Connection, deadlines: ProbeDeadlines) {
    let nonce = inner.next_ping.fetch_add(1, Ordering::Relaxed) + 1;
    let mut pongs = inner.pong.subscribe();
    let received = |conn: &Connection| conn.stats().udp_rx.datagrams;
    let before = received(&conn);
    inner.send(ClientCtl::Ping { nonce });
    let mut answered =
        std::pin::pin!(async move { pongs.wait_for(|&last| last >= nonce).await.is_ok() });
    let alive = match tokio::time::timeout(deadlines.silent_link, &mut answered).await {
        Ok(alive) => alive,
        Err(_) if received(&conn) > before => {
            tokio::time::timeout(deadlines.busy_link - deadlines.silent_link, answered)
                .await
                .unwrap_or(false)
        }
        Err(_) => false,
    };
    let current = lock(&inner.connection)
        .as_ref()
        .is_some_and(|live| live.stable_id() == conn.stable_id());
    if !alive && current && conn.close_reason().is_none() {
        tracing::info!("no answer to a ping: dropping the connection");
        conn.close(0u32.into(), b"no answer");
    }
}

async fn read_ctl(inner: Arc<Inner>, mut ctl_rx: RecvStream) -> String {
    loop {
        let msg = match recv::<ServerCtl>(&mut ctl_rx).await {
            Ok(Some(msg)) => msg,
            Ok(None) => return "daemon closed ctl".into(),
            Err(err) => return err.to_string(),
        };
        if let ServerCtl::InputRejected { input_seq, .. } = &msg {
            lock(&inner.input).confirm(input_seq.0);
        }
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
        let askpass = crate::askpass::announces(&inner.options, crate::mp::is_guest(&inner))
            || inner.options.extra_caps.contains(Caps::ASKPASS);
        let Some(msg) = inner.askpass.dispatch(msg, askpass) else {
            continue;
        };
        let browser = crate::browser::announces(&inner.options, crate::mp::is_guest(&inner));
        let Some(msg) = inner.browser.dispatch(msg, browser) else {
            continue;
        };
        let Some(msg) = inner.approvals.dispatch(msg) else {
            continue;
        };
        let event = match msg {
            ServerCtl::Pong { nonce } => {
                inner.pong.send_if_modified(|last| {
                    let newer = nonce > *last;
                    *last = (*last).max(nonce);
                    newer
                });
                continue;
            }
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
            ServerCtl::PaneSizing(state) => ClientEvent::PaneSizing { state },
            ServerCtl::ProgramStatus { pane_id, status } => {
                let mut programs = lock(&inner.programs);
                match &status {
                    Some(report) => programs.insert(pane_id, report.clone()),
                    None => programs.remove(&pane_id),
                };
                drop(programs);
                ClientEvent::ProgramStatus { pane_id, status }
            }
            ServerCtl::Projects(projects) => ClientEvent::Projects { projects },
            ServerCtl::Floats(floats) => ClientEvent::Floats { floats },
            ServerCtl::RunAgainOffers(offers) => ClientEvent::RunAgainOffers { offers },
            // Only what this connection asked for; a daemon is not trusted to honour it.
            ServerCtl::Clipboard { pane_id, text } if inner.options.clipboard => {
                ClientEvent::Clipboard { pane_id, text }
            }
            ServerCtl::PaneClosed { pane_id } => {
                lock(&inner.mirrors).remove(&pane_id);
                lock(&inner.pane_output_turns).remove(&pane_id);
                lock(&inner.programs).remove(&pane_id);
                lock(&inner.wanted).subscribed.retain(|&id| id != pane_id);
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

/// The connection dropped: reports may change unseen until the daemon sends them again.
fn forget_programs(inner: &Inner) {
    let panes: Vec<PaneId> = lock(&inner.programs)
        .drain()
        .map(|(pane_id, _)| pane_id)
        .collect();
    for pane_id in panes {
        inner.emit(ClientEvent::ProgramStatus {
            pane_id,
            status: None,
        });
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
            Ok(stream) => stream,
            Err(err) => return err.to_string(),
        };
        let inner = Arc::clone(&inner);
        let acks = Arc::clone(&acks);
        let ctl = ctl.clone();
        tokio::spawn(async move {
            match recv(&mut stream).await {
                Ok(Some(StreamHeader::Pane { pane_id })) => {
                    inner.emit(ClientEvent::PaneStreaming { pane_id });
                    while let Ok(Some(output)) = recv::<PaneOutput>(&mut stream).await {
                        apply_output(&inner, pane_id, output, &ctl);
                        acks.notify_one();
                        // A flooding stream always has the next frame ready, so its reads
                        // never yield: let other panes' output and the input writer run
                        // between frames, as the listener's terminal work is slow.
                        tokio::task::yield_now().await;
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
    output: PaneOutput,
    ctl: &mpsc::UnboundedSender<ClientCtl>,
) {
    let turn = inner.pane_output_turn(pane_id);
    let _turn = lock(&turn);
    let keep_vt = inner.config.mirror_vt;
    let event = match output {
        PaneOutput::Bytes { seq, data } => {
            lock(&inner.stats).byte_frames += 1;
            let mut mirrors = lock(&inner.mirrors);
            // No mirror: the pane is not followed (any more). Output that was in flight when
            // it was unsubscribed or closed is dropped, never a reason to follow it again.
            let Some(mirror) = mirrors.get_mut(&pane_id) else {
                return;
            };
            let applied = mirror.apply(seq.0, &data);
            if applied == Applied::Gap {
                // Start over from a snapshot, once: the frames still in flight behind this
                // one find no mirror and are dropped.
                mirrors.remove(&pane_id);
            }
            drop(mirrors);
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
        } => match inflate(&data, raw_len) {
            Ok(raw) => match snapshot_event(inner, pane_id, seq, snap_gen, raw, keep_vt) {
                Some(event) => event,
                None => return,
            },
            Err(err) => {
                tracing::warn!(%pane_id, "bad snapshot: {err}");
                return;
            }
        },
        PaneOutput::Snapshot {
            seq,
            snap_gen,
            data,
        } => match snapshot_event(inner, pane_id, seq, snap_gen, data, keep_vt) {
            Some(event) => event,
            None => return,
        },
        PaneOutput::Resized { seq, size } => {
            let mut mirrors = lock(&inner.mirrors);
            // Only a resize at or after the screen belongs to it: anything older is from a
            // stream this pane was followed on before, and the screen already includes it.
            let Some(mirror) = mirrors
                .get_mut(&pane_id)
                .filter(|mirror| seq.0 >= mirror.seq())
            else {
                return;
            };
            mirror.resize(size);
            drop(mirrors);
            ClientEvent::PaneResized {
                pane_id,
                seq: seq.0,
                size,
            }
        }
        PaneOutput::InputAck { input_seq, at_seq } => {
            lock(&inner.input).confirm(input_seq.0);
            ClientEvent::InputAck {
                pane_id,
                input_seq: input_seq.0,
                at_seq: at_seq.0,
            }
        }
    };
    inner.emit(event);
}

/// The most a snapshot or history page may inflate to. Far above any real one (a READY
/// section is a few hundred KB, a page at most 2 MiB), far below what a phone can spare.
const MAX_INFLATED: u32 = 64 << 20;

/// Decompresses one zstd frame the daemon says inflates to `raw_len` bytes. A guest dials
/// other people's daemons, so a length (and a bomb) from one is refused past
/// [`MAX_INFLATED`] rather than allocated.
fn inflate(data: &[u8], raw_len: u32) -> std::io::Result<Vec<u8>> {
    if raw_len > MAX_INFLATED {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("{raw_len} bytes decompressed is over the {MAX_INFLATED} limit"),
        ));
    }
    zstd::bulk::decompress(data, raw_len as usize)
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
            let records = match inflate(&data, raw_len) {
                Ok(records) => records,
                Err(err) => {
                    tracing::warn!(%pane_id, "bad history page: {err}");
                    return;
                }
            };
            let applied = lock(&inner.mirrors).get_mut(&pane_id).and_then(|mirror| {
                mirror.apply_history(snapshot_seq.0, offset, next_offset, done, &records)
            });
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
            if let Some(mirror) = lock(&inner.mirrors).get_mut(&pane_id)
                && mirror.history.snapshot_seq == snapshot_seq.0
            {
                mirror.history.in_flight = false;
                mirror.history.done = true;
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
) -> Option<ClientEvent> {
    lock(&inner.stats).snapshots += 1;
    // A snapshot that was in flight when the pane was unsubscribed starts nothing.
    if !lock(&inner.wanted).subscribed.contains(&pane_id) {
        return None;
    }
    let image_storage = crate::image_storage_limit(*lock(&inner.image_storage_bytes));
    let mirror = Mirror::from_snapshot(snap_gen, seq.0, &raw, keep_vt, image_storage);
    let mut mirrors = lock(&inner.mirrors);
    // Following a pane again opens a new stream while the old one drains, and the two are not
    // ordered: an older snapshot arriving last must not take the screen back.
    if mirrors
        .get(&pane_id)
        .is_some_and(|shown| shown.is_ahead_of(snap_gen, seq.0))
    {
        tracing::debug!(%pane_id, seq = seq.0, "dropping a snapshot older than the screen");
        return None;
    }
    mirrors.insert(pane_id, mirror);
    drop(mirrors);
    Some(ClientEvent::PaneSnapshot {
        pane_id,
        seq: seq.0,
        data: raw,
    })
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
            .filter(|(_, mirror)| mirror.seq() > mirror.acked)
            .map(|(&pane_id, mirror)| {
                mirror.acked = mirror.seq();
                (pane_id, mirror.seq())
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
        Ok(listener) => listener,
        Err(err) => {
            tracing::warn!("port forward listener: {err}");
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
            if let Err(err) = forward_one(&inner, tcp, remote_port).await {
                tracing::debug!("port forward: {err}");
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
        if let Some(conn) = lock(&inner.connection).clone() {
            break conn;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let (mut send_stream, mut recv_stream) = conn.open_bi().await.map_err(net_error)?;
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
        let copied = tokio::io::copy(&mut tcp_read, &mut send_stream).await;
        let _ = send_stream.finish();
        copied
    };
    let down = async {
        let copied = tokio::io::copy(&mut recv_stream, &mut tcp_write).await;
        let _ = tcp_write.shutdown().await;
        copied
    };
    let _ = tokio::join!(up, down);
    Ok(())
}

#[cfg(test)]
mod tests {
    use proto::TicketRelays;

    use super::*;
    use crate::ConnectOptions;

    #[test]
    fn old_daemons_are_not_sent_activity_claims_or_unknown_policies() {
        for control in [
            ClientCtl::PaneActivity {
                pane_id: PaneId(1),
                activity: proto::PaneActivity::Active,
            },
            ClientCtl::ClaimSize { pane_id: PaneId(1) },
            ClientCtl::SetSizePolicy {
                pane_id: PaneId(1),
                policy: proto::SizePolicy::LastActive,
            },
        ] {
            assert!(!control_supported(
                &control,
                proto::DaemonFeatures::default()
            ));
            assert!(control_supported(
                &control,
                proto::DaemonFeatures::ACTIVE_SIZING
            ));
        }
        assert!(control_supported(
            &ClientCtl::Ping { nonce: 1 },
            proto::DaemonFeatures::default()
        ));
    }

    #[test]
    fn a_reconnect_to_a_legacy_daemon_cannot_receive_queued_chat_variants() {
        for req in [
            proto::WorkspaceRequest::ChatPrepare { pane_id: PaneId(7) },
            proto::WorkspaceRequest::ChatSend {
                pane_id: PaneId(7),
                ticket: 1,
                text: "hello".into(),
                confirmed_revision: None,
            },
        ] {
            let control = ClientCtl::Workspace { req_id: 1, req };
            assert!(!control_supported(
                &control,
                proto::DaemonFeatures::default()
            ));
            assert!(control_supported(
                &control,
                proto::DaemonFeatures::CHAT_SEND
            ));
        }
    }

    #[test]
    fn queued_interrupts_require_the_current_peers_interrupt_capability_not_just_send() {
        for req in [
            proto::WorkspaceRequest::ChatInterruptPrepare { pane_id: PaneId(7) },
            proto::WorkspaceRequest::ChatInterrupt {
                pane_id: PaneId(7),
                ticket: 1,
                confirmed_revision: None,
            },
        ] {
            let control = ClientCtl::Workspace { req_id: 1, req };
            assert!(!control_supported(
                &control,
                proto::DaemonFeatures::default()
            ));
            assert!(!control_supported(
                &control,
                proto::DaemonFeatures::CHAT_SEND
            ));
            assert!(control_supported(
                &control,
                proto::DaemonFeatures::CHAT_INTERRUPT
            ));
        }
    }

    #[test]
    fn queued_metadata_watches_require_the_current_link_capability() {
        let control = ClientCtl::Workspace {
            req_id: 1,
            req: proto::WorkspaceRequest::TimelineWatchCapabilities {
                pane_id: PaneId(7),
                version: 1,
            },
        };
        assert!(!control_supported(
            &control,
            proto::DaemonFeatures::AGENT_TIMELINE | proto::DaemonFeatures::VERSIONED_TIMELINE
        ));
        assert!(control_supported(
            &control,
            proto::DaemonFeatures::AGENT_CAPABILITIES
        ));
    }

    #[test]
    fn generated_reports_use_legacy_bytes_only_when_the_daemon_needs_them() {
        let bytes = vec![0x1b, 0x5b, 0x49];
        assert_eq!(
            compatible_input_payload(
                InputPayload::GeneratedBytes(bytes.clone()),
                proto::DaemonFeatures::default()
            ),
            InputPayload::Bytes(bytes.clone())
        );
        assert_eq!(
            compatible_input_payload(
                InputPayload::GeneratedBytes(bytes.clone()),
                proto::DaemonFeatures::GENERATED_INPUT
            ),
            InputPayload::GeneratedBytes(bytes.clone())
        );
        assert_eq!(
            compatible_input_payload(
                InputPayload::Bytes(bytes.clone()),
                proto::DaemonFeatures::GENERATED_INPUT
            ),
            InputPayload::Bytes(bytes)
        );
    }

    /// A small frame that inflates to more than the limit is refused, whatever length it
    /// claims, and an honest one still decodes.
    #[test]
    fn inflating_is_bounded() {
        let bomb = zstd::bulk::compress(&vec![0u8; (MAX_INFLATED as usize) + 1], 3).unwrap();
        assert!(bomb.len() < 64 << 10);
        assert!(inflate(&bomb, MAX_INFLATED + 1).is_err());
        assert!(inflate(&bomb, u32::MAX).is_err());
        assert!(inflate(&bomb, MAX_INFLATED).is_err());
        let small = zstd::bulk::compress(b"hello", 3).unwrap();
        assert_eq!(inflate(&small, 5).unwrap(), b"hello");
    }

    const HOME: &str = "https://home.example.net/";
    const OWN: &str = "https://relay.example.com/";

    fn ticket() -> proto::Ticket {
        proto::Ticket {
            v: proto::Ticket::VERSION,
            daemon_id: proto::DaemonId(*iroh::SecretKey::from_bytes(&[7; 32]).public().as_bytes()),
            addrs: vec!["192.0.2.20:47011".parse().unwrap()],
            relay_url: Some(HOME.into()),
            principal: proto::PrincipalId([1; 16]),
            secret: proto::PairingSecret([2; 16]),
            expires: proto::UnixMillis(0),
        }
    }

    fn own_relays() -> ConnectOptions {
        ConnectOptions {
            relay_urls: vec![OWN.into()],
            relay_auth_token: Some("token".into()),
            ..ConnectOptions::default()
        }
    }

    fn relays(route: &Route) -> Vec<String> {
        let addr = ticket_addr(&ticket(), route).unwrap();
        assert_eq!(
            addr.ip_addrs().count(),
            1,
            "direct addresses are always dialled"
        );
        addr.relay_urls().map(ToString::to_string).collect()
    }

    #[test]
    fn local_only_wins_over_everything() {
        let custom = TicketRelays::Custom {
            urls: vec![HOME.into()],
            auth_token: None,
        };
        for relays in [TicketRelays::Default, custom, TicketRelays::Disabled] {
            assert_eq!(
                Route::new(RelayMode::Disabled, &relays, &own_relays()),
                Route::Direct
            );
        }
        // A local-only daemon is on no relay: the device's own relays cannot reach it.
        assert_eq!(
            Route::new(RelayMode::Default, &TicketRelays::Disabled, &own_relays()),
            Route::Direct
        );
        assert!(relays(&Route::Direct).is_empty());
    }

    #[test]
    fn the_devices_own_relays_replace_the_tickets() {
        let route = Route::new(RelayMode::Default, &TicketRelays::Default, &own_relays());
        assert_eq!(
            route,
            Route::Custom {
                urls: vec![OWN.into()],
                auth_token: Some("token".into()),
                own: true
            }
        );
        // Only the device's relay, not the daemon's home relay.
        assert_eq!(relays(&route), vec![OWN.to_string()]);
        assert!(endpoint_builder(&route, &own_relays()).is_ok());
    }

    #[test]
    fn otherwise_the_ticket_decides() {
        let none = ConnectOptions::default();
        let route = Route::new(RelayMode::Default, &TicketRelays::Default, &none);
        assert_eq!(route, Route::Default);
        assert_eq!(relays(&route), vec![HOME.to_string()]);
        let custom = TicketRelays::Custom {
            urls: vec![OWN.into()],
            auth_token: None,
        };
        let route = Route::new(RelayMode::Default, &custom, &none);
        assert!(matches!(route, Route::Custom { own: false, .. }));
        assert_eq!(relays(&route), vec![HOME.to_string(), OWN.to_string()]);
    }

    #[test]
    fn a_bad_relay_url_is_an_error_not_a_panic() {
        let options = ConnectOptions {
            relay_urls: vec!["not a url".into()],
            ..ConnectOptions::default()
        };
        let route = Route::new(RelayMode::Default, &TicketRelays::Default, &options);
        let Err(err) = endpoint_builder(&route, &options) else {
            panic!("a bad relay url is rejected");
        };
        assert!(err.to_string().contains("relay settings"), "{err}");
    }

    struct Followed {
        client: crate::Client,
        events: mpsc::UnboundedReceiver<ClientEvent>,
        ctl: mpsc::UnboundedSender<ClientCtl>,
        pane_id: PaneId,
    }

    impl Followed {
        /// A client following one pane of a daemon it never reaches, so each test decides
        /// exactly which frames arrive and in what order.
        fn new() -> Self {
            let (listener, events) = crate::EventQueue::channel();
            let mut config = crate::ClientConfig::new(crate::ClientConfig::generate_key());
            config.relay = RelayMode::Disabled;
            let client = crate::Client::connect(&ticket().to_string(), config, listener).unwrap();
            let pane_id = PaneId(4);
            client.subscribe(pane_id);
            let (ctl, _) = mpsc::unbounded_channel();
            Self {
                client,
                events,
                ctl,
                pane_id,
            }
        }

        fn arrives(&self, output: PaneOutput) {
            apply_output(&self.client.inner, self.pane_id, output, &self.ctl);
        }

        fn snapshot(&self, seq: u64) {
            self.arrives(PaneOutput::Snapshot {
                seq: Seq(seq),
                snap_gen: proto::SnapGen(3),
                data: vec![],
            });
        }

        fn shown(&mut self) -> Vec<ClientEvent> {
            std::iter::from_fn(|| self.events.try_recv().ok())
                .filter(|event| {
                    matches!(
                        event,
                        ClientEvent::PaneSnapshot { .. }
                            | ClientEvent::PaneBytes { .. }
                            | ClientEvent::PaneResized { .. }
                    )
                })
                .collect()
        }
    }

    #[test]
    fn a_snapshot_older_than_the_screen_is_dropped() {
        let mut followed = Followed::new();
        followed.snapshot(2000);
        followed.arrives(PaneOutput::Bytes {
            seq: Seq(2000),
            data: b"newer".to_vec(),
        });
        followed.snapshot(1000);
        followed.arrives(PaneOutput::Bytes {
            seq: Seq(2005),
            data: b" still".to_vec(),
        });
        let shown = followed.shown();
        assert!(
            matches!(
                shown.as_slice(),
                [
                    ClientEvent::PaneSnapshot { seq: 2000, .. },
                    ClientEvent::PaneBytes { seq: 2000, .. },
                    ClientEvent::PaneBytes { seq: 2005, .. },
                ]
            ),
            "{shown:?}"
        );
    }

    #[test]
    fn a_snapshot_from_a_new_terminal_generation_replaces_the_screen() {
        let mut followed = Followed::new();
        followed.snapshot(2000);
        followed.arrives(PaneOutput::Snapshot {
            seq: Seq(10),
            snap_gen: proto::SnapGen(4),
            data: vec![],
        });
        let shown = followed.shown();
        assert!(
            matches!(
                shown.as_slice(),
                [
                    ClientEvent::PaneSnapshot { seq: 2000, .. },
                    ClientEvent::PaneSnapshot { seq: 10, .. },
                ]
            ),
            "{shown:?}"
        );
    }

    #[test]
    fn a_resize_older_than_the_screen_or_for_no_screen_is_dropped() {
        let mut followed = Followed::new();
        let size = |cols| proto::PaneSize {
            cols,
            rows: 24,
            width_px: 0,
            height_px: 0,
        };
        followed.arrives(PaneOutput::Resized {
            seq: Seq(500),
            size: size(80),
        });
        followed.snapshot(2000);
        followed.arrives(PaneOutput::Resized {
            seq: Seq(1500),
            size: size(100),
        });
        followed.arrives(PaneOutput::Resized {
            seq: Seq(2000),
            size: size(120),
        });
        let shown = followed.shown();
        assert!(
            matches!(
                shown.as_slice(),
                [
                    ClientEvent::PaneSnapshot { seq: 2000, .. },
                    ClientEvent::PaneResized { seq: 2000, .. },
                ]
            ),
            "{shown:?}"
        );
    }

    /// Holds the first snapshot inside the app's listener until told to let it go.
    struct StallsFirstSnapshot {
        stalled: std::sync::Mutex<bool>,
        release: std::sync::Mutex<std::sync::mpsc::Receiver<()>>,
        shown: std::sync::Mutex<Vec<u64>>,
    }

    impl crate::ClientListener for StallsFirstSnapshot {
        fn on_event(&self, event: ClientEvent) {
            let ClientEvent::PaneSnapshot { seq, .. } = event else {
                return;
            };
            let first = !std::mem::replace(&mut *self.stalled.lock().unwrap(), true);
            if first {
                let _ = self.release.lock().unwrap().recv();
            }
            self.shown.lock().unwrap().push(seq);
        }
    }

    #[test]
    fn a_snapshot_still_being_shown_is_not_overtaken_by_a_newer_one() {
        let (release, released) = std::sync::mpsc::channel();
        let listener = Arc::new(StallsFirstSnapshot {
            stalled: std::sync::Mutex::new(false),
            release: std::sync::Mutex::new(released),
            shown: std::sync::Mutex::new(vec![]),
        });
        let mut config = crate::ClientConfig::new(crate::ClientConfig::generate_key());
        config.relay = RelayMode::Disabled;
        let client =
            crate::Client::connect(&ticket().to_string(), config, listener.clone()).unwrap();
        let pane_id = PaneId(4);
        client.subscribe(pane_id);
        let snapshot = |seq| PaneOutput::Snapshot {
            seq: Seq(seq),
            snap_gen: proto::SnapGen(3),
            data: vec![],
        };
        let (ctl, _) = mpsc::unbounded_channel();
        std::thread::scope(|scope| {
            let earlier =
                scope.spawn(|| apply_output(&client.inner, pane_id, snapshot(1000), &ctl));
            std::thread::sleep(Duration::from_millis(50));
            let newer = scope.spawn(|| apply_output(&client.inner, pane_id, snapshot(2000), &ctl));
            std::thread::sleep(Duration::from_millis(100));
            release.send(()).unwrap();
            earlier.join().unwrap();
            newer.join().unwrap();
        });
        assert_eq!(*listener.shown.lock().unwrap(), [1000, 2000]);
    }
}
