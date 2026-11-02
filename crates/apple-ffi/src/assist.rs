//! Input assistance for the mobile line editor on [`DaemonClient`] (docs/DAEMON.md §8): a
//! pane's foreground program and profile, its shell's prompt state and
//! input line, atomic submit, the host's history, completion, fuzzy file search for `@`
//! mentions, and a blocked agent's options.
//!
//! Requests are `async` and return the daemon's answer or an [`AssistError`]. Pushes
//! (foreground changes for panes of the attached session, prompt changes for watched panes)
//! go to an [`AssistListener`]; the latest of each is also kept
//! ([`DaemonClient::foreground`], [`DaemonClient::prompt_state`]). Text positions count
//! Unicode scalar values (Swift `unicodeScalars`), not UTF-16 units.

use std::future::Future;
use std::sync::Arc;

use client_core::proto;

use crate::art_types::mirror_enum;
use crate::bytes::Bytes;
use crate::client::DaemonClient;
use crate::on_runtime;
use crate::ws_types::FileKind;

/// Why an input-assistance request failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum AssistError {
    /// The connection's roles or scope do not allow it; the text names the role needed.
    #[error("not allowed: {message}")]
    Denied { message: String },
    /// The pane does not exist or is outside the grant's scope.
    #[error("no such pane")]
    UnknownPane,
    /// The pane is not at the expected shell prompt (a command runs, the prompt changed, a
    /// full-screen program is up, or no shell integration). Nothing was written; `state` is
    /// the pane's state now, to resynchronise the editor with.
    #[error("the pane is not at that shell prompt")]
    NotAtPrompt {
        /// The pane's prompt state now.
        state: PromptState,
    },
    /// The request was malformed.
    #[error("invalid request: {message}")]
    Invalid { message: String },
    /// The path, dialog or option does not exist (any more).
    #[error("not found: {message}")]
    NotFound { message: String },
    #[error("{message}")]
    Failed { message: String },
    /// The connection dropped before the daemon answered.
    #[error("disconnected before the daemon answered")]
    Disconnected,
}

impl From<proto::AssistError> for AssistError {
    fn from(assist_error: proto::AssistError) -> Self {
        use proto::AssistError as E;
        match assist_error {
            E::Denied(message) => Self::Denied { message },
            E::UnknownPane => Self::UnknownPane,
            E::NotAtPrompt(state) => Self::NotAtPrompt {
                state: state.into(),
            },
            E::Invalid(message) => Self::Invalid { message },
            E::NotFound(message) => Self::NotFound { message },
            E::Failed(message) => Self::Failed { message },
            E::Disconnected => Self::Disconnected,
        }
    }
}

mirror_enum! {
    /// The kind of program in a pane's foreground, for picking a key-bar profile.
    ProgramProfile = ProgramProfile {
        /// A shell (bash, zsh, fish, sh, …).
        Shell,
        /// vi-style modal editors (vim, nvim, vi, hx, kak).
        Vim,
        /// Pagers (less, more, man, most).
        Pager,
        /// System monitors (top, htop, btop, …).
        Monitor,
        /// Terminal multiplexers (tmux, screen, zellij).
        Tmux,
        /// Interactive interpreters and database shells started without a script.
        Repl,
        Claude,
        Codex,
        Other,
    }
}

mirror_enum! {
    /// Why a [`PromptInput`] may be wrong.
    InputDoubt = InputDoubt {
        /// The shell does not mark where input starts (fish 3); the start was inferred.
        NoInputMark,
        /// The cursor is outside the input area.
        CursorOutside,
        /// Text after the cursor is styled differently and may be a suggestion.
        PossibleGhostText,
        /// Non-blank rows follow the input line (a completion listing, a multi-line tail).
        ContentBelow,
        /// A continuation prompt (PS2) is up; only the current line is editable.
        Continuation,
        /// Trailing text at the right edge may be an unrecognised right prompt.
        RightPromptGuess,
        /// The input area could not be read.
        Unreadable,
    }
}

mirror_enum! {
    /// Which shell runs at the prompt.
    ShellKind = ShellKind {
        Zsh,
        Bash,
        Fish,
        Other,
    }
}

mirror_enum! {
    Keymap = Keymap {
        Emacs,
        /// vi insert or command mode.
        Vi,
        Unknown,
    }
}

mirror_enum! {
    /// Where a [`Completion`] came from.
    CompletionKind = CompletionKind {
        /// A whole command line from history.
        History,
        /// A file.
        Path,
        /// A directory (its text ends with `/`).
        Dir,
        /// A git branch, remote branch or tag.
        GitRef,
        /// A changed or untracked file in the git work tree.
        GitPath,
        /// An executable on `$PATH`, or a subcommand.
        Command,
        Flag,
        Snippet,
    }
}

mirror_enum! {
    /// What a [`BlockedOption`] means.
    BlockedChoice = BlockedChoice {
        /// Allow this one request.
        AllowOnce,
        /// Allow and stop asking for the session.
        AllowSession,
        Deny,
        /// Something else (an answer to a question).
        Other,
    }
}

mirror_enum! {
    /// Where a [`BlockedPrompt`]'s options came from.
    BlockedSource = BlockedSource {
        /// The agent's hook (exact), with keys matched from the screen when visible.
        Hook,
        /// Parsed from the numbered menu on screen.
        Screen,
    }
}

/// The process group in the foreground of a pane's terminal.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Foreground {
    pub pane_id: u64,
    /// Process id of the group leader.
    pub pid: u32,
    /// The program's name (basename of `argv[0]`, login `-` stripped).
    pub name: String,
    /// The full argument vector, empty if unreadable.
    pub argv: Vec<String>,
    /// What kind of program it is.
    pub profile: ProgramProfile,
    /// When it became the foreground program.
    pub since_ms: u64,
}

impl From<proto::Foreground> for Foreground {
    fn from(foreground: proto::Foreground) -> Self {
        Self {
            pane_id: foreground.pane_id.0,
            pid: foreground.pid,
            name: foreground.name,
            argv: foreground.argv,
            profile: foreground.profile.into(),
            since_ms: foreground.since.0,
        }
    }
}

/// The shell's input line as read off the screen.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PromptInput {
    /// The command line (soft wraps joined), without prompt text, a right prompt or an
    /// autosuggestion.
    pub text: String,
    /// Cursor position in `text` (Unicode scalars).
    pub cursor: u32,
    /// Reliable enough to prefill the editor with; otherwise start empty (`doubt` says why).
    pub confident: bool,
    /// Why the reading may be wrong.
    pub doubt: Option<InputDoubt>,
    /// Greyed-out suggestion after the cursor (zsh-autosuggestions, fish), not in `text`.
    pub suggestion: Option<String>,
    /// A right-hand prompt was recognised and left out.
    pub right_prompt: bool,
    pub shell: ShellKind,
    /// Bracketed paste is on, so multi-line text can be submitted.
    pub bracketed_paste: bool,
    pub keymap: Keymap,
}

impl From<proto::PromptInput> for PromptInput {
    fn from(prompt_input: proto::PromptInput) -> Self {
        Self {
            text: prompt_input.text,
            cursor: prompt_input.cursor,
            confident: prompt_input.confident,
            doubt: prompt_input.doubt.map(Into::into),
            suggestion: prompt_input.suggestion,
            right_prompt: prompt_input.right_prompt,
            shell: prompt_input.shell.into(),
            bracketed_paste: prompt_input.bracketed_paste,
            keymap: prompt_input.keymap.into(),
        }
    }
}

/// What the shell in a pane is doing.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PromptPhase {
    /// Editing a command line at its prompt.
    AtPrompt { input: PromptInput },
    /// A command started from the prompt runs.
    Running {
        /// The command (as in `CommandMark`).
        command_id: u64,
    },
    /// No prompt known: no shell integration, a full-screen program, or not the shell.
    Unknown,
}

impl From<proto::PromptPhase> for PromptPhase {
    fn from(prompt_phase: proto::PromptPhase) -> Self {
        match prompt_phase {
            proto::PromptPhase::AtPrompt(input) => Self::AtPrompt {
                input: input.into(),
            },
            proto::PromptPhase::Running { command_id } => Self::Running { command_id },
            proto::PromptPhase::Unknown => Self::Unknown,
        }
    }
}

/// A pane's shell prompt state.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PromptState {
    pub pane_id: u64,
    /// The prompt instance: changes whenever a command starts. Pass it to `submit_line`.
    pub prompt_id: u64,
    /// Output offset the state was read at.
    pub at_seq: u64,
    /// What the shell is doing.
    pub phase: PromptPhase,
}

impl From<proto::PromptState> for PromptState {
    fn from(prompt_state: proto::PromptState) -> Self {
        Self {
            pane_id: prompt_state.pane_id.0,
            prompt_id: prompt_state.prompt_id,
            at_seq: prompt_state.at_seq.0,
            phase: prompt_state.phase.into(),
        }
    }
}

/// A pane's foreground program and prompt state.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PaneAssist {
    /// The foreground program, if it could be read.
    pub foreground: Option<Foreground>,
    pub prompt: PromptState,
}

impl From<proto::PaneAssist> for PaneAssist {
    fn from(pane_assist: proto::PaneAssist) -> Self {
        Self {
            foreground: pane_assist.foreground.map(Into::into),
            prompt: pane_assist.prompt.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryQuery {
    /// Rank commands used in this directory (and its relatives) higher.
    #[uniffi(default = None)]
    pub cwd: Option<String>,
    /// Only commands starting with this.
    #[uniffi(default = None)]
    pub prefix: Option<String>,
    /// Only commands containing this (case-insensitive).
    #[uniffi(default = None)]
    pub contains: Option<String>,
    /// Only commands last used at or after this (Unix ms).
    #[uniffi(default = None)]
    pub since_ms: Option<u64>,
    /// Most entries returned (capped at 1000).
    #[uniffi(default = 50)]
    pub limit: u32,
}

impl From<HistoryQuery> for proto::HistoryQuery {
    fn from(history_query: HistoryQuery) -> Self {
        Self {
            cwd: history_query.cwd,
            prefix: history_query.prefix,
            contains: history_query.contains,
            since: history_query.since_ms.map(proto::UnixMillis),
            limit: history_query.limit,
        }
    }
}

/// One distinct command from the host's history.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryEntry {
    pub command: String,
    /// Directory of its last run, if known.
    pub cwd: Option<String>,
    /// Exit status of its last run, if known.
    pub exit: Option<i32>,
    /// Duration of its last run, if known.
    pub duration_ms: Option<u64>,
    /// When it last ran.
    pub last_at_ms: u64,
    /// How often it ran.
    pub count: u32,
}

impl From<proto::HistoryEntry> for HistoryEntry {
    fn from(history_entry: proto::HistoryEntry) -> Self {
        Self {
            command: history_entry.command,
            cwd: history_entry.cwd,
            exit: history_entry.exit,
            duration_ms: history_entry.duration_ms,
            last_at_ms: history_entry.last_at.0,
            count: history_entry.count,
        }
    }
}

/// One completion candidate: replace `line[start..<end]` (Unicode scalars) with `text`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Completion {
    /// Replacement text, quoted for the shell where needed.
    pub text: String,
    /// Label to show.
    pub display: String,
    /// Where it came from.
    pub kind: CompletionKind,
    /// Extra information (a history entry's directory, a git ref's kind).
    pub detail: Option<String>,
    /// Start of the replaced range.
    pub start: u32,
    /// End of the replaced range.
    pub end: u32,
}

impl From<proto::Completion> for Completion {
    fn from(completion: proto::Completion) -> Self {
        Self {
            text: completion.text,
            display: completion.display,
            kind: completion.kind.into(),
            detail: completion.detail,
            start: completion.start,
            end: completion.end,
        }
    }
}

/// Completion candidates, best first.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Completions {
    /// The directory paths were completed in.
    pub cwd: Option<String>,
    pub items: Vec<Completion>,
}

impl From<proto::Completions> for Completions {
    fn from(completions: proto::Completions) -> Self {
        Self {
            cwd: completions.cwd,
            items: completions.items.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileMatch {
    /// Path relative to the root, `/`-separated.
    pub path: String,
    pub kind: FileKind,
    /// Positions in `path` (Unicode scalars) of the matched characters, for highlighting.
    pub positions: Vec<u32>,
}

impl From<proto::FileMatch> for FileMatch {
    fn from(file_match: proto::FileMatch) -> Self {
        Self {
            path: file_match.path,
            kind: file_match.kind.into(),
            positions: file_match.positions,
        }
    }
}

/// File search results, best first.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileMatches {
    /// The root searched, resolved.
    pub root: String,
    pub matches: Vec<FileMatch>,
    /// Paths considered.
    pub scanned: u32,
    /// The walk stopped at the daemon's limit.
    pub truncated: bool,
}

impl From<proto::FileMatches> for FileMatches {
    fn from(file_matches: proto::FileMatches) -> Self {
        Self {
            root: file_matches.root,
            matches: file_matches.matches.into_iter().map(Into::into).collect(),
            scanned: file_matches.scanned,
            truncated: file_matches.truncated,
        }
    }
}

/// One answer to a [`BlockedPrompt`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BlockedOption {
    pub label: String,
    /// What the answer means.
    pub choice: BlockedChoice,
    /// Answer through `decide(requestId:optionId:)` with this id (signed, approver role);
    /// `nil` when only keystrokes can answer (`answer_blocked`).
    pub option_id: Option<u32>,
    /// Keys that pick this option in the dialog on screen; empty when no menu shows.
    pub keys: Bytes,
    /// The dialog's cursor is on this option.
    pub selected: bool,
}

impl From<proto::BlockedOption> for BlockedOption {
    fn from(blocked_option: proto::BlockedOption) -> Self {
        Self {
            label: blocked_option.label,
            choice: blocked_option.choice.into(),
            option_id: blocked_option.option_id.map(|id| id.0),
            keys: blocked_option.keys.into(),
            selected: blocked_option.selected,
        }
    }
}

/// A decision an agent is waiting for, with a way to give each answer.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BlockedPrompt {
    pub pane_id: u64,
    /// The request to answer with `decide`, when the agent's hook holds it open.
    pub request_id: Option<u64>,
    /// What the agent wants.
    pub summary: String,
    /// The answers, in the order the agent shows them.
    pub options: Vec<BlockedOption>,
    /// Where the options were read from.
    pub source: BlockedSource,
}

impl From<proto::BlockedPrompt> for BlockedPrompt {
    fn from(blocked_prompt: proto::BlockedPrompt) -> Self {
        Self {
            pane_id: blocked_prompt.pane_id.0,
            request_id: blocked_prompt.request_id.map(|r| r.0),
            summary: blocked_prompt.summary,
            options: blocked_prompt.options.into_iter().map(Into::into).collect(),
            source: blocked_prompt.source.into(),
        }
    }
}

/// A push about a pane's input state.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AssistEvent {
    /// A pane's foreground program changed (panes of the attached session).
    Foreground { foreground: Foreground },
    /// A watched pane's prompt state or input line changed.
    Prompt { state: PromptState },
}

impl From<client_core::AssistEvent> for AssistEvent {
    fn from(assist_event: client_core::AssistEvent) -> Self {
        match assist_event {
            client_core::AssistEvent::Foreground { foreground } => Self::Foreground {
                foreground: foreground.into(),
            },
            client_core::AssistEvent::Prompt { state } => Self::Prompt {
                state: state.into(),
            },
        }
    }
}

/// Receives [`AssistEvent`]s; implemented in Swift.
///
/// Called on a runtime thread, in order, one at a time per client. Return quickly.
#[uniffi::export(foreign)]
pub trait AssistListener: Send + Sync {
    fn on_assist_event(&self, event: AssistEvent);
}

struct AssistForward(Arc<dyn AssistListener>);

impl client_core::AssistListener for AssistForward {
    fn on_assist_event(&self, event: client_core::AssistEvent) {
        self.0.on_assist_event(event.into());
    }
}

/// Classifies a program by name and arguments the way the daemon does (for a profile
/// before the first push, or for programs the app knows about otherwise).
#[uniffi::export]
pub fn classify_program(name: String, argv: Vec<String>) -> ProgramProfile {
    proto::ProgramProfile::classify(&name, &argv).into()
}

impl DaemonClient {
    /// Runs a client-core assist request on the runtime and converts its answer.
    async fn assist_call<T, U, F, Fut>(&self, f: F) -> Result<U, AssistError>
    where
        F: FnOnce(Arc<client_core::Client>) -> Fut,
        Fut: Future<Output = Result<T, proto::AssistError>> + Send + 'static,
        T: Send + 'static,
        U: From<T>,
    {
        let fut = f(self.core());
        on_runtime(fut).await.map(U::from).map_err(Into::into)
    }
}

#[uniffi::export]
impl DaemonClient {
    /// Sets the receiver of [`AssistEvent`]s, replacing any previous one.
    pub fn set_assist_listener(&self, listener: Arc<dyn AssistListener>) {
        self.inner
            .set_assist_listener(Arc::new(AssistForward(listener)));
    }

    /// The last foreground program reported for a pane (no round trip).
    pub fn foreground(&self, pane_id: u64) -> Option<Foreground> {
        self.inner
            .foreground(proto::PaneId(pane_id))
            .map(Into::into)
    }

    /// The last prompt state reported for a pane (no round trip).
    pub fn prompt_state(&self, pane_id: u64) -> Option<PromptState> {
        self.inner
            .prompt_state(proto::PaneId(pane_id))
            .map(Into::into)
    }

    /// Starts (`watch: true`) or stops prompt-state pushes for a pane; returns the state
    /// now. Watches end with the connection: watch again after `.connected`.
    ///
    /// # Errors
    ///
    /// The daemon's [`AssistError`].
    pub async fn watch_prompt(&self, pane_id: u64, watch: bool) -> Result<PaneAssist, AssistError> {
        self.assist_call(|client| async move {
            client.watch_prompt(proto::PaneId(pane_id), watch).await
        })
        .await
    }

    /// The pane's foreground program and prompt state now.
    ///
    /// # Errors
    ///
    /// The daemon's [`AssistError`].
    pub async fn pane_assist(&self, pane_id: u64) -> Result<PaneAssist, AssistError> {
        self.assist_call(|client| async move { client.pane_assist(proto::PaneId(pane_id)).await })
            .await
    }

    /// Replaces the shell's input line at prompt `prompt_id` with `text` and, if `run`,
    /// presses Return, as one write. Returns the output offset of the write (the echo
    /// follows).
    ///
    /// # Errors
    ///
    /// [`AssistError::NotAtPrompt`] with the pane's state now when it left that prompt
    /// (nothing was written); otherwise the daemon's [`AssistError`].
    pub async fn submit_line(
        &self,
        pane_id: u64,
        prompt_id: u64,
        text: String,
        run: bool,
    ) -> Result<u64, AssistError> {
        let seq: proto::Seq = self
            .assist_call(|client| async move {
                client
                    .submit_line(proto::PaneId(pane_id), prompt_id, text, run)
                    .await
            })
            .await?;
        Ok(seq.0)
    }

    /// Commands from the host's history, best first (frecency).
    ///
    /// # Errors
    ///
    /// The daemon's [`AssistError`] (`Denied` without the driver role).
    pub async fn history(&self, query: HistoryQuery) -> Result<Vec<HistoryEntry>, AssistError> {
        let entries: Vec<proto::HistoryEntry> = self
            .assist_call(|client| async move { client.history(query.into()).await })
            .await?;
        Ok(entries.into_iter().map(Into::into).collect())
    }

    /// Completion candidates for `line` with the cursor at `cursor` (Unicode scalars), in
    /// the pane's directory and shell.
    ///
    /// # Errors
    ///
    /// The daemon's [`AssistError`].
    pub async fn complete(
        &self,
        pane_id: u64,
        line: String,
        cursor: u32,
        limit: u32,
    ) -> Result<Completions, AssistError> {
        self.assist_call(|client| async move {
            client
                .complete(proto::PaneId(pane_id), line, cursor, limit)
                .await
        })
        .await
    }

    /// Fuzzy file search under `root` (absolute or `~/…`, within the daemon's allowed
    /// roots), for `@` mentions.
    ///
    /// # Errors
    ///
    /// The daemon's [`AssistError`] (`Denied` outside the allowed roots).
    pub async fn file_search(
        &self,
        query: String,
        root: String,
        limit: u32,
    ) -> Result<FileMatches, AssistError> {
        self.assist_call(|client| async move { client.file_search(root, query, limit).await })
            .await
    }

    /// The decision the agent in a pane is blocked on, if any.
    ///
    /// # Errors
    ///
    /// The daemon's [`AssistError`].
    pub async fn blocked_options(
        &self,
        pane_id: u64,
    ) -> Result<Option<BlockedPrompt>, AssistError> {
        let blocked: Option<proto::BlockedPrompt> = self
            .assist_call(
                |client| async move { client.blocked_options(proto::PaneId(pane_id)).await },
            )
            .await?;
        Ok(blocked.map(Into::into))
    }

    /// Picks option `index` (labelled `label`, as shown) of the dialog on screen by typing
    /// its keys.
    ///
    /// # Errors
    ///
    /// [`AssistError::NotFound`] when the dialog no longer offers it; otherwise the daemon's
    /// [`AssistError`] (`Denied` without the approver role).
    pub async fn answer_blocked(
        &self,
        pane_id: u64,
        index: u32,
        label: String,
    ) -> Result<(), AssistError> {
        self.assist_call(|client| async move {
            client
                .answer_blocked(proto::PaneId(pane_id), index, label)
                .await
        })
        .await
    }
}
