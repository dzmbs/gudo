use agents::{
    CodexFileChange, CodexFileChangeKind, CodexInput, CodexItem, CodexLiveEvent, CodexPlanStatus,
    CodexTokenCounts, CodexTokenUsage, CodexWebSearchAction,
};
use proto::{
    AgentKind, FileDiff, OutputHandle, TimelineAttachment, TimelineBody, TimelineCursor,
    TimelineField, TimelineItem, TimelineNoticeKind, TimelineOp, TimelineOrigin, TimelineOutputRef,
    TimelinePlanEntry, TimelinePlanStatus, TimelineSession, TimelineSnapshot, TimelineTextRole,
    TimelineTool, TimelineToolKind, TimelineToolStatus, UnixMillis, WsError,
};
#[cfg(test)]
mod tests;

use std::collections::{HashMap, VecDeque};

pub(super) const SNAPSHOT_ITEMS: usize = 60;
const MAX_ITEMS: usize = 500;
const MAX_TEXT: usize = 256 * 1024;
const MAX_BYTES: usize = 768 * 1024;
/// Text over this is pushed as its start, with the whole text paged from the rollout.
pub(super) const LONG_TEXT_BYTES: usize = 64 * 1024;
const PREVIEW_BYTES: usize = 16 * 1024;
const TITLE_BYTES: usize = 2 * 1024;
const INPUT_BYTES: usize = 64 * 1024;
const NOTICE_BYTES: usize = 2 * 1024;
/// Files of one change previewed inline; all of them stay in its recorded changes.
const PREVIEWED_FILES: usize = 64;
const TOO_LARGE: &str = "This is too large for Chat. Check Terminal.";
/// Codex sends this context to the model as user messages; its markers, matched as Codex does.
const INJECTED_CONTEXT_MARKERS: [(&str, &str); 6] = [
    ("# AGENTS.md instructions", "</INSTRUCTIONS>"),
    ("<user_instructions>", "</user_instructions>"),
    ("<environment_context>", "</environment_context>"),
    ("<user_shell_command>", "</user_shell_command>"),
    ("<turn_aborted>", "</turn_aborted>"),
    ("<subagent_notification>", "</subagent_notification>"),
];

/// Where an item's whole text can be read again: its rollout record, once known.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Location {
    epoch: u64,
    record: Option<u64>,
}

impl Location {
    /// An item seen on the app-server stream, located in the rollout by its id when read.
    pub fn live(epoch: u64) -> Self {
        Self {
            epoch,
            record: None,
        }
    }

    pub fn recorded(epoch: u64, offset: u64) -> Self {
        Self {
            epoch,
            record: Some(offset),
        }
    }

    fn handle(self, id: &str) -> Option<OutputHandle> {
        // A rollout starts with its session record, so offset zero never names an item.
        OutputHandle::new(self.epoch, self.record.unwrap_or(0), id).ok()
    }
}

/// How full the model's context window was at its latest request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ContextUsage {
    pub used: u64,
    pub window: u64,
}

/// The running turn: when it started and the thread's token totals before it.
struct ActiveTurn {
    id: String,
    started_at: u64,
    base: Option<CodexTokenCounts>,
}

pub(super) struct Projection {
    cursor: TimelineCursor,
    session: TimelineSession,
    items: HashMap<String, (u64, TimelineItem)>,
    order: VecDeque<String>,
    next_item: u64,
    bytes: usize,
    usage: Option<CodexTokenUsage>,
    active: Option<ActiveTurn>,
    /// Turns this projection saw end, live or from history.
    ended_turns: u64,
}

impl Projection {
    pub fn new(thread: String) -> Self {
        Self {
            cursor: TimelineCursor {
                epoch: crate::timeline::next_epoch(),
                sequence: 0,
            },
            session: TimelineSession {
                agent: AgentKind::Codex,
                native_session: thread,
                title: None,
                model: None,
                permission_mode: None,
                commands: Vec::new(),
            },
            items: HashMap::new(),
            order: VecDeque::new(),
            next_item: 0,
            bytes: 0,
            usage: None,
            active: None,
            ended_turns: 0,
        }
    }

    pub fn context(&self) -> Option<ContextUsage> {
        let usage = self.usage?;
        Some(ContextUsage {
            used: usage.last.total_tokens,
            window: usage.model_context_window?,
        })
    }

    /// Marks where an item too large to observe went past.
    pub fn skipped(&mut self, turn: String, item: &str) -> Result<Vec<TimelineOp>, WsError> {
        self.upsert(item_id(&turn, item), turn, too_large())
    }

    pub fn cursor(&self) -> TimelineCursor {
        self.cursor
    }
    pub fn session(&self) -> &TimelineSession {
        &self.session
    }
    fn advance(&mut self) -> TimelineCursor {
        self.cursor.sequence += 1;
        self.cursor
    }

    pub fn snapshot(&self, limit: usize, since: Option<UnixMillis>) -> TimelineSnapshot {
        self.slice(self.next_item + 1, limit, since)
    }

    fn slice(&self, before: u64, limit: usize, since: Option<UnixMillis>) -> TimelineSnapshot {
        let mut selected: Vec<_> = self
            .order
            .iter()
            .rev()
            .filter_map(|id| self.items.get(id))
            .filter(|(ordinal, item)| {
                *ordinal < before && since.is_none_or(|since| item.at.0 >= since.0)
            })
            .take(limit.min(100))
            .collect();
        selected.reverse();
        let before = selected.first().and_then(|(ordinal, _)| {
            self.items
                .values()
                .any(|(prior, item)| {
                    prior < ordinal && since.is_none_or(|since| item.at.0 >= since.0)
                })
                .then_some(*ordinal)
        });
        TimelineSnapshot {
            cursor: self.cursor,
            session: self.session.clone(),
            items: selected.into_iter().map(|(_, item)| item.clone()).collect(),
            before,
        }
    }

    pub fn page(
        &self,
        before: u64,
        limit: usize,
        since: Option<UnixMillis>,
    ) -> Result<TimelineSnapshot, WsError> {
        if before == 0 || before > self.next_item + 1 {
            return Err(WsError::Invalid("invalid Chat page cursor".into()));
        }
        Ok(self.slice(before, limit, since))
    }

    pub fn apply(&mut self, event: CodexLiveEvent) -> Result<Vec<TimelineOp>, WsError> {
        match event {
            CodexLiveEvent::AssistantDelta { turn, item, text } => {
                self.append(turn.clone(), item_id(&turn, &item), text)
            }
            CodexLiveEvent::Item {
                turn,
                item,
                completed,
            } => {
                let location = Location::live(self.cursor.epoch);
                let Some((id, body)) = body(item, completed, &turn, location) else {
                    return Ok(Vec::new());
                };
                self.upsert(id, turn, body)
            }
            CodexLiveEvent::TurnStarted { turn } => {
                self.active = Some(ActiveTurn {
                    id: turn,
                    started_at: crate::identity::now_millis(),
                    // A thread with no earlier turn starts from nothing; one resumed from
                    // history without its counts has no known start.
                    base: self
                        .usage
                        .map(|usage| usage.total)
                        .or_else(|| (self.ended_turns == 0).then(CodexTokenCounts::default)),
                });
                Ok(Vec::new())
            }
            CodexLiveEvent::PlanUpdated { turn, plan } => {
                self.upsert(plan_id(&turn), turn, plan_body(plan))
            }
            CodexLiveEvent::TokenUsage { usage, .. } => {
                self.usage = Some(usage);
                Ok(Vec::new())
            }
            CodexLiveEvent::Error {
                turn,
                message,
                will_retry: true,
            } => self.upsert(
                format!("turn:{turn}:retry"),
                turn,
                notice(TimelineNoticeKind::Retry, &message),
            ),
            CodexLiveEvent::Error { .. } => Ok(Vec::new()),
            CodexLiveEvent::TurnCompleted {
                turn,
                outcome,
                error,
                duration_ms,
            } => self.complete_turn(turn, outcome, error, duration_ms),
            CodexLiveEvent::ApprovalWaiting { .. } | CodexLiveEvent::ApprovalResolved { .. } => {
                Ok(Vec::new())
            }
        }
    }

    fn complete_turn(
        &mut self,
        turn: String,
        outcome: agents::CodexTurnOutcome,
        error: Option<String>,
        duration_ms: Option<u64>,
    ) -> Result<Vec<TimelineOp>, WsError> {
        let ids: Vec<_> = self
            .items
            .iter()
            .filter(|(_, (_, item))| {
                item.turn.as_deref() == Some(&turn)
                    && matches!(
                        item.body,
                        TimelineBody::Assistant {
                            streaming: true,
                            ..
                        }
                    )
            })
            .map(|(id, _)| id.clone())
            .collect();
        let mut operations = Vec::new();
        for id in ids {
            let (_, item) = self.items.get(&id).ok_or_else(budget)?;
            let TimelineBody::Assistant { text, .. } = &item.body else {
                continue;
            };
            operations.extend(self.upsert(
                id,
                turn.clone(),
                TimelineBody::Assistant {
                    text: text.clone(),
                    streaming: false,
                },
            )?);
        }
        if let Some(body) = turn_failure(outcome, error.as_deref()) {
            operations.extend(self.upsert(turn_notice_id(&turn), turn.clone(), body)?);
        }
        self.ended_turns += 1;
        let active = self.active.take().filter(|active| active.id == turn);
        let duration_ms = duration_ms.or_else(|| {
            active
                .as_ref()
                .map(|active| crate::identity::now_millis().saturating_sub(active.started_at))
        });
        if let Some(duration_ms) = duration_ms {
            let tokens = self.turn_tokens(active.and_then(|active| active.base));
            operations.extend(self.upsert(
                turn_end_id(&turn),
                turn,
                TimelineBody::TurnEnd {
                    duration_ms,
                    input_tokens: tokens.map(|tokens| tokens.input_tokens),
                    output_tokens: tokens.map(|tokens| tokens.output_tokens),
                },
            )?);
        }
        Ok(operations)
    }

    /// The tokens the turn used: the thread's totals now less those before it began.
    fn turn_tokens(&self, base: Option<CodexTokenCounts>) -> Option<CodexTokenCounts> {
        let usage = self.usage?;
        let base = base?;
        Some(CodexTokenCounts {
            input_tokens: usage.total.input_tokens.saturating_sub(base.input_tokens),
            output_tokens: usage.total.output_tokens.saturating_sub(base.output_tokens),
            ..CodexTokenCounts::default()
        })
    }

    fn append(
        &mut self,
        turn: String,
        id: String,
        text: String,
    ) -> Result<Vec<TimelineOp>, WsError> {
        let mut operations = Vec::new();
        if !self.items.contains_key(&id) {
            operations.extend(self.upsert(
                id.clone(),
                turn,
                TimelineBody::Assistant {
                    text: String::new(),
                    streaming: true,
                },
            )?);
        }
        let epoch = self.cursor.epoch;
        let (_, item) = self.items.get_mut(&id).ok_or_else(budget)?;
        let additional = serde_json::to_vec(&text)
            .map_err(|_| budget())?
            .len()
            .saturating_sub(2);
        let TimelineBody::Assistant {
            text: current,
            streaming: true,
        } = &mut item.body
        else {
            return Ok(operations);
        };
        if current.len().saturating_add(text.len()) > LONG_TEXT_BYTES {
            // Later deltas no longer apply to the start; the completed item brings the full size.
            let body = fitted_text(
                TimelineTextRole::Assistant,
                format!("{current}{text}"),
                &id,
                Location::live(epoch),
            );
            let turn = item.turn.clone().unwrap_or_default();
            operations.extend(self.upsert(id, turn, body)?);
            return Ok(operations);
        }
        current.push_str(&text);
        self.bytes += additional;
        item.revision = item.revision.saturating_add(1);
        operations.push(TimelineOp::Append {
            cursor: self.advance(),
            id: id.clone(),
            field: TimelineField::Text,
            text,
        });
        self.evict(&id);
        Ok(operations)
    }

    fn upsert(
        &mut self,
        id: String,
        turn: String,
        body: TimelineBody,
    ) -> Result<Vec<TimelineOp>, WsError> {
        let (body, size) = within_budget(body)?;
        let previous = self.items.remove(&id);
        let (ordinal, revision, at) = match previous {
            Some((ordinal, item)) => {
                self.bytes = self
                    .bytes
                    .saturating_sub(serde_json::to_vec(&item.body).map_err(|_| budget())?.len());
                (ordinal, item.revision.saturating_add(1), item.at)
            }
            None => {
                self.next_item += 1;
                self.order.push_back(id.clone());
                (self.next_item, 1, UnixMillis(crate::identity::now_millis()))
            }
        };
        self.bytes += size;
        let item = TimelineItem {
            id: id.clone(),
            revision,
            turn: Some(turn),
            parent: None,
            at,
            origin: origin(&body),
            body,
        };
        self.items.insert(id.clone(), (ordinal, item.clone()));
        let operations = vec![TimelineOp::Upsert {
            cursor: self.advance(),
            item: Box::new(item),
        }];
        self.evict(&id);
        Ok(operations)
    }

    /// Forgets the oldest items over the budget; clients keep the rows they already have.
    fn evict(&mut self, current: &str) {
        while self.items.len() > MAX_ITEMS || self.bytes > MAX_BYTES {
            let Some(index) = self.order.iter().position(|id| id != current) else {
                return;
            };
            let Some(oldest) = self.order.remove(index) else {
                return;
            };
            if let Some((_, item)) = self.items.remove(&oldest) {
                let size = serde_json::to_vec(&item.body).map_or(0, |bytes| bytes.len());
                self.bytes = self.bytes.saturating_sub(size);
            }
        }
    }
}

pub(super) fn origin(body: &TimelineBody) -> TimelineOrigin {
    if matches!(
        body,
        TimelineBody::User { .. }
            | TimelineBody::LongText {
                role: TimelineTextRole::User,
                ..
            }
    ) {
        TimelineOrigin::Terminal
    } else {
        TimelineOrigin::Agent
    }
}

pub(super) fn item_id(turn: &str, item: &str) -> String {
    format!("item:{}:{turn}:{item}", turn.len())
}

/// The turn and item of an id made by `item_id`.
pub(super) fn split_item_id(id: &str) -> Option<(&str, &str)> {
    let rest = id.strip_prefix("item:")?;
    let (length, rest) = rest.split_once(':')?;
    let length: usize = length.parse().ok()?;
    let turn = rest.get(..length)?;
    let item = rest.get(length..)?.strip_prefix(':')?;
    Some((turn, item))
}

pub(super) fn turn_notice_id(turn: &str) -> String {
    format!("turn:{turn}:status")
}

pub(super) fn turn_end_id(turn: &str) -> String {
    format!("turn:{turn}:end")
}

pub(super) fn plan_id(turn: &str) -> String {
    format!("turn:{turn}:plan")
}

pub(super) fn plan_body(plan: Vec<agents::CodexPlanStep>) -> TimelineBody {
    let entries = plan
        .into_iter()
        .map(|step| TimelinePlanEntry {
            text: head(&step.step, TITLE_BYTES).to_owned(),
            status: match step.status {
                CodexPlanStatus::Completed => TimelinePlanStatus::Completed,
                CodexPlanStatus::InProgress => TimelinePlanStatus::InProgress,
                CodexPlanStatus::Pending | CodexPlanStatus::Unknown => TimelinePlanStatus::Pending,
            },
        })
        .collect();
    TimelineBody::Plan { entries }
}

pub(super) fn notice(kind: TimelineNoticeKind, text: &str) -> TimelineBody {
    TimelineBody::Notice {
        kind,
        text: head(text, NOTICE_BYTES).to_owned(),
    }
}

/// The notice of a turn that did not complete, with Codex's own reason when it gave one.
pub(super) fn turn_failure(
    outcome: agents::CodexTurnOutcome,
    error: Option<&str>,
) -> Option<TimelineBody> {
    let error = error.map(str::trim).filter(|error| !error.is_empty());
    let (kind, text) = match (outcome, error) {
        (agents::CodexTurnOutcome::Completed, _) => return None,
        (agents::CodexTurnOutcome::Interrupted, _) => {
            (TimelineNoticeKind::Interrupted, "Turn interrupted.")
        }
        (agents::CodexTurnOutcome::Failed | agents::CodexTurnOutcome::Unknown, Some(error)) => {
            (TimelineNoticeKind::Error, error)
        }
        (agents::CodexTurnOutcome::Failed, None) => (
            TimelineNoticeKind::Error,
            "Turn failed. Check Terminal for details.",
        ),
        (agents::CodexTurnOutcome::Unknown, None) => (
            TimelineNoticeKind::Error,
            "Turn finished with an unknown status. Check Terminal.",
        ),
    };
    Some(notice(kind, text))
}

fn is_injected_context(content: &[CodexInput]) -> bool {
    !content.is_empty()
        && content.iter().all(|part| match part {
            CodexInput::Text { text } => INJECTED_CONTEXT_MARKERS
                .iter()
                .any(|(start, end)| is_marked(text, start, end)),
            CodexInput::LocalImage { .. } | CodexInput::Image { .. } | CodexInput::Unsupported => {
                false
            }
        })
}

fn is_marked(text: &str, start_marker: &str, end_marker: &str) -> bool {
    let text = text.trim();
    let starts = text
        .get(..start_marker.len())
        .is_some_and(|start| start.eq_ignore_ascii_case(start_marker));
    let ends = text
        .get(text.len().saturating_sub(end_marker.len())..)
        .is_some_and(|end| end.eq_ignore_ascii_case(end_marker));
    starts && ends
}

/// The body with its JSON weight; shaping keeps every body far below this guard.
fn within_budget(body: TimelineBody) -> Result<(TimelineBody, usize), WsError> {
    let size = weight(&body)?;
    if size <= MAX_TEXT {
        return Ok((body, size));
    }
    let body = too_large();
    let size = weight(&body)?;
    Ok((body, size))
}

fn weight(body: &TimelineBody) -> Result<usize, WsError> {
    Ok(serde_json::to_vec(body).map_err(|_| budget())?.len())
}

fn too_large() -> TimelineBody {
    TimelineBody::Notice {
        kind: TimelineNoticeKind::Error,
        text: TOO_LARGE.into(),
    }
}

fn budget() -> WsError {
    WsError::Unavailable("This Codex message is too large for Chat. Use Terminal.".into())
}

/// The whole text an item's handle pages through: what its preview starts or ends.
pub(super) fn paged_text(item: &CodexItem) -> Option<String> {
    let text = match item {
        CodexItem::UserMessage { content, .. } => user_text(content),
        CodexItem::AgentMessage { text, .. } | CodexItem::Plan { text, .. } => text.clone(),
        CodexItem::Reasoning {
            summary, content, ..
        } => reasoning_text(summary, content),
        CodexItem::CommandExecution {
            aggregated_output, ..
        } => aggregated_output.clone()?,
        CodexItem::FileChange { changes, .. } => changes_text(changes),
        CodexItem::McpToolCall { result, error, .. } => {
            let mut parts: Vec<String> = result.iter().map(|result| result.text()).collect();
            parts.extend(error.iter().map(|error| error.message.clone()));
            parts.retain(|part| !part.is_empty());
            parts.join("\n")
        }
        CodexItem::DynamicToolCall { content_items, .. } => {
            agents::codex_content_text(content_items.as_deref().unwrap_or_default())
        }
        CodexItem::CollabAgentToolCall { agents_states, .. } => agents_states
            .values()
            .filter_map(|state| state.message.as_deref())
            .collect::<Vec<_>>()
            .join("\n\n"),
        CodexItem::WebSearch { .. }
        | CodexItem::ImageView { .. }
        | CodexItem::ContextCompaction { .. }
        | CodexItem::EnteredReviewMode { .. }
        | CodexItem::ExitedReviewMode { .. }
        | CodexItem::Unsupported => return None,
    };
    Some(text).filter(|text| !text.is_empty())
}

/// Each changed file's path and its diff, or its whole text for an added or deleted file.
fn changes_text(changes: &[CodexFileChange]) -> String {
    changes
        .iter()
        .map(|change| format!("{}\n{}", change.path, change.diff))
        .collect::<Vec<_>>()
        .join("\n")
}

fn user_text(content: &[CodexInput]) -> String {
    let mut text = String::new();
    for part in content {
        match part {
            CodexInput::Text { text: part } => text.push_str(part),
            CodexInput::LocalImage { .. } | CodexInput::Image { .. } => {}
            CodexInput::Unsupported => text.push_str("\n[Attachment available in Terminal]\n"),
        }
    }
    text
}

fn attachments(content: &[CodexInput]) -> Vec<TimelineAttachment> {
    content
        .iter()
        .filter_map(|part| match part {
            CodexInput::LocalImage { path } => Some(TimelineAttachment {
                path: head(path, TITLE_BYTES).to_owned(),
                media_type: image_media_type(path).map(str::to_owned),
            }),
            _ => None,
        })
        .collect()
}

fn image_media_type(path: &str) -> Option<&'static str> {
    let extension = std::path::Path::new(path)
        .extension()?
        .to_str()?
        .to_ascii_lowercase();
    Some(match extension.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        _ => return None,
    })
}

fn reasoning_text(summary: &[String], content: &[String]) -> String {
    summary
        .iter()
        .chain(content)
        .map(String::as_str)
        .collect::<Vec<_>>()
        .join("\n")
}

/// The start of `text` within `limit` bytes, ending at a line break when one is near the end.
fn head(text: &str, limit: usize) -> &str {
    if text.len() <= limit {
        return text;
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    let start = &text[..end];
    match start.rfind('\n') {
        Some(line_end) if line_end >= end / 2 => &start[..=line_end],
        _ => start,
    }
}

fn fitted_text(role: TimelineTextRole, text: String, id: &str, location: Location) -> TimelineBody {
    if text.len() <= LONG_TEXT_BYTES {
        return match role {
            TimelineTextRole::User => TimelineBody::User {
                text,
                attachments: Vec::new(),
                queued: false,
            },
            TimelineTextRole::Assistant => TimelineBody::Assistant {
                text,
                streaming: false,
            },
            TimelineTextRole::Thinking => TimelineBody::Thinking {
                text: (!text.is_empty()).then_some(text),
                duration_ms: None,
            },
        };
    }
    let Some(handle) = location.handle(id) else {
        return too_large();
    };
    TimelineBody::LongText {
        role,
        content: TimelineOutputRef {
            handle,
            preview: head(&text, PREVIEW_BYTES).to_owned(),
            bytes: text.len() as u64,
        },
    }
}

/// A finished tool row with no output yet, its title and input bounded like a command's.
pub(super) fn tool(kind: TimelineToolKind, name: String, title: &str, input: &str) -> TimelineTool {
    TimelineTool {
        kind,
        name,
        title: head(title, TITLE_BYTES).to_owned(),
        input: head(input, INPUT_BYTES).to_owned(),
        status: TimelineToolStatus::Done,
        output: None,
        diff: Vec::new(),
        exit: None,
        duration_ms: None,
        command_mark: None,
    }
}

/// The timeline id and body Chat shows for `item`; `None` for context Codex injects.
pub(super) fn body(
    item: CodexItem,
    completed: bool,
    turn: &str,
    location: Location,
) -> Option<(String, TimelineBody)> {
    let shaped = match item {
        CodexItem::UserMessage { id, content } => {
            if is_injected_context(&content) {
                return None;
            }
            let id = item_id(turn, &id);
            let body = match fitted_text(TimelineTextRole::User, user_text(&content), &id, location)
            {
                TimelineBody::User { text, queued, .. } => TimelineBody::User {
                    text,
                    attachments: attachments(&content),
                    queued,
                },
                body => body,
            };
            (id, body)
        }
        CodexItem::AgentMessage { id, text } => {
            let id = item_id(turn, &id);
            let body = match fitted_text(TimelineTextRole::Assistant, text, &id, location) {
                TimelineBody::Assistant { text, .. } => TimelineBody::Assistant {
                    text,
                    streaming: !completed,
                },
                body => body,
            };
            (id, body)
        }
        CodexItem::Reasoning {
            id,
            summary,
            content,
        } => {
            let id = item_id(turn, &id);
            let text = reasoning_text(&summary, &content);
            let body = fitted_text(TimelineTextRole::Thinking, text, &id, location);
            (id, body)
        }
        CodexItem::CommandExecution {
            id,
            command,
            status,
            aggregated_output,
            exit_code,
            duration_ms,
        } => {
            let id = item_id(turn, &id);
            let status = match status.as_str() {
                "completed" if exit_code.is_some_and(|code| code != 0) => {
                    TimelineToolStatus::Failed
                }
                "completed" => TimelineToolStatus::Done,
                "failed" => TimelineToolStatus::Failed,
                "declined" => TimelineToolStatus::Denied,
                "inProgress" => TimelineToolStatus::Running,
                _ => {
                    return Some((
                        id,
                        TimelineBody::Notice {
                            kind: TimelineNoticeKind::Error,
                            text: "Command state is unknown. Check Terminal.".into(),
                        },
                    ));
                }
            };
            let output = aggregated_output
                .filter(|output| !output.is_empty())
                .and_then(|output| {
                    Some(TimelineOutputRef {
                        handle: location.handle(&id)?,
                        preview: crate::timeline::output_preview(&output),
                        bytes: output.len() as u64,
                    })
                });
            let body = TimelineBody::Tool(TimelineTool {
                kind: TimelineToolKind::Shell,
                name: "Shell".into(),
                title: head(&command, TITLE_BYTES).to_owned(),
                input: head(&command, INPUT_BYTES).to_owned(),
                status,
                output,
                diff: Vec::new(),
                exit: exit_code,
                duration_ms,
                command_mark: None,
            });
            (id, body)
        }
        CodexItem::Plan { ref id, .. } => {
            let id = item_id(turn, id);
            let text = paged_text(&item).unwrap_or_default();
            let body = fitted_text(TimelineTextRole::Assistant, text, &id, location);
            (id, body)
        }
        CodexItem::ContextCompaction { id } => (
            item_id(turn, &id),
            notice(TimelineNoticeKind::Compacted, "Context compacted"),
        ),
        CodexItem::EnteredReviewMode { id, review } => (
            item_id(turn, &id),
            notice(
                TimelineNoticeKind::ModeChanged,
                &format!("Reviewing {}", review.trim()),
            ),
        ),
        CodexItem::ExitedReviewMode { id, .. } => (
            item_id(turn, &id),
            notice(TimelineNoticeKind::ModeChanged, "Review finished"),
        ),
        CodexItem::FileChange { .. }
        | CodexItem::McpToolCall { .. }
        | CodexItem::DynamicToolCall { .. }
        | CodexItem::CollabAgentToolCall { .. }
        | CodexItem::WebSearch { .. }
        | CodexItem::ImageView { .. } => tool_body(item, turn, location)?,
        CodexItem::Unsupported => (
            item_id(turn, &format!("unsupported:{turn}")),
            TimelineBody::Notice {
                kind: TimelineNoticeKind::ModeChanged,
                text: "Additional agent details are available in Terminal.".into(),
            },
        ),
    };
    Some(shaped)
}

/// A tool row: an edit, an MCP or other tool call, another agent, a web search or an image
/// the agent looked at. Its output handle pages the result, or every file's diff.
fn tool_body(item: CodexItem, turn: &str, location: Location) -> Option<(String, TimelineBody)> {
    let id = item_id(turn, item.id()?);
    let output = paged_text(&item).and_then(|text| {
        Some(TimelineOutputRef {
            handle: location.handle(&id)?,
            preview: crate::timeline::output_preview(&text),
            bytes: text.len() as u64,
        })
    });
    let tool = match item {
        CodexItem::FileChange {
            changes, status, ..
        } => {
            let paths: Vec<&str> = changes.iter().map(|change| change.path.as_str()).collect();
            let writes_only = !changes.is_empty()
                && changes
                    .iter()
                    .all(|change| change.kind == CodexFileChangeKind::Add);
            let (kind, name) = if writes_only {
                (TimelineToolKind::Write, "Write")
            } else {
                (TimelineToolKind::Edit, "Edit")
            };
            TimelineTool {
                status: tool_status(&status),
                diff: changes
                    .iter()
                    .take(PREVIEWED_FILES)
                    .flat_map(file_preview)
                    .collect(),
                ..tool(kind, name.into(), &paths.join(", "), &paths.join("\n"))
            }
        }
        CodexItem::McpToolCall {
            server,
            tool: name,
            status,
            arguments,
            error,
            duration_ms,
            ..
        } => TimelineTool {
            status: match tool_status(&status) {
                TimelineToolStatus::Done if error.is_some() => TimelineToolStatus::Failed,
                status => status,
            },
            duration_ms,
            ..tool(
                TimelineToolKind::Mcp,
                format!("mcp__{server}__{name}"),
                &format!("{server} {name}"),
                &arguments_text(&arguments),
            )
        },
        CodexItem::DynamicToolCall {
            tool: name,
            status,
            arguments,
            duration_ms,
            ..
        } => TimelineTool {
            status: tool_status(&status),
            duration_ms,
            ..tool(
                TimelineToolKind::Other,
                name.clone(),
                &name,
                &arguments_text(&arguments),
            )
        },
        CodexItem::CollabAgentToolCall {
            tool: action,
            status,
            prompt,
            model,
            ..
        } => {
            let prompt = prompt.unwrap_or_default();
            let summary = prompt
                .lines()
                .map(str::trim)
                .find(|line| !line.is_empty())
                .map_or_else(|| agent_action(&action).to_owned(), str::to_owned);
            let input = match model {
                Some(model) if !prompt.is_empty() => format!("{prompt}\n\nModel: {model}"),
                _ => prompt,
            };
            TimelineTool {
                status: tool_status(&status),
                ..tool(
                    TimelineToolKind::Task,
                    agent_action(&action).into(),
                    &summary,
                    &input,
                )
            }
        }
        CodexItem::WebSearch { query, action, .. } => {
            let title = match action {
                Some(CodexWebSearchAction::OpenPage { url: Some(url) }) => url,
                Some(CodexWebSearchAction::FindInPage {
                    url: Some(url),
                    pattern,
                }) => match pattern {
                    Some(pattern) => format!("{pattern} in {url}"),
                    None => url,
                },
                _ => query,
            };
            tool(
                TimelineToolKind::WebSearch,
                "Web search".into(),
                &title,
                &title,
            )
        }
        CodexItem::ImageView { path, .. } => {
            tool(TimelineToolKind::Read, "View image".into(), &path, &path)
        }
        _ => return None,
    };
    Some((id, TimelineBody::Tool(TimelineTool { output, ..tool })))
}

fn tool_status(status: &str) -> TimelineToolStatus {
    match status {
        "completed" => TimelineToolStatus::Done,
        "inProgress" | "in_progress" => TimelineToolStatus::Running,
        "declined" => TimelineToolStatus::Denied,
        "interrupted" => TimelineToolStatus::Interrupted,
        _ => TimelineToolStatus::Failed,
    }
}

fn agent_action(action: &str) -> &'static str {
    match action {
        "spawnAgent" | "spawn_agent" => "Start agent",
        "sendInput" | "send_input" | "sendMessage" | "send_message" => "Message agent",
        "resumeAgent" | "resume_agent" => "Resume agent",
        "wait" => "Wait for agents",
        "closeAgent" | "close_agent" => "Close agent",
        "followupTask" | "followup_task" => "Follow-up task",
        "interruptAgent" | "interrupt_agent" => "Interrupt agent",
        "listAgents" | "list_agents" => "List agents",
        _ => "Agent",
    }
}

fn arguments_text(arguments: &serde_json::Value) -> String {
    match arguments {
        serde_json::Value::Null => String::new(),
        serde_json::Value::String(text) => text.clone(),
        arguments => arguments.to_string(),
    }
}

/// The bounded inline preview of one file of a change.
fn file_preview(change: &CodexFileChange) -> Vec<FileDiff> {
    use crate::timeline::claude_diff::{created_preview, deleted_preview, unified_preview};
    match &change.kind {
        CodexFileChangeKind::Add => created_preview(&change.path, &change.diff),
        CodexFileChangeKind::Delete => deleted_preview(&change.path, &change.diff),
        CodexFileChangeKind::Update { move_path } => {
            let path = move_path.as_deref().unwrap_or(&change.path);
            let mut diff = unified_preview(path, &change.diff);
            if move_path.is_some() {
                for file in &mut diff {
                    file.old_path = Some(change.path.clone());
                    file.change = proto::FileChange::Renamed;
                }
            }
            diff
        }
    }
}
