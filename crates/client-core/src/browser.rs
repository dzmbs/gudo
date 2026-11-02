//! The app's browser, used from the host (`proto::browser`): URLs programs in a pane open,
//! and browser tools agents call.
//!
//! Only connections made with [`ConnectOptions::browser`](crate::ConnectOptions::browser)
//! receive them. Pushes go to a [`BrowserListener`] set with [`Client::set_browser_listener`];
//! a call is answered with [`Client::answer_browser_call`].

use std::sync::{Arc, Mutex};

use proto::{BrowserPush, ServerCtl};
use tokio::sync::mpsc;

use crate::{Client, lock};

/// Receives [`BrowserPush`]es. Must return quickly; it runs on the network threads.
pub trait BrowserListener: Send + Sync {
    /// Called once per push, in order.
    fn on_browser_push(&self, push: BrowserPush);
}

/// A [`BrowserListener`] that queues pushes for async Rust consumers (tests).
pub struct BrowserPushQueue {
    tx: mpsc::UnboundedSender<BrowserPush>,
}

impl BrowserPushQueue {
    /// Returns the listener and the receiving end.
    pub fn channel() -> (
        Arc<dyn BrowserListener>,
        mpsc::UnboundedReceiver<BrowserPush>,
    ) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Self { tx }), rx)
    }
}

impl BrowserListener for BrowserPushQueue {
    fn on_browser_push(&self, push: BrowserPush) {
        let _ = self.tx.send(push);
    }
}

#[derive(Default)]
pub(crate) struct BrowserState {
    listener: Mutex<Option<Arc<dyn BrowserListener>>>,
}

impl BrowserState {
    /// Handles a browser push from `ctl`; returns the message back if it is not one. Pushes
    /// on a connection that did not announce the capability are dropped: a daemon is not
    /// trusted to honour it.
    pub(crate) fn dispatch(&self, ctl: ServerCtl, announced: bool) -> Option<ServerCtl> {
        let ServerCtl::Browser(push) = ctl else {
            return Some(ctl);
        };
        if !announced {
            tracing::warn!("browser push on a connection that did not ask for it; dropped");
            return None;
        }
        let listener = lock(&self.listener).clone();
        if let Some(listener) = listener {
            listener.on_browser_push(push);
        }
        None
    }
}

/// Whether a connection announces [`proto::Caps::BROWSER`]: only when asked, and never as a
/// guest (someone else's host must not drive this device's browser).
pub(crate) fn announces(options: &crate::ConnectOptions, guest: bool) -> bool {
    options.browser && !guest
}

impl Client {
    /// Sets the receiver of [`BrowserPush`]es (replacing any previous one).
    pub fn set_browser_listener(&self, listener: Arc<dyn BrowserListener>) {
        *lock(&self.inner.browser.listener) = Some(listener);
    }

    /// Answers [`BrowserPush::Call`] `id` with the tool's result (JSON) or why it failed.
    pub fn answer_browser_call(&self, id: u64, result: Result<String, String>) {
        self.inner
            .send(proto::ClientCtl::BrowserResult { id, result });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proto::PaneId;

    fn open() -> ServerCtl {
        ServerCtl::Browser(BrowserPush::Open {
            pane_id: PaneId(1),
            url: "https://example.com/".into(),
        })
    }

    #[test]
    fn a_hostile_daemon_cannot_push_to_a_connection_that_did_not_ask() {
        let state = BrowserState::default();
        let (listener, mut pushes) = BrowserPushQueue::channel();
        *lock(&state.listener) = Some(listener);

        assert!(state.dispatch(open(), false).is_none());
        assert!(pushes.try_recv().is_err(), "dropped, not delivered");
        assert!(state.dispatch(open(), true).is_none());
        assert!(pushes.try_recv().is_ok());
    }

    #[test]
    fn guests_never_announce_the_browser() {
        let asked = crate::ConnectOptions {
            browser: true,
            ..crate::ConnectOptions::default()
        };
        assert!(announces(&asked, false));
        assert!(!announces(&asked, true));
        assert!(!announces(&crate::ConnectOptions::default(), false));
    }
}
