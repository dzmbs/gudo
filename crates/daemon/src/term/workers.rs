//! Worker agents as the tools report them: their state, the first prompt held until the agent
//! is ready for it, and the results of workers whose panes closed.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::{AgentKind, PaneId, PaneLaunch};
use serde_json::{Value, json};
use tokio::time::Instant;

use crate::core::{Core, MetaState, PaneEntry, lock};
use crate::turn_message::MessageUnavailable;

use super::{TICK, pane_ref};

/// How long a turn may sit with the agent neither working nor blocked before it counts as
/// stopped without an end (the user interrupted it). A working agent redraws all the time.
const STOPPED_AFTER: std::time::Duration = std::time::Duration::from_secs(30);
/// How long the screen must stay still before the first prompt is typed.
const SETTLE: Duration = Duration::from_millis(400);
/// How long the first prompt waits for an agent that exited (to update itself) to be run
/// again in its pane.
const RERUN_GRACE: Duration = Duration::from_secs(10);
/// How long the first prompt waits for an agent the user has not let start yet (a dialog).
const FIRST_PROMPT_PATIENCE: Duration = Duration::from_secs(15 * 60);
/// Results of closed workers kept for `agent_result` and `agent_wait`, oldest dropped first.
const KEPT_RESULTS: usize = 1024;
/// Lines of the screen a blocked agent's status quotes when nothing else says what it asks.
const EXCERPT_LINES: usize = 8;
const EXCERPT_CHARS: usize = 600;

/// Where a worker's first prompt is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PromptDelivery {
    /// Held until the agent is ready for it.
    Queued,
    /// Typed into the agent.
    Accepted,
    /// Dropped, and why.
    Failed {
        reason: &'static str,
        message: String,
    },
}

impl PromptDelivery {
    fn failed(reason: &'static str, message: impl Into<String>) -> Self {
        Self::Failed {
            reason,
            message: message.into(),
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Accepted => "accepted",
            Self::Failed { .. } => "failed",
        }
    }

    /// Adds `promptDelivery` (and `promptFailure`) to `info`.
    pub fn describe(&self, info: &mut Value) {
        info["promptDelivery"] = json!(self.as_str());
        if let Self::Failed { reason, message } = self {
            info["promptFailure"] = json!({ "reason": reason, "message": message });
        }
    }
}

/// A closed worker as tools report it, kept for the one that started it.
#[derive(Clone)]
pub(crate) struct KeptWorker {
    pub pane: PaneId,
    pub creator: PaneId,
    pub agent: Value,
    pub result: Value,
}

#[derive(Default)]
pub(crate) struct Workers {
    first_prompts: Mutex<HashMap<PaneId, PromptDelivery>>,
    kept: Mutex<VecDeque<KeptWorker>>,
}

impl Workers {
    pub fn first_prompt(&self, pane: PaneId) -> Option<PromptDelivery> {
        lock(&self.first_prompts).get(&pane).cloned()
    }

    fn set_first_prompt(&self, pane: PaneId, delivery: PromptDelivery) {
        lock(&self.first_prompts).insert(pane, delivery);
    }

    pub fn forget(&self, pane: PaneId) {
        lock(&self.first_prompts).remove(&pane);
    }

    pub fn keep(&self, worker: KeptWorker) {
        let mut kept = lock(&self.kept);
        kept.retain(|earlier| earlier.pane != worker.pane);
        if kept.len() == KEPT_RESULTS {
            kept.pop_front();
        }
        kept.push_back(worker);
    }

    pub fn kept(&self, pane: PaneId) -> Option<KeptWorker> {
        lock(&self.kept)
            .iter()
            .find(|worker| worker.pane == pane)
            .cloned()
    }
}

/// Whether the agent is in a turn it has not ended: it worked or was given a prompt since its
/// last end, and has not sat idle for [`STOPPED_AFTER`].
pub(crate) fn in_turn(meta: &MetaState) -> bool {
    meta.in_turn
        && meta
            .idle_since
            .is_none_or(|since| since.elapsed() < STOPPED_AFTER)
}

/// A turn starts: a prompt was typed into the agent.
pub(crate) fn turn_started(entry: &PaneEntry) {
    let mut meta = lock(&entry.meta);
    meta.in_turn = true;
    meta.idle_since = Some(std::time::Instant::now());
}

/// A worker agent: its pane, kind, state and finished turns.
pub(crate) fn agent_info(core: &Core, pane: PaneId, entry: &PaneEntry) -> Value {
    let launched = match &lock(&entry.record).launch {
        PaneLaunch::Agent { agent, .. } => Some(*agent),
        _ => None,
    };
    let running = lock(&entry.agent).as_ref().map(|runtime| runtime.kind());
    let kind = running.or(launched);
    let (turns, working) = {
        let meta = lock(&entry.meta);
        (meta.turns, in_turn(&meta))
    };
    let closed = core.pane_meta(pane).is_none_or(|meta| meta.exit.is_some());
    let status = agent_status(entry).unwrap_or_else(|| super::status(core, pane, entry));
    let reported = status["state"].as_str().unwrap_or("starting");
    let state = if closed || kind.is_none() {
        "exited"
    } else if reported == "blocked" {
        "blocked"
    } else if working {
        "working"
    } else {
        reported
    };
    let mut info = json!({
        "pane": pane_ref(pane),
        "kind": kind.map(crate::agent::program),
        "state": state,
        "status": status,
        "turns": turns,
    });
    if let Some(delivery) = core.term.workers.first_prompt(pane) {
        delivery.describe(&mut info);
    }
    info
}

/// What the agent integration knows: its state and, while blocked, what it waits on.
fn agent_status(entry: &PaneEntry) -> Option<Value> {
    let agent = lock(&entry.agent);
    let runtime = agent.as_ref()?;
    let app = crate::agent::program(runtime.kind());
    if let Some(blocker) = runtime.blocker() {
        let summary = crate::agent::shown_summary(runtime.kind(), blocker);
        let kind = blocked_kind(blocker.reason);
        let tool = blocker.tool.clone();
        drop(agent);
        let message = Some(summary)
            .filter(|summary| !summary.is_empty())
            .or_else(|| screen_excerpt(entry));
        return Some(json!({
            "state": "blocked",
            "kind": kind,
            "app": app,
            "message": message,
            "tool": tool,
        }));
    }
    let state = match runtime.state() {
        agents::AgentState::Working => "working",
        agents::AgentState::Error => "done",
        agents::AgentState::Unknown if runtime.session().native_id.is_none() => "starting",
        _ => "idle",
    };
    Some(json!({ "state": state, "kind": null, "app": app }))
}

fn blocked_kind(reason: agents::BlockedReason) -> &'static str {
    use agents::BlockedReason;
    match reason {
        BlockedReason::Permission => "permission",
        BlockedReason::Question => "question",
        BlockedReason::Auth => "auth",
        BlockedReason::Trust => "trust",
        BlockedReason::Update => "update",
        BlockedReason::Elicitation => "elicitation",
        BlockedReason::Other => "other",
    }
}

/// The last lines the pane shows, as printed text.
fn screen_excerpt(entry: &PaneEntry) -> Option<String> {
    let screen = entry.pane.screen_lines();
    let lines: Vec<&str> = screen
        .lines()
        .map(str::trim_end)
        .filter(|line| !line.trim().is_empty())
        .collect();
    let tail = lines[lines.len().saturating_sub(EXCERPT_LINES)..].join("\n");
    let text = proto::clean_prompt_text(&tail, EXCERPT_CHARS);
    (!text.is_empty()).then_some(text)
}

/// The pane's last agent turn as tools report it, `null` before the first.
pub(crate) fn last_turn(entry: &PaneEntry) -> Value {
    let meta = lock(&entry.meta);
    let Some(turn) = &meta.last_turn else {
        return Value::Null;
    };
    let mut result = json!({
        "outcome": match turn.outcome {
            agents::TurnOutcome::Completed => "completed",
            agents::TurnOutcome::Cancelled => "cancelled",
            agents::TurnOutcome::Failed => "failed",
        },
        "message": turn.message,
        "endedAt": turn.at.0,
        "transcriptPath": turn.transcript.as_ref().map(|path| path.to_string_lossy()),
    });
    if turn.message.is_none()
        && let Some(reason) = turn.message_unavailable
    {
        result["messageUnavailable"] = json!(reason.as_str());
    }
    result
}

/// Whether the pane's last turn is still having its message read from the transcript.
pub(crate) fn reading_message(entry: &PaneEntry) -> bool {
    lock(&entry.meta)
        .last_turn
        .as_ref()
        .is_some_and(|turn| turn.message_unavailable == Some(MessageUnavailable::ReadingTranscript))
}

/// What a closing worker leaves for the agent that started it: its last turn, or a cancelled
/// one when it closed mid-turn. `None` for a pane that never ran an agent.
pub(crate) fn closed_worker(
    core: &Core,
    pane: PaneId,
    creator: PaneId,
    entry: &PaneEntry,
) -> Option<KeptWorker> {
    let launched = matches!(lock(&entry.record).launch, PaneLaunch::Agent { .. });
    let ran_agent = lock(&entry.agent).is_some();
    let (mid_turn, finished_one, transcript) = {
        let meta = lock(&entry.meta);
        let transcript = meta
            .last_turn
            .as_ref()
            .and_then(|turn| turn.transcript.as_ref())
            .map(|path| path.to_string_lossy().into_owned());
        (in_turn(&meta), meta.last_turn.is_some(), transcript)
    };
    if !launched && !ran_agent && !finished_one {
        return None;
    }
    let result = if mid_turn {
        json!({
            "outcome": "cancelled",
            "reason": "pane_closed",
            "message": null,
            "messageUnavailable": MessageUnavailable::PaneClosed.as_str(),
            "endedAt": crate::identity::now_millis(),
            "transcriptPath": transcript,
        })
    } else {
        last_turn(entry)
    };
    let mut agent = agent_info(core, pane, entry);
    agent["state"] = json!("exited");
    agent["closed"] = json!(true);
    Some(KeptWorker {
        pane,
        creator,
        agent,
        result,
    })
}

enum Readiness {
    Ready,
    Starting,
    Blocked,
    /// The agent exited and the pane is back at its shell, where it may be run again.
    Exited,
    /// The pane's own process ended.
    Gone,
}

/// Whether the agent can take a prompt: something positive says it is at rest (an end-of-turn
/// report, or its prompt on screen), and it is not working, blocked or exited. A reported
/// session is not enough: Claude Code reports one while it still shows its sign-in.
fn readiness(entry: &PaneEntry) -> Readiness {
    if lock(&entry.meta).exit.is_some() {
        return Readiness::Gone;
    }
    let launched = matches!(lock(&entry.record).launch, PaneLaunch::Agent { .. });
    let agent = lock(&entry.agent);
    let Some(runtime) = agent.as_ref() else {
        return if launched {
            Readiness::Starting
        } else {
            Readiness::Exited
        };
    };
    if runtime.has_exited() {
        return Readiness::Exited;
    }
    // The shell's own title or prompt can look like an idle agent before its exit is noticed.
    let foreground = entry.pane.pty().foreground_process();
    if crate::core::is_own_shell(entry, foreground.as_ref()) {
        return Readiness::Exited;
    }
    match runtime.state() {
        agents::AgentState::Blocked => Readiness::Blocked,
        agents::AgentState::Working => Readiness::Starting,
        agents::AgentState::Idle | agents::AgentState::Error => match runtime.idle_evidence() {
            // Claude Code's title can say idle over any screen; only its prompt box counts.
            Some(agents::Source::Title) if runtime.kind() == AgentKind::Claude => {
                Readiness::Starting
            }
            Some(_) => Readiness::Ready,
            None => Readiness::Starting,
        },
        agents::AgentState::Unknown => Readiness::Starting,
    }
}

/// Holds the first prompt for a new worker until it is ready for it, then types it. An agent
/// that exits first (Codex updating itself) gets [`RERUN_GRACE`] to be run again.
pub(crate) fn queue_first_prompt(core: &Arc<Core>, pane: PaneId, kind: AgentKind, prompt: String) {
    core.term
        .workers
        .set_first_prompt(pane, PromptDelivery::Queued);
    let core = Arc::clone(core);
    tokio::spawn(async move {
        let delivery = match until_ready(&core, pane, kind).await {
            Ok(entry) => match super::deliver(&entry, prompt).await {
                Ok(()) => PromptDelivery::Accepted,
                Err(_) => PromptDelivery::failed(
                    "pane_closed",
                    "the pane closed before the prompt was typed",
                ),
            },
            Err(failed) => failed,
        };
        core.term.workers.set_first_prompt(pane, delivery);
    });
}

async fn until_ready(
    core: &Core,
    pane: PaneId,
    kind: AgentKind,
) -> Result<Arc<PaneEntry>, PromptDelivery> {
    let program = crate::agent::program(kind);
    let patience = Instant::now() + FIRST_PROMPT_PATIENCE;
    let mut settled_since: Option<(proto::Seq, Instant)> = None;
    let mut exited: Option<(Instant, Option<String>)> = None;
    loop {
        let Some(entry) = core.pane(pane) else {
            return Err(PromptDelivery::failed(
                "pane_closed",
                format!("the pane closed before {program} was ready"),
            ));
        };
        match readiness(&entry) {
            Readiness::Ready => {
                exited = None;
                let head = entry.pane.head();
                let since = match settled_since {
                    Some((seen, since)) if seen == head => since,
                    _ => {
                        settled_since = Some((head, Instant::now()));
                        Instant::now()
                    }
                };
                if since.elapsed() >= SETTLE {
                    return Ok(entry);
                }
            }
            Readiness::Exited => {
                settled_since = None;
                let (since, screen) =
                    exited.get_or_insert_with(|| (Instant::now(), screen_excerpt(&entry)));
                if since.elapsed() >= RERUN_GRACE {
                    let said = screen
                        .as_deref()
                        .map_or_else(String::new, |screen| format!(": {screen}"));
                    return Err(PromptDelivery::failed(
                        "agent_exited",
                        format!("{program} exited before it was ready for the prompt{said}"),
                    ));
                }
            }
            Readiness::Gone => {
                return Err(PromptDelivery::failed(
                    "pane_closed",
                    format!("{program}'s pane ended before it was ready"),
                ));
            }
            Readiness::Starting | Readiness::Blocked => {
                settled_since = None;
                exited = None;
            }
        }
        if Instant::now() >= patience {
            return Err(PromptDelivery::failed(
                "not_ready",
                format!("{program} was not ready for the prompt within 15 minutes"),
            ));
        }
        tokio::time::sleep(TICK).await;
    }
}
