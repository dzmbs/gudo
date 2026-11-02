//! The script event stream (`proto::script`) from what a connection is shown: `gudo events`.
//!
//! The daemon only sends a connection what its grant covers (the attached session, a guest's
//! scope), so the stream holds nothing the connection could not see anyway.

use std::collections::HashMap;

use proto::{
    AgentState, PaneId, SCRIPT_EVENTS_VERSION, ScriptEvent, ScriptEventKind, SessionId, pane_ref,
    session_ref, tab_ref,
};

use crate::{ClientEvent, now_millis};

/// `(state, kind, app)` as `agent.state` reports it.
type State = (String, Option<String>, Option<String>);

/// Turns [`ClientEvent`]s into [`ScriptEvent`]s.
///
/// What is there when the stream starts is not reported as having happened: the first layout
/// of a session and the first state of a pane only set the baseline.
#[derive(Default)]
pub struct EventMapper {
    seq: u64,
    panes: HashMap<PaneId, SessionId>,
    sessions: Vec<SessionId>,
    states: HashMap<PaneId, State>,
}

impl EventMapper {
    /// A mapper with nothing seen yet.
    pub fn new() -> Self {
        Self::default()
    }

    /// The script events `event` means, in order.
    pub fn feed(&mut self, event: &ClientEvent) -> Vec<ScriptEvent> {
        let mut events = Vec::new();
        match event {
            ClientEvent::Layout { layout } => {
                let session = layout.session_id;
                let baseline = !self.sessions.contains(&session);
                if baseline {
                    self.sessions.push(session);
                }
                for tab in &layout.tabs {
                    for pane in leaves(&tab.root) {
                        if self.panes.insert(pane, session).is_none() && !baseline {
                            let tab = Some(tab_ref(tab.tab_id));
                            events.push(self.event(pane, ScriptEventKind::PaneOpened { tab }));
                        }
                    }
                }
                if !baseline {
                    events.push(self.make(Some(session), None, ScriptEventKind::LayoutChanged));
                }
            }
            ClientEvent::PaneClosed { pane_id } => {
                self.states.remove(pane_id);
                if let Some(session) = self.panes.get(pane_id).copied() {
                    let closed =
                        self.make(Some(session), Some(*pane_id), ScriptEventKind::PaneClosed);
                    self.panes.remove(pane_id);
                    events.push(closed);
                }
            }
            ClientEvent::CommandMark { mark } => {
                let kind = match mark.finished {
                    None => ScriptEventKind::CommandStarted {
                        id: mark.command_id,
                        command: mark.command.clone(),
                        cwd: mark.cwd.clone(),
                    },
                    Some(finished) => ScriptEventKind::CommandFinished {
                        id: mark.command_id,
                        command: mark.command.clone(),
                        exit_code: finished.exit,
                        duration_ms: finished.duration_ms,
                    },
                };
                events.push(self.event(mark.pane_id, kind));
            }
            ClientEvent::PaneMeta { meta } => {
                let after = meta.agent.as_ref().map(|agent| {
                    let (state, kind) = match &agent.state {
                        AgentState::Idle => ("idle", None),
                        AgentState::Running => ("working", None),
                        AgentState::Blocked(_) => ("blocked", Some("permission".to_owned())),
                        AgentState::Done => ("done", None),
                    };
                    (state.to_owned(), kind, Some(agent.kind.clone()))
                });
                let before = match &after {
                    Some(after) => self.states.insert(meta.pane_id, after.clone()),
                    None => self.states.remove(&meta.pane_id),
                };
                let first = before.is_none() && after.is_some();
                if before != after && !first {
                    let (state, kind, app) = after.unwrap_or_else(|| ("none".into(), None, None));
                    events.push(self.event(
                        meta.pane_id,
                        ScriptEventKind::AgentState { state, kind, app },
                    ));
                }
            }
            ClientEvent::Disconnected { .. } if !self.sessions.is_empty() => {
                // What happens while away is not replayed: say so (count unknown).
                events.push(self.make(None, None, ScriptEventKind::Lost { missed: 0 }));
            }
            _ => {}
        }
        events
    }

    fn event(&mut self, pane: PaneId, kind: ScriptEventKind) -> ScriptEvent {
        let session = self.panes.get(&pane).copied();
        self.make(session, Some(pane), kind)
    }

    fn make(
        &mut self,
        session: Option<SessionId>,
        pane: Option<PaneId>,
        kind: ScriptEventKind,
    ) -> ScriptEvent {
        self.seq += 1;
        ScriptEvent {
            v: SCRIPT_EVENTS_VERSION,
            seq: self.seq,
            at: now_millis().0,
            session: session.map(session_ref),
            pane: pane.map(pane_ref),
            kind,
        }
    }
}

fn leaves(node: &proto::LayoutNode) -> Vec<PaneId> {
    match node {
        proto::LayoutNode::Leaf(pane_id) => vec![*pane_id],
        proto::LayoutNode::Split { first, second, .. } => {
            let mut panes = leaves(first);
            panes.extend(leaves(second));
            panes
        }
    }
}
