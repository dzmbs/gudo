//! Sessions, tabs and split trees: pure state, no I/O.
//!
//! Every mutation either fails with an [`OpError`] and leaves the state unchanged, or applies
//! completely and bumps the affected session's revision (only when something changed).
//! Creating panes is two-phase: the caller reserves an id with [`Layout::alloc_pane`], spawns
//! the process, then inserts the id. Removing panes returns their ids so the caller can kill
//! them.

use proto::{
    Axis, Direction, LayoutNode, OpError, PaneId, SessionId, SessionLayout, SessionSummary, TabId,
    TabLayout,
};
use serde::{Deserialize, Serialize};

/// Smallest share either side of a split may have.
const MIN_RATIO: f32 = 0.05;

/// One session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct Session {
    pub id: SessionId,
    pub name: String,
    pub revision: u64,
    pub active_tab: Option<TabId>,
    pub tabs: Vec<TabLayout>,
}

impl Session {
    fn to_wire(&self) -> SessionLayout {
        SessionLayout {
            session_id: self.id,
            name: self.name.clone(),
            revision: self.revision,
            active_tab: self.active_tab,
            tabs: self.tabs.clone(),
        }
    }

    fn panes(&self) -> impl Iterator<Item = PaneId> + '_ {
        self.tabs.iter().flat_map(|t| leaves(&t.root))
    }
}

/// What a removal took away.
#[derive(Debug, Default, PartialEq)]
pub(crate) struct Removed {
    /// Panes whose processes must be killed.
    pub panes: Vec<PaneId>,
    /// Set when the session lost its last tab and was removed too.
    pub session: Option<SessionId>,
}

/// All sessions of a daemon.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub(crate) struct Layout {
    sessions: Vec<Session>,
    /// Most recently used first.
    mru: Vec<SessionId>,
    next_session: u64,
    next_tab: u64,
    next_pane: u64,
}

type OpResult<T> = Result<T, OpError>;

impl Layout {
    /// Reserves a fresh pane id.
    pub fn alloc_pane(&mut self) -> PaneId {
        self.next_pane += 1;
        PaneId(self.next_pane)
    }

    #[cfg(test)]
    pub fn sessions(&self) -> &[Session] {
        &self.sessions
    }

    pub fn session(&self, id: SessionId) -> Option<&Session> {
        self.sessions.iter().find(|s| s.id == id)
    }

    pub fn snapshot(&self, id: SessionId) -> Option<SessionLayout> {
        self.session(id).map(Session::to_wire)
    }

    /// The most recently used session.
    pub fn most_recent(&self) -> Option<SessionId> {
        self.mru
            .first()
            .copied()
            .or_else(|| self.sessions.first().map(|s| s.id))
    }

    /// Marks `id` as most recently used.
    pub fn touch(&mut self, id: SessionId) {
        self.mru.retain(|&s| s != id);
        self.mru.insert(0, id);
    }

    pub fn summaries(&self, clients: impl Fn(SessionId) -> u32) -> Vec<SessionSummary> {
        self.sessions
            .iter()
            .map(|s| SessionSummary {
                session_id: s.id,
                name: s.name.clone(),
                tabs: s.tabs.len() as u32,
                panes: s.panes().count() as u32,
                clients: clients(s.id),
            })
            .collect()
    }

    /// Every pane in every session.
    pub fn all_panes(&self) -> Vec<PaneId> {
        self.sessions.iter().flat_map(Session::panes).collect()
    }

    pub fn session_of_pane(&self, pane: PaneId) -> Option<SessionId> {
        self.locate(pane).map(|(s, _)| self.sessions[s].id)
    }

    pub fn session_of_tab(&self, tab: TabId) -> Option<SessionId> {
        self.locate_tab(tab).map(|(s, _)| self.sessions[s].id)
    }

    #[cfg(test)]
    /// The focused pane of the session's active tab.
    pub fn focused_pane(&self, session: SessionId) -> Option<PaneId> {
        let s = self.session(session)?;
        let tab = s.tabs.iter().find(|t| Some(t.tab_id) == s.active_tab)?;
        Some(tab.focused)
    }

    #[cfg(test)]
    /// The panes shown on screen for the session's active tab, focused first.
    pub fn visible_panes(&self, session: SessionId) -> Vec<PaneId> {
        let Some(s) = self.session(session) else {
            return Vec::new();
        };
        let Some(tab) = s.tabs.iter().find(|t| Some(t.tab_id) == s.active_tab) else {
            return Vec::new();
        };
        if let Some(zoomed) = tab.zoomed {
            return vec![zoomed];
        }
        let mut panes: Vec<_> = leaves(&tab.root).collect();
        panes.sort_by_key(|&p| p != tab.focused);
        panes
    }

    fn locate(&self, pane: PaneId) -> Option<(usize, usize)> {
        self.sessions.iter().enumerate().find_map(|(si, s)| {
            s.tabs
                .iter()
                .position(|t| leaves(&t.root).any(|p| p == pane))
                .map(|ti| (si, ti))
        })
    }

    fn locate_tab(&self, tab: TabId) -> Option<(usize, usize)> {
        self.sessions.iter().enumerate().find_map(|(si, s)| {
            s.tabs
                .iter()
                .position(|t| t.tab_id == tab)
                .map(|ti| (si, ti))
        })
    }

    fn session_index(&self, id: SessionId) -> OpResult<usize> {
        self.sessions
            .iter()
            .position(|s| s.id == id)
            .ok_or(OpError::NotFound)
    }

    fn name_taken(&self, name: &str, except: Option<SessionId>) -> bool {
        self.sessions
            .iter()
            .any(|s| s.name == name && Some(s.id) != except)
    }

    /// Returns a session name not yet in use, `base` or `base-N`.
    pub fn unique_name(&self, base: &str) -> String {
        let base = if base.is_empty() { "main" } else { base };
        if !self.name_taken(base, None) {
            return base.to_owned();
        }
        (2..)
            .map(|n| format!("{base}-{n}"))
            .find(|n| !self.name_taken(n, None))
            .expect("some suffix is free")
    }

    fn new_tab_layout(&mut self, name: String, pane: PaneId) -> TabLayout {
        self.next_tab += 1;
        TabLayout {
            tab_id: TabId(self.next_tab),
            name,
            root: LayoutNode::Leaf(pane),
            focused: pane,
            zoomed: None,
        }
    }

    /// Fails if `name` is taken.
    pub fn check_session_name(&self, name: &str) -> OpResult<()> {
        if name.is_empty() {
            return Err(OpError::Invalid);
        }
        if self.name_taken(name, None) {
            return Err(OpError::NameTaken);
        }
        Ok(())
    }

    pub fn create_session(&mut self, name: String, pane: PaneId) -> OpResult<(SessionId, TabId)> {
        self.check_session_name(&name)?;
        self.next_session += 1;
        let id = SessionId(self.next_session);
        let tab = self.new_tab_layout(String::new(), pane);
        let tab_id = tab.tab_id;
        self.sessions.push(Session {
            id,
            name,
            revision: 1,
            active_tab: Some(tab_id),
            tabs: vec![tab],
        });
        self.touch(id);
        Ok((id, tab_id))
    }

    pub fn close_session(&mut self, id: SessionId) -> OpResult<Removed> {
        let index = self.session_index(id)?;
        let session = self.sessions.remove(index);
        self.mru.retain(|&s| s != id);
        Ok(Removed {
            panes: session.panes().collect(),
            session: Some(id),
        })
    }

    pub fn rename_session(&mut self, id: SessionId, name: String) -> OpResult<()> {
        if name.is_empty() {
            return Err(OpError::Invalid);
        }
        let index = self.session_index(id)?;
        if self.name_taken(&name, Some(id)) {
            return Err(OpError::NameTaken);
        }
        let s = &mut self.sessions[index];
        if s.name != name {
            s.name = name;
            s.revision += 1;
        }
        Ok(())
    }

    pub fn new_tab(&mut self, session: SessionId, name: String, pane: PaneId) -> OpResult<TabId> {
        let index = self.session_index(session)?;
        let tab = self.new_tab_layout(name, pane);
        let tab_id = tab.tab_id;
        let s = &mut self.sessions[index];
        s.tabs.push(tab);
        s.active_tab = Some(tab_id);
        s.revision += 1;
        Ok(tab_id)
    }

    pub fn close_tab(&mut self, tab: TabId) -> OpResult<Removed> {
        let (si, ti) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        Ok(self.remove_tab(si, ti))
    }

    fn remove_tab(&mut self, si: usize, ti: usize) -> Removed {
        let s = &mut self.sessions[si];
        let tab = s.tabs.remove(ti);
        let panes = leaves(&tab.root).collect();
        if s.tabs.is_empty() {
            let id = s.id;
            self.sessions.remove(si);
            self.mru.retain(|&x| x != id);
            return Removed {
                panes,
                session: Some(id),
            };
        }
        if s.active_tab == Some(tab.tab_id) {
            // Like browsers: the tab that slides into the closed one's place.
            s.active_tab = Some(s.tabs[ti.min(s.tabs.len() - 1)].tab_id);
        }
        s.revision += 1;
        Removed {
            panes,
            session: None,
        }
    }

    pub fn move_tab(&mut self, tab: TabId, index: u32) -> OpResult<()> {
        let (si, ti) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let s = &mut self.sessions[si];
        let to = (index as usize).min(s.tabs.len() - 1);
        if to != ti {
            let t = s.tabs.remove(ti);
            s.tabs.insert(to, t);
            s.revision += 1;
        }
        Ok(())
    }

    pub fn select_tab(&mut self, tab: TabId) -> OpResult<()> {
        let (si, _) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let s = &mut self.sessions[si];
        if s.active_tab != Some(tab) {
            s.active_tab = Some(tab);
            s.revision += 1;
        }
        Ok(())
    }

    pub fn rename_tab(&mut self, tab: TabId, name: String) -> OpResult<()> {
        let (si, ti) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let s = &mut self.sessions[si];
        if s.tabs[ti].name != name {
            s.tabs[ti].name = name;
            s.revision += 1;
        }
        Ok(())
    }

    /// Splits `pane`, putting `new` after it, and focuses `new`.
    pub fn split(&mut self, pane: PaneId, axis: Axis, new: PaneId) -> OpResult<SessionId> {
        let (si, ti) = self.locate(pane).ok_or(OpError::NotFound)?;
        let s = &mut self.sessions[si];
        let tab = &mut s.tabs[ti];
        let replaced = replace_leaf(&mut tab.root, pane, |leaf| LayoutNode::Split {
            axis,
            ratio: 0.5,
            first: Box::new(leaf),
            second: Box::new(LayoutNode::Leaf(new)),
        });
        debug_assert!(replaced);
        tab.focused = new;
        tab.zoomed = None;
        s.revision += 1;
        Ok(s.id)
    }

    pub fn close_pane(&mut self, pane: PaneId) -> OpResult<Removed> {
        let (si, ti) = self.locate(pane).ok_or(OpError::NotFound)?;
        let tab = &mut self.sessions[si].tabs[ti];
        if tab.root == LayoutNode::Leaf(pane) {
            return Ok(self.remove_tab(si, ti));
        }
        // Focus moves to the closed pane's sibling subtree (its first leaf), like tmux.
        let sibling_leaf = remove_leaf(&mut tab.root, pane).expect("pane is in this tab");
        if tab.focused == pane {
            tab.focused = sibling_leaf;
        }
        if tab.zoomed == Some(pane) {
            tab.zoomed = None;
        }
        self.sessions[si].revision += 1;
        Ok(Removed {
            panes: vec![pane],
            session: None,
        })
    }

    pub fn focus(&mut self, pane: PaneId) -> OpResult<()> {
        let (si, ti) = self.locate(pane).ok_or(OpError::NotFound)?;
        let s = &mut self.sessions[si];
        let tab_id = s.tabs[ti].tab_id;
        let tab = &mut s.tabs[ti];
        let mut changed = false;
        if tab.focused != pane {
            tab.focused = pane;
            changed = true;
        }
        if tab.zoomed.is_some_and(|z| z != pane) {
            tab.zoomed = None;
            changed = true;
        }
        if s.active_tab != Some(tab_id) {
            s.active_tab = Some(tab_id);
            changed = true;
        }
        if changed {
            s.revision += 1;
        }
        Ok(())
    }

    pub fn focus_direction(&mut self, tab: TabId, direction: Direction) -> OpResult<()> {
        let (si, ti) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let t = &self.sessions[si].tabs[ti];
        match neighbor(&t.root, t.focused, direction) {
            Some(next) => self.focus(next),
            None => Ok(()),
        }
    }

    pub fn resize(&mut self, pane: PaneId, axis: Axis, delta: f32) -> OpResult<()> {
        if !delta.is_finite() {
            return Err(OpError::Invalid);
        }
        let (si, ti) = self.locate(pane).ok_or(OpError::NotFound)?;
        let s = &mut self.sessions[si];
        if resize_in(&mut s.tabs[ti].root, pane, axis, delta) == Resize::Changed {
            s.revision += 1;
        }
        Ok(())
    }

    pub fn toggle_zoom(&mut self, pane: PaneId) -> OpResult<()> {
        let (si, ti) = self.locate(pane).ok_or(OpError::NotFound)?;
        let s = &mut self.sessions[si];
        let tab = &mut s.tabs[ti];
        tab.zoomed = if tab.zoomed == Some(pane) {
            None
        } else {
            Some(pane)
        };
        tab.focused = pane;
        s.revision += 1;
        Ok(())
    }
}

/// Leaves of a tree, left to right / top to bottom.
pub(crate) fn leaves(node: &LayoutNode) -> Box<dyn Iterator<Item = PaneId> + '_> {
    match node {
        LayoutNode::Leaf(p) => Box::new(std::iter::once(*p)),
        LayoutNode::Split { first, second, .. } => Box::new(leaves(first).chain(leaves(second))),
    }
}

fn first_leaf(node: &LayoutNode) -> PaneId {
    match node {
        LayoutNode::Leaf(p) => *p,
        LayoutNode::Split { first, .. } => first_leaf(first),
    }
}

/// Replaces the leaf `pane` with `f(leaf)`. Returns whether it was found.
fn replace_leaf(
    node: &mut LayoutNode,
    pane: PaneId,
    f: impl FnOnce(LayoutNode) -> LayoutNode,
) -> bool {
    fn walk(
        node: &mut LayoutNode,
        pane: PaneId,
        f: &mut Option<impl FnOnce(LayoutNode) -> LayoutNode>,
    ) -> bool {
        match node {
            LayoutNode::Leaf(p) if *p == pane => {
                let leaf = std::mem::replace(node, LayoutNode::Leaf(pane));
                *node = (f.take().expect("called once"))(leaf);
                true
            }
            LayoutNode::Leaf(_) => false,
            LayoutNode::Split { first, second, .. } => {
                walk(first, pane, f) || walk(second, pane, f)
            }
        }
    }
    walk(node, pane, &mut Some(f))
}

/// Removes leaf `pane` (not the root), collapsing its parent into the sibling. Returns the
/// sibling subtree's first leaf.
fn remove_leaf(node: &mut LayoutNode, pane: PaneId) -> Option<PaneId> {
    let LayoutNode::Split { first, second, .. } = node else {
        return None;
    };
    let sibling = if **first == LayoutNode::Leaf(pane) {
        Some(std::mem::replace(&mut **second, LayoutNode::Leaf(pane)))
    } else if **second == LayoutNode::Leaf(pane) {
        Some(std::mem::replace(&mut **first, LayoutNode::Leaf(pane)))
    } else {
        None
    };
    if let Some(sibling) = sibling {
        let leaf = first_leaf(&sibling);
        *node = sibling;
        return Some(leaf);
    }
    remove_leaf(first, pane).or_else(|| remove_leaf(second, pane))
}

#[derive(Debug, PartialEq)]
enum Resize {
    NotFound,
    /// The pane is in this subtree but no enclosing split on the axis has been adjusted yet.
    Pending {
        in_first: bool,
    },
    Changed,
    Unchanged,
}

fn resize_in(node: &mut LayoutNode, pane: PaneId, axis: Axis, delta: f32) -> Resize {
    match node {
        LayoutNode::Leaf(p) if *p == pane => Resize::Pending { in_first: true },
        LayoutNode::Leaf(_) => Resize::NotFound,
        LayoutNode::Split {
            axis: split_axis,
            ratio,
            first,
            second,
        } => {
            let (child, in_first) = match resize_in(first, pane, axis, delta) {
                Resize::NotFound => (resize_in(second, pane, axis, delta), false),
                other => (other, true),
            };
            match child {
                Resize::Pending { .. } if *split_axis == axis => {
                    let signed = if in_first { delta } else { -delta };
                    let next = (*ratio + signed).clamp(MIN_RATIO, 1.0 - MIN_RATIO);
                    if (next - *ratio).abs() > f32::EPSILON {
                        *ratio = next;
                        Resize::Changed
                    } else {
                        Resize::Unchanged
                    }
                }
                Resize::Pending { .. } => Resize::Pending { in_first },
                other => other,
            }
        }
    }
}

/// A pane's rectangle in the unit square.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

/// Lays out the tree in the unit square.
pub(crate) fn rects(node: &LayoutNode) -> Vec<(PaneId, Rect)> {
    fn walk(node: &LayoutNode, r: Rect, out: &mut Vec<(PaneId, Rect)>) {
        match node {
            LayoutNode::Leaf(p) => out.push((*p, r)),
            LayoutNode::Split {
                axis,
                ratio,
                first,
                second,
            } => {
                let (a, b) = match axis {
                    Axis::Horizontal => {
                        let w = r.w * ratio;
                        (
                            Rect { w, ..r },
                            Rect {
                                x: r.x + w,
                                w: r.w - w,
                                ..r
                            },
                        )
                    }
                    Axis::Vertical => {
                        let h = r.h * ratio;
                        (
                            Rect { h, ..r },
                            Rect {
                                y: r.y + h,
                                h: r.h - h,
                                ..r
                            },
                        )
                    }
                };
                walk(first, a, out);
                walk(second, b, out);
            }
        }
    }
    let mut out = Vec::new();
    walk(
        node,
        Rect {
            x: 0.0,
            y: 0.0,
            w: 1.0,
            h: 1.0,
        },
        &mut out,
    );
    out
}

/// The nearest pane in `direction` from `from`: it must start where `from` ends on that axis
/// and overlap it on the other one. Ties go to the larger overlap, then the earlier pane.
fn neighbor(root: &LayoutNode, from: PaneId, direction: Direction) -> Option<PaneId> {
    const EPS: f32 = 1e-4;
    let all = rects(root);
    let (_, f) = *all.iter().find(|(p, _)| *p == from)?;
    let overlap = |a0: f32, a1: f32, b0: f32, b1: f32| (a1.min(b1) - a0.max(b0)).max(0.0);
    all.iter()
        .filter(|(p, _)| *p != from)
        .filter_map(|&(p, r)| {
            let (gap, ov) = match direction {
                Direction::Right => (r.x - (f.x + f.w), overlap(f.y, f.y + f.h, r.y, r.y + r.h)),
                Direction::Left => (f.x - (r.x + r.w), overlap(f.y, f.y + f.h, r.y, r.y + r.h)),
                Direction::Down => (r.y - (f.y + f.h), overlap(f.x, f.x + f.w, r.x, r.x + r.w)),
                Direction::Up => (f.y - (r.y + r.h), overlap(f.x, f.x + f.w, r.x, r.x + r.w)),
            };
            (gap > -EPS && ov > EPS).then_some((p, gap, ov))
        })
        .min_by(|a, b| {
            a.1.partial_cmp(&b.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal))
        })
        .map(|(p, _, _)| p)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session_with(layout: &mut Layout) -> (SessionId, TabId, PaneId) {
        let p = layout.alloc_pane();
        let (s, t) = layout.create_session("main".into(), p).unwrap();
        (s, t, p)
    }

    #[test]
    fn split_close_and_focus() {
        let mut l = Layout::default();
        let (s, t, p1) = session_with(&mut l);
        let p2 = l.alloc_pane();
        l.split(p1, Axis::Horizontal, p2).unwrap();
        let p3 = l.alloc_pane();
        l.split(p2, Axis::Vertical, p3).unwrap();
        // p1 | (p2 / p3)
        assert_eq!(l.focused_pane(s), Some(p3));
        l.focus_direction(t, Direction::Up).unwrap();
        assert_eq!(l.focused_pane(s), Some(p2));
        l.focus_direction(t, Direction::Left).unwrap();
        assert_eq!(l.focused_pane(s), Some(p1));
        l.focus_direction(t, Direction::Left).unwrap();
        assert_eq!(l.focused_pane(s), Some(p1), "edge is a no-op");
        l.focus_direction(t, Direction::Right).unwrap();
        assert!(matches!(l.focused_pane(s), Some(p) if p == p2 || p == p3));

        let removed = l.close_pane(p2).unwrap();
        assert_eq!(removed.panes, vec![p2]);
        let snap = l.snapshot(s).unwrap();
        assert_eq!(
            snap.tabs[0].root,
            LayoutNode::Split {
                axis: Axis::Horizontal,
                ratio: 0.5,
                first: Box::new(LayoutNode::Leaf(p1)),
                second: Box::new(LayoutNode::Leaf(p3)),
            }
        );
        l.close_pane(p1).unwrap();
        assert_eq!(l.snapshot(s).unwrap().tabs[0].root, LayoutNode::Leaf(p3));
        let removed = l.close_pane(p3).unwrap();
        assert_eq!(removed.session, Some(s));
        assert!(l.sessions().is_empty());
    }

    #[test]
    fn resize_moves_nearest_divider_on_axis() {
        let mut l = Layout::default();
        let (s, _, p1) = session_with(&mut l);
        let p2 = l.alloc_pane();
        l.split(p1, Axis::Horizontal, p2).unwrap();
        let p3 = l.alloc_pane();
        l.split(p2, Axis::Vertical, p3).unwrap();
        let rev = l.session(s).unwrap().revision;
        l.resize(p3, Axis::Horizontal, 0.1).unwrap();
        let LayoutNode::Split { ratio, .. } = l.snapshot(s).unwrap().tabs[0].root else {
            panic!()
        };
        assert!(
            (ratio - 0.4).abs() < 1e-6,
            "p3 is second: its growth shrinks the first"
        );
        l.resize(p1, Axis::Horizontal, 5.0).unwrap();
        let LayoutNode::Split { ratio, .. } = l.snapshot(s).unwrap().tabs[0].root else {
            panic!()
        };
        assert!((ratio - (1.0 - MIN_RATIO)).abs() < 1e-6);
        assert!(l.session(s).unwrap().revision > rev);
        assert_eq!(
            l.resize(p1, Axis::Horizontal, f32::NAN),
            Err(OpError::Invalid)
        );
    }

    #[test]
    fn tabs_and_sessions() {
        let mut l = Layout::default();
        let (s, t1, _) = session_with(&mut l);
        let p = l.alloc_pane();
        let t2 = l.new_tab(s, "two".into(), p).unwrap();
        assert_eq!(l.session(s).unwrap().active_tab, Some(t2));
        l.move_tab(t2, 0).unwrap();
        assert_eq!(l.session(s).unwrap().tabs[0].tab_id, t2);
        let removed = l.close_tab(t2).unwrap();
        assert_eq!(removed.panes, vec![p]);
        assert_eq!(l.session(s).unwrap().active_tab, Some(t1));
        assert_eq!(
            l.create_session("main".into(), PaneId(99)),
            Err(OpError::NameTaken)
        );
        assert_eq!(l.unique_name("main"), "main-2");
        let rev = l.session(s).unwrap().revision;
        l.rename_tab(t1, String::new()).unwrap();
        assert_eq!(
            l.session(s).unwrap().revision,
            rev,
            "no-op keeps the revision"
        );
    }

    #[test]
    fn zoom_toggles_and_unzooms_on_focus_elsewhere() {
        let mut l = Layout::default();
        let (s, _, p1) = session_with(&mut l);
        let p2 = l.alloc_pane();
        l.split(p1, Axis::Vertical, p2).unwrap();
        l.toggle_zoom(p1).unwrap();
        assert_eq!(l.visible_panes(s), vec![p1]);
        l.focus(p2).unwrap();
        assert_eq!(l.visible_panes(s), vec![p2, p1]);
        l.toggle_zoom(p2).unwrap();
        l.toggle_zoom(p2).unwrap();
        assert_eq!(l.snapshot(s).unwrap().tabs[0].zoomed, None);
    }
}
