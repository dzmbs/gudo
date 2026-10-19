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
//! Registrations persist in `<state>/push.json` (mode 0600).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use proto::{
    Actor, AttentionItem, AttentionKind, AttentionSeen, AttentionUpdate, Decide, Decided, DeviceId,
    PushActionRequest, PushPrefs, PushRegistration, PushStatus, UnixMillis, WsError,
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
    #[serde(default)]
    activity_cap: Option<String>,
    registered_at: u64,
}

/// Registered devices and delivery state.
pub(crate) struct Push {
    path: PathBuf,
    regs: Mutex<Vec<Registration>>,
    /// Last delivery error per device (hex), cleared on success.
    errors: Mutex<HashMap<String, String>>,
    http: OnceLock<reqwest::Client>,
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

    fn http(&self) -> &reqwest::Client {
        self.http.get_or_init(http_client)
    }
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
        regs.retain(|r| r.device != device);
        regs.push(Registration {
            device: device.clone(),
            cap: reg.cap,
            seal_key: hex(&reg.seal_key),
            relay_url: reg.relay_url,
            prefs: reg.prefs,
            activity_cap: reg.activity_cap,
            registered_at: now_millis(),
        });
        core.push.save(&regs);
    }
    lock(&core.push.errors).remove(&device);
    tracing::info!(device = %&device[..8], "push registration updated");
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

/// Watches the attention feed and pushes items that stay unseen.
pub(crate) async fn run(core: Arc<Core>) {
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
    for reg in core.push.registrations() {
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
        ) => {
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
            };
            Some(push::ActionOffer {
                token: push::b64(&push::issue_token(&seed, &token)),
                approve: b
                    .approve
                    .as_ref()
                    .map_or_else(String::new, |(_, l)| l.clone()),
                deny: b.deny.as_ref().map_or_else(String::new, |(_, l)| l.clone()),
                expires: expires.0,
            })
        }
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
    let sealed = loop {
        let json = serde_json::to_vec(&note).map_err(|e| SendError::Failed(e.to_string()))?;
        match push::seal(&seal_key, &seed, &json) {
            Ok(sealed) => break sealed,
            // Too long for APNs: shorten the body and try again.
            Err(push::PushError::TooLarge(_)) if note.body.len() > 64 => {
                let keep = note.body.chars().count() / 2;
                note.body = note.body.chars().take(keep).collect::<String>() + "…";
            }
            Err(e) => return Err(SendError::Failed(format!("sealing: {e}"))),
        }
    };
    let collapse = push::collapse_id(&seed, item.pane_id, kind.category());
    let relay = reg
        .relay_url
        .clone()
        .unwrap_or_else(|| core.cfg.push.relay_url.clone());
    let url = format!("{}/v1/push", relay.trim_end_matches('/'));
    let daemon = hex(&core.identity.daemon_id().0);

    let mut backoff = core.cfg.push.backoff;
    let mut last = String::new();
    for attempt in 1..=core.cfg.push.attempts.max(1) {
        // Fresh timestamp and nonce per attempt: the relay refuses replays.
        let request = push::RelayRequest {
            v: push::RelayRequest::VERSION,
            daemon: daemon.clone(),
            cap: reg.cap.clone(),
            push_type: push::PushType::Alert,
            category: Some(kind.category()),
            collapse: Some(collapse.clone()),
            sealed: sealed.clone(),
            ts: now_millis(),
            nonce: push::nonce(),
            event: None,
            stale: None,
            dismiss: None,
            urgent: false,
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
                tracing::debug!(item = item.id, attempt, "pushed");
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
                retry_after.unwrap_or(backoff).min(Duration::from_secs(300))
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
        if attempt < core.cfg.push.attempts {
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
            registered_at: 1,
        };
        lock(&push.regs).push(reg.clone());
        push.save(&lock(&push.regs));
        assert_eq!(Push::load(dir.path()).registrations(), vec![reg.clone()]);
        push.remove(&reg.device);
        assert!(Push::load(dir.path()).registrations().is_empty());
    }
}
