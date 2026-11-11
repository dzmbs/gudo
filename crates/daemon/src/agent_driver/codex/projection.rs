use agents::{CodexInput, CodexItem, CodexLiveEvent};
use proto::{
    AgentKind, OutputHandle, TimelineBody, TimelineCursor, TimelineField, TimelineItem,
    TimelineNoticeKind, TimelineOp, TimelineOrigin, TimelineOutputRef, TimelineSession,
    TimelineSnapshot, TimelineTextRole, TimelineTool, TimelineToolKind, TimelineToolStatus,
    UnixMillis, WsError,
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

pub(super) struct Projection {
    cursor: TimelineCursor,
    session: TimelineSession,
    items: HashMap<String, (u64, TimelineItem)>,
    order: VecDeque<String>,
    next_item: u64,
    bytes: usize,
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
        }
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
            CodexLiveEvent::TurnCompleted { turn, outcome } => {
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
                if let Some(body) = turn_notice(outcome) {
                    operations.extend(self.upsert(turn_notice_id(&turn), turn, body)?);
                }
                Ok(operations)
            }
            CodexLiveEvent::TurnStarted { .. }
            | CodexLiveEvent::ApprovalWaiting { .. }
            | CodexLiveEvent::ApprovalResolved { .. } => Ok(Vec::new()),
        }
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

pub(super) fn turn_notice(outcome: agents::CodexTurnOutcome) -> Option<TimelineBody> {
    let (kind, text) = match outcome {
        agents::CodexTurnOutcome::Completed => return None,
        agents::CodexTurnOutcome::Interrupted => {
            (TimelineNoticeKind::Interrupted, "Turn interrupted.")
        }
        agents::CodexTurnOutcome::Failed => (
            TimelineNoticeKind::Error,
            "Turn failed. Check Terminal for details.",
        ),
        agents::CodexTurnOutcome::Unknown => (
            TimelineNoticeKind::Error,
            "Turn finished with an unknown status. Check Terminal.",
        ),
    };
    Some(TimelineBody::Notice {
        kind,
        text: text.into(),
    })
}

fn is_injected_context(content: &[CodexInput]) -> bool {
    !content.is_empty()
        && content.iter().all(|part| match part {
            CodexInput::Text { text } => INJECTED_CONTEXT_MARKERS
                .iter()
                .any(|(start, end)| is_marked(text, start, end)),
            CodexInput::Unsupported => false,
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
    match item {
        CodexItem::UserMessage { content, .. } => Some(user_text(content)),
        CodexItem::AgentMessage { text, .. } => Some(text.clone()),
        CodexItem::Reasoning {
            summary, content, ..
        } => Some(reasoning_text(summary, content)),
        CodexItem::CommandExecution {
            aggregated_output, ..
        } => aggregated_output.clone(),
        CodexItem::Unsupported => None,
    }
}

fn user_text(content: &[CodexInput]) -> String {
    let mut text = String::new();
    for part in content {
        match part {
            CodexInput::Text { text: part } => text.push_str(part),
            CodexInput::Unsupported => text.push_str("\n[Attachment available in Terminal]\n"),
        }
    }
    text
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
            let body = fitted_text(TimelineTextRole::User, user_text(&content), &id, location);
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
