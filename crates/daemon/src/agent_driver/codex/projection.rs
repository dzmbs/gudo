use agents::{CodexInput, CodexItem, CodexLiveEvent};
use proto::{
    AgentKind, TimelineBody, TimelineCursor, TimelineField, TimelineItem, TimelineNoticeKind,
    TimelineOp, TimelineOrigin, TimelineSession, TimelineSnapshot, TimelineTool, TimelineToolKind,
    TimelineToolStatus, UnixMillis, WsError,
};
#[cfg(test)]
mod tests;

use std::collections::{HashMap, VecDeque};

const MAX_ITEMS: usize = 500;
const MAX_TEXT: usize = 256 * 1024;
const MAX_BYTES: usize = 768 * 1024;

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
            CodexLiveEvent::AssistantDelta { turn, item, text } => self.append(
                turn.clone(),
                format!("item:{}:{turn}:{item}", turn.len()),
                text,
            ),
            CodexLiveEvent::Item {
                turn,
                item,
                completed,
            } => {
                let (id, body) = body(item, completed, &turn);
                self.upsert(format!("item:{}:{turn}:{id}", turn.len()), turn, body)
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
            return Err(budget());
        };
        if current.len().saturating_add(text.len()) > MAX_TEXT
            || self.bytes.saturating_add(additional) > MAX_BYTES
        {
            return Err(budget());
        }
        current.push_str(&text);
        self.bytes += additional;
        item.revision = item.revision.saturating_add(1);
        operations.push(TimelineOp::Append {
            cursor: self.advance(),
            id,
            field: TimelineField::Text,
            text,
        });
        Ok(operations)
    }

    fn upsert(
        &mut self,
        id: String,
        turn: String,
        body: TimelineBody,
    ) -> Result<Vec<TimelineOp>, WsError> {
        let size = serde_json::to_vec(&body).map_err(|_| budget())?.len();
        if size > MAX_TEXT {
            return Err(budget());
        }
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
        if self.items.len() > MAX_ITEMS || self.bytes > MAX_BYTES {
            return Err(budget());
        }
        Ok(operations)
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
                            kind: TimelineNoticeKind::ModeChanged,
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
