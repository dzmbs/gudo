//! The app's browser, used from the host (`proto::browser`).
//!
//! - **`BROWSER`.** Every pane gets `BROWSER` naming `<state>/browser/<cli>-open`, a two-line
//!   script that runs the hook shim's `open-url` mode. The shim sends one [`BrowserCall`] line
//!   on the hook socket; the daemon pushes [`BrowserPush::Open`] to the pane's browser
//!   connection and answers [`BrowserReply::Opened`], or [`BrowserReply::NoApp`] when no app
//!   can show it (the shim then tries the system's opener).
//! - **Tools.** The shim's MCP server and `browser` mode send [`BrowserAsk::Tool`]; the daemon
//!   pushes [`BrowserPush::Call`] to the same connection and holds the line until the app's
//!   `ClientCtl::BrowserResult`, [`CALL_TIMEOUT`], the caller hanging up or the app leaving.
//!
//! A pane's browser connection is one of the owner's with [`Caps::BROWSER`] attached to the
//! pane's session: the one that last sized the pane (the device in use), else the newest.
//! Guests never get one, whatever their role.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::{BrowserPush, Caps, PaneId};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::io::AsyncRead;
use tokio::sync::oneshot;

use crate::core::{ConnId, Core, Event, lock, shell_quote};
use crate::mp::{Authz, Need, Target, policy};

/// The protocol version in [`BrowserCall::v`].
pub const BROWSER_VERSION: u32 = 1;

/// Longest a tool call may take in the app (a page that loads slowly, a wait).
pub const CALL_TIMEOUT: Duration = Duration::from_secs(120);

/// Longest URL passed on.
const MAX_URL: usize = 16 * 1024;

/// What the shim sends on the hook socket: one JSON line.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BrowserCall {
    /// [`BROWSER_VERSION`].
    pub v: u32,
    /// The hook token.
    pub token: String,
    /// The pane id from the pane's environment.
    pub pane: String,
    /// What to do.
    pub browser: BrowserAsk,
}

/// What a [`BrowserCall`] asks for.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BrowserAsk {
    /// Open a URL (`$BROWSER <url>`).
    Open {
        /// The URL.
        url: String,
    },
    /// Run a browser tool.
    Tool {
        /// Its name (`browser_navigate`, …).
        name: String,
        /// Its arguments, a JSON object.
        args: Value,
    },
}

/// The daemon's answer to a [`BrowserCall`]: one JSON line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BrowserReply {
    /// The URL went to the app.
    Opened,
    /// The tool's result (JSON text).
    Result(String),
    /// The call was refused or failed.
    Error(String),
    /// No app that shows the pane can take it.
    NoApp,
}

struct Pending {
    conn: ConnId,
    reply: oneshot::Sender<Result<String, String>>,
}

/// The helper's location, the connections that announced [`Caps::BROWSER`], and calls in
/// flight.
pub(crate) struct Browser {
    helper: Option<PathBuf>,
    next: AtomicU64,
    conns: Mutex<HashMap<ConnId, Authz>>,
    calls: Mutex<HashMap<u64, Pending>>,
}

impl Browser {
    /// Writes the `BROWSER` helper under `state_dir`; a failure is logged and leaves panes
    /// without it.
    pub fn install(state_dir: &Path, hook_bin: &Path) -> Self {
        let helper = state_dir
            .join("browser")
            .join(format!("{}-open", brand::CLI_BIN));
        let script = format!(
            "#!/bin/sh\n# Written by {}: opens URLs in the app.\nexec {} open-url \"$@\"\n",
            brand::DAEMON_BIN,
            shell_quote(&hook_bin.to_string_lossy()),
        );
        let helper = match crate::askpass::write_executable(&helper, &script) {
            Ok(()) => Some(helper),
            Err(e) => {
                tracing::warn!("writing the browser helper: {e}");
                None
            }
        };
        Self {
            helper,
            next: AtomicU64::new(1),
            conns: Mutex::default(),
            calls: Mutex::default(),
        }
    }

    /// `BROWSER`, and the hook socket the helper needs.
    pub fn pane_env(&self, core: &Core, pane: PaneId) -> Vec<(String, std::ffi::OsString)> {
        let Some(helper) = &self.helper else {
            return Vec::new();
        };
        let hooks = &core.hooks;
        vec![
            ("BROWSER".into(), helper.clone().into()),
            (brand::env_var("SOCK"), hooks.socket().to_owned().into()),
            (brand::env_var("TOKEN"), hooks.pane_token(pane).into()),
            (
                brand::env_var("ENDPOINT_FILE"),
                hooks.endpoint_file().to_owned().into(),
            ),
        ]
    }

    pub fn register(&self, conn: ConnId, authz: &Authz, caps: Caps) {
        if caps.contains(Caps::BROWSER) {
            lock(&self.conns).insert(conn, authz.clone());
        }
    }

    /// A connection left: its calls fail now rather than at the timeout.
    pub fn forget_conn(&self, conn: ConnId) {
        lock(&self.conns).remove(&conn);
        lock(&self.calls).retain(|_, p| p.conn != conn);
    }

    /// The app's answer to call `id`; only the connection it was sent to may give it.
    pub fn answer(&self, conn: ConnId, id: u64, result: Result<String, String>) {
        let mut calls = lock(&self.calls);
        if calls.get(&id).is_some_and(|p| p.conn == conn)
            && let Some(p) = calls.remove(&id)
        {
            let _ = p.reply.send(result);
        }
    }
}

impl Core {
    /// The connection that shows `pane`'s browser (see the module docs).
    pub(crate) fn browser_conn(&self, pane: PaneId) -> Option<ConnId> {
        let session = self.session_of_pane(pane)?;
        let conns: Vec<(ConnId, Authz)> = lock(&self.browser.conns)
            .iter()
            .map(|(c, a)| (*c, a.clone()))
            .collect();
        let eligible: Vec<ConnId> = conns
            .into_iter()
            .filter(|(conn, authz)| {
                self.attached_session(*conn) == Some(session)
                    && self.mp.still_valid(authz)
                    // The owner's devices only: a guest's browser holds the guest's sign-ins,
                    // which the host's programs must not drive or read.
                    && policy::check(self, authz, Need::Own, Target::Pane(pane)).is_ok()
            })
            .map(|(conn, _)| conn)
            .collect();
        let sizer = self
            .pane(pane)
            .and_then(|e| lock(&e.meta).sized_by.map(|(conn, _)| conn));
        sizer
            .filter(|c| eligible.contains(c))
            .or_else(|| eligible.into_iter().max())
    }
}

/// Serves one browser call. `rest` is the rest of the caller's connection: it reaching EOF
/// means the caller gave up.
pub(crate) async fn serve(
    core: &Arc<Core>,
    call: BrowserCall,
    peer_uid: Option<u32>,
    mut rest: impl AsyncRead + Unpin,
) -> BrowserReply {
    if !core.hooks.verify(&call.token, &call.pane) {
        tracing::warn!("browser call with a bad token");
        return BrowserReply::Error("bad token".into());
    }
    // SAFETY: getuid has no preconditions and cannot fail.
    if peer_uid.is_some_and(|uid| uid != unsafe { libc::getuid() }) {
        tracing::warn!("browser call from another user");
        return BrowserReply::Error("another user".into());
    }
    let Some(pane) = call.pane.parse().ok().map(PaneId) else {
        return BrowserReply::Error("no such pane".into());
    };
    if core.pane(pane).is_none() {
        return BrowserReply::Error("no such pane".into());
    }
    let Some(conn) = core.browser_conn(pane) else {
        return BrowserReply::NoApp;
    };
    match call.browser {
        BrowserAsk::Open { url } => {
            if !is_openable(&url) {
                return BrowserReply::Error("only http and https URLs open in the app".into());
            }
            tracing::info!(pane = %pane, "opening a URL in the app");
            core.emit(Event::Browser {
                conn,
                push: BrowserPush::Open { pane_id: pane, url },
            });
            BrowserReply::Opened
        }
        BrowserAsk::Tool { name, args } => {
            let id = core.browser.next.fetch_add(1, Ordering::Relaxed);
            let (tx, rx) = oneshot::channel();
            lock(&core.browser.calls).insert(id, Pending { conn, reply: tx });
            core.emit(Event::Browser {
                conn,
                push: BrowserPush::Call {
                    id,
                    pane_id: pane,
                    tool: name,
                    args: args.to_string(),
                },
            });
            let reply = tokio::select! {
                answer = rx => match answer {
                    Ok(Ok(result)) => BrowserReply::Result(result),
                    Ok(Err(why)) => BrowserReply::Error(why),
                    Err(_) => BrowserReply::Error("the app went away".into()),
                },
                () = tokio::time::sleep(CALL_TIMEOUT) => BrowserReply::Error("the app did not answer in time".into()),
                () = crate::askpass::gone(&mut rest) => BrowserReply::Error("cancelled".into()),
            };
            if lock(&core.browser.calls).remove(&id).is_some() {
                core.emit(Event::Browser {
                    conn,
                    push: BrowserPush::CallClosed { id },
                });
            }
            reply
        }
    }
}

/// `http`/`https` URLs without control characters, of a sane length.
fn is_openable(url: &str) -> bool {
    let lower = url.get(..8).unwrap_or(url).to_ascii_lowercase();
    (lower.starts_with("http://") || lower.starts_with("https://"))
        && url.len() <= MAX_URL
        && !url.chars().any(char::is_control)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opens_only_web_urls() {
        assert!(is_openable("https://claude.ai/oauth/authorize?x=1"));
        assert!(is_openable("HTTP://localhost:3000/"));
        assert!(!is_openable("file:///etc/passwd"));
        assert!(!is_openable("javascript:alert(1)"));
        assert!(!is_openable("https://x/\n"));
        assert!(!is_openable("http"));
    }

    #[test]
    fn calls_and_replies_are_one_json_line_each() {
        let call = BrowserCall {
            v: BROWSER_VERSION,
            token: "t".into(),
            pane: "3".into(),
            browser: BrowserAsk::Open {
                url: "https://x".into(),
            },
        };
        let line = serde_json::to_string(&call).unwrap();
        assert_eq!(
            line,
            r#"{"v":1,"token":"t","pane":"3","browser":{"open":{"url":"https://x"}}}"#
        );
        // Neither the askpass helper's nor the pull channel's shape.
        assert!(serde_json::from_str::<crate::askpass::AskpassCall>(&line).is_err());
        assert!(serde_json::from_str::<crate::art::pull::PullCall>(&line).is_err());
        assert_eq!(
            serde_json::to_string(&BrowserReply::Result("{}".into())).unwrap(),
            r#"{"result":"{}"}"#
        );
        assert_eq!(
            serde_json::to_string(&BrowserReply::Opened).unwrap(),
            r#""opened""#
        );
    }
}
