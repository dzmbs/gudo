//! The attention feed: agents blocked or done and long commands finished unseen, as one list
//! the app turns into local notifications and an inbox.
//!
//! Items are kept in memory (the last [`MAX_ITEMS`]). "Seen" is per [`Viewer`]: the owner's
//! devices share one, each guest has its own. An item is seen by a viewer when it marks it,
//! when it focuses the item's pane, or when it showed the pane as the item happened; a blocked
//! agent's item is seen by everyone once the blocker goes away. Pushes and the owner's
//! notifications follow the owner's "seen" only, so no guest can silence them.

use std::collections::{HashSet, VecDeque};
use std::sync::Mutex;

use proto::{
    AttentionItem, AttentionKind, AttentionList, AttentionSeen, AttentionUpdate, PaneId,
    PrincipalId, SessionId, UnixMillis,
};

use crate::core::lock;

pub(crate) const MAX_ITEMS: usize = 500;

/// Whose "seen" an action records.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum Viewer {
    Owner,
    Guest(PrincipalId),
}

/// An item with the owner's "seen" in `item` and every guest's beside it.
struct Entry {
    item: AttentionItem,
    resolved: bool,
    guests_viewing: HashSet<PrincipalId>,
    guests_seen: HashSet<PrincipalId>,
}

impl Entry {
    fn seen_by(&self, viewer: Viewer) -> bool {
        match viewer {
            Viewer::Owner => self.item.seen,
            Viewer::Guest(principal) => self.resolved || self.guests_seen.contains(&principal),
        }
    }

    fn as_seen_by(&self, viewer: Viewer) -> AttentionItem {
        let mut item = self.item.clone();
        if let Viewer::Guest(principal) = viewer {
            item.seen = self.seen_by(viewer);
            item.while_viewed = self.guests_viewing.contains(&principal);
        }
        item
    }

    fn mark_seen_by(&mut self, viewer: Viewer) -> bool {
        if self.seen_by(viewer) {
            return false;
        }
        match viewer {
            Viewer::Owner => self.item.seen = true,
            Viewer::Guest(principal) => {
                self.guests_seen.insert(principal);
            }
        }
        true
    }
}

#[derive(Default)]
struct Inner {
    entries: VecDeque<Entry>,
    next_id: u64,
}

impl Inner {
    fn unseen_by(&self, viewer: Viewer, visible: impl Fn(PaneId) -> bool) -> u32 {
        self.entries
            .iter()
            .filter(|entry| visible(entry.item.pane_id) && !entry.seen_by(viewer))
            .count() as u32
    }
}

#[derive(Default)]
pub(crate) struct Attention {
    inner: Mutex<Inner>,
}

/// A new item, before it gets an id.
pub(crate) struct NewItem {
    pub pane_id: PaneId,
    pub session_id: Option<SessionId>,
    pub kind: AttentionKind,
    pub title: String,
    pub body: String,
    /// Who shows the pane as it happens (it starts seen for them).
    pub viewers: Vec<Viewer>,
}

impl Attention {
    /// Returns the update to broadcast, as the owner sees it.
    pub fn add(&self, new: NewItem) -> AttentionUpdate {
        let mut inner = lock(&self.inner);
        inner.next_id += 1;
        let owner_viewing = new.viewers.contains(&Viewer::Owner);
        let guests_viewing: HashSet<PrincipalId> = new
            .viewers
            .iter()
            .filter_map(|viewer| match viewer {
                Viewer::Guest(principal) => Some(*principal),
                Viewer::Owner => None,
            })
            .collect();
        let item = AttentionItem {
            id: inner.next_id,
            at: UnixMillis(crate::identity::now_millis()),
            pane_id: new.pane_id,
            session_id: new.session_id,
            kind: new.kind,
            title: new.title,
            body: new.body,
            seen: owner_viewing,
            while_viewed: owner_viewing,
        };
        inner.entries.push_back(Entry {
            item: item.clone(),
            resolved: false,
            guests_seen: guests_viewing.clone(),
            guests_viewing,
        });
        while inner.entries.len() > MAX_ITEMS {
            inner.entries.pop_front();
        }
        AttentionUpdate::Added {
            item,
            unseen: inner.unseen_by(Viewer::Owner, |_| true),
        }
    }

    /// Every item as `viewer` sees it (the caller filters to its scope).
    pub fn list_for(&self, viewer: Viewer) -> AttentionList {
        let inner = lock(&self.inner);
        AttentionList {
            items: inner
                .entries
                .iter()
                .map(|entry| entry.as_seen_by(viewer))
                .collect(),
            unseen: inner.unseen_by(viewer, |_| true),
        }
    }

    /// The owner's view of an item.
    pub fn get(&self, id: u64) -> Option<AttentionItem> {
        self.find(id, |entry| entry.item.clone())
    }

    /// `item` as `viewer` sees it now.
    pub fn as_seen_by(&self, viewer: Viewer, item: &AttentionItem) -> AttentionItem {
        self.find(item.id, |entry| entry.as_seen_by(viewer))
            .unwrap_or_else(|| item.clone())
    }

    pub fn pane_of(&self, id: u64) -> Option<PaneId> {
        self.find(id, |entry| entry.item.pane_id)
    }

    pub fn unseen_by(&self, viewer: Viewer, visible: impl Fn(PaneId) -> bool) -> u32 {
        let visible = self.visible_panes(visible);
        lock(&self.inner).unseen_by(viewer, |pane| visible.contains(&pane))
    }

    /// `visible` may take the layout lock, so it runs outside this store's.
    fn visible_panes(&self, visible: impl Fn(PaneId) -> bool) -> HashSet<PaneId> {
        let panes: HashSet<PaneId> = lock(&self.inner)
            .entries
            .iter()
            .map(|entry| entry.item.pane_id)
            .collect();
        panes.into_iter().filter(|&pane| visible(pane)).collect()
    }

    fn find<T>(&self, id: u64, read: impl FnOnce(&Entry) -> T) -> Option<T> {
        lock(&self.inner)
            .entries
            .iter()
            .find(|entry| entry.item.id == id)
            .map(read)
    }

    /// Whether an item newer than `id` exists for the same pane that the owner has not seen
    /// (a push for `id` would be superseded by that one's).
    pub fn superseded(&self, id: u64, pane: PaneId) -> bool {
        lock(&self.inner)
            .entries
            .iter()
            .any(|entry| entry.item.id > id && entry.item.pane_id == pane && !entry.item.seen)
    }

    /// Marks matching items of panes `visible` to `viewer` seen by it; returns their ids.
    pub fn mark(
        &self,
        viewer: Viewer,
        which: &AttentionSeen,
        visible: impl Fn(PaneId) -> bool,
    ) -> Vec<u64> {
        let visible = self.visible_panes(visible);
        let mut inner = lock(&self.inner);
        let mut ids = Vec::new();
        for entry in &mut inner.entries {
            let item = &entry.item;
            let matches = which.ids.contains(&item.id)
                || which.up_to.is_some_and(|up_to| item.id <= up_to)
                || which.pane_id == Some(item.pane_id);
            if matches && visible.contains(&item.pane_id) && entry.mark_seen_by(viewer) {
                ids.push(entry.item.id);
            }
        }
        ids
    }

    /// Marks a pane's blocked-agent items seen by everyone (the blocker went away).
    pub fn resolve_blocked(&self, pane: PaneId) -> Vec<u64> {
        let mut inner = lock(&self.inner);
        let mut ids = Vec::new();
        for entry in &mut inner.entries {
            if entry.item.pane_id == pane
                && matches!(entry.item.kind, AttentionKind::AgentBlocked { .. })
                && !entry.resolved
            {
                entry.resolved = true;
                entry.item.seen = true;
                ids.push(entry.item.id);
            }
        }
        ids
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(pane: u64, kind: AttentionKind, viewers: Vec<Viewer>) -> NewItem {
        NewItem {
            pane_id: PaneId(pane),
            session_id: None,
            kind,
            title: "t".into(),
            body: String::new(),
            viewers,
        }
    }

    fn pane_seen(pane: u64) -> AttentionSeen {
        AttentionSeen {
            ids: vec![],
            up_to: None,
            pane_id: Some(PaneId(pane)),
        }
    }

    #[test]
    fn counts_and_marks_seen() {
        let attention = Attention::default();
        let blocked = AttentionKind::AgentBlocked {
            agent: "claude".into(),
            request_id: None,
        };
        let done = AttentionKind::AgentDone {
            agent: "claude".into(),
        };
        attention.add(item(1, blocked.clone(), vec![]));
        attention.add(item(2, done.clone(), vec![]));
        let AttentionUpdate::Added { unseen, .. } =
            attention.add(item(2, done, vec![Viewer::Owner]))
        else {
            panic!()
        };
        assert_eq!(unseen, 2, "an item that happened in view starts seen");
        assert_eq!(attention.resolve_blocked(PaneId(1)), vec![1]);
        assert!(attention.resolve_blocked(PaneId(1)).is_empty());
        assert_eq!(
            attention.mark(Viewer::Owner, &pane_seen(2), |_| true),
            vec![2]
        );
        assert_eq!(attention.list_for(Viewer::Owner).unseen, 0);
        assert_eq!(attention.list_for(Viewer::Owner).items.len(), 3);
    }

    #[test]
    fn each_viewer_has_its_own_seen() {
        let attention = Attention::default();
        let alice = Viewer::Guest(PrincipalId([1; 16]));
        let bob = Viewer::Guest(PrincipalId([2; 16]));
        let done = AttentionKind::AgentDone {
            agent: "claude".into(),
        };
        attention.add(item(1, done.clone(), vec![alice]));
        attention.add(item(2, done, vec![]));
        assert_eq!(attention.list_for(Viewer::Owner).unseen, 2);
        assert_eq!(attention.list_for(alice).unseen, 1);
        assert!(attention.list_for(alice).items[0].while_viewed);

        let everything = AttentionSeen {
            ids: vec![],
            up_to: Some(u64::MAX),
            pane_id: None,
        };
        assert_eq!(
            attention.mark(alice, &everything, |pane| pane == PaneId(1)),
            Vec::<u64>::new(),
            "outside its scope nothing is marked"
        );
        assert_eq!(attention.mark(bob, &everything, |_| true), vec![1, 2]);
        assert_eq!(attention.list_for(Viewer::Owner).unseen, 2);
        assert_eq!(attention.list_for(alice).unseen, 1);
        assert_eq!(attention.list_for(bob).unseen, 0);
        assert!(!attention.superseded(1, PaneId(1)));
    }

    #[test]
    fn a_resolved_blocker_is_seen_by_everyone() {
        let attention = Attention::default();
        let guest = Viewer::Guest(PrincipalId([1; 16]));
        attention.add(item(
            1,
            AttentionKind::AgentBlocked {
                agent: "claude".into(),
                request_id: None,
            },
            vec![],
        ));
        assert_eq!(attention.list_for(guest).unseen, 1);
        attention.resolve_blocked(PaneId(1));
        assert_eq!(attention.list_for(guest).unseen, 0);
        assert_eq!(attention.list_for(Viewer::Owner).unseen, 0);
    }
}
