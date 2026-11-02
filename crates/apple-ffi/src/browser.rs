//! The app's browser, used from the host, on [`DaemonClient`]: URLs programs in a pane open
//! (`BROWSER`), and browser tools agents call.
//!
//! Connect with `ConnectOptions.browser = true` to receive them. Pushes go to a
//! [`BrowserListener`]; a call is answered with [`DaemonClient::answer_browser_call`].

use std::sync::Arc;

use client_core::proto;

use crate::client::DaemonClient;

/// What the host asks the app's browser to do.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum BrowserPush {
    /// A program in a pane asked for `url` to be opened.
    Open { pane_id: u64, url: String },
    /// An agent in a pane calls browser tool `tool` with JSON arguments `args`.
    Call {
        /// Answer with this id.
        id: u64,
        pane_id: u64,
        tool: String,
        /// A JSON object.
        args: String,
    },
    /// Call `id` is over (the agent gave up or it timed out).
    CallClosed { id: u64 },
}

impl From<proto::BrowserPush> for BrowserPush {
    fn from(push: proto::BrowserPush) -> Self {
        match push {
            proto::BrowserPush::Open { pane_id, url } => Self::Open {
                pane_id: pane_id.0,
                url,
            },
            proto::BrowserPush::Call {
                id,
                pane_id,
                tool,
                args,
            } => Self::Call {
                id,
                pane_id: pane_id.0,
                tool,
                args,
            },
            proto::BrowserPush::CallClosed { id } => Self::CallClosed { id },
        }
    }
}

/// Receives [`BrowserPush`]es; implemented in Swift.
///
/// Called on a runtime thread, in order, one at a time per client. Return quickly.
#[uniffi::export(foreign)]
pub trait BrowserListener: Send + Sync {
    fn on_browser_push(&self, push: BrowserPush);
}

struct BrowserForward(Arc<dyn BrowserListener>);

impl client_core::BrowserListener for BrowserForward {
    fn on_browser_push(&self, push: proto::BrowserPush) {
        self.0.on_browser_push(push.into());
    }
}

#[uniffi::export]
impl DaemonClient {
    /// Sets the receiver of [`BrowserPush`]es, replacing any previous one.
    pub fn set_browser_listener(&self, listener: Arc<dyn BrowserListener>) {
        self.inner
            .set_browser_listener(Arc::new(BrowserForward(listener)));
    }

    /// Answers a [`BrowserPush::Call`]: the tool's result (JSON), or `error` saying why not.
    pub fn answer_browser_call(&self, id: u64, result: Option<String>, error: Option<String>) {
        let result = match (result, error) {
            (Some(output), None) => Ok(output),
            (_, error) => Err(error.unwrap_or_else(|| "failed".into())),
        };
        self.inner.answer_browser_call(id, result);
    }
}
