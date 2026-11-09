use std::path::Path;
use std::sync::{Arc, Weak};

use proto::{
    PaneId, TimelineBody, TimelineField, TimelineItem, TimelineOp, TimelineOrigin,
    TimelineSnapshot, UnixMillis,
};

use super::{claude_source::Source, transcript::Transcript, value_weight};
use crate::claude_display::{Capture, Message};
use crate::core::{PaneEntry, lock};

const OVERLAY_BYTES_LIMIT: usize = 768 * 1024;

#[cfg(test)]
mod tests;

pub(super) struct DisplayOverlay {
    capture: Arc<Capture>,
    pane: PaneId,
    entry: Weak<PaneEntry>,
    live: Vec<LiveItem>,
    masked: Vec<String>,
    needs_snapshot: bool,
    pub is_streaming: bool,
}

struct LiveItem {
    prompt: String,
    sequence: u64,
    message: Message,
    item: TimelineItem,
}

enum Resolution {
    Pending(String),
    Canonical,
    Missing,
    Conflict,
}

impl DisplayOverlay {
    pub fn new(capture: Arc<Capture>, pane: PaneId, entry: &Arc<PaneEntry>) -> Self {
        Self {
            capture,
            pane,
            entry: Arc::downgrade(entry),
            live: Vec::new(),
            masked: Vec::new(),
            needs_snapshot: false,
            is_streaming: false,
        }
    }

    pub fn reset(&mut self) {
        self.live.clear();
        self.masked.clear();
        self.needs_snapshot = false;
        self.is_streaming = false;
    }

    pub fn refresh(&mut self, source: &Source, transcript: &mut Transcript) -> Vec<TimelineOp> {
        self.needs_snapshot = false;
        let snapshot = self
            .entry
            .upgrade()
            .and_then(|entry| {
                let launch = lock(&entry.pane.agent_input_gate)
                    .active_launch()
                    .map(str::to_owned)?;
                self.capture
                    .snapshot(self.pane, &entry, &launch, &source.native_session)
            })
            .filter(|snapshot| {
                snapshot.session == source.native_session
                    && same_path(&snapshot.transcript, &transcript.path)
                    && same_path(&snapshot.cwd, &source.working_directory)
            });
        self.is_streaming = snapshot
            .as_ref()
            .is_some_and(|snapshot| snapshot.is_usable && snapshot.revision > 0);
        let mut operations = Vec::new();
        let mut retained = Vec::new();
        for live in self.live.drain(..) {
            let pending = matches!(
                resolve(transcript, &live.prompt, &live.message),
                Resolution::Pending(_)
            );
            if pending && snapshot.as_ref().is_some_and(|snapshot| snapshot.is_usable) {
                retained.push(live);
            } else {
                operations.push(TimelineOp::Remove {
                    cursor: transcript.next_cursor(),
                    id: live.item.id,
                });
                self.capture
                    .retire(self.pane, live.sequence, &live.message.id);
            }
        }
        self.live = retained;
        let Some(snapshot) = snapshot.filter(|snapshot| snapshot.is_usable) else {
            self.synchronize_masks(transcript);
            return operations;
        };
        for message in snapshot.messages {
            if message.text.is_empty() {
                continue;
            }
            let turn = match resolve(transcript, &snapshot.prompt, &message) {
                Resolution::Pending(turn) => {
                    let already_live = self.live.iter().any(|live| {
                        live.sequence == snapshot.sequence && live.message.id == message.id
                    });
                    // Never hide canonical rows that may already have reached a reader just
                    // to introduce a late provisional row. Canonical delivery wins that race.
                    if !already_live
                        && canonical_group(transcript, &snapshot.prompt, &message).is_some()
                    {
                        self.capture
                            .retire(self.pane, snapshot.sequence, &message.id);
                        continue;
                    }
                    turn
                }
                Resolution::Canonical => {
                    self.capture
                        .retire(self.pane, snapshot.sequence, &message.id);
                    continue;
                }
                Resolution::Missing => continue,
                Resolution::Conflict => {
                    self.capture.disable(self.pane, snapshot.sequence);
                    self.is_streaming = false;
                    for live in self.live.drain(..) {
                        operations.push(TimelineOp::Remove {
                            cursor: transcript.next_cursor(),
                            id: live.item.id,
                        });
                    }
                    break;
                }
            };
            let retained_bytes = self
                .live
                .iter()
                .map(|live| value_weight::item(&live.item))
                .sum::<usize>();
            let previous_bytes = self
                .live
                .iter()
                .find(|live| live.sequence == snapshot.sequence && live.message.id == message.id)
                .map_or(0, |live| live.message.text.len());
            if retained_bytes
                .saturating_sub(previous_bytes)
                .saturating_add(message.text.len())
                .saturating_add(1024)
                > OVERLAY_BYTES_LIMIT
            {
                self.capture.disable(self.pane, snapshot.sequence);
                self.is_streaming = false;
                for live in self.live.drain(..) {
                    operations.push(TimelineOp::Remove {
                        cursor: transcript.next_cursor(),
                        id: live.item.id,
                    });
                }
                break;
            }
            let is_streaming = !message.is_final;
            if let Some(live) = self
                .live
                .iter_mut()
                .find(|live| live.sequence == snapshot.sequence && live.message.id == message.id)
            {
                let TimelineBody::Assistant { text, streaming } = &mut live.item.body else {
                    continue;
                };
                if *text == message.text && *streaming == is_streaming {
                    continue;
                }
                live.item.revision = live.item.revision.saturating_add(1);
                if message.text.starts_with(text.as_str()) && *streaming == is_streaming {
                    let delta = message.text[text.len()..].to_owned();
                    *text = message.text.clone();
                    operations.push(TimelineOp::Append {
                        cursor: transcript.next_cursor(),
                        id: live.item.id.clone(),
                        field: TimelineField::Text,
                        text: delta,
                    });
                } else {
                    *text = message.text.clone();
                    *streaming = !message.is_final;
                    operations.push(TimelineOp::Upsert {
                        cursor: transcript.next_cursor(),
                        item: Box::new(live.item.clone()),
                    });
                }
                live.message = message;
            } else {
                let item = TimelineItem {
                    id: format!("claude-display:{}:{}", snapshot.prompt, message.id),
                    revision: 1,
                    turn: Some(turn),
                    parent: None,
                    at: UnixMillis(0),
                    origin: TimelineOrigin::Agent,
                    body: TimelineBody::Assistant {
                        text: message.text.clone(),
                        streaming: !message.is_final,
                    },
                };
                operations.push(TimelineOp::Upsert {
                    cursor: transcript.next_cursor(),
                    item: Box::new(item.clone()),
                });
                self.live.push(LiveItem {
                    prompt: snapshot.prompt.clone(),
                    sequence: snapshot.sequence,
                    message,
                    item,
                });
            }
        }
        self.synchronize_masks(transcript);
        operations
    }

    // A shorter canonical prefix must neither duplicate nor truncate text already shown.
    // Atomic, same-epoch snapshots preserve canonical ordering (including interleaved tools)
    // when these masks change; the client retains its older, overlapping history.
    fn synchronize_masks(&mut self, transcript: &mut Transcript) {
        let mut masked = Vec::new();
        for live in &self.live {
            if let Some(group) = canonical_group(transcript, &live.prompt, &live.message) {
                for id in &group.items {
                    if !masked.contains(id) {
                        masked.push(id.clone());
                    }
                }
            }
        }
        if self.masked != masked {
            self.needs_snapshot = true;
            transcript.next_cursor();
            self.masked = masked;
        }
    }

    pub fn filter_operations(&self, transcript: &Transcript, operations: &mut Vec<TimelineOp>) {
        if self.needs_snapshot
            || operations
                .iter()
                .any(|operation| matches!(operation, TimelineOp::Snapshot(_)))
        {
            *operations = vec![TimelineOp::Snapshot(self.snapshot(transcript, None))];
            return;
        }
        for operation in operations {
            if let TimelineOp::Upsert { cursor, item } = operation
                && self.masked.contains(&item.id)
            {
                *operation = TimelineOp::Checkpoint { cursor: *cursor };
            }
        }
    }

    pub fn filter_snapshot(&self, snapshot: &mut TimelineSnapshot) {
        snapshot
            .items
            .retain(|item| !self.masked.contains(&item.id));
    }

    pub fn snapshot(&self, transcript: &Transcript, since: Option<UnixMillis>) -> TimelineSnapshot {
        if since.is_some() || self.live.is_empty() {
            let mut snapshot = transcript.snapshot(60, since);
            self.filter_snapshot(&mut snapshot);
            return snapshot;
        }
        let metadata = transcript.snapshot(0, None);
        let live_bytes = self
            .live
            .iter()
            .map(|live| value_weight::item(&live.item))
            .sum::<usize>();
        let budget = super::MAX_PUSH_BYTES
            .saturating_sub(value_weight::snapshot(&metadata))
            .saturating_sub(live_bytes)
            .saturating_sub(1024);
        let mut snapshot = transcript.snapshot_with_budget(60, None, budget);
        let mut placed = Vec::new();
        let mut items = Vec::new();
        for item in std::mem::take(&mut snapshot.items) {
            for live in &self.live {
                if !placed.contains(&live.item.id)
                    && canonical_group(transcript, &live.prompt, &live.message)
                        .is_some_and(|group| group.items.contains(&item.id))
                {
                    items.push(live.item.clone());
                    placed.push(live.item.id.clone());
                }
            }
            if !self.masked.contains(&item.id) {
                items.push(item);
            }
        }
        snapshot.items = items;
        for live in &self.live {
            if placed.contains(&live.item.id) {
                continue;
            }
            let position = snapshot
                .items
                .iter()
                .position(|item| Some(&item.id) == live.item.turn.as_ref())
                .and_then(|position| {
                    snapshot
                        .items
                        .iter()
                        .enumerate()
                        .skip(position + 1)
                        .find_map(|(index, item)| {
                            matches!(item.body, TimelineBody::User { .. }).then_some(index)
                        })
                })
                .unwrap_or(snapshot.items.len());
            snapshot.items.insert(position, live.item.clone());
        }
        snapshot
    }
}

fn resolve(transcript: &Transcript, prompt_id: &str, message: &Message) -> Resolution {
    let Some(prompt) = transcript.display_prompt(prompt_id) else {
        return Resolution::Missing;
    };
    if !prompt.is_usable {
        return Resolution::Conflict;
    }
    let Some(group) = usize::try_from(message.ordinal)
        .ok()
        .and_then(|ordinal| prompt.groups.get(ordinal))
    else {
        return Resolution::Pending(prompt.turn.clone());
    };
    let Some(text) = transcript.display_text(group) else {
        return Resolution::Canonical;
    };
    if text.starts_with(&message.text) {
        Resolution::Canonical
    } else if message.text.starts_with(&text) {
        Resolution::Pending(prompt.turn.clone())
    } else {
        Resolution::Conflict
    }
}

fn canonical_group<'a>(
    transcript: &'a Transcript,
    prompt_id: &str,
    message: &Message,
) -> Option<&'a super::display_index::DisplayGroup> {
    transcript
        .display_prompt(prompt_id)?
        .groups
        .get(usize::try_from(message.ordinal).ok()?)
}

fn same_path(left: &Path, right: &Path) -> bool {
    left == right
        || left
            .canonicalize()
            .ok()
            .zip(right.canonicalize().ok())
            .is_some_and(|(left, right)| left == right)
}
