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
/// Most splits between a tab's root and any pane. Past a few levels a pane is too small to use,
/// and the saved layout must stay well inside `serde_json`'s nesting limit (128), or the next
/// start could not read it back.
pub(crate) const MAX_SPLIT_DEPTH: usize = 16;

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
        self.tabs.iter().flat_map(|tab| leaves(&tab.root))
    }

    /// Takes `tab` out of its project, dropping the definition once no tab uses it. Only
    /// the project left is dropped: others may just have been defined for tabs to join next.
    fn leave_project(&mut self, tab: TabId) {
        let Some(index) = self
            .tab_projects
            .iter()
            .position(|membership| membership.tab_id == tab)
        else {
            return;
        };
        let left = self.tab_projects.remove(index).project;
        if !self
            .tab_projects
            .iter()
            .any(|membership| membership.project == left)
        {
            self.projects.retain(|project| project.id != left);
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
        self.floats
            .iter()
            .position(|window| window.panes.contains(&pane))
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
            .filter(|window| has_leaf(&tab.root, window.panes[0]))
            .count()
    }

    fn top_z(&self) -> u32 {
        self.floats.last().map_or(0, |window| window.z)
    }

    /// Brings the window at `index` to the front; whether it moved.
    fn raise(&mut self, index: usize) -> bool {
        if index + 1 == self.floats.len() {
            return false;
        }
        let mut window = self.floats.remove(index);
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
        if let Some(index) = self.window_of(target) {
            self.floats[index].panes.extend(panes);
        }
    }

    /// Takes `pane` out of the window holding it.
    fn release(&mut self, pane: PaneId) {
        for window in &mut self.floats {
            window.panes.retain(|&held| held != pane);
        }
    }

    /// Restores the windows' invariants after any change to the trees: a window's panes are
    /// one subtree of one tab, in tree order; empty windows go; and a tab left with no tiled
    /// pane docks its frontmost window.
    fn tidy_floats(&mut self) {
        let tabs = &self.tabs;
        for window in &mut self.floats {
            let Some(tab) = window
                .panes
                .iter()
                .find_map(|&pane| tabs.iter().find(|tab| has_leaf(&tab.root, pane)))
            else {
                window.panes.clear();
                continue;
            };
            let order: Vec<PaneId> = leaves(&tab.root).collect();
            window.panes.retain(|pane| order.contains(pane));
            window.panes.sort_by_key(|pane| {
                order
                    .iter()
                    .position(|leaf| leaf == pane)
                    .unwrap_or(usize::MAX)
            });
            if let Some(&first) = window.panes.first() {
                window.panes = contiguous(&tab.root, first, &window.panes);
            }
        }
        self.floats.retain(|window| !window.panes.is_empty());
        for tab_index in 0..self.tabs.len() {
            while self.tiled(&self.tabs[tab_index]).next().is_none() {
                let tab = &self.tabs[tab_index];
                let Some(front) = self
                    .floats
                    .iter()
                    .rposition(|window| has_leaf(&tab.root, window.panes[0]))
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
    /// Set when the whole session was closed (`CloseSession`).
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
    pub fn alloc_pane(&mut self) -> PaneId {
        self.next_pane += 1;
        PaneId(self.next_pane)
    }

    pub fn session(&self, id: SessionId) -> Option<&Session> {
        self.sessions.iter().find(|session| session.id == id)
    }

    pub fn snapshot(&self, id: SessionId) -> Option<SessionLayout> {
        self.session(id).map(Session::to_wire)
    }

    pub fn most_recent(&self) -> Option<SessionId> {
        self.mru
            .first()
            .copied()
            .or_else(|| self.sessions.first().map(|session| session.id))
    }

    /// Marks `id` as most recently used.
    pub fn touch(&mut self, id: SessionId) {
        self.mru.retain(|&recent| recent != id);
        self.mru.insert(0, id);
    }

    pub fn summaries(&self, clients: impl Fn(SessionId) -> u32) -> Vec<SessionSummary> {
        self.sessions
            .iter()
            .map(|session| SessionSummary {
                session_id: session.id,
                name: session.name.clone(),
                tabs: session.tabs.len() as u32,
                panes: session.panes().count() as u32,
                clients: clients(session.id),
            })
            .collect()
    }

    pub fn all_panes(&self) -> Vec<PaneId> {
        self.sessions.iter().flat_map(Session::panes).collect()
    }

    pub fn session_of_pane(&self, pane: PaneId) -> Option<SessionId> {
        self.locate(pane)
            .map(|(session_index, _)| self.sessions[session_index].id)
    }

    pub fn tab_of_pane(&self, pane: PaneId) -> Option<TabId> {
        self.sessions
            .iter()
            .flat_map(|session| &session.tabs)
            .find_map(|tab| has_leaf(&tab.root, pane).then_some(tab.tab_id))
    }

    /// The project of the tab holding `pane`, if it is in one.
    pub fn project_of_pane(&self, pane: PaneId) -> Option<String> {
        let tab = self.tab_of_pane(pane)?;
        self.sessions
            .iter()
            .flat_map(|session| &session.tab_projects)
            .find(|membership| membership.tab_id == tab)
            .map(|membership| membership.project.clone())
    }

    pub fn session_of_tab(&self, tab: TabId) -> Option<SessionId> {
        self.locate_tab(tab)
            .map(|(session_index, _)| self.sessions[session_index].id)
    }

    #[cfg(test)]
    /// The focused pane of the session's active tab.
    pub fn focused_pane(&self, session: SessionId) -> Option<PaneId> {
        let session = self.session(session)?;
        let tab = session
            .tabs
            .iter()
            .find(|tab| Some(tab.tab_id) == session.active_tab)?;
        Some(tab.focused)
    }

    #[cfg(test)]
    /// The panes shown on screen for the session's active tab, focused first.
    pub fn visible_panes(&self, session: SessionId) -> Vec<PaneId> {
        let Some(session) = self.session(session) else {
            return Vec::new();
        };
        let Some(tab) = session
            .tabs
            .iter()
            .find(|tab| Some(tab.tab_id) == session.active_tab)
        else {
            return Vec::new();
        };
        if let Some(zoomed) = tab.zoomed {
            return vec![zoomed];
        }
        let mut panes: Vec<_> = leaves(&tab.root).collect();
        panes.sort_by_key(|&pane| pane != tab.focused);
        panes
    }

    fn locate(&self, pane: PaneId) -> Option<(usize, usize)> {
        self.sessions
            .iter()
            .enumerate()
            .find_map(|(session_index, session)| {
                session
                    .tabs
                    .iter()
                    .position(|tab| has_leaf(&tab.root, pane))
                    .map(|tab_index| (session_index, tab_index))
            })
    }

    fn locate_tab(&self, tab: TabId) -> Option<(usize, usize)> {
        self.sessions
            .iter()
            .enumerate()
            .find_map(|(session_index, session)| {
                session
                    .tabs
                    .iter()
                    .position(|candidate| candidate.tab_id == tab)
                    .map(|tab_index| (session_index, tab_index))
            })
    }

    fn session_index(&self, id: SessionId) -> OpResult<usize> {
        self.sessions
            .iter()
            .position(|session| session.id == id)
            .ok_or(OpError::NotFound)
    }

    fn name_taken(&self, name: &str, except: Option<SessionId>) -> bool {
        self.sessions
            .iter()
            .any(|session| session.name == name && Some(session.id) != except)
    }

    /// Returns a session name not yet in use, `base` or `base-N`.
    pub fn unique_name(&self, base: &str) -> String {
        let base = if base.is_empty() { "main" } else { base };
        if !self.name_taken(base, None) {
            return base.to_owned();
        }
        (2..)
            .map(|suffix| format!("{base}-{suffix}"))
            .find(|candidate| !self.name_taken(candidate, None))
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
        self.mru.retain(|&recent| recent != id);
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
        let session = &mut self.sessions[index];
        if session.name != name {
            session.name = name;
            session.revision += 1;
        }
        Ok(())
    }

    pub fn new_tab(&mut self, session: SessionId, name: String, pane: PaneId) -> OpResult<TabId> {
        let index = self.session_index(session)?;
        let tab = self.new_tab_layout(name, pane);
        let tab_id = tab.tab_id;
        let session = &mut self.sessions[index];
        session.tabs.push(tab);
        session.active_tab = Some(tab_id);
        session.revision += 1;
        Ok(tab_id)
    }

    pub fn close_tab(&mut self, tab: TabId) -> OpResult<Removed> {
        let (session_index, tab_index) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        Ok(self.remove_tab(session_index, tab_index))
    }

    fn remove_tab(&mut self, session_index: usize, tab_index: usize) -> Removed {
        let session = &mut self.sessions[session_index];
        let tab = session.tabs.remove(tab_index);
        let panes = leaves(&tab.root).collect();
        // A session outlives its last tab: clients attached to it see it empty (and can open
        // or reopen a tab there) instead of a session that vanished under them.
        if session.active_tab == Some(tab.tab_id) {
            // The tab that slides into the closed one's place.
            session.active_tab = session
                .tabs
                .get(tab_index.min(session.tabs.len().saturating_sub(1)))
                .map(|next| next.tab_id);
        }
        session.leave_project(tab.tab_id);
        session.tidy_floats();
        session.revision += 1;
        Removed {
            panes,
            session: None,
        }
    }

    pub fn move_tab(&mut self, tab: TabId, index: u32) -> OpResult<()> {
        let (session_index, tab_index) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let session = &mut self.sessions[session_index];
        let to = (index as usize).min(session.tabs.len() - 1);
        if to != tab_index {
            let moved = session.tabs.remove(tab_index);
            session.tabs.insert(to, moved);
            session.revision += 1;
        }
        Ok(())
    }

    pub fn select_tab(&mut self, tab: TabId) -> OpResult<()> {
        let (session_index, _) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let session = &mut self.sessions[session_index];
        if session.active_tab != Some(tab) {
            session.active_tab = Some(tab);
            session.revision += 1;
        }
        Ok(())
    }

    pub fn rename_tab(&mut self, tab: TabId, name: String) -> OpResult<()> {
        let (session_index, tab_index) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let session = &mut self.sessions[session_index];
        if session.tabs[tab_index].name != name {
            session.tabs[tab_index].name = name;
            session.revision += 1;
        }
        Ok(())
    }

    /// Fails with [`OpError::Invalid`] if splitting `pane` would nest deeper than
    /// [`MAX_SPLIT_DEPTH`], so callers can refuse before starting the new pane's process.
    pub fn check_split(&self, pane: PaneId) -> OpResult<()> {
        let (session_index, tab_index) = self.locate(pane).ok_or(OpError::NotFound)?;
        let depth =
            leaf_depth(&self.sessions[session_index].tabs[tab_index].root, pane).unwrap_or(0);
        if depth + 1 > MAX_SPLIT_DEPTH {
            return Err(OpError::Invalid);
        }
        Ok(())
    }

    /// Splits `pane`, putting `new` after it, and focuses `new`.
    pub fn split(&mut self, pane: PaneId, axis: Axis, new: PaneId) -> OpResult<SessionId> {
        self.check_split(pane)?;
        let (session_index, tab_index) = self.locate(pane).ok_or(OpError::NotFound)?;
        let session = &mut self.sessions[session_index];
        let tab = &mut session.tabs[tab_index];
        let replaced = replace_leaf(&mut tab.root, pane, |leaf| LayoutNode::Split {
            axis,
            ratio: 0.5,
            first: Box::new(leaf),
            second: Box::new(LayoutNode::Leaf(new)),
        });
        debug_assert!(replaced);
        tab.focused = new;
        tab.zoomed = None;
        session.adopt(pane, [new]);
        session.revision += 1;
        Ok(session.id)
    }

    pub fn close_pane(&mut self, pane: PaneId) -> OpResult<Removed> {
        let (session_index, tab_index) = self.locate(pane).ok_or(OpError::NotFound)?;
        let tab = &mut self.sessions[session_index].tabs[tab_index];
        if tab.root == LayoutNode::Leaf(pane) {
            return Ok(self.remove_tab(session_index, tab_index));
        }
        // Focus moves to the closed pane's sibling subtree (its first leaf), like tmux.
        detach_leaf(tab, pane);
        let session = &mut self.sessions[session_index];
        session.tidy_floats();
        session.revision += 1;
        Ok(Removed {
            panes: vec![pane],
            session: None,
        })
    }

    pub fn focus(&mut self, pane: PaneId) -> OpResult<()> {
        let (session_index, tab_index) = self.locate(pane).ok_or(OpError::NotFound)?;
        let session = &mut self.sessions[session_index];
        let tab_id = session.tabs[tab_index].tab_id;
        let tab = &mut session.tabs[tab_index];
        let mut changed = false;
        if tab.focused != pane {
            tab.focused = pane;
            changed = true;
        }
        if tab.zoomed.is_some_and(|zoomed| zoomed != pane) {
            tab.zoomed = None;
            changed = true;
        }
        if session.active_tab != Some(tab_id) {
            session.active_tab = Some(tab_id);
            changed = true;
        }
        // A window focused comes to the front, and back from the tray.
        if let Some(window) = session.window_of(pane) {
            if session.floats[window].minimized {
                session.floats[window].minimized = false;
                changed = true;
            }
            changed |= session.raise(window);
        }
        if changed {
            session.revision += 1;
        }
        Ok(())
    }

    pub fn focus_direction(&mut self, tab: TabId, direction: Direction) -> OpResult<()> {
        let (session_index, tab_index) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let session = &self.sessions[session_index];
        let tab_layout = &session.tabs[tab_index];
        // Focus moves within the focused pane's own layer: the tiled panes or its window.
        let layer = match session.window_of(tab_layout.focused) {
            Some(window) => subtree(&tab_layout.root, &session.floats[window].panes).cloned(),
            None => tiled_tree(&tab_layout.root, |pane| session.is_floating(pane)),
        };
        let all = layer.as_ref().map(rects).unwrap_or_default();
        match neighbor(&all, tab_layout.focused, direction) {
            Some(next) => self.focus(next),
            None => Ok(()),
        }
    }

    pub fn resize(&mut self, pane: PaneId, axis: Axis, delta: f32) -> OpResult<()> {
        if !delta.is_finite() {
            return Err(OpError::Invalid);
        }
        let (session_index, tab_index) = self.locate(pane).ok_or(OpError::NotFound)?;
        let session = &mut self.sessions[session_index];
        // Only a divider the pane's own layer shows moves: a split whose other side is all in
        // other layers (a floating window over the tiled panes, or the tiled panes around a
        // window) is not on screen.
        let layer_of = |leaf: PaneId| {
            session
                .window_of(leaf)
                .map(|window| session.floats[window].id)
        };
        let own_layer = layer_of(pane);
        let layers: Vec<(PaneId, Option<FloatId>)> =
            session.panes().map(|leaf| (leaf, layer_of(leaf))).collect();
        let in_own_layer = |leaf: PaneId| {
            layers
                .iter()
                .any(|&(other, layer)| other == leaf && layer == own_layer)
        };
        if resize_in(
            &mut session.tabs[tab_index].root,
            pane,
            axis,
            delta,
            &in_own_layer,
        ) == Resize::Changed
        {
            session.revision += 1;
        }
        Ok(())
    }

    pub fn toggle_zoom(&mut self, pane: PaneId) -> OpResult<()> {
        let (session_index, tab_index) = self.locate(pane).ok_or(OpError::NotFound)?;
        let session = &mut self.sessions[session_index];
        let tab = &mut session.tabs[tab_index];
        tab.zoomed = if tab.zoomed == Some(pane) {
            None
        } else {
            Some(pane)
        };
        tab.focused = pane;
        session.revision += 1;
        Ok(())
    }
}

impl Layout {
    /// Moves `pane` into a new tab right after its own and selects it. A tab's only pane
    /// stays (`Invalid`): it already is a tab of its own.
    pub fn break_pane(&mut self, pane: PaneId) -> OpResult<(SessionId, TabId)> {
        let (session_index, tab_index) = self.locate(pane).ok_or(OpError::NotFound)?;
        if self.sessions[session_index].tabs[tab_index].root == LayoutNode::Leaf(pane) {
            return Err(OpError::Invalid);
        }
        detach_leaf(&mut self.sessions[session_index].tabs[tab_index], pane);
        let tab = self.new_tab_layout(String::new(), pane);
        let tab_id = tab.tab_id;
        let session = &mut self.sessions[session_index];
        session.release(pane);
        session.tabs.insert(tab_index + 1, tab);
        session.tidy_floats();
        session.active_tab = Some(tab_id);
        session.revision += 1;
        Ok((session.id, tab_id))
    }

    /// Moves `pane` beside `target` (same session) on `side`, focused; its tab closes when it
    /// was the tab's only pane.
    pub fn move_pane(
        &mut self,
        pane: PaneId,
        target: PaneId,
        side: Direction,
    ) -> OpResult<SessionId> {
        let (session_index, tab_index) = self.locate(pane).ok_or(OpError::NotFound)?;
        let (target_session_index, _) = self.locate(target).ok_or(OpError::NotFound)?;
        if pane == target || session_index != target_session_index {
            return Err(OpError::Invalid);
        }
        self.check_insert(target, &LayoutNode::Leaf(pane))?;
        self.sessions[session_index].release(pane);
        if self.sessions[session_index].tabs[tab_index].root == LayoutNode::Leaf(pane) {
            self.take_tab(session_index, tab_index);
        } else {
            detach_leaf(&mut self.sessions[session_index].tabs[tab_index], pane);
        }
        self.insert_beside(session_index, target, LayoutNode::Leaf(pane), side, pane);
        self.sessions[session_index].tidy_floats();
        Ok(self.sessions[session_index].id)
    }

    /// Moves every pane of `tab` beside `target` (in another tab of the same session) on
    /// `side`, keeping their arrangement and focus; `tab` closes.
    pub fn merge_tab(
        &mut self,
        tab: TabId,
        target: PaneId,
        side: Direction,
    ) -> OpResult<SessionId> {
        let (session_index, tab_index) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let (target_session_index, target_tab_index) =
            self.locate(target).ok_or(OpError::NotFound)?;
        if session_index != target_session_index || tab_index == target_tab_index {
            return Err(OpError::Invalid);
        }
        self.check_insert(target, &self.sessions[session_index].tabs[tab_index].root)?;
        let merged = self.take_tab(session_index, tab_index);
        // Its windows dock as they merge: one window never sits inside another.
        self.sessions[session_index]
            .floats
            .retain(|window| !has_leaf(&merged.root, window.panes[0]));
        self.insert_beside(session_index, target, merged.root, side, merged.focused);
        self.sessions[session_index].tidy_floats();
        Ok(self.sessions[session_index].id)
    }

    /// Fails if putting `node` beside `target` would nest deeper than [`MAX_SPLIT_DEPTH`].
    /// Measured before `node` leaves its place, so it can only overestimate.
    fn check_insert(&self, target: PaneId, node: &LayoutNode) -> OpResult<()> {
        let (session_index, tab_index) = self.locate(target).ok_or(OpError::NotFound)?;
        let target_depth =
            leaf_depth(&self.sessions[session_index].tabs[tab_index].root, target).unwrap_or(0);
        if target_depth + 1 + depth(node) > MAX_SPLIT_DEPTH {
            return Err(OpError::Invalid);
        }
        Ok(())
    }

    /// Removes a tab whose panes live on elsewhere in the session (so it is not the last).
    fn take_tab(&mut self, session_index: usize, tab_index: usize) -> TabLayout {
        let session = &mut self.sessions[session_index];
        let tab = session.tabs.remove(tab_index);
        if session.active_tab == Some(tab.tab_id) {
            session.active_tab = session
                .tabs
                .get(tab_index.min(session.tabs.len().saturating_sub(1)))
                .map(|next| next.tab_id);
        }
        session.leave_project(tab.tab_id);
        tab
    }

    /// Puts `node` beside the leaf `target` on `side`, focuses `focus` and selects the tab.
    fn insert_beside(
        &mut self,
        session_index: usize,
        target: PaneId,
        node: LayoutNode,
        side: Direction,
        focus: PaneId,
    ) {
        let moved: Vec<PaneId> = leaves(&node).collect();
        let session = &mut self.sessions[session_index];
        session.adopt(target, moved);
        let Some(tab) = session
            .tabs
            .iter_mut()
            .find(|tab| has_leaf(&tab.root, target))
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
        session.active_tab = Some(tab.tab_id);
        session.revision += 1;
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
        let (session_index, _) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        let session = &mut self.sessions[session_index];
        let new = match project {
            Some(project) if session.projects.iter().any(|defined| defined.id == project) => {
                Some(TabProject {
                    tab_id: tab,
                    project,
                    rank,
                })
            }
            Some(_) => return Err(OpError::Invalid),
            None => None,
        };
        let current = session
            .tab_projects
            .iter()
            .find(|membership| membership.tab_id == tab);
        if current == new.as_ref() {
            return Ok(session.id);
        }
        match new {
            // Moving within the same project keeps its definition.
            Some(membership) => match session
                .tab_projects
                .iter_mut()
                .find(|existing| existing.tab_id == tab)
            {
                Some(old) if old.project == membership.project => *old = membership,
                _ => {
                    session.leave_project(tab);
                    session.tab_projects.push(membership);
                }
            },
            None => session.leave_project(tab),
        }
        session.revision += 1;
        Ok(session.id)
    }

    /// Defines or updates `project` in `session`. An older `updated` than the stored one, or
    /// an identical definition, changes nothing.
    pub fn put_project(&mut self, session: SessionId, project: Project) -> OpResult<()> {
        if !project.is_valid() {
            return Err(OpError::Invalid);
        }
        let session_index = self.session_index(session)?;
        let session = &mut self.sessions[session_index];
        let full = session.projects.len() >= proto::MAX_PROJECTS_PER_SESSION;
        match session
            .projects
            .iter_mut()
            .find(|stored| stored.id == project.id)
        {
            Some(stored) if stored.updated > project.updated || *stored == project => {
                return Ok(());
            }
            Some(stored) => *stored = project,
            None if full => return Err(OpError::Invalid),
            None => session.projects.push(project),
        }
        session.revision += 1;
        Ok(())
    }

    /// Ungroups every tab of `project` in `session` and drops its definition.
    pub fn remove_project(&mut self, session: SessionId, project: &str) -> OpResult<()> {
        let session_index = self.session_index(session)?;
        let session = &mut self.sessions[session_index];
        let before = (session.projects.len(), session.tab_projects.len());
        session.projects.retain(|defined| defined.id != project);
        session
            .tab_projects
            .retain(|membership| membership.project != project);
        if (session.projects.len(), session.tab_projects.len()) != before {
            session.revision += 1;
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
        let (session_index, tab_index) = self.locate(anchor).ok_or(OpError::NotFound)?;
        let session = &mut self.sessions[session_index];
        if session.windows_in(&session.tabs[tab_index]) >= proto::MAX_FLOATS_PER_TAB {
            return Err(OpError::Invalid);
        }
        let frame = frame.unwrap_or_else(|| session.free_frame(&session.tabs[tab_index]));
        let tab = &mut session.tabs[tab_index];
        append_right(&mut tab.root, new);
        if focus {
            tab.focused = new;
            tab.zoomed = None;
            session.active_tab = Some(tab.tab_id);
        }
        session.open_window(vec![new], frame, close);
        session.revision += 1;
        Ok(session.id)
    }

    /// Floats a tiled pane in a window of its own (its leaf stays where it docks back to),
    /// tears a pane out of a window it shares, or moves a window that is just this pane. A
    /// tab's last tiled pane stays (`Invalid`).
    pub fn float_pane(&mut self, pane: PaneId, frame: Option<FloatFrame>) -> OpResult<SessionId> {
        let frame = clamp_frame(frame)?;
        let (session_index, tab_index) = self.locate(pane).ok_or(OpError::NotFound)?;
        let session = &mut self.sessions[session_index];
        match session.window_of(pane) {
            Some(window_index) if session.floats[window_index].panes.len() == 1 => {
                let window = &mut session.floats[window_index];
                let mut changed = frame.is_some_and(|requested| requested != window.frame);
                window.frame = frame.unwrap_or(window.frame);
                changed |= session.raise(window_index);
                if changed {
                    session.revision += 1;
                }
                return Ok(session.id);
            }
            Some(window_index) => {
                if session.windows_in(&session.tabs[tab_index]) >= proto::MAX_FLOATS_PER_TAB {
                    return Err(OpError::Invalid);
                }
                let from = session.floats[window_index].frame;
                let frame = frame.unwrap_or(FloatFrame {
                    x: from.x + 0.04,
                    y: from.y + 0.04,
                    ..from
                });
                let frame = frame.clamped().unwrap_or(FloatFrame::DEFAULT);
                session.release(pane);
                let tab = &mut session.tabs[tab_index];
                detach_leaf(tab, pane);
                append_right(&mut tab.root, pane);
                tab.focused = pane;
                session.open_window(vec![pane], frame, CloseWhen::Never);
            }
            None => {
                if session.tiled(&session.tabs[tab_index]).count() < 2
                    || session.windows_in(&session.tabs[tab_index]) >= proto::MAX_FLOATS_PER_TAB
                {
                    return Err(OpError::Invalid);
                }
                let frame = frame.unwrap_or_else(|| session.free_frame(&session.tabs[tab_index]));
                let tab = &mut session.tabs[tab_index];
                if tab.zoomed == Some(pane) {
                    tab.zoomed = None;
                }
                session.open_window(vec![pane], frame, CloseWhen::Never);
            }
        }
        session.tidy_floats();
        session.revision += 1;
        Ok(session.id)
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
        let (session_index, tab_index) = self.locate(pane).ok_or(OpError::NotFound)?;
        let session = &mut self.sessions[session_index];
        let window_index = session.window_of(pane).ok_or(OpError::Invalid)?;
        let window = &mut session.floats[window_index];
        let before = window.clone();
        window.frame = frame.unwrap_or(window.frame);
        window.minimized = minimized.unwrap_or(window.minimized);
        window.pinned = pinned.unwrap_or(window.pinned);
        let after = window.clone();
        let mut changed = after != before;
        // Restoring raises, even a window already out: the way to bring one forward without
        // touching the keyboard's focus.
        if minimized == Some(false) {
            changed |= session.raise(window_index);
        }
        let focused = session.tabs[tab_index].focused;
        if after.minimized && after.panes.contains(&focused) {
            let next = session
                .tiled(&session.tabs[tab_index])
                .next()
                .expect("a tab keeps a tiled pane");
            let tab = &mut session.tabs[tab_index];
            tab.focused = next;
            tab.zoomed = None;
            changed = true;
        }
        if changed {
            session.revision += 1;
        }
        Ok(session.id)
    }

    /// Docks the window holding `pane`, splits and all: where it is, or beside a tiled pane
    /// of the same session. Focuses `pane`.
    pub fn dock_pane(&mut self, pane: PaneId, beside: Option<DockTarget>) -> OpResult<SessionId> {
        let (session_index, tab_index) = self.locate(pane).ok_or(OpError::NotFound)?;
        let window_index = self.sessions[session_index]
            .window_of(pane)
            .ok_or(OpError::Invalid)?;
        let Some(DockTarget {
            pane_id: target,
            side,
        }) = beside
        else {
            self.sessions[session_index].floats.remove(window_index);
            self.focus(pane)?;
            self.sessions[session_index].revision += 1;
            return Ok(self.sessions[session_index].id);
        };
        let session = &self.sessions[session_index];
        if !session.session_has(target) || session.is_floating(target) {
            return Err(OpError::Invalid);
        }
        let mut probe = session.tabs[tab_index].root.clone();
        let node = take_subtree(&mut probe, &session.floats[window_index].panes)
            .ok_or(OpError::Invalid)?;
        self.check_insert(target, &node)?;
        let session = &mut self.sessions[session_index];
        let window = session.floats.remove(window_index);
        let tab = &mut session.tabs[tab_index];
        let node = take_subtree(&mut tab.root, &window.panes).ok_or(OpError::Invalid)?;
        if window.panes.contains(&tab.focused) || tab.zoomed.is_some() {
            tab.focused = first_leaf(&tab.root);
            tab.zoomed = None;
        }
        self.insert_beside(session_index, target, node, side, pane);
        self.sessions[session_index].tidy_floats();
        Ok(self.sessions[session_index].id)
    }

    /// Moves `pane` along the whole `side` edge of `tab`'s tiled panes (same session),
    /// focused; its old tab closes when it was its only pane.
    pub fn move_pane_to_edge(
        &mut self,
        pane: PaneId,
        tab: TabId,
        side: Direction,
    ) -> OpResult<SessionId> {
        let (session_index, tab_index) = self.locate(pane).ok_or(OpError::NotFound)?;
        let (target_session_index, _) = self.locate_tab(tab).ok_or(OpError::NotFound)?;
        if session_index != target_session_index {
            return Err(OpError::Invalid);
        }
        let source = self.sessions[session_index].tabs[tab_index].tab_id;
        if source == tab
            && self.sessions[session_index].tabs[tab_index].root == LayoutNode::Leaf(pane)
        {
            return Ok(self.sessions[session_index].id);
        }
        let target_tab = self.sessions[session_index]
            .tabs
            .iter()
            .find(|candidate| candidate.tab_id == tab);
        if target_tab.is_some_and(|target| depth(&target.root) + 1 > MAX_SPLIT_DEPTH) {
            return Err(OpError::Invalid);
        }
        self.sessions[session_index].release(pane);
        if self.sessions[session_index].tabs[tab_index].root == LayoutNode::Leaf(pane) {
            self.take_tab(session_index, tab_index);
        } else {
            detach_leaf(&mut self.sessions[session_index].tabs[tab_index], pane);
        }
        let session = &mut self.sessions[session_index];
        let target = session
            .tabs
            .iter_mut()
            .find(|candidate| candidate.tab_id == tab)
            .expect("the tab is in this session");
        let (axis, before) = match side {
            Direction::Left => (Axis::Horizontal, true),
            Direction::Right => (Axis::Horizontal, false),
            Direction::Up => (Axis::Vertical, true),
            Direction::Down => (Axis::Vertical, false),
        };
        let rest = std::mem::replace(&mut target.root, LayoutNode::Leaf(pane));
        let (first, second) = if before {
            (LayoutNode::Leaf(pane), rest)
        } else {
            (rest, LayoutNode::Leaf(pane))
        };
        // A third of the edge: the pane joins the tab's panes rather than halving them.
        let ratio = if before { 1.0 / 3.0 } else { 2.0 / 3.0 };
        target.root = LayoutNode::Split {
            axis,
            ratio,
            first: Box::new(first),
            second: Box::new(second),
        };
        target.focused = pane;
        target.zoomed = None;
        session.active_tab = Some(tab);
        session.tidy_floats();
        session.revision += 1;
        Ok(session.id)
    }

    pub fn floats(&self, session: SessionId) -> Option<SessionFloats> {
        self.session(session).map(Session::to_floats)
    }

    /// The window holding `pane`, if it floats.
    pub fn window_of(&self, pane: PaneId) -> Option<FloatWindow> {
        let (session_index, _) = self.locate(pane)?;
        let session = &self.sessions[session_index];
        session
            .window_of(pane)
            .map(|index| session.floats[index].clone())
    }
}

impl Session {
    fn session_has(&self, pane: PaneId) -> bool {
        self.panes().any(|leaf| leaf == pane)
    }
}

fn clamp_frame(frame: Option<FloatFrame>) -> OpResult<Option<FloatFrame>> {
    frame
        .map(|frame| frame.clamped().ok_or(OpError::Invalid))
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
    match node {
        LayoutNode::Leaf(leaf) => *leaf == pane,
        LayoutNode::Split { first, second, .. } => has_leaf(first, pane) || has_leaf(second, pane),
    }
}

/// Whether `node`'s leaves are exactly `panes`.
fn is_exactly(node: &LayoutNode, panes: &[PaneId]) -> bool {
    let all: Vec<PaneId> = leaves(node).collect();
    all.len() == panes.len() && all.iter().all(|leaf| panes.contains(leaf))
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
        if all.iter().all(|leaf| within.contains(leaf)) {
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
        LayoutNode::Leaf(pane) => (!floating(*pane)).then(|| node.clone()),
        LayoutNode::Split {
            axis,
            ratio,
            first,
            second,
        } => match (tiled_tree(first, floating), tiled_tree(second, floating)) {
            (Some(tiled_first), Some(tiled_second)) => Some(LayoutNode::Split {
                axis: *axis,
                ratio: *ratio,
                first: Box::new(tiled_first),
                second: Box::new(tiled_second),
            }),
            (tiled_first, tiled_second) => tiled_first.or(tiled_second),
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
pub(crate) fn leaves(node: &LayoutNode) -> Leaves<'_> {
    Leaves {
        next: Some(node),
        later: Vec::new(),
    }
}

/// A tree's panes, left to right. A single pane allocates nothing.
pub(crate) struct Leaves<'a> {
    next: Option<&'a LayoutNode>,
    later: Vec<&'a LayoutNode>,
}

impl Iterator for Leaves<'_> {
    type Item = PaneId;

    fn next(&mut self) -> Option<PaneId> {
        let mut node = self.next.take().or_else(|| self.later.pop())?;
        loop {
            match node {
                LayoutNode::Leaf(pane) => return Some(*pane),
                LayoutNode::Split { first, second, .. } => {
                    self.later.push(second);
                    node = first;
                }
            }
        }
    }
}

/// Splits on the longest path from `node` to a leaf.
fn depth(node: &LayoutNode) -> usize {
    match node {
        LayoutNode::Leaf(_) => 0,
        LayoutNode::Split { first, second, .. } => 1 + depth(first).max(depth(second)),
    }
}

/// Splits between `node` and the leaf `pane`, if it is in the tree.
fn leaf_depth(node: &LayoutNode, pane: PaneId) -> Option<usize> {
    match node {
        LayoutNode::Leaf(leaf) => (*leaf == pane).then_some(0),
        LayoutNode::Split { first, second, .. } => leaf_depth(first, pane)
            .or_else(|| leaf_depth(second, pane))
            .map(|depth| depth + 1),
    }
}

fn first_leaf(node: &LayoutNode) -> PaneId {
    match node {
        LayoutNode::Leaf(pane) => *pane,
        LayoutNode::Split { first, .. } => first_leaf(first),
    }
}

/// Replaces the leaf `pane` with `build(leaf)`. Returns whether it was found.
fn replace_leaf(
    node: &mut LayoutNode,
    pane: PaneId,
    build: impl FnOnce(LayoutNode) -> LayoutNode,
) -> bool {
    fn walk(
        node: &mut LayoutNode,
        pane: PaneId,
        build: &mut Option<impl FnOnce(LayoutNode) -> LayoutNode>,
    ) -> bool {
        match node {
            LayoutNode::Leaf(leaf) if *leaf == pane => {
                let leaf = std::mem::replace(node, LayoutNode::Leaf(pane));
                *node = (build.take().expect("called once"))(leaf);
                true
            }
            LayoutNode::Leaf(_) => false,
            LayoutNode::Split { first, second, .. } => {
                walk(first, pane, build) || walk(second, pane, build)
            }
        }
    }
    walk(node, pane, &mut Some(build))
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

/// Moves the divider of the nearest split on `axis` around `pane` whose other side holds a
/// pane `in_own_layer` accepts.
fn resize_in(
    node: &mut LayoutNode,
    pane: PaneId,
    axis: Axis,
    delta: f32,
    in_own_layer: &dyn Fn(PaneId) -> bool,
) -> Resize {
    match node {
        LayoutNode::Leaf(leaf) if *leaf == pane => Resize::Pending { in_first: true },
        LayoutNode::Leaf(_) => Resize::NotFound,
        LayoutNode::Split {
            axis: split_axis,
            ratio,
            first,
            second,
        } => {
            let (child, in_first) = match resize_in(first, pane, axis, delta, in_own_layer) {
                Resize::NotFound => (resize_in(second, pane, axis, delta, in_own_layer), false),
                other => (other, true),
            };
            let other = if in_first { &**second } else { &**first };
            match child {
                Resize::Pending { .. }
                    if *split_axis == axis && leaves(other).any(in_own_layer) =>
                {
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
    fn walk(node: &LayoutNode, rect: Rect, out: &mut Vec<(PaneId, Rect)>) {
        match node {
            LayoutNode::Leaf(pane) => out.push((*pane, rect)),
            LayoutNode::Split {
                axis,
                ratio,
                first,
                second,
            } => {
                let (first_rect, second_rect) = match axis {
                    Axis::Horizontal => {
                        let w = rect.w * ratio;
                        (
                            Rect { w, ..rect },
                            Rect {
                                x: rect.x + w,
                                w: rect.w - w,
                                ..rect
                            },
                        )
                    }
                    Axis::Vertical => {
                        let h = rect.h * ratio;
                        (
                            Rect { h, ..rect },
                            Rect {
                                y: rect.y + h,
                                h: rect.h - h,
                                ..rect
                            },
                        )
                    }
                };
                walk(first, first_rect, out);
                walk(second, second_rect, out);
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
    const EPSILON: f32 = 1e-4;
    let (_, origin) = *all.iter().find(|(pane, _)| *pane == from)?;
    let overlap = |a0: f32, a1: f32, b0: f32, b1: f32| (a1.min(b1) - a0.max(b0)).max(0.0);
    all.iter()
        .filter(|(pane, _)| *pane != from)
        .filter_map(|&(pane, rect)| {
            let vertical_overlap = overlap(origin.y, origin.y + origin.h, rect.y, rect.y + rect.h);
            let horizontal_overlap =
                overlap(origin.x, origin.x + origin.w, rect.x, rect.x + rect.w);
            let (gap, shared) = match direction {
                Direction::Right => (rect.x - (origin.x + origin.w), vertical_overlap),
                Direction::Left => (origin.x - (rect.x + rect.w), vertical_overlap),
                Direction::Down => (rect.y - (origin.y + origin.h), horizontal_overlap),
                Direction::Up => (origin.y - (rect.y + rect.h), horizontal_overlap),
            };
            (gap > -EPSILON && shared > EPSILON).then_some((pane, gap, shared))
        })
        .min_by(|a, b| {
            a.1.partial_cmp(&b.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal))
        })
        .map(|(pane, _, _)| pane)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session_with(layout: &mut Layout) -> (SessionId, TabId, PaneId) {
        let pane = layout.alloc_pane();
        let (session, tab) = layout.create_session("main".into(), pane).unwrap();
        (session, tab, pane)
    }

    #[test]
    fn split_close_and_focus() {
        let mut layout = Layout::default();
        let (session, tab, p1) = session_with(&mut layout);
        let p2 = layout.alloc_pane();
        layout.split(p1, Axis::Horizontal, p2).unwrap();
        let p3 = layout.alloc_pane();
        layout.split(p2, Axis::Vertical, p3).unwrap();
        // p1 | (p2 / p3)
        assert_eq!(layout.focused_pane(session), Some(p3));
        layout.focus_direction(tab, Direction::Up).unwrap();
        assert_eq!(layout.focused_pane(session), Some(p2));
        layout.focus_direction(tab, Direction::Left).unwrap();
        assert_eq!(layout.focused_pane(session), Some(p1));
        layout.focus_direction(tab, Direction::Left).unwrap();
        assert_eq!(layout.focused_pane(session), Some(p1), "edge is a no-op");
        layout.focus_direction(tab, Direction::Right).unwrap();
        assert!(matches!(layout.focused_pane(session), Some(p) if p == p2 || p == p3));

        let removed = layout.close_pane(p2).unwrap();
        assert_eq!(removed.panes, vec![p2]);
        let snapshot = layout.snapshot(session).unwrap();
        assert_eq!(
            snapshot.tabs[0].root,
            LayoutNode::Split {
                axis: Axis::Horizontal,
                ratio: 0.5,
                first: Box::new(LayoutNode::Leaf(p1)),
                second: Box::new(LayoutNode::Leaf(p3)),
            }
        );
        layout.close_pane(p1).unwrap();
        assert_eq!(
            layout.snapshot(session).unwrap().tabs[0].root,
            LayoutNode::Leaf(p3)
        );
        let removed = layout.close_pane(p3).unwrap();
        assert_eq!(
            removed.session, None,
            "the last tab leaves its session in place"
        );
        let snapshot = layout.snapshot(session).unwrap();
        assert!(snapshot.tabs.is_empty());
        assert_eq!(snapshot.active_tab, None);
    }

    #[test]
    fn resize_moves_nearest_divider_on_axis() {
        let mut layout = Layout::default();
        let (session, _, p1) = session_with(&mut layout);
        let p2 = layout.alloc_pane();
        layout.split(p1, Axis::Horizontal, p2).unwrap();
        let p3 = layout.alloc_pane();
        layout.split(p2, Axis::Vertical, p3).unwrap();
        let before = layout.session(session).unwrap().revision;
        layout.resize(p3, Axis::Horizontal, 0.1).unwrap();
        let LayoutNode::Split { ratio, .. } = layout.snapshot(session).unwrap().tabs[0].root else {
            panic!()
        };
        assert!(
            (ratio - 0.4).abs() < 1e-6,
            "p3 is second: its growth shrinks the first"
        );
        layout.resize(p1, Axis::Horizontal, 5.0).unwrap();
        let LayoutNode::Split { ratio, .. } = layout.snapshot(session).unwrap().tabs[0].root else {
            panic!()
        };
        assert!((ratio - (1.0 - MIN_RATIO)).abs() < 1e-6);
        assert!(layout.session(session).unwrap().revision > before);
        assert_eq!(
            layout.resize(p1, Axis::Horizontal, f32::NAN),
            Err(OpError::Invalid)
        );
    }

    #[test]
    fn tabs_and_sessions() {
        let mut layout = Layout::default();
        let (session, t1, _) = session_with(&mut layout);
        let p2 = layout.alloc_pane();
        let t2 = layout.new_tab(session, "two".into(), p2).unwrap();
        assert_eq!(layout.session(session).unwrap().active_tab, Some(t2));
        layout.move_tab(t2, 0).unwrap();
        assert_eq!(layout.session(session).unwrap().tabs[0].tab_id, t2);
        let removed = layout.close_tab(t2).unwrap();
        assert_eq!(removed.panes, vec![p2]);
        assert_eq!(layout.session(session).unwrap().active_tab, Some(t1));
        assert_eq!(
            layout.create_session("main".into(), PaneId(99)),
            Err(OpError::NameTaken)
        );
        assert_eq!(layout.unique_name("main"), "main-2");
        let before = layout.session(session).unwrap().revision;
        layout.rename_tab(t1, String::new()).unwrap();
        assert_eq!(
            layout.session(session).unwrap().revision,
            before,
            "no-op keeps the revision"
        );
    }

    #[test]
    fn zoom_toggles_and_unzooms_on_focus_elsewhere() {
        let mut layout = Layout::default();
        let (session, _, p1) = session_with(&mut layout);
        let p2 = layout.alloc_pane();
        layout.split(p1, Axis::Vertical, p2).unwrap();
        layout.toggle_zoom(p1).unwrap();
        assert_eq!(layout.visible_panes(session), vec![p1]);
        layout.focus(p2).unwrap();
        assert_eq!(layout.visible_panes(session), vec![p2, p1]);
        layout.toggle_zoom(p2).unwrap();
        layout.toggle_zoom(p2).unwrap();
        assert_eq!(layout.snapshot(session).unwrap().tabs[0].zoomed, None);
    }

    #[test]
    fn break_move_and_merge_keep_panes() {
        let mut layout = Layout::default();
        let (session, t1, p1) = session_with(&mut layout);
        let p2 = layout.alloc_pane();
        layout.split(p1, Axis::Horizontal, p2).unwrap();
        assert_eq!(layout.break_pane(p1).ok().map(|(id, _)| id), Some(session));
        assert_eq!(
            layout.break_pane(p2),
            Err(OpError::Invalid),
            "a tab's only pane"
        );
        let snapshot = layout.snapshot(session).unwrap();
        let t2 = snapshot.tabs[1].tab_id;
        assert_eq!(snapshot.tabs[0].root, LayoutNode::Leaf(p2));
        assert_eq!(snapshot.tabs[1].root, LayoutNode::Leaf(p1));
        assert_eq!(snapshot.active_tab, Some(t2));

        // Back beside p2, on its left: the emptied tab closes.
        layout.move_pane(p1, p2, Direction::Left).unwrap();
        let snapshot = layout.snapshot(session).unwrap();
        assert_eq!(snapshot.tabs.len(), 1);
        assert_eq!(
            snapshot.tabs[0].root,
            LayoutNode::Split {
                axis: Axis::Horizontal,
                ratio: 0.5,
                first: Box::new(LayoutNode::Leaf(p1)),
                second: Box::new(LayoutNode::Leaf(p2)),
            }
        );
        assert_eq!(snapshot.tabs[0].focused, p1);
        assert_eq!(
            layout.move_pane(p1, p1, Direction::Up),
            Err(OpError::Invalid)
        );

        // A two-pane tab merged below p1 keeps its own split and focus.
        let p3 = layout.alloc_pane();
        let t3 = layout.new_tab(session, String::new(), p3).unwrap();
        let p4 = layout.alloc_pane();
        layout.split(p3, Axis::Vertical, p4).unwrap();
        layout.merge_tab(t3, p1, Direction::Down).unwrap();
        let snapshot = layout.snapshot(session).unwrap();
        assert_eq!(snapshot.tabs.len(), 1);
        assert_eq!(snapshot.active_tab, Some(t1));
        assert_eq!(snapshot.tabs[0].focused, p4);
        assert_eq!(
            leaves(&snapshot.tabs[0].root).collect::<Vec<_>>(),
            vec![p1, p3, p4, p2]
        );
        assert_eq!(
            layout.merge_tab(t1, p1, Direction::Down),
            Err(OpError::Invalid)
        );
        assert_eq!(layout.all_panes().len(), 4, "no pane was dropped");
    }

    /// A layout nested to the limit still loads from its saved form, and nothing nests past it.
    #[test]
    fn nesting_is_capped_so_saved_layouts_load() {
        let mut layout = Layout::default();
        let (session, t1, mut pane) = session_with(&mut layout);
        for _ in 0..MAX_SPLIT_DEPTH {
            let new = layout.alloc_pane();
            layout.split(pane, Axis::Horizontal, new).unwrap();
            pane = new;
        }
        let new = layout.alloc_pane();
        assert_eq!(layout.check_split(pane), Err(OpError::Invalid));
        assert_eq!(
            layout.split(pane, Axis::Vertical, new),
            Err(OpError::Invalid)
        );

        // Moving or merging a tree beside the deepest pane is refused too.
        let top = layout.alloc_pane();
        let t2 = layout.new_tab(session, String::new(), top).unwrap();
        let bottom = layout.alloc_pane();
        layout.split(top, Axis::Vertical, bottom).unwrap();
        assert_eq!(
            layout.move_pane(bottom, pane, Direction::Down),
            Err(OpError::Invalid)
        );
        assert_eq!(
            layout.merge_tab(t2, pane, Direction::Down),
            Err(OpError::Invalid)
        );
        // So are docking a window beside it and adding a pane along the full tab's edge, and
        // the refused window stays as it was.
        layout.float_pane(bottom, None).unwrap();
        let beside = DockTarget {
            pane_id: pane,
            side: Direction::Down,
        };
        assert_eq!(
            layout.dock_pane(bottom, Some(beside)),
            Err(OpError::Invalid)
        );
        assert!(layout.window_of(bottom).is_some());
        assert_eq!(
            layout.move_pane_to_edge(top, t1, Direction::Left),
            Err(OpError::Invalid)
        );

        let saved = crate::persist::Saved::new(layout.clone(), Default::default(), Vec::new());
        let json = serde_json::to_vec(&saved).unwrap();
        let back: crate::persist::Saved = serde_json::from_slice(&json).unwrap();
        assert_eq!(
            back.into_parts().0.all_panes().len(),
            layout.all_panes().len()
        );
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

    fn member(layout: &Layout, session: SessionId, tab: TabId) -> Option<(String, i64)> {
        let projects = layout.projects(session).unwrap();
        let membership = projects
            .tabs
            .iter()
            .find(|membership| membership.tab_id == tab)?;
        Some((membership.project.clone(), membership.rank))
    }

    fn defined(layout: &Layout, session: SessionId) -> Vec<String> {
        layout
            .projects(session)
            .unwrap()
            .projects
            .into_iter()
            .map(|project| project.id)
            .collect()
    }

    fn revision(layout: &Layout, session: SessionId) -> u64 {
        layout.session(session).unwrap().revision
    }

    #[test]
    fn tabs_join_move_within_and_leave_projects() {
        let mut layout = Layout::default();
        let (session, t1, _) = session_with(&mut layout);
        assert_eq!(
            layout.set_tab_project(t1, Some("web".into()), 0),
            Err(OpError::Invalid),
            "an undefined project"
        );
        layout.put_project(session, project("web", 1)).unwrap();
        layout.put_project(session, project("api", 1)).unwrap();
        let before = revision(&layout, session);
        layout.set_tab_project(t1, Some("web".into()), 3).unwrap();
        assert_eq!(member(&layout, session, t1), Some(("web".into(), 3)));
        assert_eq!(revision(&layout, session), before + 1);
        assert_eq!(
            defined(&layout, session),
            ["web", "api"],
            "api awaits its tabs"
        );

        layout.set_tab_project(t1, Some("web".into()), 3).unwrap();
        assert_eq!(revision(&layout, session), before + 1, "no change, no bump");
        layout.set_tab_project(t1, Some("web".into()), 7).unwrap();
        assert_eq!(member(&layout, session, t1), Some(("web".into(), 7)));
        assert_eq!(defined(&layout, session), ["web", "api"]);

        // Moving to another project drops the one left empty.
        layout.set_tab_project(t1, Some("api".into()), 0).unwrap();
        assert_eq!(defined(&layout, session), ["api"]);
        layout.set_tab_project(t1, None, 0).unwrap();
        assert_eq!(member(&layout, session, t1), None);
        assert!(defined(&layout, session).is_empty());
        let before = revision(&layout, session);
        layout.set_tab_project(t1, None, 0).unwrap();
        assert_eq!(revision(&layout, session), before);
        assert_eq!(
            layout.set_tab_project(TabId(99), None, 0),
            Err(OpError::NotFound)
        );
    }

    #[test]
    fn newer_project_definitions_win() {
        let mut layout = Layout::default();
        let (session, _, _) = session_with(&mut layout);
        layout.put_project(session, project("web", 5)).unwrap();
        let before = revision(&layout, session);
        let mut older = project("web", 4);
        older.name = "Old".into();
        layout.put_project(session, older).unwrap();
        layout.put_project(session, project("web", 5)).unwrap();
        assert_eq!(
            revision(&layout, session),
            before,
            "an older or identical definition is ignored"
        );
        let mut newer = project("web", 6);
        newer.color = 7;
        layout.put_project(session, newer.clone()).unwrap();
        assert_eq!(layout.projects(session).unwrap().projects, [newer]);
        assert_eq!(revision(&layout, session), before + 1);
    }

    #[test]
    fn invalid_projects_are_refused() {
        let mut layout = Layout::default();
        let (session, _, _) = session_with(&mut layout);
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
            assert_eq!(layout.put_project(session, bad), Err(OpError::Invalid));
        }
        for i in 0..proto::MAX_PROJECTS_PER_SESSION {
            layout
                .put_project(session, project(&i.to_string(), 1))
                .unwrap();
        }
        assert_eq!(
            layout.put_project(session, project("one-more", 1)),
            Err(OpError::Invalid)
        );
        assert_eq!(
            layout.put_project(SessionId(99), project("web", 1)),
            Err(OpError::NotFound)
        );
    }

    #[test]
    fn removing_a_project_ungroups_its_tabs() {
        let mut layout = Layout::default();
        let (session, t1, _) = session_with(&mut layout);
        let p2 = layout.alloc_pane();
        let t2 = layout.new_tab(session, String::new(), p2).unwrap();
        layout.put_project(session, project("web", 1)).unwrap();
        layout.set_tab_project(t1, Some("web".into()), 0).unwrap();
        layout.set_tab_project(t2, Some("web".into()), 1).unwrap();
        let before = revision(&layout, session);
        layout.remove_project(session, "web").unwrap();
        assert_eq!(layout.projects(session).unwrap().tabs, []);
        assert!(defined(&layout, session).is_empty());
        assert_eq!(revision(&layout, session), before + 1);
        layout.remove_project(session, "web").unwrap();
        assert_eq!(
            revision(&layout, session),
            before + 1,
            "nothing left to remove"
        );
    }

    #[test]
    fn projects_follow_tabs_that_close_merge_or_break() {
        let mut layout = Layout::default();
        let (session, t1, p1) = session_with(&mut layout);
        let p2 = layout.alloc_pane();
        let t2 = layout.new_tab(session, String::new(), p2).unwrap();
        let p3 = layout.alloc_pane();
        let t3 = layout.new_tab(session, String::new(), p3).unwrap();
        layout.put_project(session, project("a", 1)).unwrap();
        layout.put_project(session, project("b", 1)).unwrap();
        layout.set_tab_project(t1, Some("a".into()), 0).unwrap();
        layout.set_tab_project(t2, Some("a".into()), 1).unwrap();
        layout.set_tab_project(t3, Some("b".into()), 0).unwrap();

        // Merging t3 away drops its membership and its now unused project.
        layout.merge_tab(t3, p1, Direction::Right).unwrap();
        assert_eq!(member(&layout, session, t3), None);
        assert_eq!(defined(&layout, session), ["a"]);

        // A pane broken out of a grouped tab starts ungrouped.
        let (_, t4) = layout.break_pane(p3).unwrap();
        assert_eq!(member(&layout, session, t4), None);
        assert_eq!(member(&layout, session, t1), Some(("a".into(), 0)));

        // Closing the last pane of t2 closes the tab; "a" lives on in t1.
        layout.close_pane(p2).unwrap();
        assert_eq!(member(&layout, session, t2), None);
        assert_eq!(defined(&layout, session), ["a"]);
        layout.close_tab(t1).unwrap();
        assert!(defined(&layout, session).is_empty());
        assert_eq!(layout.projects(session).unwrap().tabs, []);
    }

    /// Every window is one subtree of one tab, in tree order, and every tab keeps a tiled
    /// pane.
    fn check_floats(layout: &Layout) {
        for session in &layout.sessions {
            for window in &session.floats {
                let tab = session
                    .tabs
                    .iter()
                    .find(|tab| has_leaf(&tab.root, window.panes[0]))
                    .expect("in a tab");
                let node = subtree(&tab.root, &window.panes).expect("one subtree");
                assert_eq!(leaves(node).collect::<Vec<_>>(), window.panes, "tree order");
            }
            for tab in &session.tabs {
                assert!(
                    session.tiled(tab).next().is_some(),
                    "{:?} has no tiled pane",
                    tab.tab_id
                );
            }
            let depths: Vec<u32> = session.floats.iter().map(|window| window.z).collect();
            assert!(
                depths.windows(2).all(|pair| pair[0] < pair[1]),
                "back to front: {depths:?}"
            );
        }
    }

    fn windows(layout: &Layout, session: SessionId) -> Vec<Vec<PaneId>> {
        layout
            .floats(session)
            .unwrap()
            .floats
            .into_iter()
            .map(|window| window.panes)
            .collect()
    }

    fn tiled_leaves(layout: &Layout, session: SessionId) -> Vec<PaneId> {
        let session = layout.session(session).unwrap();
        let tab = session
            .tabs
            .iter()
            .find(|tab| Some(tab.tab_id) == session.active_tab)
            .unwrap();
        session.tiled(tab).collect()
    }

    /// p1 | p2 | p3, left to right.
    fn three(layout: &mut Layout) -> (SessionId, TabId, [PaneId; 3]) {
        let (session, tab, p1) = session_with(layout);
        let p2 = layout.alloc_pane();
        layout.split(p1, Axis::Horizontal, p2).unwrap();
        let p3 = layout.alloc_pane();
        layout.split(p2, Axis::Horizontal, p3).unwrap();
        (session, tab, [p1, p2, p3])
    }

    #[test]
    fn a_pane_floats_and_docks_back_where_it_was() {
        let mut layout = Layout::default();
        let (session, _, [p1, p2, p3]) = three(&mut layout);
        let before = layout.snapshot(session).unwrap().tabs[0].root.clone();
        layout.float_pane(p2, None).unwrap();
        assert_eq!(windows(&layout, session), [vec![p2]]);
        assert_eq!(tiled_leaves(&layout, session), [p1, p3]);
        assert_eq!(
            layout.snapshot(session).unwrap().tabs[0].root,
            before,
            "older clients see the same tree"
        );
        check_floats(&layout);

        layout.dock_pane(p2, None).unwrap();
        assert!(windows(&layout, session).is_empty());
        assert_eq!(layout.focused_pane(session), Some(p2));
        assert_eq!(layout.snapshot(session).unwrap().tabs[0].root, before);

        layout.float_pane(p1, None).unwrap();
        layout.float_pane(p2, None).unwrap();
        assert_eq!(
            layout.float_pane(p3, None),
            Err(OpError::Invalid),
            "a tab keeps a tiled pane"
        );
        check_floats(&layout);
    }

    #[test]
    fn new_floats_open_right_of_the_tab_without_taking_focus() {
        let mut layout = Layout::default();
        let (session, _, [p1, p2, p3]) = three(&mut layout);
        layout.focus(p1).unwrap();
        let a = layout.alloc_pane();
        layout
            .new_float(p3, a, None, false, CloseWhen::Done)
            .unwrap();
        let b = layout.alloc_pane();
        layout
            .new_float(p1, b, None, false, CloseWhen::Never)
            .unwrap();
        assert_eq!(layout.focused_pane(session), Some(p1), "no focus stealing");
        let tab = &layout.snapshot(session).unwrap().tabs[0];
        assert_eq!(leaves(&tab.root).collect::<Vec<_>>(), [p1, p2, p3, a, b]);
        let floats = layout.floats(session).unwrap().floats;
        assert_eq!(floats[0].close, CloseWhen::Done);
        assert_ne!(
            floats[0].frame, floats[1].frame,
            "cascaded, never stacked exactly"
        );
        check_floats(&layout);

        // Focusing the back window raises it and brings it out of the tray.
        layout.set_float(a, None, Some(true), None).unwrap();
        layout.focus(a).unwrap();
        assert_eq!(windows(&layout, session), [vec![b], vec![a]]);
        assert!(!layout.floats(session).unwrap().floats[1].minimized);
        let c = layout.alloc_pane();
        layout
            .new_float(p1, c, None, true, CloseWhen::Never)
            .unwrap();
        assert_eq!(layout.focused_pane(session), Some(c));
        check_floats(&layout);
    }

    #[test]
    fn windows_hold_splits_and_panes_move_in_and_out() {
        let mut layout = Layout::default();
        let (session, _, [p1, p2, p3]) = three(&mut layout);
        let f = layout.alloc_pane();
        layout
            .new_float(p1, f, None, false, CloseWhen::Never)
            .unwrap();
        // A split inside the window stays in it.
        let g = layout.alloc_pane();
        layout.split(f, Axis::Vertical, g).unwrap();
        assert_eq!(windows(&layout, session), [vec![f, g]]);
        // A tiled pane dropped beside a window's pane joins the window...
        layout.move_pane(p2, g, Direction::Right).unwrap();
        assert_eq!(windows(&layout, session), [vec![f, g, p2]]);
        assert_eq!(tiled_leaves(&layout, session), [p1, p3]);
        check_floats(&layout);
        // ...and one dropped beside a tiled pane leaves it.
        layout.move_pane(f, p1, Direction::Down).unwrap();
        assert_eq!(windows(&layout, session), [vec![g, p2]]);
        assert_eq!(tiled_leaves(&layout, session), [p1, f, p3]);
        check_floats(&layout);
        // Floating a pane of a shared window tears it off into its own.
        layout.float_pane(p2, None).unwrap();
        assert_eq!(windows(&layout, session), [vec![g], vec![p2]]);
        let frames: Vec<FloatFrame> = layout
            .floats(session)
            .unwrap()
            .floats
            .iter()
            .map(|window| window.frame)
            .collect();
        assert!(frames[1].x > frames[0].x, "offset from the window it left");
        check_floats(&layout);
    }

    #[test]
    fn docking_beside_a_pane_keeps_the_window_splits() {
        let mut layout = Layout::default();
        let (session, _, [p1, _, p3]) = three(&mut layout);
        let f = layout.alloc_pane();
        layout
            .new_float(p1, f, None, false, CloseWhen::Never)
            .unwrap();
        let g = layout.alloc_pane();
        layout.split(f, Axis::Vertical, g).unwrap();
        // Into another tab, below its pane.
        let q = layout.alloc_pane();
        layout.new_tab(session, String::new(), q).unwrap();
        layout
            .dock_pane(
                g,
                Some(DockTarget {
                    pane_id: q,
                    side: Direction::Down,
                }),
            )
            .unwrap();
        let snapshot = layout.snapshot(session).unwrap();
        assert!(windows(&layout, session).is_empty());
        assert_eq!(snapshot.active_tab, Some(snapshot.tabs[1].tab_id));
        assert_eq!(
            snapshot.tabs[1].root,
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
        assert_eq!(snapshot.tabs[1].focused, g);
        assert!(!leaves(&snapshot.tabs[0].root).any(|p| p == f || p == g));
        // Never beside a float, nor a pane that does not float.
        layout.float_pane(p3, None).unwrap();
        assert_eq!(
            layout.dock_pane(
                p3,
                Some(DockTarget {
                    pane_id: p3,
                    side: Direction::Left
                })
            ),
            Err(OpError::Invalid)
        );
        assert_eq!(layout.dock_pane(p1, None), Err(OpError::Invalid));
        check_floats(&layout);
    }

    #[test]
    fn the_last_tiled_pane_closing_docks_the_front_window() {
        let mut layout = Layout::default();
        let (session, _, p1) = session_with(&mut layout);
        let a = layout.alloc_pane();
        layout
            .new_float(p1, a, None, false, CloseWhen::Never)
            .unwrap();
        let b = layout.alloc_pane();
        layout
            .new_float(p1, b, None, false, CloseWhen::Never)
            .unwrap();
        layout.close_pane(p1).unwrap();
        assert_eq!(windows(&layout, session), [vec![a]], "b was in front");
        assert_eq!(tiled_leaves(&layout, session), [b]);
        layout.close_pane(a).unwrap();
        assert!(windows(&layout, session).is_empty());
        check_floats(&layout);
    }

    #[test]
    fn minimizing_hands_focus_to_the_tiled_panes_and_frames_stay_inside() {
        let mut layout = Layout::default();
        let (session, _, [p1, p2, _]) = three(&mut layout);
        layout.float_pane(p2, None).unwrap();
        layout.focus(p2).unwrap();
        let before = revision(&layout, session);
        layout.set_float(p2, None, Some(true), Some(true)).unwrap();
        assert_eq!(layout.focused_pane(session), Some(p1));
        assert!(revision(&layout, session) > before);
        let window = &layout.floats(session).unwrap().floats[0];
        assert!(window.minimized && window.pinned);
        let before = revision(&layout, session);
        layout.set_float(p2, None, Some(true), None).unwrap();
        assert_eq!(revision(&layout, session), before, "no change, no bump");

        let frame = FloatFrame {
            x: 0.95,
            y: -1.0,
            w: 0.5,
            h: 0.01,
        };
        layout.set_float(p2, Some(frame), None, None).unwrap();
        let window = &layout.floats(session).unwrap().floats[0];
        assert_eq!(
            window.frame,
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
            layout.set_float(p2, Some(nan), None, None),
            Err(OpError::Invalid)
        );
        assert_eq!(
            layout.set_float(p1, None, Some(true), None),
            Err(OpError::Invalid)
        );
    }

    #[test]
    fn focus_moves_within_its_own_layer() {
        let mut layout = Layout::default();
        let (session, tab, [p1, p2, p3]) = three(&mut layout);
        layout.float_pane(p2, None).unwrap();
        layout.focus(p1).unwrap();
        layout.focus_direction(tab, Direction::Right).unwrap();
        assert_eq!(
            layout.focused_pane(session),
            Some(p3),
            "over the floated pane's slot"
        );
        let g = layout.alloc_pane();
        layout.split(p2, Axis::Vertical, g).unwrap();
        layout.focus_direction(tab, Direction::Up).unwrap();
        assert_eq!(layout.focused_pane(session), Some(p2));
        layout.focus_direction(tab, Direction::Left).unwrap();
        assert_eq!(layout.focused_pane(session), Some(p2), "the window's edge");
    }

    #[test]
    fn merging_a_tab_docks_its_windows_and_breaking_out_leaves_one() {
        let mut layout = Layout::default();
        let (session, _, [p1, p2, _]) = three(&mut layout);
        let q = layout.alloc_pane();
        let t2 = layout.new_tab(session, String::new(), q).unwrap();
        let floating = layout.alloc_pane();
        layout
            .new_float(q, floating, None, false, CloseWhen::Never)
            .unwrap();
        layout.float_pane(p2, None).unwrap();
        layout.merge_tab(t2, p1, Direction::Down).unwrap();
        assert_eq!(windows(&layout, session), [vec![p2]]);
        let g = layout.alloc_pane();
        layout.split(p2, Axis::Vertical, g).unwrap();
        layout.break_pane(g).unwrap();
        assert_eq!(windows(&layout, session), [vec![p2]]);
        check_floats(&layout);
    }

    #[test]
    fn panes_move_to_a_whole_edge_of_the_tiled_panes() {
        let mut layout = Layout::default();
        let (session, tab, [p1, p2, p3]) = three(&mut layout);
        let f = layout.alloc_pane();
        layout
            .new_float(p1, f, None, false, CloseWhen::Never)
            .unwrap();
        layout.move_pane_to_edge(f, tab, Direction::Down).unwrap();
        assert!(windows(&layout, session).is_empty(), "out of its window");
        let root = layout.snapshot(session).unwrap().tabs[0].root.clone();
        let LayoutNode::Split {
            axis: Axis::Vertical,
            second,
            ..
        } = &root
        else {
            panic!("{root:?}")
        };
        assert_eq!(**second, LayoutNode::Leaf(f));
        assert_eq!(tiled_leaves(&layout, session), [p1, p2, p3, f]);
        layout.move_pane_to_edge(p3, tab, Direction::Left).unwrap();
        assert_eq!(tiled_leaves(&layout, session)[0], p3);
        assert_eq!(layout.focused_pane(session), Some(p3));
        assert_eq!(
            layout.move_pane_to_edge(p3, TabId(99), Direction::Left),
            Err(OpError::NotFound)
        );
        check_floats(&layout);
    }

    #[test]
    fn dividers_move_only_within_the_panes_own_layer() {
        let mut layout = Layout::default();
        // (p1 | p2) | p3, with p2 floating: on screen p1 | p3.
        let (session, _, p1) = session_with(&mut layout);
        let p3 = layout.alloc_pane();
        layout.split(p1, Axis::Horizontal, p3).unwrap();
        let p2 = layout.alloc_pane();
        layout.split(p1, Axis::Horizontal, p2).unwrap();
        layout.float_pane(p2, None).unwrap();
        layout.resize(p1, Axis::Horizontal, 0.1).unwrap();
        let root = layout.snapshot(session).unwrap().tabs[0].root.clone();
        let LayoutNode::Split { ratio, first, .. } = &root else {
            panic!()
        };
        assert!(
            (ratio - 0.6).abs() < 1e-6,
            "the divider on screen moved: {ratio}"
        );
        let LayoutNode::Split { ratio: hidden, .. } = **first else {
            panic!()
        };
        assert!(
            (hidden - 0.5).abs() < 1e-6,
            "the floated pane's split stays"
        );
        // Inside a window its own splits move.
        let g = layout.alloc_pane();
        layout.split(p2, Axis::Horizontal, g).unwrap();
        layout.resize(p2, Axis::Horizontal, 0.2).unwrap();
        let window = layout.window_of(p2).unwrap();
        let tab = &layout.snapshot(session).unwrap().tabs[0];
        let LayoutNode::Split { ratio, .. } = subtree(&tab.root, &window.panes).unwrap() else {
            panic!()
        };
        assert!((ratio - 0.7).abs() < 1e-6);
    }

    #[test]
    fn floats_survive_a_save_and_load() {
        let mut layout = Layout::default();
        let (_, _, [_, p2, _]) = three(&mut layout);
        layout.float_pane(p2, None).unwrap();
        let json = serde_json::to_string(&layout).unwrap();
        let loaded: Layout = serde_json::from_str(&json).unwrap();
        assert_eq!(loaded, layout);
    }

    #[test]
    fn layouts_saved_before_projects_still_load() {
        let mut layout = Layout::default();
        session_with(&mut layout);
        let mut json = serde_json::to_value(&layout).unwrap();
        for session in json["sessions"].as_array_mut().unwrap() {
            let session = session.as_object_mut().unwrap();
            for key in ["projects", "tab_projects", "floats", "next_float"] {
                assert!(session.remove(key).is_some(), "{key}");
            }
        }
        let loaded: Layout = serde_json::from_value(json).unwrap();
        assert_eq!(loaded, layout);
    }

    #[test]
    fn leaves_walk_left_to_right_and_find_each_pane() {
        let mut layout = Layout::default();
        let (session, _, p1) = session_with(&mut layout);
        let p2 = layout.alloc_pane();
        layout.split(p1, Axis::Horizontal, p2).unwrap();
        let p3 = layout.alloc_pane();
        layout.split(p1, Axis::Vertical, p3).unwrap();
        let p4 = layout.alloc_pane();
        layout.split(p2, Axis::Vertical, p4).unwrap();
        let tab = &layout.session(session).unwrap().tabs[0];
        assert_eq!(leaves(&tab.root).collect::<Vec<_>>(), vec![p1, p3, p2, p4]);
        for pane in [p1, p2, p3, p4] {
            assert!(has_leaf(&tab.root, pane));
            assert_eq!(layout.session_of_pane(pane), Some(session));
        }
        assert!(!has_leaf(&tab.root, PaneId(999)));
        assert_eq!(layout.session_of_pane(PaneId(999)), None);
    }

    /// Cost of the pane lookups every event pays per client, with 400 panes: 300 one-pane tabs
    /// and 25 tabs of four splits, in two sessions. `cargo test --release -p daemon
    /// layout::tests::pane_lookup_cost -- --ignored --nocapture`
    #[test]
    #[ignore = "timing; run by hand"]
    fn pane_lookup_cost() {
        let mut layout = Layout::default();
        let (first, _, _) = session_with(&mut layout);
        let second_pane = layout.alloc_pane();
        let (second, _) = layout.create_session("second".into(), second_pane).unwrap();
        let mut panes = Vec::new();
        for i in 0..300 {
            let pane = layout.alloc_pane();
            let session = if i % 2 == 0 { first } else { second };
            layout.new_tab(session, String::new(), pane).unwrap();
            panes.push(pane);
        }
        for _ in 0..25 {
            let pane = layout.alloc_pane();
            layout.new_tab(first, String::new(), pane).unwrap();
            panes.push(pane);
            let mut last = pane;
            for axis in [Axis::Horizontal, Axis::Vertical, Axis::Horizontal] {
                let next = layout.alloc_pane();
                layout.split(last, axis, next).unwrap();
                panes.push(next);
                last = next;
            }
        }
        let lookups = 200_000;
        let start = std::time::Instant::now();
        let mut found = 0;
        for i in 0..lookups {
            let pane = panes[(i * 7919) % panes.len()];
            if layout.session_of_pane(pane).is_some() {
                found += 1;
            }
            if layout.tab_of_pane(pane).is_some() {
                found += 1;
            }
        }
        assert_eq!(found, lookups * 2);
        let nanos = start.elapsed().as_nanos() as f64 / (lookups * 2) as f64;
        println!("pane lookup with {} panes: {nanos:.0} ns", panes.len() + 2);
    }
}
