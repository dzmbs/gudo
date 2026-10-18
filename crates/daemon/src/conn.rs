//! One client connection: the handshake, `ctl`, `input`, pane streams and port forwards.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use iroh::endpoint::{Connection, RecvStream, SendStream};
use proto::{
    Actor, AuditKind, Bulk, ClientCtl, ClientInput, DeviceId, ForwardReply, Hello, InputPayload,
    InputRejectReason, LeaseRequestKind, MpError, MpRequest, MpResponse, PaneId, PaneLaunch,
    PaneSize, RefuseReason, ResumePoint, RpcError, Scope, Seq, ServerCtl, SessionId, SignedGrant,
    StreamHeader, SubscribeMode, TransferReply, WIRE_VERSION, Welcome, WorkspaceRequest,
    WorkspaceResponse, WsError,
};
use tokio::sync::{broadcast, mpsc, watch};
use tokio::task::{AbortHandle, JoinSet};

use crate::core::{ConnId, Core, Event, lock};
use crate::forward;
use crate::mp::{Authz, Need, Target, policy};
use crate::net::{self, NetError};
use crate::stream::{Class, PaneStream, Start, StreamCmd, priority};

struct Sub {
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
    subs: HashMap<PaneId, Sub>,
    resume: HashMap<PaneId, ResumePoint>,
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
    ctl: mpsc::UnboundedSender<ServerCtl>,
    state: Mutex<ConnState>,
    /// The connection's `bulk` stream, opened on first use.
    bulk: tokio::sync::Mutex<Option<SendStream>>,
    /// Directory watches and the push channel for workspace requests.
    ws: crate::ws::ConnCtx,
}

/// Serves one accepted connection until it closes.
pub(crate) async fn serve(core: Arc<Core>, conn: Connection) {
    let remote = conn.remote_id();
    match run(core, conn).await {
        Ok(()) => tracing::debug!(%remote, "client left"),
        Err(e) => tracing::debug!(%remote, "client connection ended: {e}"),
    }
}

async fn run(core: Arc<Core>, conn: Connection) -> Result<(), NetError> {
    let (mut ctl_tx, mut ctl_rx) = conn.accept_bi().await.map_err(conn_err)?;
    let _ = ctl_tx.set_priority(priority::CTL);
    let Some(ClientCtl::Hello(hello)) = net::recv(&mut ctl_rx).await? else {
        return Ok(());
    };
    let device = DeviceId(*conn.remote_id().as_bytes());
    let authz = match handshake(&core, &hello, device) {
        Ok(a) => a,
        Err(reason) => {
            net::send(&mut ctl_tx, &ServerCtl::Refused { reason }).await?;
            let _ = ctl_tx.finish();
            let _ = ctl_tx.stopped().await;
            return Ok(());
        }
    };

    let welcome = Welcome {
        daemon_id: core.identity.daemon_id(),
        session_epoch: core.epoch,
        roles: authz.roles,
        snapshot_format: u32::from(ghostty_vt::snapshot_format()),
        panes: core
            .pane_entries()
            .into_iter()
            .filter(|(id, _)| core.scope_within(Scope::Pane(*id), authz.scope))
            .filter_map(|(id, _)| core.pane_meta(id))
            .collect(),
        resume_token: proto::ResumeToken(core.epoch.0.to_le_bytes().to_vec()),
    };
    net::send(&mut ctl_tx, &ServerCtl::Welcome(welcome)).await?;

    let (ctl, ctl_out) = mpsc::unbounded_channel();
    let ws = crate::ws::ConnCtx {
        ctl: ctl.clone(),
        watches: Arc::default(),
    };
    let id = core.next_conn_id();
    let _ = ctl.send(ServerCtl::Joined(authz.join_info(&authz.name)));
    core.mp.join(&core, id, &authz, ctl.clone(), conn.clone());
    let client = Arc::new(Client {
        id,
        core: Arc::clone(&core),
        conn: conn.clone(),
        actor: authz.actor,
        authz,
        ctl,
        state: Mutex::new(ConnState::default()),
        bulk: tokio::sync::Mutex::new(None),
        ws,
    });
    core.client_connected(true);
    let mut tasks = JoinSet::new();
    tasks.spawn(write_ctl(ctl_tx, ctl_out));
    tasks.spawn(forward_events(Arc::clone(&client), core.events.subscribe()));
    tasks.spawn(accept_uni(Arc::clone(&client)));
    tasks.spawn(accept_bi(Arc::clone(&client)));

    // Resume: stream the panes the client already holds right away, in its order (focused
    let mut first = true;
    for point in hello
        .resume
        .into_iter()
        .filter(|p| client.pane_allowed(p.pane_id))
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
    for (_, sub) in lock(&client.state).subs.drain() {
        sub.task.abort();
    }
    core.detach(client.id);
    core.mp.leave(&core, client.id);
    core.client_connected(false);
    lock(&client.ws.watches).clear();
    result
}

fn conn_err(e: iroh::endpoint::ConnectionError) -> NetError {
    NetError::Frame(proto::FrameError::Io(std::io::Error::other(e)))
}

fn handshake(core: &Core, hello: &Hello, device: DeviceId) -> Result<Authz, RefuseReason> {
    if hello.device_id != device {
        return Err(RefuseReason::DeviceMismatch);
    }
    let format = u32::from(ghostty_vt::snapshot_format());
    if hello.snapshot_format != format {
        return Err(RefuseReason::SnapshotFormat { daemon: format });
    }
    let _ = WIRE_VERSION;
    if hello.grant.v == SignedGrant::CHAIN {
        return core
            .mp
            .redeem(core, device, hello.principal_id, &hello.grant.token);
    }
    if core.mp.device_revoked(device) {
        return Err(RefuseReason::Revoked);
    }
    let principal = core
        .identity
        .authorize(device, hello.principal_id, &hello.grant)?;
    let actor = Actor { principal, device };
    if hello.grant.v == SignedGrant::PAIRING {
        core.mp.audit.append(
            AuditKind::Paired,
            crate::mp::AuditEntry {
                actor: Some(actor),
                detail: "paired a new owner device".into(),
                ..crate::mp::AuditEntry::default()
            },
        );
    }
    Ok(Authz::owner(actor))
}

async fn write_ctl(mut send: SendStream, mut out: mpsc::UnboundedReceiver<ServerCtl>) {
    let mut buf = Vec::new();
    while let Some(msg) = out.recv().await {
        buf.clear();
        let mut next = Some(msg);
        // Coalesce whatever is queued into one write.
        while let Some(msg) = next {
            if let Err(e) = proto::frame::encode(&msg, &mut buf) {
                tracing::warn!("encoding ctl message: {e}");
            }
            next = out.try_recv().ok();
        }
        if send.write_all(&buf).await.is_err() {
            return;
        }
    }
}

async fn read_ctl(client: &Arc<Client>, mut rx: RecvStream) -> Result<(), NetError> {
    while let Some(msg) = net::recv::<ClientCtl>(&mut rx).await? {
        client.handle_ctl(msg).await;
    }
    Ok(())
}

async fn forward_events(client: Arc<Client>, mut events: broadcast::Receiver<Event>) {
    loop {
        match events.recv().await {
            Ok(event) => client.forward(event),
            Err(broadcast::error::RecvError::Lagged(_)) => {
                client.send(client.core.sessions_message(client.authz.scope));
                let session = lock(&client.state).session;
                if let Some(s) = session {
                    client.forward(Event::Layout(s));
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
                    if let Err(e) = read_input(&client, stream).await {
                        tracing::debug!("input stream: {e}");
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
        // daemon- or session-wide grant (docs/DAEMON.md §6.3).
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
            && let Err(e) = client
                .live()
                .and_then(|()| client.allow(Need::Drive, Target::Host))
        {
            let _ = match header {
                Ok(Some(StreamHeader::Upload(_) | StreamHeader::Download(_))) => {
                    let reply = TransferReply::Failed(WsError::Denied(e.to_string()));
                    net::send(&mut send, &reply).await
                }
                _ => {
                    let reply = ForwardReply::Refused {
                        reason: e.to_string(),
                    };
                    net::send(&mut send, &reply).await
                }
            };
            let _ = send.finish();
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
        // path (`MpRequest::Prompt`).
        if let Err(e) = client.allow(Need::Drive, Target::Pane(input.pane_id)) {
            client.send(reject(InputRejectReason::Role));
            client.send(ServerCtl::Forbidden {
                what: "Input".into(),
                reason: e.to_string(),
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
        let bytes = match input.payload {
            InputPayload::Bytes(b) => b,
            payload => entry.pane.encode_input(payload),
        };
        let size = lock(&client.state).sizes.get(&input.pane_id).copied();
        if let Some(size) = size {
            client
                .core
                .apply_client_size(&entry, client.id, client.actor.principal, size, true);
        }
        let Ok(at_seq) = entry.pane.write(bytes).await else {
            client.send(reject(InputRejectReason::UnknownPane));
            continue;
        };
        if let Some(sub) = lock(&client.state).subs.get(&input.pane_id) {
            let _ = sub.cmds.send(StreamCmd::InputAck {
                input_seq: input.input_seq,
                at_seq,
            });
        }
    }
    Ok(())
}

impl Client {
    fn send(&self, msg: ServerCtl) {
        let _ = self.ctl.send(msg);
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

    /// Whether the pane is inside this connection's scope.
    fn pane_allowed(&self, pane: PaneId) -> bool {
        self.core.scope_within(Scope::Pane(pane), self.authz.scope)
    }

    /// Checks a ctl request; on refusal tells the client what and why.
    fn permit(&self, what: &str, need: Need, target: Target) -> bool {
        match self.allow(need, target) {
            Ok(()) => true,
            Err(e) => {
                self.send(ServerCtl::Forbidden {
                    what: what.into(),
                    reason: e.to_string(),
                });
                false
            }
        }
    }

    fn in_session(&self, pane: PaneId) -> bool {
        let session = lock(&self.state).session;
        // One lock at a time: `pane_allowed` takes the layout lock itself.
        let in_session = session.is_some() && self.core.session_of_pane(pane) == session;
        in_session && self.pane_allowed(pane)
    }

    fn forward(&self, event: Event) {
        match event {
            Event::Layout(s) => {
                if lock(&self.state).session == Some(s)
                    && let Some(layout) = self.core.layout_for(s, self.authz.scope)
                {
                    self.send(ServerCtl::LayoutChanged(layout));
                }
            }
            Event::Sessions => self.send(self.core.sessions_message(self.authz.scope)),
            Event::PaneMeta(p) => {
                if self.in_session(p)
                    && let Some(meta) = self.core.pane_meta(p)
                {
                    self.send(ServerCtl::PaneMeta(meta));
                }
            }
            Event::PaneClosed(p) => {
                let had = lock(&self.state)
                    .subs
                    .remove(&p)
                    .map(|sub| sub.task.abort());
                // A scoped guest is only told about panes it could see.
                if had.is_some() || self.authz.scope == Scope::Daemon {
                    self.send(ServerCtl::PaneClosed { pane_id: p });
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
            Event::Decided(d) => {
                if self.pane_allowed(d.pane_id) {
                    self.send(ServerCtl::Decided(d));
                }
            }
            Event::Command(mark) => {
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
            Event::Attention(update) => {
                let visible = match &update {
                    proto::AttentionUpdate::Added { item, .. } => self.pane_allowed(item.pane_id),
                    proto::AttentionUpdate::Seen { .. } => true,
                };
                if visible {
                    self.send(ServerCtl::Attention(update));
                }
            }
            Event::VsCodeTunnel(status) => {
                if self.allow(Need::Drive, Target::Host).is_ok() {
                    self.send(ServerCtl::VsCodeTunnel(status));
                }
            }
            Event::Participants => self.send(ServerCtl::Participants {
                participants: self.core.mp.participants(&self.core, &self.authz),
            }),
            Event::Presence(mut p) => {
                if p.focus.is_some_and(|f| !self.pane_allowed(f)) {
                    p.focus = None;
                    p.typing = false;
                }
                if p.cursor.is_some_and(|c| !self.pane_allowed(c.pane_id)) {
                    p.cursor = None;
                }
                if p.viewport.is_some_and(|v| !self.pane_allowed(v.pane_id)) {
                    p.viewport = None;
                }
                if p.actor != self.actor {
                    self.send(ServerCtl::Presence(p));
                }
            }
            Event::Lease(lease) => {
                if self.pane_allowed(lease.pane_id) {
                    self.send(ServerCtl::Lease(lease));
                }
            }
        }
    }

    /// Ports of panes outside a scoped grant are hidden (host-wide ones too).
    fn scoped_ports(&self, mut ports: Vec<proto::PortInfo>) -> Vec<proto::PortInfo> {
        if self.authz.scope != Scope::Daemon {
            ports.retain(|p| p.pane_id.is_some_and(|pane| self.pane_allowed(pane)));
        }
        ports
    }

    fn view_changed(&self) {
        let panes = {
            let state = lock(&self.state);
            let mut panes = state.visible.clone();
            panes.extend(state.focus);
            panes
        };
        self.core.set_view(self.id, panes);
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
                        .unwrap_or_else(|e| Err(RpcError::Internal(e.to_string())))
                }
            };
            client.send(answer(result));
        });
    }

    /// Serves one history page on the `bulk` stream.
    fn fetch_history(self: &Arc<Self>, pane_id: PaneId, snapshot_seq: Seq, offset: u64, max: u32) {
        let client = Arc::clone(self);
        tokio::spawn(async move {
            let pane = client
                .core
                .pane(pane_id)
                .filter(|_| client.in_session(pane_id))
                .map(|e| Arc::clone(&e.pane));
            let max = max.clamp(16 << 10, 2 << 20);
            let chunk = match pane {
                Some(pane) => tokio::task::spawn_blocking(move || {
                    pane.history_page(snapshot_seq, offset, max)
                })
                .await
                .ok()
                .flatten(),
                None => None,
            };
            let msg = match chunk {
                Some(c) => Bulk::HistoryPage {
                    pane_id,
                    snapshot_seq,
                    offset,
                    next_offset: c.next_offset,
                    total_len: c.total_len,
                    raw_len: c.raw_len,
                    pages: c.pages,
                    done: c.done,
                    data: c.zstd,
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
                && let Err(e) = net::send(stream, &msg).await
            {
                tracing::debug!("bulk stream: {e}");
                *bulk = None;
            }
        });
    }

    async fn handle_ctl(self: &Arc<Self>, msg: ClientCtl) {
        // expired grant ends the connection here, not at the next reconnect.
        if self.live().is_err() {
            return;
        }
        match msg {
            ClientCtl::Hello(_) => {}
            ClientCtl::Subscribe { pane_id, mode, .. } => {
                if self.permit("Subscribe", Need::View, Target::Pane(pane_id)) {
                    self.subscribe(pane_id, mode).await;
                } else {
                    self.send(ServerCtl::PaneClosed { pane_id });
                }
            }
            ClientCtl::Unsubscribe { pane_id } => {
                if let Some(sub) = lock(&self.state).subs.remove(&pane_id) {
                    sub.task.abort();
                }
            }
            ClientCtl::Visible { mut pane_ids } => {
                pane_ids.retain(|&p| self.pane_allowed(p));
                lock(&self.state).visible = pane_ids;
                self.reclassify();
                self.view_changed();
            }
            ClientCtl::Focus { pane_id } => {
                let pane_id = pane_id.filter(|&p| self.pane_allowed(p));
                if let Some(pane) = pane_id {
                    crate::ws::pane_focused(&self.core, pane);
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
            } => self.query(
                pane_id,
                move |e, _| e.pane.search(&query, cursor, limit),
                move |result| ServerCtl::SearchResult {
                    req_id,
                    pane_id,
                    result,
                },
            ),
            ClientCtl::Links {
                req_id,
                pane_id,
                commands,
            } => self.query(
                pane_id,
                move |e, core| {
                    let cwd = lock(&e.meta).cwd.clone().map(std::path::PathBuf::from);
                    let home = core.cfg.pane_var("HOME").map(std::path::PathBuf::from);
                    Ok(e.pane.links(commands, cwd.as_deref(), home.as_deref()))
                },
                move |result| ServerCtl::LinksResult {
                    req_id,
                    pane_id,
                    result,
                },
            ),
            ClientCtl::Commands { req_id, pane_id } => self.query(
                pane_id,
                |e, _| Ok(e.pane.commands()),
                move |result| ServerCtl::CommandsResult {
                    req_id,
                    pane_id,
                    result,
                },
            ),
            ClientCtl::CommandOutput {
                req_id,
                pane_id,
                command_id,
            } => self.query(
                pane_id,
                move |e, _| e.pane.command_output(command_id),
                move |result| ServerCtl::CommandOutputResult {
                    req_id,
                    pane_id,
                    result,
                },
            ),
            ClientCtl::Resize { pane_id, size } => {
                if !self.pane_allowed(pane_id) {
                    return;
                }
                lock(&self.state).sizes.insert(pane_id, size);
                // Viewers keep their size for later but never size the PTY; with a lease,
                let sizes_pty = self.allow(Need::Drive, Target::Pane(pane_id)).is_ok()
                    && self.core.mp.may_size(pane_id, self.actor.principal);
                if sizes_pty && let Some(entry) = self.core.pane(pane_id) {
                    self.core
                        .apply_client_size(&entry, self.id, self.actor.principal, size, false);
                }
            }
            ClientCtl::Ack { pane_id, seq } => {
                if let Some(sub) = lock(&self.state).subs.get(&pane_id) {
                    sub.acks.send_replace(seq);
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
                    Err(e) => self.send(ServerCtl::Forbidden {
                        what: "LeaseRequest".into(),
                        reason: e.to_string(),
                    }),
                }
            }
            ClientCtl::SetSizePolicy { .. } => {}
            ClientCtl::Presence(p) => {
                if p.actor == self.actor {
                    self.core.mp.presence(&self.core, self.id, p);
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
                    let result = client.workspace(req).await;
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
            ClientCtl::Op { op_id, op } => {
                let (need, target) = policy::op(&op);
                let outcome = match self.allow(need, target) {
                    Ok(()) => Arc::clone(&self.core).apply_op(op),
                    Err(e) => proto::OpOutcome::Failed {
                        code: proto::OpError::Forbidden,
                        message: e.to_string(),
                    },
                };
                // Send this client's layout first so the result never precedes it.
                let session = lock(&self.state).session;
                if let Some(layout) =
                    session.and_then(|s| self.core.layout_for(s, self.authz.scope))
                {
                    self.send(ServerCtl::LayoutChanged(layout));
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
        if let Err(e) = self.allow(Need::Approve, Target::Pane(pane)) {
            return refuse(e.to_string());
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
        let sig = decide.sig.clone();
        let record = |decided: &proto::Decided, details: &crate::agent::DecidedRequest| {
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
                        sig,
                    }),
                    ..self.authz.audit()
                },
            );
        };
        match self.core.decide(self.actor, &decide, record) {
            Ok(_) => {}
            Err(Some(by)) => self.send(ServerCtl::AlreadyDecided {
                request_id: decide.request_id,
                by,
            }),
            Err(None) => refuse("the request is no longer open".into()),
        }
    }

    /// A workspace request, gated by the policy table and filtered to the scope.
    async fn workspace(&self, req: WorkspaceRequest) -> Result<WorkspaceResponse, WsError> {
        let (need, target) = policy::workspace(&req);
        self.allow(need, target)
            .map_err(|e| WsError::Denied(e.to_string()))?;
        // A prompter may review an agent's turns and send it notes, but only into an agent.
        if let WorkspaceRequest::SendReview(r) = &req
            && self.allow(Need::Drive, Target::Pane(r.pane_id)).is_err()
            && !self.core.is_agent_pane(r.pane_id)
        {
            return Err(WsError::Denied(
                "review notes from a prompter go to agent panes only".into(),
            ));
        }
        let result = crate::ws::handle(&self.core, &self.ws, req).await?;
        Ok(match result {
            WorkspaceResponse::Ports(ports) => WorkspaceResponse::Ports(self.scoped_ports(ports)),
            WorkspaceResponse::Attention(mut list) if self.authz.scope != Scope::Daemon => {
                list.items.retain(|i| self.pane_allowed(i.pane_id));
                list.unseen = list.items.iter().filter(|i| !i.seen).count() as u32;
                WorkspaceResponse::Attention(list)
            }
            other => other,
        })
    }

    /// A multiplayer request.
    async fn multiplayer(&self, req: MpRequest) -> Result<MpResponse, MpError> {
        let core = &self.core;
        let mp = &core.mp;
        match req {
            MpRequest::WhoAmI => Ok(MpResponse::Me(self.authz.join_info(&mp.name_of(self.id)))),
            MpRequest::Participants => {
                Ok(MpResponse::Participants(mp.participants(core, &self.authz)))
            }
            MpRequest::SetName { name } => {
                mp.set_name(core, self.id, name);
                Ok(MpResponse::Done)
            }
            MpRequest::RegisterGrant(chain) => mp
                .register(core, &self.authz, &chain)
                .map(MpResponse::Grant),
            MpRequest::ListGrants => {
                self.allow(Need::Own, Target::Daemon)?;
                Ok(MpResponse::Grants(mp.list_grants()))
            }
            MpRequest::ListDevices => {
                self.allow(Need::Own, Target::Daemon)?;
                Ok(MpResponse::Devices(mp.list_devices(core)))
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
                    .filter(|l| self.pane_allowed(l.pane_id))
                    .collect(),
            )),
            MpRequest::Prompt {
                pane_id,
                text,
                submit,
            } => self.prompt(pane_id, text, submit).await,
        }
    }

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
        if !self.core.is_agent_pane(pane_id) {
            return Err(MpError::Forbidden(
                "prompts go to agent panes only; this pane runs a shell".into(),
            ));
        }
        crate::mp::prompt::check(&text).map_err(|e| MpError::Invalid(e.to_string()))?;
        let bytes = entry.pane.encode_input(InputPayload::Paste(text.clone()));
        entry
            .pane
            .write(bytes)
            .await
            .map_err(|_| MpError::NotFound(format!("pane {pane_id} exited")))?;
        if submit {
            // Let the agent's input box take the paste before Enter arrives.
            tokio::time::sleep(std::time::Duration::from_millis(80)).await;
            let _ = entry.pane.write(b"\r".to_vec()).await;
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

    fn attach(&self, requested: Option<SessionId>) {
        let scope = self.authz.scope;
        let exists = requested.is_some_and(|s| {
            let known = lock(&self.core.layout).session(s).is_some();
            known && self.core.session_visible(s, scope)
        });
        let recent = self.core.recent_session_in(scope);
        let session = match requested {
            Some(s) if exists => s,
            Some(_) => {
                self.send(ServerCtl::OpResult {
                    op_id: 0,
                    outcome: proto::OpOutcome::Failed {
                        code: proto::OpError::NotFound,
                        message: "no such session".into(),
                    },
                });
                return;
            }
            None => match recent {
                Some(s) => s,
                None if self.allow(Need::Own, Target::Daemon).is_err() => {
                    self.send(ServerCtl::OpResult {
                        op_id: 0,
                        outcome: proto::OpOutcome::Failed {
                            code: proto::OpError::NotFound,
                            message: "nothing to attach to in this grant's scope".into(),
                        },
                    });
                    return;
                }
                None => match self
                    .core
                    .create_session(String::new(), PaneLaunch::Shell { cwd: None })
                {
                    Ok((s, _, _)) => s,
                    Err((code, message)) => {
                        self.send(ServerCtl::OpResult {
                            op_id: 0,
                            outcome: proto::OpOutcome::Failed { code, message },
                        });
                        return;
                    }
                },
            },
        };
        lock(&self.state).session = Some(session);
        self.core.attach(self.id, session);
        self.send(ServerCtl::Attached {
            session_id: session,
        });
        let Some(layout) = self.core.layout_for(session, scope) else {
            return;
        };
        let panes: Vec<PaneId> = layout
            .tabs
            .iter()
            .flat_map(|t| crate::layout::leaves(&t.root).collect::<Vec<_>>())
            .collect();
        self.send(ServerCtl::LayoutChanged(layout));
        for pane in panes {
            if let Some(meta) = self.core.pane_meta(pane) {
                self.send(ServerCtl::PaneMeta(meta));
            }
            if let Some(hint) = self.core.echo_hint(pane) {
                self.send(ServerCtl::EchoHintAt(hint));
            }
            let lease = self.core.mp.lease(pane);
            if lease.holder.is_some() {
                self.send(ServerCtl::Lease(lease));
            }
        }
        self.send(ServerCtl::Participants {
            participants: self.core.mp.participants(&self.core, &self.authz),
        });
    }

    fn reclassify(&self) {
        let state = lock(&self.state);
        for (pane, sub) in &state.subs {
            let _ = sub.cmds.send(StreamCmd::Class(state.class(*pane)));
        }
    }

    async fn subscribe(self: &Arc<Self>, pane_id: PaneId, mode: SubscribeMode) {
        if mode == SubscribeMode::Meta {
            return;
        }
        if lock(&self.state).subs.contains_key(&pane_id) {
            return;
        }
        let Some(entry) = self.core.pane(pane_id) else {
            self.send(ServerCtl::PaneClosed { pane_id });
            return;
        };
        let pane = Arc::clone(&entry.pane);
        let start = match lock(&self.state).resume.remove(&pane_id) {
            Some(point) if point.snap_gen == pane.snap_gen => Start::Resume(point.last_seq),
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
            one_shot: mode == SubscribeMode::Snapshot,
        };
        let task = tokio::spawn(async move {
            match stream.run(start).await {
                Ok(stats) => tracing::trace!(%pane_id, ?stats, "pane stream done"),
                Err(e) => tracing::debug!(%pane_id, "pane stream: {e}"),
            }
        });
        lock(&self.state).subs.insert(
            pane_id,
            Sub {
                acks,
                cmds,
                task: task.abort_handle(),
            },
        );
    }
}
