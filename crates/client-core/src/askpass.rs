//! Native password prompts (`proto::askpass`, docs/DAEMON.md §9): a program in a pane asked
//! for a secret through the daemon's askpass helper, or printed a password prompt with echo
//! off.
//!
//! Only owner connections made with [`ConnectOptions::askpass`](crate::ConnectOptions::askpass)
//! receive them: a guest never announces the capability, and pushes on a connection that did
//! not announce it are dropped (someone else's host must not ask for this device's passwords).
//! Pushes go to an [`AskpassListener`] set with [`Client::set_askpass_listener`]; the open
//! prompts and detected prompts are also kept ([`Client::open_askpass`],
//! [`Client::detected_prompt`]). Answers are [`Client::answer_askpass`],
//! [`Client::cancel_askpass`] and [`Client::type_secret`].
//!
//! Secrets are passed as [`Secret`], zeroed when dropped, and never logged.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::{
    AskpassError, AskpassId, AskpassPush, AskpassRequest, CloseReason, DetectedPrompt, PaneId,
    Secret, SecretPrompt, ServerCtl,
};
use tokio::sync::{mpsc, oneshot};

use crate::{Client, Inner, lock};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// A change in a pane's password prompts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AskpassEvent {
    /// A program asks for a secret.
    Prompt(SecretPrompt),
    /// A program asks for a secret while a guest holds the pane's lease: the guest may have
    /// typed the command that asks.
    PromptWhileGuestDrives {
        prompt: SecretPrompt,
        /// The guest's name.
        guest: String,
    },
    /// A prompt is over (answered here or elsewhere, cancelled, timed out, abandoned).
    Closed {
        id: AskpassId,
        pane_id: PaneId,
        reason: CloseReason,
    },
    /// The pane shows a password prompt with echo off.
    Detected(DetectedPrompt),
    /// The detected prompt is gone.
    DetectedGone { pane_id: PaneId },
    /// The connection dropped: everything above is forgotten. Prompts still open are sent
    /// again (same ids) once the client is attached again.
    Reset,
}

/// Receives [`AskpassEvent`]s. Must return quickly; it runs on the network threads.
pub trait AskpassListener: Send + Sync {
    /// Called once per event, in order.
    fn on_askpass_event(&self, event: AskpassEvent);
}

/// An [`AskpassListener`] that queues events for async Rust consumers (`gudo`, tests).
pub struct AskpassEventQueue {
    tx: mpsc::UnboundedSender<AskpassEvent>,
}

impl AskpassEventQueue {
    /// Returns the listener and the receiving end.
    pub fn channel() -> (
        Arc<dyn AskpassListener>,
        mpsc::UnboundedReceiver<AskpassEvent>,
    ) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Self { tx }), rx)
    }
}

impl AskpassListener for AskpassEventQueue {
    fn on_askpass_event(&self, event: AskpassEvent) {
        let _ = self.tx.send(event);
    }
}

type Pending = oneshot::Sender<Result<(), AskpassError>>;

/// Askpass state kept by the client.
#[derive(Default)]
pub(crate) struct AskpassState {
    pending: Mutex<HashMap<u64, Pending>>,
    listener: Mutex<Option<Arc<dyn AskpassListener>>>,
    open: Mutex<HashMap<AskpassId, SecretPrompt>>,
    /// The guest driving the pane when an open prompt was asked.
    guests: Mutex<HashMap<AskpassId, String>>,
    detected: Mutex<HashMap<PaneId, DetectedPrompt>>,
}

/// Whether a connection announces [`proto::Caps::ASKPASS`]: only when asked, and never as a
/// guest.
pub(crate) fn announces(options: &crate::ConnectOptions, guest: bool) -> bool {
    options.askpass && !guest
}

impl AskpassState {
    /// Handles an askpass message from `ctl`; returns it back if it is not one. Pushes on a
    /// connection that did not announce the capability are dropped: a daemon is not trusted
    /// to honour it.
    pub(crate) fn dispatch(&self, message: ServerCtl, announced: bool) -> Option<ServerCtl> {
        if !announced && matches!(message, ServerCtl::Askpass(_)) {
            tracing::warn!("askpass push on a connection that did not ask for it; dropped");
            return None;
        }
        let event = match message {
            ServerCtl::AskpassResult { req_id, result } => {
                if let Some(reply) = lock(&self.pending).remove(&req_id) {
                    let _ = reply.send(result);
                }
                return None;
            }
            ServerCtl::Askpass(push) => match push {
                AskpassPush::Prompt(prompt) => {
                    lock(&self.open).insert(prompt.id, prompt.clone());
                    AskpassEvent::Prompt(prompt)
                }
                AskpassPush::PromptWhileGuestDrives { prompt, guest } => {
                    lock(&self.open).insert(prompt.id, prompt.clone());
                    lock(&self.guests).insert(prompt.id, guest.clone());
                    AskpassEvent::PromptWhileGuestDrives { prompt, guest }
                }
                AskpassPush::Closed {
                    id,
                    pane_id,
                    reason,
                } => {
                    lock(&self.open).remove(&id);
                    lock(&self.guests).remove(&id);
                    AskpassEvent::Closed {
                        id,
                        pane_id,
                        reason,
                    }
                }
                AskpassPush::Detected(detected) => {
                    lock(&self.detected).insert(detected.pane_id, detected.clone());
                    AskpassEvent::Detected(detected)
                }
                AskpassPush::DetectedGone { pane_id } => {
                    lock(&self.detected).remove(&pane_id);
                    AskpassEvent::DetectedGone { pane_id }
                }
            },
            other => return Some(other),
        };
        self.emit(event);
        None
    }

    fn emit(&self, event: AskpassEvent) {
        let listener = lock(&self.listener).clone();
        if let Some(listener) = listener {
            listener.on_askpass_event(event);
        }
    }

    /// The connection dropped: requests in flight will not be answered, and what the daemon
    /// told us is stale.
    pub(crate) fn fail_pending(&self) {
        for (_, reply) in lock(&self.pending).drain() {
            let _ = reply.send(Err(AskpassError::Disconnected));
        }
        let had_prompts = {
            let mut open = lock(&self.open);
            let mut detected = lock(&self.detected);
            let had_prompts = !open.is_empty() || !detected.is_empty();
            open.clear();
            detected.clear();
            lock(&self.guests).clear();
            had_prompts
        };
        if had_prompts {
            self.emit(AskpassEvent::Reset);
        }
    }
}

impl Client {
    /// Sets the receiver of [`AskpassEvent`]s (replacing any previous one).
    pub fn set_askpass_listener(&self, listener: Arc<dyn AskpassListener>) {
        *lock(&self.inner.askpass.listener) = Some(listener);
    }

    /// The prompts open now, oldest first.
    pub fn open_askpass(&self) -> Vec<SecretPrompt> {
        let mut open: Vec<SecretPrompt> =
            lock(&self.inner.askpass.open).values().cloned().collect();
        open.sort_by_key(|prompt| prompt.id);
        open
    }

    /// The guest who was driving the pane when open prompt `id` was asked, if one was.
    pub fn askpass_guest(&self, id: AskpassId) -> Option<String> {
        lock(&self.inner.askpass.guests).get(&id).cloned()
    }

    /// The password prompt `pane_id` shows with echo off, if any.
    pub fn detected_prompt(&self, pane_id: PaneId) -> Option<DetectedPrompt> {
        lock(&self.inner.askpass.detected).get(&pane_id).cloned()
    }

    /// Sends any askpass request and waits for the answer.
    ///
    /// # Errors
    ///
    /// The daemon's [`AskpassError`], or [`AskpassError::Disconnected`] if the connection
    /// dropped (or nothing came back within 30 s).
    pub async fn askpass(&self, request: AskpassRequest) -> Result<(), AskpassError> {
        let req_id = self
            .inner
            .next_op
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (reply_tx, reply_rx) = oneshot::channel();
        lock(&self.inner.askpass.pending).insert(req_id, reply_tx);
        self.inner.send(proto::ClientCtl::Askpass {
            req_id,
            req: request,
        });
        let inner: Arc<Inner> = Arc::clone(&self.inner);
        self.handle
            .spawn(async move {
                match tokio::time::timeout(REQUEST_TIMEOUT, reply_rx).await {
                    Ok(Ok(result)) => result,
                    _ => {
                        lock(&inner.askpass.pending).remove(&req_id);
                        Err(AskpassError::Disconnected)
                    }
                }
            })
            .await
            .unwrap_or(Err(AskpassError::Disconnected))
    }

    /// Answers prompt `id` with `secret`. The first answer from anyone wins.
    ///
    /// # Errors
    ///
    /// [`AskpassError::Gone`] if it closed first; otherwise as [`askpass`](Self::askpass).
    pub async fn answer_askpass(&self, id: AskpassId, secret: Secret) -> Result<(), AskpassError> {
        self.askpass(AskpassRequest::Answer { id, secret }).await
    }

    /// Declines prompt `id`: the program gets no answer.
    ///
    /// # Errors
    ///
    /// As [`answer_askpass`](Self::answer_askpass).
    pub async fn cancel_askpass(&self, id: AskpassId) -> Result<(), AskpassError> {
        self.askpass(AskpassRequest::Cancel { id }).await
    }

    /// Types `secret` and Return into `pane_id`, only while its terminal hides input.
    ///
    /// # Errors
    ///
    /// [`AskpassError::NotHidden`] (nothing typed) if the pane echoes input now; otherwise
    /// as [`askpass`](Self::askpass).
    pub async fn type_secret(&self, pane_id: PaneId, secret: Secret) -> Result<(), AskpassError> {
        self.askpass(AskpassRequest::TypeSecret { pane_id, secret })
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proto::{SecretSource, UnixMillis};

    fn prompt() -> ServerCtl {
        ServerCtl::Askpass(AskpassPush::Prompt(SecretPrompt {
            id: AskpassId(1),
            pane_id: PaneId(1),
            source: SecretSource::Sudo,
            prompt: "Password:".into(),
            program: "sudo ls".into(),
            echo: false,
            retry: false,
            expires_at: UnixMillis(0),
        }))
    }

    #[test]
    fn a_hostile_daemon_cannot_ask_a_connection_that_did_not_offer() {
        let state = AskpassState::default();
        let (listener, mut events) = AskpassEventQueue::channel();
        *lock(&state.listener) = Some(listener);

        assert!(state.dispatch(prompt(), false).is_none());
        assert!(events.try_recv().is_err(), "dropped, not shown");
        assert!(lock(&state.open).is_empty());
        assert!(state.dispatch(prompt(), true).is_none());
        assert!(matches!(events.try_recv(), Ok(AskpassEvent::Prompt(_))));
    }

    #[test]
    fn guests_never_offer_to_answer_password_prompts() {
        let asked = crate::ConnectOptions {
            askpass: true,
            ..crate::ConnectOptions::default()
        };
        assert!(announces(&asked, false));
        assert!(!announces(&asked, true));
        assert!(!announces(&crate::ConnectOptions::default(), false));
    }
}
