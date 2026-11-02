//! Live presence: who is here, where they look, what they are typing, and whom
//! they follow. Offered by daemons with [`DaemonFeatures::PRESENCE`](crate::DaemonFeatures) to
//! clients announcing [`Caps::PRESENCE`](crate::Caps).
//!
//! - A client reports its own state with [`ClientCtl::Peer`](crate::ClientCtl::Peer)
//!   ([`PeerUpdate`]): its device class, activity, viewport, the draft in its line editor or
//!   composer, and whom it follows. Focus still comes from `ClientCtl::Focus`.
//! - The daemon answers with [`ServerCtl::Peers`](crate::ServerCtl::Peers) ([`PeerPush`]): the
//!   whole list on joining and whenever someone joins or leaves, then one [`Peer`] at a time.
//!   Each carries a daemon revision; a client keeps the newest per [`PeerId`] (last write
//!   wins). Under back-pressure the daemon sends only the newest state of each peer.
//! - Everything here is ephemeral: never written to scrollback, history or the audit log, and
//!   gone when the connection is. A reconnecting client sends its state again.
//! - Scope applies: what a peer does in panes outside the recipient's grant (focus, viewport,
//!   typing, draft) is withheld. Drafts need the prompter, driver or approver role.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::ids::{Actor, PaneId, PrincipalId, Roles, UnixMillis};
use crate::msg::PresenceState;

/// One connection on one daemon run. A device may hold several.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct PeerId(pub u64);

impl fmt::Display for PeerId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// What kind of device a peer is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub enum DeviceClass {
    /// Not said (older clients).
    #[default]
    Unknown,
    /// iPhone.
    Phone,
    /// iPad.
    Tablet,
    /// Mac.
    Desktop,
    /// A command-line client.
    Terminal,
}

/// The rows of a pane a peer has on screen, counted from the bottom so they mean the same on
/// every client whatever scrollback each holds: `from_bottom == 0` is the live screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PeerViewport {
    pub pane_id: PaneId,
    /// Rows scrolled back from the live screen.
    pub from_bottom: u32,
    pub rows: u16,
}

/// Where a draft is being written.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DraftSource {
    /// The line editor at a shell prompt.
    LineEditor,
    /// The agent composer above the key bar.
    Composer,
    /// A prompter's composer (sent with `MpRequest::Prompt`).
    Prompt,
}

/// Text being composed for a pane, not yet sent.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Draft {
    pub pane_id: PaneId,
    /// Where it is typed.
    pub source: DraftSource,
    /// The text so far, at most [`Draft::MAX_BYTES`] (the daemon truncates).
    pub text: String,
    /// The caret, in characters from the start.
    pub caret: u32,
}

impl Draft {
    /// The longest draft the daemon keeps and forwards, in UTF-8 bytes.
    pub const MAX_BYTES: usize = 4096;

    /// Truncates to [`MAX_BYTES`](Self::MAX_BYTES) on a character boundary and clamps the
    /// caret to the text.
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::{Draft, DraftSource, PaneId};
    ///
    /// let mut draft = Draft { pane_id: PaneId(1), source: DraftSource::Composer, text: "é".repeat(3000), caret: 9999 };
    /// draft.clamp();
    /// assert!(draft.text.len() <= Draft::MAX_BYTES);
    /// assert_eq!(draft.caret as usize, draft.text.chars().count());
    /// ```
    pub fn clamp(&mut self) {
        if self.text.len() > Self::MAX_BYTES {
            let mut end = Self::MAX_BYTES;
            while !self.text.is_char_boundary(end) {
                end -= 1;
            }
            self.text.truncate(end);
        }
        let char_count = self.text.chars().count() as u32;
        self.caret = self.caret.min(char_count);
    }
}

/// A client's report of its own state ([`ClientCtl::Peer`](crate::ClientCtl::Peer)). Each
/// replaces the previous value of the same kind.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum PeerUpdate {
    /// The kind of device (once, after connecting).
    Device(DeviceClass),
    /// Activity: `Away` when the app goes to the background, `Active` when it comes back.
    /// The daemon derives idleness and silence on its own.
    State(PresenceState),
    /// The rows on screen of the focused pane; `None` when no terminal shows.
    Viewport(Option<PeerViewport>),
    /// The draft being composed; `None` clears it (sent, discarded, or the editor closed).
    Draft(Option<Draft>),
    /// Follow a person (their most recently active device), or stop.
    Follow(Option<PrincipalId>),
    /// Still here. Sent every [`PeerUpdate::HEARTBEAT_SECS`] seconds when nothing else is.
    Heartbeat,
}

impl PeerUpdate {
    /// How often a client sends [`PeerUpdate::Heartbeat`].
    pub const HEARTBEAT_SECS: u64 = 10;
}

/// One peer as the recipient may see it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Peer {
    /// The connection.
    pub peer: PeerId,
    /// The daemon's revision of this state; newer replaces older.
    pub rev: u64,
    pub actor: Actor,
    pub name: String,
    /// Effective roles.
    pub roles: Roles,
    pub device: DeviceClass,
    /// When it connected.
    pub since: UnixMillis,
    /// Active, idle (no input for a while) or away (backgrounded, or silent).
    pub state: PresenceState,
    /// The pane it focuses.
    pub focus: Option<PaneId>,
    /// What it sees of its focused pane.
    pub viewport: Option<PeerViewport>,
    /// The pane it is typing in right now (raw input or a draft).
    pub typing: Option<PaneId>,
    pub draft: Option<Draft>,
    pub following: Option<PrincipalId>,
}

/// Peer pushes ([`ServerCtl::Peers`](crate::ServerCtl::Peers)).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum PeerPush {
    /// Everyone connected, this connection included: replaces the list.
    All {
        /// This connection.
        you: PeerId,
        /// Every peer, oldest connection first.
        peers: Vec<Peer>,
    },
    /// One peer changed: replace it when `rev` is newer than the one held.
    Changed(Peer),
}
