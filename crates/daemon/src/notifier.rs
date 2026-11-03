//! Push notifications through the push relay (ARCHITECTURE D16, `docs/PUSH.md`).
//!
//! Devices register over their own connection with an opaque push capability (issued by the
//! relay, which alone can open it) and an X25519 key. When an attention item stays unseen for
//! [`PushConfig::delay`](crate::PushConfig::delay), the daemon seals a [`push::Notification`]
//! to each registered device that wants that kind and is not looking at this host right now,
//! signs a [`push::RelayRequest`] with its iroh key and POSTs it to the relay, retrying
//! transient failures with exponential back-off. A `410` from the relay (APNs says the token
//! is gone) drops the registration.
//!
//! Approval notifications carry an [`push::ActionToken`]: the app's action handler returns it
//! with its decision over iroh ([`action`]), signed with the device key, so Approve / Deny work
//! from the lock screen without opening the app.
//!
//! The agents Live Activity ([`activity`]) goes the same way: a summary of this host's agents,
//! sealed to the device, as `start` (push-to-start), `update` and `end` pushes.
//!
//! Registrations persist in `<state>/push.json` (mode 0600).

mod activity;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use proto::{
    Actor, AttentionItem, AttentionKind, AttentionSeen, AttentionUpdate, Decide, Decided, DeviceId,
    PaneId, PushActionRequest, PushActivityToken, PushAgentRule, PushPrefs, PushRegistration,
    PushStatus, UnixMillis, WsError,
};
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast::error::RecvError;

use crate::core::{Core, Event, lock};
use crate::fsutil::{hex, read_optional, unhex, write_atomic};
use crate::identity::now_millis;

const STORE_FILE: &str = "push.json";
/// Longest capability accepted (the relay's are about 200 bytes).
const MAX_CAP_LEN: usize = 4096;
/// Most per-agent rules a device may keep.
const MAX_AGENT_RULES: usize = 32;
/// Longest one-line summary in a "finished" notification, in characters.
const SUMMARY_CHARS: usize = 140;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Registration {
    /// Device key, hex.
    device: String,
    cap: String,
    /// X25519 public key, hex.
    seal_key: String,
    relay_url: Option<String>,
    prefs: PushPrefs,
    /// Push-to-start capability for the agents Live Activity.
    #[serde(default)]
    activity_cap: Option<String>,
    /// The running Live Activity's update capability (`PushActivity`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    activity_update_cap: Option<String>,
    /// Per-agent choices (`PushAgents`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    agents: Vec<PushAgentRule>,
    registered_at: u64,
}

/// Registered devices and delivery state.
pub(crate) struct Push {
    path: PathBuf,
    registrations: Mutex<Vec<Registration>>,
    /// Last delivery error per device (hex), cleared on success.
    errors: Mutex<HashMap<String, String>>,
    http: OnceLock<reqwest::Client>,
    /// Wakes the Live Activity task (a device's activity token changed).
    activity_wake: tokio::sync::Notify,
    /// What each device's Live Activity was sent (hex device key).
    activities: Mutex<HashMap<String, activity::DeviceState>>,
    /// What is left of the relay's alert budgets.
    budgets: Mutex<Budgets>,
    /// When each device was last sent a "finished" push for a pane.
    finished_sent: Mutex<HashMap<(String, PaneId), Instant>>,
}

/// A rate the push relay enforces: `burst` at once, then one every `every`.
#[derive(Debug, Clone, Copy)]
struct Budget {
    burst: u32,
    every: Duration,
}

/// Alerts the relay accepts (docs/PUSH.md §9): per daemon 30 at once then one every 3 s, per
/// device 30 then one every 12 s. Past them it only refuses (and retries pile up), so pushes
/// past them wait their turn instead.
const DAEMON_ALERTS: Budget = Budget {
    burst: 30,
    every: Duration::from_secs(3),
};
const DEVICE_ALERTS: Budget = Budget {
    burst: 30,
    every: Duration::from_secs(12),
};

/// Pushes left in a budget, refilled over time.
#[derive(Debug, Clone, Copy)]
struct Bucket {
    tokens: f64,
    at: Instant,
}

impl Bucket {
    fn full(budget: Budget, now: Instant) -> Self {
        Self {
            tokens: f64::from(budget.burst),
            at: now,
        }
    }

    fn refill(&mut self, budget: Budget, now: Instant) {
        let earned =
            now.saturating_duration_since(self.at).as_secs_f64() / budget.every.as_secs_f64();
        self.tokens = (self.tokens + earned).min(f64::from(budget.burst));
        self.at = now;
    }

    /// How long until a whole push is available (after [`refill`](Self::refill)).
    fn wait(&self, budget: Budget) -> Duration {
        if self.tokens >= 1.0 {
            Duration::ZERO
        } else {
            budget.every.mul_f64(1.0 - self.tokens)
        }
    }
}

/// The relay's alert budgets as this daemon has spent them.
#[derive(Debug)]
struct Budgets {
    daemon: Bucket,
    devices: HashMap<String, Bucket>,
    /// The relay answered 429: nothing goes out before this.
    paused_until: Option<Instant>,
}

impl Budgets {
    fn new(now: Instant) -> Self {
        Self {
            daemon: Bucket::full(DAEMON_ALERTS, now),
            devices: HashMap::new(),
            paused_until: None,
        }
    }

    /// Takes one alert to `device` from both budgets; if either is spent, how long until
    /// both have one again.
    fn spend(&mut self, device: &str, now: Instant) -> Result<(), Duration> {
        let paused = self
            .paused_until
            .map_or(Duration::ZERO, |until| until.saturating_duration_since(now));
        self.daemon.refill(DAEMON_ALERTS, now);
        let own = self
            .devices
            .entry(device.to_owned())
            .or_insert_with(|| Bucket::full(DEVICE_ALERTS, now));
        own.refill(DEVICE_ALERTS, now);
        let wait = paused
            .max(self.daemon.wait(DAEMON_ALERTS))
            .max(own.wait(DEVICE_ALERTS));
        if !wait.is_zero() {
            return Err(wait);
        }
        self.daemon.tokens -= 1.0;
        own.tokens -= 1.0;
        Ok(())
    }
}

impl Push {
    pub fn load(state_dir: &Path) -> Self {
        let path = state_dir.join(STORE_FILE);
        let registrations = match read_optional(&path) {
            Ok(Some(bytes)) => serde_json::from_slice(&bytes).unwrap_or_else(|error| {
                tracing::warn!("ignoring malformed {}: {error}", path.display());
                Vec::new()
            }),
            Ok(None) => Vec::new(),
            Err(error) => {
                tracing::warn!("reading {}: {error}", path.display());
                Vec::new()
            }
        };
        Self {
            path,
            registrations: Mutex::new(registrations),
            errors: Mutex::new(HashMap::new()),
            http: OnceLock::new(),
            activity_wake: tokio::sync::Notify::new(),
            activities: Mutex::new(HashMap::new()),
            budgets: Mutex::new(Budgets::new(Instant::now())),
            finished_sent: Mutex::new(HashMap::new()),
        }
    }

    fn save(&self, registrations: &[Registration]) {
        let result = serde_json::to_vec_pretty(registrations)
            .map_err(std::io::Error::other)
            .and_then(|bytes| write_atomic(&self.path, &bytes));
        if let Err(error) = result {
            tracing::warn!("saving {}: {error}", self.path.display());
        }
    }

    fn registrations(&self) -> Vec<Registration> {
        lock(&self.registrations).clone()
    }

    fn remove(&self, device: &str) {
        let mut registrations = lock(&self.registrations);
        let before = registrations.len();
        registrations.retain(|registration| registration.device != device);
        if registrations.len() != before {
            self.save(&registrations);
        }
    }

    /// Changes one device's registration; saved when `edit` returns true.
    fn update(&self, device: &str, edit: impl FnOnce(&mut Registration) -> bool) {
        let mut registrations = lock(&self.registrations);
        let Some(registration) = registrations
            .iter_mut()
            .find(|registration| registration.device == device)
        else {
            return;
        };
        if edit(registration) {
            self.save(&registrations);
        }
    }

    fn http(&self) -> &reqwest::Client {
        self.http.get_or_init(http_client)
    }
}

/// Drops the registrations of revoked devices: a revoked device may be lost or stolen, and
/// must not keep receiving sealed prompts or action tokens.
pub(crate) fn drop_revoked(core: &Core) {
    let mut registrations = lock(&core.push.registrations);
    let before = registrations.len();
    registrations.retain(|registration| {
        unhex::<32>(&registration.device)
            .is_some_and(|device| !core.mp.device_removed(DeviceId(device)))
    });
    if registrations.len() != before {
        core.push.save(&registrations);
    }
}

/// The registrations to push to now.
fn targets(core: &Core) -> Vec<Registration> {
    drop_revoked(core);
    core.push.registrations()
}

/// An HTTPS client on rustls/ring with the web roots (reqwest is built without a default
/// crypto provider, as iroh-relay uses it).
pub(crate) fn http_client() -> reqwest::Client {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .expect("ring supports the default TLS versions")
    .with_root_certificates(roots)
    .with_no_client_auth();
    reqwest::Client::builder()
        .use_preconfigured_tls(tls)
        .timeout(Duration::from_secs(15))
        .user_agent(format!(
            "{}/{}",
            brand::DAEMON_BIN,
            env!("CARGO_PKG_VERSION")
        ))
        .build()
        .expect("the HTTP client builds")
}

/// `PushRegister`: adds or replaces the asking device's registration.
pub(crate) fn register(
    core: &Core,
    actor: Actor,
    registration: PushRegistration,
) -> Result<PushStatus, WsError> {
    if registration.cap.is_empty() || registration.cap.len() > MAX_CAP_LEN {
        return Err(WsError::Invalid("bad push capability".into()));
    }
    // A small-order point would make every seal fail; refuse it now.
    if push::hpke::seal(&registration.seal_key, b"", b"", b"").is_err() {
        return Err(WsError::Invalid("bad sealing key".into()));
    }
    if let Some(url) = &registration.relay_url
        && !(url.starts_with("https://") || url.starts_with("http://"))
    {
        return Err(WsError::Invalid(format!("relay url {url:?}")));
    }
    let device = hex(&actor.device.0);
    {
        let mut registrations = lock(&core.push.registrations);
        // A running Live Activity and the agent rules outlive a re-registration (each launch).
        let existing = registrations
            .iter()
            .find(|existing| existing.device == device);
        let activity_update_cap =
            existing.and_then(|existing| existing.activity_update_cap.clone());
        let agents = existing
            .map(|existing| existing.agents.clone())
            .unwrap_or_default();
        registrations.retain(|existing| existing.device != device);
        registrations.push(Registration {
            device: device.clone(),
            cap: registration.cap,
            seal_key: hex(&registration.seal_key),
            relay_url: registration.relay_url,
            prefs: registration.prefs,
            activity_cap: registration.activity_cap,
            activity_update_cap,
            agents,
            registered_at: now_millis(),
        });
        core.push.save(&registrations);
    }
    lock(&core.push.errors).remove(&device);
    core.push.activity_wake.notify_one();
    tracing::info!(device = %&device[..8], "push registration updated");
    Ok(status(core, actor.device))
}

/// `PushActivity`: the device's running agents Live Activity (its update capability), or that
/// it ended.
pub(crate) fn activity_token(
    core: &Core,
    actor: Actor,
    token: PushActivityToken,
) -> Result<PushStatus, WsError> {
    if let Some(cap) = &token.cap
        && (cap.is_empty() || cap.len() > MAX_CAP_LEN)
    {
        return Err(WsError::Invalid("bad activity capability".into()));
    }
    let device = hex(&actor.device.0);
    if !lock(&core.push.registrations)
        .iter()
        .any(|registration| registration.device == device)
    {
        return Err(WsError::NotFound("register for push first".into()));
    }
    activity::token_changed(core, &device, token.cap);
    Ok(status(core, actor.device))
}

/// `PushAgents`: which agents the asking device wants pushed.
pub(crate) fn agent_rules(
    core: &Core,
    actor: Actor,
    rules: Vec<PushAgentRule>,
) -> Result<PushStatus, WsError> {
    if rules.len() > MAX_AGENT_RULES || rules.iter().any(|rule| rule.agent.len() > 64) {
        return Err(WsError::Invalid("too many agent rules".into()));
    }
    let device = hex(&actor.device.0);
    if !lock(&core.push.registrations)
        .iter()
        .any(|registration| registration.device == device)
    {
        return Err(WsError::NotFound("register for push first".into()));
    }
    core.push.update(&device, |registration| {
        let changed = registration.agents != rules;
        registration.agents = rules;
        changed
    });
    Ok(status(core, actor.device))
}

/// `PushUnregister`.
pub(crate) fn unregister(core: &Core, actor: Actor) -> PushStatus {
    core.push.remove(&hex(&actor.device.0));
    status(core, actor.device)
}

/// `PushStatus`.
pub(crate) fn status(core: &Core, device: DeviceId) -> PushStatus {
    let device = hex(&device.0);
    let registrations = lock(&core.push.registrations);
    PushStatus {
        enabled: core.cfg.push.enabled,
        relay_url: core.cfg.push.relay_url.clone(),
        registered: registrations
            .iter()
            .find(|registration| registration.device == device)
            .map(|registration| registration.prefs),
        devices: registrations.len() as u32,
        last_error: lock(&core.push.errors).get(&device).cloned(),
    }
}

/// The pane and [`push::request_subject`] of request `id` while its agent waits on it.
fn open_subject(core: &Core, id: proto::RequestId) -> Option<(proto::PaneId, [u8; 32])> {
    let (pane, facts) = core.request_facts(id, None)?;
    let subject = push::request_subject(
        &facts.request.to_string(),
        facts.tool.as_deref(),
        &facts.summary,
    );
    Some((pane, subject))
}

/// `PushAction`: applies Approve / Deny from a notification.
pub(crate) fn action(
    core: &Core,
    actor: Actor,
    request: &PushActionRequest,
) -> Result<Decided, WsError> {
    let daemon = core.identity.daemon_id().0;
    let token =
        push::verify_token(&daemon, &request.token, UnixMillis(now_millis())).map_err(|error| {
            match error {
                push::PushError::Expired => {
                    WsError::Denied("the notification action expired".into())
                }
                _ => WsError::Denied("invalid action token".into()),
            }
        })?;
    if token.device != actor.device {
        return Err(WsError::Denied(
            "the action token is for another device".into(),
        ));
    }
    // Only the exact request the notification showed: same pane, same call, same content.
    if open_subject(core, token.request) != Some((token.pane, token.subject)) {
        return Err(WsError::NotFound(
            "the agent is no longer waiting for this".into(),
        ));
    }
    let decision = if request.approve {
        push::Decision::Approve
    } else {
        push::Decision::Deny
    };
    push::verify_decision(&actor.device.0, &request.token, decision, &request.sig)
        .map_err(|_| WsError::Denied("bad decision signature".into()))?;
    let option = match decision {
        push::Decision::Approve => token.approve,
        push::Decision::Deny => token.deny,
    }
    .ok_or_else(|| WsError::Invalid("the request has no such option".into()))?;
    // The same signed audit record as an in-app approval: the device signed
    // `DECISION_DOMAIN || token || decision`, which the audit log re-verifies.
    let signed = [
        push::DECISION_DOMAIN,
        &push::decision_message(&request.token, decision),
    ]
    .concat();
    // Push actions come from owner devices only, so only the two-person rule can hold them.
    let ballot = crate::mp::approvals::Ballot {
        actor,
        name: "The owner",
        owner: true,
    };
    // A drive request is the owner's alone; approval policies are for agents' tool calls.
    let gate = if core.term.asks.caller_of(token.request).is_some() {
        Ok(crate::mp::Gate::Proceed)
    } else {
        crate::mp::gate_decision(
            core,
            ballot,
            token.request,
            option,
            (signed.clone(), request.sig.clone()),
        )
    };
    match gate {
        Ok(crate::mp::Gate::Proceed) => {}
        Ok(crate::mp::Gate::Held) => {
            return Err(WsError::Conflict(
                "approval counted; a second person must approve too".into(),
            ));
        }
        Err(error) => return Err(WsError::Denied(error.to_string())),
    }
    let record = |decided: &Decided, details: &crate::agent::DecidedRequest| {
        core.mp.audit.append(
            proto::AuditKind::Approval,
            crate::mp::AuditEntry {
                actor: Some(actor),
                pane_id: Some(decided.pane_id),
                detail: format!(
                    "chose {:?} for {} from a notification",
                    details.option, details.summary
                ),
                approval: Some(proto::ApprovalAudit {
                    request_id: token.request,
                    agent_request: details.request.to_string(),
                    option_id: option,
                    option: details.option.clone(),
                    tool: details.tool.clone(),
                    summary: details.summary.clone(),
                    signed,
                    sig: request.sig.clone(),
                }),
                ..crate::mp::AuditEntry::default()
            },
        );
    };
    let decided = core
        .decide(
            actor,
            &Decide {
                request_id: token.request,
                option_id: option,
                actor,
                sig: request.sig.clone(),
            },
            record,
        )
        .map_err(|by| match by {
            Some(by) => WsError::Conflict(format!(
                "already decided by device {}",
                &hex(&by.device.0)[..8]
            )),
            None => WsError::NotFound("the agent is no longer waiting for this".into()),
        })?;
    core.mp.approvals.forget(token.request);
    tracing::info!(
        pane = decided.pane_id.0,
        approve = request.approve,
        "decision from a notification"
    );
    let seen = AttentionSeen {
        ids: vec![token.item],
        up_to: None,
        pane_id: None,
    };
    if let Some(update) = core.ws.attention.mark(&seen) {
        core.emit(Event::Attention(update));
    }
    Ok(decided)
}

/// Watches the attention feed and pushes items that stay unseen; runs the Live Activity.
pub(crate) async fn run(core: Arc<Core>) {
    tokio::spawn(activity::run(Arc::clone(&core)));
    let mut events = core.events.subscribe();
    loop {
        match events.recv().await {
            Ok(Event::Attention(AttentionUpdate::Added { item, .. })) if !item.seen => {
                tokio::spawn(deliver(Arc::clone(&core), item));
            }
            Ok(_) | Err(RecvError::Lagged(_)) => {}
            Err(RecvError::Closed) => return,
        }
    }
}

/// What to push for an item, and the approve / deny options if it is an approval.
fn classify(
    core: &Core,
    item: &AttentionItem,
) -> (push::Kind, Option<crate::agent::ApprovalButtons>) {
    match &item.kind {
        AttentionKind::AgentBlocked {
            request_id: Some(id),
            ..
        } if core.term.asks.caller_of(*id).is_some() => {
            // Approve allows this one action; a cut-off action is never approved blind.
            match core.term.asks.notice(*id) {
                Some((_, _, true)) => (
                    push::Kind::Approval,
                    Some(crate::agent::ApprovalButtons {
                        approve: Some((proto::DriveAsk::ALLOW_ONCE, "Allow once".into())),
                        deny: Some((proto::DriveAsk::DENY, "Deny".into())),
                    }),
                ),
                _ => (push::Kind::Blocked, None),
            }
        }
        AttentionKind::AgentBlocked { request_id, .. } => {
            let buttons = request_id.and_then(|id| {
                let entry = core.pane(item.pane_id)?;
                let agent = lock(&entry.agent);
                agent.as_ref()?.approval_options(id)
            });
            match buttons {
                Some(buttons) if buttons.approve.is_some() || buttons.deny.is_some() => {
                    (push::Kind::Approval, Some(buttons))
                }
                _ => (push::Kind::Blocked, None),
            }
        }
        AttentionKind::AgentDone { .. } => (push::Kind::Done, None),
        AttentionKind::AgentFailed { .. } => (push::Kind::Failed, None),
        AttentionKind::CommandFinished(_) => (push::Kind::Command, None),
    }
}

fn wants(prefs: &PushPrefs, kind: push::Kind) -> bool {
    match kind {
        push::Kind::Approval => prefs.approvals,
        push::Kind::Blocked => prefs.blocked,
        push::Kind::Done => prefs.done,
        push::Kind::Failed => prefs.failed,
        push::Kind::Command => prefs.commands,
    }
}

/// The agent an item is about (`claude`, `codex`), if any.
fn agent_of(item: &AttentionItem) -> Option<&str> {
    match &item.kind {
        AttentionKind::AgentBlocked { agent, .. }
        | AttentionKind::AgentDone { agent }
        | AttentionKind::AgentFailed { agent } => Some(agent),
        AttentionKind::CommandFinished(_) => None,
    }
}

/// [`wants`], then the device's rule for the agent (or for other agents).
fn registration_wants(registration: &Registration, kind: push::Kind, agent: Option<&str>) -> bool {
    if !wants(&registration.prefs, kind) {
        return false;
    }
    let Some(agent) = agent else {
        return true;
    };
    let rules = &registration.agents;
    let rule = rules
        .iter()
        .find(|rule| rule.agent == agent)
        .or_else(|| rules.iter().find(|rule| rule.agent == PushAgentRule::OTHER));
    rule.is_none_or(|rule| match kind {
        push::Kind::Approval | push::Kind::Blocked => rule.needs_you,
        push::Kind::Done | push::Kind::Failed => rule.finished,
        push::Kind::Command => true,
    })
}

fn is_finished(kind: push::Kind) -> bool {
    matches!(kind, push::Kind::Done | push::Kind::Failed)
}

/// Debounce: not seen meanwhile (a client focused the pane, the blocker went away), and no
/// newer item for the same pane that will be pushed instead.
fn still_due(core: &Core, item: &AttentionItem) -> bool {
    core.ws
        .attention
        .get(item.id)
        .is_some_and(|current| !current.seen)
        && !core.ws.attention.superseded(item.id, item.pane_id)
        && !(matches!(
            item.kind,
            AttentionKind::AgentDone { .. } | AttentionKind::AgentFailed { .. }
        ) && agent_working(core, item.pane_id))
}

/// A turn that ended and went straight on (a stop hook, queued input) is not finished.
fn agent_working(core: &Core, pane: PaneId) -> bool {
    core.pane(pane).is_some_and(|entry| {
        lock(&entry.agent)
            .as_ref()
            .is_some_and(|agent| agent.state() == agents::AgentState::Working)
    })
}

async fn deliver(core: Arc<Core>, item: AttentionItem) {
    if !core.cfg.push.enabled || lock(&core.push.registrations).is_empty() {
        return;
    }
    tokio::time::sleep(core.cfg.push.delay).await;
    if !still_due(&core, &item) {
        return;
    }
    let (kind, buttons) = classify(&core, &item);
    let host = crate::ws::tunnel::hostname();
    for registration in targets(&core) {
        if !registration_wants(&registration, kind, agent_of(&item)) {
            continue;
        }
        let Some(device) = unhex::<32>(&registration.device).map(DeviceId) else {
            continue;
        };
        if core.device_active(device) {
            tracing::debug!(item = item.id, "device is looking at this host; no push");
            continue;
        }
        let core = Arc::clone(&core);
        let (item, host, buttons) = (item.clone(), host.clone(), buttons.clone());
        tokio::spawn(async move {
            if is_finished(kind) {
                let key = (registration.device.clone(), item.pane_id);
                let last = lock(&core.push.finished_sent).get(&key).copied();
                if let Some(last) = last {
                    let wait = core.cfg.push.pane_interval.saturating_sub(last.elapsed());
                    if !wait.is_zero() {
                        tokio::time::sleep(wait).await;
                        if !still_due(&core, &item) || core.device_active(device) {
                            return;
                        }
                    }
                }
                lock(&core.push.finished_sent).insert(key, Instant::now());
            }
            // Past the relay's budget a push waits its turn, and goes only if still due.
            loop {
                let wait =
                    match lock(&core.push.budgets).spend(&registration.device, Instant::now()) {
                        Ok(()) => break,
                        Err(wait) => wait,
                    };
                tokio::time::sleep(wait).await;
                if !still_due(&core, &item) || core.device_active(device) {
                    return;
                }
            }
            let result = send(
                &core,
                &registration,
                device,
                &item,
                kind,
                buttons.as_ref(),
                &host,
            )
            .await;
            match result {
                Ok(()) => {
                    lock(&core.push.errors).remove(&registration.device);
                }
                Err(SendError::Gone) => {
                    tracing::info!(device = %&registration.device[..8], "push token gone; unregistering");
                    core.push.remove(&registration.device);
                }
                Err(SendError::Failed(why)) => {
                    tracing::warn!(device = %&registration.device[..8], "push failed: {why}");
                    lock(&core.push.errors).insert(registration.device.clone(), why);
                }
            }
        });
    }
}

#[derive(Debug)]
enum SendError {
    /// The relay says the device's APNs token is no longer valid.
    Gone,
    Failed(String),
}

fn notification(
    core: &Core,
    device: DeviceId,
    item: &AttentionItem,
    kind: push::Kind,
    buttons: Option<&crate::agent::ApprovalButtons>,
    host: &str,
) -> push::Notification {
    let seed = core.identity.secret.to_bytes();
    let action = match (&item.kind, buttons) {
        (
            AttentionKind::AgentBlocked {
                request_id: Some(request),
                ..
            },
            Some(buttons),
        ) => open_subject(core, *request).map(|(_, subject)| {
            let expires = UnixMillis(now_millis() + core.cfg.push.action_ttl.as_millis() as u64);
            let token = push::ActionToken {
                v: push::ActionToken::VERSION,
                daemon: core.identity.daemon_id(),
                device,
                pane: item.pane_id,
                request: *request,
                approve: buttons.approve.as_ref().map(|(id, _)| *id),
                deny: buttons.deny.as_ref().map(|(id, _)| *id),
                item: item.id,
                expires,
                subject,
            };
            push::ActionOffer {
                token: push::b64(&push::issue_token(&seed, &token)),
                approve: buttons
                    .approve
                    .as_ref()
                    .map_or_else(String::new, |(_, label)| label.clone()),
                deny: buttons
                    .deny
                    .as_ref()
                    .map_or_else(String::new, |(_, label)| label.clone()),
                expires: expires.0,
            }
        }),
        _ => None,
    };
    push::Notification {
        v: push::Notification::VERSION,
        daemon: hex(&core.identity.daemon_id().0),
        host: host.to_owned(),
        kind,
        item: item.id,
        pane: item.pane_id.0,
        session: item.session_id.map(|session| session.0),
        title: title(core, item),
        place: place(core, item.pane_id),
        body: body(item),
        at: item.at.0,
        action,
    }
}

/// The agent's product name.
fn agent_name(agent: &str) -> String {
    match agent {
        "claude" => "Claude Code".to_owned(),
        "codex" => "Codex".to_owned(),
        other => {
            let mut chars = other.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().chain(chars).collect())
                .unwrap_or_else(|| "Agent".to_owned())
        }
    }
}

/// A drive request keeps its own title (what the agent wants to do).
fn title(core: &Core, item: &AttentionItem) -> String {
    match &item.kind {
        AttentionKind::AgentBlocked {
            request_id: Some(request),
            ..
        } if core.term.asks.caller_of(*request).is_some() => item.title.clone(),
        AttentionKind::AgentBlocked { agent, .. } => format!("{} needs you", agent_name(agent)),
        AttentionKind::AgentDone { agent } => format!("{} finished", agent_name(agent)),
        AttentionKind::AgentFailed { agent } => format!("{} failed", agent_name(agent)),
        AttentionKind::CommandFinished(_) => item.title.clone(),
    }
}

/// A finished turn says its first line; the rest of the message is in the app.
fn body(item: &AttentionItem) -> String {
    match &item.kind {
        AttentionKind::AgentDone { .. } => {
            summary_line(&item.body).unwrap_or_else(|| "Finished".to_owned())
        }
        AttentionKind::AgentFailed { .. } => {
            summary_line(&item.body).unwrap_or_else(|| "The turn ended with an error.".to_owned())
        }
        _ => item.body.clone(),
    }
}

/// The first line of a message with words in it, without Markdown heading, list and emphasis
/// marks, cut to [`SUMMARY_CHARS`].
fn summary_line(message: &str) -> Option<String> {
    let line = message
        .lines()
        .map(|line| {
            line.trim()
                .trim_start_matches(['#', '>', '-', '*', '+'])
                .trim()
        })
        .find(|line| line.chars().any(char::is_alphanumeric))?;
    let plain = line.replace("**", "").replace('`', "");
    let clean = proto::clean_prompt_text(&plain, SUMMARY_CHARS);
    (!clean.is_empty()).then_some(clean)
}

/// The pane's project, else its tab's name, else its directory's name.
fn place(core: &Core, pane: PaneId) -> Option<String> {
    let named = {
        let layout = lock(&core.layout);
        layout
            .project_of_pane(pane)
            .or_else(|| layout.tab_name_of_pane(pane))
    };
    let name = named.or_else(|| {
        let entry = core.pane(pane)?;
        let cwd = lock(&entry.meta).cwd.clone()?;
        std::path::Path::new(&cwd)
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
    })?;
    let clean = proto::clean_prompt_text(&name, 60);
    (!clean.is_empty()).then_some(clean)
}

/// Lock-screen Approve only for what the notification shows in full: an approval whose summary
/// was cut (`…`, here or by the agent's adapter) goes out with Open only, and the app shows
/// the whole request.
fn open_only(note: &mut push::Notification) {
    if note.kind == push::Kind::Approval {
        note.kind = push::Kind::Blocked;
        note.action = None;
    }
}

async fn send(
    core: &Core,
    registration: &Registration,
    device: DeviceId,
    item: &AttentionItem,
    kind: push::Kind,
    buttons: Option<&crate::agent::ApprovalButtons>,
    host: &str,
) -> Result<(), SendError> {
    let seal_key = unhex::<32>(&registration.seal_key)
        .ok_or_else(|| SendError::Failed("bad sealing key on file".into()))?;
    let seed = core.identity.secret.to_bytes();
    let mut note = notification(core, device, item, kind, buttons, host);
    if note.body.ends_with('…') {
        open_only(&mut note);
    }
    let sealed = loop {
        let json =
            serde_json::to_vec(&note).map_err(|error| SendError::Failed(error.to_string()))?;
        match push::seal(&seal_key, &seed, &json) {
            Ok(sealed) => break sealed,
            // Too long for APNs: shorten the body and try again.
            Err(push::PushError::TooLarge(_)) if note.body.len() > 64 => {
                let keep = note.body.chars().count() / 2;
                note.body = note.body.chars().take(keep).collect::<String>() + "…";
                open_only(&mut note);
            }
            Err(error) => return Err(SendError::Failed(format!("sealing: {error}"))),
        }
    };
    let kind = note.kind;
    let collapse = push::collapse_id(&seed, item.pane_id, kind.category());
    let attempts = core.cfg.push.attempts;
    post(core, registration, attempts, || push::RelayRequest {
        v: push::RelayRequest::VERSION,
        daemon: String::new(),
        cap: registration.cap.clone(),
        push_type: push::PushType::Alert,
        category: Some(kind.category()),
        collapse: Some(collapse.clone()),
        sealed: sealed.clone(),
        ts: 0,
        nonce: String::new(),
        event: None,
        stale: None,
        dismiss: None,
        urgent: false,
    })
    .await
}

/// Signs and POSTs a relay request (from `make`, given a fresh daemon key, `ts` and nonce on
/// each attempt: the relay refuses replays) to the device's relay, retrying 429 / 5xx /
/// network errors with exponential back-off up to `attempts` times.
async fn post(
    core: &Core,
    registration: &Registration,
    attempts: u32,
    make: impl Fn() -> push::RelayRequest,
) -> Result<(), SendError> {
    let seed = core.identity.secret.to_bytes();
    let relay = registration
        .relay_url
        .clone()
        .unwrap_or_else(|| core.cfg.push.relay_url.clone());
    let url = format!("{}/v1/push", relay.trim_end_matches('/'));
    let daemon = hex(&core.identity.daemon_id().0);

    let mut backoff = core.cfg.push.backoff;
    let mut last = String::new();
    let attempts = attempts.max(1);
    for attempt in 1..=attempts {
        let request = push::RelayRequest {
            daemon: daemon.clone(),
            ts: now_millis(),
            nonce: push::nonce(),
            ..make()
        };
        let body =
            serde_json::to_vec(&request).map_err(|error| SendError::Failed(error.to_string()))?;
        let signature = push::sign_request(&seed, &body);
        let response = core
            .push
            .http()
            .post(&url)
            .header("content-type", "application/json")
            .header(push::SIGNATURE_HEADER, signature)
            .body(body)
            .send()
            .await;
        let wait = match response {
            Ok(reply) if reply.status().is_success() => {
                tracing::debug!(attempt, "pushed");
                return Ok(());
            }
            Ok(reply) if reply.status().as_u16() == 410 => return Err(SendError::Gone),
            Ok(reply) if reply.status().as_u16() == 429 || reply.status().is_server_error() => {
                let retry_after = reply
                    .headers()
                    .get("retry-after")
                    .and_then(|value| value.to_str().ok())
                    .and_then(|value| value.parse::<u64>().ok())
                    .map(Duration::from_secs);
                last = format!("relay answered {}", reply.status());
                let wait = retry_after.unwrap_or(backoff).min(Duration::from_secs(300));
                if reply.status().as_u16() == 429 {
                    lock(&core.push.budgets).paused_until = Some(Instant::now() + wait);
                }
                wait
            }
            Ok(reply) => {
                let status = reply.status();
                let text = reply.text().await.unwrap_or_default();
                return Err(SendError::Failed(format!(
                    "relay refused the push: {status} {}",
                    text.chars().take(200).collect::<String>()
                )));
            }
            Err(error) => {
                last = format!("posting to {url}: {error}");
                backoff
            }
        };
        if attempt < attempts {
            tokio::time::sleep(wait).await;
            backoff *= 2;
        }
    }
    Err(SendError::Failed(last))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefs_filter_kinds() {
        let prefs = PushPrefs {
            done: false,
            ..PushPrefs::default()
        };
        assert!(wants(&prefs, push::Kind::Approval));
        assert!(!wants(&prefs, push::Kind::Done));
        assert!(wants(&prefs, push::Kind::Failed));
    }

    fn registration(agents: Vec<PushAgentRule>) -> Registration {
        Registration {
            device: "ab".repeat(32),
            cap: "cap".into(),
            seal_key: "cd".repeat(32),
            relay_url: None,
            prefs: PushPrefs::default(),
            activity_cap: None,
            activity_update_cap: None,
            agents,
            registered_at: 1,
        }
    }

    fn rule(agent: &str, needs_you: bool, finished: bool) -> PushAgentRule {
        PushAgentRule {
            agent: agent.into(),
            needs_you,
            finished,
        }
    }

    #[test]
    fn agent_rules_filter_per_agent_with_a_fallback() {
        let everything = registration(Vec::new());
        assert!(registration_wants(
            &everything,
            push::Kind::Done,
            Some("codex")
        ));

        let rules = registration(vec![
            rule("codex", true, false),
            rule(PushAgentRule::OTHER, false, true),
        ]);
        assert!(registration_wants(
            &rules,
            push::Kind::Approval,
            Some("codex")
        ));
        assert!(registration_wants(
            &rules,
            push::Kind::Blocked,
            Some("codex")
        ));
        assert!(!registration_wants(&rules, push::Kind::Done, Some("codex")));
        assert!(!registration_wants(
            &rules,
            push::Kind::Failed,
            Some("codex")
        ));
        assert!(registration_wants(&rules, push::Kind::Done, Some("claude")));
        assert!(!registration_wants(
            &rules,
            push::Kind::Blocked,
            Some("claude")
        ));
        assert!(registration_wants(&rules, push::Kind::Command, None));

        let mut off = registration(vec![rule("claude", true, true)]);
        off.prefs.done = false;
        assert!(!registration_wants(&off, push::Kind::Done, Some("claude")));
    }

    #[test]
    fn finished_turns_say_their_first_line() {
        assert_eq!(
            summary_line("## Summary\n\nRenamed `foo` to **bar** in 12 files.\n- Tests pass")
                .as_deref(),
            Some("Summary")
        );
        assert_eq!(
            summary_line("\n  - Renamed `foo` to **bar**.\nMore.").as_deref(),
            Some("Renamed foo to bar.")
        );
        assert_eq!(summary_line("---\n\n```\n"), None);
        let long = "word ".repeat(100);
        assert!(summary_line(&long).unwrap().chars().count() <= SUMMARY_CHARS + 1);
        assert_eq!(agent_name("claude"), "Claude Code");
        assert_eq!(agent_name("codex"), "Codex");
        assert_eq!(agent_name("pi"), "Pi");
    }

    #[test]
    fn alerts_stay_within_the_relays_budgets() {
        let start = Instant::now();
        let mut budgets = Budgets::new(start);
        let sent = (0..100)
            .filter(|_| budgets.spend("a", start).is_ok())
            .count();
        assert_eq!(sent, 30, "a burst stops at the budget");
        let wait = budgets
            .spend("a", start + Duration::from_secs(11))
            .unwrap_err();
        assert!(
            wait.abs_diff(Duration::from_secs(1)) < Duration::from_millis(1),
            "the next one is due a second later, not {wait:?}"
        );
        assert_eq!(budgets.spend("a", start + Duration::from_secs(12)), Ok(()));
        // The daemon's budget earned 4 in those 12 s, one of them spent above.
        let other = (0..100)
            .filter(|_| budgets.spend("b", start + Duration::from_secs(12)).is_ok())
            .count();
        assert_eq!(other, 3);
        // A 429 holds everything back until its retry-after.
        let later = start + Duration::from_secs(600);
        budgets.paused_until = Some(later + Duration::from_secs(5));
        assert_eq!(budgets.spend("c", later), Err(Duration::from_secs(5)));
        assert_eq!(budgets.spend("c", later + Duration::from_secs(5)), Ok(()));
    }

    #[test]
    fn store_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let push = Push::load(dir.path());
        let registration = Registration {
            device: "ab".repeat(32),
            cap: "cap".into(),
            seal_key: "cd".repeat(32),
            relay_url: None,
            prefs: PushPrefs::default(),
            activity_cap: None,
            activity_update_cap: Some("u".into()),
            agents: vec![rule("codex", true, false)],
            registered_at: 1,
        };
        lock(&push.registrations).push(registration.clone());
        push.save(&lock(&push.registrations));
        assert_eq!(
            Push::load(dir.path()).registrations(),
            vec![registration.clone()]
        );
        push.remove(&registration.device);
        assert!(Push::load(dir.path()).registrations().is_empty());
    }
}
