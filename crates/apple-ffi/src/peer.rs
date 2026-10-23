//! viewports, following, idle and away.

use client_core::proto;

use crate::client::DaemonClient;
use crate::mp::{Actor, MultiplayerError, PresenceState, Role, hex, roles_to_ffi, unhex};

/// What kind of device a peer is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum DeviceClass {
    /// Not said (older apps).
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

impl From<proto::DeviceClass> for DeviceClass {
    fn from(d: proto::DeviceClass) -> Self {
        match d {
            proto::DeviceClass::Unknown => Self::Unknown,
            proto::DeviceClass::Phone => Self::Phone,
            proto::DeviceClass::Tablet => Self::Tablet,
            proto::DeviceClass::Desktop => Self::Desktop,
            proto::DeviceClass::Terminal => Self::Terminal,
        }
    }
}

impl From<DeviceClass> for proto::DeviceClass {
    fn from(d: DeviceClass) -> Self {
        match d {
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
    /// The pane.
    pub pane_id: u64,
    /// Rows scrolled back; 0 is the live screen.
    pub from_bottom: u32,
    /// Rows visible.
    pub rows: u16,
}

impl From<proto::PeerViewport> for PeerViewport {
    fn from(v: proto::PeerViewport) -> Self {
        Self {
            pane_id: v.pane_id.0,
            from_bottom: v.from_bottom,
            rows: v.rows,
        }
    }
}

impl From<PeerViewport> for proto::PeerViewport {
    fn from(v: PeerViewport) -> Self {
        Self {
            pane_id: proto::PaneId(v.pane_id),
            from_bottom: v.from_bottom,
            rows: v.rows,
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
    fn from(s: proto::DraftSource) -> Self {
        match s {
            proto::DraftSource::LineEditor => Self::LineEditor,
            proto::DraftSource::Composer => Self::Composer,
            proto::DraftSource::Prompt => Self::Prompt,
        }
    }
}

impl From<DraftSource> for proto::DraftSource {
    fn from(s: DraftSource) -> Self {
        match s {
            DraftSource::LineEditor => Self::LineEditor,
            DraftSource::Composer => Self::Composer,
            DraftSource::Prompt => Self::Prompt,
        }
    }
}

/// Text someone is composing for a pane.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct Draft {
    /// The pane.
    pub pane_id: u64,
    /// Where it is typed.
    pub source: DraftSource,
    /// The text so far.
    pub text: String,
    /// The caret, in characters.
    pub caret: u32,
}

impl From<proto::Draft> for Draft {
    fn from(d: proto::Draft) -> Self {
        Self {
            pane_id: d.pane_id.0,
            source: d.source.into(),
            text: d.text,
            caret: d.caret,
        }
    }
}

/// One connection's live presence.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Peer {
    /// The connection (one device may hold several).
    pub peer: u64,
    /// The daemon's revision; newer replaces older.
    pub rev: u64,
    /// Who.
    pub actor: Actor,
    /// Display name.
    pub name: String,
    /// Effective roles.
    pub roles: Vec<Role>,
    /// The device kind.
    pub device: DeviceClass,
    /// Connected since, Unix ms.
    pub since_ms: u64,
    /// Active, idle or away.
    pub state: PresenceState,
    /// Focused pane.
    pub focus: Option<u64>,
    /// What it sees of the focused pane.
    pub viewport: Option<PeerViewport>,
    /// The pane it is typing in right now.
    pub typing: Option<u64>,
    /// Its draft.
    pub draft: Option<Draft>,
    /// The principal it follows (hex).
    pub following: Option<String>,
}

impl From<proto::Peer> for Peer {
    fn from(p: proto::Peer) -> Self {
        Self {
            peer: p.peer.0,
            rev: p.rev,
            actor: p.actor.into(),
            name: p.name,
            roles: roles_to_ffi(p.roles),
            device: p.device.into(),
            since_ms: p.since.0,
            state: p.state.into(),
            focus: p.focus.map(|f| f.0),
            viewport: p.viewport.map(Into::into),
            typing: p.typing.map(|t| t.0),
            draft: p.draft.map(Into::into),
            following: p.following.map(|f| hex(&f.0)),
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

    /// This device's kind.
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
