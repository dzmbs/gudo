//! Sessions, tabs and split trees: pure state, no I/O.
//!
//! Every mutation either fails with an [`OpError`] and leaves the state unchanged, or applies
//! completely and bumps the affected session's revision (only when something changed).
//! Creating panes is two-phase: the caller reserves an id with [`Layout::alloc_pane`], spawns
//! the process, then inserts the id. Removing panes returns their ids so the caller can kill
//! them.

use proto::{
    Axis, CloseWhen, Direction, DockTarget, FloatFrame, FloatId, FloatWindow, LayoutNode, OpError,
    PaneId, Project, SessionFloats, SessionId, SessionLayout, SessionProjects, SessionSummary,
    TabId, TabLayout, TabProject,
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
    /// Definitions of the projects `tab_projects` uses.
    #[serde(default)]
    pub projects: Vec<Project>,
    /// Which tabs belong to which project.
    #[serde(default)]
    pub tab_projects: Vec<TabProject>,
    /// Floating windows over the tabs, back to front.
    #[serde(default)]
    pub floats: Vec<FloatWindow>,
    /// The last floating window id handed out.
    #[serde(default)]
    pub next_float: u64,
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

    /// Takes `tab` out of its project, dropping the definition once no tab uses it. Only
    /// the project left is dropped: others may just have been defined for tabs to join next.
    fn leave_project(&mut self, tab: TabId) {
        let Some(i) = self.tab_projects.iter().position(|m| m.tab_id == tab) else {
            return;
        };
        let left = self.tab_projects.remove(i).project;
        if !self.tab_projects.iter().any(|m| m.project == left) {
            self.projects.retain(|p| p.id != left);
        }
    }

    fn to_floats(&self) -> SessionFloats {
        SessionFloats {
            session_id: self.id,
            revision: self.revision,
            floats: self.floats.clone(),
        }
    }

    /// The index of the window holding `pane`.
    fn window_of(&self, pane: PaneId) -> Option<usize> {
        self.floats.iter().position(|w| w.panes.contains(&pane))
    }

    fn is_floating(&self, pane: PaneId) -> bool {
        self.window_of(pane).is_some()
    }

    /// The tab's leaves that are not in a floating window.
    fn tiled<'a>(&'a self, tab: &'a TabLayout) -> impl Iterator<Item = PaneId> + 'a {
        leaves(&tab.root).filter(|&p| !self.is_floating(p))
    }

    fn windows_in(&self, tab: &TabLayout) -> usize {
        self.floats
            .iter()
            .filter(|w| has_leaf(&tab.root, w.panes[0]))
            .count()
    }

    fn top_z(&self) -> u32 {
        self.floats.last().map_or(0, |w| w.z)
    }

    /// Brings window `w` to the front; whether it moved.
    fn raise(&mut self, w: usize) -> bool {
        if w + 1 == self.floats.len() {
            return false;
        }
        let mut window = self.floats.remove(w);
        window.z = self.top_z() + 1;
        self.floats.push(window);
        true
    }

    /// Opens a window in front holding `panes`.
    fn open_window(&mut self, panes: Vec<PaneId>, frame: FloatFrame, close: CloseWhen) {
        self.next_float += 1;
        let z = self.top_z() + 1;
        self.floats.push(FloatWindow {
            id: FloatId(self.next_float),
            panes,
            frame,
            z,
            minimized: false,
            pinned: false,
            close,
        });
    }

    /// Panes just put beside `target` join its window, if it is in one.
    fn adopt(&mut self, target: PaneId, panes: impl IntoIterator<Item = PaneId>) {
        if let Some(w) = self.window_of(target) {
            self.floats[w].panes.extend(panes);
        }
    }

    /// Takes `pane` out of the window holding it.
    fn release(&mut self, pane: PaneId) {
        for w in &mut self.floats {
            w.panes.retain(|&p| p != pane);
        }
    }

    /// Restores the windows' invariants after any change to the trees: a window's panes are
    /// one subtree of one tab, in tree order; empty windows go; and a tab left with no tiled
    /// pane docks its frontmost window.
    fn tidy_floats(&mut self) {
        let tabs = &self.tabs;
        for w in &mut self.floats {
            let Some(tab) = w
                .panes
                .iter()
                .find_map(|&p| tabs.iter().find(|t| has_leaf(&t.root, p)))
            else {
                w.panes.clear();
                continue;
            };
            let order: Vec<PaneId> = leaves(&tab.root).collect();
            w.panes.retain(|p| order.contains(p));
            w.panes
                .sort_by_key(|p| order.iter().position(|o| o == p).unwrap_or(usize::MAX));
            if let Some(&first) = w.panes.first() {
                w.panes = contiguous(&tab.root, first, &w.panes);
            }
        }
        self.floats.retain(|w| !w.panes.is_empty());
        for t in 0..self.tabs.len() {
            while self.tiled(&self.tabs[t]).next().is_none() {
                let tab = &self.tabs[t];
                let Some(front) = self
                    .floats
                    .iter()
                    .rposition(|w| has_leaf(&tab.root, w.panes[0]))
                else {
                    break;
                };
                self.floats.remove(front);
            }
        }
    }

    /// A spot for a new window in `tab`: the default frame, stepped down and right for each
    /// window already there so none hides another exactly.
    fn free_frame(&self, tab: &TabLayout) -> FloatFrame {
        let step = 0.04 * (self.windows_in(tab) % 5) as f32;
        FloatFrame {
            x: FloatFrame::DEFAULT.x + step,
            y: FloatFrame::DEFAULT.y + step,
            ..FloatFrame::DEFAULT
        }
    }

    fn to_projects(&self) -> SessionProjects {
        SessionProjects {
            session_id: self.id,
            revision: self.revision,
            projects: self.projects.clone(),
            tabs: self.tab_projects.clone(),
        }
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

    pub fn tab_of_pane(&self, pane: PaneId) -> Option<TabId> {
        self.sessions
            .iter()
            .flat_map(|s| &s.tabs)
            .find_map(|t| leaves(&t.root).any(|p| p == pane).then_some(t.tab_id))
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
            projects: Vec::new(),
            tab_projects: Vec::new(),
            floats: Vec::new(),
            next_float: 0,
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
        s.leave_project(tab.tab_id);
        s.tidy_floats();
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
        s.adopt(pane, [new]);
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
        detach_leaf(tab, pane);
        let s = &mut self.sessions[si];
        s.tidy_floats();
        s.revision += 1;
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
        // A window focused comes to the front, and back from the tray.
        if let Some(w) = s.window_of(pane) {
            if s.floats[w].minimized {
                s.floats[w].minimized = false;
                changed = true;
            }
            changed |= s.raise(w);
        }
        if changed {
            s.revision += 1;
        }
        Ok(())
    }

    pub fn focus_direction(&mut self, tab: TabId, direction: Direction) -> OpResult<()> {
        let (si, ti) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let s = &self.sessions[si];
        let t = &s.tabs[ti];
        // Focus moves within the focused pane's own layer: the tiled panes or its window.
        let layer = match s.window_of(t.focused) {
            Some(w) => subtree(&t.root, &s.floats[w].panes).cloned(),
            None => tiled_tree(&t.root, |p| s.is_floating(p)),
        };
        let all = layer.as_ref().map(rects).unwrap_or_default();
        match neighbor(&all, t.focused, direction) {
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

impl Layout {
    /// Moves `pane` into a new tab right after its own and selects it. A tab's only pane
    /// stays (`Invalid`): it already is a tab of its own.
    pub fn break_pane(&mut self, pane: PaneId) -> OpResult<(SessionId, TabId)> {
        let (si, ti) = self.locate(pane).ok_or(OpError::NotFound)?;
        if self.sessions[si].tabs[ti].root == LayoutNode::Leaf(pane) {
            return Err(OpError::Invalid);
        }
        detach_leaf(&mut self.sessions[si].tabs[ti], pane);
        let tab = self.new_tab_layout(String::new(), pane);
        let tab_id = tab.tab_id;
        let s = &mut self.sessions[si];
        s.release(pane);
        s.tabs.insert(ti + 1, tab);
        s.tidy_floats();
        s.active_tab = Some(tab_id);
        s.revision += 1;
        Ok((s.id, tab_id))
    }

    /// Moves `pane` beside `target` (same session) on `side`, focused; its tab closes when it
    /// was the tab's only pane.
    pub fn move_pane(
        &mut self,
        pane: PaneId,
        target: PaneId,
        side: Direction,
    ) -> OpResult<SessionId> {
        let (si, ti) = self.locate(pane).ok_or(OpError::NotFound)?;
        let (target_si, _) = self.locate(target).ok_or(OpError::NotFound)?;
        if pane == target || si != target_si {
            return Err(OpError::Invalid);
        }
        self.sessions[si].release(pane);
        if self.sessions[si].tabs[ti].root == LayoutNode::Leaf(pane) {
            self.take_tab(si, ti);
        } else {
            detach_leaf(&mut self.sessions[si].tabs[ti], pane);
        }
        self.insert_beside(si, target, LayoutNode::Leaf(pane), side, pane);
        self.sessions[si].tidy_floats();
        Ok(self.sessions[si].id)
    }

    /// Moves every pane of `tab` beside `target` (in another tab of the same session) on
    /// `side`, keeping their arrangement and focus; `tab` closes.
    pub fn merge_tab(
        &mut self,
        tab: TabId,
        target: PaneId,
        side: Direction,
    ) -> OpResult<SessionId> {
        let (si, ti) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let (target_si, target_ti) = self.locate(target).ok_or(OpError::NotFound)?;
        if si != target_si || ti == target_ti {
            return Err(OpError::Invalid);
        }
        let merged = self.take_tab(si, ti);
        // Its windows dock as they merge: one window never sits inside another.
        self.sessions[si]
            .floats
            .retain(|w| !has_leaf(&merged.root, w.panes[0]));
        self.insert_beside(si, target, merged.root, side, merged.focused);
        self.sessions[si].tidy_floats();
        Ok(self.sessions[si].id)
    }

    /// Removes a tab whose panes live on elsewhere in the session (so it is not the last).
    fn take_tab(&mut self, si: usize, ti: usize) -> TabLayout {
        let s = &mut self.sessions[si];
        let tab = s.tabs.remove(ti);
        if s.active_tab == Some(tab.tab_id) {
            s.active_tab = s
                .tabs
                .get(ti.min(s.tabs.len().saturating_sub(1)))
                .map(|t| t.tab_id);
        }
        s.leave_project(tab.tab_id);
        tab
    }

    /// Puts `node` beside the leaf `target` on `side`, focuses `focus` and selects the tab.
    fn insert_beside(
        &mut self,
        si: usize,
        target: PaneId,
        node: LayoutNode,
        side: Direction,
        focus: PaneId,
    ) {
        let moved: Vec<PaneId> = leaves(&node).collect();
        let s = &mut self.sessions[si];
        s.adopt(target, moved);
        let Some(tab) = s
            .tabs
            .iter_mut()
            .find(|t| leaves(&t.root).any(|p| p == target))
        else {
            return;
        };
        let (axis, before) = match side {
            Direction::Left => (Axis::Horizontal, true),
            Direction::Right => (Axis::Horizontal, false),
            Direction::Up => (Axis::Vertical, true),
            Direction::Down => (Axis::Vertical, false),
        };
        replace_leaf(&mut tab.root, target, |leaf| {
            let (first, second) = if before { (node, leaf) } else { (leaf, node) };
            LayoutNode::Split {
                axis,
                ratio: 0.5,
                first: Box::new(first),
                second: Box::new(second),
            }
        });
        tab.focused = focus;
        tab.zoomed = None;
        s.active_tab = Some(tab.tab_id);
        s.revision += 1;
    }
}

impl Layout {
    /// Puts `tab` in `project` at `rank`, or ungroups it with `None`. The project must be
    /// defined in the tab's session.
    pub fn set_tab_project(
        &mut self,
        tab: TabId,
        project: Option<String>,
        rank: i64,
    ) -> OpResult<SessionId> {
        let (si, _) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let s = &mut self.sessions[si];
        let new = match project {
            Some(project) if s.projects.iter().any(|p| p.id == project) => Some(TabProject {
                tab_id: tab,
                project,
                rank,
            }),
            Some(_) => return Err(OpError::Invalid),
            None => None,
        };
        if s.tab_projects.iter().find(|m| m.tab_id == tab) == new.as_ref() {
            return Ok(s.id);
        }
        match new {
            // Moving within the same project keeps its definition.
            Some(m) => match s.tab_projects.iter_mut().find(|o| o.tab_id == tab) {
                Some(old) if old.project == m.project => *old = m,
                _ => {
                    s.leave_project(tab);
                    s.tab_projects.push(m);
                }
            },
            None => s.leave_project(tab),
        }
        s.revision += 1;
        Ok(s.id)
    }

    /// Defines or updates `project` in `session`. An older `updated` than the stored one, or
    /// an identical definition, changes nothing.
    pub fn put_project(&mut self, session: SessionId, project: Project) -> OpResult<()> {
        if !project.is_valid() {
            return Err(OpError::Invalid);
        }
        let si = self.session_index(session)?;
        let s = &mut self.sessions[si];
        let full = s.projects.len() >= proto::MAX_PROJECTS_PER_SESSION;
        match s.projects.iter_mut().find(|p| p.id == project.id) {
            Some(stored) if stored.updated > project.updated || *stored == project => {
                return Ok(());
            }
            Some(stored) => *stored = project,
            None if full => return Err(OpError::Invalid),
            None => s.projects.push(project),
        }
        s.revision += 1;
        Ok(())
    }

    /// Ungroups every tab of `project` in `session` and drops its definition.
    pub fn remove_project(&mut self, session: SessionId, project: &str) -> OpResult<()> {
        let si = self.session_index(session)?;
        let s = &mut self.sessions[si];
        let before = (s.projects.len(), s.tab_projects.len());
        s.projects.retain(|p| p.id != project);
        s.tab_projects.retain(|m| m.project != project);
        if (s.projects.len(), s.tab_projects.len()) != before {
            s.revision += 1;
        }
        Ok(())
    }

    pub fn projects(&self, session: SessionId) -> Option<SessionProjects> {
        self.session(session).map(Session::to_projects)
    }
}

impl Layout {
    /// Opens `new` in a window of its own over `anchor`'s tab, at `frame` or a free spot. In
    /// the tree it goes right of the whole tab. Focused only when asked.
    pub fn new_float(
        &mut self,
        anchor: PaneId,
        new: PaneId,
        frame: Option<FloatFrame>,
        focus: bool,
        close: CloseWhen,
    ) -> OpResult<SessionId> {
        let frame = clamp_frame(frame)?;
        let (si, ti) = self.locate(anchor).ok_or(OpError::NotFound)?;
        let s = &mut self.sessions[si];
        if s.windows_in(&s.tabs[ti]) >= proto::MAX_FLOATS_PER_TAB {
            return Err(OpError::Invalid);
        }
        let frame = frame.unwrap_or_else(|| s.free_frame(&s.tabs[ti]));
        let tab = &mut s.tabs[ti];
        append_right(&mut tab.root, new);
        if focus {
            tab.focused = new;
            tab.zoomed = None;
            s.active_tab = Some(tab.tab_id);
        }
        s.open_window(vec![new], frame, close);
        s.revision += 1;
        Ok(s.id)
    }

    /// Floats a tiled pane in a window of its own (its leaf stays where it docks back to),
    /// tears a pane out of a window it shares, or moves a window that is just this pane. A
    /// tab's last tiled pane stays (`Invalid`).
    pub fn float_pane(&mut self, pane: PaneId, frame: Option<FloatFrame>) -> OpResult<SessionId> {
        let frame = clamp_frame(frame)?;
        let (si, ti) = self.locate(pane).ok_or(OpError::NotFound)?;
        let s = &mut self.sessions[si];
        match s.window_of(pane) {
            Some(w) if s.floats[w].panes.len() == 1 => {
                let window = &mut s.floats[w];
                let mut changed = frame.is_some_and(|f| f != window.frame);
                window.frame = frame.unwrap_or(window.frame);
                changed |= s.raise(w);
                if changed {
                    s.revision += 1;
                }
                return Ok(s.id);
            }
            Some(w) => {
                if s.windows_in(&s.tabs[ti]) >= proto::MAX_FLOATS_PER_TAB {
                    return Err(OpError::Invalid);
                }
                let from = s.floats[w].frame;
                let frame = frame.unwrap_or(FloatFrame {
                    x: from.x + 0.04,
                    y: from.y + 0.04,
                    ..from
                });
                let frame = frame.clamped().unwrap_or(FloatFrame::DEFAULT);
                s.release(pane);
                let tab = &mut s.tabs[ti];
                detach_leaf(tab, pane);
                append_right(&mut tab.root, pane);
                tab.focused = pane;
                s.open_window(vec![pane], frame, CloseWhen::Never);
            }
            None => {
                if s.tiled(&s.tabs[ti]).count() < 2
                    || s.windows_in(&s.tabs[ti]) >= proto::MAX_FLOATS_PER_TAB
                {
                    return Err(OpError::Invalid);
                }
                let frame = frame.unwrap_or_else(|| s.free_frame(&s.tabs[ti]));
                let tab = &mut s.tabs[ti];
                if tab.zoomed == Some(pane) {
                    tab.zoomed = None;
                }
                s.open_window(vec![pane], frame, CloseWhen::Never);
            }
        }
        s.tidy_floats();
        s.revision += 1;
        Ok(s.id)
    }

    /// Changes the window holding `pane`; `None` keeps each value. Restoring it from the tray
    /// raises it; minimizing the window with the focus hands the focus to the tiled panes.
    pub fn set_float(
        &mut self,
        pane: PaneId,
        frame: Option<FloatFrame>,
        minimized: Option<bool>,
        pinned: Option<bool>,
    ) -> OpResult<SessionId> {
        let frame = clamp_frame(frame)?;
        let (si, ti) = self.locate(pane).ok_or(OpError::NotFound)?;
        let s = &mut self.sessions[si];
        let w = s.window_of(pane).ok_or(OpError::Invalid)?;
        let window = &mut s.floats[w];
        let before = window.clone();
        window.frame = frame.unwrap_or(window.frame);
        window.minimized = minimized.unwrap_or(window.minimized);
        window.pinned = pinned.unwrap_or(window.pinned);
        let after = window.clone();
        let mut changed = after != before;
        if before.minimized && !after.minimized {
            changed |= s.raise(w);
        }
        let focused = s.tabs[ti].focused;
        if after.minimized && after.panes.contains(&focused) {
            let next = s
                .tiled(&s.tabs[ti])
                .next()
                .expect("a tab keeps a tiled pane");
            let tab = &mut s.tabs[ti];
            tab.focused = next;
            tab.zoomed = None;
            changed = true;
        }
        if changed {
            s.revision += 1;
        }
        Ok(s.id)
    }

    /// Docks the window holding `pane`, splits and all: where it is, or beside a tiled pane
    /// of the same session. Focuses `pane`.
    pub fn dock_pane(&mut self, pane: PaneId, beside: Option<DockTarget>) -> OpResult<SessionId> {
        let (si, ti) = self.locate(pane).ok_or(OpError::NotFound)?;
        let w = self.sessions[si].window_of(pane).ok_or(OpError::Invalid)?;
        let Some(DockTarget {
            pane_id: target,
            side,
        }) = beside
        else {
            self.sessions[si].floats.remove(w);
            self.focus(pane)?;
            self.sessions[si].revision += 1;
            return Ok(self.sessions[si].id);
        };
        let s = &self.sessions[si];
        if !s.session_has(target) || s.is_floating(target) {
            return Err(OpError::Invalid);
        }
        let s = &mut self.sessions[si];
        let window = s.floats.remove(w);
        let tab = &mut s.tabs[ti];
        let node = take_subtree(&mut tab.root, &window.panes).ok_or(OpError::Invalid)?;
        if window.panes.contains(&tab.focused) || tab.zoomed.is_some() {
            tab.focused = first_leaf(&tab.root);
            tab.zoomed = None;
        }
        self.insert_beside(si, target, node, side, pane);
        self.sessions[si].tidy_floats();
        Ok(self.sessions[si].id)
    }

    pub fn floats(&self, session: SessionId) -> Option<SessionFloats> {
        self.session(session).map(Session::to_floats)
    }

    /// The window holding `pane`, if it floats.
    pub fn window_of(&self, pane: PaneId) -> Option<FloatWindow> {
        let (si, _) = self.locate(pane)?;
        let s = &self.sessions[si];
        s.window_of(pane).map(|w| s.floats[w].clone())
    }
}

impl Session {
    fn session_has(&self, pane: PaneId) -> bool {
        self.panes().any(|p| p == pane)
    }
}

fn clamp_frame(frame: Option<FloatFrame>) -> OpResult<Option<FloatFrame>> {
    frame
        .map(|f| f.clamped().ok_or(OpError::Invalid))
        .transpose()
}

/// Puts `pane` right of everything in `root`.
fn append_right(root: &mut LayoutNode, pane: PaneId) {
    let old = std::mem::replace(root, LayoutNode::Leaf(pane));
    *root = LayoutNode::Split {
        axis: Axis::Horizontal,
        ratio: 0.5,
        first: Box::new(old),
        second: Box::new(LayoutNode::Leaf(pane)),
    };
}

fn has_leaf(node: &LayoutNode, pane: PaneId) -> bool {
    leaves(node).any(|p| p == pane)
}

/// Whether `node`'s leaves are exactly `panes`.
fn is_exactly(node: &LayoutNode, panes: &[PaneId]) -> bool {
    let all: Vec<PaneId> = leaves(node).collect();
    all.len() == panes.len() && all.iter().all(|p| panes.contains(p))
}

/// The subtree whose leaves are exactly `panes`.
pub(crate) fn subtree<'a>(node: &'a LayoutNode, panes: &[PaneId]) -> Option<&'a LayoutNode> {
    if is_exactly(node, panes) {
        return Some(node);
    }
    match node {
        LayoutNode::Leaf(_) => None,
        LayoutNode::Split { first, second, .. } => {
            subtree(first, panes).or_else(|| subtree(second, panes))
        }
    }
}

/// Takes out the subtree (never the root) whose leaves are exactly `panes`, collapsing its
/// parent into the sibling.
fn take_subtree(node: &mut LayoutNode, panes: &[PaneId]) -> Option<LayoutNode> {
    let LayoutNode::Split { first, second, .. } = node else {
        return None;
    };
    let in_first = is_exactly(first, panes);
    if in_first || is_exactly(second, panes) {
        let keep = if in_first {
            &mut **second
        } else {
            &mut **first
        };
        let keep = std::mem::replace(keep, LayoutNode::Leaf(PaneId(0)));
        let LayoutNode::Split { first, second, .. } = std::mem::replace(node, keep) else {
            unreachable!("matched a split above");
        };
        return Some(if in_first { *first } else { *second });
    }
    take_subtree(first, panes).or_else(|| take_subtree(second, panes))
}

/// The leaves of the largest subtree around `pane` whose leaves all lie in `within`.
fn contiguous(root: &LayoutNode, pane: PaneId, within: &[PaneId]) -> Vec<PaneId> {
    fn walk(node: &LayoutNode, pane: PaneId, within: &[PaneId]) -> Option<Vec<PaneId>> {
        let all: Vec<PaneId> = leaves(node).collect();
        if !all.contains(&pane) {
            return None;
        }
        if all.iter().all(|p| within.contains(p)) {
            return Some(all);
        }
        match node {
            LayoutNode::Leaf(_) => None,
            LayoutNode::Split { first, second, .. } => {
                walk(first, pane, within).or_else(|| walk(second, pane, within))
            }
        }
    }
    walk(root, pane, within).unwrap_or_default()
}

/// The tree without the leaves `floating` names, or `None` if every leaf floats.
pub(crate) fn tiled_tree(
    node: &LayoutNode,
    floating: impl Fn(PaneId) -> bool + Copy,
) -> Option<LayoutNode> {
    match node {
        LayoutNode::Leaf(p) => (!floating(*p)).then(|| node.clone()),
        LayoutNode::Split {
            axis,
            ratio,
            first,
            second,
        } => match (tiled_tree(first, floating), tiled_tree(second, floating)) {
            (Some(a), Some(b)) => Some(LayoutNode::Split {
                axis: *axis,
                ratio: *ratio,
                first: Box::new(a),
                second: Box::new(b),
            }),
            (a, b) => a.or(b),
        },
    }
}

/// Takes leaf `pane` (not the root) out of `tab`, moving focus and zoom off it.
fn detach_leaf(tab: &mut TabLayout, pane: PaneId) {
    let sibling = remove_leaf(&mut tab.root, pane).expect("pane is in this tab");
    if tab.focused == pane {
        tab.focused = sibling;
    }
    if tab.zoomed == Some(pane) {
        tab.zoomed = None;
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
fn neighbor(all: &[(PaneId, Rect)], from: PaneId, direction: Direction) -> Option<PaneId> {
    const EPS: f32 = 1e-4;
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

    #[test]
    fn break_move_and_merge_keep_panes() {
        let mut l = Layout::default();
        let (s, t1, p1) = session_with(&mut l);
        let p2 = l.alloc_pane();
        l.split(p1, Axis::Horizontal, p2).unwrap();
        assert_eq!(l.break_pane(p1).ok().map(|(id, _)| id), Some(s));
        assert_eq!(l.break_pane(p2), Err(OpError::Invalid), "a tab's only pane");
        let snap = l.snapshot(s).unwrap();
        let t2 = snap.tabs[1].tab_id;
        assert_eq!(snap.tabs[0].root, LayoutNode::Leaf(p2));
        assert_eq!(snap.tabs[1].root, LayoutNode::Leaf(p1));
        assert_eq!(snap.active_tab, Some(t2));

        // Back beside p2, on its left: the emptied tab closes.
        l.move_pane(p1, p2, Direction::Left).unwrap();
        let snap = l.snapshot(s).unwrap();
        assert_eq!(snap.tabs.len(), 1);
        assert_eq!(
            snap.tabs[0].root,
            LayoutNode::Split {
                axis: Axis::Horizontal,
                ratio: 0.5,
                first: Box::new(LayoutNode::Leaf(p1)),
                second: Box::new(LayoutNode::Leaf(p2)),
            }
        );
        assert_eq!(snap.tabs[0].focused, p1);
        assert_eq!(l.move_pane(p1, p1, Direction::Up), Err(OpError::Invalid));

        // A two-pane tab merged below p1 keeps its own split and focus.
        let p3 = l.alloc_pane();
        let t3 = l.new_tab(s, String::new(), p3).unwrap();
        let p4 = l.alloc_pane();
        l.split(p3, Axis::Vertical, p4).unwrap();
        l.merge_tab(t3, p1, Direction::Down).unwrap();
        let snap = l.snapshot(s).unwrap();
        assert_eq!(snap.tabs.len(), 1);
        assert_eq!(snap.active_tab, Some(t1));
        assert_eq!(snap.tabs[0].focused, p4);
        assert_eq!(
            leaves(&snap.tabs[0].root).collect::<Vec<_>>(),
            vec![p1, p3, p4, p2]
        );
        assert_eq!(l.merge_tab(t1, p1, Direction::Down), Err(OpError::Invalid));
        assert_eq!(l.all_panes().len(), 4, "no pane was dropped");
    }

    fn project(id: &str, updated: u64) -> Project {
        Project {
            id: id.into(),
            name: id.to_uppercase(),
            color: 1,
            order: 0,
            updated: proto::UnixMillis(updated),
        }
    }

    fn member(l: &Layout, s: SessionId, tab: TabId) -> Option<(String, i64)> {
        let p = l.projects(s).unwrap();
        let m = p.tabs.iter().find(|m| m.tab_id == tab)?;
        Some((m.project.clone(), m.rank))
    }

    fn defined(l: &Layout, s: SessionId) -> Vec<String> {
        l.projects(s)
            .unwrap()
            .projects
            .into_iter()
            .map(|p| p.id)
            .collect()
    }

    fn revision(l: &Layout, s: SessionId) -> u64 {
        l.session(s).unwrap().revision
    }

    #[test]
    fn tabs_join_move_within_and_leave_projects() {
        let mut l = Layout::default();
        let (s, t1, _) = session_with(&mut l);
        assert_eq!(
            l.set_tab_project(t1, Some("web".into()), 0),
            Err(OpError::Invalid),
            "an undefined project"
        );
        l.put_project(s, project("web", 1)).unwrap();
        l.put_project(s, project("api", 1)).unwrap();
        let r = revision(&l, s);
        l.set_tab_project(t1, Some("web".into()), 3).unwrap();
        assert_eq!(member(&l, s, t1), Some(("web".into(), 3)));
        assert_eq!(revision(&l, s), r + 1);
        assert_eq!(defined(&l, s), ["web", "api"], "api awaits its tabs");

        l.set_tab_project(t1, Some("web".into()), 3).unwrap();
        assert_eq!(revision(&l, s), r + 1, "no change, no bump");
        l.set_tab_project(t1, Some("web".into()), 7).unwrap();
        assert_eq!(member(&l, s, t1), Some(("web".into(), 7)));
        assert_eq!(defined(&l, s), ["web", "api"]);

        // Moving to another project drops the one left empty.
        l.set_tab_project(t1, Some("api".into()), 0).unwrap();
        assert_eq!(defined(&l, s), ["api"]);
        l.set_tab_project(t1, None, 0).unwrap();
        assert_eq!(member(&l, s, t1), None);
        assert!(defined(&l, s).is_empty());
        let r = revision(&l, s);
        l.set_tab_project(t1, None, 0).unwrap();
        assert_eq!(revision(&l, s), r);
        assert_eq!(
            l.set_tab_project(TabId(99), None, 0),
            Err(OpError::NotFound)
        );
    }

    #[test]
    fn newer_project_definitions_win() {
        let mut l = Layout::default();
        let (s, _, _) = session_with(&mut l);
        l.put_project(s, project("web", 5)).unwrap();
        let r = revision(&l, s);
        let mut older = project("web", 4);
        older.name = "Old".into();
        l.put_project(s, older).unwrap();
        l.put_project(s, project("web", 5)).unwrap();
        assert_eq!(
            revision(&l, s),
            r,
            "an older or identical definition is ignored"
        );
        let mut newer = project("web", 6);
        newer.color = 7;
        l.put_project(s, newer.clone()).unwrap();
        assert_eq!(l.projects(s).unwrap().projects, [newer]);
        assert_eq!(revision(&l, s), r + 1);
    }

    #[test]
    fn invalid_projects_are_refused() {
        let mut l = Layout::default();
        let (s, _, _) = session_with(&mut l);
        let long = "x".repeat(proto::MAX_PROJECT_ID_LEN + 1);
        for bad in [
            project("", 1),
            project(&long, 1),
            Project {
                color: proto::MAX_PROJECT_COLOR + 1,
                ..project("web", 1)
            },
            Project {
                name: "n".repeat(proto::MAX_PROJECT_NAME_LEN + 1),
                ..project("web", 1)
            },
        ] {
            assert_eq!(l.put_project(s, bad), Err(OpError::Invalid));
        }
        for i in 0..proto::MAX_PROJECTS_PER_SESSION {
            l.put_project(s, project(&i.to_string(), 1)).unwrap();
        }
        assert_eq!(
            l.put_project(s, project("one-more", 1)),
            Err(OpError::Invalid)
        );
        assert_eq!(
            l.put_project(SessionId(99), project("web", 1)),
            Err(OpError::NotFound)
        );
    }

    #[test]
    fn removing_a_project_ungroups_its_tabs() {
        let mut l = Layout::default();
        let (s, t1, _) = session_with(&mut l);
        let p2 = l.alloc_pane();
        let t2 = l.new_tab(s, String::new(), p2).unwrap();
        l.put_project(s, project("web", 1)).unwrap();
        l.set_tab_project(t1, Some("web".into()), 0).unwrap();
        l.set_tab_project(t2, Some("web".into()), 1).unwrap();
        let r = revision(&l, s);
        l.remove_project(s, "web").unwrap();
        assert_eq!(l.projects(s).unwrap().tabs, []);
        assert!(defined(&l, s).is_empty());
        assert_eq!(revision(&l, s), r + 1);
        l.remove_project(s, "web").unwrap();
        assert_eq!(revision(&l, s), r + 1, "nothing left to remove");
    }

    #[test]
    fn projects_follow_tabs_that_close_merge_or_break() {
        let mut l = Layout::default();
        let (s, t1, p1) = session_with(&mut l);
        let p2 = l.alloc_pane();
        let t2 = l.new_tab(s, String::new(), p2).unwrap();
        let p3 = l.alloc_pane();
        let t3 = l.new_tab(s, String::new(), p3).unwrap();
        l.put_project(s, project("a", 1)).unwrap();
        l.put_project(s, project("b", 1)).unwrap();
        l.set_tab_project(t1, Some("a".into()), 0).unwrap();
        l.set_tab_project(t2, Some("a".into()), 1).unwrap();
        l.set_tab_project(t3, Some("b".into()), 0).unwrap();

        // Merging t3 away drops its membership and its now unused project.
        l.merge_tab(t3, p1, Direction::Right).unwrap();
        assert_eq!(member(&l, s, t3), None);
        assert_eq!(defined(&l, s), ["a"]);

        // A pane broken out of a grouped tab starts ungrouped.
        let (_, t4) = l.break_pane(p3).unwrap();
        assert_eq!(member(&l, s, t4), None);
        assert_eq!(member(&l, s, t1), Some(("a".into(), 0)));

        // Closing the last pane of t2 closes the tab; "a" lives on in t1.
        l.close_pane(p2).unwrap();
        assert_eq!(member(&l, s, t2), None);
        assert_eq!(defined(&l, s), ["a"]);
        l.close_tab(t1).unwrap();
        assert!(defined(&l, s).is_empty());
        assert_eq!(l.projects(s).unwrap().tabs, []);
    }

    /// Every window is one subtree of one tab, in tree order, and every tab keeps a tiled
    /// pane.
    fn check_floats(l: &Layout) {
        for s in &l.sessions {
            for w in &s.floats {
                let tab = s
                    .tabs
                    .iter()
                    .find(|t| has_leaf(&t.root, w.panes[0]))
                    .expect("in a tab");
                let node = subtree(&tab.root, &w.panes).expect("one subtree");
                assert_eq!(leaves(node).collect::<Vec<_>>(), w.panes, "tree order");
            }
            for t in &s.tabs {
                assert!(
                    s.tiled(t).next().is_some(),
                    "{:?} has no tiled pane",
                    t.tab_id
                );
            }
            let zs: Vec<u32> = s.floats.iter().map(|w| w.z).collect();
            assert!(zs.windows(2).all(|p| p[0] < p[1]), "back to front: {zs:?}");
        }
    }

    fn windows(l: &Layout, s: SessionId) -> Vec<Vec<PaneId>> {
        l.floats(s)
            .unwrap()
            .floats
            .into_iter()
            .map(|w| w.panes)
            .collect()
    }

    fn tiled_leaves(l: &Layout, s: SessionId) -> Vec<PaneId> {
        let session = l.session(s).unwrap();
        let tab = session
            .tabs
            .iter()
            .find(|t| Some(t.tab_id) == session.active_tab)
            .unwrap();
        session.tiled(tab).collect()
    }

    /// p1 | p2 | p3, left to right.
    fn three(l: &mut Layout) -> (SessionId, TabId, [PaneId; 3]) {
        let (s, t, p1) = session_with(l);
        let p2 = l.alloc_pane();
        l.split(p1, Axis::Horizontal, p2).unwrap();
        let p3 = l.alloc_pane();
        l.split(p2, Axis::Horizontal, p3).unwrap();
        (s, t, [p1, p2, p3])
    }

    #[test]
    fn a_pane_floats_and_docks_back_where_it_was() {
        let mut l = Layout::default();
        let (s, _, [p1, p2, p3]) = three(&mut l);
        let before = l.snapshot(s).unwrap().tabs[0].root.clone();
        l.float_pane(p2, None).unwrap();
        assert_eq!(windows(&l, s), [vec![p2]]);
        assert_eq!(tiled_leaves(&l, s), [p1, p3]);
        assert_eq!(
            l.snapshot(s).unwrap().tabs[0].root,
            before,
            "older clients see the same tree"
        );
        check_floats(&l);

        l.dock_pane(p2, None).unwrap();
        assert!(windows(&l, s).is_empty());
        assert_eq!(l.focused_pane(s), Some(p2));
        assert_eq!(l.snapshot(s).unwrap().tabs[0].root, before);

        l.float_pane(p1, None).unwrap();
        l.float_pane(p2, None).unwrap();
        assert_eq!(
            l.float_pane(p3, None),
            Err(OpError::Invalid),
            "a tab keeps a tiled pane"
        );
        check_floats(&l);
    }

    #[test]
    fn new_floats_open_right_of_the_tab_without_taking_focus() {
        let mut l = Layout::default();
        let (s, _, [p1, p2, p3]) = three(&mut l);
        l.focus(p1).unwrap();
        let a = l.alloc_pane();
        l.new_float(p3, a, None, false, CloseWhen::Done).unwrap();
        let b = l.alloc_pane();
        l.new_float(p1, b, None, false, CloseWhen::Never).unwrap();
        assert_eq!(l.focused_pane(s), Some(p1), "no focus stealing");
        let tab = &l.snapshot(s).unwrap().tabs[0];
        assert_eq!(leaves(&tab.root).collect::<Vec<_>>(), [p1, p2, p3, a, b]);
        let floats = l.floats(s).unwrap().floats;
        assert_eq!(floats[0].close, CloseWhen::Done);
        assert_ne!(
            floats[0].frame, floats[1].frame,
            "cascaded, never stacked exactly"
        );
        check_floats(&l);

        // Focusing the back window raises it and brings it out of the tray.
        l.set_float(a, None, Some(true), None).unwrap();
        l.focus(a).unwrap();
        assert_eq!(windows(&l, s), [vec![b], vec![a]]);
        assert!(!l.floats(s).unwrap().floats[1].minimized);
        let c = l.alloc_pane();
        l.new_float(p1, c, None, true, CloseWhen::Never).unwrap();
        assert_eq!(l.focused_pane(s), Some(c));
        check_floats(&l);
    }

    #[test]
    fn windows_hold_splits_and_panes_move_in_and_out() {
        let mut l = Layout::default();
        let (s, _, [p1, p2, p3]) = three(&mut l);
        let f = l.alloc_pane();
        l.new_float(p1, f, None, false, CloseWhen::Never).unwrap();
        // A split inside the window stays in it.
        let g = l.alloc_pane();
        l.split(f, Axis::Vertical, g).unwrap();
        assert_eq!(windows(&l, s), [vec![f, g]]);
        // A tiled pane dropped beside a window's pane joins the window...
        l.move_pane(p2, g, Direction::Right).unwrap();
        assert_eq!(windows(&l, s), [vec![f, g, p2]]);
        assert_eq!(tiled_leaves(&l, s), [p1, p3]);
        check_floats(&l);
        // ...and one dropped beside a tiled pane leaves it.
        l.move_pane(f, p1, Direction::Down).unwrap();
        assert_eq!(windows(&l, s), [vec![g, p2]]);
        assert_eq!(tiled_leaves(&l, s), [p1, f, p3]);
        check_floats(&l);
        // Floating a pane of a shared window tears it off into its own.
        l.float_pane(p2, None).unwrap();
        assert_eq!(windows(&l, s), [vec![g], vec![p2]]);
        let frames: Vec<FloatFrame> = l
            .floats(s)
            .unwrap()
            .floats
            .iter()
            .map(|w| w.frame)
            .collect();
        assert!(frames[1].x > frames[0].x, "offset from the window it left");
        check_floats(&l);
    }

    #[test]
    fn docking_beside_a_pane_keeps_the_window_splits() {
        let mut l = Layout::default();
        let (s, _, [p1, _, p3]) = three(&mut l);
        let f = l.alloc_pane();
        l.new_float(p1, f, None, false, CloseWhen::Never).unwrap();
        let g = l.alloc_pane();
        l.split(f, Axis::Vertical, g).unwrap();
        // Into another tab, below its pane.
        let q = l.alloc_pane();
        l.new_tab(s, String::new(), q).unwrap();
        l.dock_pane(
            g,
            Some(DockTarget {
                pane_id: q,
                side: Direction::Down,
            }),
        )
        .unwrap();
        let snap = l.snapshot(s).unwrap();
        assert!(windows(&l, s).is_empty());
        assert_eq!(snap.active_tab, Some(snap.tabs[1].tab_id));
        assert_eq!(
            snap.tabs[1].root,
            LayoutNode::Split {
                axis: Axis::Vertical,
                ratio: 0.5,
                first: Box::new(LayoutNode::Leaf(q)),
                second: Box::new(LayoutNode::Split {
                    axis: Axis::Vertical,
                    ratio: 0.5,
                    first: Box::new(LayoutNode::Leaf(f)),
                    second: Box::new(LayoutNode::Leaf(g)),
                }),
            }
        );
        assert_eq!(snap.tabs[1].focused, g);
        assert!(!leaves(&snap.tabs[0].root).any(|p| p == f || p == g));
        // Never beside a float, nor a pane that does not float.
        l.float_pane(p3, None).unwrap();
        assert_eq!(
            l.dock_pane(
                p3,
                Some(DockTarget {
                    pane_id: p3,
                    side: Direction::Left
                })
            ),
            Err(OpError::Invalid)
        );
        assert_eq!(l.dock_pane(p1, None), Err(OpError::Invalid));
        check_floats(&l);
    }

    #[test]
    fn the_last_tiled_pane_closing_docks_the_front_window() {
        let mut l = Layout::default();
        let (s, _, p1) = session_with(&mut l);
        let a = l.alloc_pane();
        l.new_float(p1, a, None, false, CloseWhen::Never).unwrap();
        let b = l.alloc_pane();
        l.new_float(p1, b, None, false, CloseWhen::Never).unwrap();
        l.close_pane(p1).unwrap();
        assert_eq!(windows(&l, s), [vec![a]], "b was in front");
        assert_eq!(tiled_leaves(&l, s), [b]);
        l.close_pane(a).unwrap();
        assert!(windows(&l, s).is_empty());
        check_floats(&l);
    }

    #[test]
    fn minimizing_hands_focus_to_the_tiled_panes_and_frames_stay_inside() {
        let mut l = Layout::default();
        let (s, _, [p1, p2, _]) = three(&mut l);
        l.float_pane(p2, None).unwrap();
        l.focus(p2).unwrap();
        let rev = revision(&l, s);
        l.set_float(p2, None, Some(true), Some(true)).unwrap();
        assert_eq!(l.focused_pane(s), Some(p1));
        assert!(revision(&l, s) > rev);
        let w = &l.floats(s).unwrap().floats[0];
        assert!(w.minimized && w.pinned);
        let rev = revision(&l, s);
        l.set_float(p2, None, Some(true), None).unwrap();
        assert_eq!(revision(&l, s), rev, "no change, no bump");

        let frame = FloatFrame {
            x: 0.95,
            y: -1.0,
            w: 0.5,
            h: 0.01,
        };
        l.set_float(p2, Some(frame), None, None).unwrap();
        let w = &l.floats(s).unwrap().floats[0];
        assert_eq!(
            w.frame,
            FloatFrame {
                x: 0.5,
                y: 0.0,
                w: 0.5,
                h: proto::MIN_FLOAT_SIDE
            }
        );
        let nan = FloatFrame {
            w: f32::NAN,
            ..frame
        };
        assert_eq!(
            l.set_float(p2, Some(nan), None, None),
            Err(OpError::Invalid)
        );
        assert_eq!(
            l.set_float(p1, None, Some(true), None),
            Err(OpError::Invalid)
        );
    }

    #[test]
    fn focus_moves_within_its_own_layer() {
        let mut l = Layout::default();
        let (s, t, [p1, p2, p3]) = three(&mut l);
        l.float_pane(p2, None).unwrap();
        l.focus(p1).unwrap();
        l.focus_direction(t, Direction::Right).unwrap();
        assert_eq!(l.focused_pane(s), Some(p3), "over the floated pane's slot");
        let g = l.alloc_pane();
        l.split(p2, Axis::Vertical, g).unwrap();
        l.focus_direction(t, Direction::Up).unwrap();
        assert_eq!(l.focused_pane(s), Some(p2));
        l.focus_direction(t, Direction::Left).unwrap();
        assert_eq!(l.focused_pane(s), Some(p2), "the window's edge");
    }

    #[test]
    fn merging_a_tab_docks_its_windows_and_breaking_out_leaves_one() {
        let mut l = Layout::default();
        let (s, _, [p1, p2, _]) = three(&mut l);
        let q = l.alloc_pane();
        let t2 = l.new_tab(s, String::new(), q).unwrap();
        let r = l.alloc_pane();
        l.new_float(q, r, None, false, CloseWhen::Never).unwrap();
        l.float_pane(p2, None).unwrap();
        l.merge_tab(t2, p1, Direction::Down).unwrap();
        assert_eq!(windows(&l, s), [vec![p2]]);
        let g = l.alloc_pane();
        l.split(p2, Axis::Vertical, g).unwrap();
        l.break_pane(g).unwrap();
        assert_eq!(windows(&l, s), [vec![p2]]);
        check_floats(&l);
    }

    #[test]
    fn floats_survive_a_save_and_load() {
        let mut l = Layout::default();
        let (_, _, [_, p2, _]) = three(&mut l);
        l.float_pane(p2, None).unwrap();
        let json = serde_json::to_string(&l).unwrap();
        let loaded: Layout = serde_json::from_str(&json).unwrap();
        assert_eq!(loaded, l);
    }

    #[test]
    fn layouts_saved_before_projects_still_load() {
        let mut l = Layout::default();
        session_with(&mut l);
        let mut json = serde_json::to_value(&l).unwrap();
        for s in json["sessions"].as_array_mut().unwrap() {
            let s = s.as_object_mut().unwrap();
            for key in ["projects", "tab_projects", "floats", "next_float"] {
                assert!(s.remove(key).is_some(), "{key}");
            }
        }
        let loaded: Layout = serde_json::from_value(json).unwrap();
        assert_eq!(loaded, l);
    }
}
