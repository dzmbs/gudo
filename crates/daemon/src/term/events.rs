//! The event stream for agents and scripts (`events_wait`, `proto::script`): panes opening and
//! closing, commands starting and finishing, agents changing state, layouts changing.
//!
//! One ring for the daemon, fed from the core's broadcast; each caller sees its own session's
//! events only, so a subscriber learns nothing it could not read with `pane_list`.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::{PaneId, ScriptEvent, ScriptEventKind, SessionId};
use tokio::sync::Notify;
use tokio::sync::broadcast::error::RecvError;

use crate::core::{Core, Event, lock};

/// Events kept for subscribers that read late.
const KEEP: usize = 1024;

#[derive(Default)]
struct Ring {
    /// `(session, event)`, oldest first; `None` is for every session.
    events: VecDeque<(Option<SessionId>, ScriptEvent)>,
    /// The `seq` the next event gets.
    next: u64,
    panes: HashMap<PaneId, SessionId>,
    /// Each pane's last reported state, `(state, kind, app)`.
    states: HashMap<PaneId, (String, Option<String>, Option<String>)>,
}

impl Ring {
    fn push(&mut self, session: Option<SessionId>, pane: Option<PaneId>, kind: ScriptEventKind) {
        // A vanished pane has no session, not permission to broadcast its data.
        if session.is_none() && (pane.is_some() || !matches!(kind, ScriptEventKind::Lost { .. })) {
            return;
        }
        let event = ScriptEvent {
            v: proto::SCRIPT_EVENTS_VERSION,
            seq: self.next,
            at: crate::identity::now_millis(),
            session: session.map(proto::session_ref),
            pane: pane.map(proto::pane_ref),
            kind,
        };
        self.next += 1;
        self.events.push_back((session, event));
        if self.events.len() > KEEP {
            self.events.pop_front();
        }
    }
}

#[derive(Default)]
pub(crate) struct Feed {
    ring: Mutex<Ring>,
    arrived: Notify,
}

pub(crate) struct Page {
    pub events: Vec<ScriptEvent>,
    pub cursor: u64,
}

impl Feed {
    fn record(&self, update: impl FnOnce(&mut Ring)) {
        update(&mut lock(&self.ring));
        self.arrived.notify_waiters();
    }

    /// The events of `session` from `since` (default: from now), waiting up to `wait` for the
    /// first one. Starts with `events.lost` when some had already been dropped.
    pub async fn read(
        &self,
        session: Option<SessionId>,
        since: Option<u64>,
        wanted: impl Fn(&ScriptEventKind) -> bool,
        max: usize,
        wait: Duration,
    ) -> Page {
        let deadline = tokio::time::Instant::now() + wait;
        let mut since = since.unwrap_or_else(|| lock(&self.ring).next);
        loop {
            let arrived = self.arrived.notified();
            let page = self.page(session, &mut since, &wanted, max);
            if !page.events.is_empty() {
                return page;
            }
            if tokio::time::timeout_at(deadline, arrived).await.is_err() {
                return page;
            }
        }
    }

    fn page(
        &self,
        session: Option<SessionId>,
        since: &mut u64,
        wanted: &impl Fn(&ScriptEventKind) -> bool,
        max: usize,
    ) -> Page {
        let ring = lock(&self.ring);
        let oldest = ring
            .events
            .front()
            .map_or(ring.next, |(_, event)| event.seq);
        let mut events = Vec::new();
        if *since < oldest {
            events.push(ScriptEvent {
                v: proto::SCRIPT_EVENTS_VERSION,
                seq: oldest.saturating_sub(1),
                at: crate::identity::now_millis(),
                session: None,
                pane: None,
                kind: ScriptEventKind::Lost {
                    missed: oldest - *since,
                },
            });
            *since = oldest;
        }
        let from = (*since).max(oldest).min(ring.next);
        let mut cursor = from;
        for (scope, event) in ring.events.iter().filter(|(_, event)| event.seq >= from) {
            if events.len() >= max {
                break;
            }
            cursor = event.seq + 1;
            if (scope.is_none() || *scope == session) && wanted(&event.kind) {
                events.push(event.clone());
            }
        }
        *since = cursor;
        Page { events, cursor }
    }
}

pub(crate) fn type_name(kind: &ScriptEventKind) -> &'static str {
    match kind {
        ScriptEventKind::PaneOpened { .. } => "pane.opened",
        ScriptEventKind::PaneClosed => "pane.closed",
        ScriptEventKind::CommandStarted { .. } => "command.started",
        ScriptEventKind::CommandFinished { .. } => "command.finished",
        ScriptEventKind::AgentState { .. } => "agent.state",
        ScriptEventKind::LayoutChanged => "layout.changed",
        ScriptEventKind::Lost { .. } => "events.lost",
    }
}

pub(crate) async fn run(core: Arc<Core>) {
    let mut events = core.events.subscribe();
    let feed = &core.term.events;
    let panes = lock(&core.layout).all_panes();
    feed.record(|ring| {
        for pane in panes {
            if let Some(session) = core.session_of_pane(pane) {
                ring.panes.insert(pane, session);
            }
            if let Some(state) = state_of(&core, pane) {
                ring.states.insert(pane, state);
            }
        }
    });
    loop {
        match events.recv().await {
            Ok(event) => on_event(&core, event),
            Err(RecvError::Lagged(missed)) => {
                feed.record(|ring| ring.push(None, None, ScriptEventKind::Lost { missed }));
            }
            Err(RecvError::Closed) => return,
        }
    }
}

fn on_event(core: &Core, event: Event) {
    let feed = &core.term.events;
    match event {
        Event::Layout(session) => {
            let Some(layout) = lock(&core.layout).snapshot(session) else {
                return;
            };
            feed.record(|ring| {
                for tab in &layout.tabs {
                    for pane in crate::layout::leaves(&tab.root) {
                        if ring.panes.insert(pane, session).is_none() {
                            let tab = Some(proto::tab_ref(tab.tab_id));
                            ring.push(
                                Some(session),
                                Some(pane),
                                ScriptEventKind::PaneOpened { tab },
                            );
                        }
                    }
                }
                ring.push(Some(session), None, ScriptEventKind::LayoutChanged);
            });
        }
        Event::PaneClosed(pane) => feed.record(|ring| {
            ring.states.remove(&pane);
            if let Some(session) = ring.panes.remove(&pane) {
                ring.push(Some(session), Some(pane), ScriptEventKind::PaneClosed);
            }
        }),
        Event::Command(mark) => {
            let session = core.session_of_pane(mark.pane_id);
            let kind = match mark.finished {
                None => ScriptEventKind::CommandStarted {
                    id: mark.command_id,
                    command: mark.command,
                    cwd: mark.cwd,
                },
                Some(finished) => ScriptEventKind::CommandFinished {
                    id: mark.command_id,
                    command: mark.command,
                    exit_code: finished.exit,
                    duration_ms: finished.duration_ms,
                },
            };
            feed.record(|ring| ring.push(session, Some(mark.pane_id), kind));
        }
        Event::PaneMeta(pane) | Event::ProgramStatus(pane) => {
            let current = state_of(core, pane);
            let session = core.session_of_pane(pane);
            feed.record(|ring| {
                let changed = match &current {
                    Some(current) => ring.states.get(&pane) != Some(current),
                    None => ring.states.contains_key(&pane),
                };
                if !changed {
                    return;
                }
                let (state, kind, app) = match &current {
                    Some(current) => {
                        ring.states.insert(pane, current.clone());
                        current.clone()
                    }
                    None => {
                        ring.states.remove(&pane);
                        ("none".to_owned(), None, None)
                    }
                };
                ring.push(
                    session,
                    Some(pane),
                    ScriptEventKind::AgentState { state, kind, app },
                );
            });
        }
        _ => {}
    }
}

/// What the program in `pane` reports about itself, as `pane_list` shows it.
fn state_of(core: &Core, pane: PaneId) -> Option<(String, Option<String>, Option<String>)> {
    let entry = core.pane(pane)?;
    let status = super::status(core, pane, &entry);
    let text = |key: &str| {
        status
            .get(key)
            .and_then(|value| value.as_str())
            .map(str::to_owned)
    };
    Some((text("state")?, text("kind"), text("app")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed_with(count: u64, session: SessionId) -> Feed {
        let feed = Feed::default();
        feed.record(|ring| {
            for _ in 0..count {
                ring.push(Some(session), None, ScriptEventKind::LayoutChanged);
            }
        });
        feed
    }

    #[tokio::test]
    async fn missing_pane_scope_never_makes_private_events_daemon_wide() {
        let feed = Feed::default();
        feed.record(|ring| {
            for kind in [
                ScriptEventKind::CommandStarted {
                    id: 1,
                    command: Some("private command".into()),
                    cwd: Some("/private/fixture".into()),
                },
                ScriptEventKind::CommandFinished {
                    id: 1,
                    command: Some("private command".into()),
                    exit_code: Some(7),
                    duration_ms: 1,
                },
                ScriptEventKind::AgentState {
                    state: "working".into(),
                    kind: None,
                    app: Some("claude".into()),
                },
                ScriptEventKind::Lost { missed: 1 },
            ] {
                ring.push(None, Some(PaneId(42)), kind);
            }
            ring.push(Some(SessionId(1)), None, ScriptEventKind::LayoutChanged);
            ring.push(None, None, ScriptEventKind::Lost { missed: 1 });
        });
        let mine = feed
            .read(Some(SessionId(1)), Some(0), |_| true, 10, Duration::ZERO)
            .await;
        assert_eq!(mine.events.len(), 2, "{:?}", mine.events);
        let other = feed
            .read(Some(SessionId(2)), Some(0), |_| true, 10, Duration::ZERO)
            .await;
        assert_eq!(other.events.len(), 1, "{:?}", other.events);
        assert!(matches!(
            other.events[0].kind,
            ScriptEventKind::Lost { missed: 1 }
        ));
    }

    #[tokio::test]
    async fn a_late_reader_is_told_what_it_missed() {
        let mine = SessionId(1);
        let feed = feed_with(KEEP as u64 + 10, mine);
        let page = feed
            .read(Some(mine), Some(0), |_| true, 5, Duration::ZERO)
            .await;
        assert_eq!(
            page.events[0].kind,
            ScriptEventKind::Lost { missed: 10 },
            "the first ten were dropped"
        );
        assert_eq!(page.events[1].seq, 10);
        assert_eq!(page.cursor, 14);
    }

    #[tokio::test]
    async fn another_sessions_events_are_skipped_not_shown() {
        let feed = feed_with(3, SessionId(2));
        let page = feed
            .read(Some(SessionId(1)), Some(0), |_| true, 10, Duration::ZERO)
            .await;
        assert!(page.events.is_empty());
        assert_eq!(page.cursor, 3, "the reader moves past what it may not see");
    }
}
