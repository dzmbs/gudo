use super::Live;
use crate::core::{Core, PaneEntry, lock};
use agents::{
    Claim, CodexApprovalKind, CodexLiveEvent, CodexRpcId, CodexTurnOutcome, Confidence, EventKind,
    Signal, Source,
};
use std::path::PathBuf;
use std::sync::{Arc, Weak};

#[derive(Clone)]
pub(super) struct Owner {
    pub root: u32,
    pub(super) core: Weak<Core>,
    pub(super) entry: Weak<PaneEntry>,
}

pub(super) enum Effect {
    Bound(String, Option<PathBuf>),
    Started,
    Completed(CodexTurnOutcome),
    Waiting(
        CodexRpcId,
        CodexApprovalKind,
        Box<agents::CodexApprovalDetails>,
    ),
    Resolved(CodexRpcId),
    Lost,
    Hydrate(agents::CodexThreadBinding),
    Ready,
}

impl Effect {
    pub(super) fn from_event(event: &CodexLiveEvent) -> Option<Self> {
        match event {
            CodexLiveEvent::TurnStarted { .. } => Some(Self::Started),
            CodexLiveEvent::TurnCompleted { outcome, .. } => Some(Self::Completed(*outcome)),
            CodexLiveEvent::ApprovalWaiting {
                request,
                kind,
                details,
                ..
            } => Some(Self::Waiting(request.clone(), *kind, details.clone())),
            CodexLiveEvent::ApprovalResolved { request, .. } => {
                Some(Self::Resolved(request.clone()))
            }
            _ => None,
        }
    }
}

#[derive(Default)]
pub(super) struct Runtime {
    pub cwd: Option<PathBuf>,
    thread: Option<String>,
    pub(super) pending: Vec<Pending>,
}

pub(super) struct Pending {
    pub id: CodexRpcId,
    pub kind: CodexApprovalKind,
    pub details: Box<agents::CodexApprovalDetails>,
    pub common: Option<agents::RequestId>,
    pub admitted: bool,
}

impl Pending {
    pub(super) fn tool(&self) -> &'static str {
        match self.kind {
            CodexApprovalKind::Command if self.details.is_plain_command() => "Bash",
            CodexApprovalKind::Command => "Codex permissions",
            CodexApprovalKind::FileChange => "Edit",
        }
    }
}

impl Runtime {
    fn apply(&mut self, effect: Effect) -> Option<Signal> {
        let (kind, claim, outcome) = match effect {
            Effect::Bound(thread, cwd) => {
                self.thread = Some(thread);
                if let Some(cwd) = cwd {
                    self.cwd = Some(cwd);
                }
                self.pending.clear();
                (EventKind::SessionStarted, Claim::Idle, None)
            }
            Effect::Started => {
                self.pending.clear();
                (EventKind::TurnStarted, Claim::Working, None)
            }
            Effect::Completed(outcome) => {
                self.pending.clear();
                match outcome {
                    CodexTurnOutcome::Completed => (
                        EventKind::TurnEnded,
                        Claim::Idle,
                        Some(agents::TurnOutcome::Completed),
                    ),
                    CodexTurnOutcome::Interrupted => (
                        EventKind::Interrupted,
                        Claim::Idle,
                        Some(agents::TurnOutcome::Cancelled),
                    ),
                    CodexTurnOutcome::Failed => (
                        EventKind::Error,
                        Claim::Error,
                        Some(agents::TurnOutcome::Failed),
                    ),
                    CodexTurnOutcome::Unknown => (EventKind::Error, Claim::Error, None),
                }
            }
            Effect::Waiting(request, kind, details) => {
                self.pending.push(Pending {
                    id: request,
                    kind,
                    details,
                    common: None,
                    admitted: false,
                });
                if self.pending.len() > 1 {
                    return None;
                }
                (EventKind::Blocked, self.claim(), None)
            }
            Effect::Resolved(request) => {
                let first = self
                    .pending
                    .first()
                    .is_some_and(|pending| pending.id == request);
                self.pending.retain(|pending| pending.id != request);
                if !first {
                    return None;
                }
                let kind = if self.pending.is_empty() {
                    EventKind::Unblocked
                } else {
                    EventKind::Blocked
                };
                (kind, self.claim(), None)
            }
            Effect::Lost => {
                self.pending.clear();
                (EventKind::Stale, Claim::Release, None)
            }
            Effect::Hydrate(_) | Effect::Ready => return None,
        };
        let mut signal =
            Signal::new(Source::Structured, Confidence::Authoritative, kind).with_claim(claim);
        signal.session.native_id = self.thread.clone().map(agents::NativeSessionId::new);
        signal.session.cwd.clone_from(&self.cwd);
        signal.turn = outcome.map(|outcome| agents::Turn {
            outcome,
            last_message: None,
        });
        Some(signal)
    }

    fn claim(&self) -> Claim {
        let Some(pending) = self.pending.first() else {
            return Claim::Working;
        };
        let mut blocker = agents::Blocker::new(agents::BlockedReason::Permission);
        blocker.tool = Some(pending.tool().into());
        let summary = if pending.kind == CodexApprovalKind::FileChange {
            format!(
                "File changes. Review the proposed edits in Terminal.\n{}",
                pending.details.summary()
            )
        } else {
            pending.details.summary()
        };
        blocker.answer_paths.push(agents::AnswerPath::AppServer);
        blocker.detail = Some(serde_json::json!({"request":pending.id,"context":summary}));
        if summary.chars().count() <= 500 {
            blocker.summary = Some(summary);
            let supported = match pending.kind {
                CodexApprovalKind::Command => pending.details.is_supported_command(),
                CodexApprovalKind::FileChange => pending.details.is_file_change(),
            };
            if supported && pending.details.offers("accept") {
                blocker.options.push(agents::ApprovalOption::new(
                    agents::ApprovalChoice::AllowOnce,
                    if pending.kind == CodexApprovalKind::FileChange {
                        "Allow file changes once"
                    } else {
                        "Allow once"
                    },
                ));
            }
            if let Some(denial) = pending.details.denial() {
                blocker.options.push(agents::ApprovalOption::new(
                    agents::ApprovalChoice::Deny,
                    if denial == "cancel" {
                        "Cancel turn"
                    } else {
                        "Deny"
                    },
                ));
            }
        } else {
            blocker.summary = Some("Approval request is too long. Answer in Terminal.".into());
        }
        Claim::Blocked(blocker)
    }
}

impl Live {
    pub(crate) fn set_owner(&self, core: &Arc<Core>, entry: &Arc<PaneEntry>) {
        self.owner.send_replace(Some(Owner {
            root: entry.pane.pty().pid(),
            core: Arc::downgrade(core),
            entry: Arc::downgrade(entry),
        }));
    }

    pub(super) fn capture_context(self: &Arc<Self>, cwd: PathBuf, tui: u32) {
        lock(&self.runtime).cwd = Some(cwd);
        if let Some((_, entry)) = self.target()
            && let Some(runtime) = lock(&entry.agent).as_mut()
        {
            runtime.note_process(tui);
        }
    }

    pub(super) fn target(self: &Arc<Self>) -> Option<(Arc<Core>, Arc<PaneEntry>)> {
        let owner = self.owner.borrow().clone()?;
        let (core, entry) = (owner.core.upgrade()?, owner.entry.upgrade()?);
        if !core
            .pane(entry.pane.id)
            .is_some_and(|current| Arc::ptr_eq(&current, &entry))
            || !lock(&entry.codex)
                .as_ref()
                .is_some_and(|current| Arc::ptr_eq(current, self))
        {
            return None;
        }
        Some((core, entry))
    }

    pub(super) fn publish(self: &Arc<Self>, effects: Vec<Effect>) {
        if effects.is_empty() {
            return;
        }
        let Some((core, entry)) = self.target() else {
            return;
        };
        for effect in effects {
            if let Effect::Hydrate(binding) = effect {
                self.load_history(binding);
                continue;
            }
            let Some(signal) = lock(&self.runtime).apply(effect) else {
                core.emit(crate::core::Event::PaneMeta(entry.pane.id));
                continue;
            };
            let blocked = signal.kind == EventKind::Blocked;
            let event = {
                let mut gate = lock(&entry.pane.agent_input_gate);
                if signal.kind == EventKind::TurnStarted
                    && let Some(session) = &signal.session.native_id
                {
                    gate.native_turn(session.as_str());
                }
                let mut agent = lock(&entry.agent);
                let event = agent
                    .as_mut()
                    .and_then(|runtime| runtime.structured_signal(signal));
                if let Some(detail) = agent.as_mut().and_then(|runtime| runtime.blocked_detail())
                    && let Some(pending) = lock(&self.runtime).pending.first_mut()
                {
                    pending.common = Some(detail.request);
                }
                event
            };
            core.agent_event(entry.pane.id, event);
            if blocked {
                crate::approve::request_held(&core, entry.pane.id);
            }
        }
    }
}

#[cfg(test)]
mod tests;
