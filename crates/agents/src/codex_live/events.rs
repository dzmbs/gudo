use serde::Deserialize;
use serde::de::IgnoredAny;

use super::{CodexBinding, CodexBindingError, CodexThreadBinding, RpcId, parse, validate_id};

/// A turn outcome reported by the mapped app-server, never inferred from notify or pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexTurnOutcome {
    Completed,
    Interrupted,
    Failed,
    Unknown,
}

/// Approval category only; a signal is not sufficient metadata to authorize a decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexApprovalKind {
    Command,
    FileChange,
}

/// Bounded event data from one exact TUI binding, not authority to send or approve.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodexLiveEvent {
    TurnStarted {
        turn: String,
    },
    TurnCompleted {
        turn: String,
        outcome: CodexTurnOutcome,
    },
    AssistantDelta {
        turn: String,
        item: String,
        text: String,
    },
    Item {
        turn: String,
        item: super::CodexItem,
        completed: bool,
    },
    ApprovalWaiting {
        request: super::CodexRpcId,
        turn: String,
        item: String,
        kind: CodexApprovalKind,
    },
}

/// Launch-owned event cursor. Start before the first turn; late joins require snapshot hydration.
#[derive(Debug)]
pub struct CodexLiveEvents {
    binding: CodexThreadBinding,
    turn: Option<String>,
    closed: bool,
}

impl CodexLiveEvents {
    /// Starts an event cursor at this binding's first live turn.
    pub fn new(binding: CodexThreadBinding) -> Self {
        Self {
            binding,
            turn: None,
            closed: false,
        }
    }

    /// Parses a frame from this binding's proven physical transport.
    ///
    /// Unrelated threads, obsolete turn deltas/completions, replies and unknown methods produce no event.
    /// # Errors
    /// Malformed/oversized frames or a retired binding permanently close this native cursor.
    /// The caller must still forward official transport frames unchanged.
    pub fn observe(
        &mut self,
        connection: &CodexBinding,
        frame: &str,
    ) -> Result<Option<CodexLiveEvent>, CodexBindingError> {
        if self.closed || !connection.is_current(&self.binding) {
            self.closed = true;
            return Err(CodexBindingError::Closed);
        }
        let result = parse(frame).and_then(|frame| self.apply(frame));
        if result.is_err() {
            self.closed = true;
        }
        result
    }

    fn apply(&mut self, frame: Frame) -> Result<Option<CodexLiveEvent>, CodexBindingError> {
        match frame {
            Frame::Event(Event::TurnStarted { params }) => self.started(params),
            Frame::Event(Event::TurnCompleted { params }) => self.completed(params),
            Frame::Event(Event::AssistantDelta { params }) => self.delta(params),
            Frame::Event(Event::ItemStarted { params }) => self.item(params, false),
            Frame::Event(Event::ItemCompleted { params }) => self.item(params, true),
            Frame::Event(Event::CommandApproval { id, params }) => {
                self.approval(id, params, CodexApprovalKind::Command)
            }
            Frame::Event(Event::FileApproval { id, params }) => {
                self.approval(id, params, CodexApprovalKind::FileChange)
            }
            Frame::Event(Event::Other) => Ok(None),
            Frame::Reply(reply) => {
                if let RpcId::Text(text) = reply.id {
                    validate_id(&text)?;
                }
                Ok(None)
            }
        }
    }

    fn started(&mut self, params: TurnParams) -> Result<Option<CodexLiveEvent>, CodexBindingError> {
        if params.thread_id != self.binding.thread_id()
            || self.is_current(&params.thread_id, &params.turn.id)
        {
            return Ok(None);
        }
        validate_id(&params.turn.id)?;
        if params.turn.status != TurnStatus::InProgress {
            return Err(CodexBindingError::InvalidFrame);
        }
        self.turn = Some(params.turn.id.clone());
        Ok(Some(CodexLiveEvent::TurnStarted {
            turn: params.turn.id,
        }))
    }

    fn completed(
        &mut self,
        params: TurnParams,
    ) -> Result<Option<CodexLiveEvent>, CodexBindingError> {
        if !self.is_current(&params.thread_id, &params.turn.id) {
            return Ok(None);
        }
        let outcome = match params.turn.status {
            TurnStatus::InProgress => return Err(CodexBindingError::InvalidFrame),
            TurnStatus::Completed => CodexTurnOutcome::Completed,
            TurnStatus::Interrupted => CodexTurnOutcome::Interrupted,
            TurnStatus::Failed => CodexTurnOutcome::Failed,
            TurnStatus::Unknown => CodexTurnOutcome::Unknown,
        };
        self.turn = None;
        Ok(Some(CodexLiveEvent::TurnCompleted {
            turn: params.turn.id,
            outcome,
        }))
    }

    fn delta(&self, params: DeltaParams) -> Result<Option<CodexLiveEvent>, CodexBindingError> {
        if !self.is_current(&params.thread_id, &params.turn_id) {
            return Ok(None);
        }
        validate_id(&params.item_id)?;
        Ok(Some(CodexLiveEvent::AssistantDelta {
            turn: params.turn_id,
            item: params.item_id,
            text: params.delta,
        }))
    }

    fn item(
        &self,
        params: ItemParams,
        completed: bool,
    ) -> Result<Option<CodexLiveEvent>, CodexBindingError> {
        if !self.is_current(&params.thread_id, &params.turn_id) {
            return Ok(None);
        }
        match &params.item {
            super::CodexItem::UserMessage { id, .. }
            | super::CodexItem::AgentMessage { id, .. }
            | super::CodexItem::CommandExecution { id, .. }
            | super::CodexItem::Reasoning { id, .. } => validate_id(id)?,
            super::CodexItem::Unsupported => {}
        }
        Ok(Some(CodexLiveEvent::Item {
            turn: params.turn_id,
            item: params.item,
            completed,
        }))
    }

    fn is_current(&self, thread: &str, turn: &str) -> bool {
        thread == self.binding.thread_id() && self.turn.as_deref() == Some(turn)
    }

    fn approval(
        &self,
        request: RpcId,
        params: ApprovalParams,
        kind: CodexApprovalKind,
    ) -> Result<Option<CodexLiveEvent>, CodexBindingError> {
        if !self.is_current(&params.thread_id, &params.turn_id) {
            return Ok(None);
        }
        if let RpcId::Text(text) = &request {
            validate_id(text)?;
        }
        validate_id(&params.item_id)?;
        Ok(Some(CodexLiveEvent::ApprovalWaiting {
            request,
            turn: params.turn_id,
            item: params.item_id,
            kind,
        }))
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Frame {
    Event(Event),
    Reply(Reply),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Reply {
    id: RpcId,
    #[serde(rename = "result")]
    _result: Option<IgnoredAny>,
    #[serde(rename = "error")]
    _error: Option<IgnoredAny>,
}

#[derive(Deserialize)]
#[serde(tag = "method")]
enum Event {
    #[serde(rename = "turn/started")]
    TurnStarted { params: TurnParams },
    #[serde(rename = "turn/completed")]
    TurnCompleted { params: TurnParams },
    #[serde(rename = "item/agentMessage/delta")]
    AssistantDelta { params: DeltaParams },
    #[serde(rename = "item/started")]
    ItemStarted { params: ItemParams },
    #[serde(rename = "item/completed")]
    ItemCompleted { params: ItemParams },
    #[serde(rename = "item/commandExecution/requestApproval")]
    CommandApproval { id: RpcId, params: ApprovalParams },
    #[serde(rename = "item/fileChange/requestApproval")]
    FileApproval { id: RpcId, params: ApprovalParams },
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TurnParams {
    thread_id: String,
    turn: Turn,
}

#[derive(Deserialize)]
struct Turn {
    id: String,
    status: TurnStatus,
}

#[derive(Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum TurnStatus {
    InProgress,
    Completed,
    Interrupted,
    Failed,
    #[serde(other)]
    Unknown,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeltaParams {
    thread_id: String,
    turn_id: String,
    item_id: String,
    delta: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ItemParams {
    thread_id: String,
    turn_id: String,
    item: super::CodexItem,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ApprovalParams {
    thread_id: String,
    turn_id: String,
    item_id: String,
}

#[cfg(test)]
mod tests;
