//! Exact thread correlation for one pane-owned Codex app-server TUI connection.
//!
//! Notifications and cwd matches are not ownership evidence. Only a reply to this connection's
//! observed thread/start, thread/resume or thread/fork request can establish a binding. This
//! observer does not open sockets, start agents, attach threads or authorize native input.

use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, Ordering};

mod approval;
mod events;
mod history;
pub use approval::CodexApprovalDetails;
mod items;
pub use events::{CodexApprovalKind, CodexLiveEvent, CodexLiveEvents, CodexTurnOutcome};
pub use history::{CodexHistoryStatus, CodexHistoryTurn, CodexThreadHistory};
pub use items::{CodexInput, CodexItem};

use serde::de::{DeserializeOwned, IgnoredAny};
use serde::{Deserialize, Serialize};

/// The largest app-server message observed; Codex caps one command's output at 1 MiB, which
/// JSON escaping can grow several times over.
pub const CODEX_FRAME_LIMIT: usize = 8 * 1024 * 1024;
const MAX_ID_BYTES: usize = 128;
const MAX_BINDING_REQUESTS: usize = 256;
static NEXT_BINDING: AtomicU64 = AtomicU64::new(1);

/// A correlated thread on one physical TUI connection, not permission to control that thread.
///
/// Snapshots also carry a private, non-reused identity. Resuming the same thread later cannot
/// revive old work. Check [`CodexBinding::is_current`] at dispatch as well as owner authorization.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct CodexThreadBinding {
    thread: String,
    identity: u64,
}

impl CodexThreadBinding {
    /// Returns the official opaque thread ID from the correlated response.
    pub fn thread_id(&self) -> &str {
        &self.thread
    }
}

/// Bounded passive observer owned by one proven pane/account TUI transport, never by a view.
///
/// Feed only TUI-origin frames to [`Self::observe_tui`], and that connection's upstream frames
/// to [`Self::observe_server`]. An observation failure closes native binding permanently; the
/// relay still forwards official frames unchanged so Terminal remains usable.
///
/// # Examples
///
/// ```
/// use agents::CodexBinding;
/// let mut connection = CodexBinding::default();
/// connection.observe_tui(r#"{"id":1,"method":"thread/start","params":{}}"#)?;
/// connection.observe_server(r#"{"id":1,"result":{"thread":{"id":"example-thread"}}}"#)?;
/// assert_eq!(connection.binding().map(|value| value.thread_id()), Some("example-thread"));
/// # Ok::<(), agents::CodexBindingError>(())
/// ```
#[derive(Debug, Default)]
pub struct CodexBinding {
    state: State,
    seen: HashSet<RpcId>,
}

#[derive(Debug, Default)]
enum State {
    #[default]
    Unbound,
    Waiting {
        id: RpcId,
        expected: Option<String>,
    },
    Bound(CodexThreadBinding),
    Closed,
}

/// Official JSON-RPC identifiers retain their numeric or string identity.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(untagged)]
pub enum CodexRpcId {
    Integer(i64),
    Text(String),
}

type RpcId = CodexRpcId;

#[derive(Deserialize)]
struct TuiFrame {
    id: Option<RpcId>,
    method: Option<String>,
    params: Option<ThreadParams>,
}

#[derive(Deserialize)]
struct ThreadParams {
    #[serde(rename = "threadId")]
    thread: Option<String>,
    #[serde(rename = "threadSource")]
    purpose: Option<ThreadPurpose>,
    ephemeral: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum ThreadPurpose {
    User,
    ThreadTitle,
    #[serde(other)]
    Unknown,
}

impl ThreadParams {
    fn is_auxiliary(&self) -> Result<bool, CodexBindingError> {
        match (&self.purpose, self.ephemeral) {
            (Some(ThreadPurpose::ThreadTitle), Some(true)) => Ok(true),
            (Some(ThreadPurpose::User), _) | (None, None | Some(false)) => Ok(false),
            _ => Err(CodexBindingError::InvalidFrame),
        }
    }
}

#[derive(Deserialize)]
struct ServerFrame {
    id: Option<RpcId>,
    method: Option<String>,
    result: Option<ThreadResult>,
    error: Option<IgnoredAny>,
}

#[derive(Deserialize)]
struct ThreadResult {
    thread: Option<ThreadInfo>,
}

#[derive(Deserialize)]
struct ThreadInfo {
    id: String,
}

/// Why a connection cannot supply an exact native binding.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodexBindingError {
    /// The observer's bounded frame or identity allowance was exceeded.
    TooLarge,
    /// A binding request/response was malformed or ambiguous.
    InvalidFrame,
    /// A resume reply named a different thread than the observed request.
    ThreadMismatch,
    /// Binding identities or the connection's retained request IDs were exhausted.
    Exhausted,
    /// This observer was closed and cannot be reused for another transport.
    Closed,
}

impl std::fmt::Display for CodexBindingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::TooLarge => "Codex binding observation exceeds its allowance",
            Self::InvalidFrame => "Codex binding observation is ambiguous",
            Self::ThreadMismatch => "Codex resume response names another thread",
            Self::Exhausted => "Codex binding identity allowance is exhausted",
            Self::Closed => "Codex binding connection is closed",
        })
    }
}

impl std::error::Error for CodexBindingError {}

impl CodexBinding {
    /// Returns the currently correlated binding, or none while starting/changing/closed.
    pub fn binding(&self) -> Option<&CodexThreadBinding> {
        match &self.state {
            State::Bound(binding) => Some(binding),
            _ => None,
        }
    }

    /// Whether deferred work still belongs to this exact successful binding.
    pub fn is_current(&self, binding: &CodexThreadBinding) -> bool {
        self.binding() == Some(binding)
    }

    /// The exact outstanding binding request, not authority to issue a request.
    pub fn pending_request(&self) -> Option<&CodexRpcId> {
        match &self.state {
            State::Waiting { id, .. } => Some(id),
            _ => None,
        }
    }

    /// Observes an outgoing TUI frame without changing or forwarding it.
    ///
    /// A user binding request retires the old binding before any response arrives.
    /// Version-tested ephemeral title requests preserve the visible conversation.
    ///
    /// # Errors
    ///
    /// Returns an error and permanently closes native binding for malformed/oversized frames,
    /// reused binding request IDs, exhausted allowances or an already-closed connection.
    pub fn observe_tui(&mut self, frame: &str) -> Result<(), CodexBindingError> {
        let result = self.tui(frame);
        if result.is_err() {
            self.close();
        }
        result
    }

    fn tui(&mut self, frame: &str) -> Result<(), CodexBindingError> {
        self.ensure_open()?;
        let frame: TuiFrame = parse(frame)?;
        let Some(method) = frame.method.as_deref() else {
            return Ok(());
        };
        if !matches!(method, "thread/start" | "thread/resume" | "thread/fork") {
            if let State::Waiting { id, .. } = &self.state
                && frame.id.as_ref() == Some(id)
            {
                return Err(CodexBindingError::InvalidFrame);
            }
            return Ok(());
        }
        let id = frame.id.ok_or(CodexBindingError::InvalidFrame)?;
        if let RpcId::Text(text) = &id {
            validate_id(text)?;
        }
        let auxiliary = method == "thread/start"
            && frame
                .params
                .as_ref()
                .map(ThreadParams::is_auxiliary)
                .transpose()?
                .unwrap_or(false);
        let parent = if method != "thread/start" {
            let thread = frame
                .params
                .and_then(|params| params.thread)
                .ok_or(CodexBindingError::InvalidFrame)?;
            validate_id(&thread)?;
            Some(thread)
        } else {
            None
        };
        if self.seen.len() >= MAX_BINDING_REQUESTS {
            return Err(CodexBindingError::Exhausted);
        }
        if !self.seen.insert(id.clone()) {
            return Err(CodexBindingError::InvalidFrame);
        }
        if auxiliary {
            return Ok(());
        }
        self.state = State::Waiting {
            id,
            expected: if method == "thread/resume" {
                parent
            } else {
                None
            },
        };
        Ok(())
    }

    /// Observes an upstream frame; unsolicited thread notifications cannot create a binding.
    ///
    /// Frames are not decoded while no binding reply is pending. The observation limit is never
    /// a transport limit for the TUI.
    ///
    /// # Errors
    ///
    /// Returns an error and closes native binding if a pending binding cannot be correlated,
    /// a resume reply changes identity, or the connection is already closed.
    pub fn observe_server(&mut self, frame: &str) -> Result<(), CodexBindingError> {
        let result = self.server(frame);
        if result.is_err() {
            self.close();
        }
        result
    }

    fn server(&mut self, frame: &str) -> Result<(), CodexBindingError> {
        self.ensure_open()?;
        if !matches!(self.state, State::Waiting { .. }) {
            return Ok(());
        }
        let frame: ServerFrame = parse(frame)?;
        if frame.method.is_some() {
            return Ok(());
        }
        let id = frame.id.ok_or(CodexBindingError::InvalidFrame)?;
        if let RpcId::Text(text) = &id {
            validate_id(text)?;
        }
        let State::Waiting {
            id: pending,
            expected,
        } = &self.state
        else {
            return Ok(());
        };
        if &id != pending {
            return Ok(());
        }
        if frame.error.is_some() {
            if frame.result.is_some() {
                return Err(CodexBindingError::InvalidFrame);
            }
            self.state = State::Unbound;
            return Ok(());
        }
        let thread = frame
            .result
            .and_then(|result| result.thread)
            .ok_or(CodexBindingError::InvalidFrame)?
            .id;
        validate_id(&thread)?;
        if expected
            .as_ref()
            .is_some_and(|expected| expected != &thread)
        {
            return Err(CodexBindingError::ThreadMismatch);
        }
        // Relaxed ordering supplies uniqueness only; connection state has a single owner.
        let identity = NEXT_BINDING
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
            .map_err(|_| CodexBindingError::Exhausted)?;
        self.state = State::Bound(CodexThreadBinding { thread, identity });
        Ok(())
    }

    /// Irreversibly retires this physical connection and all its deferred snapshots.
    pub fn close(&mut self) {
        self.state = State::Closed;
        self.seen.clear();
    }

    fn ensure_open(&self) -> Result<(), CodexBindingError> {
        if matches!(self.state, State::Closed) {
            Err(CodexBindingError::Closed)
        } else {
            Ok(())
        }
    }
}

fn parse<T: DeserializeOwned>(frame: &str) -> Result<T, CodexBindingError> {
    if frame.len() > CODEX_FRAME_LIMIT {
        return Err(CodexBindingError::TooLarge);
    }
    if !frame.trim_start().starts_with('{') {
        return Err(CodexBindingError::InvalidFrame);
    }
    serde_json::from_str(frame).map_err(|_| CodexBindingError::InvalidFrame)
}

fn validate_id(text: &str) -> Result<(), CodexBindingError> {
    if text.is_empty() || text.len() > MAX_ID_BYTES || text.chars().any(char::is_control) {
        return Err(CodexBindingError::InvalidFrame);
    }
    Ok(())
}

#[cfg(test)]
mod tests;
