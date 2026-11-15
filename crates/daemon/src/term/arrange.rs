//! What a layout tool changed, as its result's `effects` list it: every pane whose tab, floating
//! window, frame or focus differs from before the call.

use std::collections::{BTreeMap, BTreeSet};

use proto::{FloatFrame, PaneId, SessionId, TabId};
use serde_json::{Value, json};

use super::{frame_json, pane_ref, tab_ref};
use crate::layout::{Layout, leaves};

#[derive(Debug, Clone, Copy, PartialEq)]
struct Window {
    frame: FloatFrame,
    minimized: bool,
    pinned: bool,
}

/// Where a pane is: its tab, the window it floats in, and whether it has its tab's focus.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Placement {
    tab: TabId,
    window: Option<Window>,
    focused: bool,
}

impl Placement {
    fn to_json(self) -> Value {
        json!({
            "tab": tab_ref(self.tab),
            "floating": self.window.is_some(),
            "frame": self.window.map(|window| frame_json(window.frame)),
            "minimized": self.window.is_some_and(|window| window.minimized),
            "pinned": self.window.is_some_and(|window| window.pinned),
            "focused": self.focused,
        })
    }
}

pub(super) type Placements = BTreeMap<PaneId, Placement>;

/// Every pane of `session` and where it is.
pub(super) fn placements(layout: &Layout, session: SessionId) -> Placements {
    let Some(session) = layout.session(session) else {
        return Placements::new();
    };
    let mut placements = Placements::new();
    for tab in &session.tabs {
        for pane in leaves(&tab.root) {
            let window = session
                .floats
                .iter()
                .find(|window| window.panes.contains(&pane))
                .map(|window| Window {
                    frame: window.frame,
                    minimized: window.minimized,
                    pinned: window.pinned,
                });
            let placement = Placement {
                tab: tab.tab_id,
                window,
                focused: tab.focused == pane,
            };
            placements.insert(pane, placement);
        }
    }
    placements
}

/// The panes placed differently in `after` than in `before`, with what changed.
pub(super) fn effects(before: &Placements, after: &Placements) -> Vec<Value> {
    let panes: BTreeSet<PaneId> = before.keys().chain(after.keys()).copied().collect();
    panes
        .into_iter()
        .filter_map(|pane| {
            let was = before.get(&pane).copied();
            let now = after.get(&pane).copied();
            let changes = changes(was, now);
            (!changes.is_empty()).then(|| {
                json!({
                    "pane": pane_ref(pane),
                    "changes": changes,
                    "was": was.map(Placement::to_json),
                    "now": now.map(Placement::to_json),
                })
            })
        })
        .collect()
}

fn changes(was: Option<Placement>, now: Option<Placement>) -> Vec<&'static str> {
    let (was, now) = match (was, now) {
        (None, None) => return Vec::new(),
        (None, Some(_)) => return vec!["opened"],
        (Some(_), None) => return vec!["closed"],
        (Some(was), Some(now)) => (was, now),
    };
    let mut changes = Vec::new();
    if was.tab != now.tab {
        changes.push("tab");
    }
    let window_state = |placement: Placement| {
        placement
            .window
            .map(|window| (window.minimized, window.pinned))
    };
    if window_state(was) != window_state(now) {
        changes.push("float");
    }
    if let (Some(was_window), Some(now_window)) = (was.window, now.window)
        && was_window.frame != now_window.frame
    {
        changes.push("frame");
    }
    if was.focused != now.focused {
        changes.push("focus");
    }
    changes
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tiled(tab: u64, focused: bool) -> Placement {
        Placement {
            tab: TabId(tab),
            window: None,
            focused,
        }
    }

    fn floating(tab: u64, x: f32) -> Placement {
        Placement {
            tab: TabId(tab),
            window: Some(Window {
                frame: FloatFrame {
                    x,
                    ..FloatFrame::DEFAULT
                },
                minimized: false,
                pinned: false,
            }),
            focused: false,
        }
    }

    #[test]
    fn only_panes_placed_differently_are_listed() {
        let before = Placements::from([
            (PaneId(1), tiled(1, true)),
            (PaneId(2), floating(1, 0.1)),
            (PaneId(3), tiled(1, false)),
        ]);
        let after = Placements::from([
            (PaneId(1), tiled(1, true)),
            (PaneId(2), tiled(2, false)),
            (PaneId(4), floating(1, 0.2)),
        ]);
        let effects = effects(&before, &after);
        let listed: Vec<(&str, Vec<&str>)> = effects
            .iter()
            .map(|effect| {
                (
                    effect["pane"].as_str().unwrap(),
                    effect["changes"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|change| change.as_str().unwrap())
                        .collect(),
                )
            })
            .collect();
        assert_eq!(
            listed,
            [
                ("p2", vec!["tab", "float"]),
                ("p3", vec!["closed"]),
                ("p4", vec!["opened"]),
            ]
        );
        assert_eq!(effects[0]["was"]["tab"], "t1");
        assert_eq!(effects[0]["now"]["tab"], "t2");
        assert!(effects[1]["now"].is_null());
    }

    #[test]
    fn a_moved_window_changes_its_frame_only() {
        assert_eq!(
            changes(Some(floating(1, 0.1)), Some(floating(1, 0.3))),
            ["frame"]
        );
    }
}
