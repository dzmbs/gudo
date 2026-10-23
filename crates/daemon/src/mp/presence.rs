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

/// A connection's presence.
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
        let p = &live.peer;
        if p.said == PresenceState::Away || (p.heartbeats && p.heard.elapsed() >= self.times.away) {
            PresenceState::Away
        } else if p.said == PresenceState::Idle || p.active.elapsed() >= self.times.idle {
            PresenceState::Idle
        } else {
            PresenceState::Active
        }
    }

    /// Any message from the connection: it is still there.
    pub fn heard(&self, core: &Core, id: ConnId) {
        let woke = {
            let mut live = lock(&self.live);
            let Some(l) = live.get_mut(&id) else { return };
            l.peer.heard = Instant::now();
            let woke = l.peer.shown == PresenceState::Away && self.state_of(l) != l.peer.shown;
            if woke {
                l.peer.shown = self.state_of(l);
                self.bump(l);
            }
            woke
        };
        if woke {
            core.emit(Event::Peer(id));
        }
    }

    /// Applies a client's report of its own state; the caller checked roles and scope.
    pub fn peer_update(&self, core: &Core, id: ConnId, update: PeerUpdate) {
        let (changed, old) = {
            let mut live = lock(&self.live);
            let Some(l) = live.get_mut(&id) else { return };
            let was_typing = l.typing;
            let p = &mut l.peer;
            let changed = match update {
                PeerUpdate::Heartbeat => false,
                PeerUpdate::Device(d) => std::mem::replace(&mut p.device, d) != d,
                PeerUpdate::State(s) => {
                    if s == PresenceState::Active {
                        p.active = Instant::now();
                    }
                    std::mem::replace(&mut p.said, s) != s
                }
                PeerUpdate::Viewport(v) => {
                    p.active = Instant::now();
                    std::mem::replace(&mut p.viewport, v) != v
                }
                PeerUpdate::Draft(mut d) => {
                    if let Some(d) = &mut d {
                        d.clamp();
                        p.typing = Some((d.pane_id, Instant::now()));
                    } else if p.draft.is_some() {
                        p.typing = None;
                    }
                    p.active = Instant::now();
                    let changed = std::mem::replace(&mut p.draft, d) != p.draft;
                    // The old `Presence.typing`, for clients without live presence.
                    l.typing = p.draft.as_ref().is_some_and(|d| !d.text.is_empty());
                    changed
                }
                PeerUpdate::Follow(f) => std::mem::replace(&mut p.following, f) != f,
            };
            let state = self.state_of(l);
            let changed = changed || state != l.peer.shown;
            if changed {
                l.peer.shown = state;
                self.bump(l);
            }
            // Clients without live presence hear typing the old way.
            let old = (l.typing != was_typing).then_some(proto::Presence {
                actor: l.authz.actor,
                state,
                focus: l.focus,
                typing: l.typing,
                viewport: None,
                cursor: l.cursor,
            });
            (changed, old)
        };
        if changed {
            core.emit(Event::Peer(id));
        }
        if let Some(presence) = old {
            core.emit(Event::Presence(presence));
        }
    }

    /// Raw input reached a pane: "typing" there, active. Broadcast only on the transition.
    pub fn typed(&self, core: &Core, id: ConnId, pane: proto::PaneId) {
        let changed = {
            let mut live = lock(&self.live);
            let Some(l) = live.get_mut(&id) else { return };
            let now = Instant::now();
            let was = l.peer.typing.map(|(p, _)| p);
            l.peer.typing = Some((pane, now));
            l.peer.active = now;
            let changed = was != Some(pane) || l.peer.shown != PresenceState::Active;
            if changed {
                l.peer.shown = self.state_of(l);
                self.bump(l);
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
        let l = live.get(&id)?;
        let peer = self.wire(id, l);
        drop(live);
        Some(redact(core, peer, viewer))
    }

    /// Everyone, oldest connection first, as `viewer` may see them.
    pub fn peers(&self, core: &Core, viewer: &Authz) -> Vec<Peer> {
        let mut all: Vec<Peer> = lock(&self.live)
            .iter()
            .map(|(&id, l)| self.wire(id, l))
            .collect();
        all.sort_by_key(|p| (p.since, p.peer));
        all.into_iter().map(|p| redact(core, p, viewer)).collect()
    }

    fn wire(&self, id: ConnId, l: &Live) -> Peer {
        Peer {
            peer: PeerId(id),
            rev: l.peer.rev,
            actor: l.authz.actor,
            name: l.name.clone(),
            roles: l.authz.roles,
            device: l.peer.device,
            since: l.since,
            state: self.state_of(l),
            focus: l.focus,
            viewport: l.peer.viewport,
            typing: l.peer.typing.map(|(p, _)| p),
            draft: l.peer.draft.clone(),
            following: l.peer.following,
        }
    }

    /// Typing that stopped, idleness, silence; drops connections silent past `gone`.
    pub(super) fn tick_presence(&self, core: &Core) {
        let mut changed = Vec::new();
        let mut gone = Vec::new();
        {
            let mut live = lock(&self.live);
            for (&id, l) in live.iter_mut() {
                let mut dirty = false;
                if l.peer
                    .typing
                    .is_some_and(|(_, at)| at.elapsed() >= self.times.typing)
                {
                    l.peer.typing = None;
                    dirty = true;
                }
                let state = self.state_of(l);
                if state != l.peer.shown {
                    l.peer.shown = state;
                    dirty = true;
                }
                if dirty {
                    self.bump(l);
                    changed.push(id);
                }
                if l.peer.heartbeats && l.peer.heard.elapsed() >= self.times.gone {
                    gone.push(l.conn.clone());
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
fn redact(core: &Core, mut p: Peer, viewer: &Authz) -> Peer {
    if viewer.scope == Scope::Daemon {
        return p;
    }
    let visible = |pane: proto::PaneId| core.scope_within(Scope::Pane(pane), viewer.scope);
    if p.focus.is_some_and(|f| !visible(f)) {
        p.focus = None;
    }
    if p.viewport.is_some_and(|v| !visible(v.pane_id)) {
        p.viewport = None;
    }
    if p.typing.is_some_and(|t| !visible(t)) {
        p.typing = None;
    }
    if p.draft.as_ref().is_some_and(|d| !visible(d.pane_id)) {
        p.draft = None;
    }
    p
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
            let mut p = lock(&self.pending);
            match push {
                all @ PeerPush::All { .. } => {
                    p.changed.clear();
                    p.all = Some(all);
                }
                PeerPush::Changed(peer) => {
                    let newer = p.changed.get(&peer.peer).is_none_or(|q| q.rev <= peer.rev);
                    if newer {
                        p.changed.insert(peer.peer, peer);
                    }
                }
            }
        }
        self.ready.notify_one();
    }

    /// Everything queued, as `ctl` messages, oldest kind first.
    pub fn take(&self) -> Vec<ServerCtl> {
        let mut p = lock(&self.pending);
        let all = p.all.take();
        let changed = std::mem::take(&mut p.changed);
        all.into_iter()
            .chain(changed.into_values().map(PeerPush::Changed))
            .map(ServerCtl::Peers)
            .collect()
    }
}
