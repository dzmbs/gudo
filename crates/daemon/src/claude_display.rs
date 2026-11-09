pub(crate) mod http;
mod launch;

pub(crate) use launch::prepare as prepare_launch;

#[cfg(test)]
mod live_probe;
#[cfg(test)]
pub(crate) mod tests;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, Weak};

use agents::{ClaudeDisplayBatch, ClaudeDisplayChange, ClaudeDisplayStream};
use proto::{AgentKind, PaneId};
use tokio::sync::mpsc;

use crate::core::{Core, PaneEntry, lock};

const PANES_LIMIT: usize = 64;
const PATH_LIMIT: usize = 4096;

pub(crate) struct Capture {
    key: ring::hmac::Key,
    entries: Mutex<HashMap<PaneId, Entry>>,
}

struct Entry {
    pane: Weak<PaneEntry>,
    wake: Option<mpsc::WeakSender<()>>,
    scope: Option<Scope>,
    last_sequence: u64,
}

impl Entry {
    fn new(pane: &Arc<PaneEntry>) -> Self {
        Self {
            pane: Arc::downgrade(pane),
            wake: None,
            scope: None,
            last_sequence: 0,
        }
    }
    fn matches(&self, pane: &Arc<PaneEntry>) -> bool {
        self.pane
            .upgrade()
            .is_some_and(|previous| Arc::ptr_eq(&previous, pane))
    }
}

struct Scope {
    launch: String,
    session: String,
    prompt: String,
    transcript: PathBuf,
    cwd: PathBuf,
    sequence: u64,
    revision: u64,
    is_usable: bool,
    stream: ClaudeDisplayStream,
}

pub(crate) struct Snapshot {
    pub session: String,
    pub prompt: String,
    pub transcript: PathBuf,
    pub cwd: PathBuf,
    pub sequence: u64,
    pub revision: u64,
    pub is_usable: bool,
    pub messages: Vec<Message>,
}

#[derive(Clone)]
pub(crate) struct Message {
    pub id: String,
    pub ordinal: u64,
    pub text: String,
    pub is_final: bool,
}

impl Capture {
    pub fn new(secret: &[u8]) -> Self {
        Self {
            key: ring::hmac::Key::new(ring::hmac::HMAC_SHA256, secret),
            entries: Mutex::default(),
        }
    }

    pub fn token(&self, pane: PaneId) -> String {
        crate::fsutil::hex(ring::hmac::sign(&self.key, token_context(pane).as_bytes()).as_ref())
    }

    pub fn verify(&self, pane: PaneId, token: &str) -> bool {
        crate::fsutil::constant_eq(self.token(pane).as_bytes(), token.as_bytes())
    }

    pub fn subscribe(&self, pane: PaneId, entry: &Arc<PaneEntry>, wake: &mpsc::Sender<()>) {
        let mut entries = lock(&self.entries);
        entries.retain(|_, entry| entry.pane.strong_count() > 0);
        if entries.len() >= PANES_LIMIT && !entries.contains_key(&pane) {
            return;
        }
        let state = entries.entry(pane).or_insert_with(|| Entry::new(entry));
        if !state.matches(entry) {
            *state = Entry::new(entry);
        }
        state.wake = Some(wake.downgrade());
    }

    // Called inside input -> runtime admission, before a later prompt can replace this scope.
    pub fn prompt(
        &self,
        pane: PaneId,
        entry: &Arc<PaneEntry>,
        launch: &str,
        request: &crate::HookRequest,
    ) {
        if request.agent != "claude"
            || request.event != "UserPromptSubmit"
            || request
                .payload
                .get("hook_event_name")
                .and_then(serde_json::Value::as_str)
                != Some("UserPromptSubmit")
            || request
                .payload
                .get("agent_id")
                .is_some_and(|agent| !agent.is_null())
        {
            return;
        }
        let scope = (|| {
            let text = |name| {
                request
                    .payload
                    .get(name)
                    .and_then(serde_json::Value::as_str)
            };
            let (session, prompt, transcript, cwd) = (
                text("session_id")?,
                text("prompt_id")?,
                text("transcript_path")?,
                text("cwd")?,
            );
            if !crate::claude_session::is_session_id(session)
                || !crate::claude_session::is_session_id(prompt)
                || transcript.len() > PATH_LIMIT
                || cwd.len() > PATH_LIMIT
            {
                return None;
            }
            let transcript = PathBuf::from(transcript);
            let cwd = PathBuf::from(cwd);
            if !transcript.is_absolute() || !cwd.is_absolute() {
                return None;
            }
            Some(Scope {
                launch: launch.to_owned(),
                session: session.to_owned(),
                prompt: prompt.to_owned(),
                transcript,
                cwd,
                sequence: request.seq,
                revision: 0,
                is_usable: true,
                stream: ClaudeDisplayStream::new(session.to_owned(), Some(prompt.to_owned())),
            })
        })();
        let wake = {
            let mut entries = lock(&self.entries);
            entries.retain(|_, entry| entry.pane.strong_count() > 0);
            if entries.len() >= PANES_LIMIT && !entries.contains_key(&pane) {
                return;
            }
            let state = entries.entry(pane).or_insert_with(|| Entry::new(entry));
            if !state.matches(entry) {
                *state = Entry::new(entry);
            }
            if request.seq <= state.last_sequence {
                return;
            }
            state.last_sequence = request.seq;
            state.scope = scope;
            state.wake.as_ref().and_then(mpsc::WeakSender::upgrade)
        };
        if let Some(wake) = wake {
            let _ = wake.try_send(());
        }
    }

    pub fn receive(&self, core: &Core, pane: PaneId, token: &str, bytes: &[u8]) {
        if !self.verify(pane, token) {
            return;
        }
        let batch = ClaudeDisplayBatch::decode(bytes);
        let Some(entry) = core.pane(pane) else {
            return;
        };
        let input = lock(&entry.pane.agent_input_gate);
        let Some(launch) = input.active_launch() else {
            return;
        };
        let agent = lock(&entry.agent);
        let Some(runtime) = agent
            .as_ref()
            .filter(|runtime| runtime.kind() == AgentKind::Claude)
        else {
            return;
        };
        let wake = {
            let mut entries = lock(&self.entries);
            let Some(state) = entries.get_mut(&pane).filter(|state| state.matches(&entry)) else {
                return;
            };
            let Some(scope) = state
                .scope
                .as_mut()
                .filter(|scope| scope.launch == launch && scope.is_usable)
            else {
                return;
            };
            if runtime
                .session()
                .native_id
                .as_ref()
                .map(ToString::to_string)
                .as_deref()
                != Some(scope.session.as_str())
            {
                return;
            }
            match batch {
                Ok(batch) => {
                    if batch.session_id != scope.session
                        || batch.prompt_id.as_deref() != Some(scope.prompt.as_str())
                        || batch.transcript_path != scope.transcript
                        || batch.cwd != scope.cwd
                    {
                        return;
                    }
                    match scope.stream.apply(batch) {
                        Ok(ClaudeDisplayChange::Duplicate) => return,
                        Ok(ClaudeDisplayChange::Updated) => {}
                        Err(_) => scope.is_usable = false,
                    }
                }
                Err(_) => scope.is_usable = false,
            }
            scope.revision = scope.revision.saturating_add(1);
            state.wake.as_ref().and_then(mpsc::WeakSender::upgrade)
        };
        drop(agent);
        drop(input);
        if let Some(wake) = wake {
            let _ = wake.try_send(());
        }
    }

    pub fn snapshot(
        &self,
        pane: PaneId,
        entry: &Arc<PaneEntry>,
        launch: &str,
        session: &str,
    ) -> Option<Snapshot> {
        let entries = lock(&self.entries);
        let state = entries.get(&pane).filter(|state| state.matches(entry))?;
        let scope = state
            .scope
            .as_ref()
            .filter(|scope| scope.launch == launch && scope.session == session)?;
        Some(Snapshot {
            session: scope.session.clone(),
            prompt: scope.prompt.clone(),
            transcript: scope.transcript.clone(),
            cwd: scope.cwd.clone(),
            sequence: scope.sequence,
            revision: scope.revision,
            is_usable: scope.is_usable,
            messages: scope
                .stream
                .messages()
                .iter()
                .map(|message| Message {
                    id: message.id.clone(),
                    ordinal: message.ordinal,
                    text: message.text.clone(),
                    is_final: message.is_final,
                })
                .collect(),
        })
    }

    pub fn disable(&self, pane: PaneId, sequence: u64) {
        let mut entries = lock(&self.entries);
        if let Some(scope) = entries
            .get_mut(&pane)
            .and_then(|entry| entry.scope.as_mut())
            .filter(|scope| scope.sequence == sequence)
        {
            scope.is_usable = false;
            scope.stream =
                ClaudeDisplayStream::new(scope.session.clone(), Some(scope.prompt.clone()));
        }
    }

    pub fn retire(&self, pane: PaneId, sequence: u64, message: &str) {
        let mut entries = lock(&self.entries);
        if let Some(scope) = entries
            .get_mut(&pane)
            .and_then(|entry| entry.scope.as_mut())
            .filter(|scope| scope.sequence == sequence)
        {
            scope.stream.retire(message);
        }
    }
}

fn token_context(pane: PaneId) -> String {
    format!("claude-message-display-v1:{}", pane.0)
}
