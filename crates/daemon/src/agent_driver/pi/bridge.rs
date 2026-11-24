//! The channel a launched pi opens through its bridge extension: what it streams, and the
//! prompts, stops and setting changes the daemon asks of it, beside its terminal UI.
//!
//! The extension connects to the hook socket and names the pane with the pane's token, like a
//! hook. It reconnects after the daemon restarts or hands off, so the channel survives both.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use proto::{PaneId, WsError};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};

use crate::core::{Core, PaneEntry, lock};

const PROTOCOL: u32 = 1;
/// The longest line either side sends; a streamed delta or a model list is far below it.
const LINE_BYTES_LIMIT: usize = 8 * 1024 * 1024;
const OUTGOING_LIMIT: usize = 64;
const REPLY_WAIT: Duration = Duration::from_secs(10);
/// Streamed text kept per message; the session file holds the whole reply once it ends.
const STREAMED_BYTES_LIMIT: usize = 256 * 1024;
const LIVE_MESSAGES_LIMIT: usize = 8;
/// How long an ended message stays shown while pi writes it to its session file.
const RECORDING_WAIT: Duration = Duration::from_secs(30);
const MODELS_LIMIT: usize = 512;
const COMMANDS_LIMIT: usize = 512;
const TEXT_FIELD_LIMIT: usize = 1024;

/// The first line the extension sends, as its own hook-socket call.
#[derive(Debug, Deserialize)]
pub(crate) struct PiBridgeCall {
    pi_bridge: Hello,
}

#[derive(Debug, Deserialize)]
struct Hello {
    v: u32,
    token: String,
    pane: String,
}

/// One pane's connected pi.
pub(crate) struct Bridge {
    entry: Weak<PaneEntry>,
    outgoing: mpsc::Sender<String>,
    next_request: AtomicU64,
    replies: Mutex<HashMap<u64, oneshot::Sender<Result<Value, String>>>>,
    state: Mutex<LiveState>,
    wakes: Mutex<Vec<mpsc::Sender<()>>>,
}

/// What pi last reported about itself and what it is streaming.
#[derive(Debug, Default, Clone)]
pub(crate) struct LiveState {
    pub session: Option<SessionInfo>,
    pub models: Vec<PiModel>,
    pub commands: Vec<PiCommand>,
    pub busy: bool,
    pub context: Option<ContextUsage>,
    pub messages: VecDeque<LiveMessage>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(crate) struct SessionInfo {
    pub session_id: Option<String>,
    pub session_file: Option<String>,
    pub cwd: Option<String>,
    pub model: Option<PiModel>,
    pub thinking: Option<String>,
    #[serde(default)]
    pub thinking_levels: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(crate) struct PiModel {
    pub provider: String,
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub reasoning: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(crate) struct PiCommand {
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub scope: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ContextUsage {
    pub tokens: Option<u64>,
    pub window: u64,
}

/// An assistant message pi is streaming, or ended and not yet read from its session file.
/// pi records the message with the same timestamp, which is how the two are matched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LiveMessage {
    pub timestamp: u64,
    pub blocks: BTreeMap<u32, LiveBlock>,
    pub ended: Option<Instant>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LiveBlock {
    pub kind: BlockKind,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum BlockKind {
    Text,
    Thinking,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Incoming {
    Session(SessionInfo),
    Models {
        models: Vec<PiModel>,
    },
    Commands {
        commands: Vec<PiCommand>,
    },
    Usage {
        tokens: Option<f64>,
        context_window: Option<f64>,
    },
    Busy {
        busy: bool,
    },
    MessageStart {
        timestamp: u64,
    },
    Delta {
        timestamp: u64,
        index: u32,
        kind: BlockKind,
        text: String,
    },
    MessageEnd {
        timestamp: u64,
    },
    Reply {
        id: u64,
        ok: bool,
        error: Option<String>,
        #[serde(default)]
        data: Value,
    },
    #[serde(other)]
    Other,
}

/// What the daemon asks of pi.
#[derive(Debug)]
pub(crate) enum Request<'a> {
    Prompt {
        text: &'a str,
        images: &'a [std::path::PathBuf],
    },
    Abort,
    SetModel {
        provider: &'a str,
        model: &'a str,
    },
    SetThinking {
        level: &'a str,
    },
}

impl Request<'_> {
    fn encode(&self, id: u64) -> Value {
        match self {
            Self::Prompt { text, images } => {
                let images: Vec<Value> = images
                    .iter()
                    .map(|path| {
                        let media_type =
                            match path.extension().and_then(|extension| extension.to_str()) {
                                Some("jpg" | "jpeg") => "image/jpeg",
                                _ => "image/png",
                            };
                        json!({"path": path, "media_type": media_type})
                    })
                    .collect();
                json!({"id": id, "type": "prompt", "text": text, "images": images})
            }
            Self::Abort => json!({"id": id, "type": "abort"}),
            Self::SetModel { provider, model } => {
                json!({"id": id, "type": "set_model", "provider": provider, "model": model})
            }
            Self::SetThinking { level } => {
                json!({"id": id, "type": "set_thinking", "level": level})
            }
        }
    }
}

impl Bridge {
    fn new(entry: Weak<PaneEntry>, outgoing: mpsc::Sender<String>) -> Self {
        Self {
            entry,
            outgoing,
            next_request: AtomicU64::new(1),
            replies: Mutex::new(HashMap::new()),
            state: Mutex::new(LiveState::default()),
            wakes: Mutex::new(Vec::new()),
        }
    }

    pub fn state(&self) -> LiveState {
        lock(&self.state).clone()
    }

    /// Wakes `wake` whenever pi reports something.
    pub fn watch(&self, wake: &mpsc::Sender<()>) {
        let mut wakes = lock(&self.wakes);
        wakes.retain(|known| !known.is_closed());
        if !wakes.iter().any(|known| known.same_channel(wake)) {
            wakes.push(wake.clone());
        }
    }

    fn wake(&self) {
        for wake in lock(&self.wakes).iter() {
            let _ = wake.try_send(());
        }
    }

    /// Forgets messages pi has recorded, and ended ones it took too long to record.
    pub fn recorded(&self, timestamps: &[u64]) {
        let now = Instant::now();
        lock(&self.state).messages.retain(|message| {
            !timestamps.contains(&message.timestamp)
                && message
                    .ended
                    .is_none_or(|ended| now.duration_since(ended) < RECORDING_WAIT)
        });
    }

    /// Queues `request` for pi and returns its answer. The queue never waits: a pi that stopped
    /// reading refuses new requests rather than holding the caller.
    pub fn request(
        &self,
        request: &Request<'_>,
    ) -> Result<impl Future<Output = Result<Value, WsError>> + Send + 'static, WsError> {
        let id = self.next_request.fetch_add(1, Ordering::Relaxed);
        let (sender, receiver) = oneshot::channel();
        lock(&self.replies).insert(id, sender);
        let line = request.encode(id).to_string();
        if self.outgoing.try_send(line).is_err() {
            lock(&self.replies).remove(&id);
            return Err(unavailable());
        }
        Ok(async move {
            match tokio::time::timeout(REPLY_WAIT, receiver).await {
                Ok(Ok(Ok(data))) => Ok(data),
                Ok(Ok(Err(error))) => Err(WsError::Failed(bounded(&error))),
                Ok(Err(_)) | Err(_) => Err(unavailable()),
            }
        })
    }

    fn apply(&self, incoming: Incoming) {
        let mut state = lock(&self.state);
        match incoming {
            Incoming::Session(session) => state.session = Some(session.bounded()),
            Incoming::Models { mut models } => {
                models.truncate(MODELS_LIMIT);
                state.models = models.into_iter().map(PiModel::bounded).collect();
            }
            Incoming::Commands { mut commands } => {
                commands.truncate(COMMANDS_LIMIT);
                state.commands = commands.into_iter().map(PiCommand::bounded).collect();
            }
            Incoming::Usage {
                tokens,
                context_window,
            } => {
                state.context =
                    context_window
                        .filter(|window| *window > 0.0)
                        .map(|window| ContextUsage {
                            tokens: tokens
                                .filter(|tokens| *tokens >= 0.0)
                                .map(|tokens| tokens as u64),
                            window: window as u64,
                        });
            }
            Incoming::Busy { busy } => {
                state.busy = busy;
                if busy {
                    drop(state);
                    self.started_run();
                    self.wake();
                    return;
                }
                let now = Instant::now();
                for message in &mut state.messages {
                    message.ended.get_or_insert(now);
                }
            }
            Incoming::MessageStart { timestamp } => {
                state.message(timestamp);
            }
            Incoming::Delta {
                timestamp,
                index,
                kind,
                text,
            } => {
                let message = state.message(timestamp);
                let block = message.blocks.entry(index).or_insert(LiveBlock {
                    kind,
                    text: String::new(),
                });
                if block.text.len() + text.len() <= STREAMED_BYTES_LIMIT {
                    block.text.push_str(&text);
                }
            }
            Incoming::MessageEnd { timestamp } => {
                state.message(timestamp).ended = Some(Instant::now());
            }
            Incoming::Reply {
                id,
                ok,
                error,
                data,
            } => {
                drop(state);
                if let Some(reply) = lock(&self.replies).remove(&id) {
                    let _ = reply.send(if ok {
                        Ok(data)
                    } else {
                        Err(error.unwrap_or_else(|| "pi refused the request".into()))
                    });
                }
                return;
            }
            Incoming::Other => return,
        }
        drop(state);
        self.wake();
    }
}

impl Bridge {
    /// pi began a run: Chat may interrupt it, and only it.
    fn started_run(&self) {
        let Some(entry) = self.entry.upgrade() else {
            return;
        };
        if let Some(session) = super::session_of(&entry) {
            lock(&entry.pane.agent_input_gate).native_turn(&session);
        }
    }
}

impl LiveState {
    fn message(&mut self, timestamp: u64) -> &mut LiveMessage {
        let index = match self
            .messages
            .iter()
            .position(|message| message.timestamp == timestamp)
        {
            Some(index) => index,
            None => {
                if self.messages.len() >= LIVE_MESSAGES_LIMIT {
                    self.messages.pop_front();
                }
                self.messages.push_back(LiveMessage {
                    timestamp,
                    blocks: BTreeMap::new(),
                    ended: None,
                });
                self.messages.len() - 1
            }
        };
        &mut self.messages[index]
    }
}

impl SessionInfo {
    fn bounded(self) -> Self {
        Self {
            session_id: self
                .session_id
                .filter(|id| crate::resumable::is_session_id(id)),
            session_file: self.session_file.map(|file| bounded(&file)),
            cwd: self.cwd.map(|cwd| bounded(&cwd)),
            model: self.model.map(PiModel::bounded),
            thinking: self.thinking.map(|level| bounded(&level)),
            thinking_levels: self
                .thinking_levels
                .into_iter()
                .take(16)
                .map(|level| bounded(&level))
                .collect(),
        }
    }
}

impl PiModel {
    fn bounded(self) -> Self {
        Self {
            provider: bounded(&self.provider),
            id: bounded(&self.id),
            name: bounded(&self.name),
            reasoning: self.reasoning,
        }
    }

    /// How Chat names the model: its own name, else `provider/id`.
    pub fn label(&self) -> String {
        if self.name.is_empty() {
            format!("{}/{}", self.provider, self.id)
        } else {
            self.name.clone()
        }
    }
}

impl PiCommand {
    fn bounded(self) -> Self {
        Self {
            name: bounded(&self.name),
            description: bounded(&self.description),
            scope: bounded(&self.scope),
        }
    }
}

fn bounded(text: &str) -> String {
    let mut end = text.len().min(TEXT_FIELD_LIMIT);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}

/// Writes the bridge extension into `state_dir`, returning its path for pi's `--extension`.
pub(crate) fn install(state_dir: &std::path::Path) -> std::io::Result<std::path::PathBuf> {
    let path = state_dir.join(agents::PI_BRIDGE_FILE);
    let source = agents::pi_bridge_extension();
    if crate::fsutil::read_optional(&path)?.as_deref() != Some(source.as_bytes()) {
        crate::fsutil::write_atomic(&path, source.as_bytes())?;
    }
    Ok(path)
}

/// The connected pi of `pane`, if its bridge is connected.
pub(crate) fn of(entry: &PaneEntry) -> Option<Arc<Bridge>> {
    lock(&entry.pi).clone()
}

/// Serves one extension connection until either side closes it.
pub(crate) async fn serve<R, W>(
    core: &Arc<Core>,
    call: PiBridgeCall,
    peer_uid: Option<u32>,
    reader: BufReader<R>,
    mut writer: W,
) -> std::io::Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    let hello = call.pi_bridge;
    let entry = (hello.v == PROTOCOL
        && crate::agent::same_user(peer_uid)
        && core.hooks.verify(&hello.token, &hello.pane))
    .then(|| hello.pane.parse().ok().map(PaneId))
    .flatten()
    .and_then(|pane| core.pane(pane))
    .filter(|entry| crate::agent_driver::chat_agent(entry) == Some(proto::AgentKind::Pi));
    let Some(entry) = entry else {
        return writer.shutdown().await;
    };
    let (outgoing, mut lines) = mpsc::channel::<String>(OUTGOING_LIMIT);
    let bridge = Arc::new(Bridge::new(Arc::downgrade(&entry), outgoing));
    let previous = lock(&entry.pi).replace(Arc::clone(&bridge));
    if let Some(previous) = previous {
        previous.wake();
    }
    writer.write_all(b"{\"type\":\"ready\"}\n").await?;
    core.emit(crate::core::Event::PaneMeta(entry.pane.id));
    let weak = Arc::downgrade(&bridge);
    let (watched, pane) = (Arc::downgrade(core), entry.pane.id);
    let config_changed = move || {
        if let Some(core) = watched.upgrade() {
            crate::agent_config::changed(&core, pane);
        }
    };
    let result = run(&weak, reader, &mut writer, &mut lines, config_changed).await;
    let current = lock(&entry.pi)
        .as_ref()
        .is_some_and(|current| Arc::ptr_eq(current, &bridge));
    if current {
        lock(&entry.pi).take();
    }
    lock(&bridge.replies).clear();
    bridge.wake();
    core.emit(crate::core::Event::PaneMeta(entry.pane.id));
    result
}

async fn run<R, W>(
    bridge: &Weak<Bridge>,
    mut reader: BufReader<R>,
    writer: &mut W,
    lines: &mut mpsc::Receiver<String>,
    config_changed: impl Fn(),
) -> std::io::Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    let mut line = Vec::new();
    loop {
        tokio::select! {
            read = read_line(&mut reader, &mut line) => {
                if !read? {
                    return Ok(());
                }
                let Some(bridge) = bridge.upgrade() else {
                    return Ok(());
                };
                if let Ok(incoming) = serde_json::from_slice::<Incoming>(&line) {
                    let reconfigures = matches!(
                        incoming,
                        Incoming::Session(_) | Incoming::Models { .. } | Incoming::Usage { .. }
                    );
                    bridge.apply(incoming);
                    if reconfigures {
                        config_changed();
                    }
                }
                line.clear();
            }
            outgoing = lines.recv() => {
                let Some(mut outgoing) = outgoing else {
                    return Ok(());
                };
                outgoing.push('\n');
                writer.write_all(outgoing.as_bytes()).await?;
            }
        }
    }
}

/// Reads one line into `line`, refusing one over the limit; `false` at the end of the stream.
async fn read_line<R: tokio::io::AsyncRead + Unpin>(
    reader: &mut BufReader<R>,
    line: &mut Vec<u8>,
) -> std::io::Result<bool> {
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return Ok(false);
        }
        let (taken, complete) = match memchr::memchr(b'\n', available) {
            Some(newline) => (newline + 1, true),
            None => (available.len(), false),
        };
        if line.len() + taken > LINE_BYTES_LIMIT {
            return Err(std::io::Error::other("pi bridge line over the limit"));
        }
        line.extend_from_slice(&available[..taken]);
        reader.consume(taken);
        if complete {
            line.pop();
            return Ok(true);
        }
    }
}

fn unavailable() -> WsError {
    WsError::Unavailable("pi is not connected to the helper. Use Terminal.".into())
}
