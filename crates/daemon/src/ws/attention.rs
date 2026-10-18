//! The attention feed: agents blocked or done and long commands finished unseen, as one list
//!
//! Items are kept in memory (the last [`MAX_ITEMS`]). "Seen" is shared by all devices: an
//! item is seen when a client marks it, when any client focuses its pane, or (for a blocked
//! agent) when the blocker goes away. An item that happened while a client showed the pane
//! starts out seen, so it never notifies.

use std::collections::VecDeque;
use std::sync::Mutex;

use proto::{
    AttentionItem, AttentionKind, AttentionList, AttentionSeen, AttentionUpdate, PaneId, SessionId,
    UnixMillis,
};

use crate::core::lock;

/// Items kept.
pub(crate) const MAX_ITEMS: usize = 500;

#[derive(Default)]
struct Inner {
    items: VecDeque<AttentionItem>,
    next_id: u64,
}

impl Inner {
    fn unseen(&self) -> u32 {
        self.items.iter().filter(|i| !i.seen).count() as u32
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
    pub while_viewed: bool,
}

impl Attention {
    /// Records an item; returns the update to broadcast.
    pub fn add(&self, new: NewItem) -> AttentionUpdate {
        let mut inner = lock(&self.inner);
        inner.next_id += 1;
        let item = AttentionItem {
            id: inner.next_id,
            at: UnixMillis(crate::identity::now_millis()),
            pane_id: new.pane_id,
            session_id: new.session_id,
            kind: new.kind,
            title: new.title,
            body: new.body,
            seen: new.while_viewed,
            while_viewed: new.while_viewed,
        };
        inner.items.push_back(item.clone());
        while inner.items.len() > MAX_ITEMS {
            inner.items.pop_front();
        }
        AttentionUpdate::Added {
            item,
            unseen: inner.unseen(),
        }
    }

    pub fn list(&self) -> AttentionList {
        let inner = lock(&self.inner);
        AttentionList {
            items: inner.items.iter().cloned().collect(),
            unseen: inner.unseen(),
        }
    }

    /// Marks matching unseen items seen; `None` if nothing changed.
    pub fn mark(&self, which: &AttentionSeen) -> Option<AttentionUpdate> {
        self.mark_where(|item| {
            which.ids.contains(&item.id)
                || which.up_to.is_some_and(|up| item.id <= up)
                || which.pane_id == Some(item.pane_id)
        })
    }

    /// Marks a pane's blocked-agent items seen (the blocker went away).
    pub fn resolve_blocked(&self, pane: PaneId) -> Option<AttentionUpdate> {
        self.mark_where(|item| {
            item.pane_id == pane && matches!(item.kind, AttentionKind::AgentBlocked { .. })
        })
    }

    fn mark_where(&self, pred: impl Fn(&AttentionItem) -> bool) -> Option<AttentionUpdate> {
        let mut inner = lock(&self.inner);
        let mut ids = Vec::new();
        for item in inner.items.iter_mut().filter(|i| !i.seen) {
            if pred(item) {
                item.seen = true;
                ids.push(item.id);
            }
        }
        (!ids.is_empty()).then(|| AttentionUpdate::Seen {
            ids,
            unseen: inner.unseen(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(pane: u64, kind: AttentionKind, viewed: bool) -> NewItem {
        NewItem {
            pane_id: PaneId(pane),
            session_id: None,
            kind,
            title: "t".into(),
            body: String::new(),
            while_viewed: viewed,
        }
    }

    #[test]
    fn counts_and_marks_seen() {
        let a = Attention::default();
        let blocked = AttentionKind::AgentBlocked {
            agent: "claude".into(),
            request_id: None,
        };
        let done = AttentionKind::AgentDone {
            agent: "claude".into(),
        };
        a.add(item(1, blocked.clone(), false));
        a.add(item(2, done.clone(), false));
        let AttentionUpdate::Added { unseen, .. } = a.add(item(2, done, true)) else {
            panic!()
        };
        assert_eq!(unseen, 2, "an item that happened in view starts seen");
        assert_eq!(
            a.resolve_blocked(PaneId(1)),
            Some(AttentionUpdate::Seen {
                ids: vec![1],
                unseen: 1
            })
        );
        assert_eq!(a.resolve_blocked(PaneId(1)), None);
        let seen = AttentionSeen {
            ids: vec![],
            up_to: None,
            pane_id: Some(PaneId(2)),
        };
        assert_eq!(
            a.mark(&seen),
            Some(AttentionUpdate::Seen {
                ids: vec![2],
                unseen: 0
            })
        );
        assert_eq!(a.list().items.len(), 3);
    }
}
