//! a pane, its shell's prompt state and input line, atomic submit, the host's command history,
//! completion, fuzzy file search for `@` mentions, and a blocked agent's options.
//!
//! Requests are `async` like the workspace API. Pushes — foreground changes for panes in the
//! attached session, prompt changes for watched panes ([`Client::watch_prompt`]) — go to an
//! [`AssistListener`] set with [`Client::set_assist_listener`]; the latest of each is also
//! kept ([`Client::foreground`], [`Client::prompt_state`]).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::{
    AnswerBlocked, AssistError, AssistPush, AssistRequest, AssistResponse, BlockedPrompt,
    CompleteRequest, Completions, FileMatches, FileSearch, Foreground, HistoryEntry, HistoryQuery,
    PaneAssist, PaneId, PromptState, Seq, ServerCtl, SubmitLine,
};
use tokio::sync::{mpsc, oneshot};

use crate::{Client, Inner, lock};

/// How long a request waits for its answer.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// A push about a pane's input state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AssistEvent {
    /// A pane's foreground program changed.
    Foreground {
        /// The new foreground program.
        foreground: Foreground,
    },
    /// A watched pane's prompt state changed.
    Prompt {
        /// The new state.
        state: PromptState,
    },
}

/// Receives [`AssistEvent`]s. Must return quickly; it runs on the network threads.
pub trait AssistListener: Send + Sync {
    /// Called once per event, in order.
    fn on_assist_event(&self, event: AssistEvent);
}

/// An [`AssistListener`] that queues events for async Rust consumers (`un`, tests).
pub struct AssistEventQueue {
    tx: mpsc::UnboundedSender<AssistEvent>,
}

impl AssistEventQueue {
    /// Returns the listener and the receiving end.
    pub fn channel() -> (
        Arc<dyn AssistListener>,
        mpsc::UnboundedReceiver<AssistEvent>,
    ) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Self { tx }), rx)
    }
}

impl AssistListener for AssistEventQueue {
    fn on_assist_event(&self, event: AssistEvent) {
        let _ = self.tx.send(event);
    }
}

/// Input-assistance state kept by the client.
#[derive(Default)]
pub(crate) struct AssistState {
    pending: Mutex<HashMap<u64, oneshot::Sender<Result<AssistResponse, AssistError>>>>,
    listener: Mutex<Option<Arc<dyn AssistListener>>>,
    foreground: Mutex<HashMap<PaneId, Foreground>>,
    prompts: Mutex<HashMap<PaneId, PromptState>>,
}

impl AssistState {
    /// Handles an input-assistance message from `ctl`; returns it back if it is not one.
    pub(crate) fn dispatch(&self, msg: ServerCtl) -> Option<ServerCtl> {
        let event = match msg {
            ServerCtl::AssistResult { req_id, result } => {
                if let Some(tx) = lock(&self.pending).remove(&req_id) {
                    let _ = tx.send(result);
                }
                return None;
            }
            ServerCtl::Assist(AssistPush::Foreground(foreground)) => {
                lock(&self.foreground).insert(foreground.pane_id, foreground.clone());
                AssistEvent::Foreground { foreground }
            }
            ServerCtl::Assist(AssistPush::Prompt(state)) => {
                lock(&self.prompts).insert(state.pane_id, state.clone());
                AssistEvent::Prompt { state }
            }
            other => return Some(other),
        };
        let listener = lock(&self.listener).clone();
        if let Some(l) = listener {
            l.on_assist_event(event);
        }
        None
    }

    /// The connection dropped: requests in flight will not be answered.
    pub(crate) fn fail_pending(&self) {
        for (_, tx) in lock(&self.pending).drain() {
            let _ = tx.send(Err(AssistError::Disconnected));
        }
    }

    fn remember(&self, state: &PaneAssist) {
        if let Some(fg) = &state.foreground {
            lock(&self.foreground).insert(fg.pane_id, fg.clone());
        }
        lock(&self.prompts).insert(state.prompt.pane_id, state.prompt.clone());
    }
}

fn unexpected(other: AssistResponse) -> AssistError {
    AssistError::Failed(format!("unexpected answer {other:?}"))
}

impl Client {
    /// Sets the receiver of [`AssistEvent`]s (replacing any previous one).
    pub fn set_assist_listener(&self, listener: Arc<dyn AssistListener>) {
        *lock(&self.inner.assist.listener) = Some(listener);
    }

    /// The last foreground program the daemon reported for `pane`.
    pub fn foreground(&self, pane: PaneId) -> Option<Foreground> {
        lock(&self.inner.assist.foreground).get(&pane).cloned()
    }

    /// The last prompt state the daemon reported for `pane`.
    pub fn prompt_state(&self, pane: PaneId) -> Option<PromptState> {
        lock(&self.inner.assist.prompts).get(&pane).cloned()
    }

    /// Sends any input-assistance request and waits for the answer.
    ///
    /// # Errors
    ///
    /// The daemon's [`AssistError`], or [`AssistError::Disconnected`] if the connection
    /// dropped (or nothing came back within 30 s).
    pub async fn assist(&self, req: AssistRequest) -> Result<AssistResponse, AssistError> {
        let req_id = self
            .inner
            .next_op
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        lock(&self.inner.assist.pending).insert(req_id, tx);
        self.inner.send(proto::ClientCtl::Assist { req_id, req });
        let inner: Arc<Inner> = Arc::clone(&self.inner);
        self.handle
            .spawn(async move {
                match tokio::time::timeout(REQUEST_TIMEOUT, rx).await {
                    Ok(Ok(result)) => result,
                    _ => {
                        lock(&inner.assist.pending).remove(&req_id);
                        Err(AssistError::Disconnected)
                    }
                }
            })
            .await
            .unwrap_or(Err(AssistError::Disconnected))
    }

    /// Starts (or stops) prompt-state pushes for `pane`; returns the state now.
    ///
    /// # Errors
    ///
    /// As for [`assist`](Self::assist).
    pub async fn watch_prompt(&self, pane: PaneId, watch: bool) -> Result<PaneAssist, AssistError> {
        match self
            .assist(AssistRequest::Watch {
                pane_id: pane,
                watch,
            })
            .await?
        {
            AssistResponse::State(state) => {
                self.inner.assist.remember(&state);
                Ok(state)
            }
            other => Err(unexpected(other)),
        }
    }

    /// The pane's foreground program and prompt state now.
    ///
    /// # Errors
    ///
    /// As for [`assist`](Self::assist).
    pub async fn pane_assist(&self, pane: PaneId) -> Result<PaneAssist, AssistError> {
        match self.assist(AssistRequest::State { pane_id: pane }).await? {
            AssistResponse::State(state) => {
                self.inner.assist.remember(&state);
                Ok(state)
            }
            other => Err(unexpected(other)),
        }
    }

    /// Replaces the shell's input line at prompt `prompt_id` with `text` and, if `run`, runs
    /// it, as one write. Returns the output offset of the write.
    ///
    /// # Errors
    ///
    /// [`AssistError::NotAtPrompt`] (with the pane's state now) when the pane left that
    /// prompt; nothing was written. Otherwise as for [`assist`](Self::assist).
    pub async fn submit_line(
        &self,
        pane: PaneId,
        prompt_id: u64,
        text: impl Into<String>,
        run: bool,
    ) -> Result<Seq, AssistError> {
        let req = AssistRequest::SubmitLine(SubmitLine {
            pane_id: pane,
            prompt_id,
            text: text.into(),
            run,
        });
        match self.assist(req).await? {
            AssistResponse::Submitted { at_seq, .. } => Ok(at_seq),
            other => Err(unexpected(other)),
        }
    }

    /// Commands from the host's history, best first.
    ///
    /// # Errors
    ///
    /// As for [`assist`](Self::assist).
    pub async fn history(&self, query: HistoryQuery) -> Result<Vec<HistoryEntry>, AssistError> {
        match self.assist(AssistRequest::History(query)).await? {
            AssistResponse::History(entries) => Ok(entries),
            other => Err(unexpected(other)),
        }
    }

    /// Completion candidates for `line` with the cursor at `cursor` (in `char`s).
    ///
    /// # Errors
    ///
    /// As for [`assist`](Self::assist).
    pub async fn complete(
        &self,
        pane: PaneId,
        line: impl Into<String>,
        cursor: u32,
        limit: u32,
    ) -> Result<Completions, AssistError> {
        let req = AssistRequest::Complete(CompleteRequest {
            pane_id: pane,
            line: line.into(),
            cursor,
            limit,
        });
        match self.assist(req).await? {
            AssistResponse::Completions(c) => Ok(c),
            other => Err(unexpected(other)),
        }
    }

    /// Fuzzy file search under `root` for `@` mentions.
    ///
    /// # Errors
    ///
    /// As for [`assist`](Self::assist).
    pub async fn file_search(
        &self,
        root: impl Into<String>,
        query: impl Into<String>,
        limit: u32,
    ) -> Result<FileMatches, AssistError> {
        let req = AssistRequest::FileSearch(FileSearch {
            root: root.into(),
            query: query.into(),
            limit,
        });
        match self.assist(req).await? {
            AssistResponse::Files(m) => Ok(m),
            other => Err(unexpected(other)),
        }
    }

    /// The decision the agent in `pane` is blocked on, if any.
    ///
    /// # Errors
    ///
    /// As for [`assist`](Self::assist).
    pub async fn blocked_options(
        &self,
        pane: PaneId,
    ) -> Result<Option<BlockedPrompt>, AssistError> {
        match self
            .assist(AssistRequest::BlockedOptions { pane_id: pane })
            .await?
        {
            AssistResponse::Blocked(b) => Ok(b),
            other => Err(unexpected(other)),
        }
    }

    /// Picks option `index` (labelled `label`) of the dialog on screen by typing its keys.
    ///
    /// # Errors
    ///
    /// [`AssistError::NotFound`] when the dialog no longer offers it. Otherwise as for
    /// [`assist`](Self::assist).
    pub async fn answer_blocked(
        &self,
        pane: PaneId,
        index: u32,
        label: impl Into<String>,
    ) -> Result<(), AssistError> {
        let req = AssistRequest::AnswerBlocked(AnswerBlocked {
            pane_id: pane,
            index,
            label: label.into(),
        });
        match self.assist(req).await? {
            AssistResponse::Done => Ok(()),
            other => Err(unexpected(other)),
        }
    }
}
