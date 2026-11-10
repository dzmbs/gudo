//! Approval extras (`proto::approve`): approving with edited input and auto-approve rules
//! ("approve all like this for this task").
//!
//! Every connection announces `Caps::APPROVALS`. Pushes go to an [`ApprovalListener`] set
//! with [`Client::set_approval_listener`] and are also kept: [`Client::approval_info`] (what
//! may be done with a pane's open request), [`Client::auto_approve_rules`] and, on owner
//! devices, [`Client::drive_asks`] (agents asking to drive the user's panes, `proto::drive`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::{
    ActiveRule, ApprovalError, ApprovalInfo, ApprovalPush, ApprovalRequest, ApprovalResponse,
    AutoApproveRule, Decide, DriveAsk, DrivePush, PaneId, RequestId, RuleId, RuleMatch, ServerCtl,
    UnixMillis,
};
use tokio::sync::{mpsc, oneshot};

use crate::{Client, lock};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// A change in approvals.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApprovalEvent {
    /// A pane is blocked on a request: what may be done with it.
    Request(ApprovalInfo),
    /// The rules in force on a pane (empty when none are left).
    Rules {
        pane_id: PaneId,
        rules: Vec<ActiveRule>,
    },
    /// An agent asks to drive one of the user's panes, or such a request closed. Answer with
    /// [`Client::decide`] and one of the [`DriveAsk`] options.
    Drive(DrivePush),
    /// The connection dropped: everything above is forgotten until the daemon says it again.
    Reset,
}

/// Receives [`ApprovalEvent`]s. Must return quickly; it runs on the network threads.
pub trait ApprovalListener: Send + Sync {
    /// Called once per event, in order.
    fn on_approval_event(&self, event: ApprovalEvent);
}

/// An [`ApprovalListener`] that queues events for async consumers (tests, `gudo`).
pub struct ApprovalEventQueue {
    tx: mpsc::UnboundedSender<ApprovalEvent>,
}

impl ApprovalEventQueue {
    /// Returns the listener and the receiving end.
    pub fn channel() -> (
        Arc<dyn ApprovalListener>,
        mpsc::UnboundedReceiver<ApprovalEvent>,
    ) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Self { tx }), rx)
    }
}

impl ApprovalListener for ApprovalEventQueue {
    fn on_approval_event(&self, event: ApprovalEvent) {
        let _ = self.tx.send(event);
    }
}

type Pending = oneshot::Sender<Result<ApprovalResponse, ApprovalError>>;

/// Approval state kept by the client.
#[derive(Default)]
pub(crate) struct ApprovalState {
    pending: Mutex<HashMap<u64, Pending>>,
    listener: Mutex<Option<Arc<dyn ApprovalListener>>>,
    requests: Mutex<HashMap<PaneId, ApprovalInfo>>,
    rules: Mutex<HashMap<PaneId, Vec<ActiveRule>>>,
    drives: Mutex<HashMap<RequestId, DriveAsk>>,
}

impl ApprovalState {
    /// Whether a caller still waits for the answer to `req_id`.
    pub(crate) fn awaits(&self, req_id: u64) -> bool {
        lock(&self.pending)
            .get(&req_id)
            .is_some_and(|reply| !reply.is_closed())
    }

    /// Handles an approval message from `ctl`; returns it back if it is not one.
    pub(crate) fn dispatch(&self, message: ServerCtl) -> Option<ServerCtl> {
        let event = match message {
            ServerCtl::ApprovalResult { req_id, result } => {
                if let Some(reply) = lock(&self.pending).remove(&req_id) {
                    let _ = reply.send(result);
                }
                return None;
            }
            ServerCtl::Approval(ApprovalPush::Request(info)) => {
                lock(&self.requests).insert(info.pane_id, info.clone());
                ApprovalEvent::Request(info)
            }
            ServerCtl::Approval(ApprovalPush::Rules { pane_id, rules }) => {
                if rules.is_empty() {
                    lock(&self.rules).remove(&pane_id);
                } else {
                    lock(&self.rules).insert(pane_id, rules.clone());
                }
                ApprovalEvent::Rules { pane_id, rules }
            }
            ServerCtl::Approval(ApprovalPush::Drive(push)) => {
                match &push {
                    DrivePush::Open(ask) => {
                        lock(&self.drives).insert(ask.request_id, ask.clone());
                    }
                    DrivePush::Closed { request_id } => {
                        lock(&self.drives).remove(request_id);
                    }
                }
                ApprovalEvent::Drive(push)
            }
            other => return Some(other),
        };
        self.emit(event);
        None
    }

    fn emit(&self, event: ApprovalEvent) {
        let listener = lock(&self.listener).clone();
        if let Some(listener) = listener {
            listener.on_approval_event(event);
        }
    }

    pub(crate) fn fail_pending(&self) {
        for (_, reply) in lock(&self.pending).drain() {
            let _ = reply.send(Err(ApprovalError::Disconnected));
        }
        let had_state = {
            let mut requests = lock(&self.requests);
            let mut rules = lock(&self.rules);
            let mut drives = lock(&self.drives);
            let had_state = !requests.is_empty() || !rules.is_empty() || !drives.is_empty();
            requests.clear();
            rules.clear();
            drives.clear();
            had_state
        };
        if had_state {
            self.emit(ApprovalEvent::Reset);
        }
    }
}

impl Client {
    /// Sets the receiver of [`ApprovalEvent`]s (replacing any previous one).
    pub fn set_approval_listener(&self, listener: Arc<dyn ApprovalListener>) {
        *lock(&self.inner.approvals.listener) = Some(listener);
    }

    /// The open requests of agents to drive the user's panes, oldest first (owner devices).
    pub fn drive_asks(&self) -> Vec<DriveAsk> {
        let mut asks: Vec<DriveAsk> = lock(&self.inner.approvals.drives)
            .values()
            .cloned()
            .collect();
        asks.sort_by_key(|ask| ask.request_id);
        asks
    }

    /// What may be done with the request `pane_id` is blocked on, if the daemon said. Check
    /// that its `request_id` is the one the pane's agent state names: it may be stale.
    pub fn approval_info(&self, pane_id: PaneId) -> Option<ApprovalInfo> {
        lock(&self.inner.approvals.requests).get(&pane_id).cloned()
    }

    /// The auto-approve rules in force on `pane_id`, oldest first.
    pub fn auto_approve_rules(&self, pane_id: PaneId) -> Vec<ActiveRule> {
        lock(&self.inner.approvals.rules)
            .get(&pane_id)
            .cloned()
            .unwrap_or_default()
    }

    /// Sends any approval request and waits for the answer.
    ///
    /// # Errors
    ///
    /// The daemon's [`ApprovalError`], or [`ApprovalError::Disconnected`] if the connection
    /// dropped (or nothing came back in time).
    pub async fn approval(
        &self,
        request: ApprovalRequest,
    ) -> Result<ApprovalResponse, ApprovalError> {
        let req_id = self
            .inner
            .next_op
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (reply_tx, reply_rx) = oneshot::channel();
        lock(&self.inner.approvals.pending).insert(req_id, reply_tx);
        self.inner.send(proto::ClientCtl::Approval {
            req_id,
            req: request,
        });
        let inner = Arc::clone(&self.inner);
        self.handle
            .spawn(async move {
                match tokio::time::timeout(REQUEST_TIMEOUT, reply_rx).await {
                    Ok(Ok(result)) => result,
                    _ => {
                        lock(&inner.approvals.pending).remove(&req_id);
                        Err(ApprovalError::Disconnected)
                    }
                }
            })
            .await
            .unwrap_or(Err(ApprovalError::Disconnected))
    }

    /// Approves `request_id` with option `option_id` (the allow option), running `input`
    /// instead of what the agent asked for. Signed like [`Client::decide`].
    ///
    /// # Errors
    ///
    /// [`ApprovalError::NotEditable`] if the agent cannot take edited input; otherwise as
    /// [`approval`](Self::approval).
    pub async fn approve_edited(
        &self,
        request_id: RequestId,
        option_id: proto::OptionId,
        input: String,
    ) -> Result<(), ApprovalError> {
        let mut decide = Decide {
            request_id,
            option_id,
            actor: self.actor(),
            sig: Vec::new(),
        };
        if let Ok(key) = grants::DeviceKey::from_seed(&self.inner.config.secret_key) {
            grants::sign_approval(&key, self.inner.ticket.daemon_id, &mut decide);
        }
        self.approval(ApprovalRequest::ApproveEdited { decide, input })
            .await
            .map(|_| ())
    }

    /// Adds a rule approving requests on `pane_id` that `matcher` covers, for `ttl` and at most
    /// `max_turns` agent turns (the current one included), signed with this device's key.
    /// With `request_id`, that open request is approved too. Returns the rule's id.
    ///
    /// # Errors
    ///
    /// [`ApprovalError::Invalid`] if the rule is wider than the daemon allows; otherwise as
    /// [`approval`](Self::approval).
    pub async fn add_auto_approve(
        &self,
        pane_id: PaneId,
        request_id: Option<RequestId>,
        matcher: RuleMatch,
        ttl: Duration,
        max_turns: u32,
    ) -> Result<RuleId, ApprovalError> {
        let key = grants::DeviceKey::from_seed(&self.inner.config.secret_key)
            .map_err(|_| ApprovalError::Forbidden("no device key".into()))?;
        let expires = crate::now_millis().0.saturating_add(ttl.as_millis() as u64);
        let mut rule = AutoApproveRule {
            rule_id: RuleId(grants::random()),
            pane_id,
            request_id,
            matcher,
            expires_at: UnixMillis(expires),
            max_turns,
            actor: self.actor(),
            sig: Vec::new(),
        };
        grants::sign_auto_approve(&key, self.inner.ticket.daemon_id, &mut rule);
        let rule_id = rule.rule_id;
        self.approval(ApprovalRequest::AddRule(rule)).await?;
        Ok(rule_id)
    }

    /// Revokes rule `rule_id`.
    ///
    /// # Errors
    ///
    /// [`ApprovalError::NotFound`] if it already ended; otherwise as
    /// [`approval`](Self::approval).
    pub async fn revoke_auto_approve(&self, rule_id: RuleId) -> Result<(), ApprovalError> {
        self.approval(ApprovalRequest::RevokeRule { rule_id })
            .await
            .map(|_| ())
    }
}
