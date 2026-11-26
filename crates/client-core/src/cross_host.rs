//! Agents reaching other hosts, relayed by this device (`proto::cross_host`).
//!
//! An owner device connected with [`ConnectOptions::cross_host`](crate::ConnectOptions)
//! announces `Caps::CROSS_HOST` and gets the agents' requests of each of its hosts. A
//! [`CrossHostRelay`] holds every host the device knows, the owner's per-pair switches and
//! the standing yeses, and does the rest: it refuses what the owner has not turned on, shows a
//! [`CrossHostCard`] for what needs an answer, claims the request with a signed answer, runs
//! the call on the other host over that host's own connection and sends the reply back.
//!
//! Nothing here holds a credential for one host on behalf of another: each leg is this
//! device's own connection, and each host only ever hears from this device.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use proto::{
    ClientCtl, Consent, CrossHostMsg, CrossHostPush, CrossHostRefusal, CrossHostRequest,
    CrossHostVerb, DaemonId, Decide, HostEntry, MoreDaemonFeatures, OptionId, PairState, PaneId,
    RemoteAgent, RemoteCall, RequestId, ServerCtl, UnixMillis,
};
use tokio::sync::{mpsc, oneshot};

use crate::{Client, lock};

/// How long a claim waits for the host's answer.
const CLAIM_TIMEOUT: Duration = Duration::from_secs(15);
/// How long a call on the other host may take: the longest wait a tool allows (240 s), and
/// some room to start it.
const CALL_TIMEOUT: Duration = Duration::from_secs(300);
/// Calls this device may have running on one host at once for agents elsewhere.
const MAX_CALLS_IN_FLIGHT: usize = 64;

/// Receives the raw [`CrossHostPush`]es of one connection. Must return quickly; it runs on the
/// network threads. A [`CrossHostRelay`] installs its own.
pub trait CrossHostPushListener: Send + Sync {
    fn on_cross_host_push(&self, push: CrossHostPush);
}

/// A [`CrossHostPushListener`] that queues pushes (tests).
pub struct CrossHostPushQueue {
    tx: mpsc::UnboundedSender<CrossHostPush>,
}

impl CrossHostPushQueue {
    pub fn channel() -> (
        Arc<dyn CrossHostPushListener>,
        mpsc::UnboundedReceiver<CrossHostPush>,
    ) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Self { tx }), rx)
    }
}

impl CrossHostPushListener for CrossHostPushQueue {
    fn on_cross_host_push(&self, push: CrossHostPush) {
        let _ = self.tx.send(push);
    }
}

type CallReply = oneshot::Sender<Result<String, String>>;

/// Per connection: where pushes go, claims and calls waiting for their answer, and the host
/// list to send on every connection.
#[derive(Default)]
pub(crate) struct CrossHostState {
    listener: Mutex<Option<Arc<dyn CrossHostPushListener>>>,
    claims: Mutex<HashMap<RequestId, oneshot::Sender<bool>>>,
    calls: Mutex<HashMap<u64, CallReply>>,
    next_call: std::sync::atomic::AtomicU64,
    directory: Mutex<Option<Vec<HostEntry>>>,
}

impl CrossHostState {
    /// Handles a cross-host push; returns the message back if it is not one. Requests on a
    /// connection that did not announce the capability are dropped: a daemon is not trusted
    /// to honour it.
    pub(crate) fn dispatch(&self, message: ServerCtl, announced: bool) -> Option<ServerCtl> {
        let ServerCtl::CrossHost(push) = message else {
            return Some(message);
        };
        match push {
            CrossHostPush::CallResult { req_id, reply } => {
                if let Some(waiting) = lock(&self.calls).remove(&req_id) {
                    let _ = waiting.send(Ok(reply));
                }
            }
            CrossHostPush::Claimed { id, won } => {
                if let Some(waiting) = lock(&self.claims).remove(&id) {
                    let _ = waiting.send(won);
                }
            }
            push if announced => {
                let listener = lock(&self.listener).clone();
                if let Some(listener) = listener {
                    listener.on_cross_host_push(push);
                }
            }
            _ => tracing::warn!("cross-host push on a connection that did not ask for it; dropped"),
        }
        None
    }

    pub(crate) fn awaits(&self, req_id: u64) -> bool {
        lock(&self.calls)
            .get(&req_id)
            .is_some_and(|reply| !reply.is_closed())
    }

    pub(crate) fn fail_pending(&self) {
        for (_, waiting) in lock(&self.calls).drain() {
            let _ = waiting.send(Err("the connection dropped".into()));
        }
        lock(&self.claims).clear();
    }

    /// The host list to send on a new connection, if the app gave one.
    pub(crate) fn directory(&self) -> Option<ClientCtl> {
        lock(&self.directory)
            .clone()
            .map(|entries| ClientCtl::CrossHost(CrossHostMsg::Directory(entries)))
    }
}

/// Whether a connection announces `Caps::CROSS_HOST`: only when asked, and never as a guest.
pub(crate) fn announces(options: &crate::ConnectOptions, guest: bool) -> bool {
    options.cross_host && !guest
}

impl Client {
    /// Sets the receiver of this connection's [`CrossHostPush`]es (a [`CrossHostRelay`] sets
    /// its own when the host is added).
    pub fn set_cross_host_listener(&self, listener: Arc<dyn CrossHostPushListener>) {
        *lock(&self.inner.cross_host.listener) = Some(listener);
    }

    fn clear_cross_host_listener(&self) {
        *lock(&self.inner.cross_host.listener) = None;
    }

    /// Whether this daemon takes part in relayed calls.
    pub fn offers_cross_host(&self) -> bool {
        self.daemon_offers(MoreDaemonFeatures::CROSS_HOST)
    }

    /// The daemon this client talks to.
    pub fn daemon_id(&self) -> DaemonId {
        self.inner.ticket.daemon_id
    }

    fn is_connected(&self) -> bool {
        lock(&self.inner.connection).is_some()
    }

    /// Tells the daemon this device's other hosts, now and on every later connection.
    pub fn set_cross_host_directory(&self, entries: Vec<HostEntry>) {
        *lock(&self.inner.cross_host.directory) = Some(entries.clone());
        if self.is_connected() {
            self.inner
                .send(ClientCtl::CrossHost(CrossHostMsg::Directory(entries)));
        }
    }

    /// Claims request `id` with `option`, signed for this daemon; `true` if this device won it.
    pub async fn claim_cross_host(&self, id: RequestId, option: OptionId) -> bool {
        let mut decide = Decide {
            request_id: id,
            option_id: option,
            actor: self.actor(),
            sig: Vec::new(),
        };
        if let Ok(key) = grants::DeviceKey::from_seed(&self.inner.config.secret_key) {
            grants::sign_approval(&key, self.inner.ticket.daemon_id, &mut decide);
        }
        let (tx, rx) = oneshot::channel();
        lock(&self.inner.cross_host.claims).insert(id, tx);
        self.inner
            .send(ClientCtl::CrossHost(CrossHostMsg::Claim(decide)));
        let won = tokio::time::timeout(CLAIM_TIMEOUT, rx).await;
        lock(&self.inner.cross_host.claims).remove(&id);
        matches!(won, Ok(Ok(true)))
    }

    /// Sends a message of the relay protocol (refusals, results, ends of agents).
    pub fn send_cross_host(&self, message: CrossHostMsg) {
        self.inner.send(ClientCtl::CrossHost(message));
    }

    /// Runs `call` on this daemon for an agent on another host; the terminal tools' reply
    /// (one JSON object), or why it could not run.
    pub async fn remote_call(&self, call: RemoteCall) -> Result<String, String> {
        if !self.offers_cross_host() {
            return Err("its helper is too old".into());
        }
        let state = &self.inner.cross_host;
        let req_id = state
            .next_call
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        {
            let mut calls = lock(&state.calls);
            if calls.len() >= MAX_CALLS_IN_FLIGHT {
                return Err("too many calls are running there".into());
            }
            calls.insert(req_id, tx);
        }
        self.inner
            .send(ClientCtl::CrossHost(CrossHostMsg::Call { req_id, call }));
        let reply = tokio::time::timeout(CALL_TIMEOUT, rx).await;
        lock(&state.calls).remove(&req_id);
        match reply {
            Ok(Ok(outcome)) => outcome,
            Ok(Err(_)) => Err("the connection dropped".into()),
            Err(_) => Err("it did not answer in time".into()),
        }
    }

    fn attached_session(&self) -> Option<proto::SessionId> {
        lock(&self.inner.wanted).session
    }
}

/// How this device reaches a host.
#[derive(Clone)]
pub enum HostLink {
    /// Paired as owner, with its connection.
    Owner(Arc<Client>),
    /// Joined as a guest: never a target, never asked.
    Guest,
    /// Reached over plain SSH, with no helper.
    SshOnly,
    /// Paired as owner, but this device has no connection to it now.
    Unreached,
}

/// A host of this device, as the relay knows it.
#[derive(Clone)]
pub struct RelayHost {
    /// The app's id for the host.
    pub id: String,
    /// Its name as the app shows it.
    pub name: String,
    pub link: HostLink,
}

impl RelayHost {
    pub fn owner(id: impl Into<String>, name: impl Into<String>, client: Arc<Client>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            link: HostLink::Owner(client),
        }
    }

    pub fn guest(id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            link: HostLink::Guest,
        }
    }

    pub fn ssh_only(id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            link: HostLink::SshOnly,
        }
    }

    pub fn unreached(id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            link: HostLink::Unreached,
        }
    }

    fn client(&self) -> Option<&Arc<Client>> {
        match &self.link {
            HostLink::Owner(client) => Some(client),
            HostLink::Guest | HostLink::SshOnly | HostLink::Unreached => None,
        }
    }

    /// The id a host lists it under: its daemon's, else the app's.
    fn listed_id(&self) -> String {
        match &self.link {
            HostLink::Owner(client) => hex(&client.daemon_id().0),
            HostLink::Guest | HostLink::SshOnly | HostLink::Unreached => self.id.clone(),
        }
    }

    fn answers_to(&self, wanted: &str) -> bool {
        let wanted = wanted.trim();
        !wanted.is_empty()
            && (self.name.eq_ignore_ascii_case(wanted)
                || self.id == wanted
                || self.listed_id().eq_ignore_ascii_case(wanted))
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A request on screen, by the host that asked and its id there.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct CrossHostCardKey {
    /// The asking host's id in the relay.
    pub from: String,
    pub id: RequestId,
}

/// What the device shows for a request that needs the owner's answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CrossHostCard {
    pub key: CrossHostCardKey,
    /// `Claude`.
    pub agent: String,
    /// The asking agent's pane on its host.
    pub pane_id: PaneId,
    pub from_name: String,
    /// The target host's id in the relay.
    pub to: String,
    pub to_name: String,
    pub tool: String,
    pub verb: CrossHostVerb,
    /// The call in words, from its arguments (never the asking host's own wording).
    pub action: String,
    /// A guest drives the asking pane.
    pub guest_driving: Option<String>,
    pub expires_at: UnixMillis,
}

impl CrossHostCard {
    /// `Claude on mac wants to run $ npm test on ops`.
    pub fn title(&self) -> String {
        format!(
            "{} on {} wants to {} on {}",
            self.agent, self.from_name, self.action, self.to_name
        )
    }
}

/// The owner's answer to a card.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CrossHostChoice {
    AllowOnce,
    /// Everything this agent asks on that host until its pane closes.
    AllowAgent,
    Deny,
}

/// What a standing yes covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StandingScope {
    /// Reads, after an "Allow once".
    Reads,
    /// Everything, after "Allow all for this agent".
    All,
}

/// An agent's standing yes on another host, until its pane closes or the owner revokes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StandingAllow {
    pub from: String,
    pub from_name: String,
    pub to: String,
    pub to_name: String,
    pub pane_id: PaneId,
    pub agent_key: u64,
    pub agent: String,
    pub scope: StandingScope,
}

/// What the relay tells the app.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CrossHostEvent {
    /// A request needs the owner's answer.
    Card(CrossHostCard),
    /// It no longer does (answered here or elsewhere, expired, withdrawn).
    CardClosed(CrossHostCardKey),
    /// The standing yeses changed.
    Standing(Vec<StandingAllow>),
}

/// Receives [`CrossHostEvent`]s. Must return quickly.
pub trait CrossHostListener: Send + Sync {
    fn on_cross_host_event(&self, event: CrossHostEvent);
}

/// A [`CrossHostListener`] that queues events (tests).
pub struct CrossHostEventQueue {
    tx: mpsc::UnboundedSender<CrossHostEvent>,
}

impl CrossHostEventQueue {
    pub fn channel() -> (
        Arc<dyn CrossHostListener>,
        mpsc::UnboundedReceiver<CrossHostEvent>,
    ) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Self { tx }), rx)
    }
}

impl CrossHostListener for CrossHostEventQueue {
    fn on_cross_host_event(&self, event: CrossHostEvent) {
        let _ = self.tx.send(event);
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct AgentOnHost {
    from: String,
    pane_id: PaneId,
    agent_key: u64,
    to: String,
}

struct Standing {
    scope: StandingScope,
    agent: String,
}

struct OpenCard {
    request: CrossHostRequest,
    to: String,
}

/// What the relay does with a request.
#[derive(Debug, PartialEq, Eq)]
enum Verdict {
    Refuse(CrossHostRefusal),
    /// Covered by an earlier yes: performed at once.
    Perform {
        to: String,
        consent: Consent,
        option: OptionId,
    },
    /// Needs the owner.
    Ask {
        to: String,
    },
}

#[derive(Default)]
struct Book {
    hosts: Vec<RelayHost>,
    /// `(from, to)`: agents on `from` may ask to reach `to`.
    pairs: HashSet<(String, String)>,
    standing: HashMap<AgentOnHost, Standing>,
    cards: HashMap<CrossHostCardKey, OpenCard>,
}

/// Where a target stands for this device right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Reach {
    Ready,
    Offline,
    OldHelper,
}

fn reach(host: &RelayHost) -> Option<Reach> {
    let client = host.client()?;
    Some(if !client.is_connected() {
        Reach::Offline
    } else if !client.offers_cross_host() {
        Reach::OldHelper
    } else {
        Reach::Ready
    })
}

impl Book {
    fn host(&self, id: &str) -> Option<&RelayHost> {
        self.hosts.iter().find(|host| host.id == id)
    }

    fn judge(
        &self,
        from: &str,
        request: &CrossHostRequest,
        reach: impl Fn(&RelayHost) -> Option<Reach>,
    ) -> Verdict {
        let Some(target) = self
            .hosts
            .iter()
            .find(|host| host.answers_to(&request.host))
        else {
            return Verdict::Refuse(CrossHostRefusal::UnknownHost {
                host: request.host.clone(),
            });
        };
        if target.id == from {
            return Verdict::Refuse(CrossHostRefusal::SameHost);
        }
        let host = target.name.clone();
        match &target.link {
            HostLink::Guest => return Verdict::Refuse(CrossHostRefusal::Guest { host }),
            HostLink::SshOnly => return Verdict::Refuse(CrossHostRefusal::NoHelper { host }),
            HostLink::Owner(_) | HostLink::Unreached => {}
        }
        if !self.pairs.contains(&(from.to_owned(), target.id.clone())) {
            return Verdict::Refuse(CrossHostRefusal::NotEnabled { host });
        }
        match reach(target) {
            Some(Reach::Ready) => {}
            Some(Reach::OldHelper) => {
                return Verdict::Refuse(CrossHostRefusal::OldHelper { host });
            }
            Some(Reach::Offline) | None => {
                return Verdict::Refuse(CrossHostRefusal::Offline { host });
            }
        }
        let agent = AgentOnHost {
            from: from.to_owned(),
            pane_id: request.pane_id,
            agent_key: request.agent_key,
            to: target.id.clone(),
        };
        let to = target.id.clone();
        match (
            self.standing.get(&agent).map(|standing| standing.scope),
            request.verb(),
        ) {
            (_, None) => Verdict::Refuse(CrossHostRefusal::SameHost),
            (Some(StandingScope::All), Some(_)) => Verdict::Perform {
                to,
                consent: Consent::Agent,
                option: CrossHostRequest::ALLOW_AGENT,
            },
            (Some(StandingScope::Reads), Some(CrossHostVerb::Read)) => Verdict::Perform {
                to,
                consent: Consent::Reads,
                option: CrossHostRequest::ALLOW_ONCE,
            },
            _ => Verdict::Ask { to },
        }
    }

    /// What `from` may list: every other host and where it stands.
    fn directory(&self, from: &str, reach: impl Fn(&RelayHost) -> Option<Reach>) -> Vec<HostEntry> {
        self.hosts
            .iter()
            .filter(|host| host.id != from)
            .map(|host| HostEntry {
                id: host.listed_id(),
                name: host.name.clone(),
                state: match (&host.link, reach(host)) {
                    (HostLink::Guest, _) => PairState::Guest,
                    (HostLink::SshOnly, _) => PairState::NoHelper,
                    _ if !self.pairs.contains(&(from.to_owned(), host.id.clone())) => {
                        PairState::Off
                    }
                    (_, Some(Reach::Ready)) => PairState::Enabled,
                    (_, Some(Reach::OldHelper)) => PairState::OldHelper,
                    (_, _) => PairState::Offline,
                },
            })
            .collect()
    }

    fn standing_list(&self) -> Vec<StandingAllow> {
        let name = |id: &str| {
            self.host(id)
                .map(|host| host.name.clone())
                .unwrap_or_default()
        };
        let mut list: Vec<StandingAllow> = self
            .standing
            .iter()
            .map(|(agent, standing)| StandingAllow {
                from: agent.from.clone(),
                from_name: name(&agent.from),
                to: agent.to.clone(),
                to_name: name(&agent.to),
                pane_id: agent.pane_id,
                agent_key: agent.agent_key,
                agent: standing.agent.clone(),
                scope: standing.scope,
            })
            .collect();
        list.sort_by(|left, right| {
            (&left.from, &left.to, left.pane_id).cmp(&(&right.from, &right.to, right.pane_id))
        });
        list
    }

    /// Ends the standing yeses `matching` picks; the agents they named, for their hosts.
    fn end_standing(&mut self, matching: impl Fn(&AgentOnHost) -> bool) -> Vec<AgentOnHost> {
        let ended: Vec<AgentOnHost> = self
            .standing
            .keys()
            .filter(|agent| matching(agent))
            .cloned()
            .collect();
        for agent in &ended {
            self.standing.remove(agent);
        }
        ended
    }
}

struct RelayInner {
    book: Mutex<Book>,
    listener: Arc<dyn CrossHostListener>,
}

/// Relays agents' calls between this device's hosts (see the module docs). Cheap to clone.
#[derive(Clone)]
pub struct CrossHostRelay {
    inner: Arc<RelayInner>,
}

/// Hands one host's pushes to the relay.
struct FromHost {
    relay: Weak<RelayInner>,
    host: String,
}

impl CrossHostPushListener for FromHost {
    fn on_cross_host_push(&self, push: CrossHostPush) {
        if let Some(inner) = self.relay.upgrade() {
            CrossHostRelay { inner }.on_push(&self.host, push);
        }
    }
}

impl CrossHostRelay {
    pub fn new(listener: Arc<dyn CrossHostListener>) -> Self {
        Self {
            inner: Arc::new(RelayInner {
                book: Mutex::default(),
                listener,
            }),
        }
    }

    /// Adds a host, or replaces the one with its id (a new connection, a rename).
    pub fn add_host(&self, host: RelayHost) {
        if let Some(client) = host.client() {
            client.set_cross_host_listener(Arc::new(FromHost {
                relay: Arc::downgrade(&self.inner),
                host: host.id.clone(),
            }));
        }
        {
            let mut book = lock(&self.inner.book);
            book.hosts.retain(|known| known.id != host.id);
            book.hosts.push(host);
        }
        self.send_directories();
    }

    /// Forgets a host; its pairs and standing yeses go with it.
    pub fn remove_host(&self, id: &str) {
        let removed = {
            let mut book = lock(&self.inner.book);
            let removed = book.hosts.iter().position(|host| host.id == id);
            let removed = removed.map(|index| book.hosts.remove(index));
            book.pairs.retain(|(from, to)| from != id && to != id);
            book.end_standing(|agent| agent.from == id || agent.to == id);
            removed
        };
        if let Some(client) = removed.as_ref().and_then(RelayHost::client) {
            client.clear_cross_host_listener();
        }
        self.standing_changed();
        self.send_directories();
    }

    /// Turns "agents on `from` may reach `to`" on or off. Off also ends every standing yes for
    /// the pair, at once.
    pub fn set_pair(&self, from: &str, to: &str, enabled: bool) {
        {
            let mut book = lock(&self.inner.book);
            let pair = (from.to_owned(), to.to_owned());
            if enabled {
                book.pairs.insert(pair);
            } else {
                book.pairs.remove(&pair);
            }
        }
        if !enabled {
            self.end_allows(from, to);
        }
        self.send_directories();
    }

    pub fn pair_enabled(&self, from: &str, to: &str) -> bool {
        lock(&self.inner.book)
            .pairs
            .contains(&(from.to_owned(), to.to_owned()))
    }

    /// The pair's switch off: every standing yes ends and agents on `from` reach `to` no more.
    pub fn revoke(&self, from: &str, to: &str) {
        self.set_pair(from, to, false);
    }

    /// Ends every standing yes of agents on `from` for `to`, keeping the pair on: their next
    /// request is asked again.
    pub fn end_allows(&self, from: &str, to: &str) {
        let ended =
            lock(&self.inner.book).end_standing(|agent| agent.from == from && agent.to == to);
        self.tell_targets(ended);
        self.standing_changed();
    }

    /// The standing yeses in force.
    pub fn standing(&self) -> Vec<StandingAllow> {
        lock(&self.inner.book).standing_list()
    }

    /// The owner's answer to a card. Allow runs the call on the other host; the card closes
    /// either way.
    pub fn answer(&self, key: &CrossHostCardKey, choice: CrossHostChoice) {
        let Some(card) = lock(&self.inner.book).cards.remove(key) else {
            return;
        };
        self.inner
            .listener
            .on_cross_host_event(CrossHostEvent::CardClosed(key.clone()));
        let (consent, option) = match choice {
            CrossHostChoice::AllowOnce => (Consent::Once, CrossHostRequest::ALLOW_ONCE),
            CrossHostChoice::AllowAgent => (Consent::Agent, CrossHostRequest::ALLOW_AGENT),
            CrossHostChoice::Deny => (Consent::Once, CrossHostRequest::DENY),
        };
        self.perform(&key.from, &card.to, card.request, consent, option);
    }

    fn on_push(&self, from: &str, push: CrossHostPush) {
        match push {
            CrossHostPush::Request(request) => self.on_request(from, request),
            CrossHostPush::Closed { id } => {
                let key = CrossHostCardKey {
                    from: from.to_owned(),
                    id,
                };
                if lock(&self.inner.book).cards.remove(&key).is_some() {
                    self.inner
                        .listener
                        .on_cross_host_event(CrossHostEvent::CardClosed(key));
                }
            }
            CrossHostPush::AgentGone { pane_id, agent_key } => {
                let ended = lock(&self.inner.book).end_standing(|agent| {
                    agent.from == from && agent.pane_id == pane_id && agent.agent_key == agent_key
                });
                let tell = if ended.is_empty() {
                    lock(&self.inner.book)
                        .hosts
                        .iter()
                        .filter(|host| host.id != from && host.client().is_some())
                        .map(|host| AgentOnHost {
                            from: from.to_owned(),
                            pane_id,
                            agent_key,
                            to: host.id.clone(),
                        })
                        .collect()
                } else {
                    ended
                };
                self.tell_targets(tell);
                self.standing_changed();
            }
            CrossHostPush::Claimed { .. } | CrossHostPush::CallResult { .. } => {}
        }
    }

    fn on_request(&self, from: &str, request: CrossHostRequest) {
        let verdict = lock(&self.inner.book).judge(from, &request, reach);
        match verdict {
            Verdict::Refuse(refusal) => {
                if let Some(client) = self.client(from) {
                    client.send_cross_host(CrossHostMsg::Refuse {
                        id: request.id,
                        refusal,
                    });
                }
            }
            Verdict::Perform {
                to,
                consent,
                option,
            } => self.perform(from, &to, request, consent, option),
            Verdict::Ask { to } => {
                let card = {
                    let mut book = lock(&self.inner.book);
                    let name = |id: &str| {
                        book.host(id)
                            .map(|host| host.name.clone())
                            .unwrap_or_default()
                    };
                    let card = CrossHostCard {
                        key: CrossHostCardKey {
                            from: from.to_owned(),
                            id: request.id,
                        },
                        agent: request.agent.clone(),
                        pane_id: request.pane_id,
                        from_name: name(from),
                        to: to.clone(),
                        to_name: name(&to),
                        tool: request.tool.clone(),
                        verb: request.verb().unwrap_or(CrossHostVerb::Input),
                        action: proto::describe_cross_host(&request.tool, &request.args),
                        guest_driving: request.guest_driving.clone(),
                        expires_at: request.expires_at,
                    };
                    book.cards
                        .insert(card.key.clone(), OpenCard { request, to });
                    card
                };
                self.inner
                    .listener
                    .on_cross_host_event(CrossHostEvent::Card(card));
            }
        }
    }

    fn client(&self, id: &str) -> Option<Arc<Client>> {
        lock(&self.inner.book)
            .host(id)
            .and_then(RelayHost::client)
            .cloned()
    }

    /// Claims the request with `option` and, when this device wins an allow, runs it on `to`
    /// and sends the outcome back.
    fn perform(
        &self,
        from: &str,
        to: &str,
        request: CrossHostRequest,
        consent: Consent,
        option: OptionId,
    ) {
        let (Some(asking), Some(target)) = (self.client(from), self.client(to)) else {
            return;
        };
        let relay = self.clone();
        let from = from.to_owned();
        let to = to.to_owned();
        asking.handle.clone().spawn(async move {
            if !asking.claim_cross_host(request.id, option).await {
                return;
            }
            if option == CrossHostRequest::DENY {
                return;
            }
            relay.remember(&from, &to, &request, consent);
            let host_name = lock(&relay.inner.book)
                .host(&from)
                .map(|host| host.name.clone())
                .unwrap_or_default();
            let call = RemoteCall {
                on_behalf_of: RemoteAgent {
                    host: asking.daemon_id(),
                    host_name,
                    pane_id: request.pane_id,
                    agent_key: request.agent_key,
                    agent: request.agent.clone(),
                },
                consent,
                session: target.attached_session(),
                tool: request.tool.clone(),
                args: request.args.clone(),
            };
            let outcome = target.remote_call(call).await;
            asking.send_cross_host(CrossHostMsg::Result {
                id: request.id,
                outcome,
            });
        });
    }

    /// A won allow: reads from then on, or everything for "Allow all".
    fn remember(&self, from: &str, to: &str, request: &CrossHostRequest, consent: Consent) {
        let scope = match consent {
            Consent::Once => StandingScope::Reads,
            Consent::Agent => StandingScope::All,
            Consent::Reads => return,
        };
        let agent = AgentOnHost {
            from: from.to_owned(),
            pane_id: request.pane_id,
            agent_key: request.agent_key,
            to: to.to_owned(),
        };
        {
            let mut book = lock(&self.inner.book);
            let current = book.standing.get(&agent).map(|standing| standing.scope);
            if current == Some(StandingScope::All) {
                return;
            }
            book.standing.insert(
                agent,
                Standing {
                    scope,
                    agent: request.agent.clone(),
                },
            );
        }
        self.standing_changed();
    }

    /// Tells each target host that these agents are gone, so their panes go back to the user.
    fn tell_targets(&self, agents: Vec<AgentOnHost>) {
        for agent in agents {
            let (Some(asking), Some(target)) = (self.client(&agent.from), self.client(&agent.to))
            else {
                continue;
            };
            if target.offers_cross_host() {
                target.send_cross_host(CrossHostMsg::AgentGone {
                    host: asking.daemon_id(),
                    pane_id: agent.pane_id,
                    agent_key: agent.agent_key,
                });
            }
        }
    }

    fn standing_changed(&self) {
        let list = self.standing();
        self.inner
            .listener
            .on_cross_host_event(CrossHostEvent::Standing(list));
    }

    /// Sends each owner host the list of the others.
    fn send_directories(&self) {
        let lists: Vec<(Arc<Client>, Vec<HostEntry>)> = {
            let book = lock(&self.inner.book);
            book.hosts
                .iter()
                .filter_map(|host| {
                    let client = host.client()?;
                    Some((Arc::clone(client), book.directory(&host.id, reach)))
                })
                .collect()
        };
        for (client, entries) in lists {
            client.set_cross_host_directory(entries);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(host: &str, tool: &str) -> CrossHostRequest {
        CrossHostRequest {
            id: RequestId(1),
            pane_id: PaneId(3),
            agent_key: 9,
            agent: "Claude".into(),
            host: host.into(),
            tool: tool.into(),
            args: "{}".into(),
            guest_driving: None,
            expires_at: UnixMillis(0),
        }
    }

    /// A book of hosts `mac` and `ops` as owner (both reachable per `ready`), `theirs` as a
    /// guest and `pi` over SSH. Owner hosts need a client, so they are judged through
    /// `reach` alone: `answers_to` is checked on names.
    fn book() -> Book {
        Book {
            hosts: vec![
                RelayHost::guest("mac", "mac"),
                RelayHost::guest("theirs", "theirs"),
                RelayHost::ssh_only("pi", "pi"),
            ],
            ..Book::default()
        }
    }

    #[test]
    fn guests_plain_ssh_hosts_and_unknown_names_are_refused() {
        let book = book();
        let refusal = |host: &str| match book.judge("mac", &request(host, "pane_list"), |_| None) {
            Verdict::Refuse(refusal) => refusal,
            other => panic!("{other:?}"),
        };
        assert_eq!(
            refusal("THEIRS"),
            CrossHostRefusal::Guest {
                host: "theirs".into()
            }
        );
        assert_eq!(
            refusal("pi"),
            CrossHostRefusal::NoHelper { host: "pi".into() }
        );
        assert_eq!(
            refusal("nowhere"),
            CrossHostRefusal::UnknownHost {
                host: "nowhere".into()
            }
        );
        assert_eq!(refusal("mac"), CrossHostRefusal::SameHost);
        assert_eq!(
            refusal(""),
            CrossHostRefusal::UnknownHost { host: "".into() }
        );
    }

    #[test]
    fn a_host_the_device_cannot_reach_is_offline_once_turned_on() {
        let mut book = book();
        book.hosts.push(RelayHost::unreached("ops", "ops"));
        let judged = |book: &Book| book.judge("mac", &request("ops", "pane_list"), reach);
        assert_eq!(
            judged(&book),
            Verdict::Refuse(CrossHostRefusal::NotEnabled { host: "ops".into() })
        );
        book.pairs.insert(("mac".into(), "ops".into()));
        assert_eq!(
            judged(&book),
            Verdict::Refuse(CrossHostRefusal::Offline { host: "ops".into() })
        );
        let listed = book.directory("mac", reach);
        assert_eq!(
            listed.last().map(|entry| entry.state),
            Some(PairState::Offline)
        );
    }

    #[test]
    fn directories_never_list_the_asking_host() {
        let book = book();
        let listed = book.directory("mac", |_| None);
        let names: Vec<(&str, PairState)> = listed
            .iter()
            .map(|entry| (entry.name.as_str(), entry.state))
            .collect();
        assert_eq!(
            names,
            [("theirs", PairState::Guest), ("pi", PairState::NoHelper)]
        );
    }

    #[test]
    fn ending_standing_yeses_reports_whom_to_tell() {
        let mut book = book();
        let agent = |pane, to: &str| AgentOnHost {
            from: "mac".into(),
            pane_id: PaneId(pane),
            agent_key: 1,
            to: to.into(),
        };
        for (pane, to) in [(1, "ops"), (2, "ops"), (1, "box")] {
            book.standing.insert(
                agent(pane, to),
                Standing {
                    scope: StandingScope::All,
                    agent: "Claude".into(),
                },
            );
        }
        let mut ended = book.end_standing(|agent| agent.to == "ops");
        ended.sort_by_key(|agent| agent.pane_id);
        assert_eq!(ended, [agent(1, "ops"), agent(2, "ops")]);
        assert_eq!(book.standing.len(), 1);
    }

    #[test]
    fn guests_never_announce_the_capability() {
        let asked = crate::ConnectOptions {
            cross_host: true,
            ..crate::ConnectOptions::default()
        };
        assert!(announces(&asked, false));
        assert!(!announces(&asked, true));
        assert!(!announces(&crate::ConnectOptions::default(), false));
    }

    #[test]
    fn a_daemon_cannot_push_requests_to_a_connection_that_did_not_ask() {
        let state = CrossHostState::default();
        let (listener, mut pushes) = CrossHostPushQueue::channel();
        *lock(&state.listener) = Some(listener);
        let push = || ServerCtl::CrossHost(CrossHostPush::Request(request("ops", "pane_list")));
        assert!(state.dispatch(push(), false).is_none());
        assert!(pushes.try_recv().is_err(), "dropped, not delivered");
        assert!(state.dispatch(push(), true).is_none());
        assert!(pushes.try_recv().is_ok());
    }
}
