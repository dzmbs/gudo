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
    PushActionRequest, PushActivityToken, PushPrefs, PushRegistration, PushStatus, UnixMillis,
    WsError,
};
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast::error::RecvError;

use crate::core::{Core, Event, lock};
use crate::fsutil::{hex, read_optional, unhex, write_atomic};
use crate::identity::now_millis;

const STORE_FILE: &str = "push.json";
/// Longest capability accepted (the relay's are about 200 bytes).
const MAX_CAP_LEN: usize = 4096;

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
    registered_at: u64,
}

/// Registered devices and delivery state.
pub(crate) struct Push {
    path: PathBuf,
    regs: Mutex<Vec<Registration>>,
    /// Last delivery error per device (hex), cleared on success.
    errors: Mutex<HashMap<String, String>>,
    http: OnceLock<reqwest::Client>,
    /// Wakes the Live Activity task (a device's activity token changed).
    activity_wake: tokio::sync::Notify,
    /// What each device's Live Activity was sent (hex device key).
    activities: Mutex<HashMap<String, activity::DeviceState>>,
    /// What is left of the relay's alert budgets.
    budgets: Mutex<Budgets>,
}

/// A rate the push relay enforces: `burst` at once, then one every `every`.
#[derive(Debug, Clone, Copy)]
struct Budget {
    burst: u32,
    every: Duration,
}

/// Alerts the relay accepts (docs/PUSH.md §9): per daemon 30 at once then one every 3 s, per
/// device 30 then one every 12 s. Past them it only refuses, so an agent asking for approval in
/// a loop is pushed within them and the rest wait in the inbox.
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

    /// Takes one alert to `device` from both budgets, or nothing if either is spent.
    fn spend(&mut self, device: &str, now: Instant) -> bool {
        if self.paused_until.is_some_and(|until| now < until) {
            return false;
        }
        self.daemon.refill(DAEMON_ALERTS, now);
        let own = self
            .devices
            .entry(device.to_owned())
            .or_insert_with(|| Bucket::full(DEVICE_ALERTS, now));
        own.refill(DEVICE_ALERTS, now);
        if self.daemon.tokens < 1.0 || own.tokens < 1.0 {
            return false;
        }
        self.daemon.tokens -= 1.0;
        own.tokens -= 1.0;
        true
    }
}

impl Push {
    pub fn load(state_dir: &Path) -> Self {
        let path = state_dir.join(STORE_FILE);
        let regs = match read_optional(&path) {
            Ok(Some(bytes)) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                tracing::warn!("ignoring malformed {}: {e}", path.display());
                Vec::new()
            }),
            Ok(None) => Vec::new(),
            Err(e) => {
                tracing::warn!("reading {}: {e}", path.display());
                Vec::new()
            }
        };
        Self {
            path,
            regs: Mutex::new(regs),
            errors: Mutex::new(HashMap::new()),
            http: OnceLock::new(),
            activity_wake: tokio::sync::Notify::new(),
            activities: Mutex::new(HashMap::new()),
            budgets: Mutex::new(Budgets::new(Instant::now())),
        }
    }

    fn save(&self, regs: &[Registration]) {
        let result = serde_json::to_vec_pretty(regs)
            .map_err(std::io::Error::other)
            .and_then(|bytes| write_atomic(&self.path, &bytes));
        if let Err(e) = result {
            tracing::warn!("saving {}: {e}", self.path.display());
        }
    }

    fn registrations(&self) -> Vec<Registration> {
        lock(&self.regs).clone()
    }

    fn remove(&self, device: &str) {
        let mut regs = lock(&self.regs);
        let before = regs.len();
        regs.retain(|r| r.device != device);
        if regs.len() != before {
            self.save(&regs);
        }
    }

    /// Changes one device's registration; saved when `edit` returns true.
    fn update(&self, device: &str, edit: impl FnOnce(&mut Registration) -> bool) {
        let mut regs = lock(&self.regs);
        let Some(reg) = regs.iter_mut().find(|r| r.device == device) else {
            return;
        };
        if edit(reg) {
            self.save(&regs);
        }
    }

    fn http(&self) -> &reqwest::Client {
        self.http.get_or_init(http_client)
    }
}

/// Drops the registrations of revoked devices: a revoked device may be lost or stolen, and
/// must not keep receiving sealed prompts or action tokens.
pub(crate) fn drop_revoked(core: &Core) {
    let mut regs = lock(&core.push.regs);
    let before = regs.len();
    regs.retain(|r| unhex::<32>(&r.device).is_some_and(|d| !core.mp.device_removed(DeviceId(d))));
    if regs.len() != before {
        core.push.save(&regs);
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

// --- requests from clients ----------------------------------------------------------------------

/// `PushRegister`: adds or replaces the asking device's registration.
pub(crate) fn register(
    core: &Core,
    actor: Actor,
    reg: PushRegistration,
) -> Result<PushStatus, WsError> {
    if reg.cap.is_empty() || reg.cap.len() > MAX_CAP_LEN {
        return Err(WsError::Invalid("bad push capability".into()));
    }
    // A small-order point would make every seal fail; refuse it now.
    if push::hpke::seal(&reg.seal_key, b"", b"", b"").is_err() {
        return Err(WsError::Invalid("bad sealing key".into()));
    }
    if let Some(url) = &reg.relay_url
        && !(url.starts_with("https://") || url.starts_with("http://"))
    {
        return Err(WsError::Invalid(format!("relay url {url:?}")));
    }
    let device = hex(&actor.device.0);
    {
        let mut regs = lock(&core.push.regs);
        // A running Live Activity outlives a re-registration (each launch).
        let activity_update_cap = regs
            .iter()
            .find(|r| r.device == device)
            .and_then(|r| r.activity_update_cap.clone());
        regs.retain(|r| r.device != device);
        regs.push(Registration {
            device: device.clone(),
            cap: reg.cap,
            seal_key: hex(&reg.seal_key),
            relay_url: reg.relay_url,
            prefs: reg.prefs,
            activity_cap: reg.activity_cap,
            activity_update_cap,
            registered_at: now_millis(),
        });
        core.push.save(&regs);
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
    if !lock(&core.push.regs).iter().any(|r| r.device == device) {
        return Err(WsError::NotFound("register for push first".into()));
    }
    activity::token_changed(core, &device, token.cap);
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
    let regs = lock(&core.push.regs);
    PushStatus {
        enabled: core.cfg.push.enabled,
        relay_url: core.cfg.push.relay_url.clone(),
        registered: regs.iter().find(|r| r.device == device).map(|r| r.prefs),
        devices: regs.len() as u32,
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
    req: &PushActionRequest,
) -> Result<Decided, WsError> {
    let daemon = core.identity.daemon_id().0;
    let token =
        push::verify_token(&daemon, &req.token, UnixMillis(now_millis())).map_err(|e| match e {
            push::PushError::Expired => WsError::Denied("the notification action expired".into()),
            _ => WsError::Denied("invalid action token".into()),
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
    let decision = if req.approve {
        push::Decision::Approve
    } else {
        push::Decision::Deny
    };
    push::verify_decision(&actor.device.0, &req.token, decision, &req.sig)
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
        &push::decision_message(&req.token, decision),
    ]
    .concat();
    // Push actions come from owner devices only, so only the two-person rule can hold them.
    let ballot = crate::mp::approvals::Ballot {
        actor,
        name: "The owner",
        owner: true,
    };
    let gate = crate::mp::gate_decision(
        core,
        ballot,
        token.request,
        option,
        (signed.clone(), req.sig.clone()),
    );
    match gate {
        Ok(crate::mp::Gate::Proceed) => {}
        Ok(crate::mp::Gate::Held) => {
            return Err(WsError::Conflict(
                "approval counted; a second person must approve too".into(),
            ));
        }
        Err(e) => return Err(WsError::Denied(e.to_string())),
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
                    sig: req.sig.clone(),
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
                sig: req.sig.clone(),
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
        approve = req.approve,
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

// --- delivery -----------------------------------------------------------------------------------

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
        AttentionKind::AgentBlocked { request_id, .. } => {
            let buttons = request_id.and_then(|id| {
                let entry = core.pane(item.pane_id)?;
                let agent = lock(&entry.agent);
                agent.as_ref()?.approval_options(id)
            });
            match buttons {
                Some(b) if b.approve.is_some() || b.deny.is_some() => {
                    (push::Kind::Approval, Some(b))
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

async fn deliver(core: Arc<Core>, item: AttentionItem) {
    if !core.cfg.push.enabled || lock(&core.push.regs).is_empty() {
        return;
    }
    tokio::time::sleep(core.cfg.push.delay).await;
    // Debounce: seen meanwhile (a client focused the pane, the blocker went away), or a newer
    // item for the same pane will be pushed instead.
    match core.ws.attention.get(item.id) {
        Some(current) if !current.seen => {}
        _ => return,
    }
    if core.ws.attention.superseded(item.id, item.pane_id) {
        return;
    }
    let (kind, buttons) = classify(&core, &item);
    let host = crate::ws::tunnel::hostname();
    for reg in targets(&core) {
        if !wants(&reg.prefs, kind) {
            continue;
        }
        let Some(device) = unhex::<32>(&reg.device).map(DeviceId) else {
            continue;
        };
        if core.device_active(device) {
            tracing::debug!(item = item.id, "device is looking at this host; no push");
            continue;
        }
        if !lock(&core.push.budgets).spend(&reg.device, Instant::now()) {
            tracing::debug!(
                item = item.id,
                "push budget spent; the item stays in the inbox"
            );
            continue;
        }
        let core = Arc::clone(&core);
        let (item, host, buttons) = (item.clone(), host.clone(), buttons.clone());
        tokio::spawn(async move {
            let result = send(&core, &reg, device, &item, kind, buttons.as_ref(), &host).await;
            match result {
                Ok(()) => {
                    lock(&core.push.errors).remove(&reg.device);
                }
                Err(SendError::Gone) => {
                    tracing::info!(device = %&reg.device[..8], "push token gone; unregistering");
                    core.push.remove(&reg.device);
                }
                Err(SendError::Failed(why)) => {
                    tracing::warn!(device = %&reg.device[..8], "push failed: {why}");
                    lock(&core.push.errors).insert(reg.device.clone(), why);
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
            Some(b),
        ) => open_subject(core, *request).map(|(_, subject)| {
            let expires = UnixMillis(now_millis() + core.cfg.push.action_ttl.as_millis() as u64);
            let token = push::ActionToken {
                v: push::ActionToken::VERSION,
                daemon: core.identity.daemon_id(),
                device,
                pane: item.pane_id,
                request: *request,
                approve: b.approve.as_ref().map(|(id, _)| *id),
                deny: b.deny.as_ref().map(|(id, _)| *id),
                item: item.id,
                expires,
                subject,
            };
            push::ActionOffer {
                token: push::b64(&push::issue_token(&seed, &token)),
                approve: b
                    .approve
                    .as_ref()
                    .map_or_else(String::new, |(_, l)| l.clone()),
                deny: b.deny.as_ref().map_or_else(String::new, |(_, l)| l.clone()),
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
        session: item.session_id.map(|s| s.0),
        title: item.title.clone(),
        body: item.body.clone(),
        at: item.at.0,
        action,
    }
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
    reg: &Registration,
    device: DeviceId,
    item: &AttentionItem,
    kind: push::Kind,
    buttons: Option<&crate::agent::ApprovalButtons>,
    host: &str,
) -> Result<(), SendError> {
    let seal_key = unhex::<32>(&reg.seal_key)
        .ok_or_else(|| SendError::Failed("bad sealing key on file".into()))?;
    let seed = core.identity.secret.to_bytes();
    let mut note = notification(core, device, item, kind, buttons, host);
    if note.body.ends_with('…') {
        open_only(&mut note);
    }
    let sealed = loop {
        let json = serde_json::to_vec(&note).map_err(|e| SendError::Failed(e.to_string()))?;
        match push::seal(&seal_key, &seed, &json) {
            Ok(sealed) => break sealed,
            // Too long for APNs: shorten the body and try again.
            Err(push::PushError::TooLarge(_)) if note.body.len() > 64 => {
                let keep = note.body.chars().count() / 2;
                note.body = note.body.chars().take(keep).collect::<String>() + "…";
                open_only(&mut note);
            }
            Err(e) => return Err(SendError::Failed(format!("sealing: {e}"))),
        }
    };
    let kind = note.kind;
    let collapse = push::collapse_id(&seed, item.pane_id, kind.category());
    let attempts = core.cfg.push.attempts;
    post(core, reg, attempts, || push::RelayRequest {
        v: push::RelayRequest::VERSION,
        daemon: String::new(),
        cap: reg.cap.clone(),
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
    reg: &Registration,
    attempts: u32,
    make: impl Fn() -> push::RelayRequest,
) -> Result<(), SendError> {
    let seed = core.identity.secret.to_bytes();
    let relay = reg
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
        let body = serde_json::to_vec(&request).map_err(|e| SendError::Failed(e.to_string()))?;
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
            Ok(r) if r.status().is_success() => {
                tracing::debug!(attempt, "pushed");
                return Ok(());
            }
            Ok(r) if r.status().as_u16() == 410 => return Err(SendError::Gone),
            Ok(r) if r.status().as_u16() == 429 || r.status().is_server_error() => {
                let retry_after = r
                    .headers()
                    .get("retry-after")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse::<u64>().ok())
                    .map(Duration::from_secs);
                last = format!("relay answered {}", r.status());
                let wait = retry_after.unwrap_or(backoff).min(Duration::from_secs(300));
                if r.status().as_u16() == 429 {
                    lock(&core.push.budgets).paused_until = Some(Instant::now() + wait);
                }
                wait
            }
            Ok(r) => {
                let status = r.status();
                let text = r.text().await.unwrap_or_default();
                return Err(SendError::Failed(format!(
                    "relay refused the push: {status} {}",
                    text.chars().take(200).collect::<String>()
                )));
            }
            Err(e) => {
                last = format!("posting to {url}: {e}");
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

    #[test]
    fn alerts_stay_within_the_relays_budgets() {
        let t0 = Instant::now();
        let mut b = Budgets::new(t0);
        let sent = (0..100).filter(|_| b.spend("a", t0)).count();
        assert_eq!(sent, 30, "a burst stops at the budget");
        assert!(!b.spend("a", t0 + Duration::from_secs(11)));
        assert!(
            b.spend("a", t0 + Duration::from_secs(12)),
            "one more every 12 s"
        );
        // The daemon's budget earned 4 in those 12 s, one of them spent above.
        let other = (0..100)
            .filter(|_| b.spend("b", t0 + Duration::from_secs(12)))
            .count();
        assert_eq!(other, 3);
        // A 429 holds everything back until its retry-after.
        let later = t0 + Duration::from_secs(600);
        b.paused_until = Some(later + Duration::from_secs(5));
        assert!(!b.spend("c", later));
        assert!(b.spend("c", later + Duration::from_secs(5)));
    }

    #[test]
    fn store_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let push = Push::load(dir.path());
        let reg = Registration {
            device: "ab".repeat(32),
            cap: "cap".into(),
            seal_key: "cd".repeat(32),
            relay_url: None,
            prefs: PushPrefs::default(),
            activity_cap: None,
            activity_update_cap: Some("u".into()),
            registered_at: 1,
        };
        lock(&push.regs).push(reg.clone());
        push.save(&lock(&push.regs));
        assert_eq!(Push::load(dir.path()).registrations(), vec![reg.clone()]);
        push.remove(&reg.device);
        assert!(Push::load(dir.path()).registrations().is_empty());
    }
}
