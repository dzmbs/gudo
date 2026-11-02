//! Asking the owner before an agent drives one of the user's panes (`proto::drive`).
//!
//! The asking pane shows as blocked on an ordinary approval request, so the owner answers it
//! like any other: on a card, from the Inbox or from the lock screen, signed by their device.
//! The waiting tool call then does exactly the action that was shown, once; nothing else is
//! unlocked by it except, with "Allow for this pane", later calls from the same pane to the same
//! target until either pane closes.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use proto::{
    Actor, AgentState, AgentStatus, Blocker, Decide, Decided, DecisionOption, DriveAction,
    DriveAsk, DrivePush, OptionId, PaneId, RequestId,
};
use tokio::sync::oneshot;

use crate::core::{Core, Event, lock};

/// Longest action text a notification may carry with Approve and Deny buttons. A longer one
/// is cut, and a cut action is never approved blind from the lock screen.
const NOTIFY_ACTION_CHARS: usize = 400;

/// The owner's answer to a drive request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Answer {
    Once,
    Pane,
    Deny,
}

impl Answer {
    fn of(option: OptionId) -> Option<Self> {
        match option {
            DriveAsk::ALLOW_ONCE => Some(Self::Once),
            DriveAsk::ALLOW_PANE => Some(Self::Pane),
            DriveAsk::DENY => Some(Self::Deny),
            _ => None,
        }
    }
}

/// The label of a drive request's option.
pub(crate) fn option_label(option: OptionId) -> Option<&'static str> {
    DriveAsk::OPTIONS
        .iter()
        .find(|(id, _)| *id == option)
        .map(|(_, l)| *l)
}

struct Open {
    ask: DriveAsk,
    /// `Claude wants to type into ~/api · zsh`.
    title: String,
    /// The exact action, in words.
    action: String,
    reply: oneshot::Sender<Answer>,
}

impl Open {
    fn summary(&self) -> String {
        format!("{}: {}", self.title, self.action)
    }
}

/// Open drive requests and the standing "for this pane" grants.
#[derive(Default)]
pub(crate) struct Asks {
    open: Mutex<HashMap<RequestId, Open>>,
    /// `(caller, target)`: the caller may drive the target until either closes.
    granted: Mutex<HashSet<(PaneId, PaneId)>>,
}

/// What an approval needs to know about an open drive request.
pub(crate) struct Facts {
    pub caller: PaneId,
    pub tool: &'static str,
    pub summary: String,
}

impl Asks {
    pub fn granted(&self, caller: PaneId, target: PaneId) -> bool {
        lock(&self.granted).contains(&(caller, target))
    }

    /// Opens a request; the receiver gets the answer, or closes when the request is withdrawn.
    /// `None` while the same pane already waits on one: an agent cannot queue up questions
    /// (or notifications) faster than the owner answers them.
    pub fn open(&self, ask: DriveAsk) -> Option<oneshot::Receiver<Answer>> {
        let (reply, rx) = oneshot::channel();
        let title = ask.title();
        let action = ask.action.describe();
        let mut open = lock(&self.open);
        if open.values().any(|o| o.ask.pane_id == ask.pane_id) {
            return None;
        }
        open.insert(
            ask.request_id,
            Open {
                ask,
                title,
                action,
                reply,
            },
        );
        Some(rx)
    }

    /// Withdraws a request (expired, the caller hung up); `true` if it was still open.
    pub fn withdraw(&self, id: RequestId) -> bool {
        lock(&self.open).remove(&id).is_some()
    }

    pub fn caller_of(&self, id: RequestId) -> Option<PaneId> {
        lock(&self.open).get(&id).map(|o| o.ask.pane_id)
    }

    pub fn facts(&self, id: RequestId) -> Option<Facts> {
        lock(&self.open).get(&id).map(|o| Facts {
            caller: o.ask.pane_id,
            tool: tool(&o.ask.action),
            summary: o.summary(),
        })
    }

    /// The blocker the asking pane shows while its request is open.
    pub fn blocker(&self, caller: PaneId) -> Option<Blocker> {
        let open = lock(&self.open);
        let o = open.values().find(|o| o.ask.pane_id == caller)?;
        Some(Blocker {
            request_id: o.ask.request_id,
            summary: o.summary(),
            options: DriveAsk::OPTIONS
                .iter()
                .map(|(id, label)| DecisionOption {
                    id: *id,
                    label: (*label).to_owned(),
                })
                .collect(),
        })
    }

    /// Every open request, for a connection that just attached.
    pub fn all(&self) -> Vec<DriveAsk> {
        lock(&self.open).values().map(|o| o.ask.clone()).collect()
    }

    /// The title and body of the request's notification, and whether its body shows the
    /// action whole (only then may it be approved from the lock screen).
    pub fn notice(&self, id: RequestId) -> Option<(String, String, bool)> {
        let open = lock(&self.open);
        let o = open.get(&id)?;
        let whole = o.action.chars().count() <= NOTIFY_ACTION_CHARS;
        let body = if whole {
            o.action.clone()
        } else {
            let cut: String = o.action.chars().take(NOTIFY_ACTION_CHARS).collect();
            format!("{cut}…")
        };
        Some((o.title.clone(), body, whole))
    }

    /// Ends every grant and request that involves `pane`, which closed.
    pub fn forget_pane(&self, pane: PaneId) {
        lock(&self.granted).retain(|&(caller, target)| caller != pane && target != pane);
        // Dropping the reply tells the waiting call the pane is gone.
        lock(&self.open).retain(|_, o| o.ask.pane_id != pane && o.ask.target != pane);
    }

    /// Applies the owner's decision. The request is used up whatever the answer: a replay,
    /// or a second device, finds nothing. `record` runs before the waiting call is told.
    pub fn decide(
        &self,
        core: &Core,
        actor: Actor,
        decide: &Decide,
        record: impl FnOnce(&Decided, &crate::agent::DecidedRequest),
    ) -> Option<Decided> {
        let answer = Answer::of(decide.option_id)?;
        let open = lock(&self.open).remove(&decide.request_id)?;
        let caller = open.ask.pane_id;
        let decided = Decided {
            pane_id: caller,
            request_id: decide.request_id,
            option_id: decide.option_id,
            decided_by: actor,
            at: proto::UnixMillis(crate::identity::now_millis()),
        };
        let label = option_label(decide.option_id).unwrap_or_default();
        record(
            &decided,
            &crate::agent::DecidedRequest {
                choice: match answer {
                    Answer::Once => agents::ApprovalChoice::AllowOnce,
                    Answer::Pane => agents::ApprovalChoice::AllowSession,
                    Answer::Deny => agents::ApprovalChoice::Deny,
                },
                request: agent_request(decide.request_id),
                option: label.to_owned(),
                tool: Some(tool(&open.ask.action).to_owned()),
                summary: open.summary(),
            },
        );
        if answer == Answer::Pane {
            lock(&self.granted).insert((caller, open.ask.target));
        }
        let _ = open.reply.send(answer);
        core.emit(Event::Decided(decided));
        closed(core, decide.request_id, caller);
        Some(decided)
    }
}

/// Tells everyone a request is no longer open.
pub(crate) fn closed(core: &Core, request_id: RequestId, caller: PaneId) {
    core.emit(Event::Approval(proto::ApprovalPush::Drive(
        DrivePush::Closed { request_id },
    )));
    core.emit(Event::PaneMeta(caller));
    crate::ws::agent_unblocked(core, caller);
}

/// The id the audit log and push subjects use for the request.
pub(crate) fn agent_request(id: RequestId) -> agents::RequestId {
    agents::RequestId::new(format!("drive/{}", id.0))
}

/// The tool the request came from.
pub(crate) fn tool(action: &DriveAction) -> &'static str {
    match action {
        DriveAction::Type { .. } => "pane_send",
        DriveAction::Run { .. } => "cmd_run",
        DriveAction::Prompt { .. } => "agent_prompt",
        DriveAction::Close => "pane_close",
    }
}

/// The asking pane's agent status while it waits: blocked on its drive request.
pub(crate) fn status(kind: String, blocker: Blocker) -> AgentStatus {
    AgentStatus {
        kind,
        state: AgentState::Blocked(blocker),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_decision_is_used_once_and_only_by_its_options() {
        let asks = Asks::default();
        let ask = |id| DriveAsk {
            request_id: RequestId(id),
            pane_id: PaneId(1),
            target: PaneId(2),
            agent: "Claude".into(),
            target_label: "~ · zsh".into(),
            action: DriveAction::Close,
            expires_at: proto::UnixMillis(0),
        };
        let mut rx = asks.open(ask(7)).unwrap();
        assert!(
            asks.open(ask(9)).is_none(),
            "one question at a time per pane"
        );
        assert_eq!(asks.blocker(PaneId(1)).unwrap().options.len(), 3);
        assert_eq!(asks.facts(RequestId(7)).unwrap().tool, "pane_close");
        asks.forget_pane(PaneId(2));
        assert!(
            rx.try_recv().is_err(),
            "closing the target withdraws the request"
        );
        assert!(asks.caller_of(RequestId(7)).is_none());
        let _rx = asks.open(ask(8)).unwrap();
        assert!(asks.withdraw(RequestId(8)));
        assert!(!asks.withdraw(RequestId(8)));
    }
}
