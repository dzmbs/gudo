//! The app's browser, used from the host: URLs programs open and browser tools agents call.
//!
//! 1. **Opening URLs.** Panes get `BROWSER` naming the daemon's helper. When a program opens a
//!    URL with it (`claude /login`, `gh browse`), the daemon pushes [`BrowserPush::Open`] to
//!    one connection that shows the pane: the one that last sized it, else the newest. The
//!    app decides how: a sign-in whose redirect returns to a loopback port on the host gets
//!    that port here and a system sign-in sheet; anything else opens in its browser.
//! 2. **Browser tools.** An agent's MCP server (`gudo-hook mcp`) or `gudo-hook browser <verb>`
//!    asks for a [`BrowserPush::Call`]: navigate, snapshot, click, type, … on the browser pane
//!    beside the agent's pane. The app answers with
//!    [`ClientCtl::BrowserResult`](crate::ClientCtl::BrowserResult); the daemon pushes
//!    [`BrowserPush::CallClosed`] when the call ends any other way.
//!
//! Pushes go only to connections that announced [`Caps::BROWSER`](crate::Caps::BROWSER) and
//! hold Driver (or Owner) on the pane.

use serde::{Deserialize, Serialize};

use crate::ids::PaneId;

/// What the host asks the app's browser to do.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum BrowserPush {
    /// A program in `pane_id` asked for `url` to be opened.
    Open {
        pane_id: PaneId,
        /// The URL, as the program passed it.
        url: String,
    },
    /// An agent in `pane_id` calls browser tool `tool` with JSON arguments `args`.
    Call {
        /// Answer with this id.
        id: u64,
        /// The agent's pane.
        pane_id: PaneId,
        /// The tool (`browser_navigate`, `browser_snapshot`, …).
        tool: String,
        /// Its arguments, a JSON object.
        args: String,
    },
    /// Call `id` is over (the agent gave up or it timed out): drop it.
    CallClosed { id: u64 },
}
