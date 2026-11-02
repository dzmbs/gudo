//! Live presence (`proto::peer`): this device's draft, viewport, follow target and
//! activity going out, everyone's coming in.
//!
//! Outgoing state is kept, not queued: a sender task per connection sends what changed, the
//! first change at once and then at most every [`MIN_INTERVAL`] (last write wins), and sends
//! everything again after a reconnect. Nothing goes to daemons without
//! [`DaemonFeatures::PRESENCE`](proto::DaemonFeatures), which would not understand it.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::{
    ClientCtl, DaemonFeatures, DeviceClass, Draft, Peer, PeerId, PeerPush, PeerUpdate,
    PeerViewport, PresenceState, PrincipalId,
};
use tokio::sync::{Notify, mpsc};

use crate::{Client, Inner, lock};

/// Drafts and viewports go out at most this often (~30 Hz).
pub const MIN_INTERVAL: Duration = Duration::from_millis(33);

/// What this device reports, and which parts the daemon has not heard yet.
#[derive(Default)]
struct OutgoingPresence {
    device: Option<DeviceClass>,
    state: Option<PresenceState>,
    viewport: Option<Option<PeerViewport>>,
    draft: Option<Option<Draft>>,
    follow: Option<Option<PrincipalId>>,
    dirty: Dirty,
}

#[derive(Default, Clone, Copy)]
struct Dirty {
    device: bool,
    state: bool,
    viewport: bool,
    draft: bool,
    follow: bool,
}

/// Presence state kept by the client.
#[derive(Default)]
pub(crate) struct PeerState {
    outgoing: Mutex<OutgoingPresence>,
    changed: Notify,
    you: Mutex<Option<PeerId>>,
    peers: Mutex<BTreeMap<PeerId, Peer>>,
}

impl PeerState {
    /// Applies a push; returns it as an event when it changed anything.
    pub(crate) fn apply(&self, push: PeerPush) -> Option<crate::MultiplayerEvent> {
        match push {
            PeerPush::All { you, peers } => {
                *lock(&self.you) = Some(you);
                *lock(&self.peers) = peers.iter().map(|peer| (peer.peer, peer.clone())).collect();
                Some(crate::MultiplayerEvent::Peers { you, peers })
            }
            PeerPush::Changed(peer) => {
                let mut known = lock(&self.peers);
                if known
                    .get(&peer.peer)
                    .is_some_and(|held| held.rev >= peer.rev)
                {
                    return None;
                }
                known.insert(peer.peer, peer.clone());
                Some(crate::MultiplayerEvent::PeerChanged { peer })
            }
        }
    }

    /// A new connection: everyone else's state comes again; ours is sent again.
    pub(crate) fn reset_for_connection(&self) {
        lock(&self.peers).clear();
        *lock(&self.you) = None;
        let mut outgoing = lock(&self.outgoing);
        outgoing.dirty = Dirty {
            device: outgoing.device.is_some(),
            state: outgoing.state.is_some(),
            viewport: outgoing.viewport.is_some(),
            draft: outgoing.draft.is_some(),
            follow: outgoing.follow.is_some(),
        };
        drop(outgoing);
        self.changed.notify_one();
    }

    fn update(&self, change: impl FnOnce(&mut OutgoingPresence)) {
        change(&mut lock(&self.outgoing));
        self.changed.notify_one();
    }

    /// The pending updates, oldest kind first; marks them sent.
    fn take(&self) -> Vec<PeerUpdate> {
        let mut outgoing = lock(&self.outgoing);
        let dirty = std::mem::take(&mut outgoing.dirty);
        let mut updates = Vec::new();
        if dirty.device
            && let Some(device) = outgoing.device
        {
            updates.push(PeerUpdate::Device(device));
        }
        if dirty.state
            && let Some(state) = outgoing.state
        {
            updates.push(PeerUpdate::State(state));
        }
        if dirty.follow
            && let Some(follow) = outgoing.follow
        {
            updates.push(PeerUpdate::Follow(follow));
        }
        if dirty.viewport
            && let Some(viewport) = outgoing.viewport
        {
            updates.push(PeerUpdate::Viewport(viewport));
        }
        if dirty.draft
            && let Some(draft) = outgoing.draft.clone()
        {
            updates.push(PeerUpdate::Draft(draft));
        }
        updates
    }
}

/// Sends this device's presence on one connection until it ends: changes as they come
/// (rate-limited), a heartbeat when quiet.
pub(crate) async fn send_presence(
    inner: Arc<Inner>,
    ctl: mpsc::UnboundedSender<ClientCtl>,
) -> String {
    let supported = lock(&inner.daemon_info)
        .as_ref()
        .is_some_and(|info| info.features.contains(DaemonFeatures::PRESENCE));
    if !supported {
        return std::future::pending().await;
    }
    let state = &inner.mp.peers;
    let heartbeat = Duration::from_secs(PeerUpdate::HEARTBEAT_SECS);
    loop {
        let mut updates = state.take();
        if updates.is_empty() {
            if tokio::time::timeout(heartbeat, state.changed.notified())
                .await
                .is_ok()
            {
                continue;
            }
            updates.push(PeerUpdate::Heartbeat);
        }
        for update in updates {
            if ctl.send(ClientCtl::Peer(update)).is_err() {
                return "ctl closed".into();
            }
        }
        tokio::time::sleep(MIN_INTERVAL).await;
    }
}

impl Client {
    /// Whether the daemon offers live presence (drafts, viewports, following).
    pub fn has_live_presence(&self) -> bool {
        self.daemon_has(DaemonFeatures::PRESENCE)
    }

    /// The draft being composed for a pane, or `None` once it is sent or discarded. Others
    /// see it as it is typed; it is never written anywhere.
    pub fn set_draft(&self, draft: Option<Draft>) {
        self.inner.mp.peers.update(|outgoing| {
            if outgoing.draft.as_ref() != Some(&draft) {
                outgoing.draft = Some(draft);
                outgoing.dirty.draft = true;
            }
        });
    }

    /// The rows of the focused pane on screen.
    pub fn set_viewport(&self, viewport: Option<PeerViewport>) {
        self.inner.mp.peers.update(|outgoing| {
            if outgoing.viewport != Some(viewport) {
                outgoing.viewport = Some(viewport);
                outgoing.dirty.viewport = true;
            }
        });
    }

    /// Follows a person (their most recently active device), or stops (`None`).
    pub fn follow(&self, principal: Option<PrincipalId>) {
        self.inner.mp.peers.update(|outgoing| {
            if outgoing.follow != Some(principal) {
                outgoing.follow = Some(principal);
                outgoing.dirty.follow = true;
            }
        });
    }

    /// This device's kind, said once per connection.
    pub fn set_device_class(&self, device: DeviceClass) {
        self.inner.mp.peers.update(|outgoing| {
            outgoing.device = Some(device);
            outgoing.dirty.device = true;
        });
    }

    /// `Away` while the app is in the background, `Active` when it is back.
    pub fn set_presence_state(&self, state: PresenceState) {
        self.inner.mp.peers.update(|outgoing| {
            if outgoing.state != Some(state) {
                outgoing.state = Some(state);
                outgoing.dirty.state = true;
            }
        });
    }

    /// Everyone connected with their live presence, oldest connection first, and which of
    /// them is this connection.
    pub fn peers(&self) -> (Option<PeerId>, Vec<Peer>) {
        let state = &self.inner.mp.peers;
        let you = *lock(&state.you);
        (you, lock(&state.peers).values().cloned().collect())
    }
}

#[cfg(test)]
mod tests {
    use proto::{Actor, DeviceId, PrincipalId, Roles, UnixMillis};

    use super::*;

    fn peer(id: u64, rev: u64, text: &str) -> Peer {
        Peer {
            peer: PeerId(id),
            rev,
            actor: Actor {
                principal: PrincipalId([1; 16]),
                device: DeviceId([2; 32]),
            },
            name: "Kim".into(),
            roles: Roles::DRIVER,
            device: DeviceClass::Tablet,
            since: UnixMillis(0),
            state: PresenceState::Active,
            focus: None,
            viewport: None,
            typing: None,
            draft: Some(Draft {
                pane_id: proto::PaneId(1),
                source: proto::DraftSource::Composer,
                text: text.into(),
                caret: 0,
            }),
            following: None,
        }
    }

    #[test]
    fn the_newest_revision_wins() {
        let state = PeerState::default();
        assert!(state.apply(PeerPush::Changed(peer(1, 5, "abc"))).is_some());
        assert!(state.apply(PeerPush::Changed(peer(1, 4, "ab"))).is_none());
        assert!(state.apply(PeerPush::Changed(peer(1, 5, "ab"))).is_none());
        assert_eq!(
            lock(&state.peers)[&PeerId(1)].draft.as_ref().unwrap().text,
            "abc"
        );
        // A whole list replaces everything, older revisions included.
        state.apply(PeerPush::All {
            you: PeerId(2),
            peers: vec![peer(1, 3, "a")],
        });
        assert_eq!(lock(&state.peers)[&PeerId(1)].rev, 3);
    }

    #[test]
    fn a_reconnect_sends_everything_again_and_only_once() {
        let state = PeerState::default();
        state.update(|outgoing| {
            outgoing.draft = Some(peer(1, 1, "hi").draft);
            outgoing.dirty.draft = true;
            outgoing.follow = Some(None);
            outgoing.dirty.follow = true;
        });
        assert_eq!(state.take().len(), 2);
        assert!(state.take().is_empty());
        state.reset_for_connection();
        assert_eq!(state.take().len(), 2);
    }
}
