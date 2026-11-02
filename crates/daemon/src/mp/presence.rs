//! Live presence (`proto::peer`): drafts, viewports, following, typing, idle and
//! away, per connection. All of it is ephemeral: kept in [`Live`](super::Live), never persisted
//! or audited, and gone with the connection.
//!
//! Ordering: every change bumps the daemon-wide revision and is stamped on the peer, so clients
//! keep the newest (last write wins). Fan-out sends a peer id ([`Event::Peer`]); each connection
//! reads the current state when it forwards, and coalesces per peer while its `ctl` stream is
//! backed up ([`Mailbox`]).

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::Instant;

use proto::{
    DeviceClass, Draft, Peer, PeerId, PeerPush, PeerUpdate, PeerViewport, PresenceState,
    PrincipalId, Scope, ServerCtl,
};
use tokio::sync::Notify;

use super::{Authz, Live, Mp};
use crate::core::{ConnId, Core, Event, lock};

pub(super) struct PeerState {
    /// Announced `Caps::PRESENCE`: it heartbeats, so silence means trouble.
    pub heartbeats: bool,
    pub device: DeviceClass,
    /// What the client said (`Away` while backgrounded).
    pub said: PresenceState,
    /// The state last broadcast, to notice derived changes.
    pub shown: PresenceState,
    pub viewport: Option<PeerViewport>,
    pub draft: Option<Draft>,
    pub following: Option<PrincipalId>,
    pub typing: Option<(proto::PaneId, Instant)>,
    /// Last message of any kind.
    pub heard: Instant,
    /// Last input, focus, viewport or draft change.
    pub active: Instant,
    pub rev: u64,
}

impl PeerState {
    pub fn new(heartbeats: bool) -> Self {
        let now = Instant::now();
        Self {
            heartbeats,
            device: DeviceClass::Unknown,
            said: PresenceState::Active,
            shown: PresenceState::Active,
            viewport: None,
            draft: None,
            following: None,
            typing: None,
            heard: now,
            active: now,
            rev: 0,
        }
    }
}

impl Mp {
    pub(super) fn bump(&self, live: &mut Live) {
        live.peer.rev = self
            .peer_rev
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            + 1;
    }

    /// The state others see: away when the client said so or went silent, idle after a
    /// while without activity.
    pub(super) fn state_of(&self, live: &Live) -> PresenceState {
        let peer = &live.peer;
        if peer.said == PresenceState::Away
            || (peer.heartbeats && peer.heard.elapsed() >= self.times.away)
        {
            PresenceState::Away
        } else if peer.said == PresenceState::Idle || peer.active.elapsed() >= self.times.idle {
            PresenceState::Idle
        } else {
            PresenceState::Active
        }
    }

    pub fn heard(&self, core: &Core, id: ConnId) {
        let woke = {
            let mut live = lock(&self.live);
            let Some(connection) = live.get_mut(&id) else {
                return;
            };
            connection.peer.heard = Instant::now();
            let woke = connection.peer.shown == PresenceState::Away
                && self.state_of(connection) != connection.peer.shown;
            if woke {
                connection.peer.shown = self.state_of(connection);
                self.bump(connection);
            }
            woke
        };
        if woke {
            core.emit(Event::Peer(id));
        }
    }

    /// Applies a client's report of its own state; the caller checked roles and scope.
    pub fn peer_update(&self, core: &Core, id: ConnId, update: PeerUpdate) {
        let (changed, legacy_presence) = {
            let mut live = lock(&self.live);
            let Some(connection) = live.get_mut(&id) else {
                return;
            };
            let was_typing = connection.typing;
            let peer = &mut connection.peer;
            let changed = match update {
                PeerUpdate::Heartbeat => false,
                PeerUpdate::Device(device) => std::mem::replace(&mut peer.device, device) != device,
                PeerUpdate::State(said) => {
                    if said == PresenceState::Active {
                        peer.active = Instant::now();
                    }
                    std::mem::replace(&mut peer.said, said) != said
                }
                PeerUpdate::Viewport(viewport) => {
                    peer.active = Instant::now();
                    std::mem::replace(&mut peer.viewport, viewport) != viewport
                }
                PeerUpdate::Draft(mut draft) => {
                    if let Some(draft) = &mut draft {
                        draft.clamp();
                        peer.typing = Some((draft.pane_id, Instant::now()));
                    } else if peer.draft.is_some() {
                        peer.typing = None;
                    }
                    peer.active = Instant::now();
                    let changed = std::mem::replace(&mut peer.draft, draft) != peer.draft;
                    // Feeds `Presence.typing` for clients without live presence.
                    connection.typing = peer
                        .draft
                        .as_ref()
                        .is_some_and(|draft| !draft.text.is_empty());
                    changed
                }
                PeerUpdate::Follow(following) => {
                    std::mem::replace(&mut peer.following, following) != following
                }
            };
            let state = self.state_of(connection);
            let changed = changed || state != connection.peer.shown;
            if changed {
                connection.peer.shown = state;
                self.bump(connection);
            }
            // Clients without live presence hear typing through `Presence`.
            let legacy_presence = (connection.typing != was_typing).then_some(proto::Presence {
                actor: connection.authz.actor,
                state,
                focus: connection.focus,
                typing: connection.typing,
                viewport: None,
                cursor: connection.cursor,
            });
            (changed, legacy_presence)
        };
        if changed {
            core.emit(Event::Peer(id));
        }
        if let Some(presence) = legacy_presence {
            core.emit(Event::Presence(presence));
        }
    }

    /// Raw input reached a pane: "typing" there, active. Broadcast only on the transition.
    pub fn typed(&self, core: &Core, id: ConnId, pane: proto::PaneId) {
        let changed = {
            let mut live = lock(&self.live);
            let Some(connection) = live.get_mut(&id) else {
                return;
            };
            let now = Instant::now();
            let was_typing_in = connection.peer.typing.map(|(pane, _)| pane);
            connection.peer.typing = Some((pane, now));
            connection.peer.active = now;
            let changed =
                was_typing_in != Some(pane) || connection.peer.shown != PresenceState::Active;
            if changed {
                connection.peer.shown = self.state_of(connection);
                self.bump(connection);
            }
            changed
        };
        if changed {
            core.emit(Event::Peer(id));
        }
    }

    /// One connection's presence as `viewer` may see it.
    pub fn peer(&self, core: &Core, id: ConnId, viewer: &Authz) -> Option<Peer> {
        let live = lock(&self.live);
        let connection = live.get(&id)?;
        let peer = self.wire(id, connection);
        drop(live);
        Some(redact(core, peer, viewer))
    }

    /// Everyone, oldest connection first, as `viewer` may see them.
    pub fn peers(&self, core: &Core, viewer: &Authz) -> Vec<Peer> {
        let mut all: Vec<Peer> = lock(&self.live)
            .iter()
            .map(|(&id, connection)| self.wire(id, connection))
            .collect();
        all.sort_by_key(|peer| (peer.since, peer.peer));
        all.into_iter()
            .map(|peer| redact(core, peer, viewer))
            .collect()
    }

    fn wire(&self, id: ConnId, connection: &Live) -> Peer {
        Peer {
            peer: PeerId(id),
            rev: connection.peer.rev,
            actor: connection.authz.actor,
            name: connection.name.clone(),
            roles: connection.authz.roles,
            device: connection.peer.device,
            since: connection.since,
            state: self.state_of(connection),
            focus: connection.focus,
            viewport: connection.peer.viewport,
            typing: connection.peer.typing.map(|(pane, _)| pane),
            draft: connection.peer.draft.clone(),
            following: connection.peer.following,
        }
    }

    /// Typing that stopped, idleness, silence; drops connections silent past `gone`.
    pub(super) fn tick_presence(&self, core: &Core) {
        let mut changed = Vec::new();
        let mut gone = Vec::new();
        {
            let mut live = lock(&self.live);
            for (&id, connection) in live.iter_mut() {
                let mut dirty = false;
                if connection
                    .peer
                    .typing
                    .is_some_and(|(_, at)| at.elapsed() >= self.times.typing)
                {
                    connection.peer.typing = None;
                    dirty = true;
                }
                let state = self.state_of(connection);
                if state != connection.peer.shown {
                    connection.peer.shown = state;
                    dirty = true;
                }
                if dirty {
                    self.bump(connection);
                    changed.push(id);
                }
                if connection.peer.heartbeats && connection.peer.heard.elapsed() >= self.times.gone
                {
                    gone.push(connection.conn.clone());
                }
            }
        }
        for id in changed {
            core.emit(Event::Peer(id));
        }
        for conn in gone {
            tracing::info!("dropping a connection silent past the presence timeout");
            conn.close(2u32.into(), b"presence timeout");
        }
    }
}

/// Hides what a peer does outside the viewer's scope.
fn redact(core: &Core, mut peer: Peer, viewer: &Authz) -> Peer {
    if viewer.scope == Scope::Daemon {
        return peer;
    }
    let visible = |pane: proto::PaneId| core.scope_within(Scope::Pane(pane), viewer.scope);
    if peer.focus.is_some_and(|pane| !visible(pane)) {
        peer.focus = None;
    }
    if peer
        .viewport
        .is_some_and(|viewport| !visible(viewport.pane_id))
    {
        peer.viewport = None;
    }
    if peer.typing.is_some_and(|pane| !visible(pane)) {
        peer.typing = None;
    }
    if peer
        .draft
        .as_ref()
        .is_some_and(|draft| !visible(draft.pane_id))
    {
        peer.draft = None;
    }
    peer
}

/// Peer pushes waiting for one connection's `ctl` writer: the newest state per peer, so a
/// slow link gets the latest rather than a backlog.
#[derive(Default)]
pub(crate) struct Mailbox {
    pending: Mutex<Pending>,
    pub ready: Notify,
}

#[derive(Default)]
struct Pending {
    all: Option<PeerPush>,
    changed: BTreeMap<PeerId, proto::Peer>,
}

impl Mailbox {
    /// Queues a push; a whole list replaces everything queued before it.
    pub fn put(&self, push: PeerPush) {
        {
            let mut pending = lock(&self.pending);
            match push {
                all @ PeerPush::All { .. } => {
                    pending.changed.clear();
                    pending.all = Some(all);
                }
                PeerPush::Changed(peer) => {
                    let newer = pending
                        .changed
                        .get(&peer.peer)
                        .is_none_or(|queued| queued.rev <= peer.rev);
                    if newer {
                        pending.changed.insert(peer.peer, peer);
                    }
                }
            }
        }
        self.ready.notify_one();
    }

    /// Everything queued, as `ctl` messages, oldest kind first.
    pub fn take(&self) -> Vec<ServerCtl> {
        let mut pending = lock(&self.pending);
        let all = pending.all.take();
        let changed = std::mem::take(&mut pending.changed);
        all.into_iter()
            .chain(changed.into_values().map(PeerPush::Changed))
            .map(ServerCtl::Peers)
            .collect()
    }
}
