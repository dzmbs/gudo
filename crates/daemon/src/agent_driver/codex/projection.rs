use agents::{CodexInput, CodexItem, CodexLiveEvent};
use proto::{
    AgentKind, TimelineBody, TimelineCursor, TimelineField, TimelineItem, TimelineNoticeKind,
    TimelineOp, TimelineOrigin, TimelineSession, TimelineSnapshot, TimelineTool, TimelineToolKind,
    TimelineToolStatus, UnixMillis, WsError,
};
#[cfg(test)]
mod tests;

use std::collections::{HashMap, VecDeque};

pub(super) const SNAPSHOT_ITEMS: usize = 60;
const MAX_ITEMS: usize = 500;
const MAX_TEXT: usize = 256 * 1024;
const MAX_BYTES: usize = 768 * 1024;
const PREVIEW_BYTES: usize = 96 * 1024;
const MIN_PREVIEW_BYTES: usize = 1024;
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
                item: CodexItem::UserMessage { content, .. },
                ..
            } if is_injected_context(&content) => Ok(Vec::new()),
            CodexLiveEvent::Item {
                turn,
                item,
                completed,
            } => {
                let (id, body) = body(item, completed, &turn);
                self.upsert(item_id(&turn, &id), turn, body)
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
                let notice = match outcome {
                    agents::CodexTurnOutcome::Completed => None,
                    agents::CodexTurnOutcome::Interrupted => {
                        Some((TimelineNoticeKind::Interrupted, "Turn interrupted."))
                    }
                    agents::CodexTurnOutcome::Failed => Some((
                        TimelineNoticeKind::Error,
                        "Turn failed. Check Terminal for details.",
                    )),
                    agents::CodexTurnOutcome::Unknown => Some((
                        TimelineNoticeKind::Error,
                        "Turn finished with an unknown status. Check Terminal.",
                    )),
                };
                if let Some((kind, text)) = notice {
                    operations.extend(self.upsert(
                        format!("turn:{turn}:status"),
                        turn,
                        TimelineBody::Notice {
                            kind,
                            text: text.into(),
                        },
                    )?);
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
        if current.len().saturating_add(text.len()) > MAX_TEXT {
            // Not streaming any more, so later deltas cannot land after the preview's marker;
            // the completed item replaces it.
            let body = TimelineBody::Assistant {
                text: format!("{current}{text}"),
                streaming: false,
            };
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
        let (body, size) = bounded(body)?;
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
            origin: if matches!(body, TimelineBody::User { .. }) {
                TimelineOrigin::Terminal
            } else {
                TimelineOrigin::Agent
            },
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

fn item_id(turn: &str, item: &str) -> String {
    format!("item:{}:{turn}:{item}", turn.len())
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

/// The body with its JSON weight, shortened to a preview of its start and end when it is over
/// the item limit.
fn bounded(body: TimelineBody) -> Result<(TimelineBody, usize), WsError> {
    let size = weight(&body)?;
    if size <= MAX_TEXT {
        return Ok((body, size));
    }
    let mut limit = PREVIEW_BYTES;
    while limit >= MIN_PREVIEW_BYTES {
        let shortened = shortened(&body, limit);
        let size = weight(&shortened)?;
        if size <= MAX_TEXT {
            return Ok((shortened, size));
        }
        limit /= 2;
    }
    let body = too_large();
    let size = weight(&body)?;
    Ok((body, size))
}

fn weight(body: &TimelineBody) -> Result<usize, WsError> {
    Ok(serde_json::to_vec(body).map_err(|_| budget())?.len())
}

fn shortened(body: &TimelineBody, limit: usize) -> TimelineBody {
    match body {
        TimelineBody::User {
            text,
            attachments,
            queued,
        } => TimelineBody::User {
            text: preview(text, limit),
            attachments: attachments.clone(),
            queued: *queued,
        },
        TimelineBody::Assistant { text, streaming } => TimelineBody::Assistant {
            text: preview(text, limit),
            streaming: *streaming,
        },
        TimelineBody::Thinking { text, duration_ms } => TimelineBody::Thinking {
            text: text.as_deref().map(|text| preview(text, limit)),
            duration_ms: *duration_ms,
        },
        TimelineBody::Tool(tool) => TimelineBody::Tool(TimelineTool {
            title: preview(&tool.title, limit),
            input: preview(&tool.input, limit),
            ..tool.clone()
        }),
        other => other.clone(),
    }
}

fn preview(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_owned();
    }
    let mut head_end = limit / 2;
    while !text.is_char_boundary(head_end) {
        head_end -= 1;
    }
    let mut tail_start = text.len() - limit / 2;
    while !text.is_char_boundary(tail_start) {
        tail_start += 1;
    }
    format!(
        "{}\n\n[Showing the start and end of {}. The rest is in Terminal.]\n\n{}",
        &text[..head_end],
        describe_size(text.len()),
        &text[tail_start..]
    )
}

fn describe_size(bytes: usize) -> String {
    const KIB: usize = 1024;
    const MIB: usize = 1024 * KIB;
    if bytes < MIB {
        format!("{} KB", bytes.div_ceil(KIB))
    } else {
        format!("{:.1} MB", bytes as f64 / MIB as f64)
    }
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

fn body(item: CodexItem, completed: bool, turn: &str) -> (String, TimelineBody) {
    match item {
        CodexItem::UserMessage { id, content } => {
            let mut text = String::new();
            for part in content {
                match part {
                    CodexInput::Text { text: part } => text.push_str(&part),
                    CodexInput::Unsupported => {
                        text.push_str("\n[Attachment available in Terminal]\n")
                    }
                }
            }
            (
                id,
                TimelineBody::User {
                    text,
                    attachments: Vec::new(),
                    queued: false,
                },
            )
        }
        CodexItem::AgentMessage { id, text } => (
            id,
            TimelineBody::Assistant {
                text,
                streaming: !completed,
            },
        ),
        CodexItem::Reasoning {
            id,
            summary,
            content,
        } => {
            let text = summary
                .into_iter()
                .chain(content)
                .collect::<Vec<_>>()
                .join("\n");
            (
                id,
                TimelineBody::Thinking {
                    text: (!text.is_empty()).then_some(text),
                    duration_ms: None,
                },
            )
        }
        CodexItem::CommandExecution {
            id,
            command,
            status,
            aggregated_output,
            exit_code,
            duration_ms,
        } => {
            let status = match status.as_str() {
                "completed" if exit_code.is_some_and(|code| code != 0) => {
                    TimelineToolStatus::Failed
                }
                "completed" => TimelineToolStatus::Done,
                "failed" => TimelineToolStatus::Failed,
                "declined" => TimelineToolStatus::Denied,
                "inProgress" => TimelineToolStatus::Running,
                _ => {
                    return (
                        id,
                        TimelineBody::Notice {
                            kind: TimelineNoticeKind::Error,
                            text: "Command state is unknown. Check Terminal.".into(),
                        },
                    );
                }
            };
            (
                id,
                TimelineBody::Tool(TimelineTool {
                    kind: TimelineToolKind::Shell,
                    name: "Shell".into(),
                    title: command.clone(),
                    input: [command, aggregated_output.unwrap_or_default()].join("\n"),
                    status,
                    output: None,
                    diff: Vec::new(),
                    exit: exit_code,
                    duration_ms,
                    command_mark: None,
                }),
            )
        }
        CodexItem::Unsupported => (
            format!("unsupported:{turn}"),
            TimelineBody::Notice {
                kind: TimelineNoticeKind::ModeChanged,
                text: "Additional agent details are available in Terminal.".into(),
            },
        ),
    }
}
