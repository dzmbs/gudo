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
    /// Handles a browser push from `ctl`; returns the message back if it is not one.
    pub(crate) fn dispatch(&self, msg: ServerCtl) -> Option<ServerCtl> {
        let ServerCtl::Browser(push) = msg else {
            return Some(msg);
        };
        let listener = lock(&self.listener).clone();
        if let Some(l) = listener {
            l.on_browser_push(push);
        }
        None
    }
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
