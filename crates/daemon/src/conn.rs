//! One client connection: the handshake, `ctl`, `input`, pane streams and port forwards.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use iroh::endpoint::{Connection, RecvStream, SendStream};
use proto::{
    Actor, ArtifactError, ArtifactEvent, ArtifactInfo, ArtifactRequest, ArtifactResponse,
    AttachFailure, AttachVia, Attachment, AuditKind, BlobHeader, BlobReply, Bulk, Caps, ClientCtl,
    ClientInput, DaemonFeatures, DeviceId, ForwardReply, Hello, InputPayload, InputRejectReason,
    LeaseRequestKind, MpError, MpRequest, MpResponse, PaneId, PaneLaunch, PaneSize, RefuseReason,
    ResumePoint, RpcError, Scope, Seq, ServerCtl, SessionId, SignedGrant, StreamHeader,
    SubscribeMode, TransferReply, WIRE_VERSION, Welcome, WorkspaceRequest, WorkspaceResponse,
    WsError,
};
use tokio::sync::{broadcast, mpsc, watch};
use tokio::task::{AbortHandle, JoinSet};

use crate::core::{ConnId, Core, Event, View, lock};
use crate::forward;
use crate::mp::{Authz, Knocker, Mailbox, Need, Redeemed, Target, policy};
use crate::net::{self, NetError};
use crate::stream::{Class, PaneStream, Start, StreamCmd, priority};
use crate::ws::Viewer;

fn pane_metadata_for_client(core: &Core, pane: PaneId, caps: Caps) -> Option<proto::PaneMeta> {
    let mut meta = core.pane_meta(pane)?;
    meta.size_policy = meta.size_policy.for_client(caps);
    Some(meta)
}

struct Subscription {
    acks: watch::Sender<Seq>,
    cmds: mpsc::UnboundedSender<StreamCmd>,
    task: AbortHandle,
}

#[derive(Default)]
struct ConnState {
    session: Option<SessionId>,
    focus: Option<PaneId>,
    visible: Vec<PaneId>,
    sizes: HashMap<PaneId, PaneSize>,
    subscriptions: HashMap<PaneId, Subscription>,
    resume: HashMap<PaneId, ResumePoint>,
    /// The metadata last sent per pane: most changes the core announces (agent events, a
    /// title set again) leave what this client sees as it was.
    sent_meta: HashMap<PaneId, proto::PaneMeta>,
    sent_sizing: HashMap<PaneId, proto::PaneSizing>,
    /// Sent `ClientCtl::WatchRunAgain`, so it reads `ServerCtl::RunAgainOffers`.
    watches_run_again: bool,
}

impl ConnState {
    fn class(&self, pane: PaneId) -> Class {
        if self.focus == Some(pane) {
            Class::Focused
        } else if self.visible.contains(&pane) {
            Class::Visible
        } else {
            Class::Background
        }
    }
}

struct Client {
    id: ConnId,
    core: Arc<Core>,
    conn: Connection,
    actor: Actor,
    /// Roles and scope, fixed at the handshake; re-validated on every message.
    authz: Authz,
    caps: Caps,
    /// What the client said about its network (Low Data Mode is `Constrained`).
    link: proto::LinkClass,
    /// The input stream this connection continues, for clients that resend input after a
    /// reconnect (`Caps::INPUT_RESUME`).
    input_stream: Option<u64>,
    ctl: mpsc::UnboundedSender<ServerCtl>,
    state: Mutex<ConnState>,
    /// Opened on first use.
    bulk: tokio::sync::Mutex<Option<SendStream>>,
    /// Directory watches and the push channel for workspace requests.
    ws: crate::ws::ConnCtx,
    /// Live presence waiting for the `ctl` writer (clients with `Caps::PRESENCE`).
    peers: Option<Arc<Mailbox>>,
}

/// Serves one accepted connection until it closes. `pending` is its slot among the
/// connections not yet past the `Hello`; it is released once the `Hello` is in.
pub(crate) async fn serve(core: Arc<Core>, connection: Connection, pending: crate::preauth::Slot) {
    let remote = connection.remote_id();
    match run(core, connection, pending).await {
        Ok(()) => tracing::debug!(%remote, "client left"),
        Err(error) => tracing::debug!(%remote, "client connection ended: {error}"),
    }
}

/// The connection's `ctl` stream and its `Hello`; `None` if it sent something else, left, or
/// took longer than `timeout`.
async fn await_hello(
    conn: &Connection,
    timeout: Duration,
) -> Result<Option<(SendStream, RecvStream, Hello)>, NetError> {
    let hello = async {
        let (ctl_tx, mut ctl_rx) = conn.accept_bi().await.map_err(conn_err)?;
        let hello = match net::recv(&mut ctl_rx).await? {
            Some(ClientCtl::Hello(hello)) => Some(hello),
            _ => None,
        };
        Ok(hello.map(|hello| (ctl_tx, ctl_rx, hello)))
    };
    match tokio::time::timeout(timeout, hello).await {
        Ok(result) => result,
        Err(_) => {
            conn.close(0u32.into(), b"no hello");
            Ok(None)
        }
    }
}

async fn run(
    core: Arc<Core>,
    conn: Connection,
    pending: crate::preauth::Slot,
) -> Result<(), NetError> {
    let Some((mut ctl_tx, ctl_rx, hello)) = await_hello(&conn, core.cfg.hello_timeout).await?
    else {
        return Ok(());
    };
    let _ = ctl_tx.set_priority(priority::CTL);
    let device = DeviceId(*conn.remote_id().as_bytes());
    let handshake = handshake(&core, &hello, device);
    // A refused peer keeps its pre-`Hello` slot until it is gone, and spends its budget.
    let _pending = match &handshake {
        Ok(_) => {
            drop(pending);
            None
        }
        Err(_) => {
            pending.refused(device.0);
            Some(pending)
        }
    };
    if hello.caps.contains(Caps::DAEMON_INFO) {
        let mut info = daemon_info(&core);
        if !matches!(handshake, Ok(Admission::Join(..))) {
            // A refused peer learns what explains the refusal (versions), not which
            // machine or build this is.
            info.hostname.clear();
            info.os_name.clear();
            info.build.clear();
            info.built_unix = 0;
        }
        net::send(&mut ctl_tx, &ServerCtl::DaemonInfo(info)).await?;
    }
    if hello.caps.contains(Caps::MORE_DAEMON_FEATURES)
        && matches!(handshake, Ok(Admission::Join(..)))
    {
        let more = ServerCtl::MoreDaemonFeatures(more_daemon_features());
        net::send(&mut ctl_tx, &more).await?;
    }
    if hello.caps.contains(Caps::TERMINAL_LIMITS) && matches!(handshake, Ok(Admission::Join(..))) {
        let limits = ServerCtl::TerminalLimits {
            image_storage_bytes: core.cfg.image_storage_bytes,
        };
        net::send(&mut ctl_tx, &limits).await?;
    }
    let (authz, maintenance) = match handshake {
        Ok(Admission::Join(authz, maintenance)) => (authz, maintenance),
        Ok(Admission::Knock(knocker)) => {
            return serve_knock(core, conn, ctl_tx, ctl_rx, knocker).await;
        }
        Err(reason) => {
            net::send(&mut ctl_tx, &ServerCtl::Refused { reason }).await?;
            let _ = ctl_tx.finish();
            let _ = tokio::time::timeout(core.cfg.hello_timeout, ctl_tx.stopped()).await;
            return Ok(());
        }
    };

    let input_stream = core.inputs.stream(core.epoch, hello.resume_token.as_ref());
    let welcome = Welcome {
        daemon_id: core.identity.daemon_id(),
        session_epoch: core.epoch,
        roles: authz.roles,
        snapshot_format: core.cfg.snapshot_format(),
        panes: if maintenance {
            Vec::new()
        } else {
            core.pane_entries()
                .into_iter()
                .filter(|(id, _)| core.scope_within(Scope::Pane(*id), authz.scope))
                .filter_map(|(id, _)| pane_metadata_for_client(&core, id, hello.caps))
                .collect()
        },
        resume_token: crate::resume::InputStreams::token(core.epoch, input_stream),
    };
    net::send(&mut ctl_tx, &ServerCtl::Welcome(welcome)).await?;
    if maintenance {
        return serve_upgrade_only(core, conn, authz.actor, ctl_rx).await;
    }

    let (ctl, ctl_out) = mpsc::unbounded_channel();
    let owner = is_owner(&core, &authz);
    let ws = crate::ws::ConnCtx {
        ctl: ctl.clone(),
        watches: Arc::default(),
        timeline_watches: Arc::default(),
        timeline_mailbox: Arc::default(),
        timeline_since: (!owner && authz.history == proto::History::SinceJoin)
            .then_some(authz.joined_at),
        actor: authz.actor,
        caps: hello.caps,
        owner,
        viewer: if owner {
            Viewer::Owner
        } else {
            Viewer::Guest(authz.actor.principal)
        },
        scope: authz.scope,
    };
    let id = core.next_conn_id();
    let _ = ctl.send(ServerCtl::Joined(authz.join_info(&authz.name)));
    if hello.caps.contains(Caps::KNOCK) && is_owner(&core, &authz) {
        for knock in core.mp.knocks() {
            let _ = ctl.send(ServerCtl::Knock(proto::KnockUpdate::Added(knock)));
        }
    }
    if hello.caps.contains(Caps::HOST_ALERTS)
        && is_owner(&core, &authz)
        && let Some(alert) = core.mp.host_alert()
    {
        let _ = ctl.send(ServerCtl::HostAlert(alert));
    }
    let presence = hello.caps.contains(Caps::PRESENCE);
    core.mp
        .join(&core, id, &authz, presence, ctl.clone(), conn.clone());
    if authz.history == proto::History::SinceJoin {
        open_views(&core, &authz).await;
    }
    let client = Arc::new(Client {
        id,
        core: Arc::clone(&core),
        conn: conn.clone(),
        actor: authz.actor,
        authz,
        caps: hello.caps,
        link: hello.link,
        input_stream: hello
            .caps
            .contains(Caps::INPUT_RESUME)
            .then_some(input_stream),
        ctl,
        state: Mutex::new(ConnState::default()),
        bulk: tokio::sync::Mutex::new(None),
        ws,
        peers: presence.then(Arc::default),
    });
    core.client_connected(true);
    core.device_connected(device, client.id, conn.clone());
    // Only the apps announce BROWSER; a CLI connection never opens an editor.
    if owner && hello.caps.contains(Caps::BROWSER) {
        core.ws.editors.want_prewarm();
    }
    core.askpass.register(client.id, &client.authz, client.caps);
    core.browser.register(client.id, &client.authz, client.caps);
    client.approvals_state();
    client.program_state();
    let repo_watch = client.caps.contains(Caps::REPO_STATUS);
    if repo_watch {
        core.ws.repos.watch(true);
        client.forward(Event::Repos);
    }
    // Everyone here and what they are doing, before any change to it.
    client.forward(Event::Participants);
    client.forward(Event::Accounts);
    let mut tasks = JoinSet::new();
    tasks.spawn(write_ctl(
        conn.clone(),
        ctl_tx,
        ctl_out,
        client.peers.clone(),
        Some(Arc::clone(&client.ws.timeline_mailbox)),
    ));
    tasks.spawn(forward_events(Arc::clone(&client), core.events.subscribe()));
    tasks.spawn(accept_uni(Arc::clone(&client)));
    tasks.spawn(accept_bi(Arc::clone(&client)));

    // Stream the panes the client already holds right away, in its order (focused first), so
    // the focused pane is current one RTT after the handshake.
    let mut first = true;
    let mut seen = std::collections::HashSet::new();
    for point in hello
        .resume
        .into_iter()
        .filter(|point| client.pane_allowed(point.pane_id) && seen.insert(point.pane_id))
        .take(MAX_RESUME_POINTS)
    {
        lock(&client.state).resume.insert(point.pane_id, point);
        if first {
            lock(&client.state).focus = Some(point.pane_id);
            first = false;
        } else {
            lock(&client.state).visible.push(point.pane_id);
        }
        client.subscribe(point.pane_id, SubscribeMode::Live).await;
    }
    client.view_changed();

    let result = read_ctl(&client, ctl_rx).await;
    tasks.abort_all();
    for (_, subscription) in lock(&client.state).subscriptions.drain() {
        subscription.task.abort();
    }
    core.detach(client.id);
    core.mp.leave(&core, client.id);
    core.client_connected(false);
    core.device_disconnected(device, client.id);
    if repo_watch {
        core.ws.repos.watch(false);
    }
    lock(&client.ws.watches).clear();
    lock(&client.ws.timeline_watches).clear();
    client.ws.timeline_mailbox.clear();
    result
}

fn conn_err(error: iroh::endpoint::ConnectionError) -> NetError {
    NetError::Frame(proto::FrameError::Io(std::io::Error::other(error)))
}

pub(crate) fn more_daemon_features() -> proto::MoreDaemonFeatures {
    proto::MoreDaemonFeatures::REPO_ROOT
        | proto::MoreDaemonFeatures::RESOLVE_PATHS
        | proto::MoreDaemonFeatures::RUN_AGAIN
}

pub(crate) fn daemon_info(core: &Core) -> proto::DaemonInfo {
    let mut features = DaemonFeatures::EMPTY;
    if core.cfg.self_exe.is_some() {
        features |= DaemonFeatures::SELF_UPGRADE;
    }
    features |= DaemonFeatures::AGENT_USAGE
        | DaemonFeatures::ARTIFACT_HISTORY
        | DaemonFeatures::MP2
        | DaemonFeatures::WORKFLOWS
        | DaemonFeatures::AGENT_INSTALLS
        | DaemonFeatures::PANE_MOVES
        | DaemonFeatures::PROJECTS
        | DaemonFeatures::FLOATS
        | DaemonFeatures::BROWSER
        | DaemonFeatures::AGENT_MCP
        | DaemonFeatures::PRESENCE
        | DaemonFeatures::INVITE_LINKS
        | DaemonFeatures::PROGRAM_STATUS
        | DaemonFeatures::REPO_TRUST
        | DaemonFeatures::REOPEN
        | DaemonFeatures::ACCOUNTS
        | DaemonFeatures::INPUT_RESUME
        | DaemonFeatures::DEVICE_MANAGEMENT
        | DaemonFeatures::PUSH_AGENTS
        | DaemonFeatures::TERMINAL_COLORS
        | DaemonFeatures::POWER_SETTINGS
        | DaemonFeatures::AGENT_TIMELINE
        | DaemonFeatures::VERSIONED_TIMELINE
        | DaemonFeatures::TIMELINE_TOOL_DIFF
        | DaemonFeatures::CHAT_SEND
        | DaemonFeatures::CHAT_INTERRUPT
        | DaemonFeatures::AGENT_CAPABILITIES
        | DaemonFeatures::GENERATED_INPUT
        | DaemonFeatures::ACTIVE_SIZING;
    if core.cfg.push.enabled && core.cfg.push.live_activity {
        features |= DaemonFeatures::LIVE_ACTIVITY;
    }
    crate::info::build_info(features)
}

/// What a `Hello` leads to.
enum Admission {
    /// The connection joins; `true` admits an owner device whose snapshot format does not
    /// match, for an upgrade only (clients announcing [`Caps::DAEMON_INFO`]).
    Join(Authz, bool),
    /// A knock invite: the connection waits for an owner ([`serve_knock`]).
    Knock(Knocker),
}

fn handshake(core: &Arc<Core>, hello: &Hello, device: DeviceId) -> Result<Admission, RefuseReason> {
    if hello.device_id != device {
        return Err(RefuseReason::DeviceMismatch);
    }
    // The TLS handshake accepts small-order keys, whose signatures anyone can forge: such
    // a key proves nothing about who is connecting.
    if !grants::is_strong_key(device) {
        return Err(RefuseReason::InvalidGrant);
    }
    let format = core.cfg.snapshot_format();
    let maintenance = hello.snapshot_format != format;
    if maintenance
        && !(hello.caps.contains(Caps::DAEMON_INFO) && hello.grant.v == SignedGrant::DEVICE)
    {
        return Err(RefuseReason::SnapshotFormat { daemon: format });
    }
    if hello.grant.v == SignedGrant::CHAIN {
        return core
            .mp
            .redeem(
                core,
                device,
                hello.principal_id,
                &hello.grant.token,
                hello.caps,
            )
            .map(|redeemed| match redeemed {
                Redeemed::Joined(authz) => Admission::Join(authz, false),
                Redeemed::Knock(knocker) => Admission::Knock(knocker),
            });
    }
    // A removed device comes back only with a fresh pairing ticket.
    if hello.grant.v != SignedGrant::PAIRING && core.mp.device_removed(device) {
        return Err(RefuseReason::Revoked);
    }
    let principal = core
        .identity
        .authorize(device, hello.principal_id, &hello.grant)?;
    let _ = WIRE_VERSION;
    let actor = Actor { principal, device };
    if hello.grant.v == SignedGrant::PAIRING {
        core.mp.paired(core, actor);
    }
    Ok(Admission::Join(Authz::owner(actor), maintenance))
}

/// Opens since-join views (multiplayer `History::SinceJoin`) on every pane in scope that
/// existed when the guest first joined, so their history starts there even before they
/// subscribe. Panes created later are shown whole.
async fn open_views(core: &Arc<Core>, authz: &Authz) {
    let panes: Vec<_> = core
        .pane_entries()
        .into_iter()
        .filter(|(id, entry)| {
            core.scope_within(Scope::Pane(*id), authz.scope) && entry.existed_at(authz.joined_at)
        })
        .map(|(_, entry)| Arc::clone(&entry.pane))
        .collect();
    let principal = authz.actor.principal;
    let opened = tokio::task::spawn_blocking(move || {
        for pane in panes {
            if let Err(error) = pane.open_view(principal) {
                tracing::warn!(pane = %pane.id, "opening a since-join view: {error}");
            }
        }
    })
    .await;
    if let Err(error) = opened {
        tracing::warn!("opening since-join views: {error}");
    }
}

/// A connection that presented a knock invite: it waits here, seeing nothing, until an owner
/// admits it (it is sent a grant to reconnect with) or turns it away, or it leaves. It may
/// only ping and say its name.
async fn serve_knock(
    core: Arc<Core>,
    conn: Connection,
    ctl_tx: SendStream,
    mut ctl_rx: RecvStream,
    mut knocker: Knocker,
) -> Result<(), NetError> {
    let (ctl, ctl_out) = mpsc::unbounded_channel();
    let writer = tokio::spawn(write_ctl(conn.clone(), ctl_tx, ctl_out, None, None));
    // The knocker says who it is right after `Hello`; wait a moment for it, so the owner (and
    // the audit log) see the name rather than a placeholder.
    let first = tokio::time::timeout(
        std::time::Duration::from_millis(500),
        net::recv(&mut ctl_rx),
    )
    .await;
    let mut named = None;
    match first {
        Ok(Ok(Some(ClientCtl::Multiplayer {
            req_id,
            req: MpRequest::SetName { name },
        }))) => {
            let name: String = name.trim().chars().take(64).collect();
            if !name.is_empty() {
                knocker.name = name;
            }
            named = Some(req_id);
        }
        Ok(Ok(None | Some(ClientCtl::Bye { .. })) | Err(_)) => {
            writer.abort();
            return Ok(());
        }
        _ => {}
    }
    let id = match core.mp.knock(&core, knocker, ctl.clone(), conn.clone()) {
        Ok(id) => {
            core.client_arrived.notify_waiters();
            id
        }
        Err(reason) => {
            let _ = ctl.send(ServerCtl::Refused { reason });
            drop(ctl);
            let _ = writer.await;
            return Ok(());
        }
    };
    let _ = ctl.send(ServerCtl::KnockAnswer(proto::KnockAnswer::Waiting {
        knock_id: id,
    }));
    if let Some(req_id) = named {
        let _ = ctl.send(ServerCtl::MultiplayerResult {
            req_id,
            result: Ok(MpResponse::Done),
        });
    }
    // The knocker pings every few seconds; silence this long means it is gone.
    const LOBBY_IDLE: std::time::Duration = std::time::Duration::from_secs(45);
    let result = loop {
        let Ok(message) = tokio::time::timeout(LOBBY_IDLE, net::recv(&mut ctl_rx)).await else {
            break Ok(());
        };
        match message {
            Ok(Some(ClientCtl::Ping { nonce })) => {
                let _ = ctl.send(ServerCtl::Pong { nonce });
            }
            Ok(Some(ClientCtl::Multiplayer { req_id, req })) => {
                let result = match req {
                    MpRequest::SetName { name } => {
                        core.mp.rename_knock(&core, id, &name);
                        Ok(MpResponse::Done)
                    }
                    _ => Err(MpError::Forbidden(
                        "waiting for the owner to let you in".into(),
                    )),
                };
                let _ = ctl.send(ServerCtl::MultiplayerResult { req_id, result });
            }
            Ok(Some(ClientCtl::Bye { .. }) | None) => break Ok(()),
            Ok(Some(_)) => {}
            Err(error) => break Err(error),
        }
    };
    core.mp.withdraw_knock(&core, id);
    writer.abort();
    result
}

/// Whether `authz` is the daemon's owner: a paired owner device on the whole daemon, not a
/// guest's chain (whatever roles it delegates).
fn is_owner(core: &Core, authz: &Authz) -> bool {
    authz.is_owner_device(core)
}

/// A connection admitted only to upgrade an incompatible daemon: serves upgrade streams from
/// its owner and ignores everything else until the client leaves.
async fn serve_upgrade_only(
    core: Arc<Core>,
    connection: Connection,
    actor: Actor,
    mut ctl_rx: RecvStream,
) -> Result<(), NetError> {
    tracing::info!(device = ?actor.device, "an owner with another snapshot format connected to upgrade");
    let owner = is_owner(&core, &Authz::owner(actor));
    let accept = {
        let core = Arc::clone(&core);
        let connection = connection.clone();
        tokio::spawn(async move {
            while let Ok((mut send, mut recv)) = connection.accept_bi().await {
                let header = net::recv::<StreamHeader>(&mut recv).await;
                match header
                    .as_ref()
                    .ok()
                    .and_then(Option::as_ref)
                    .and_then(crate::upgrade::requested)
                {
                    Some((header, downgrade)) => {
                        let _ = send.set_priority(crate::stream::priority::BULK);
                        tokio::spawn(crate::upgrade::serve(
                            Arc::clone(&core),
                            actor,
                            owner,
                            downgrade,
                            header.clone(),
                            send,
                            recv,
                        ));
                    }
                    None => {
                        let _ = send.finish();
                    }
                }
            }
        })
    };
    while net::recv::<ClientCtl>(&mut ctl_rx).await?.is_some() {}
    accept.abort();
    Ok(())
}

/// Panes a reconnecting client may resume at once; the rest it subscribes to as usual.
const MAX_RESUME_POINTS: usize = 256;
/// `ctl` messages waiting for a client beyond which it is disconnected: it has stopped reading,
/// and holding everything for it would grow without bound. It resumes on reconnect.
const MAX_CTL_BACKLOG: usize = 8192;
/// A `ctl` write that has not finished after this long ends the connection the same way.
const CTL_STALL: Duration = Duration::from_secs(60);
const MAX_CTL_BATCH: usize = 256 * 1024;

/// Live presence comes from `peers` rather than the queue: while a write is stuck on a slow
/// link it keeps only the newest state per peer, so the link catches up with the present
/// instead of replaying every keystroke.
async fn write_ctl(
    connection: Connection,
    mut send: SendStream,
    mut out: mpsc::UnboundedReceiver<ServerCtl>,
    peers: Option<Arc<Mailbox>>,
    timelines: Option<Arc<crate::timeline::Mailbox>>,
) {
    let mut batch = Vec::new();
    let mut bulk_replies = Vec::new();
    loop {
        let first = tokio::select! {
            message = out.recv() => match message {
                Some(message) => Some(message),
                None => return,
            },
            () = async {
                match &peers {
                    Some(mailbox) => mailbox.ready.notified().await,
                    None => std::future::pending().await,
                }
            } => None,
            () = async {
                match &timelines {
                    Some(mailbox) => mailbox.ready.notified().await,
                    None => std::future::pending().await,
                }
            } => None,
        };
        batch.clear();
        bulk_replies.clear();
        let mut next = first;
        // Coalesce what is queued into one write, up to a bound: a producer that never pauses
        // must not keep this loop (and its buffer) growing.
        while let Some(message) = next {
            let bulk_reply = match &message {
                ServerCtl::WorkspaceResult { req_id, result }
                    if crate::timeline::bulk_reply(result) =>
                {
                    Some(*req_id)
                }
                _ => None,
            };
            if let Err(error) = proto::frame::encode(&message, &mut batch) {
                tracing::warn!("encoding ctl message: {error}");
                if let (Some(mailbox), Some(request)) = (&timelines, bulk_reply) {
                    mailbox.reply_sent(request);
                }
            } else if let Some(request) = bulk_reply {
                bulk_replies.push(request);
            }
            next = if batch.len() < MAX_CTL_BATCH {
                out.try_recv().ok()
            } else {
                None
            };
        }
        for message in peers
            .iter()
            .flat_map(|mailbox| mailbox.take())
            .chain(timelines.iter().flat_map(|mailbox| mailbox.take()))
        {
            if let Err(error) = proto::frame::encode(&message, &mut batch) {
                tracing::warn!("encoding ctl message: {error}");
            }
        }
        if batch.is_empty() {
            continue;
        }
        let started = tokio::time::Instant::now();
        let write = send.write_all(&batch);
        tokio::pin!(write);
        let mut check = tokio::time::interval(Duration::from_millis(250));
        loop {
            tokio::select! {
                written = &mut write => {
                    if written.is_err() {
                        // A client without its `ctl` stream cannot work; let it reconnect.
                        connection.close(3u32.into(), b"ctl stream lost");
                        return;
                    }
                    break;
                }
                _ = check.tick() => {
                    if out.len() > MAX_CTL_BACKLOG || started.elapsed() > CTL_STALL {
                        tracing::info!(
                            remote = %connection.remote_id(),
                            backlog = out.len(),
                            "client stopped reading; disconnecting it"
                        );
                        connection.close(3u32.into(), b"too slow");
                        return;
                    }
                }
            }
        }
        if let Some(mailbox) = &timelines {
            for request in bulk_replies.drain(..) {
                mailbox.reply_sent(request);
            }
        }
    }
}

async fn read_ctl(client: &Arc<Client>, mut stream: RecvStream) -> Result<(), NetError> {
    while let Some(message) = net::recv::<ClientCtl>(&mut stream).await? {
        client.handle_ctl(message).await;
    }
    Ok(())
}

async fn forward_events(client: Arc<Client>, mut events: broadcast::Receiver<Event>) {
    loop {
        match events.recv().await {
            Ok(event) => client.forward(event),
            Err(broadcast::error::RecvError::Lagged(_)) => {
                // Events are hints; after missing some, resend the state itself.
                client.send(client.core.sessions_message(client.authz.scope));
                let session = lock(&client.state).session;
                if let Some(session) = session {
                    client.forward(Event::Layout(session));
                }
                client.forward(Event::Participants);
            }
            Err(broadcast::error::RecvError::Closed) => return,
        }
    }
}

async fn accept_uni(client: Arc<Client>) {
    while let Ok(mut stream) = client.conn.accept_uni().await {
        match net::recv::<StreamHeader>(&mut stream).await {
            Ok(Some(StreamHeader::Input)) => {
                let client = Arc::clone(&client);
                tokio::spawn(async move {
                    if let Err(error) = read_input(&client, stream).await {
                        tracing::debug!("input stream: {error}");
                    }
                });
            }
            other => tracing::debug!("unexpected uni stream header: {other:?}"),
        }
    }
}

async fn accept_bi(client: Arc<Client>) {
    while let Ok((mut send, mut recv)) = client.conn.accept_bi().await {
        let header = net::recv::<StreamHeader>(&mut recv).await;
        // Forwards and file transfers reach the host beyond the terminal: driver, with a
        // daemon- or session-wide grant.
        let host = matches!(
            header,
            Ok(Some(
                StreamHeader::PortForward { .. }
                    | StreamHeader::Forward { .. }
                    | StreamHeader::Upload(_)
                    | StreamHeader::Download(_)
            ))
        );
        if host
            && let Err(error) = client
                .live()
                .and_then(|()| client.allow(Need::Drive, Target::Host))
        {
            let _ = match header {
                Ok(Some(StreamHeader::Upload(_) | StreamHeader::Download(_))) => {
                    let reply = TransferReply::Failed(WsError::Denied(error.to_string()));
                    net::send(&mut send, &reply).await
                }
                _ => {
                    let reply = ForwardReply::Refused {
                        reason: error.to_string(),
                    };
                    net::send(&mut send, &reply).await
                }
            };
            let _ = send.finish();
            continue;
        }
        if let Some((header, downgrade)) = header
            .as_ref()
            .ok()
            .and_then(Option::as_ref)
            .and_then(crate::upgrade::requested)
        {
            let owner = client.live().is_ok() && is_owner(&client.core, &client.authz);
            let _ = send.set_priority(crate::stream::priority::BULK);
            tokio::spawn(crate::upgrade::serve(
                Arc::clone(&client.core),
                client.actor,
                owner,
                downgrade,
                header.clone(),
                send,
                recv,
            ));
            continue;
        }
        if let Ok(Some(StreamHeader::Blob(blob))) = &header {
            // Uploads need the draw role in the session; downloads any role (a blob is named
            // by its SHA-256, which only someone who can see an artifact holding it learns).
            let allowed = client.live().and_then(|()| match blob {
                BlobHeader::Put { session_id, .. } => {
                    client.allow(Need::Draw, Target::Session(*session_id))
                }
                BlobHeader::Get { .. } => client.allow(Need::View, Target::Any),
            });
            if let Err(error) = allowed {
                let reply = BlobReply::Failed(ArtifactError::Forbidden(error.to_string()));
                let _ = net::send(&mut send, &reply).await;
                let _ = send.finish();
                continue;
            }
            let _ = send.set_priority(crate::stream::priority::BULK);
            let core = Arc::clone(&client.core);
            let blob = blob.clone();
            tokio::spawn(crate::art::send::serve_blob(core, blob, send, recv));
            continue;
        }
        match header {
            Ok(Some(StreamHeader::PortForward { port })) => {
                tokio::spawn(forward::serve(port, send, recv));
            }
            Ok(Some(StreamHeader::Forward { target })) => {
                let policy = client.core.ws.policy.clone();
                tokio::spawn(forward::serve_target(target, policy, send, recv));
            }
            Ok(Some(StreamHeader::Upload(header))) => {
                let _ = send.set_priority(crate::stream::priority::BULK);
                let policy = client.core.ws.policy.clone();
                tokio::spawn(crate::ws::serve_upload(policy, header, send, recv));
            }
            Ok(Some(StreamHeader::Download(header))) => {
                let _ = send.set_priority(crate::stream::priority::BULK);
                let policy = client.core.ws.policy.clone();
                tokio::spawn(crate::ws::serve_download(policy, header, send));
            }
            other => tracing::debug!("unexpected bidi stream header: {other:?}"),
        }
    }
}

async fn read_input(client: &Arc<Client>, mut stream: RecvStream) -> Result<(), NetError> {
    while let Some(ClientInput::Input(input)) = net::recv(&mut stream).await? {
        let reject = |reason| ServerCtl::InputRejected {
            pane_id: input.pane_id,
            input_seq: input.input_seq,
            reason,
        };
        if client.live().is_err() {
            return Ok(());
        }
        // Sent again after a reconnect, but this one arrived before the old link died; its
        // acknowledgement did not, or it would not have been sent again.
        if let Some(stream) = client.input_stream
            && !client
                .core
                .inputs
                .admit(client.actor.device, stream, input.input_seq.0)
        {
            if let Some(entry) = client.core.pane(input.pane_id)
                && let Some(subscription) = lock(&client.state).subscriptions.get(&input.pane_id)
            {
                let _ = subscription.cmds.send(StreamCmd::InputAck {
                    input_seq: input.input_seq,
                    at_seq: entry.pane.head(),
                });
            }
            continue;
        }
        if input.principal != client.actor.principal {
            client.send(reject(InputRejectReason::Role));
            continue;
        }
        if !client.pane_allowed(input.pane_id) {
            client.send(reject(InputRejectReason::UnknownPane));
            continue;
        }
        let Some(entry) = client.core.pane(input.pane_id) else {
            client.send(reject(InputRejectReason::UnknownPane));
            continue;
        };
        // Raw keys, paste and mouse are the Driver's; prompters use the composer path
        // (`MpRequest::Prompt`).
        if let Err(error) = client.allow(Need::Drive, Target::Pane(input.pane_id)) {
            client.send(reject(InputRejectReason::Role));
            client.send(ServerCtl::Forbidden {
                what: "Input".into(),
                reason: error.to_string(),
            });
            continue;
        }
        // One driver at a time per pane: input from anyone but the lease holder is refused,
        // with the lease so the client can say who is driving.
        if let Err(lease) = client
            .core
            .mp
            .input(&client.core, input.pane_id, client.actor)
        {
            client.send(reject(InputRejectReason::NoLease));
            client.send(ServerCtl::Lease(lease));
            continue;
        }
        // Keys, mouse and paste are encoded for the program's current modes, which only the
        // daemon's VT knows for sure (the client's may lag behind by the bytes in flight).
        let is_sizing_input = crate::input::is_sizing_input(&input.payload);
        let records_typing = !matches!(&input.payload, InputPayload::GeneratedBytes(_));
        let bytes = match input.payload {
            InputPayload::Bytes(bytes) | InputPayload::GeneratedBytes(bytes) => bytes,
            payload => entry.pane.encode_input(payload),
        };
        let is_focus_report = crate::input::is_focus_report(&bytes);
        let is_sizing_input = is_sizing_input && !bytes.is_empty() && !is_focus_report;
        let size = lock(&client.state).sizes.get(&input.pane_id).copied();
        if is_sizing_input && let Some(size) = size {
            client
                .core
                .apply_client_size(&entry, client.id, &client.authz, size, true);
        }
        let written = if records_typing && !is_focus_report {
            entry.pane.write(bytes).await
        } else {
            entry.pane.write_generated(bytes).await
        };
        let at_seq = match written {
            Ok(at_seq) => at_seq,
            Err(crate::pane::InputError::Closed) => {
                client.send(reject(InputRejectReason::UnknownPane));
                continue;
            }
            Err(error @ crate::pane::InputError::Stalled) => {
                tracing::debug!(pane = %input.pane_id, "input refused: {error}");
                client.send(reject(InputRejectReason::Blocked));
                continue;
            }
        };
        if records_typing && !is_focus_report {
            lock(&entry.meta).typed_by = Some(client.id);
            client.core.theme_used(client.id, &entry);
            client.core.mp.typed(&client.core, client.id, input.pane_id);
        }
        if let Some(subscription) = lock(&client.state).subscriptions.get(&input.pane_id) {
            let _ = subscription.cmds.send(StreamCmd::InputAck {
                input_seq: input.input_seq,
                at_seq,
            });
        }
    }
    Ok(())
}

impl Client {
    fn send(&self, message: ServerCtl) {
        let _ = self.ctl.send(message);
    }

    /// Re-checks the grant (revocation, expiry). On failure the connection is told and
    /// closed.
    fn live(&self) -> Result<(), MpError> {
        if self.core.mp.still_valid(&self.authz) {
            Ok(())
        } else {
            self.core.mp.kick_invalid();
            Err(MpError::Forbidden("grant revoked or expired".into()))
        }
    }

    fn allow(&self, need: Need, target: Target) -> Result<(), MpError> {
        policy::check(&self.core, &self.authz, need, target)
    }

    fn pane_allowed(&self, pane: PaneId) -> bool {
        self.core.scope_within(Scope::Pane(pane), self.authz.scope)
    }

    /// Checks a ctl request; on refusal tells the client what and why.
    fn permit(&self, what: &str, need: Need, target: Target) -> bool {
        match self.allow(need, target) {
            Ok(()) => true,
            Err(error) => {
                self.send(ServerCtl::Forbidden {
                    what: what.into(),
                    reason: error.to_string(),
                });
                false
            }
        }
    }

    /// The principal whose since-join view this connection sees `pane` through: guests
    /// with `History::SinceJoin` on panes that existed when they first joined.
    fn viewer(&self, pane: PaneId) -> Option<proto::PrincipalId> {
        if self.authz.history != proto::History::SinceJoin {
            return None;
        }
        let entry = self.core.pane(pane)?;
        entry
            .existed_at(self.authz.joined_at)
            .then_some(self.actor.principal)
    }

    fn in_session(&self, pane: PaneId) -> bool {
        let session = lock(&self.state).session;
        // One lock at a time: `pane_allowed` takes the layout lock itself.
        let in_session = session.is_some() && self.core.session_of_pane(pane) == session;
        in_session && self.pane_allowed(pane)
    }

    /// Sends a layout, then its projects to an owner client that wants them.
    fn send_layout(&self, layout: proto::SessionLayout) {
        let session = layout.session_id;
        self.send(ServerCtl::LayoutChanged(layout));
        if self.caps.contains(Caps::PROJECTS)
            && self.authz.roles.allows_any(proto::Roles::OWNER)
            && let Some(projects) = self.core.projects_for(session, self.authz.scope)
        {
            self.send(ServerCtl::Projects(projects));
        }
        if self.caps.contains(Caps::FLOATS)
            && let Some(floats) = self.core.floats_for(session, self.authz.scope)
        {
            self.send(ServerCtl::Floats(floats));
        }
    }

    fn forward(&self, event: Event) {
        match event {
            Event::Layout(session) => {
                if lock(&self.state).session == Some(session)
                    && let Some(layout) = self.core.layout_for(session, self.authz.scope)
                {
                    self.send_layout(layout);
                }
            }
            Event::Sessions => self.send(self.core.sessions_message(self.authz.scope)),
            Event::PaneMeta(pane) => {
                if self.in_session(pane)
                    && let Some(meta) = self.pane_metadata(pane)
                {
                    let changed = {
                        let mut state = lock(&self.state);
                        if state.sent_meta.get(&pane) != Some(&meta) {
                            state.sent_meta.insert(pane, meta.clone());
                            true
                        } else {
                            false
                        }
                    };
                    if changed {
                        self.send(ServerCtl::PaneMeta(meta));
                    }
                    self.send_pane_sizing(pane);
                }
            }
            Event::PaneClosed(pane) => {
                let had = {
                    let mut state = lock(&self.state);
                    state.sent_meta.remove(&pane);
                    state.sent_sizing.remove(&pane);
                    state
                        .subscriptions
                        .remove(&pane)
                        .map(|subscription| subscription.task.abort())
                };
                // A scoped guest is only told about panes it could see.
                if had.is_some() || self.authz.scope == Scope::Daemon {
                    self.send(ServerCtl::PaneClosed { pane_id: pane });
                }
            }
            Event::Echo(hint) => {
                if self.in_session(hint.hint.pane_id) {
                    self.send(ServerCtl::EchoHintAt(hint));
                }
            }
            Event::Agent { pane_id, json } => {
                if self.in_session(pane_id) {
                    self.send(ServerCtl::AgentEvent {
                        pane_id,
                        json: json.to_string(),
                    });
                }
            }
            Event::Decided(decided) => {
                if self.pane_allowed(decided.pane_id) {
                    self.send(ServerCtl::Decided(decided));
                }
            }
            Event::Command { mark, .. } => {
                if self.in_session(mark.pane_id) {
                    self.send(ServerCtl::CommandMark(mark));
                }
            }
            Event::CommandUnseen(mark) => {
                if self.pane_allowed(mark.pane_id) {
                    self.send(ServerCtl::CommandFinishedUnseen(mark));
                }
            }
            Event::Ports => self.send(ServerCtl::PortsChanged {
                ports: self.scoped_ports(self.core.ws.ports.current()),
            }),
            Event::Attention(proto::AttentionUpdate::Added { item, .. }) => {
                if self.pane_allowed(item.pane_id) {
                    let attention = &self.core.ws.attention;
                    self.send(ServerCtl::Attention(proto::AttentionUpdate::Added {
                        item: attention.as_seen_by(self.ws.viewer, &item),
                        unseen: attention.unseen_by(self.ws.viewer, |pane| self.pane_allowed(pane)),
                    }));
                }
            }
            Event::AttentionSeen { by, mut ids }
                if by.is_none_or(|viewer| viewer == self.ws.viewer) =>
            {
                let attention = &self.core.ws.attention;
                ids.retain(|&id| {
                    attention
                        .pane_of(id)
                        .is_some_and(|pane| self.pane_allowed(pane))
                });
                if !ids.is_empty() {
                    self.send(ServerCtl::Attention(proto::AttentionUpdate::Seen {
                        ids,
                        unseen: attention.unseen_by(self.ws.viewer, |pane| self.pane_allowed(pane)),
                    }));
                }
            }
            Event::Attention(proto::AttentionUpdate::Seen { .. }) | Event::AttentionSeen { .. } => {
            }
            Event::VsCodeTunnel(status) => {
                if self.allow(Need::Drive, Target::Host).is_ok() {
                    self.send(ServerCtl::VsCodeTunnel(status));
                }
            }
            Event::Participants => {
                self.send(ServerCtl::Participants {
                    participants: self.core.mp.participants(&self.core, &self.authz),
                });
                if let Some(mailbox) = &self.peers {
                    mailbox.put(proto::PeerPush::All {
                        you: proto::PeerId(self.id),
                        peers: self.core.mp.peers(&self.core, &self.authz),
                    });
                }
            }
            Event::Peer(id) => {
                if let Some(mailbox) = &self.peers
                    && id != self.id
                    && let Some(peer) = self.core.mp.peer(&self.core, id, &self.authz)
                {
                    mailbox.put(proto::PeerPush::Changed(peer));
                }
            }
            Event::Presence(mut presence) => {
                if presence.focus.is_some_and(|pane| !self.pane_allowed(pane)) {
                    presence.focus = None;
                    presence.typing = false;
                }
                if presence
                    .cursor
                    .is_some_and(|cursor| !self.pane_allowed(cursor.pane_id))
                {
                    presence.cursor = None;
                }
                if presence
                    .viewport
                    .is_some_and(|viewport| !self.pane_allowed(viewport.pane_id))
                {
                    presence.viewport = None;
                }
                if presence.actor != self.actor {
                    self.send(ServerCtl::Presence(presence));
                }
            }
            Event::Lease(lease) => {
                if self.pane_allowed(lease.pane_id) {
                    self.send(ServerCtl::Lease(lease));
                }
            }
            Event::Artifact {
                session,
                event,
                from,
            } => {
                if from == Some(self.id) || lock(&self.state).session != Some(session) {
                    return;
                }
                let event = match &*event {
                    ArtifactEvent::Created(info)
                    | ArtifactEvent::Info(info)
                    | ArtifactEvent::Changed { info, .. } => {
                        if !self.artifact_visible(info) {
                            return;
                        }
                        (*event).clone()
                    }
                    ArtifactEvent::Deleted { .. } => {
                        if !matches!(self.authz.scope, Scope::Daemon | Scope::Session(_)) {
                            return;
                        }
                        (*event).clone()
                    }
                    ArtifactEvent::Ink(ink) => {
                        let visible = self
                            .core
                            .art
                            .info(ink.artifact_id)
                            .is_some_and(|info| self.artifact_visible(&info));
                        if !visible {
                            return;
                        }
                        (*event).clone()
                    }
                    ArtifactEvent::Excalidraw { artifact_id, .. } => {
                        let visible = self
                            .core
                            .art
                            .info(*artifact_id)
                            .is_some_and(|info| self.artifact_visible(&info));
                        if !visible {
                            return;
                        }
                        (*event).clone()
                    }
                    ArtifactEvent::Placed(placement) => {
                        if !self.pane_allowed(placement.pane_id) {
                            return;
                        }
                        (*event).clone()
                    }
                    ArtifactEvent::Unplaced { pane_id, .. } => {
                        if !self.pane_allowed(*pane_id) {
                            return;
                        }
                        (*event).clone()
                    }
                    ArtifactEvent::Canvases {
                        session_id,
                        canvases,
                    } => ArtifactEvent::Canvases {
                        session_id: *session_id,
                        canvases: canvases
                            .iter()
                            .filter(|canvas| self.pane_allowed(canvas.pane_id))
                            .copied()
                            .collect(),
                    },
                };
                self.send(ServerCtl::Artifact(event));
            }
            Event::Assist(push) => {
                let send = match &push {
                    proto::AssistPush::Foreground(foreground) => {
                        self.in_session(foreground.pane_id)
                    }
                    proto::AssistPush::Prompt(state) => {
                        self.core.assist.watching(self.id, state.pane_id)
                            && self.pane_allowed(state.pane_id)
                    }
                };
                if send {
                    self.send(ServerCtl::Assist(push));
                }
            }
            Event::ProgramStatus(pane_id) => {
                if self.caps.contains(Caps::PROGRAM_STATUS) && self.in_session(pane_id) {
                    self.send(ServerCtl::ProgramStatus {
                        pane_id,
                        status: self.core.program_report(pane_id),
                    });
                }
            }
            Event::Askpass(push) => {
                if self.may_answer(crate::askpass::push_pane(&push)) {
                    self.send(ServerCtl::Askpass(self.askpass_push(push)));
                }
            }
            Event::Repos => {
                if let Some(snapshot) = self.scoped_repos() {
                    self.send(ServerCtl::Repos(snapshot));
                }
            }
            Event::RunAgain => {
                if lock(&self.state).watches_run_again && is_owner(&self.core, &self.authz) {
                    self.send(ServerCtl::RunAgainOffers(self.core.run_again_offers()));
                }
            }
            Event::Accounts => {
                if self.caps.contains(Caps::ACCOUNTS) && is_owner(&self.core, &self.authz) {
                    self.send(ServerCtl::Accounts(self.core.accounts_report()));
                }
            }
            Event::Knock(update) => {
                if self.caps.contains(Caps::KNOCK) && is_owner(&self.core, &self.authz) {
                    self.send(ServerCtl::Knock(update));
                }
            }
            Event::DevicePaired(info) => {
                if self.caps.contains(Caps::DEVICE_ALERTS)
                    && info.device != self.actor.device
                    && is_owner(&self.core, &self.authz)
                {
                    self.send(ServerCtl::DevicePaired(info));
                }
            }
            Event::GuestAnswered(answer) => {
                if self.caps.contains(Caps::ANSWER_ALERTS) && self.ws.owner {
                    self.send(ServerCtl::GuestAnswered(answer));
                }
            }
            Event::ApprovalPolicy(session_id, policy) => {
                if self.caps.contains(Caps::APPROVAL_POLICY)
                    && lock(&self.state).session == Some(session_id)
                {
                    self.send(ServerCtl::ApprovalPolicy { session_id, policy });
                }
            }
            Event::ApprovalStatus(status) => {
                if self.caps.contains(Caps::APPROVAL_POLICY) && self.pane_allowed(status.pane_id) {
                    self.send(ServerCtl::ApprovalStatus(status));
                }
            }
            Event::Approval(proto::ApprovalPush::Drive(push)) => {
                let shown = match &push {
                    proto::DrivePush::Open(ask) => self.sees_drive_asks(ask.pane_id),
                    proto::DrivePush::Closed { .. } => self.sees_drive_asks(None),
                };
                if shown {
                    self.send(ServerCtl::Approval(proto::ApprovalPush::Drive(push)));
                }
            }
            Event::Approval(push) => {
                let pane = match &push {
                    proto::ApprovalPush::Request(info) => info.pane_id,
                    proto::ApprovalPush::Rules { pane_id, .. } => *pane_id,
                    proto::ApprovalPush::Drive(_) => return,
                };
                if self.caps.contains(Caps::APPROVALS) && self.pane_allowed(pane) {
                    self.send(ServerCtl::Approval(push));
                }
            }
            Event::Workflows(revision) => {
                if self.caps.contains(Caps::WORKFLOWS) {
                    self.send(ServerCtl::WorkflowsChanged { rev: revision });
                }
            }
            Event::Browser { conn, push } => {
                if conn == self.id {
                    self.send(ServerCtl::Browser(push));
                }
            }
            Event::Clipboard {
                conn,
                pane_id,
                text,
            } => {
                if conn == self.id
                    && self.caps.contains(Caps::CLIPBOARD)
                    && self.in_session(pane_id)
                {
                    self.send(ServerCtl::Clipboard {
                        pane_id,
                        text: text.to_string(),
                    });
                }
            }
        }
    }

    /// The reports of the panes in `Welcome`, for a connection that just arrived.
    fn program_state(&self) {
        if !self.caps.contains(Caps::PROGRAM_STATUS) {
            return;
        }
        for (pane_id, _) in self.core.pane_entries() {
            if self.pane_allowed(pane_id)
                && let Some(status) = self.core.program_report(pane_id)
            {
                self.send(ServerCtl::ProgramStatus {
                    pane_id,
                    status: Some(status),
                });
            }
        }
    }

    /// Whether this connection is told about drive requests (of `pane`'s session, or any when
    /// `None`): owner devices that asked for them.
    fn sees_drive_asks(&self, pane: impl Into<Option<PaneId>>) -> bool {
        self.caps.contains(Caps::APPROVALS | Caps::DRIVE_ASKS)
            && is_owner(&self.core, &self.authz)
            && pane.into().is_none_or(|pane| self.in_session(pane))
    }

    /// The open drive requests of the attached session, for a connection that just attached.
    fn drive_state(&self) {
        for ask in self.core.term.asks.all() {
            if self.sees_drive_asks(ask.pane_id) {
                self.send(ServerCtl::Approval(proto::ApprovalPush::Drive(
                    proto::DrivePush::Open(ask),
                )));
            }
        }
    }

    /// The open requests' extras and the rules in force, for a connection that just arrived.
    fn approvals_state(&self) {
        if !self.caps.contains(Caps::APPROVALS) {
            return;
        }
        let (open, panes) = self.core.approvals.snapshot();
        for info in open {
            if self.pane_allowed(info.pane_id) {
                self.send(ServerCtl::Approval(proto::ApprovalPush::Request(info)));
            }
        }
        for pane in panes {
            if self.pane_allowed(pane) {
                let rules = self.core.approvals.rules(pane);
                self.send(ServerCtl::Approval(proto::ApprovalPush::Rules {
                    pane_id: pane,
                    rules,
                }));
            }
        }
    }

    /// An approval extra: approve with edited input, add or revoke an auto-approve rule.
    /// Each needs Approver on the pane, and the first two a signature by this device.
    fn approval(
        &self,
        request: proto::ApprovalRequest,
    ) -> Result<proto::ApprovalResponse, proto::ApprovalError> {
        use proto::ApprovalError as E;
        self.live()
            .map_err(|error| E::Forbidden(error.to_string()))?;
        let daemon = self.core.identity.daemon_id();
        let name = self.core.mp.name_of(self.id);
        match request {
            proto::ApprovalRequest::ApproveEdited { decide, input } => {
                if decide.actor != self.actor {
                    return Err(E::Forbidden(
                        "the decision's actor is not this connection".into(),
                    ));
                }
                let pane = self
                    .core
                    .request_pane(decide.request_id)
                    .ok_or(E::NotFound)?;
                self.allow(Need::Approve, Target::Pane(pane))
                    .map_err(|error| E::Forbidden(error.to_string()))?;
                if !grants::verify_approval(daemon, &decide) {
                    return Err(E::Forbidden(
                        "the decision is not signed by this device".into(),
                    ));
                }
                let input = input.trim();
                if input.is_empty() || input.len() > 64 * 1024 {
                    return Err(E::Invalid("the command is empty or too long".into()));
                }
                let (original, allow) =
                    crate::approve::editable(&self.core, pane, decide.request_id)?;
                if decide.option_id != allow {
                    return Err(E::Invalid("an edited request can only be allowed".into()));
                }
                let signature = decide.sig.clone();
                let record = |decided: &proto::Decided, details: &crate::agent::DecidedRequest| {
                    self.answered(
                        decided.pane_id,
                        &details.option,
                        &format!("{original} → {input}"),
                    );
                    self.core.mp.audit.append(
                        AuditKind::Approval,
                        crate::mp::AuditEntry {
                            pane_id: Some(decided.pane_id),
                            detail: format!(
                                "{name} edited {original:?} to {input:?} and chose {:?}",
                                details.option
                            ),
                            approval: Some(proto::ApprovalAudit {
                                request_id: decide.request_id,
                                agent_request: details.request.to_string(),
                                option_id: decide.option_id,
                                option: details.option.clone(),
                                tool: details.tool.clone(),
                                summary: format!("{original} → {input}"),
                                signed: proto::approval_signing_bytes(
                                    daemon,
                                    decide.request_id,
                                    decide.option_id,
                                    decide.actor,
                                ),
                                sig: signature,
                            }),
                            ..self.authz.audit()
                        },
                    );
                };
                match self.core.decide_authorized(
                    self.actor,
                    &decide,
                    Some(input),
                    Some(crate::agent_driver::ApprovalEvidence::Device(&self.authz)),
                    record,
                ) {
                    Ok(_) => Ok(proto::ApprovalResponse::Done),
                    Err(Some(_)) => Err(E::AlreadyDecided),
                    Err(None) => Err(E::NotFound),
                }
            }
            proto::ApprovalRequest::AddRule(rule) => {
                if rule.actor != self.actor {
                    return Err(E::Forbidden(
                        "the rule's actor is not this connection".into(),
                    ));
                }
                self.allow(Need::Approve, Target::Pane(rule.pane_id))
                    .map_err(|error| E::Forbidden(error.to_string()))?;
                grants::check_rule(
                    daemon,
                    &rule,
                    proto::UnixMillis(crate::identity::now_millis()),
                )
                .map_err(|error| match error {
                    grants::RuleError::Signature => E::Forbidden(error.to_string()),
                    _ => E::Invalid(error.to_string()),
                })?;
                crate::approve::add_rule(&self.core, rule, name)?;
                Ok(proto::ApprovalResponse::Done)
            }
            proto::ApprovalRequest::RevokeRule { rule_id } => {
                let pane = crate::approve::rule_pane(&self.core, rule_id).ok_or(E::NotFound)?;
                self.allow(Need::Approve, Target::Pane(pane))
                    .map_err(|error| E::Forbidden(error.to_string()))?;
                crate::approve::revoke(&self.core, rule_id, self.actor, &name)?;
                Ok(proto::ApprovalResponse::Done)
            }
        }
    }

    /// Whether this connection is shown native password prompts for `pane`: it asked for
    /// them, shows the pane's session and may drive the pane. Guests who only watch never see
    /// the prompt text, and only owner devices qualify: a host that is not a guest's own must
    /// never ask for the guest's passwords.
    fn may_answer(&self, pane: PaneId) -> bool {
        self.caps.contains(Caps::ASKPASS)
            && is_owner(&self.core, &self.authz)
            && self.in_session(pane)
            && self.allow(Need::Drive, Target::Pane(pane)).is_ok()
    }

    /// `push` as this client understands it.
    fn askpass_push(&self, push: proto::AskpassPush) -> proto::AskpassPush {
        match push {
            proto::AskpassPush::PromptWhileGuestDrives { prompt, .. }
                if !self.caps.contains(Caps::ASKPASS_DRIVER) =>
            {
                proto::AskpassPush::Prompt(prompt)
            }
            push => push,
        }
    }

    /// The open and detected password prompts of `pane`, for a connection that just attached.
    fn askpass_state(&self, pane: PaneId) {
        if !self.may_answer(pane) {
            return;
        }
        for push in self.core.askpass.open_in(pane) {
            self.send(ServerCtl::Askpass(self.askpass_push(push)));
        }
        if let Some(detected) = crate::askpass::detected(&self.core, pane) {
            self.send(ServerCtl::Askpass(proto::AskpassPush::Detected(detected)));
        }
    }

    /// The repository snapshot as this connection may see it: clients with
    /// `Caps::REPO_STATUS` that may read the host's repositories, panes within the scope and
    /// the repositories those panes are in. `None` before the first snapshot.
    fn scoped_repos(&self) -> Option<proto::RepoSnapshot> {
        if !self.caps.contains(Caps::REPO_STATUS) || self.allow(Need::Drive, Target::Host).is_err()
        {
            return None;
        }
        let snapshot = self.core.ws.repos.snapshot();
        if snapshot.rev == 0 {
            return None;
        }
        let mut snapshot = (*snapshot).clone();
        if self.authz.scope != Scope::Daemon {
            snapshot
                .panes
                .retain(|pane| self.pane_allowed(pane.pane_id));
            let repos: std::collections::BTreeSet<String> = snapshot
                .worktrees
                .iter()
                .filter(|worktree| {
                    snapshot
                        .panes
                        .iter()
                        .any(|pane| pane.worktree == worktree.path)
                })
                .map(|worktree| worktree.repo.clone())
                .collect();
            snapshot
                .worktrees
                .retain(|worktree| repos.contains(&worktree.repo));
        }
        Some(snapshot)
    }

    /// Whether this connection may see an artifact: its session for daemon- and
    /// session-wide grants; for tab- and pane-scoped guests only ink anchored to, or canvases
    /// shown in, panes they can see.
    fn artifact_visible(&self, info: &ArtifactInfo) -> bool {
        match self.authz.scope {
            Scope::Daemon => true,
            Scope::Session(session) => info.session_id == session,
            Scope::Tab(_) | Scope::Pane(_) => {
                info.anchor
                    .is_some_and(|anchor| self.pane_allowed(anchor.pane_id))
                    || info
                        .canvas_panes
                        .iter()
                        .any(|pane| self.pane_allowed(*pane))
                    || self
                        .core
                        .art
                        .placement_panes(info.artifact_id)
                        .into_iter()
                        .any(|pane| self.pane_allowed(pane))
            }
        }
    }

    fn visible_artifact(&self, id: proto::ArtifactId) -> Result<ArtifactInfo, ArtifactError> {
        self.core
            .art
            .info(id)
            .filter(|info| self.artifact_visible(info))
            .ok_or_else(|| ArtifactError::NotFound(format!("artifact {id}")))
    }

    /// Gated by the policy table and the artifact's visibility.
    async fn artifact(&self, request: ArtifactRequest) -> Result<ArtifactResponse, ArtifactError> {
        let (need, target) = policy::artifact(&request);
        self.allow(need, target)
            .map_err(|error| ArtifactError::Forbidden(error.to_string()))?;
        let core = &self.core;
        let art = &core.art;
        match request {
            ArtifactRequest::List { session_id } => {
                if !core.session_visible(session_id, self.authz.scope) {
                    return Err(ArtifactError::NotFound(format!("session {session_id}")));
                }
                let _ = art.check_anchors(core);
                Ok(ArtifactResponse::List(
                    art.list(session_id)
                        .into_iter()
                        .filter(|info| self.artifact_visible(info))
                        .collect(),
                ))
            }
            ArtifactRequest::Create(create) => {
                if lock(&core.layout).session(create.session_id).is_none() {
                    return Err(ArtifactError::NotFound(format!(
                        "session {}",
                        create.session_id
                    )));
                }
                if let Some(anchor) = create.anchor
                    && core.session_of_pane(anchor.pane_id) != Some(create.session_id)
                {
                    return Err(ArtifactError::Invalid(
                        "the anchor pane is in another session".into(),
                    ));
                }
                let (mut info, _) = art.create(self.actor, &create, None)?;
                if let Some(requested) = create.anchor {
                    match crate::art::Art::resolve_anchor(core, info.artifact_id, requested) {
                        Ok(anchor) => {
                            info =
                                art.update(info.artifact_id, |info| info.anchor = Some(anchor))?
                        }
                        Err(error) => {
                            let _ = art.delete(info.artifact_id);
                            return Err(error);
                        }
                    }
                }
                core.emit_artifact(
                    info.session_id,
                    ArtifactEvent::Created(info.clone()),
                    Some(self.id),
                );
                Ok(ArtifactResponse::Created(info))
            }
            ArtifactRequest::Get { artifact_id, since } => {
                self.visible_artifact(artifact_id)?;
                art.scene(artifact_id, since).map(ArtifactResponse::Scene)
            }
            ArtifactRequest::Apply {
                artifact_id, ops, ..
            } => {
                self.visible_artifact(artifact_id)?;
                let (info, batch) = art.apply(artifact_id, self.actor, ops)?;
                let version = info.version;
                core.emit_artifact(
                    info.session_id,
                    ArtifactEvent::Changed { info, batch },
                    None,
                );
                Ok(ArtifactResponse::Applied {
                    artifact_id,
                    version,
                })
            }
            ArtifactRequest::Delete { artifact_id } => {
                let info = self.visible_artifact(artifact_id)?;
                if let Some(anchor) = info.anchor
                    && let Some(entry) = core.pane(anchor.pane_id)
                {
                    entry.pane.anchor_remove(artifact_id.0);
                }
                // Close the canvas panes while the artifact still holds them, so clients hear
                // `PaneClosed` and the new `Canvases` list.
                for pane in &info.canvas_panes {
                    Arc::clone(core).apply_op(proto::LayoutOp::ClosePane { pane_id: *pane });
                }
                let info = match art.delete(artifact_id) {
                    Ok(info) => info,
                    // Closing its last pane closed the session, and its artifacts with it.
                    Err(ArtifactError::NotFound(_)) if !info.canvas_panes.is_empty() => info,
                    Err(error) => return Err(error),
                };
                core.emit_artifact(
                    info.session_id,
                    ArtifactEvent::Deleted {
                        session_id: info.session_id,
                        artifact_id,
                    },
                    None,
                );
                Ok(ArtifactResponse::Done)
            }
            ArtifactRequest::SetAnchor {
                artifact_id,
                anchor,
            } => {
                let info = self.visible_artifact(artifact_id)?;
                if info.kind == proto::ArtifactKind::Image {
                    return Err(ArtifactError::Invalid(
                        "images are placed (`Place`), not anchored".into(),
                    ));
                }
                if let Some(old) = info.anchor
                    && let Some(entry) = core.pane(old.pane_id)
                {
                    entry.pane.anchor_remove(artifact_id.0);
                }
                let anchor = match anchor {
                    Some(requested) => {
                        if core.session_of_pane(requested.pane_id) != Some(info.session_id) {
                            return Err(ArtifactError::Invalid(
                                "the anchor pane is in another session".into(),
                            ));
                        }
                        Some(crate::art::Art::resolve_anchor(
                            core,
                            artifact_id,
                            requested,
                        )?)
                    }
                    None => None,
                };
                let info = art.update(artifact_id, |info| info.anchor = anchor)?;
                core.emit_artifact(info.session_id, ArtifactEvent::Info(info.clone()), None);
                Ok(ArtifactResponse::Info(info))
            }
            ArtifactRequest::SetPreview {
                artifact_id,
                version,
                png,
            } => {
                let info = self.visible_artifact(artifact_id)?;
                if version > info.version {
                    return Err(ArtifactError::NotFound(format!("version {version}")));
                }
                let (image, _) = art.read_blob(&png)?;
                let info = art.update(artifact_id, |info| {
                    info.preview = Some(proto::Preview { image, version });
                })?;
                if version == info.version {
                    art.checkpoint(artifact_id, self.actor, Some(image), None);
                }
                core.emit_artifact(info.session_id, ArtifactEvent::Info(info.clone()), None);
                Ok(ArtifactResponse::Info(info))
            }
            ArtifactRequest::Export {
                artifact_id,
                version,
                format,
            } => {
                self.visible_artifact(artifact_id)?;
                let core = Arc::clone(core);
                tokio::task::spawn_blocking(move || {
                    crate::art::export(&core.art, artifact_id, version, format)
                })
                .await
                .map_err(|error| ArtifactError::Failed(error.to_string()))?
                .map(ArtifactResponse::Exported)
            }
            ArtifactRequest::ExcalidrawGet { artifact_id, since } => {
                self.visible_artifact(artifact_id)?;
                art.ex_get(artifact_id, since)
                    .map(ArtifactResponse::Excalidraw)
            }
            ArtifactRequest::ExcalidrawPut(put) => {
                self.visible_artifact(put.artifact_id)?;
                let artifact_id = put.artifact_id;
                let applied = art.ex_put(put)?;
                if !applied.won.is_empty()
                    || applied.app_state.is_some()
                    || !applied.files.is_empty()
                {
                    core.emit_artifact(
                        applied.info.session_id,
                        ArtifactEvent::Excalidraw {
                            artifact_id,
                            version: applied.info.version,
                            elements: applied.won,
                            app_state: applied.app_state,
                            files: applied.files,
                        },
                        Some(self.id),
                    );
                }
                Ok(ArtifactResponse::ExcalidrawApplied {
                    artifact_id,
                    version: applied.info.version,
                    rejected: applied.lost,
                })
            }
            ArtifactRequest::Place(place) => {
                self.visible_artifact(place.artifact_id)?;
                if let Some(old) = place.replace {
                    let mine = art
                        .placement(old)
                        .is_some_and(|placement| self.pane_allowed(placement.pane_id));
                    if !mine {
                        return Err(ArtifactError::NotFound(format!("placement {old}")));
                    }
                }
                let core_handle = Arc::clone(core);
                let (placement, replaced) = tokio::task::spawn_blocking(move || {
                    crate::art::place::place(&core_handle, place, proto::PlacementSource::User)
                })
                .await
                .map_err(|error| ArtifactError::Failed(error.to_string()))??;
                // Finishing a drawing from the overlay records that version.
                if art
                    .info(placement.artifact_id)
                    .is_some_and(|info| info.version == placement.version)
                {
                    art.checkpoint(
                        placement.artifact_id,
                        self.actor,
                        Some(placement.image),
                        None,
                    );
                }
                if let Some(session) = core.session_of_pane(placement.pane_id) {
                    if let Some(old) = replaced {
                        core.emit_artifact(
                            session,
                            ArtifactEvent::Unplaced {
                                pane_id: old.pane_id,
                                placement_id: old.placement_id,
                            },
                            None,
                        );
                    }
                    core.emit_artifact(session, ArtifactEvent::Placed(placement.clone()), None);
                }
                Ok(ArtifactResponse::Placed(placement))
            }
            ArtifactRequest::Unplace { placement_id } => {
                let placement = art
                    .placement(placement_id)
                    .filter(|placement| self.pane_allowed(placement.pane_id))
                    .ok_or_else(|| ArtifactError::NotFound(format!("placement {placement_id}")))?;
                crate::art::place::unplace(core, placement_id);
                if let Some(session) = core.session_of_pane(placement.pane_id) {
                    core.emit_artifact(
                        session,
                        ArtifactEvent::Unplaced {
                            pane_id: placement.pane_id,
                            placement_id,
                        },
                        None,
                    );
                }
                Ok(ArtifactResponse::Done)
            }
            ArtifactRequest::Placements { pane_id } => {
                let _ = art.check_placements(core);
                Ok(ArtifactResponse::Placements(art.placements(pane_id)))
            }
            ArtifactRequest::Import(import) => {
                let (core_handle, actor) = (Arc::clone(core), self.actor);
                let (placement, info) = tokio::task::spawn_blocking(move || {
                    crate::art::place::import(&core_handle, actor, import)
                })
                .await
                .map_err(|error| ArtifactError::Failed(error.to_string()))??;
                core.emit_artifact(info.session_id, ArtifactEvent::Created(info.clone()), None);
                core.emit_artifact(
                    info.session_id,
                    ArtifactEvent::Placed(placement.clone()),
                    None,
                );
                Ok(ArtifactResponse::Placed(placement))
            }
            ArtifactRequest::Send(send) => {
                if let Some(id) = send.artifact_id {
                    self.visible_artifact(id)?;
                }
                let pane_id = send.pane_id;
                core.mp
                    .admit_prompt(&self.authz, self.ws.owner)
                    .map_err(|error| ArtifactError::Failed(error.to_string()))?;
                let (sent, events) = crate::art::send::send(core, self.actor, send).await?;
                for event in events {
                    if let ArtifactEvent::Created(info) = &event {
                        core.emit_artifact(info.session_id, event.clone(), None);
                    }
                }
                core.mp.audit.append(
                    AuditKind::Prompt,
                    crate::mp::AuditEntry {
                        pane_id: Some(pane_id),
                        detail: format!(
                            "sent artifact {} v{} to the agent as {}",
                            sent.artifact_id, sent.version, sent.path
                        ),
                        ..self.authz.audit()
                    },
                );
                Ok(ArtifactResponse::Sent(sent))
            }
            ArtifactRequest::History { artifact_id } => {
                self.visible_artifact(artifact_id)?;
                art.history(artifact_id).map(ArtifactResponse::History)
            }
            ArtifactRequest::Restore {
                artifact_id,
                version,
            } => self.restore(artifact_id, version).await,
        }
    }

    /// Brings a drawing back to `version` as a new version: the content goes out like any
    /// edit (open editors and caches converge), the result is recorded in the history, and
    /// every placement shows that version's render.
    async fn restore(
        &self,
        artifact_id: proto::ArtifactId,
        version: u64,
    ) -> Result<ArtifactResponse, ArtifactError> {
        let core = &self.core;
        let art = &core.art;
        self.visible_artifact(artifact_id)?;
        let restored = art.history_entry(artifact_id, version)?;
        let info = match art.restore_plan(artifact_id, version)? {
            crate::art::history::RestorePlan::Excalidraw(put) => {
                let applied = art.ex_put(put)?;
                core.emit_artifact(
                    applied.info.session_id,
                    ArtifactEvent::Excalidraw {
                        artifact_id,
                        version: applied.info.version,
                        elements: applied.won,
                        app_state: applied.app_state,
                        files: applied.files,
                    },
                    None,
                );
                applied.info
            }
            crate::art::history::RestorePlan::Ops(ops) => {
                let (info, batch) = art.apply(artifact_id, self.actor, ops)?;
                core.emit_artifact(
                    info.session_id,
                    ArtifactEvent::Changed {
                        info: info.clone(),
                        batch,
                    },
                    None,
                );
                info
            }
        };
        // The old render shows the same content; without one the daemon renders it.
        let image = match restored.image {
            Some(image) => Some(image),
            None => {
                let core = Arc::clone(core);
                tokio::task::spawn_blocking(move || {
                    let export =
                        crate::art::export(&core.art, artifact_id, None, proto::ExportFormat::Png)
                            .ok()?;
                    match export.blob {
                        Some(hash) => core.art.read_blob(&hash).ok().map(|(image, _)| image),
                        None => core.art.put_blob(&export.data).ok(),
                    }
                })
                .await
                .ok()
                .flatten()
            }
        };
        let info = match image {
            Some(image) => art.update(artifact_id, |info| {
                info.preview = Some(proto::Preview {
                    image,
                    version: info.version,
                });
            })?,
            None => info,
        };
        core.emit_artifact(info.session_id, ArtifactEvent::Info(info.clone()), None);
        if let Some(image) = image {
            for placement in crate::art::place::reshow(core, artifact_id, info.version, image) {
                if let Some(session) = core.session_of_pane(placement.pane_id) {
                    core.emit_artifact(session, ArtifactEvent::Placed(placement), None);
                }
            }
        }
        let entry = art
            .checkpoint(artifact_id, self.actor, image, Some(version))
            .ok_or_else(|| ArtifactError::Failed("the restored version was not recorded".into()))?;
        Ok(ArtifactResponse::Restored {
            info,
            version: entry,
        })
    }

    /// Live ink: drawers only, on a visible drawing; stamped with the actor and fanned out to
    /// the session's other clients.
    fn ink(&self, mut ink: proto::InkLive) {
        let refuse = |reason: String| {
            self.send(ServerCtl::Forbidden {
                what: "InkLive".into(),
                reason,
            });
        };
        if let Err(error) = self.allow(Need::Draw, Target::Any) {
            return refuse(error.to_string());
        }
        let Ok(info) = self.visible_artifact(ink.artifact_id) else {
            return refuse(format!("no artifact {}", ink.artifact_id));
        };
        if ink.points.0.len() > 16 << 10 {
            return refuse("ink chunks are at most 16 KiB".into());
        }
        ink.actor = self.actor;
        self.core
            .emit_artifact(info.session_id, ArtifactEvent::Ink(ink), Some(self.id));
    }

    /// Creates the drawing a new canvas pane will show (`PaneLaunch::Canvas { None }`).
    fn prepare_canvas(
        &self,
        op: &mut proto::LayoutOp,
    ) -> Result<Option<proto::ArtifactId>, String> {
        use proto::LayoutOp as O;
        let (session, launch) = match op {
            O::Split {
                pane_id, launch, ..
            } => (self.core.session_of_pane(*pane_id), launch),
            O::NewTab {
                session_id, launch, ..
            } => (Some(*session_id), launch),
            O::CreateSession {
                launch: PaneLaunch::Canvas { .. },
                ..
            } => return Err("a new session starts with a terminal pane".into()),
            _ => return Ok(None),
        };
        let PaneLaunch::Canvas { artifact_id } = launch else {
            return Ok(None);
        };
        let session = session.ok_or("no such pane or session")?;
        if let Some(id) = artifact_id {
            let info = self
                .visible_artifact(*id)
                .map_err(|error| error.to_string())?;
            if info.session_id != session {
                return Err("the drawing belongs to another session".into());
            }
            return Ok(None);
        }
        let (info, _) = self
            .core
            .art
            .create(
                self.actor,
                &proto::ArtifactCreate {
                    session_id: session,
                    // Canvas panes host the Excalidraw editor (finger, mouse, trackpad).
                    kind: proto::ArtifactKind::Excalidraw,
                    title: String::new(),
                    space: proto::CoordSpace::Canvas,
                    anchor: None,
                    image: None,
                    ops: Vec::new(),
                },
                None,
            )
            .map_err(|error| error.to_string())?;
        *artifact_id = Some(info.artifact_id);
        self.core
            .emit_artifact(session, ArtifactEvent::Created(info.clone()), None);
        Ok(Some(info.artifact_id))
    }

    /// Ports of panes outside a scoped grant are hidden (host-wide ones too).
    fn scoped_ports(&self, mut ports: Vec<proto::PortInfo>) -> Vec<proto::PortInfo> {
        if self.authz.scope != Scope::Daemon {
            ports.retain(|port| port.pane_id.is_some_and(|pane| self.pane_allowed(pane)));
        }
        ports
    }

    fn send_pane_sizing(&self, pane_id: PaneId) {
        if !self.caps.contains(Caps::PANE_SIZING) {
            return;
        }
        let Some(state) = self.core.pane_sizing(pane_id) else {
            return;
        };
        if lock(&self.state).sent_sizing.insert(pane_id, state) != Some(state) {
            self.send(ServerCtl::PaneSizing(state));
        }
    }

    fn pane_metadata(&self, pane_id: PaneId) -> Option<proto::PaneMeta> {
        pane_metadata_for_client(&self.core, pane_id, self.caps)
    }

    fn view_changed(&self) {
        let panes = {
            let state = lock(&self.state);
            let mut panes = state.visible.clone();
            panes.extend(state.focus);
            panes
        };
        self.core.set_view(
            self.id,
            View {
                device: self.actor.device,
                viewer: self.ws.viewer,
                panes,
            },
            &self.authz,
        );
    }

    /// Runs a pane query off the async threads and sends its answer.
    fn query<T: Send + 'static>(
        self: &Arc<Self>,
        pane_id: PaneId,
        run: impl FnOnce(&crate::core::PaneEntry, &Core) -> Result<T, RpcError> + Send + 'static,
        answer: impl FnOnce(Result<T, RpcError>) -> ServerCtl + Send + 'static,
    ) {
        let client = Arc::clone(self);
        tokio::spawn(async move {
            let entry = client
                .core
                .pane(pane_id)
                .filter(|_| client.in_session(pane_id));
            let result = match entry {
                None => Err(RpcError::UnknownPane),
                Some(entry) => {
                    let core = Arc::clone(&client.core);
                    tokio::task::spawn_blocking(move || run(&entry, &core))
                        .await
                        .unwrap_or_else(|join_error| {
                            Err(RpcError::Internal(join_error.to_string()))
                        })
                }
            };
            client.send(answer(result));
        });
    }

    fn fetch_history(self: &Arc<Self>, pane_id: PaneId, snapshot_seq: Seq, offset: u64, max: u32) {
        let client = Arc::clone(self);
        tokio::spawn(async move {
            let pane = client
                .core
                .pane(pane_id)
                .filter(|_| client.in_session(pane_id))
                .map(|entry| Arc::clone(&entry.pane));
            let max = max.clamp(16 << 10, 2 << 20);
            let viewer = client.viewer(pane_id);
            let page = match pane {
                Some(pane) => tokio::task::spawn_blocking(move || {
                    pane.history_page(viewer, snapshot_seq, offset, max)
                })
                .await
                .ok()
                .flatten(),
                None => None,
            };
            let message = match page {
                Some(page) => Bulk::HistoryPage {
                    pane_id,
                    snapshot_seq,
                    offset,
                    next_offset: page.next_offset,
                    total_len: page.total_len,
                    raw_len: page.raw_len,
                    pages: page.pages,
                    done: page.done,
                    data: page.zstd,
                },
                None => Bulk::HistoryGone {
                    pane_id,
                    snapshot_seq,
                },
            };
            let mut bulk = client.bulk.lock().await;
            if bulk.is_none() {
                let Ok(mut stream) = client.conn.open_uni().await else {
                    return;
                };
                let _ = stream.set_priority(crate::stream::priority::BULK);
                if net::send(&mut stream, &StreamHeader::Bulk).await.is_err() {
                    return;
                }
                *bulk = Some(stream);
            }
            if let Some(stream) = bulk.as_mut()
                && let Err(error) = net::send(stream, &message).await
            {
                tracing::debug!("bulk stream: {error}");
                *bulk = None;
            }
        });
    }

    async fn handle_ctl(self: &Arc<Self>, message: ClientCtl) {
        // Every message is checked against the live grant table: a revoked or expired grant
        // ends the connection here, not at the next reconnect.
        if self.live().is_err() {
            return;
        }
        self.core.mp.heard(&self.core, self.id);
        match message {
            ClientCtl::Hello(_) => {}
            ClientCtl::TerminalColors(colors) => {
                // Only someone who may type into panes chooses what their programs are told,
                // and only someone with the whole host or session for panes nobody used.
                if self.allow(Need::Drive, Target::Any).is_ok()
                    && let Some(colors) = crate::theme::default_colors(&colors)
                {
                    let everywhere = self.allow(Need::Drive, Target::Host).is_ok();
                    self.core.theme_announced(self.id, colors, everywhere);
                }
            }
            ClientCtl::Peer(update) => {
                // Drafts are typed to be sent: the same roles as the composer path.
                let allowed = match &update {
                    proto::PeerUpdate::Draft(Some(draft)) => {
                        self.permit("Draft", Need::Prompt, Target::Pane(draft.pane_id))
                    }
                    proto::PeerUpdate::Viewport(Some(viewport)) => {
                        self.pane_allowed(viewport.pane_id)
                    }
                    _ => true,
                };
                if allowed {
                    self.core.mp.peer_update(&self.core, self.id, update);
                }
            }
            ClientCtl::Subscribe { pane_id, mode, .. } => {
                if self.permit("Subscribe", Need::View, Target::Pane(pane_id)) {
                    self.subscribe(pane_id, mode).await;
                } else {
                    self.send(ServerCtl::PaneClosed { pane_id });
                }
            }
            ClientCtl::Unsubscribe { pane_id } => {
                if let Some(subscription) = lock(&self.state).subscriptions.remove(&pane_id) {
                    subscription.task.abort();
                }
            }
            ClientCtl::Visible { mut pane_ids } => {
                pane_ids.retain(|&pane| self.pane_allowed(pane));
                lock(&self.state).visible = pane_ids;
                self.reclassify();
                self.view_changed();
            }
            ClientCtl::Focus { pane_id } => {
                let pane_id = pane_id.filter(|&pane| self.pane_allowed(pane));
                if let Some(pane) = pane_id {
                    crate::ws::pane_focused(&self.core, self.ws.viewer, pane);
                    // A quiet terminal stopped polling its modes: fresh ones before typing.
                    if let Some(entry) = self.core.pane(pane) {
                        entry.pane.pty().refresh_echo();
                        if self.allow(Need::Drive, Target::Pane(pane)).is_ok() {
                            self.core.theme_used(self.id, &entry);
                        }
                    }
                }
                lock(&self.state).focus = pane_id;
                self.core.mp.set_focus(&self.core, self.id, pane_id);
                self.reclassify();
                self.view_changed();
            }
            ClientCtl::FetchHistory {
                pane_id,
                snapshot_seq,
                offset,
                max_bytes,
            } => self.fetch_history(pane_id, snapshot_seq, offset, max_bytes),
            ClientCtl::Search {
                req_id,
                pane_id,
                query,
                cursor,
                limit,
            } => {
                let viewer = self.viewer(pane_id);
                self.query(
                    pane_id,
                    move |entry, _| entry.pane.search(viewer, &query, cursor, limit),
                    move |result| ServerCtl::SearchResult {
                        req_id,
                        pane_id,
                        result,
                    },
                )
            }
            ClientCtl::Links {
                req_id,
                pane_id,
                commands,
            } => {
                let viewer = self.viewer(pane_id);
                self.query(
                    pane_id,
                    move |entry, core| {
                        let cwd = lock(&entry.meta).cwd.clone().map(std::path::PathBuf::from);
                        let home = core.cfg.pane_var("HOME").map(std::path::PathBuf::from);
                        Ok(entry
                            .pane
                            .links(viewer, commands, cwd.as_deref(), home.as_deref()))
                    },
                    move |result| ServerCtl::LinksResult {
                        req_id,
                        pane_id,
                        result,
                    },
                )
            }
            ClientCtl::Commands { req_id, pane_id } => {
                let viewer = self.viewer(pane_id);
                self.query(
                    pane_id,
                    move |entry, _| Ok(entry.pane.commands(viewer)),
                    move |result| ServerCtl::CommandsResult {
                        req_id,
                        pane_id,
                        result,
                    },
                )
            }
            ClientCtl::CommandOutput {
                req_id,
                pane_id,
                command_id,
            } => {
                let viewer = self.viewer(pane_id);
                self.query(
                    pane_id,
                    move |entry, _| entry.pane.command_output(viewer, command_id),
                    move |result| ServerCtl::CommandOutputResult {
                        req_id,
                        pane_id,
                        result,
                    },
                )
            }
            ClientCtl::Resize { pane_id, size } => {
                if !self.pane_allowed(pane_id) {
                    return;
                }
                lock(&self.state).sizes.insert(pane_id, size);
                let sizes_pty = self.allow(Need::Drive, Target::Pane(pane_id)).is_ok();
                if sizes_pty && let Some(entry) = self.core.pane(pane_id) {
                    self.core
                        .apply_client_size(&entry, self.id, &self.authz, size, false);
                }
            }
            ClientCtl::Ack { pane_id, seq } => {
                if let Some(subscription) = lock(&self.state).subscriptions.get(&pane_id) {
                    subscription.acks.send_replace(seq);
                }
            }
            ClientCtl::Decide(decide) => self.decide(decide),
            ClientCtl::LeaseRequest { pane_id, kind } => {
                let force = kind == LeaseRequestKind::Force;
                match self
                    .core
                    .mp
                    .take_control(&self.core, self.id, &self.authz, pane_id, force)
                {
                    Ok(_) => self.send(ServerCtl::Lease(self.core.mp.lease(pane_id))),
                    Err(error) => self.send(ServerCtl::Forbidden {
                        what: "LeaseRequest".into(),
                        reason: error.to_string(),
                    }),
                }
            }
            ClientCtl::SetSizePolicy { pane_id, policy } => {
                let allowed = self.allow(Need::Drive, Target::Pane(pane_id));
                if let Err(error) = allowed {
                    self.send(ServerCtl::Forbidden {
                        what: "SetSizePolicy".into(),
                        reason: error.to_string(),
                    });
                    return;
                }
                if !self.core.mp.may_size(pane_id, self.actor.principal) {
                    self.send(ServerCtl::Forbidden {
                        what: "SetSizePolicy".into(),
                        reason: "another principal holds the input lease".into(),
                    });
                    return;
                }
                if let Some(entry) = self.core.pane(pane_id)
                    && let Err(error) = self.core.set_size_policy(&entry, policy)
                {
                    self.send(ServerCtl::Forbidden {
                        what: "SetSizePolicy".into(),
                        reason: error.to_string(),
                    });
                }
            }
            ClientCtl::PaneActivity { pane_id, activity } => {
                if self.allow(Need::Drive, Target::Pane(pane_id)).is_ok()
                    && let Some(entry) = self.core.pane(pane_id)
                {
                    self.core
                        .pane_activity(&entry, self.id, &self.authz, activity);
                }
            }
            ClientCtl::WatchRunAgain => {
                if is_owner(&self.core, &self.authz) {
                    lock(&self.state).watches_run_again = true;
                    self.send(ServerCtl::RunAgainOffers(self.core.run_again_offers()));
                }
            }
            ClientCtl::ClaimSize { pane_id } => {
                if self.allow(Need::Drive, Target::Pane(pane_id)).is_ok()
                    && let Some(entry) = self.core.pane(pane_id)
                {
                    self.core.claim_client_size(&entry, self.id);
                }
            }
            ClientCtl::Presence(presence) => {
                if presence.actor == self.actor {
                    self.core.mp.presence(&self.core, self.id, presence);
                }
            }
            ClientCtl::Ping { nonce } => self.send(ServerCtl::Pong { nonce }),
            ClientCtl::Bye { .. } => {}
            ClientCtl::ListSessions => {
                self.send(self.core.sessions_message(self.authz.scope));
            }
            ClientCtl::Attach { session_id } => self.attach(session_id),
            ClientCtl::Workspace { req_id, req } => {
                let client = Arc::clone(self);
                tokio::spawn(async move {
                    let permit = if crate::timeline::bulk_request(&req) {
                        match client.ws.timeline_mailbox.reserve_reply() {
                            Ok(permit) => Some(permit),
                            Err(error) => {
                                client.send(ServerCtl::WorkspaceResult {
                                    req_id,
                                    result: Err(error),
                                });
                                return;
                            }
                        }
                    } else {
                        None
                    };
                    let result = client.workspace(req).await;
                    if let Some(permit) = permit
                        && crate::timeline::bulk_reply(&result)
                    {
                        client.ws.timeline_mailbox.hold_reply(req_id, permit);
                    }
                    client.send(ServerCtl::WorkspaceResult { req_id, result });
                });
            }
            ClientCtl::Multiplayer { req_id, req } => {
                let client = Arc::clone(self);
                tokio::spawn(async move {
                    let result = client.multiplayer(req).await;
                    client.send(ServerCtl::MultiplayerResult { req_id, result });
                });
            }
            ClientCtl::Artifact { req_id, req } => {
                let client = Arc::clone(self);
                tokio::spawn(async move {
                    let result = client.artifact(req).await;
                    client.send(ServerCtl::ArtifactResult { req_id, result });
                });
            }
            ClientCtl::InkLive(ink) => self.ink(ink),
            ClientCtl::Assist { req_id, req } => {
                let client = Arc::clone(self);
                tokio::spawn(async move {
                    let result = client.assist(req).await;
                    client.send(ServerCtl::AssistResult { req_id, result });
                });
            }
            ClientCtl::Approval { req_id, req } => {
                let result = self.approval(req);
                self.send(ServerCtl::ApprovalResult { req_id, result });
            }
            ClientCtl::BrowserResult { id, result } => {
                self.core.browser.answer(self.id, id, result);
            }
            ClientCtl::Askpass { req_id, req } => {
                let client = Arc::clone(self);
                tokio::spawn(async move {
                    let result = crate::askpass::request(&client.core, &client.authz, req).await;
                    client.send(ServerCtl::AskpassResult { req_id, result });
                });
            }
            ClientCtl::Op { op_id, mut op } => {
                let (need, target) = policy::op(&op);
                let allowed = self.allow(need, target).and_then(|()| {
                    // A delegated owner role is still a guest: the sign-ins are the owner's.
                    if policy::chooses_account(&op) && !is_owner(&self.core, &self.authz) {
                        Err(MpError::Forbidden(
                            "only the host's owner chooses its agent accounts".into(),
                        ))
                    } else {
                        Ok(())
                    }
                });
                let outcome = match allowed {
                    Ok(()) => match self.prepare_canvas(&mut op) {
                        Ok(created) => {
                            let outcome = Arc::clone(&self.core).apply_op(op);
                            if let (Some(id), proto::OpOutcome::Failed { .. }) = (created, &outcome)
                            {
                                let _ = self.core.art.delete(id);
                            }
                            outcome
                        }
                        Err(message) => proto::OpOutcome::Failed {
                            code: proto::OpError::Invalid,
                            message,
                        },
                    },
                    Err(error) => proto::OpOutcome::Failed {
                        code: proto::OpError::Forbidden,
                        message: error.to_string(),
                    },
                };
                // Send this client's layout first so the result never precedes it.
                let session = lock(&self.state).session;
                if let Some(layout) =
                    session.and_then(|session| self.core.layout_for(session, self.authz.scope))
                {
                    self.send_layout(layout);
                }
                self.send(ServerCtl::OpResult { op_id, outcome });
            }
        }
    }

    /// An approval decision: approver role on the request's pane, a valid signature by the
    /// deciding device, first valid decision wins, recorded in the audit log.
    fn decide(&self, decide: proto::Decide) {
        let refuse = |reason: String| {
            self.send(ServerCtl::Forbidden {
                what: "Decide".into(),
                reason,
            });
        };
        if decide.actor != self.actor {
            return refuse("the decision's actor is not this connection".into());
        }
        let Some(pane) = self.core.request_pane(decide.request_id) else {
            return refuse("no such approval request".into());
        };
        if let Err(error) = self.allow(Need::Approve, Target::Pane(pane)) {
            return refuse(error.to_string());
        }
        // Letting an agent drive the user's panes is the owner's call alone, never a guest's.
        let drive = self.core.term.asks.caller_of(decide.request_id).is_some();
        if drive && !is_owner(&self.core, &self.authz) {
            self.core.mp.audit.append(
                AuditKind::Denied,
                crate::mp::AuditEntry {
                    pane_id: Some(pane),
                    detail: format!(
                        "a guest tried to answer drive request {}",
                        decide.request_id
                    ),
                    ..self.authz.audit()
                },
            );
            return refuse("only the owner may let an agent drive their panes".into());
        }
        let daemon = self.core.identity.daemon_id();
        if !grants::verify_approval(daemon, &decide) {
            self.core.mp.audit.append(
                AuditKind::Denied,
                crate::mp::AuditEntry {
                    pane_id: Some(pane),
                    detail: format!("unsigned or badly signed decision on {}", decide.request_id),
                    ..self.authz.audit()
                },
            );
            return refuse("the decision is not signed by this device".into());
        }
        let name = self.core.mp.name_of(self.id);
        let signature = decide.sig.clone();
        let signed_bytes = proto::approval_signing_bytes(
            daemon,
            decide.request_id,
            decide.option_id,
            decide.actor,
        );
        let ballot = crate::mp::approvals::Ballot {
            actor: self.actor,
            name: &name,
            owner: is_owner(&self.core, &self.authz),
            authorization: Some(&self.authz),
        };
        // Approval policies are for agents' own tool calls; a drive request is the owner's.
        let gate = if drive {
            Ok(crate::mp::Gate::Proceed)
        } else {
            crate::mp::gate_decision(
                &self.core,
                ballot,
                decide.request_id,
                decide.option_id,
                (signed_bytes, signature.clone()),
            )
        };
        match gate {
            Ok(crate::mp::Gate::Proceed) => {}
            Ok(crate::mp::Gate::Held) => return,
            Err(error) => return refuse(error.to_string()),
        }
        let record = |decided: &proto::Decided, details: &crate::agent::DecidedRequest| {
            self.answered(decided.pane_id, &details.option, &details.summary);
            let signed = proto::approval_signing_bytes(
                daemon,
                decide.request_id,
                decide.option_id,
                decide.actor,
            );
            self.core.mp.audit.append(
                AuditKind::Approval,
                crate::mp::AuditEntry {
                    pane_id: Some(decided.pane_id),
                    detail: format!("{name} chose {:?} for {}", details.option, details.summary),
                    approval: Some(proto::ApprovalAudit {
                        request_id: decide.request_id,
                        agent_request: details.request.to_string(),
                        option_id: decide.option_id,
                        option: details.option.clone(),
                        tool: details.tool.clone(),
                        summary: details.summary.clone(),
                        signed,
                        sig: signature,
                    }),
                    ..self.authz.audit()
                },
            );
        };
        match self.core.decide_authorized(
            self.actor,
            &decide,
            None,
            Some(crate::agent_driver::ApprovalEvidence::Device(&self.authz)),
            record,
        ) {
            Ok(_) => self.core.mp.approvals.forget(decide.request_id),
            Err(Some(by)) => self.send(ServerCtl::AlreadyDecided {
                request_id: decide.request_id,
                by,
            }),
            Err(None) => refuse("the request is no longer open".into()),
        }
    }

    /// A workspace request, gated by the policy table and filtered to the scope.
    async fn workspace(&self, request: WorkspaceRequest) -> Result<WorkspaceResponse, WsError> {
        let (need, target) = policy::workspace(&request);
        self.allow(need, target)
            .map_err(|error| WsError::Denied(error.to_string()))?;
        if matches!(request, WorkspaceRequest::SendReview(_)) {
            self.core
                .mp
                .admit_prompt(&self.authz, self.ws.owner)
                .map_err(|error| WsError::Failed(error.to_string()))?;
        }
        // A prompter may review an agent's turns and send it notes, but only into an agent
        // that holds the terminal as they are written, and only under the standard opening
        // line: how a prompt starts decides whether the agent takes it as a shell command or
        // one of its own commands.
        if let WorkspaceRequest::SendReview(review) = &request
            && self
                .allow(Need::Drive, Target::Pane(review.pane_id))
                .is_err()
        {
            return crate::ws::review::send(
                &self.core,
                review.pane_id,
                None,
                &review.notes,
                review.submit,
                true,
            )
            .await
            .map(|prompt| WorkspaceResponse::ReviewSent { prompt });
        }
        let result = crate::ws::handle(&self.core, &self.ws, request).await?;
        Ok(match result {
            WorkspaceResponse::Ports(ports) => WorkspaceResponse::Ports(self.scoped_ports(ports)),
            WorkspaceResponse::Attention(mut list) if self.authz.scope != Scope::Daemon => {
                list.items.retain(|item| self.pane_allowed(item.pane_id));
                list.unseen = list.items.iter().filter(|item| !item.seen).count() as u32;
                WorkspaceResponse::Attention(list)
            }
            other => other,
        })
    }

    /// An input-assistance request, gated by the policy table and the pane's scope.
    async fn assist(
        &self,
        request: proto::AssistRequest,
    ) -> Result<proto::AssistResponse, proto::AssistError> {
        let (need, target) = policy::assist(&request);
        self.allow(need, target)
            .map_err(|error| proto::AssistError::Denied(error.to_string()))?;
        if let Some(pane) = policy::assist_pane(&request)
            && !self.pane_allowed(pane)
        {
            return Err(proto::AssistError::UnknownPane);
        }
        let audit = match &request {
            proto::AssistRequest::AnswerBlocked(answer) => {
                Some((answer.pane_id, answer.label.clone()))
            }
            _ => None,
        };
        if let Some((pane, _)) = &audit {
            self.screen_answer_allowed(*pane)
                .map_err(|error| proto::AssistError::Denied(error.to_string()))?;
        }
        let caller = crate::assist::Caller {
            conn: self.id,
            actor: self.actor,
        };
        let asked = audit
            .as_ref()
            .and_then(|(pane, _)| self.blocker_summary(*pane));
        let result = crate::assist::handle(&self.core, caller, request).await;
        if let (Some((pane, label)), Ok(_)) = (audit, &result) {
            self.answered(pane, &label, asked.as_deref().unwrap_or_default());
            let name = self.core.mp.name_of(self.id);
            self.core.mp.audit.append(
                AuditKind::Approval,
                crate::mp::AuditEntry {
                    pane_id: Some(pane),
                    detail: format!("{name} chose {label:?} on screen"),
                    ..self.authz.audit()
                },
            );
        }
        result
    }

    /// Tells the owner's devices (and their pushes) that someone else answered an agent's
    /// request, whatever they have seen: no guest answers for the owner unnoticed.
    fn answered(&self, pane_id: PaneId, answer: &str, summary: &str) {
        if self.ws.owner {
            return;
        }
        self.core
            .emit(crate::core::Event::GuestAnswered(proto::GuestAnswer {
                pane_id,
                by: self.actor,
                name: self.core.mp.name_of(self.id),
                answer: answer.to_owned(),
                summary: summary.to_owned(),
                at: proto::UnixMillis(crate::identity::now_millis()),
            }));
    }

    /// What the agent in `pane` is blocked on, as its status says.
    fn blocker_summary(&self, pane: PaneId) -> Option<String> {
        match self.core.pane_meta(pane)?.agent?.state {
            proto::AgentState::Blocked(blocker) => Some(blocker.summary),
            _ => None,
        }
    }

    /// Whether this connection may answer a dialog read off a pane's screen under the
    /// session's approval policy (a screen answer has no request id or tool, so the
    /// policy's stricter rules keep it to owners).
    fn screen_answer_allowed(&self, pane: PaneId) -> Result<(), MpError> {
        let owner = is_owner(&self.core, &self.authz);
        let policy = self.core.mp.policy_of_pane(&self.core, pane);
        crate::mp::approvals::screen_answer(policy, owner)?;
        if policy.mode == proto::ApprovalMode::Claim
            && !owner
            && let Some(claim) = self.core.mp.approvals.claimant_on(pane)
            && claim.actor.principal != self.actor.principal
        {
            return Err(MpError::Conflict(format!(
                "{} claimed this request",
                claim.name
            )));
        }
        Ok(())
    }

    /// Claims an open approval request (or releases a claim), and withdraws its attention
    /// item so nobody else is notified about it.
    fn claim(&self, request: proto::RequestId, claim: bool) -> Result<MpResponse, MpError> {
        let (pane, facts) = self
            .core
            .request_facts(request, None)
            .ok_or_else(|| MpError::NotFound("the request is no longer open".into()))?;
        self.allow(Need::Approve, Target::Pane(pane))?;
        let mp = &self.core.mp;
        let policy = mp.policy_of_pane(&self.core, pane);
        let name = mp.name_of(self.id);
        let ballot = crate::mp::approvals::Ballot {
            actor: self.actor,
            name: &name,
            owner: is_owner(&self.core, &self.authz),
            authorization: Some(&self.authz),
        };
        let risk = proto::Risk::of_tool(facts.tool.as_deref());
        let status = mp
            .approvals
            .claim(policy, pane, request, risk, ballot, claim)?;
        mp.audit.append(
            AuditKind::Claim,
            crate::mp::AuditEntry {
                pane_id: Some(pane),
                detail: if claim {
                    format!("{name} claimed {}", facts.summary)
                } else {
                    format!("{name} released {}", facts.summary)
                },
                ..self.authz.audit()
            },
        );
        if claim {
            crate::ws::agent_unblocked(&self.core, pane);
        }
        self.core
            .emit(crate::core::Event::ApprovalStatus(status.clone()));
        Ok(MpResponse::Approval(status))
    }

    /// Paired owner devices only: a guest, whatever roles its grant carries, never makes
    /// another device an owner.
    fn require_owner_device(&self, action: &str) -> Result<(), MpError> {
        self.allow(Need::Own, Target::Daemon)?;
        if !is_owner(&self.core, &self.authz) {
            return Err(MpError::Forbidden(format!(
                "only the host's own devices can {action}"
            )));
        }
        Ok(())
    }

    async fn multiplayer(&self, request: MpRequest) -> Result<MpResponse, MpError> {
        let core = &self.core;
        let mp = &core.mp;
        match request {
            MpRequest::WhoAmI => Ok(MpResponse::Me(self.authz.join_info(&mp.name_of(self.id)))),
            MpRequest::Participants => {
                Ok(MpResponse::Participants(mp.participants(core, &self.authz)))
            }
            MpRequest::SetName { name } => {
                mp.set_name(core, self.id, name);
                Ok(MpResponse::Done)
            }
            MpRequest::RegisterGrant(chain) => mp
                .register(core, &self.authz, &chain, proto::InviteTerms::default())
                .map(MpResponse::Grant),
            MpRequest::RegisterInvite { chain, terms } => mp
                .register(core, &self.authz, &chain, terms)
                .map(MpResponse::Grant),
            MpRequest::Knocks => {
                self.allow(Need::Own, Target::Daemon)?;
                Ok(MpResponse::Knocks(mp.knocks()))
            }
            MpRequest::AnswerKnock { knock_id, admit } => {
                self.allow(Need::Own, Target::Daemon)?;
                mp.answer_knock(core, &self.authz, knock_id, admit)
            }
            MpRequest::GetApprovalPolicy { session_id } => {
                self.allow(Need::View, Target::Session(session_id))?;
                Ok(MpResponse::ApprovalPolicy(mp.policy(session_id)))
            }
            MpRequest::SetApprovalPolicy { session_id, policy } => {
                self.allow(Need::Own, Target::Session(session_id))?;
                if !is_owner(core, &self.authz) {
                    return Err(MpError::Forbidden(
                        "only the host's owner sets approval rules".into(),
                    ));
                }
                if lock(&core.layout).session(session_id).is_none() {
                    return Err(MpError::NotFound(format!("session {session_id}")));
                }
                Ok(MpResponse::ApprovalPolicy(mp.set_policy(
                    core,
                    &self.authz,
                    session_id,
                    policy,
                )))
            }
            MpRequest::Claim { request_id, claim } => self.claim(request_id, claim),
            MpRequest::ListGrants => {
                self.allow(Need::Own, Target::Daemon)?;
                Ok(MpResponse::Grants(mp.list_grants()))
            }
            MpRequest::InviteLink(id) => {
                self.allow(Need::Own, Target::Daemon)?;
                mp.invite_link(id)
            }
            MpRequest::ListDevices => {
                self.allow(Need::Own, Target::Daemon)?;
                Ok(MpResponse::Devices(mp.list_devices(core)))
            }
            MpRequest::PairingTicket => {
                self.require_owner_device("pair a device")?;
                mp.pairing_ticket(core, &self.authz)
            }
            MpRequest::RenameDevice { device, name } => {
                self.require_owner_device("rename a device")?;
                mp.rename_device(core, device, &name)
            }
            MpRequest::Revoke(target) => {
                self.allow(Need::Own, Target::Daemon)?;
                mp.revoke(core, &self.authz, target)
            }
            MpRequest::Audit(query) => {
                self.allow(Need::Own, Target::Daemon)?;
                let mut page = mp.audit.query(query);
                page.chain_ok = page.chain_ok && mp.audit.verify_file();
                Ok(MpResponse::Audit(page))
            }
            MpRequest::TakeControl { pane_id, force } => mp
                .take_control(core, self.id, &self.authz, pane_id, force)
                .map(MpResponse::Lease),
            MpRequest::ReleaseControl { pane_id } => mp
                .release_control(core, &self.authz, pane_id)
                .map(|()| MpResponse::Done),
            MpRequest::AnswerControl { pane_id, give } => mp
                .answer_control(core, &self.authz, pane_id, give)
                .map(MpResponse::Lease),
            MpRequest::GiveControl { pane_id, to } => mp
                .give_control(core, &self.authz, pane_id, to)
                .map(MpResponse::Lease),
            MpRequest::Leases => Ok(MpResponse::Leases(
                mp.leases()
                    .into_iter()
                    .filter(|lease| self.pane_allowed(lease.pane_id))
                    .collect(),
            )),
            MpRequest::Prompt {
                pane_id,
                text,
                submit,
            } => self.prompt(pane_id, text, submit).await,
        }
    }

    /// The composer path: sanitized text into an agent pane as a bracketed paste,
    /// then Enter. Not leased: prompts from several people interleave per message, never per
    /// keystroke.
    async fn prompt(
        &self,
        pane_id: PaneId,
        text: String,
        submit: bool,
    ) -> Result<MpResponse, MpError> {
        self.allow(Need::Prompt, Target::Pane(pane_id))?;
        let entry = self
            .core
            .pane(pane_id)
            .ok_or_else(|| MpError::NotFound(format!("pane {pane_id}")))?;
        crate::mp::prompt::check(&text).map_err(|error| MpError::Invalid(error.to_string()))?;
        let write = |bytes| {
            crate::agent_input::enqueue(&self.core, pane_id, bytes).map_err(|error| match error {
                crate::agent_input::EnqueueError::Unavailable => MpError::Forbidden(
                    "prompts go to agent panes only, with a live input fence; use Terminal or relaunch it".into(),
                ),
                crate::agent_input::EnqueueError::Busy => MpError::Invalid(
                    "agent input is busy or closed; retry from Terminal".into(),
                ),
            })
        };
        self.core.mp.admit_prompt(&self.authz, self.ws.owner)?;
        let bytes = entry.pane.encode_input(InputPayload::Paste(text.clone()));
        write(bytes)?;
        if submit {
            // Let the agent's input box take the paste before Enter arrives.
            tokio::time::sleep(std::time::Duration::from_millis(80)).await;
            write(b"\r".to_vec())?;
        }
        let digest = grants::sha256(&[text.as_bytes()]);
        self.core.mp.audit.append(
            AuditKind::Prompt,
            crate::mp::AuditEntry {
                pane_id: Some(pane_id),
                detail: format!(
                    "prompt of {} chars, sha256 {}",
                    text.chars().count(),
                    crate::fsutil::hex(&digest[..8])
                ),
                ..self.authz.audit()
            },
        );
        Ok(MpResponse::Prompted {
            chars: text.chars().count() as u32,
        })
    }

    /// Answers an `Attach` that found nothing to attach to. Clients without
    /// [`Caps::ATTACH_RESULT`] get the older failed `OpResult` with op id 0.
    fn attach_failed(&self, code: proto::OpError, message: String) {
        self.send(if self.caps.contains(Caps::ATTACH_RESULT) {
            ServerCtl::AttachResult(Err(AttachFailure { code, message }))
        } else {
            ServerCtl::OpResult {
                op_id: 0,
                outcome: proto::OpOutcome::Failed { code, message },
            }
        });
    }

    fn attach(&self, requested: Option<SessionId>) {
        let scope = self.authz.scope;
        let exists = requested.is_some_and(|session| {
            let known = lock(&self.core.layout).session(session).is_some();
            known && self.core.session_visible(session, scope)
        });
        // A requested session that is gone falls back like `None` does, so a client that
        // remembered a closed session still lands somewhere (it is told which one).
        let missing = requested.filter(|_| !exists);
        let (session, via) = if let Some(session) = requested.filter(|_| exists) {
            (session, AttachVia::Requested)
        } else if let Some(session) = self.core.recent_session_in(scope) {
            (session, AttachVia::MostRecent)
        } else if self.allow(Need::Own, Target::Daemon).is_err() {
            self.attach_failed(
                proto::OpError::NotFound,
                "nothing to attach to in this grant's scope".into(),
            );
            return;
        } else {
            match self
                .core
                .create_session(String::new(), PaneLaunch::Shell { cwd: None })
            {
                Ok((session, _, _)) => (session, AttachVia::Created),
                Err((code, message)) => {
                    self.attach_failed(code, message);
                    return;
                }
            }
        };
        if let Some(gone) = missing {
            tracing::info!(conn = %self.id, requested = %gone, attached = %session, "requested session is gone; attached another");
        }
        {
            let mut state = lock(&self.state);
            state.session = Some(session);
            // A client may drop what it knew about another session's panes.
            state.sent_meta.clear();
            state.sent_sizing.clear();
        }
        self.core.attach(self.id, session);
        self.send(if self.caps.contains(Caps::ATTACH_RESULT) {
            ServerCtl::AttachResult(Ok(Attachment {
                session_id: session,
                via,
                missing,
            }))
        } else {
            ServerCtl::Attached {
                session_id: session,
            }
        });
        let Some(layout) = self.core.layout_for(session, scope) else {
            return;
        };
        let panes: Vec<PaneId> = layout
            .tabs
            .iter()
            .flat_map(|tab| crate::layout::leaves(&tab.root).collect::<Vec<_>>())
            .collect();
        self.send_layout(layout);
        for pane in panes {
            if let Some(meta) = self.pane_metadata(pane) {
                self.send(ServerCtl::PaneMeta(meta));
            }
            self.send_pane_sizing(pane);
            if let Some(hint) = self.core.echo_hint(pane) {
                self.send(ServerCtl::EchoHintAt(hint));
            }
            let lease = self.core.mp.lease(pane);
            if lease.holder.is_some() {
                self.send(ServerCtl::Lease(lease));
            }
            self.askpass_state(pane);
            // `None` too: a report cleared while another session was attached.
            if self.caps.contains(Caps::PROGRAM_STATUS) {
                self.send(ServerCtl::ProgramStatus {
                    pane_id: pane,
                    status: self.core.program_report(pane),
                });
            }
        }
        self.drive_state();
        self.send(ServerCtl::Participants {
            participants: self.core.mp.participants(&self.core, &self.authz),
        });
        if self.caps.contains(Caps::APPROVAL_POLICY) {
            let mp = &self.core.mp;
            self.send(ServerCtl::ApprovalPolicy {
                session_id: session,
                policy: mp.policy(session),
            });
            for status in mp.approvals.all(|pane| mp.policy_of_pane(&self.core, pane)) {
                if self.pane_allowed(status.pane_id) {
                    self.send(ServerCtl::ApprovalStatus(status));
                }
            }
        }
        let canvases = self
            .core
            .art
            .canvases(session)
            .into_iter()
            .filter(|canvas| self.pane_allowed(canvas.pane_id))
            .collect();
        self.send(ServerCtl::Artifact(ArtifactEvent::Canvases {
            session_id: session,
            canvases,
        }));
        // Inline images in the session's panes: not part of Ghostty snapshots, so the
        // daemon hands them over itself on every attach (resume, reattach, new device).
        let _ = self.core.art.check_placements(&self.core);
        for pane in panes_of(&self.core, session, scope) {
            for placement in self.core.art.placements(pane) {
                self.send(ServerCtl::Artifact(ArtifactEvent::Placed(placement)));
            }
        }
    }

    fn reclassify(&self) {
        let state = lock(&self.state);
        for (pane, subscription) in &state.subscriptions {
            let _ = subscription.cmds.send(StreamCmd::Class(state.class(*pane)));
        }
    }

    async fn subscribe(self: &Arc<Self>, pane_id: PaneId, mode: SubscribeMode) {
        if mode == SubscribeMode::Meta {
            return;
        }
        if lock(&self.state).subscriptions.contains_key(&pane_id) {
            return;
        }
        let Some(entry) = self.core.pane(pane_id) else {
            self.send(ServerCtl::PaneClosed { pane_id });
            return;
        };
        let pane = Arc::clone(&entry.pane);
        pane.pty().refresh_echo();
        let viewer = self.viewer(pane_id);
        // A since-join guest never resumes from before its view opened: the ring would
        // replay output it must not see.
        let floor = viewer.map_or(Seq(0), |principal| pane.view_start(principal));
        let start = match lock(&self.state).resume.remove(&pane_id) {
            Some(point) if point.snap_gen == pane.snap_gen && point.last_seq >= floor => {
                Start::Resume(point.last_seq)
            }
            _ => Start::Snapshot,
        };
        let Ok(mut send) = self.conn.open_uni().await else {
            return;
        };
        let class = lock(&self.state).class(pane_id);
        let _ = send.set_priority(class.priority());
        if net::send(&mut send, &StreamHeader::Pane { pane_id })
            .await
            .is_err()
        {
            return;
        }
        let (acks, acks_rx) = watch::channel(Seq(0));
        let (cmds, cmds_rx) = mpsc::unbounded_channel();
        let stream = PaneStream {
            pane,
            send,
            conn: self.conn.clone(),
            acks: acks_rx,
            cmds: cmds_rx,
            class,
            link: self.link,
            one_shot: mode == SubscribeMode::Snapshot,
            viewer,
        };
        let task = tokio::spawn(async move {
            match stream.run(start).await {
                Ok(stats) => tracing::trace!(%pane_id, ?stats, "pane stream done"),
                Err(error) => tracing::debug!(%pane_id, "pane stream: {error}"),
            }
        });
        let mut state = lock(&self.state);
        // A view reported while the stream was opening reclassified the subscriptions before
        // this one was among them.
        let current = state.class(pane_id);
        if current != class {
            let _ = cmds.send(StreamCmd::Class(current));
        }
        state.subscriptions.insert(
            pane_id,
            Subscription {
                acks,
                cmds,
                task: task.abort_handle(),
            },
        );
    }
}

fn panes_of(core: &Core, session: SessionId, scope: Scope) -> Vec<PaneId> {
    core.layout_for(session, scope)
        .map(|layout| {
            layout
                .tabs
                .iter()
                .flat_map(|tab| crate::layout::leaves(&tab.root).collect::<Vec<_>>())
                .collect()
        })
        .unwrap_or_default()
}
