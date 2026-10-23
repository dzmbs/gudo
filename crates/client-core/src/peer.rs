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
struct Out {
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
    out: Mutex<Out>,
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
                *lock(&self.peers) = peers.iter().map(|p| (p.peer, p.clone())).collect();
                Some(crate::MultiplayerEvent::Peers { you, peers })
            }
            PeerPush::Changed(peer) => {
                let mut all = lock(&self.peers);
                if all.get(&peer.peer).is_some_and(|held| held.rev >= peer.rev) {
                    return None;
                }
                all.insert(peer.peer, peer.clone());
                Some(crate::MultiplayerEvent::PeerChanged { peer })
            }
        }
    }

    /// A new connection: everyone else's state comes again; ours is sent again.
    pub(crate) fn reset_for_connection(&self) {
        lock(&self.peers).clear();
        *lock(&self.you) = None;
        let mut out = lock(&self.out);
        out.dirty = Dirty {
            device: out.device.is_some(),
            state: out.state.is_some(),
            viewport: out.viewport.is_some(),
            draft: out.draft.is_some(),
            follow: out.follow.is_some(),
        };
        drop(out);
        self.changed.notify_one();
    }

    fn update(&self, f: impl FnOnce(&mut Out)) {
        f(&mut lock(&self.out));
        self.changed.notify_one();
    }

    /// The pending updates, oldest kind first; marks them sent.
    fn take(&self) -> Vec<PeerUpdate> {
        let mut out = lock(&self.out);
        let dirty = std::mem::take(&mut out.dirty);
        let mut msgs = Vec::new();
        if dirty.device
            && let Some(d) = out.device
        {
            msgs.push(PeerUpdate::Device(d));
        }
        if dirty.state
            && let Some(s) = out.state
        {
            msgs.push(PeerUpdate::State(s));
        }
        if dirty.follow
            && let Some(f) = out.follow
        {
            msgs.push(PeerUpdate::Follow(f));
        }
        if dirty.viewport
            && let Some(v) = out.viewport
        {
            msgs.push(PeerUpdate::Viewport(v));
        }
        if dirty.draft
            && let Some(d) = out.draft.clone()
        {
            msgs.push(PeerUpdate::Draft(d));
        }
        msgs
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
        .is_some_and(|i| i.features.contains(DaemonFeatures::PRESENCE));
    if !supported {
        return std::future::pending().await;
    }
    let state = &inner.mp.peers;
    let heartbeat = Duration::from_secs(PeerUpdate::HEARTBEAT_SECS);
    loop {
        let mut msgs = state.take();
        if msgs.is_empty() {
            if tokio::time::timeout(heartbeat, state.changed.notified())
                .await
                .is_ok()
            {
                continue;
            }
            msgs.push(PeerUpdate::Heartbeat);
        }
        for msg in msgs {
            if ctl.send(ClientCtl::Peer(msg)).is_err() {
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
        self.inner.mp.peers.update(|o| {
            if o.draft.as_ref() != Some(&draft) {
                o.draft = Some(draft);
                o.dirty.draft = true;
            }
        });
    }

    /// The rows of the focused pane on screen.
    pub fn set_viewport(&self, viewport: Option<PeerViewport>) {
        self.inner.mp.peers.update(|o| {
            if o.viewport != Some(viewport) {
                o.viewport = Some(viewport);
                o.dirty.viewport = true;
            }
        });
    }

    /// Follows a person (their most recently active device), or stops (`None`).
    pub fn follow(&self, principal: Option<PrincipalId>) {
        self.inner.mp.peers.update(|o| {
            if o.follow != Some(principal) {
                o.follow = Some(principal);
                o.dirty.follow = true;
            }
        });
    }

    /// This device's kind, said once per connection.
    pub fn set_device_class(&self, device: DeviceClass) {
        self.inner.mp.peers.update(|o| {
            o.device = Some(device);
            o.dirty.device = true;
        });
    }

    /// `Away` while the app is in the background, `Active` when it is back.
    pub fn set_presence_state(&self, state: PresenceState) {
        self.inner.mp.peers.update(|o| {
            if o.state != Some(state) {
                o.state = Some(state);
                o.dirty.state = true;
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
        state.update(|o| {
            o.draft = Some(peer(1, 1, "hi").draft);
            o.dirty.draft = true;
            o.follow = Some(None);
            o.dirty.follow = true;
        });
        assert_eq!(state.take().len(), 2);
        assert!(state.take().is_empty());
        state.reset_for_connection();
        assert_eq!(state.take().len(), 2);
    }
}
