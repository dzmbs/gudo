//! Live presence on [`DaemonClient`] (`proto::peer`): drafts being typed,
//! viewports, following, idle and away.

use client_core::proto;

use crate::client::DaemonClient;
use crate::mp::{Actor, MultiplayerError, PresenceState, Role, hex, roles_to_ffi, unhex};

/// What kind of device a peer is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum DeviceClass {
    /// Not said (older apps).
    Unknown,
    Phone,
    Tablet,
    Desktop,
    /// A command-line client.
    Terminal,
}

impl From<proto::DeviceClass> for DeviceClass {
    fn from(device_class: proto::DeviceClass) -> Self {
        match device_class {
            proto::DeviceClass::Unknown => Self::Unknown,
            proto::DeviceClass::Phone => Self::Phone,
            proto::DeviceClass::Tablet => Self::Tablet,
            proto::DeviceClass::Desktop => Self::Desktop,
            proto::DeviceClass::Terminal => Self::Terminal,
        }
    }
}

impl From<DeviceClass> for proto::DeviceClass {
    fn from(device_class: DeviceClass) -> Self {
        match device_class {
            DeviceClass::Unknown => Self::Unknown,
            DeviceClass::Phone => Self::Phone,
            DeviceClass::Tablet => Self::Tablet,
            DeviceClass::Desktop => Self::Desktop,
            DeviceClass::Terminal => Self::Terminal,
        }
    }
}

/// The rows of a pane on screen, counted from the live screen up.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PeerViewport {
    pub pane_id: u64,
    /// Rows scrolled back; 0 is the live screen.
    pub from_bottom: u32,
    /// Rows visible.
    pub rows: u16,
}

impl From<proto::PeerViewport> for PeerViewport {
    fn from(peer_viewport: proto::PeerViewport) -> Self {
        Self {
            pane_id: peer_viewport.pane_id.0,
            from_bottom: peer_viewport.from_bottom,
            rows: peer_viewport.rows,
        }
    }
}

impl From<PeerViewport> for proto::PeerViewport {
    fn from(peer_viewport: PeerViewport) -> Self {
        Self {
            pane_id: proto::PaneId(peer_viewport.pane_id),
            from_bottom: peer_viewport.from_bottom,
            rows: peer_viewport.rows,
        }
    }
}

/// Where a draft is typed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum DraftSource {
    /// The line editor at a shell prompt.
    LineEditor,
    /// The agent composer above the key bar.
    Composer,
    /// A prompter's composer.
    Prompt,
}

impl From<proto::DraftSource> for DraftSource {
    fn from(draft_source: proto::DraftSource) -> Self {
        match draft_source {
            proto::DraftSource::LineEditor => Self::LineEditor,
            proto::DraftSource::Composer => Self::Composer,
            proto::DraftSource::Prompt => Self::Prompt,
        }
    }
}

impl From<DraftSource> for proto::DraftSource {
    fn from(draft_source: DraftSource) -> Self {
        match draft_source {
            DraftSource::LineEditor => Self::LineEditor,
            DraftSource::Composer => Self::Composer,
            DraftSource::Prompt => Self::Prompt,
        }
    }
}

/// Text someone is composing for a pane.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct Draft {
    pub pane_id: u64,
    /// Where it is typed.
    pub source: DraftSource,
    /// The text so far.
    pub text: String,
    /// The caret, in characters.
    pub caret: u32,
}

impl From<proto::Draft> for Draft {
    fn from(draft: proto::Draft) -> Self {
        Self {
            pane_id: draft.pane_id.0,
            source: draft.source.into(),
            text: draft.text,
            caret: draft.caret,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Peer {
    /// The connection (one device may hold several).
    pub peer: u64,
    /// The daemon's revision; newer replaces older.
    pub rev: u64,
    pub actor: Actor,
    pub name: String,
    pub roles: Vec<Role>,
    pub device: DeviceClass,
    /// Connected since, Unix ms.
    pub since_ms: u64,
    /// Active, idle or away.
    pub state: PresenceState,
    pub focus: Option<u64>,
    /// What it sees of the focused pane.
    pub viewport: Option<PeerViewport>,
    /// The pane it is typing in right now.
    pub typing: Option<u64>,
    pub draft: Option<Draft>,
    /// The principal it follows (hex).
    pub following: Option<String>,
}

impl From<proto::Peer> for Peer {
    fn from(peer: proto::Peer) -> Self {
        Self {
            peer: peer.peer.0,
            rev: peer.rev,
            actor: peer.actor.into(),
            name: peer.name,
            roles: roles_to_ffi(peer.roles),
            device: peer.device.into(),
            since_ms: peer.since.0,
            state: peer.state.into(),
            focus: peer.focus.map(|f| f.0),
            viewport: peer.viewport.map(Into::into),
            typing: peer.typing.map(|t| t.0),
            draft: peer.draft.map(Into::into),
            following: peer.following.map(|f| hex(&f.0)),
        }
    }
}

/// Everyone's live presence and which entry is this connection.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PeerList {
    /// This connection, once the daemon said.
    pub you: Option<u64>,
    /// Every connection, oldest first.
    pub peers: Vec<Peer>,
}

#[uniffi::export]
impl DaemonClient {
    /// Whether the daemon offers live presence (drafts, viewports, following).
    pub fn has_live_presence(&self) -> bool {
        self.inner.has_live_presence()
    }

    /// The draft being typed for a pane; others see it live. Sent at most ~30 times a second.
    pub fn set_draft(&self, pane_id: u64, source: DraftSource, text: String, caret: u32) {
        self.inner.set_draft(Some(proto::Draft {
            pane_id: proto::PaneId(pane_id),
            source: source.into(),
            text,
            caret,
        }));
    }

    /// The draft was sent or discarded.
    pub fn clear_draft(&self) {
        self.inner.set_draft(None);
    }

    /// The rows of the focused pane on screen; `nil` when no terminal shows.
    pub fn set_viewport(&self, viewport: Option<PeerViewport>) {
        self.inner.set_viewport(viewport.map(Into::into));
    }

    /// Follows a person by principal (hex), or stops with `nil`.
    ///
    /// # Errors
    ///
    /// [`MultiplayerError::Invalid`] for a malformed principal.
    pub fn follow(&self, principal: Option<String>) -> Result<(), MultiplayerError> {
        let principal = principal
            .map(|p| unhex("principal", &p).map(proto::PrincipalId))
            .transpose()?;
        self.inner.follow(principal);
        Ok(())
    }

    pub fn set_device_class(&self, device: DeviceClass) {
        self.inner.set_device_class(device.into());
    }

    /// `Away` in the background, `Active` in the foreground.
    pub fn set_presence_state(&self, state: PresenceState) {
        self.inner.set_presence_state(match state {
            PresenceState::Active => proto::PresenceState::Active,
            PresenceState::Idle => proto::PresenceState::Idle,
            PresenceState::Away => proto::PresenceState::Away,
        });
    }

    /// Everyone's live presence as last pushed (no round trip).
    pub fn peer_list(&self) -> PeerList {
        let (you, peers) = self.inner.peers();
        PeerList {
            you: you.map(|p| p.0),
            peers: peers.into_iter().map(Into::into).collect(),
        }
    }
}
