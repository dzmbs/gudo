//! per pane, the shell's prompt state and input line, atomic submit, command history,
//! completion, fuzzy file search for `@` mentions, and the options of a blocked agent.
//!
//! Requests travel as [`ClientCtl::Assist`](crate::ClientCtl::Assist) with a client-chosen
//! `req_id` and are answered by [`ServerCtl::AssistResult`](crate::ServerCtl::AssistResult)
//! holding `Result<`[`AssistResponse`]`, `[`AssistError`]`>`. Changes are pushed as
//! [`ServerCtl::Assist`](crate::ServerCtl::Assist): [`AssistPush::Foreground`] to every client
//! showing the pane's session, [`AssistPush::Prompt`] only to connections that asked with
//! [`AssistRequest::Watch`].
//!
//! Text positions (`cursor`, completion ranges, match positions) count Unicode scalar values
//! (Rust `char`s), not bytes or UTF-16 units.
//!
//! Same compatibility rules as the rest of the crate: append only. A daemon without these
//! messages never sends them, so a client stays in direct-typing mode.

use serde::{Deserialize, Serialize};

use crate::ids::{OptionId, PaneId, RequestId, Seq, UnixMillis};
use crate::workspace::FileKind;

// ---------------------------------------------------------------------------------------------
// Requests and responses
// ---------------------------------------------------------------------------------------------

/// An input-assistance request (see the module docs).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AssistRequest {
    /// Starts (`watch: true`) or stops pushing [`AssistPush::Prompt`] for a pane to this
    /// connection → [`AssistResponse::State`] (the state now, either way).
    Watch {
        /// The pane.
        pane_id: PaneId,
        /// Watch or stop watching.
        watch: bool,
    },
    /// The pane's foreground program and prompt state now → [`AssistResponse::State`].
    State {
        /// The pane.
        pane_id: PaneId,
    },
    /// Replaces the shell's input line with `text` and runs it, atomically →
    /// [`AssistResponse::Submitted`], or [`AssistError::NotAtPrompt`] with nothing written.
    SubmitLine(SubmitLine),
    /// Commands from the host's history, best first → [`AssistResponse::History`].
    History(HistoryQuery),
    /// Completions for a command line → [`AssistResponse::Completions`].
    Complete(CompleteRequest),
    /// Fuzzy file search under a directory, for `@` mentions → [`AssistResponse::Files`].
    FileSearch(FileSearch),
    /// The decision an agent in the pane is blocked on, with an answer per button →
    /// [`AssistResponse::Blocked`].
    BlockedOptions {
        /// The agent pane.
        pane_id: PaneId,
    },
    /// Answers the dialog on screen by typing one option's keys, after checking it still shows
    /// that option → [`AssistResponse::Done`].
    AnswerBlocked(AnswerBlocked),
}

/// The answer to an [`AssistRequest`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AssistResponse {
    /// Done; nothing to return.
    Done,
    /// A pane's foreground program and prompt state.
    State(PaneAssist),
    /// The line was written to the shell.
    Submitted {
        /// The prompt it was submitted at.
        prompt_id: u64,
        /// Output offset when it was written; the echo follows.
        at_seq: Seq,
    },
    /// History entries, best first.
    History(Vec<HistoryEntry>),
    /// Completion candidates.
    Completions(Completions),
    /// File search results.
    Files(FileMatches),
    /// The blocked agent's decision, `None` when the agent is not blocked.
    Blocked(Option<BlockedPrompt>),
}

/// Why an input-assistance request failed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AssistError {
    /// The connection's roles or scope do not allow it; the text names the role needed.
    Denied(String),
    /// The pane does not exist or is outside the grant's scope.
    UnknownPane,
    /// The pane is not at the expected shell prompt (a command runs, the prompt changed, a
    /// full-screen program is up, or there is no shell integration). Nothing was written. The
    /// pane's state now is attached so the client can resynchronise.
    NotAtPrompt(PromptState),
    /// The request was malformed; the text says why.
    Invalid(String),
    /// The path, dialog or option does not exist (any more).
    NotFound(String),
    /// Anything else; the text says why.
    Failed(String),
    /// The connection dropped before the answer arrived (client side only).
    Disconnected,
}

impl std::fmt::Display for AssistError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Denied(why) => write!(f, "not allowed: {why}"),
            Self::UnknownPane => f.write_str("no such pane"),
            Self::NotAtPrompt(_) => f.write_str("the pane is not at that shell prompt"),
            Self::Invalid(why) => write!(f, "invalid request: {why}"),
            Self::NotFound(what) => write!(f, "not found: {what}"),
            Self::Failed(why) => f.write_str(why),
            Self::Disconnected => f.write_str("disconnected before the daemon answered"),
        }
    }
}

impl std::error::Error for AssistError {}

/// A push about a pane (see the module docs).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AssistPush {
    /// The pane's foreground program changed (debounced: short-lived commands are not
    /// reported).
    Foreground(Foreground),
    /// The prompt state or input line of a watched pane changed.
    Prompt(PromptState),
}

/// Everything [`AssistRequest::State`] reports about a pane.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneAssist {
    /// The foreground program, if it could be read.
    pub foreground: Option<Foreground>,
    /// The prompt state.
    pub prompt: PromptState,
}

// ---------------------------------------------------------------------------------------------
// D1: foreground program
// ---------------------------------------------------------------------------------------------

/// The process group in the foreground of a pane's terminal (`tcgetpgrp` on the PTY).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Foreground {
    /// The pane.
    pub pane_id: PaneId,
    /// Process id of the group leader.
    pub pid: u32,
    /// The program's name: the basename of `argv[0]` (login `-` stripped), else the kernel's
    /// process name.
    pub name: String,
    /// The full argument vector, empty if unreadable.
    pub argv: Vec<String>,
    /// What kind of program it is, for picking a key-bar profile.
    pub profile: ProgramProfile,
    /// When it became the foreground program (as far as the daemon saw).
    pub since: UnixMillis,
}

/// The kind of program in a pane's foreground, for picking an input profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ProgramProfile {
    /// A shell (`bash`, `zsh`, `fish`, `sh`, …).
    Shell,
    /// vi-style modal editors (`vim`, `nvim`, `vi`, `hx`, `kak`).
    Vim,
    /// Pagers (`less`, `more`, `man`, `most`).
    Pager,
    /// System monitors (`top`, `htop`, `btop`, `btm`, `glances`, `atop`, `nvtop`).
    Monitor,
    /// Terminal multiplexers (`tmux`, `screen`, `zellij`).
    Tmux,
    /// Interactive interpreters and database shells (`python`, `node`, `irb`, `psql`, …)
    /// started without a script.
    Repl,
    /// Claude Code.
    Claude,
    /// Codex.
    Codex,
    /// Anything else.
    Other,
}

impl ProgramProfile {
    /// Classifies a program by its name and arguments.
    ///
    /// Interpreters count as [`Repl`](Self::Repl) only without a script argument, and an
    /// interpreter running a script named `claude` or `codex` (npm installs) counts as that
    /// agent.
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::ProgramProfile;
    ///
    /// assert_eq!(ProgramProfile::classify("-zsh", &[]), ProgramProfile::Shell);
    /// assert_eq!(ProgramProfile::classify("nvim", &["nvim".into()]), ProgramProfile::Vim);
    /// assert_eq!(ProgramProfile::classify("python3", &["python3".into()]), ProgramProfile::Repl);
    /// let script = ["python3".into(), "serve.py".into()];
    /// assert_eq!(ProgramProfile::classify("python3", &script), ProgramProfile::Other);
    /// let npm = ["node".into(), "/usr/local/bin/claude".into()];
    /// assert_eq!(ProgramProfile::classify("node", &npm), ProgramProfile::Claude);
    /// ```
    pub fn classify(name: &str, argv: &[String]) -> Self {
        let base = |s: &str| -> String {
            let b = s.rsplit('/').next().unwrap_or(s);
            b.strip_prefix('-').unwrap_or(b).to_ascii_lowercase()
        };
        let program = argv
            .first()
            .map(|a| base(a))
            .filter(|b| !b.is_empty())
            .unwrap_or_else(|| base(name));
        // Interpreters running a script: classify by the script (npm-installed agents).
        let script = argv
            .iter()
            .skip(1)
            .find(|a| !a.starts_with('-'))
            .map(|a| base(a));
        let stem = program.trim_end_matches(|c: char| c.is_ascii_digit() || c == '.');
        let interpreter = matches!(stem, "node" | "bun" | "deno" | "python");
        let agent = std::iter::once(program.as_str())
            .chain(script.as_deref().filter(|_| interpreter))
            .find_map(|candidate| match candidate {
                "claude" | "claude-code" => Some(Self::Claude),
                "codex" | "codex-cli" => Some(Self::Codex),
                _ => None,
            });
        if let Some(agent) = agent {
            return agent;
        }
        match stem {
            "bash" | "zsh" | "fish" | "sh" | "dash" | "ksh" | "mksh" | "tcsh" | "csh" | "nu"
            | "elvish" | "xonsh" | "pwsh" | "ash" | "yash" => Self::Shell,
            "vi" | "vim" | "nvim" | "view" | "vimdiff" | "gvim" | "hx" | "helix" | "kak" => {
                Self::Vim
            }
            "less" | "more" | "most" | "man" | "pg" => Self::Pager,
            "top" | "htop" | "btop" | "btm" | "glances" | "atop" | "nvtop" | "iotop" | "bpytop"
            | "gotop" | "nmon" => Self::Monitor,
            "tmux" | "screen" | "zellij" | "byobu" => Self::Tmux,
            "python" | "ipython" | "node" | "deno" | "bun" | "irb" | "ruby" | "ghci" | "iex"
            | "erl" | "lua" | "luajit" | "julia" | "r" | "scala" | "clj" | "clojure" | "ocaml"
            | "utop" | "php" | "perl" | "sbcl" | "racket" | "guile" | "swift" | "jshell" => {
                if script.is_none() || argv.iter().any(|a| a == "-i" || a == "repl") {
                    Self::Repl
                } else {
                    Self::Other
                }
            }
            "sqlite" | "psql" | "mysql" | "mariadb" | "redis-cli" | "mongosh" | "mongo"
            | "duckdb" | "bc" | "dc" => Self::Repl,
            _ => Self::Other,
        }
    }
}

// ---------------------------------------------------------------------------------------------
// D2: prompt state
// ---------------------------------------------------------------------------------------------

/// A pane's shell prompt state, from OSC 133 marks and the screen.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PromptState {
    /// The pane.
    pub pane_id: PaneId,
    /// Identifies the prompt instance: it changes whenever a command starts (OSC 133;C), so a
    /// submit naming it cannot land in a running command or a later prompt. Redraws of the same
    /// prompt (resize, Ctrl-L) keep it.
    pub prompt_id: u64,
    /// Output offset the state was read at.
    pub at_seq: Seq,
    /// What the shell is doing.
    pub phase: PromptPhase,
}

/// What the shell in a pane is doing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum PromptPhase {
    /// Editing a command line at its prompt.
    AtPrompt(PromptInput),
    /// A command started from the prompt runs.
    Running {
        /// The command (as in [`CommandMark`](crate::CommandMark)).
        command_id: u64,
    },
    /// No prompt known: no shell integration yet, a full-screen program is up, or the
    /// foreground program is not the shell.
    Unknown,
}

/// The shell's input line as read off the screen.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PromptInput {
    /// The command line, soft wraps joined, without prompt text, a right prompt or an
    /// autosuggestion.
    pub text: String,
    /// Cursor position in `text`.
    pub cursor: u32,
    /// The reading is reliable enough to prefill an editor with. When `false`, `doubt` says
    /// why and the client should start empty.
    pub confident: bool,
    /// Why the reading may be wrong.
    pub doubt: Option<InputDoubt>,
    /// Greyed-out suggestion text shown after the cursor (zsh-autosuggestions, fish), left out
    /// of `text`.
    pub suggestion: Option<String>,
    /// A right-hand prompt (zsh `RPROMPT`) was recognised and left out.
    pub right_prompt: bool,
    /// The shell.
    pub shell: ShellKind,
    /// The shell enabled bracketed paste (mode 2004), so multi-line text can be submitted.
    pub bracketed_paste: bool,
    pub keymap: Keymap,
}

/// Why a [`PromptInput`] may be wrong.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum InputDoubt {
    /// The shell does not mark where input starts (fish 3 sends no OSC 133;B); the start was
    /// inferred from where the cursor was after the prompt was drawn.
    NoInputMark,
    /// The cursor is outside the input area.
    CursorOutside,
    /// Text after the cursor is styled differently from the typed text and may be a
    /// suggestion in an unrecognised color.
    PossibleGhostText,
    /// Non-blank rows follow the input line: a completion listing or the tail of a
    /// multi-line command. They are left out.
    ContentBelow,
    /// A continuation prompt (PS2) is up; only the current line is editable.
    Continuation,
    /// Trailing text at the right edge may be a right prompt, but it could not be matched
    /// against the one drawn with the prompt.
    RightPromptGuess,
    /// The input area could not be read (it left the screen).
    Unreadable,
}

/// Which shell runs at the prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ShellKind {
    /// zsh.
    Zsh,
    /// bash.
    Bash,
    /// fish.
    Fish,
    /// Another shell.
    Other,
}

/// A line editor keymap.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Keymap {
    /// Emacs bindings (the default in bash, zsh and fish).
    Emacs,
    /// vi insert or command mode.
    Vi,
    /// Not reported.
    Unknown,
}

// ---------------------------------------------------------------------------------------------
// D3: atomic submit
// ---------------------------------------------------------------------------------------------

/// Replaces the input line at a prompt and (optionally) runs it, as one PTY write.
///
/// The daemon checks that the pane is still at prompt `prompt_id` with the shell in the
/// foreground and no full-screen program up, then writes, in one write: end-of-line and
/// kill-line (`^E ^U`, which clears the line in the emacs keymaps of bash, zsh and fish), the
/// text as a bracketed paste, and Return when `run`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubmitLine {
    /// The pane.
    pub pane_id: PaneId,
    /// [`PromptState::prompt_id`] the client saw.
    pub prompt_id: u64,
    /// The command line. Control characters other than newline and tab are refused; newlines
    /// need bracketed paste.
    pub text: String,
    /// Press Return after it (else the text is left in the shell's editor).
    pub run: bool,
}

// ---------------------------------------------------------------------------------------------
// D4: history
// ---------------------------------------------------------------------------------------------

/// What [`AssistRequest::History`] returns.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryQuery {
    /// Rank commands used in this directory (and its relatives) higher.
    pub cwd: Option<String>,
    /// Only commands starting with this.
    pub prefix: Option<String>,
    /// Only commands containing this (case-insensitive).
    pub contains: Option<String>,
    /// Only commands last used at or after this.
    pub since: Option<UnixMillis>,
    /// Most entries returned (the daemon caps it at 1000).
    pub limit: u32,
}

/// One distinct command from the history.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryEntry {
    /// The command line.
    pub command: String,
    /// Directory of its last run, if known.
    pub cwd: Option<String>,
    /// Exit status of its last run, if known.
    pub exit: Option<i32>,
    /// Duration of its last run, if known.
    pub duration_ms: Option<u64>,
    /// When it last ran.
    pub last_at: UnixMillis,
    /// How often it ran.
    pub count: u32,
}

// ---------------------------------------------------------------------------------------------
// D5: completion
// ---------------------------------------------------------------------------------------------

/// What [`AssistRequest::Complete`] completes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompleteRequest {
    /// The pane (its working directory and shell).
    pub pane_id: PaneId,
    /// The command line being edited.
    pub line: String,
    /// Cursor position in `line`.
    pub cursor: u32,
    /// Most candidates wanted (the daemon caps it at 200).
    pub limit: u32,
}

/// Completion candidates, best first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Completions {
    /// The directory paths were completed in.
    pub cwd: Option<String>,
    /// The candidates.
    pub items: Vec<Completion>,
}

/// One completion candidate: replace `line[start..end]` with `text`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Completion {
    /// Replacement text, quoted for the shell where needed.
    pub text: String,
    /// Label to show.
    pub display: String,
    /// Where it came from.
    pub kind: CompletionKind,
    /// Extra information (a history entry's directory, a git ref's kind).
    pub detail: Option<String>,
    /// Start of the replaced range in the line.
    pub start: u32,
    /// End of the replaced range in the line.
    pub end: u32,
}

/// Where a [`Completion`] came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CompletionKind {
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
    /// An option.
    Flag,
    /// A snippet.
    Snippet,
}

// ---------------------------------------------------------------------------------------------
// D7: file search
// ---------------------------------------------------------------------------------------------

/// What [`AssistRequest::FileSearch`] looks for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileSearch {
    /// Directory to search under (absolute or `~/…`, within the daemon's allowed roots).
    pub root: String,
    /// Fuzzy query: its characters must appear in order in the relative path.
    pub query: String,
    /// Most matches wanted (the daemon caps it at 200).
    pub limit: u32,
}

/// File search results, best first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileMatches {
    /// The root searched, resolved.
    pub root: String,
    /// The matches.
    pub matches: Vec<FileMatch>,
    /// Paths considered (files that `.gitignore` and hidden-file rules let through).
    pub scanned: u32,
    /// The walk stopped at the daemon's limit, so some files were not considered.
    pub truncated: bool,
}

/// One file search match.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileMatch {
    /// Path relative to the root, `/`-separated.
    pub path: String,
    /// File or directory.
    pub kind: FileKind,
    /// Positions in `path` of the characters that matched the query, for highlighting.
    pub positions: Vec<u32>,
}

// ---------------------------------------------------------------------------------------------
// D9: blocked agent options
// ---------------------------------------------------------------------------------------------

/// A decision an agent is waiting for, with a way to give each answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockedPrompt {
    /// The agent pane.
    pub pane_id: PaneId,
    /// The request to answer with [`ClientCtl::Decide`](crate::ClientCtl::Decide), when the
    /// agent's hook holds it open (options then carry an `option_id`).
    pub request_id: Option<RequestId>,
    /// What the agent wants, for display.
    pub summary: String,
    /// The answers, in the order the agent shows them.
    pub options: Vec<BlockedOption>,
    /// Where the options were read from.
    pub source: BlockedSource,
}

/// One answer to a [`BlockedPrompt`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockedOption {
    /// Button label.
    pub label: String,
    /// What the answer means.
    pub choice: BlockedChoice,
    /// Answer through [`ClientCtl::Decide`](crate::ClientCtl::Decide) with this id (signed,
    /// approver role); `None` when only keystrokes can answer.
    pub option_id: Option<OptionId>,
    /// Keys that pick this option in the dialog on screen; empty when the screen shows no
    /// menu. [`AssistRequest::AnswerBlocked`] types them after re-checking the screen.
    #[serde(with = "crate::serde_bytes")]
    pub keys: Vec<u8>,
    /// The dialog's cursor is on this option.
    pub selected: bool,
}

/// What a [`BlockedOption`] means.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum BlockedChoice {
    /// Allow this one request.
    AllowOnce,
    /// Allow and stop asking for the session.
    AllowSession,
    /// Refuse.
    Deny,
    /// Something else (an answer to a question).
    Other,
}

/// Where a [`BlockedPrompt`]'s options came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum BlockedSource {
    /// The agent's hook (exact), matched to the menu on screen for keys when it is visible.
    Hook,
    /// Parsed from the numbered menu on screen.
    Screen,
}

/// Picks option `index` of the dialog on screen by typing its keys.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AnswerBlocked {
    /// The agent pane.
    pub pane_id: PaneId,
    /// Index into [`BlockedPrompt::options`].
    pub index: u32,
    /// The label the client showed; the daemon refuses if the screen no longer offers it at
    /// that index.
    pub label: String,
}
