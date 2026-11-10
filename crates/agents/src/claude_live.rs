use std::collections::VecDeque;
use std::path::PathBuf;

use serde::Deserialize;

pub const CLAUDE_DISPLAY_BATCH_LIMIT: usize = 64 * 1024;
const MESSAGE_LIMIT: usize = 256 * 1024;
const STREAM_LIMIT: usize = 768 * 1024;
const MESSAGE_COUNT_LIMIT: usize = 16;
/// Retired identities remembered so a retried batch is not shown twice.
const RETIRED_LIMIT: usize = 1024;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ClaudeDisplayError {
    #[error("invalid Claude display batch")]
    Invalid,
    #[error("Claude display batch belongs to another context")]
    Context,
    #[error("Claude display batches arrived out of order")]
    Order,
    #[error("Claude display capture exceeded its bound")]
    Limit,
}

#[derive(Debug, Deserialize)]
#[serde(try_from = "RawBatch")]
pub struct ClaudeDisplayBatch {
    pub session_id: String,
    pub prompt_id: Option<String>,
    pub turn_id: String,
    pub message_id: String,
    pub index: u64,
    pub is_final: bool,
    pub delta: String,
    pub transcript_path: PathBuf,
    pub cwd: PathBuf,
}

#[derive(Deserialize)]
struct RawBatch {
    hook_event_name: String,
    session_id: String,
    #[serde(default)]
    prompt_id: Option<String>,
    turn_id: String,
    message_id: String,
    index: u64,
    #[serde(rename = "final")]
    is_final: bool,
    delta: String,
    transcript_path: PathBuf,
    cwd: PathBuf,
    #[serde(default)]
    agent_id: Option<String>,
}

impl ClaudeDisplayBatch {
    pub fn decode(bytes: &[u8]) -> Result<Self, ClaudeDisplayError> {
        if bytes.len() > CLAUDE_DISPLAY_BATCH_LIMIT {
            return Err(ClaudeDisplayError::Limit);
        }
        serde_json::from_slice(bytes).map_err(|_| ClaudeDisplayError::Invalid)
    }
}

impl TryFrom<RawBatch> for ClaudeDisplayBatch {
    type Error = ClaudeDisplayError;

    fn try_from(batch: RawBatch) -> Result<Self, Self::Error> {
        if batch.hook_event_name != "MessageDisplay"
            || batch.agent_id.is_some()
            || [&batch.session_id, &batch.turn_id, &batch.message_id]
                .iter()
                .any(|id| !is_uuid(id))
            || batch.prompt_id.as_ref().is_some_and(|id| !is_uuid(id))
            || !batch.cwd.is_absolute()
            || !batch.transcript_path.is_absolute()
            || batch.delta.len() > CLAUDE_DISPLAY_BATCH_LIMIT
            || (!batch.is_final && !batch.delta.ends_with('\n'))
        {
            return Err(ClaudeDisplayError::Invalid);
        }
        Ok(Self {
            session_id: batch.session_id,
            prompt_id: batch.prompt_id,
            turn_id: batch.turn_id,
            message_id: batch.message_id,
            index: batch.index,
            is_final: batch.is_final,
            delta: batch.delta,
            transcript_path: batch.transcript_path,
            cwd: batch.cwd,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClaudeDisplayMessage {
    pub id: String,
    pub ordinal: u64,
    pub text: String,
    pub is_final: bool,
    next_index: u64,
    last_delta: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClaudeDisplayChange {
    Updated,
    Duplicate,
}

/// Display-only reassembly; callers separately admit the pane, session, prompt and paths.
pub struct ClaudeDisplayStream {
    session_id: String,
    prompt_id: Option<String>,
    turn_id: Option<String>,
    messages: Vec<ClaudeDisplayMessage>,
    retired: VecDeque<String>,
    next_ordinal: u64,
    bytes: usize,
}

impl ClaudeDisplayStream {
    pub fn new(session_id: String, prompt_id: Option<String>) -> Self {
        Self {
            session_id,
            prompt_id,
            turn_id: None,
            messages: Vec::new(),
            retired: VecDeque::new(),
            next_ordinal: 0,
            bytes: 0,
        }
    }

    pub fn messages(&self) -> &[ClaudeDisplayMessage] {
        &self.messages
    }

    pub fn apply(
        &mut self,
        batch: ClaudeDisplayBatch,
    ) -> Result<ClaudeDisplayChange, ClaudeDisplayError> {
        if batch.session_id != self.session_id
            || batch.prompt_id != self.prompt_id
            || self
                .turn_id
                .as_ref()
                .is_some_and(|turn| turn != &batch.turn_id)
        {
            return Err(ClaudeDisplayError::Context);
        }
        if self.retired.iter().any(|id| id == &batch.message_id) {
            return Ok(ClaudeDisplayChange::Duplicate);
        }
        if let Some(message) = self
            .messages
            .iter_mut()
            .find(|message| message.id == batch.message_id)
        {
            if batch.index.checked_add(1) == Some(message.next_index)
                && batch.delta == message.last_delta
                && batch.is_final == message.is_final
            {
                return Ok(ClaudeDisplayChange::Duplicate);
            }
            if message.is_final || batch.index != message.next_index {
                return Err(ClaudeDisplayError::Order);
            }
            let next_bytes = self
                .bytes
                .saturating_sub(message.last_delta.len())
                .saturating_add(batch.delta.len().saturating_mul(2));
            if message.text.len().saturating_add(batch.delta.len()) > MESSAGE_LIMIT
                || next_bytes > STREAM_LIMIT
            {
                return Err(ClaudeDisplayError::Limit);
            }
            let next_index = message
                .next_index
                .checked_add(1)
                .ok_or(ClaudeDisplayError::Order)?;
            self.bytes = next_bytes;
            message.text.push_str(&batch.delta);
            message.last_delta = batch.delta;
            message.is_final = batch.is_final;
            message.next_index = next_index;
        } else {
            if batch.index != 0 {
                return Err(ClaudeDisplayError::Order);
            }
            let additional = batch.delta.len().saturating_mul(2);
            while self.messages.len() >= MESSAGE_COUNT_LIMIT
                || self.bytes.saturating_add(additional) > STREAM_LIMIT
            {
                let finished = self
                    .messages
                    .iter()
                    .find(|message| message.is_final)
                    .map(|message| message.id.clone())
                    .ok_or(ClaudeDisplayError::Limit)?;
                self.retire(&finished);
            }
            self.bytes += batch.delta.len() * 2;
            self.turn_id = Some(batch.turn_id);
            self.messages.push(ClaudeDisplayMessage {
                id: batch.message_id,
                ordinal: self.next_ordinal,
                text: batch.delta.clone(),
                is_final: batch.is_final,
                next_index: 1,
                last_delta: batch.delta,
            });
            self.next_ordinal += 1;
        }
        Ok(ClaudeDisplayChange::Updated)
    }

    pub fn retire(&mut self, message_id: &str) {
        if let Some(index) = self
            .messages
            .iter()
            .position(|message| message.id == message_id)
        {
            let message = self.messages.remove(index);
            self.bytes -= message.text.len() + message.last_delta.len();
            self.retired.push_back(message.id);
            if self.retired.len() > RETIRED_LIMIT {
                self.retired.pop_front();
            }
        }
    }
}

pub fn claude_supports_message_display(version: &str) -> bool {
    if version.len() > 128 {
        return false;
    }
    let Some(version) = version.trim().strip_suffix(" (Claude Code)") else {
        return false;
    };
    let numbers = version
        .split('.')
        .map(|part| {
            (!part.is_empty()
                && part.bytes().all(|byte| byte.is_ascii_digit())
                && (part == "0" || !part.starts_with('0')))
            .then(|| part.parse::<u64>().ok())
            .flatten()
        })
        .collect::<Option<Vec<_>>>();
    matches!(numbers.as_deref(), Some([major, minor, patch]) if (*major, *minor, *patch) >= (2, 1, 69))
}

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

#[cfg(test)]
mod tests;
