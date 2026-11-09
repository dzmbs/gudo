use std::collections::{HashSet, VecDeque};

use serde::Deserialize;

use super::{CodexBinding, CodexBindingError, CodexThreadBinding, RpcId, parse, validate_id};

const REMEMBERED_TURNS: usize = 500;
const TURN_APPROVALS: usize = 256;
const EVENT_METHODS: [&str; 8] = [
    "turn/started",
    "turn/completed",
    "item/agentMessage/delta",
    "item/started",
    "item/completed",
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "serverRequest/resolved",
];

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
        details: Box<super::CodexApprovalDetails>,
    },
    ApprovalResolved {
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
    seen_turns: HashSet<String>,
    turn_order: VecDeque<String>,
    approvals: Vec<Approval>,
    retired_requests: VecDeque<RpcId>,
    closed: bool,
}

#[derive(Debug)]
struct Approval {
    request: RpcId,
    turn: String,
    item: String,
    kind: CodexApprovalKind,
    details: super::CodexApprovalDetails,
    resolved: bool,
}

impl CodexLiveEvents {
    /// Starts an event cursor at this binding's first live turn.
    pub fn new(binding: CodexThreadBinding) -> Self {
        Self {
            binding,
            turn: None,
            seen_turns: HashSet::new(),
            turn_order: VecDeque::new(),
            approvals: Vec::new(),
            retired_requests: VecDeque::new(),
            closed: false,
        }
    }

    pub fn active_turn(&self) -> Option<&str> {
        self.turn.as_deref()
    }

    pub fn has_pending_approval(&self) -> bool {
        self.approvals.iter().any(|approval| {
            !approval.resolved && Some(approval.turn.as_str()) == self.turn.as_deref()
        })
    }

    pub fn approval_pending(&self, request: &RpcId) -> bool {
        self.approvals.iter().any(|approval| {
            &approval.request == request
                && !approval.resolved
                && Some(approval.turn.as_str()) == self.turn.as_deref()
        })
    }

    /// Restores the active turn reported in this binding's correlated history reply.
    /// # Errors
    /// Rejects invalid turn identities.
    pub fn with_active_turn(mut self, turn: String) -> Result<Self, CodexBindingError> {
        self.reserve_turn(&turn)?;
        self.turn = Some(turn);
        Ok(self)
    }

    /// Reserves completed baseline turns so delayed live frames cannot replay their text.
    /// Only the most recent turns stay reserved; a frame delayed past them is not a risk.
    /// # Errors
    /// Rejects invalid identities.
    pub fn with_completed_turns(
        mut self,
        turns: impl IntoIterator<Item = String>,
    ) -> Result<Self, CodexBindingError> {
        for turn in turns {
            self.reserve_turn(&turn)?;
        }
        Ok(self)
    }

    fn retire_request(&mut self, request: RpcId) {
        self.retired_requests.push_back(request);
        if self.retired_requests.len() > TURN_APPROVALS {
            self.retired_requests.pop_front();
        }
    }

    fn reserve_turn(&mut self, turn: &str) -> Result<(), CodexBindingError> {
        validate_id(turn)?;
        if !self.seen_turns.insert(turn.to_owned()) {
            return Ok(());
        }
        self.turn_order.push_back(turn.to_owned());
        while self.turn_order.len() > REMEMBERED_TURNS {
            if let Some(oldest) = self.turn_order.pop_front() {
                self.seen_turns.remove(&oldest);
            }
        }
        Ok(())
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
        let result = self.decode(frame);
        if result.is_err() {
            self.closed = true;
        }
        result
    }

    fn decode(&mut self, frame: &str) -> Result<Option<CodexLiveEvent>, CodexBindingError> {
        let envelope: Envelope = parse(frame)?;
        let Some(method) = envelope.method else {
            if let Some(RpcId::Text(text)) = envelope.id {
                validate_id(&text)?;
            }
            return Ok(None);
        };
        if !EVENT_METHODS.contains(&method.as_str()) {
            return Ok(None);
        }
        let event = serde_json::from_str(frame).map_err(|_| CodexBindingError::InvalidFrame)?;
        self.apply(event)
    }

    fn apply(&mut self, event: Event) -> Result<Option<CodexLiveEvent>, CodexBindingError> {
        match event {
            Event::TurnStarted { params } => self.started(params),
            Event::TurnCompleted { params } => self.completed(params),
            Event::AssistantDelta { params } => self.delta(params),
            Event::ItemStarted { params } => self.item(params, false),
            Event::ItemCompleted { params } => self.item(params, true),
            Event::CommandApproval { id, params } => {
                self.approval(id, params, CodexApprovalKind::Command)
            }
            Event::FileApproval { id, params } => {
                self.approval(id, params, CodexApprovalKind::FileChange)
            }
            Event::RequestResolved { params } => self.resolved(params),
        }
    }

    fn started(&mut self, params: TurnParams) -> Result<Option<CodexLiveEvent>, CodexBindingError> {
        if params.thread_id != self.binding.thread_id() || self.seen_turns.contains(&params.turn.id)
        {
            return Ok(None);
        }
        validate_id(&params.turn.id)?;
        if params.turn.status != TurnStatus::InProgress {
            return Err(CodexBindingError::InvalidFrame);
        }
        self.reserve_turn(&params.turn.id)?;
        for approval in std::mem::take(&mut self.approvals) {
            self.retire_request(approval.request);
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
        &mut self,
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
        if self.retired_requests.contains(&request) {
            return Err(CodexBindingError::InvalidFrame);
        }
        if let Some(known) = self.approvals.iter().find(|known| known.request == request) {
            if known.turn == params.turn_id
                && known.item == params.item_id
                && known.kind == kind
                && known.details == params.details
            {
                return Ok(None);
            }
            return Err(CodexBindingError::InvalidFrame);
        }
        // Resolved identities stay reserved so delayed notifications cannot resolve a reused id.
        if self.approvals.len() >= TURN_APPROVALS {
            let resolved = self
                .approvals
                .iter()
                .position(|approval| approval.resolved)
                .ok_or(CodexBindingError::Exhausted)?;
            let retired = self.approvals.remove(resolved);
            self.retire_request(retired.request);
        }
        self.approvals.push(Approval {
            request: request.clone(),
            turn: params.turn_id.clone(),
            item: params.item_id.clone(),
            kind,
            details: params.details.clone(),
            resolved: false,
        });
        Ok(Some(CodexLiveEvent::ApprovalWaiting {
            request,
            turn: params.turn_id,
            item: params.item_id,
            kind,
            details: Box::new(params.details),
        }))
    }

    fn resolved(
        &mut self,
        params: ResolutionParams,
    ) -> Result<Option<CodexLiveEvent>, CodexBindingError> {
        if params.thread_id != self.binding.thread_id() {
            return Ok(None);
        }
        if let RpcId::Text(text) = &params.request_id {
            validate_id(text)?;
        }
        let Some(approval) = self.approvals.iter_mut().find(|approval| {
            approval.request == params.request_id
                && !approval.resolved
                && Some(approval.turn.as_str()) == self.turn.as_deref()
        }) else {
            return Ok(None);
        };
        approval.resolved = true;
        Ok(Some(CodexLiveEvent::ApprovalResolved {
            request: approval.request.clone(),
            turn: approval.turn.clone(),
            item: approval.item.clone(),
            kind: approval.kind,
        }))
    }
}

#[derive(Deserialize)]
struct Envelope {
    id: Option<RpcId>,
    method: Option<String>,
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
    #[serde(rename = "serverRequest/resolved")]
    RequestResolved { params: ResolutionParams },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResolutionParams {
    thread_id: String,
    request_id: RpcId,
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
    #[serde(flatten)]
    details: super::CodexApprovalDetails,
}

#[cfg(test)]
mod tests;
