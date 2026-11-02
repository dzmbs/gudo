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
    Actor, AgentState, AgentStatus, Blocker, DecisionOption, Decided, Decide, DriveAction,
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

const OPTIONS: [(OptionId, &str); 3] = [
    (DriveAsk::ALLOW_ONCE, "Allow once"),
    (DriveAsk::ALLOW_PANE, "Allow for this pane until it closes"),
    (DriveAsk::DENY, "Deny"),
];

/// The label of a drive request's option.
pub(crate) fn option_label(option: OptionId) -> Option<&'static str> {
    OPTIONS.iter().find(|(id, _)| *id == option).map(|(_, l)| *l)
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
    pub fn open(&self, ask: DriveAsk, title: String) -> oneshot::Receiver<Answer> {
        let (reply, rx) = oneshot::channel();
        let action = describe(&ask.action);
        lock(&self.open).insert(
            ask.request_id,
            Open {
                ask,
                title,
                action,
                reply,
            },
        );
        rx
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
            options: OPTIONS
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
    core.emit(Event::Approval(proto::ApprovalPush::Drive(DrivePush::Closed {
        request_id,
    })));
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

/// `type into`, `run a command in`, …
pub(crate) fn verb(action: &DriveAction) -> &'static str {
    match action {
        DriveAction::Type { .. } => "type into",
        DriveAction::Run { .. } => "run a command in",
        DriveAction::Prompt { .. } => "prompt the agent in",
        DriveAction::Close => "close",
    }
}

/// The action exactly, in words: what is typed, run or sent.
pub(crate) fn describe(action: &DriveAction) -> String {
    match action {
        DriveAction::Type { text, keys, submit } => {
            let mut parts = Vec::new();
            if let Some(text) = text.as_deref().filter(|t| !t.is_empty()) {
                parts.push(format!("“{}”", visible_controls(text)));
            }
            if !keys.is_empty() {
                parts.push(format!("keys {}", keys.join(" ")));
            }
            if *submit {
                parts.push("then Return".into());
            }
            if parts.is_empty() {
                "nothing".into()
            } else {
                format!("Type {}", parts.join(", "))
            }
        }
        DriveAction::Run { command } => format!("Run $ {}", visible_controls(command)),
        DriveAction::Prompt { text } => format!("Prompt “{}”", visible_controls(text)),
        DriveAction::Close => "Close the pane".into(),
    }
}

/// Control characters shown as `^X` and newlines as `⏎`, so what is shown is what is typed and
/// nothing can hide behind an escape sequence or a line break.
fn visible_controls(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\n' | '\r' => out.push('⏎'),
            '\t' => out.push('⇥'),
            c if (c as u32) < 0x20 => {
                out.push('^');
                out.push(char::from(c as u8 + b'@'));
            }
            '\u{7f}' => out.push_str("^?"),
            // Bidi controls and other invisible formatting could reorder what is shown.
            c if is_invisible(c) => out.push_str(&format!("<U+{:04X}>", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn is_invisible(c: char) -> bool {
    matches!(c,
        '\u{80}'..='\u{9f}'
        | '\u{200b}'..='\u{200f}'
        | '\u{202a}'..='\u{202e}'
        | '\u{2060}'..='\u{2069}'
        | '\u{feff}')
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
    fn actions_show_what_is_typed() {
        let typed = DriveAction::Type {
            text: Some("rm -rf build\n\x1b[2K".into()),
            keys: vec!["ctrl+c".into()],
            submit: true,
        };
        assert_eq!(
            describe(&typed),
            "Type “rm -rf build⏎^[[2K”, keys ctrl+c, then Return"
        );
        let hidden = DriveAction::Run {
            command: "echo safe\u{202e}fr- mr".into(),
        };
        assert_eq!(describe(&hidden), "Run $ echo safe<U+202E>fr- mr");
    }

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
        let mut rx = asks.open(ask(7), "t".into());
        assert_eq!(asks.blocker(PaneId(1)).unwrap().options.len(), 3);
        assert_eq!(asks.facts(RequestId(7)).unwrap().tool, "pane_close");
        asks.forget_pane(PaneId(2));
        assert!(rx.try_recv().is_err(), "closing the target withdraws the request");
        assert!(asks.caller_of(RequestId(7)).is_none());
        let _rx = asks.open(ask(8), "t".into());
        assert!(asks.withdraw(RequestId(8)));
        assert!(!asks.withdraw(RequestId(8)));
    }
}
