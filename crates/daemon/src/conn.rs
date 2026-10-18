//! One client connection: the handshake, `ctl`, `input`, pane streams and port forwards.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use iroh::endpoint::{Connection, RecvStream, SendStream};
use proto::{
    Actor, Bulk, ClientCtl, ClientInput, DeviceId, Hello, InputPayload, InputRejectReason, Lease,
    LeaseMode, PaneId, PaneLaunch, PaneSize, PrincipalId, RefuseReason, ResumePoint, Roles,
    RpcError, Seq, ServerCtl, SessionId, StreamHeader, SubscribeMode, UnixMillis, WIRE_VERSION,
    Welcome,
};
use tokio::sync::{broadcast, mpsc, watch};
use tokio::task::{AbortHandle, JoinSet};

use crate::core::{ConnId, Core, Event, lock};
use crate::forward;
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
    let principal = match handshake(&core, &hello, device) {
        Ok(p) => p,
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
        roles: Roles::OWNER,
        snapshot_format: u32::from(ghostty_vt::snapshot_format()),
        panes: core
            .pane_entries()
            .into_iter()
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
    let client = Arc::new(Client {
        id: core.next_conn_id(),
        core: Arc::clone(&core),
        conn: conn.clone(),
        actor: Actor { principal, device },
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
    for point in hello.resume {
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
    core.client_connected(false);
    lock(&client.ws.watches).clear();
    result
}

fn conn_err(e: iroh::endpoint::ConnectionError) -> NetError {
    NetError::Frame(proto::FrameError::Io(std::io::Error::other(e)))
}

fn handshake(core: &Core, hello: &Hello, device: DeviceId) -> Result<PrincipalId, RefuseReason> {
    if hello.device_id != device {
        return Err(RefuseReason::DeviceMismatch);
    }
    let format = u32::from(ghostty_vt::snapshot_format());
    if hello.snapshot_format != format {
        return Err(RefuseReason::SnapshotFormat { daemon: format });
    }
    let _ = WIRE_VERSION;
    core.identity
        .authorize(device, hello.principal_id, &hello.grant)
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
                client.send(client.core.sessions_message());
                let session = lock(&client.state).session;
                if let Some(s) = session {
                    client.forward(Event::Layout(s));
                }
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
    while let Ok((send, mut recv)) = client.conn.accept_bi().await {
        match net::recv::<StreamHeader>(&mut recv).await {
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
        if input.principal != client.actor.principal {
            client.send(reject(InputRejectReason::Role));
            continue;
        }
        let Some(entry) = client.core.pane(input.pane_id) else {
            client.send(reject(InputRejectReason::UnknownPane));
            continue;
        };
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

    fn in_session(&self, pane: PaneId) -> bool {
        let session = lock(&self.state).session;
        session.is_some() && lock(&self.core.layout).session_of_pane(pane) == session
    }

    fn forward(&self, event: Event) {
        match event {
            Event::Layout(s) => {
                if lock(&self.state).session == Some(s)
                    && let Some(layout) = lock(&self.core.layout).snapshot(s)
                {
                    self.send(ServerCtl::LayoutChanged(layout));
                }
            }
            Event::Sessions => self.send(self.core.sessions_message()),
            Event::PaneMeta(p) => {
                if self.in_session(p)
                    && let Some(meta) = self.core.pane_meta(p)
                {
                    self.send(ServerCtl::PaneMeta(meta));
                }
            }
            Event::PaneClosed(p) => {
                if let Some(sub) = lock(&self.state).subs.remove(&p) {
                    sub.task.abort();
                }
                self.send(ServerCtl::PaneClosed { pane_id: p });
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
            Event::Decided(d) => self.send(ServerCtl::Decided(d)),
            Event::Command(mark) => {
                if self.in_session(mark.pane_id) {
                    self.send(ServerCtl::CommandMark(mark));
                }
            }
            Event::CommandUnseen(mark) => self.send(ServerCtl::CommandFinishedUnseen(mark)),
            Event::Ports => self.send(ServerCtl::PortsChanged {
                ports: self.core.ws.ports.current(),
            }),
            Event::Attention(update) => self.send(ServerCtl::Attention(update)),
            Event::VsCodeTunnel(status) => self.send(ServerCtl::VsCodeTunnel(status)),
        }
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
        match msg {
            ClientCtl::Hello(_) => {}
            ClientCtl::Subscribe { pane_id, mode, .. } => self.subscribe(pane_id, mode).await,
            ClientCtl::Unsubscribe { pane_id } => {
                if let Some(sub) = lock(&self.state).subs.remove(&pane_id) {
                    sub.task.abort();
                }
            }
            ClientCtl::Visible { pane_ids } => {
                lock(&self.state).visible = pane_ids;
                self.reclassify();
                self.view_changed();
            }
            ClientCtl::Focus { pane_id } => {
                if let Some(pane) = pane_id {
                    crate::ws::pane_focused(&self.core, pane);
                }
                lock(&self.state).focus = pane_id;
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
                lock(&self.state).sizes.insert(pane_id, size);
                if let Some(entry) = self.core.pane(pane_id) {
                    self.core
                        .apply_client_size(&entry, self.id, self.actor.principal, size, false);
                }
            }
            ClientCtl::Ack { pane_id, seq } => {
                if let Some(sub) = lock(&self.state).subs.get(&pane_id) {
                    sub.acks.send_replace(seq);
                }
            }
            ClientCtl::Decide(decide) => {
                if decide.actor != self.actor {
                    return;
                }
                if let Err(Some(by)) = self.core.decide(self.actor, &decide) {
                    self.send(ServerCtl::AlreadyDecided {
                        request_id: decide.request_id,
                        by,
                    });
                }
            }
            ClientCtl::LeaseRequest { pane_id, .. } => self.send(ServerCtl::Lease(Lease {
                pane_id,
                holder: None,
                since: UnixMillis(0),
                mode: LeaseMode::Free,
            })),
            ClientCtl::SetSizePolicy { .. } | ClientCtl::Presence(_) => {}
            ClientCtl::Ping { nonce } => self.send(ServerCtl::Pong { nonce }),
            ClientCtl::Bye { .. } => {}
            ClientCtl::ListSessions => self.send(self.core.sessions_message()),
            ClientCtl::Attach { session_id } => self.attach(session_id),
            ClientCtl::Workspace { req_id, req } => {
                let client = Arc::clone(self);
                tokio::spawn(async move {
                    let result = crate::ws::handle(&client.core, &client.ws, req).await;
                    client.send(ServerCtl::WorkspaceResult { req_id, result });
                });
            }
            ClientCtl::Op { op_id, op } => {
                let core = Arc::clone(&self.core);
                let outcome = core.apply_op(op);
                // Send this client's layout first so the result never precedes it.
                let session = lock(&self.state).session;
                if let Some(layout) = session.and_then(|s| lock(&self.core.layout).snapshot(s)) {
                    self.send(ServerCtl::LayoutChanged(layout));
                }
                self.send(ServerCtl::OpResult { op_id, outcome });
            }
        }
    }

    fn attach(&self, requested: Option<SessionId>) {
        let exists = requested.is_some_and(|s| lock(&self.core.layout).session(s).is_some());
        let recent = lock(&self.core.layout).most_recent();
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
        let Some(layout) = lock(&self.core.layout).snapshot(session) else {
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
        }
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
