//! server, git status and diffs, agent-turn changes, review notes, worktrees, files and the
//! attention feed.
//!
//! Requests travel as [`ClientCtl::Workspace`](crate::ClientCtl::Workspace) with a client-chosen
//! `req_id` and are answered by [`ServerCtl::WorkspaceResult`](crate::ServerCtl::WorkspaceResult)
//! holding `Result<`[`WorkspaceResponse`]`, `[`WsError`]`>`. Pushes arrive unrequested as
//! [`ServerCtl::PortsChanged`](crate::ServerCtl::PortsChanged),
//! [`ServerCtl::FsChanged`](crate::ServerCtl::FsChanged) and
//! [`ServerCtl::Attention`](crate::ServerCtl::Attention). File contents larger than a ctl frame
//! move on their own bidirectional streams ([`StreamHeader::Upload`](crate::StreamHeader::Upload),
//! [`StreamHeader::Download`](crate::StreamHeader::Download)) at bulk priority, so QUIC flow
//! control is the backpressure.
//!
//! Every path is absolute or starts with `~/` and must stay inside the daemon's allowed roots
//! (`$HOME` unless the host's config allows more); `..` components are refused.
//!
//! Same compatibility rules as the rest of the crate: append only.

use serde::{Deserialize, Serialize};

use crate::ids::{PaneId, RequestId, SessionId, UnixMillis};
use crate::layout::{AgentKind, Axis};
use crate::msg::CommandMark;

// ---------------------------------------------------------------------------------------------
// Port forwarding
// ---------------------------------------------------------------------------------------------

/// Where a [`StreamHeader::Forward`](crate::StreamHeader::Forward) stream connects on the
/// daemon's host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ForwardTarget {
    /// `localhost:port` (IPv4 loopback, then IPv6).
    Tcp {
        /// The port.
        port: u16,
    },
    /// A Unix domain socket, subject to the path policy.
    Unix {
        /// Absolute path (or `~/…`) of the socket.
        path: String,
    },
}

// ---------------------------------------------------------------------------------------------
// Requests and responses
// ---------------------------------------------------------------------------------------------

/// A workspace request (see the module docs).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkspaceRequest {
    /// Listening TCP ports owned by processes in panes → [`WorkspaceResponse::Ports`].
    ListPorts,
    /// Editors the host can run and the ones running → [`WorkspaceResponse::Editors`].
    EditorStatus,
    /// Starts (or reuses) an editor server for a folder → [`WorkspaceResponse::Editor`].
    EditorLaunch(EditorLaunch),
    /// Stops the editor serving `folder` → [`WorkspaceResponse::Done`].
    EditorStop {
        /// The folder.
        folder: String,
    },
    /// Opens a file at a line in the running editor → [`WorkspaceResponse::EditorOpened`].
    EditorOpen {
        /// Folder whose editor to use; `None` picks the running editor whose folder contains
        /// `path` (the deepest one).
        folder: Option<String>,
        /// The file.
        path: String,
        /// 1-based line.
        line: Option<u32>,
        /// 1-based column.
        column: Option<u32>,
    },
    /// Repository status → [`WorkspaceResponse::GitStatus`].
    GitStatus {
        /// Any directory inside the repository (or worktree).
        path: String,
    },
    /// A diff → [`WorkspaceResponse::GitDiff`].
    GitDiff(GitDiffRequest),
    /// The turns recorded for an agent pane, newest last → [`WorkspaceResponse::Turns`].
    ListTurns {
        /// The agent pane.
        pane_id: PaneId,
    },
    /// What an agent turn changed (worktree at turn start vs turn end, or vs now while the turn
    /// runs) → [`WorkspaceResponse::GitDiff`].
    TurnDiff {
        /// The agent pane.
        pane_id: PaneId,
        /// Turn number from [`TurnInfo::turn`]; `None` is the latest.
        turn: Option<u64>,
        /// Unified context lines.
        context: u32,
        /// Include hunks (else only the file list with counts).
        hunks: bool,
    },
    /// Formats review notes into a prompt and types it into an agent pane →
    /// [`WorkspaceResponse::ReviewSent`].
    SendReview(ReviewRequest),
    /// Creates a worktree on a new branch → [`WorkspaceResponse::Worktree`].
    WorktreeCreate(WorktreeCreate),
    /// The repository's worktrees → [`WorkspaceResponse::Worktrees`].
    WorktreeList {
        /// Any directory inside the repository.
        repo: String,
    },
    /// Removes a worktree; refused when it has changes unless `force` →
    /// [`WorkspaceResponse::Done`].
    WorktreeRemove {
        /// The worktree's directory.
        path: String,
        /// Remove even with uncommitted changes or untracked files.
        force: bool,
        /// Also delete its branch if it is fully merged (`git branch -d`).
        delete_branch: bool,
    },
    /// Splits `split_from` and runs a shell or an agent in a worktree, with the worktree's
    /// `PORT` in its environment → [`WorkspaceResponse::PaneCreated`].
    WorktreeLaunch {
        /// The worktree's directory.
        path: String,
        /// Pane to split.
        split_from: PaneId,
        /// Split direction.
        axis: Axis,
        /// Agent to launch; `None` opens a shell.
        agent: Option<AgentKind>,
    },
    /// Lists a directory → [`WorkspaceResponse::Dir`].
    FsList {
        /// The directory.
        path: String,
        /// Include dot files.
        show_hidden: bool,
    },
    /// Stats a path without following a final symlink → [`WorkspaceResponse::Stat`].
    FsStat {
        /// The path.
        path: String,
    },
    /// Reads part of a file (at most 1 MiB; use a download stream for more) →
    /// [`WorkspaceResponse::FileData`].
    FsRead {
        /// The file.
        path: String,
        /// Byte offset.
        offset: u64,
        /// Bytes wanted.
        len: u32,
    },
    /// Creates a directory → [`WorkspaceResponse::Stat`].
    FsMkdir {
        /// The directory.
        path: String,
        /// Create missing parents too.
        parents: bool,
    },
    /// Renames or moves → [`WorkspaceResponse::Stat`] of the destination.
    FsRename {
        /// Source.
        from: String,
        /// Destination.
        to: String,
        /// Replace an existing destination.
        overwrite: bool,
    },
    /// Deletes a file or directory → [`WorkspaceResponse::Done`].
    FsDelete {
        /// The path.
        path: String,
        /// Move to the user's trash, or delete for good.
        mode: DeleteMode,
        /// Allow deleting a non-empty directory.
        recursive: bool,
    },
    /// Watches a directory (not recursively) → [`WorkspaceResponse::Watching`]; changes
    /// arrive as [`ServerCtl::FsChanged`](crate::ServerCtl::FsChanged) on this connection.
    FsWatch {
        /// The directory.
        path: String,
    },
    /// Stops a watch → [`WorkspaceResponse::Done`].
    FsUnwatch {
        /// From [`WorkspaceResponse::Watching`].
        watch_id: u64,
    },
    /// The attention feed → [`WorkspaceResponse::Attention`].
    AttentionList,
    /// Marks attention items seen on every device → [`WorkspaceResponse::Attention`].
    AttentionSeen(AttentionSeen),
    /// Writes a small file in one message (at most 1 MiB; use an upload stream for more) →
    /// [`WorkspaceResponse::Stat`].
    FsWrite {
        /// Where and how.
        target: WriteTarget,
        /// The contents.
        #[serde(with = "crate::serde_bytes")]
        data: Vec<u8>,
    },
    /// The VS Code tunnel and the `code` CLI → [`WorkspaceResponse::VsCodeTunnel`].
    VsCodeTunnelStatus,
    /// Downloads Microsoft's `code` CLI from Microsoft's update service onto the host →
    /// [`WorkspaceResponse::VsCodeTunnel`].
    VsCodeCliInstall(VsCodeCliInstall),
    /// Starts (or reuses) the host's one VS Code tunnel → [`WorkspaceResponse::VsCodeTunnel`].
    /// Sign-in and progress arrive as
    /// [`ServerCtl::VsCodeTunnel`](crate::ServerCtl::VsCodeTunnel).
    VsCodeTunnelStart(VsCodeTunnelStart),
    /// Stops the tunnel the daemon runs (and its restart at daemon start) →
    /// [`WorkspaceResponse::VsCodeTunnel`].
    VsCodeTunnelStop,
    /// A folder, or a file at a line, through the running tunnel →
    /// [`WorkspaceResponse::VsCodeTunnelOpened`].
    VsCodeTunnelOpen(VsCodeTunnelOpen),
    /// Registers (or updates) this device for push notifications → [`WorkspaceResponse::Push`].
    PushRegister(PushRegistration),
    /// Stops push notifications to this device → [`WorkspaceResponse::Push`].
    PushUnregister,
    /// Push settings and this device's registration → [`WorkspaceResponse::Push`].
    PushStatus,
    /// Answers an approval from a notification action → [`WorkspaceResponse::PushDecided`].
    PushAction(PushActionRequest),
    /// Agent plan usage now → [`WorkspaceResponse::AgentUsage`]; while watching, changes
    /// arrive as [`ServerCtl::AgentUsage`](crate::ServerCtl::AgentUsage) (clients with
    /// [`Caps::AGENT_USAGE`](crate::Caps::AGENT_USAGE)). Sending it again refreshes (at most
    /// once a minute) and replaces the options. Only daemons offering
    /// [`DaemonFeatures::AGENT_USAGE`](crate::DaemonFeatures::AGENT_USAGE) understand it.
    UsageWatch(crate::UsageWatch),
    /// Stops this connection's usage pushes → [`WorkspaceResponse::Done`].
    UsageUnwatch,
    /// Re-reads the git state of every watched worktree (and the pull request of `path`'s, or
    /// of all of them) now → [`WorkspaceResponse::Repos`].
    RepoRefresh {
        /// One worktree whose pull request to refresh; `None` for all.
        path: Option<String>,
    },
    /// Merges a worktree's pull request → [`WorkspaceResponse::Pr`].
    PrMerge(crate::repo::PrMerge),
    /// Re-runs the failed jobs of the pull request's failed workflow runs (`gh run rerun
    /// --failed`) → [`WorkspaceResponse::Pr`].
    PrRerunFailed {
        /// The worktree.
        path: String,
    },
    /// Pushes the branch and opens a pull request → [`WorkspaceResponse::Pr`].
    PrCreate(crate::repo::PrCreate),
    /// Checks a pull request out into a new worktree → [`WorkspaceResponse::Worktree`].
    PrCheckout(crate::repo::PrCheckout),
    /// Archives a worktree: runs its teardown, keeps its commits (and, with `force`, its
    /// uncommitted changes) under a ref, removes the directory → [`WorkspaceResponse::Done`].
    /// Refused with `Conflict` when it has changes unless `force`.
    WorktreeArchive {
        /// The worktree.
        path: String,
        /// Archive even with uncommitted changes (they are saved and restored).
        force: bool,
    },
    /// Archived worktrees, newest first → [`WorkspaceResponse::Archived`].
    WorktreeArchived {
        /// Only this repository's (any directory inside it); `None` for all.
        repo: Option<String>,
    },
    /// Brings an archived worktree back where it was → [`WorkspaceResponse::Worktree`].
    WorktreeRestore {
        /// From [`ArchivedWorktree::id`](crate::repo::ArchivedWorktree::id).
        id: u64,
    },
    /// Reads, and with `Some` changes, the worktree housekeeping →
    /// [`WorkspaceResponse::WorktreeSettings`].
    WorktreeSettings(Option<crate::repo::WorktreeSettings>),
    /// A new task: worktree, branch and a tab with a shell or agent →
    /// [`WorkspaceResponse::TaskCreated`].
    TaskCreate(crate::repo::TaskCreate),
    /// Runs a script in a new tab → [`WorkspaceResponse::PaneCreated`].
    ScriptRun(crate::repo::ScriptRun),
    /// The running agents Live Activity's update capability (or that it ended) for this
    /// device's push registration → [`WorkspaceResponse::Push`]. Only daemons offering
    /// [`DaemonFeatures::LIVE_ACTIVITY`](crate::DaemonFeatures::LIVE_ACTIVITY) understand it.
    PushActivity(PushActivityToken),
    /// The workflows a pane can use (its repository's and the global ones), or only the global
    /// ones without a pane → [`WorkspaceResponse::Workflows`]. See [`crate::workflow`].
    WorkflowList {
        /// The pane whose repository to look in.
        pane_id: Option<PaneId>,
    },
    /// Writes a new workflow file (never replacing one) → [`WorkspaceResponse::WorkflowSaved`].
    WorkflowSave(crate::workflow::WorkflowSave),
}

/// The answer to a [`WorkspaceRequest`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkspaceResponse {
    /// Done; nothing to return.
    Done,
    /// Detected ports.
    Ports(Vec<PortInfo>),
    /// Editors.
    Editors(EditorList),
    /// A running editor server.
    Editor(EditorInstance),
    /// How a file was opened in the editor.
    EditorOpened(EditorOpened),
    /// Repository status.
    GitStatus(GitStatus),
    /// A diff.
    GitDiff(GitDiff),
    /// Recorded agent turns.
    Turns(Vec<TurnInfo>),
    /// The prompt that was typed into the pane.
    ReviewSent {
        /// The prompt text.
        prompt: String,
    },
    /// A worktree.
    Worktree(WorktreeInfo),
    /// Worktrees.
    Worktrees(Vec<WorktreeInfo>),
    /// A pane was created.
    PaneCreated {
        /// The new pane.
        pane_id: PaneId,
    },
    /// A directory listing.
    Dir(DirListing),
    /// One path's metadata.
    Stat(FileStat),
    /// Part of a file.
    FileData(FileChunk),
    /// A watch was set up.
    Watching {
        /// Id for [`WorkspaceRequest::FsUnwatch`] and in change events.
        watch_id: u64,
    },
    /// The attention feed.
    Attention(AttentionList),
    /// The VS Code tunnel and CLI.
    VsCodeTunnel(VsCodeTunnelStatus),
    /// Where a folder or file opens through the tunnel.
    VsCodeTunnelOpened(VsCodeTunnelOpened),
    /// Push settings and this device's registration.
    Push(PushStatus),
    /// A notification action's decision was applied.
    PushDecided(crate::Decided),
    /// Agent plan usage.
    AgentUsage(crate::AgentUsageReport),
    /// The repositories of the panes.
    Repos(crate::repo::RepoSnapshot),
    /// A worktree's pull request after the request (`None`: it has none).
    Pr(Option<crate::repo::PullRequest>),
    /// Archived worktrees.
    Archived(Vec<crate::repo::ArchivedWorktree>),
    /// The worktree housekeeping.
    WorktreeSettings(crate::repo::WorktreeSettings),
    /// A new task.
    TaskCreated(crate::repo::TaskCreated),
    /// Workflows.
    Workflows(crate::workflow::WorkflowList),
    /// The workflow as written (its file in [`Workflow::path`](crate::workflow::Workflow::path)).
    WorkflowSaved(crate::workflow::Workflow),
}

/// Why a workspace request failed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WsError {
    /// The path is outside the allowed roots, has `..` components, or the operation is not
    /// allowed by policy.
    Denied(String),
    /// The path, repository, pane, turn or editor does not exist.
    NotFound(String),
    /// The target changed or exists (`if_match` mismatch, destination exists, dirty worktree).
    Conflict(String),
    /// The request was malformed.
    Invalid(String),
    /// A tool the request needs is missing (git, an editor) or the platform lacks it.
    Unavailable(String),
    /// Anything else; the text says why.
    Failed(String),
    /// The connection dropped before the answer arrived (client side only).
    Disconnected,
}

impl std::fmt::Display for WsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Denied(why) => write!(f, "not allowed: {why}"),
            Self::NotFound(what) => write!(f, "not found: {what}"),
            Self::Conflict(why) => write!(f, "conflict: {why}"),
            Self::Invalid(why) => write!(f, "invalid request: {why}"),
            Self::Unavailable(why) => write!(f, "unavailable: {why}"),
            Self::Failed(why) => f.write_str(why),
            Self::Disconnected => f.write_str("disconnected before the daemon answered"),
        }
    }
}

impl std::error::Error for WsError {}

// ---------------------------------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------------------------------

/// A listening TCP port owned by a process in a pane's process tree.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PortInfo {
    /// The port.
    pub port: u16,
    /// Bound to loopback only (`127.0.0.1`/`::1`), so only reachable through a forward.
    pub loopback_only: bool,
    /// The pane whose process tree owns it.
    pub pane_id: Option<PaneId>,
    /// The owning process.
    pub pid: u32,
    /// The owning process's name.
    pub process: String,
    /// What it speaks, as far as the daemon can tell.
    pub kind: PortKind,
    /// A URL the pane printed for this port (`Local: http://localhost:5173/`), if any.
    pub url: Option<String>,
}

/// What a port speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PortKind {
    /// Answered an HTTP request, or the pane printed an `http://` URL for it.
    Http,
    /// Answered with TLS, or the pane printed an `https://` URL for it.
    Https,
    /// Answered with something else.
    Other,
    /// Not probed yet, or it did not answer in time.
    Unknown,
}

// ---------------------------------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------------------------------

/// Which editor server to run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum EditorKind {
    /// Microsoft's VS Code server through the user's `code serve-web` (Microsoft licence,
    /// Microsoft marketplace). Never downloaded or redistributed by us.
    VsCode,
    /// Gitpod's openvscode-server (MIT, Open VSX), downloaded on demand and SHA-256 pinned.
    OpenVsCode,
    /// VSCodium's Web Host (`vscodium-reh-web`, MIT, Open VSX extensions), downloaded on
    /// demand from VSCodium's GitHub releases and SHA-256 pinned. No licence prompt and no
    /// sign-in.
    Vscodium,
}

/// Which editor a launch should use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EditorChoice {
    /// The host's configured default (`[editor] default` in the daemon's `config.toml`):
    /// `code serve-web` (needs the `code` CLI and the licence accepted; the default) or
    /// VSCodium. Never falls back to another editor.
    Auto,
    /// Exactly this one.
    Only(EditorKind),
}

/// Starts an editor server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditorLaunch {
    /// The workspace folder to open.
    pub folder: String,
    /// Which editor.
    pub choice: EditorChoice,
    /// The user accepted the Microsoft VS Code Server licence in the app
    /// (<https://aka.ms/vscode-server-license>); required for [`EditorKind::VsCode`].
    pub accept_vscode_license: bool,
}

/// A running editor server, bound to `127.0.0.1:port` on the host. Open
/// `http://localhost:<port><url_path>` through a port forward.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditorInstance {
    /// Which editor.
    pub kind: EditorKind,
    /// The folder it serves.
    pub folder: String,
    /// Port on the host's loopback interface.
    pub port: u16,
    /// The connection token (random, per launch).
    pub token: String,
    /// Path and query to load, token and folder included.
    pub url_path: String,
    /// The server's process id.
    pub pid: u32,
    /// When it started.
    pub started_at: UnixMillis,
}

/// What the host offers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditorList {
    /// Each editor kind and whether it can run here.
    pub available: Vec<EditorAvailability>,
    /// Running servers.
    pub running: Vec<EditorInstance>,
}

/// Whether an editor kind can run on this host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditorAvailability {
    /// The editor.
    pub kind: EditorKind,
    /// Installed (the `code` CLI found; openvscode-server already downloaded).
    pub installed: bool,
    /// Can be downloaded on demand (openvscode-server on Linux x86_64/arm64).
    pub downloadable: bool,
    /// The executable, if found.
    pub path: Option<String>,
    /// Version, if known.
    pub version: Option<String>,
    /// Why it cannot run, if it cannot.
    pub note: Option<String>,
}

/// How [`WorkspaceRequest::EditorOpen`] reached the editor.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditorOpened {
    /// The editor used.
    pub instance: EditorInstance,
    /// The file was opened in the already-open editor window through the editor's own CLI
    /// channel; the app only needs to show the editor.
    pub in_window: bool,
    /// Otherwise load this path and query (it opens the file on load).
    pub url_path: String,
}

// ---------------------------------------------------------------------------------------------
// Git
// ---------------------------------------------------------------------------------------------

/// Repository status (`git status --porcelain=v2 --branch -z`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitStatus {
    /// Top level of the worktree.
    pub root: String,
    /// Current branch; `None` when detached.
    pub branch: Option<String>,
    /// `HEAD` commit; `None` in a repository with no commits.
    pub head: Option<String>,
    /// Upstream branch, if set.
    pub upstream: Option<String>,
    /// Commits ahead of upstream.
    pub ahead: u32,
    /// Commits behind upstream.
    pub behind: u32,
    /// Changed, unmerged and untracked paths.
    pub files: Vec<GitFileStatus>,
}

/// One path in [`GitStatus`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitFileStatus {
    /// Path relative to the root.
    pub path: String,
    /// Path before a rename or copy.
    pub orig_path: Option<String>,
    /// Change between `HEAD` and the index (staged).
    pub staged: FileChange,
    /// Change between the index and the worktree (unstaged).
    pub unstaged: FileChange,
}

/// How a path changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum FileChange {
    /// No change on this side.
    Unmodified,
    /// Contents or mode changed.
    Modified,
    /// New file.
    Added,
    /// Removed.
    Deleted,
    /// Renamed (see `orig_path`).
    Renamed,
    /// Copied (see `orig_path`).
    Copied,
    /// File type changed (file ↔ symlink).
    TypeChanged,
    /// Merge conflict.
    Unmerged,
    /// Not tracked.
    Untracked,
}

/// What a diff compares against.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum DiffBase {
    /// `HEAD` vs the worktree, staged, unstaged and untracked changes together.
    Head,
    /// The index vs the worktree (unstaged and untracked).
    Index,
    /// `HEAD` vs the index (staged).
    Staged,
    /// A commit, branch or tag vs the worktree.
    Rev(String),
    /// The merge base of `HEAD` and a branch vs the worktree (a worktree's whole change).
    MergeBase(String),
}

/// A diff request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitDiffRequest {
    /// Any directory inside the repository.
    pub path: String,
    /// What to compare against.
    pub base: DiffBase,
    /// Only these paths (relative to the root); empty for all.
    pub files: Vec<String>,
    /// Unified context lines (git's default is 3).
    pub context: u32,
    /// Include hunks (else only the file list with counts).
    pub hunks: bool,
}

/// A diff, file by file. Renames are detected (`-M`). A file's hunks are dropped when its
/// patch exceeds the per-file cap (1 MiB) and later files' hunks once the whole diff exceeds
/// 8 MiB; ask for those files alone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitDiff {
    /// Top level of the worktree.
    pub root: String,
    /// Tree the diff starts from.
    pub from: String,
    /// Tree it ends at.
    pub to: String,
    /// Changed files.
    pub files: Vec<FileDiff>,
    /// Some hunks were left out to stay under the size caps.
    pub truncated: bool,
}

/// One file in a [`GitDiff`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileDiff {
    /// Path after the change.
    pub path: String,
    /// Path before a rename or copy.
    pub old_path: Option<String>,
    /// What happened.
    pub change: FileChange,
    /// Git treats the file as binary; no hunks.
    pub binary: bool,
    /// Added lines.
    pub additions: u32,
    /// Removed lines.
    pub deletions: u32,
    /// The hunks, unless left out.
    pub hunks: Vec<Hunk>,
    /// The hunks were left out (too large, or not asked for).
    pub hunks_omitted: bool,
}

/// One `@@` hunk.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hunk {
    /// First line in the old file.
    pub old_start: u32,
    /// Lines in the old file.
    pub old_lines: u32,
    /// First line in the new file.
    pub new_start: u32,
    /// Lines in the new file.
    pub new_lines: u32,
    /// Text after the second `@@` (often the enclosing function).
    pub header: String,
    /// The lines.
    pub lines: Vec<DiffLine>,
}

/// One line of a hunk.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiffLine {
    /// Its kind.
    pub kind: LineKind,
    /// The text without the leading marker or line ending (lossy UTF-8).
    pub text: String,
}

/// Kinds of [`DiffLine`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum LineKind {
    /// Unchanged.
    Context,
    /// Added.
    Added,
    /// Removed.
    Removed,
    /// `\ No newline at end of file` for the previous line.
    NoNewline,
}

/// One agent turn the daemon snapshotted (worktree trees written without touching the index).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnInfo {
    /// Per-pane turn number, from 1.
    pub turn: u64,
    /// Top level of the repository the pane was in.
    pub root: String,
    /// When it started.
    pub started_at: UnixMillis,
    /// When it ended; `None` while running.
    pub ended_at: Option<UnixMillis>,
    /// Tree of the worktree at the start.
    pub start_tree: String,
    /// Tree at the end.
    pub end_tree: Option<String>,
}

/// Review notes to send to an agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewRequest {
    /// The agent pane.
    pub pane_id: PaneId,
    /// Text before the notes; a default is used when `None`.
    pub preamble: Option<String>,
    /// The notes, in order.
    pub notes: Vec<ReviewNote>,
    /// Press Enter after typing the prompt.
    pub submit: bool,
}

/// A note on a range of lines.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewNote {
    /// File, relative to the repository root.
    pub path: String,
    /// First line (in the new file unless `old_side`).
    pub start_line: u32,
    /// Last line, inclusive.
    pub end_line: u32,
    /// The lines refer to the old side (removed lines).
    pub old_side: bool,
    /// The quoted code, if the app wants it included.
    pub quote: Option<String>,
    /// What the reviewer says.
    pub note: String,
}

// ---------------------------------------------------------------------------------------------
// Worktrees
// ---------------------------------------------------------------------------------------------

/// Creates a worktree.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorktreeCreate {
    /// Any directory inside the repository.
    pub repo: String,
    /// New branch; a generated `<product>/<word>-<hex>` name when `None`.
    pub branch: Option<String>,
    /// Commit or branch to start from; `HEAD` when `None`.
    pub base: Option<String>,
    /// Directory; under the daemon's worktree root when `None`.
    pub path: Option<String>,
}

/// One worktree.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorktreeInfo {
    /// Its directory.
    pub path: String,
    /// Checked-out branch; `None` when detached.
    pub branch: Option<String>,
    /// `HEAD` commit.
    pub head: Option<String>,
    /// The repository's main worktree.
    pub main: bool,
    /// Locked (`git worktree lock`).
    pub locked: bool,
    /// Its directory is gone (`git worktree prune` would remove it).
    pub prunable: bool,
    /// `PORT` given to panes in it, if the daemon allocated one.
    pub port: Option<u16>,
}

// ---------------------------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------------------------

/// What a directory entry is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum FileKind {
    /// Regular file.
    File,
    /// Directory.
    Dir,
    /// Symbolic link.
    Symlink,
    /// Socket, FIFO, device.
    Other,
}

/// Metadata of one path (`lstat`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileStat {
    /// Absolute path.
    pub path: String,
    /// File name.
    pub name: String,
    /// What it is.
    pub kind: FileKind,
    /// Size in bytes.
    pub size: u64,
    /// Modification time.
    pub modified: UnixMillis,
    /// Unix permission bits.
    pub mode: u32,
    /// The name starts with a dot.
    pub hidden: bool,
    /// For a symlink: where it points (as stored).
    pub link_target: Option<String>,
    /// For a symlink: what the target is, `None` if dangling.
    pub target_kind: Option<FileKind>,
    /// Opaque version for `if_match` (inode, size and nanosecond mtime).
    pub version: String,
}

/// A directory listing, sorted directories first, then by name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DirListing {
    /// The directory, absolute.
    pub path: String,
    /// Its entries.
    pub entries: Vec<FileStat>,
    /// More than 10 000 entries; the rest were left out.
    pub truncated: bool,
}

/// Part of a file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileChunk {
    /// The file's metadata when read.
    pub stat: FileStat,
    /// Offset of `data`.
    pub offset: u64,
    /// The bytes.
    #[serde(with = "crate::serde_bytes")]
    pub data: Vec<u8>,
    /// `data` reaches the end of the file.
    pub eof: bool,
}

/// How [`WorkspaceRequest::FsDelete`] deletes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeleteMode {
    /// Move into the user's trash (`~/.Trash` on macOS, the XDG trash on Linux).
    Trash,
    /// Remove for good.
    Permanent,
}

/// Where an upload or [`WorkspaceRequest::FsWrite`] goes. The data is written to a temporary
/// file in the same directory and renamed over the target, so readers never see half a file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WriteTarget {
    /// The file.
    pub path: String,
    /// Only replace the file if it still has this [`FileStat::version`] (`None`: no check).
    pub if_match: Option<String>,
    /// Fail if the file exists (ignored when `if_match` is set).
    pub create_new: bool,
    /// Create missing parent directories.
    pub mkdirs: bool,
    /// Permission bits for a new file; an existing file keeps its own.
    pub mode: Option<u32>,
}

/// First frame of an upload stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadHeader {
    /// Where.
    pub target: WriteTarget,
    /// Exact number of bytes that will follow.
    pub size: u64,
}

/// First frame of a download stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DownloadHeader {
    /// The file.
    pub path: String,
    /// Where to start.
    pub offset: u64,
    /// Bytes wanted; `None` to the end.
    pub len: Option<u64>,
}

/// The daemon's frames on an upload or download stream.
///
/// Upload: header → `Ready` → the client sends exactly `size` raw bytes and finishes → `Done`
/// (or `Failed` at any point). Download: header → `Ready{stat, len}` → `len` raw bytes, then
/// the daemon finishes the stream (or `Failed` instead of `Ready`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransferReply {
    /// Go ahead. For a download, `len` raw bytes of the file follow.
    Ready {
        /// The file's metadata (for an upload: the existing file, if any).
        stat: Option<FileStat>,
        /// Bytes that follow (download) or are expected (upload).
        len: u64,
    },
    /// The upload is in place.
    Done(FileStat),
    /// The transfer failed; the stream ends.
    Failed(WsError),
}

/// Changes in a watched directory, debounced (about 100 ms).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FsChange {
    /// The watch.
    pub watch_id: u64,
    /// Paths that were created, changed or removed (absolute).
    pub paths: Vec<String>,
    /// Too many changes to name; list the directory again.
    pub rescan: bool,
}

// ---------------------------------------------------------------------------------------------
// Attention
// ---------------------------------------------------------------------------------------------

/// Something that needs (or got) the user's attention: one feed for local notifications and
/// the inbox, across all sessions of this daemon.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttentionItem {
    /// Increasing id, unique for the daemon's lifetime.
    pub id: u64,
    /// When it happened.
    pub at: UnixMillis,
    /// The pane.
    pub pane_id: PaneId,
    /// The pane's session, if it still has one.
    pub session_id: Option<SessionId>,
    /// What happened.
    pub kind: AttentionKind,
    /// One-line title for a notification ("claude needs you").
    pub title: String,
    /// Body text.
    pub body: String,
    /// A client looked at it (focused the pane or marked it seen); synced across devices.
    pub seen: bool,
    /// A client was showing the pane when it happened, so a notification would be noise.
    pub while_viewed: bool,
}

/// Kinds of [`AttentionItem`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AttentionKind {
    /// An agent waits for a decision or an answer.
    AgentBlocked {
        /// Agent name (`claude`, `codex`).
        agent: String,
        /// Answer with `Decide` when the agent asked through a hook.
        request_id: Option<RequestId>,
    },
    /// An agent finished its turn.
    AgentDone {
        /// Agent name.
        agent: String,
    },
    /// An agent's turn failed.
    AgentFailed {
        /// Agent name.
        agent: String,
    },
    /// A long command finished while no client showed its pane
    /// (also sent as `CommandFinishedUnseen`).
    CommandFinished(CommandMark),
}

/// The feed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttentionList {
    /// The last 500 items, oldest first.
    pub items: Vec<AttentionItem>,
    /// Items not seen yet (this daemon's badge count).
    pub unseen: u32,
}

/// Which items to mark seen. All conditions add up.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttentionSeen {
    /// These ids.
    pub ids: Vec<u64>,
    /// Every item with an id up to and including this one.
    pub up_to: Option<u64>,
    /// Every item of this pane.
    pub pane_id: Option<PaneId>,
}

/// A change to the attention feed, pushed to every client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AttentionUpdate {
    /// A new item.
    Added {
        /// The item.
        item: AttentionItem,
        /// Unseen items now.
        unseen: u32,
    },
    /// Items were marked seen (by a client, or because the pane was focused or the blocker
    /// went away).
    Seen {
        /// The items.
        ids: Vec<u64>,
        /// Unseen items now.
        unseen: u32,
    },
}

// ---------------------------------------------------------------------------------------------
// ---------------------------------------------------------------------------------------------

/// The Microsoft Software License Terms for Visual Studio Code, which cover the `code` CLI.
/// The app shows them before [`WorkspaceRequest::VsCodeCliInstall`].
pub const VSCODE_LICENSE_URL: &str = "https://code.visualstudio.com/license";
/// The Visual Studio Code Server licence that `code tunnel` (and `code serve-web`) asks the
/// user to accept. The app shows it before [`WorkspaceRequest::VsCodeTunnelStart`].
pub const VSCODE_SERVER_LICENSE_URL: &str = "https://aka.ms/vscode-server-license";
/// The Microsoft Privacy Statement, shown with the server licence (the CLI's own banner names
/// both).
pub const MICROSOFT_PRIVACY_URL: &str = "https://privacy.microsoft.com/en-US/privacystatement";

/// Installs the `code` CLI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VsCodeCliInstall {
    /// The user read and accepted [`VSCODE_LICENSE_URL`] in the app; refused otherwise.
    pub accept_license: bool,
}

/// Which account the tunnel signs in with (always the user's own).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TunnelProvider {
    /// A GitHub account (device code at `github.com/login/device`).
    GitHub,
    /// A Microsoft account (device code at `login.microsoft.com/device`).
    Microsoft,
}

/// Starts the tunnel.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VsCodeTunnelStart {
    /// The user read and accepted [`VSCODE_SERVER_LICENSE_URL`] and [`MICROSOFT_PRIVACY_URL`]
    /// in the app; refused otherwise.
    pub accept_server_license: bool,
    /// Account to sign in with if the CLI is not signed in yet.
    pub provider: TunnelProvider,
    /// Machine name on vscode.dev (at most 20 letters, digits and `-`); when `None` the daemon
    /// keeps the last one used, else derives one from the host name.
    pub name: Option<String>,
}

/// Opens a folder or file through the tunnel.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VsCodeTunnelOpen {
    /// Workspace folder; for a file, `None` picks the enclosing git work tree, else the file's
    /// directory.
    pub folder: Option<String>,
    /// A folder or a file.
    pub path: String,
    /// 1-based line.
    pub line: Option<u32>,
    /// 1-based column.
    pub column: Option<u32>,
}

/// The `code` CLI the tunnel uses.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VsCodeCli {
    /// The executable.
    pub path: String,
    /// Product version (`1.142.0`), if known.
    pub version: Option<String>,
    /// Build commit, if known.
    pub commit: Option<String>,
    /// SHA-256 of the archive it was unpacked from (daemon installs only).
    pub sha256: Option<String>,
    /// Installed by the daemon from Microsoft's update service, else the user's own.
    pub managed: bool,
}

/// A device-code sign-in waiting for the user.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceLogin {
    /// The account kind.
    pub provider: TunnelProvider,
    /// Where to enter the code (open it in a browser sheet).
    pub verification_url: String,
    /// The code to enter.
    pub user_code: String,
    /// When the CLI printed it.
    pub at: UnixMillis,
}

/// What the tunnel is doing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum TunnelState {
    /// Not running.
    Stopped,
    /// Starting: signing in or connecting to the tunnel service.
    Starting,
    /// The user has to sign in: show the URL and the code.
    NeedsLogin(DeviceLogin),
    /// Connected to Microsoft's tunnel service.
    Running {
        /// The machine name.
        name: String,
        /// `https://vscode.dev/tunnel/<name>…` as the CLI printed it.
        web_url: String,
        /// A tunnel the daemon did not start (the user's own `code tunnel` or its service).
        adopted: bool,
    },
    /// The tunnel failed.
    Failed {
        /// Why (the end of the CLI's output).
        message: String,
        /// The daemon restarts it after a back-off.
        retrying: bool,
    },
}

/// The VS Code tunnel on this host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VsCodeTunnelStatus {
    /// The CLI, if one is installed.
    pub cli: Option<VsCodeCli>,
    /// Microsoft publishes a CLI build for this host, so
    /// [`WorkspaceRequest::VsCodeCliInstall`] can fetch it.
    pub cli_downloadable: bool,
    /// The tunnel.
    pub state: TunnelState,
    /// The account kind last used.
    pub provider: Option<TunnelProvider>,
}

/// Where a folder or file opens through the tunnel.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VsCodeTunnelOpened {
    /// The tunnel's machine name.
    pub name: String,
    /// The workspace folder.
    pub folder: String,
    /// `https://vscode.dev/tunnel/<name>/<folder>`, for the in-app web view.
    pub web_url: String,
    /// `vscode://vscode-remote/tunnel+<name>/<path>[:line[:col]]`, for desktop VS Code with
    /// the Remote - Tunnels extension.
    pub desktop_uri: String,
    /// The file was opened at the line in a window already connected to the tunnel (through
    /// the server's own CLI channel); otherwise load `web_url` and ask again once connected.
    pub in_window: bool,
}

// ---------------------------------------------------------------------------------------------
// Push notifications (docs/PUSH.md)
// ---------------------------------------------------------------------------------------------

/// A device's push registration, sent over its own connection (so the daemon knows which
/// device it is). Everything Apple-side stays inside `cap`, which only the push relay can
/// open: the daemon never sees the APNs token.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushRegistration {
    /// The push capability the relay issued for this device and this daemon (`POST
    /// /v1/register`), opaque.
    pub cap: String,
    /// The device's X25519 public key; payloads are HPKE-sealed to it.
    pub seal_key: [u8; 32],
    /// The relay that issued `cap`; the daemon's configured relay when `None`.
    pub relay_url: Option<String>,
    /// What to push.
    pub prefs: PushPrefs,
    /// A push-to-start capability for the agents Live Activity, if the device has one.
    pub activity_cap: Option<String>,
}

/// The agents Live Activity running on a device (docs/PUSH.md §6): the relay capability for
/// its ActivityKit update token. The daemon sends `update` and `end` pushes to it, and a
/// push-to-start ([`PushRegistration::activity_cap`]) only while the device has none.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushActivityToken {
    /// The capability the relay issued for the activity's push token (`kind: "activity"`);
    /// `None`: the activity ended or was dismissed.
    pub cap: Option<String>,
}

/// Which attention items a device wants pushed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushPrefs {
    /// An agent asks to approve a tool call (actionable: Approve / Deny).
    pub approvals: bool,
    /// An agent waits for an answer in the terminal.
    pub blocked: bool,
    /// An agent finished its turn.
    pub done: bool,
    /// An agent's turn failed.
    pub failed: bool,
    /// A long command finished unseen.
    pub commands: bool,
}

impl Default for PushPrefs {
    fn default() -> Self {
        Self {
            approvals: true,
            blocked: true,
            done: true,
            failed: true,
            commands: true,
        }
    }
}

/// Push settings on the daemon and the asking device's registration.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushStatus {
    /// Pushes are on (`push.enabled` in the daemon's `config.toml`).
    pub enabled: bool,
    /// The relay the daemon posts to by default.
    pub relay_url: String,
    /// This device's preferences, if it is registered.
    pub registered: Option<PushPrefs>,
    /// Registered devices.
    pub devices: u32,
    /// The last delivery failure for this device, if the last attempt failed.
    pub last_error: Option<String>,
}

/// A decision taken in a notification action, without opening the app.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushActionRequest {
    /// The action token from the decrypted notification, verbatim.
    #[serde(with = "crate::serde_bytes")]
    pub token: Vec<u8>,
    /// Approve (`true`) or deny.
    pub approve: bool,
    /// The device's Ed25519 signature over the token and decision (crates/push
    /// `sign_decision`).
    #[serde(with = "crate::serde_bytes")]
    pub sig: Vec<u8>,
}
