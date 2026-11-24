//! What pi is streaming, shown over its session file until pi writes the message there.

use std::collections::VecDeque;

use proto::{
    TimelineBody, TimelineCommand, TimelineCommandSource, TimelineField, TimelineItem, TimelineOp,
    TimelineOrigin, TimelineSession, UnixMillis,
};

use super::bridge::{BlockKind, Bridge, LiveState};

/// Assistant messages read from the file, remembered to retire their streamed copies.
const RECORDED_LIMIT: usize = 64;

#[derive(Default)]
pub(super) struct Overlay {
    shown: Vec<TimelineItem>,
    recorded: VecDeque<u64>,
}

impl Overlay {
    pub fn recorded(&mut self, timestamps: &[u64]) {
        for timestamp in timestamps {
            if !self.recorded.contains(timestamp) {
                self.recorded.push_back(*timestamp);
            }
        }
        while self.recorded.len() > RECORDED_LIMIT {
            self.recorded.pop_front();
        }
    }

    pub fn shown(&self) -> &[TimelineItem] {
        &self.shown
    }

    /// Forgets the shown rows: a new snapshot leaves them out until the next update.
    pub fn clear(&mut self) {
        self.shown.clear();
    }

    /// The operations that bring the shown rows to what `bridge` streams now.
    pub fn update(
        &mut self,
        bridge: Option<&Bridge>,
        mut advance: impl FnMut() -> proto::TimelineCursor,
    ) -> Vec<TimelineOp> {
        let wanted = bridge.map_or_else(Vec::new, |bridge| {
            bridge.recorded(self.recorded.make_contiguous());
            items(&bridge.state(), self.recorded.as_slices().0)
        });
        let mut operations = Vec::new();
        let gone: Vec<String> = self
            .shown
            .iter()
            .filter(|shown| !wanted.iter().any(|item| item.id == shown.id))
            .map(|shown| shown.id.clone())
            .collect();
        for id in gone {
            self.shown.retain(|shown| shown.id != id);
            operations.push(TimelineOp::Remove {
                cursor: advance(),
                id,
            });
        }
        for mut item in wanted {
            let Some(shown) = self.shown.iter_mut().find(|shown| shown.id == item.id) else {
                self.shown.push(item.clone());
                operations.push(TimelineOp::Upsert {
                    cursor: advance(),
                    item: Box::new(item),
                });
                continue;
            };
            if shown.body == item.body {
                continue;
            }
            item.revision = shown.revision.saturating_add(1);
            let appended = appended(&shown.body, &item.body);
            *shown = item.clone();
            operations.push(match appended {
                Some((field, text)) => TimelineOp::Append {
                    cursor: advance(),
                    id: item.id,
                    field,
                    text,
                },
                None => TimelineOp::Upsert {
                    cursor: advance(),
                    item: Box::new(item),
                },
            });
        }
        operations
    }
}

/// The rows of messages pi streams that its file does not hold yet.
fn items(state: &LiveState, recorded: &[u64]) -> Vec<TimelineItem> {
    state
        .messages
        .iter()
        .filter(|message| !recorded.contains(&message.timestamp))
        .flat_map(|message| {
            message.blocks.iter().map(move |(index, block)| {
                let body = match block.kind {
                    BlockKind::Text => TimelineBody::Assistant {
                        text: block.text.clone(),
                        streaming: message.ended.is_none(),
                    },
                    BlockKind::Thinking => TimelineBody::Thinking {
                        text: Some(block.text.clone()),
                        duration_ms: None,
                    },
                };
                TimelineItem {
                    id: format!("live:{}:{index}", message.timestamp),
                    revision: 1,
                    turn: None,
                    parent: None,
                    at: UnixMillis(message.timestamp),
                    origin: TimelineOrigin::Agent,
                    body,
                }
            })
        })
        .filter(
            |item| !matches!(&item.body, TimelineBody::Assistant { text, .. } if text.is_empty()),
        )
        .collect()
}

/// The text `newer` adds at the end of `older`, when that is all that changed.
fn appended(older: &TimelineBody, newer: &TimelineBody) -> Option<(TimelineField, String)> {
    match (older, newer) {
        (
            TimelineBody::Assistant {
                text: old,
                streaming: true,
            },
            TimelineBody::Assistant {
                text: new,
                streaming: true,
            },
        ) => Some((
            TimelineField::Text,
            new.strip_prefix(old.as_str())?.to_owned(),
        )),
        (
            TimelineBody::Thinking {
                text: Some(old),
                duration_ms: None,
            },
            TimelineBody::Thinking {
                text: Some(new),
                duration_ms: None,
            },
        ) => Some((
            TimelineField::Thinking,
            new.strip_prefix(old.as_str())?.to_owned(),
        )),
        _ => None,
    }
}

/// `session` with what pi reports of itself: its model and its slash commands.
pub(super) fn session(mut session: TimelineSession, state: &LiveState) -> TimelineSession {
    if let Some(model) = state
        .session
        .as_ref()
        .and_then(|session| session.model.as_ref())
    {
        session.model = Some(model.label());
    }
    if !state.commands.is_empty() {
        session.commands = state
            .commands
            .iter()
            .map(|command| TimelineCommand {
                name: format!("/{}", command.name),
                description: command.description.clone(),
                source: if command.scope == "project" {
                    TimelineCommandSource::Project
                } else {
                    TimelineCommandSource::User
                },
            })
            .collect();
    }
    session
}
