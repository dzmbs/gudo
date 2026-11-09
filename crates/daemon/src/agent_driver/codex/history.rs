use super::{Projection, State, runtime::Effect};
use agents::{CodexHistoryTurn, CodexLiveEvent, CodexThreadHistory};
use std::collections::HashSet;

#[derive(Debug, thiserror::Error)]
pub(super) enum HistoryError {
    #[error("invalid Codex history reply")]
    Decode(#[from] agents::CodexBindingError),
    #[error("Codex resume reply omitted history")]
    Missing,
    #[error("Codex history exceeded projection admission")]
    Projection,
    #[error("active resume lacks an ordered live baseline")]
    Active,
}

pub(super) fn observe_tui(state: &mut State, frame: &str) {
    #[derive(serde::Deserialize)]
    struct Method<'a> {
        id: Option<agents::CodexRpcId>,
        method: Option<&'a str>,
        params: Option<ThreadOptions>,
    }
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct ThreadOptions {
        exclude_turns: Option<bool>,
        thread_id: Option<String>,
    }
    let Ok(request) = serde_json::from_str::<Method<'_>>(frame) else {
        return;
    };
    if request.id.is_none() {
        return;
    }
    if request.method == Some("thread/rollback")
        && state.binding.binding().is_some_and(|binding| {
            request
                .params
                .as_ref()
                .and_then(|params| params.thread_id.as_deref())
                == Some(binding.thread_id())
        })
    {
        // Until rollback has an ordered baseline, never present old rows as current.
        // Stop observation only; the official request is forwarded unchanged.
        state.fail();
        return;
    }
    if state.binding.pending_request() == request.id.as_ref() {
        state.requires_history = matches!(request.method, Some("thread/resume" | "thread/fork"));
        state.deferred_history = state.requires_history
            && request
                .params
                .and_then(|params| params.exclude_turns)
                .unwrap_or(false);
    }
}

fn thread(state: &State, frame: &str) -> Result<CodexThreadHistory, HistoryError> {
    let mut history = CodexThreadHistory::parse(frame)?;
    if state.current.as_ref().map(|binding| binding.thread_id()) != Some(history.id.as_str()) {
        return Err(agents::CodexBindingError::ThreadMismatch.into());
    }
    if history.turns.is_none() {
        if state.requires_history {
            return Err(HistoryError::Missing);
        }
        history.turns = Some(Vec::new());
    }
    Ok(history)
}

pub(super) fn hydrate(
    state: &mut State,
    frame: &str,
) -> Result<Option<std::path::PathBuf>, HistoryError> {
    let history = thread(state, frame)?;
    let turns = history.turns.unwrap_or_default();
    let mut completed = Vec::new();
    for turn in turns {
        if turn.status.outcome().is_some() {
            completed.push(turn.id.clone());
        } else {
            state.events = state
                .events
                .take()
                .map(|events| events.with_active_turn(turn.id.clone()))
                .transpose()?;
            state.effects.push(Effect::Started);
        }
        apply_turn(state, turn)?;
    }
    remember(state, completed)?;
    Ok(history.cwd)
}

pub(super) fn install(state: &mut State, frame: &str) -> Result<(), HistoryError> {
    let turns = thread(state, frame)?.turns.unwrap_or_default();
    let started: HashSet<_> = state
        .captured
        .iter()
        .filter_map(|event| {
            if let CodexLiveEvent::TurnStarted { turn } = event {
                Some(turn.clone())
            } else {
                None
            }
        })
        .collect();
    if turns
        .iter()
        .any(|turn| turn.status.outcome().is_none() && !started.contains(&turn.id))
    {
        return Err(HistoryError::Active);
    }
    let captured = std::mem::take(&mut state.captured);
    state.captured_bytes = 0;
    state.projection = Projection::new(
        state
            .current
            .as_ref()
            .ok_or(HistoryError::Missing)?
            .thread_id()
            .to_owned(),
    );
    let mut replayed = HashSet::new();
    let mut completed = Vec::new();
    for turn in turns {
        if started.contains(&turn.id) {
            for event in captured.iter().filter(|event| event_turn(event) == turn.id) {
                state
                    .projection
                    .apply(event.clone())
                    .map_err(|_| HistoryError::Projection)?;
            }
            replayed.insert(turn.id);
        } else {
            completed.push(turn.id.clone());
            apply_turn(state, turn)?;
        }
    }
    for event in captured {
        if !replayed.contains(event_turn(&event)) {
            state
                .projection
                .apply(event)
                .map_err(|_| HistoryError::Projection)?;
        }
    }
    remember(state, completed)?;
    state.history_ready = true;
    state.operations.clear();
    state.operation_bytes = 0;
    state.push(proto::TimelineOp::Snapshot(
        state.projection.snapshot(60, None),
    ));
    state.effects.push(Effect::Ready);
    Ok(())
}

fn apply_turn(state: &mut State, turn: CodexHistoryTurn) -> Result<(), HistoryError> {
    let outcome = turn.status.outcome();
    for item in turn.items {
        state
            .projection
            .apply(CodexLiveEvent::Item {
                turn: turn.id.clone(),
                item,
                completed: outcome.is_some(),
            })
            .map_err(|_| HistoryError::Projection)?;
    }
    if let Some(outcome) = outcome {
        state
            .projection
            .apply(CodexLiveEvent::TurnCompleted {
                turn: turn.id,
                outcome,
            })
            .map_err(|_| HistoryError::Projection)?;
    }
    Ok(())
}

fn remember(state: &mut State, completed: Vec<String>) -> Result<(), HistoryError> {
    state.events = state
        .events
        .take()
        .map(|events| events.with_completed_turns(completed))
        .transpose()?;
    Ok(())
}

fn event_turn(event: &CodexLiveEvent) -> &str {
    match event {
        CodexLiveEvent::TurnStarted { turn }
        | CodexLiveEvent::TurnCompleted { turn, .. }
        | CodexLiveEvent::AssistantDelta { turn, .. }
        | CodexLiveEvent::Item { turn, .. }
        | CodexLiveEvent::ApprovalWaiting { turn, .. }
        | CodexLiveEvent::ApprovalResolved { turn, .. } => turn,
    }
}

#[cfg(test)]
mod tests;
