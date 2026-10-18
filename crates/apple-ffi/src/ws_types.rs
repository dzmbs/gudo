//! FFI mirrors of the workspace wire types (`proto::workspace`): forwards, ports, git, files,
//! worktrees, attention, the editor, the VS Code tunnel and push registration.
//!
//! Same rules as [`crate::types`]: ids are `u64`, times are Unix milliseconds (`*_ms`),
//! payloads are [`Bytes`].

use client_core::proto;

use crate::bytes::Bytes;
use crate::types::{AgentKind, Axis, CommandMark};

// --- errors ---------------------------------------------------------------------------------

/// Why a workspace request (files, git, worktrees, editor, push, forwards) failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum WorkspaceError {
    /// Outside the allowed roots, `..` components, or not allowed by the grant's roles.
    #[error("not allowed: {message}")]
    Denied {
        /// Why.
        message: String,
    },
    /// The path, repository, pane, turn or editor does not exist.
    #[error("not found: {message}")]
    NotFound {
        /// What.
        message: String,
    },
    /// The target changed or exists (`if_match` mismatch, destination exists, dirty worktree).
    #[error("conflict: {message}")]
    Conflict {
        /// Why.
        message: String,
    },
    /// The request was malformed.
    #[error("invalid request: {message}")]
    Invalid {
        /// Why.
        message: String,
    },
    /// A tool the request needs is missing on the host (git, the `code` CLI).
    #[error("unavailable: {message}")]
    Unavailable {
        /// Why, and what to do about it.
        message: String,
    },
    /// Anything else (including local I/O: binding a forward, writing a download).
    #[error("{message}")]
    Failed {
        /// Why.
        message: String,
    },
    /// The connection dropped before the daemon answered.
    #[error("disconnected before the daemon answered")]
    Disconnected,
}

impl From<proto::WsError> for WorkspaceError {
    fn from(e: proto::WsError) -> Self {
        use proto::WsError as E;
        match e {
            E::Denied(message) => Self::Denied { message },
            E::NotFound(message) => Self::NotFound { message },
            E::Conflict(message) => Self::Conflict { message },
            E::Invalid(message) => Self::Invalid { message },
            E::Unavailable(message) => Self::Unavailable { message },
            E::Failed(message) => Self::Failed { message },
            E::Disconnected => Self::Disconnected,
        }
    }
}

impl From<client_core::ClientError> for WorkspaceError {
    fn from(e: client_core::ClientError) -> Self {
        Self::Failed {
            message: e.to_string(),
        }
    }
}

// --- forwards and ports ---------------------------------------------------------------------

/// Where a forward connects on the daemon's host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ForwardTarget {
    /// `localhost:port` (IPv4 loopback, then IPv6).
    Tcp {
        /// The port.
        port: u16,
    },
    /// A Unix domain socket (absolute or `~/…`; path policy applies).
    Unix {
        /// The socket's path.
        path: String,
    },
}

impl From<ForwardTarget> for proto::ForwardTarget {
    fn from(t: ForwardTarget) -> Self {
        match t {
            ForwardTarget::Tcp { port } => Self::Tcp { port },
            ForwardTarget::Unix { path } => Self::Unix { path },
        }
    }
}

impl From<proto::ForwardTarget> for ForwardTarget {
    fn from(t: proto::ForwardTarget) -> Self {
        match t {
            proto::ForwardTarget::Tcp { port } => Self::Tcp { port },
            proto::ForwardTarget::Unix { path } => Self::Unix { path },
        }
    }
}

/// A running forward: `127.0.0.1:local_port` here → `target` on the host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForwardInfo {
    /// The bound local port.
    pub local_port: u16,
    /// Where it goes.
    pub target: ForwardTarget,
}

/// What a detected port speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PortKind {
    /// HTTP (answered a request, or the pane printed an `http://` URL).
    Http,
    /// HTTPS.
    Https,
    /// Something else.
    Other,
    /// Not probed yet.
    Unknown,
}

/// A listening TCP port owned by a process in a pane.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PortInfo {
    /// The port.
    pub port: u16,
    /// Bound to loopback only, so reachable only through a forward.
    pub loopback_only: bool,
    /// The pane whose process tree owns it.
    pub pane_id: Option<u64>,
    /// The owning process.
    pub pid: u32,
    /// Its name.
    pub process: String,
    /// What it speaks.
    pub kind: PortKind,
    /// A URL the pane printed for it.
    pub url: Option<String>,
}

impl From<proto::PortInfo> for PortInfo {
    fn from(p: proto::PortInfo) -> Self {
        Self {
            port: p.port,
            loopback_only: p.loopback_only,
            pane_id: p.pane_id.map(|p| p.0),
            pid: p.pid,
            process: p.process,
            kind: match p.kind {
                proto::PortKind::Http => PortKind::Http,
                proto::PortKind::Https => PortKind::Https,
                proto::PortKind::Other => PortKind::Other,
                proto::PortKind::Unknown => PortKind::Unknown,
            },
            url: p.url,
        }
    }
}

// --- git ------------------------------------------------------------------------------------

/// How a path changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum FileChange {
    /// No change on this side.
    Unmodified,
    /// Contents or mode changed.
    Modified,
    /// New file.
    Added,
    /// Removed.
    Deleted,
    /// Renamed (see the old path).
    Renamed,
    /// Copied.
    Copied,
    /// File ↔ symlink.
    TypeChanged,
    /// Merge conflict.
    Unmerged,
    /// Not tracked.
    Untracked,
}

impl From<proto::FileChange> for FileChange {
    fn from(c: proto::FileChange) -> Self {
        use proto::FileChange as C;
        match c {
            C::Unmodified => Self::Unmodified,
            C::Modified => Self::Modified,
            C::Added => Self::Added,
            C::Deleted => Self::Deleted,
            C::Renamed => Self::Renamed,
            C::Copied => Self::Copied,
            C::TypeChanged => Self::TypeChanged,
            C::Unmerged => Self::Unmerged,
            C::Untracked => Self::Untracked,
        }
    }
}

/// One path in a [`GitStatus`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GitFileStatus {
    /// Relative to the root.
    pub path: String,
    /// Before a rename or copy.
    pub orig_path: Option<String>,
    /// `HEAD` vs index.
    pub staged: FileChange,
    /// Index vs worktree.
    pub unstaged: FileChange,
}

/// Repository status.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GitStatus {
    /// Top level of the worktree.
    pub root: String,
    /// Branch; `nil` when detached.
    pub branch: Option<String>,
    /// `HEAD`; `nil` with no commits.
    pub head: Option<String>,
    /// Upstream branch.
    pub upstream: Option<String>,
    /// Commits ahead of upstream.
    pub ahead: u32,
    /// Commits behind.
    pub behind: u32,
    /// Changed, unmerged and untracked paths.
    pub files: Vec<GitFileStatus>,
}

impl From<proto::GitStatus> for GitStatus {
    fn from(s: proto::GitStatus) -> Self {
        Self {
            root: s.root,
            branch: s.branch,
            head: s.head,
            upstream: s.upstream,
            ahead: s.ahead,
            behind: s.behind,
            files: s
                .files
                .into_iter()
                .map(|f| GitFileStatus {
                    path: f.path,
                    orig_path: f.orig_path,
                    staged: f.staged.into(),
                    unstaged: f.unstaged.into(),
                })
                .collect(),
        }
    }
}

/// What a diff compares against.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum DiffBase {
    /// `HEAD` vs the worktree (staged, unstaged and untracked together).
    Head,
    /// The index vs the worktree.
    Index,
    /// `HEAD` vs the index.
    Staged,
    /// A commit, branch or tag vs the worktree.
    Rev {
        /// The revision.
        rev: String,
    },
    /// The merge base of `HEAD` and a branch vs the worktree.
    MergeBase {
        /// The branch.
        branch: String,
    },
}

impl From<DiffBase> for proto::DiffBase {
    fn from(b: DiffBase) -> Self {
        match b {
            DiffBase::Head => Self::Head,
            DiffBase::Index => Self::Index,
            DiffBase::Staged => Self::Staged,
            DiffBase::Rev { rev } => Self::Rev(rev),
            DiffBase::MergeBase { branch } => Self::MergeBase(branch),
        }
    }
}

/// A diff request.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GitDiffRequest {
    /// Any directory inside the repository.
    pub path: String,
    /// What to compare against.
    pub base: DiffBase,
    /// Only these paths (relative to the root); empty for all.
    #[uniffi(default = [])]
    pub files: Vec<String>,
    /// Context lines.
    #[uniffi(default = 3)]
    pub context: u32,
    /// Include hunks (else only the file list with counts).
    #[uniffi(default = true)]
    pub hunks: bool,
}

impl From<GitDiffRequest> for proto::GitDiffRequest {
    fn from(r: GitDiffRequest) -> Self {
        Self {
            path: r.path,
            base: r.base.into(),
            files: r.files,
            context: r.context,
            hunks: r.hunks,
        }
    }
}

/// Kinds of [`DiffLine`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum LineKind {
    /// Unchanged.
    Context,
    /// Added.
    Added,
    /// Removed.
    Removed,
    /// `\ No newline at end of file`.
    NoNewline,
}

/// One line of a hunk.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DiffLine {
    /// Its kind.
    pub kind: LineKind,
    /// The text without marker or line ending.
    pub text: String,
}

/// One `@@` hunk.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Hunk {
    /// First old line.
    pub old_start: u32,
    /// Old line count.
    pub old_lines: u32,
    /// First new line.
    pub new_start: u32,
    /// New line count.
    pub new_lines: u32,
    /// Text after the second `@@`.
    pub header: String,
    /// The lines.
    pub lines: Vec<DiffLine>,
}

/// One file of a [`GitDiff`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileDiff {
    /// Path after the change.
    pub path: String,
    /// Path before a rename or copy.
    pub old_path: Option<String>,
    /// What happened.
    pub change: FileChange,
    /// Binary: no hunks.
    pub binary: bool,
    /// Added lines.
    pub additions: u32,
    /// Removed lines.
    pub deletions: u32,
    /// Hunks, unless left out.
    pub hunks: Vec<Hunk>,
    /// Hunks were left out (too large, or not asked for).
    pub hunks_omitted: bool,
}

/// A diff, file by file.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GitDiff {
    /// Top level of the worktree.
    pub root: String,
    /// Tree it starts from.
    pub from: String,
    /// Tree it ends at.
    pub to: String,
    /// Changed files.
    pub files: Vec<FileDiff>,
    /// Some hunks were left out to stay under the size caps.
    pub truncated: bool,
}

impl From<proto::GitDiff> for GitDiff {
    fn from(d: proto::GitDiff) -> Self {
        Self {
            root: d.root,
            from: d.from,
            to: d.to,
            truncated: d.truncated,
            files: d
                .files
                .into_iter()
                .map(|f| FileDiff {
                    path: f.path,
                    old_path: f.old_path,
                    change: f.change.into(),
                    binary: f.binary,
                    additions: f.additions,
                    deletions: f.deletions,
                    hunks_omitted: f.hunks_omitted,
                    hunks: f
                        .hunks
                        .into_iter()
                        .map(|h| Hunk {
                            old_start: h.old_start,
                            old_lines: h.old_lines,
                            new_start: h.new_start,
                            new_lines: h.new_lines,
                            header: h.header,
                            lines: h
                                .lines
                                .into_iter()
                                .map(|l| DiffLine {
                                    kind: match l.kind {
                                        proto::LineKind::Context => LineKind::Context,
                                        proto::LineKind::Added => LineKind::Added,
                                        proto::LineKind::Removed => LineKind::Removed,
                                        proto::LineKind::NoNewline => LineKind::NoNewline,
                                    },
                                    text: l.text,
                                })
                                .collect(),
                        })
                        .collect(),
                })
                .collect(),
        }
    }
}

/// One agent turn the daemon snapshotted.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TurnInfo {
    /// Per-pane turn number, from 1.
    pub turn: u64,
    /// Repository top level.
    pub root: String,
    /// Start, Unix ms.
    pub started_at_ms: u64,
    /// End, Unix ms; `nil` while running.
    pub ended_at_ms: Option<u64>,
    /// Tree at the start.
    pub start_tree: String,
    /// Tree at the end.
    pub end_tree: Option<String>,
}

impl From<proto::TurnInfo> for TurnInfo {
    fn from(t: proto::TurnInfo) -> Self {
        Self {
            turn: t.turn,
            root: t.root,
            started_at_ms: t.started_at.0,
            ended_at_ms: t.ended_at.map(|t| t.0),
            start_tree: t.start_tree,
            end_tree: t.end_tree,
        }
    }
}

/// A review note on a range of lines.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReviewNote {
    /// File, relative to the repository root.
    pub path: String,
    /// First line (new side unless `old_side`).
    pub start_line: u32,
    /// Last line, inclusive.
    pub end_line: u32,
    /// The lines are on the old side.
    #[uniffi(default = false)]
    pub old_side: bool,
    /// Quoted code to include.
    #[uniffi(default = None)]
    pub quote: Option<String>,
    /// The note.
    pub note: String,
}

/// Review notes for an agent pane.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReviewRequest {
    /// The agent pane.
    pub pane_id: u64,
    /// Text before the notes; a default when `nil`.
    #[uniffi(default = None)]
    pub preamble: Option<String>,
    /// The notes.
    pub notes: Vec<ReviewNote>,
    /// Press Enter after typing the prompt.
    #[uniffi(default = true)]
    pub submit: bool,
}

impl From<ReviewRequest> for proto::ReviewRequest {
    fn from(r: ReviewRequest) -> Self {
        Self {
            pane_id: proto::PaneId(r.pane_id),
            preamble: r.preamble,
            submit: r.submit,
            notes: r
                .notes
                .into_iter()
                .map(|n| proto::ReviewNote {
                    path: n.path,
                    start_line: n.start_line,
                    end_line: n.end_line,
                    old_side: n.old_side,
                    quote: n.quote,
                    note: n.note,
                })
                .collect(),
        }
    }
}

// --- worktrees ------------------------------------------------------------------------------

/// Creates a worktree.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorktreeCreate {
    /// Any directory inside the repository.
    pub repo: String,
    /// New branch; generated when `nil`.
    #[uniffi(default = None)]
    pub branch: Option<String>,
    /// Start point; `HEAD` when `nil`.
    #[uniffi(default = None)]
    pub base: Option<String>,
    /// Directory; under the daemon's worktree root when `nil`.
    #[uniffi(default = None)]
    pub path: Option<String>,
}

impl From<WorktreeCreate> for proto::WorktreeCreate {
    fn from(w: WorktreeCreate) -> Self {
        Self {
            repo: w.repo,
            branch: w.branch,
            base: w.base,
            path: w.path,
        }
    }
}

/// One worktree.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorktreeInfo {
    /// Its directory.
    pub path: String,
    /// Branch; `nil` when detached.
    pub branch: Option<String>,
    /// `HEAD`.
    pub head: Option<String>,
    /// The main worktree.
    pub main: bool,
    /// Locked.
    pub locked: bool,
    /// Its directory is gone.
    pub prunable: bool,
    /// `PORT` given to panes in it.
    pub port: Option<u16>,
}

impl From<proto::WorktreeInfo> for WorktreeInfo {
    fn from(w: proto::WorktreeInfo) -> Self {
        Self {
            path: w.path,
            branch: w.branch,
            head: w.head,
            main: w.main,
            locked: w.locked,
            prunable: w.prunable,
            port: w.port,
        }
    }
}

/// What [`DaemonClient::worktree_launch`](crate::DaemonClient::worktree_launch) starts.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorktreeLaunch {
    /// The worktree's directory.
    pub path: String,
    /// Pane to split.
    pub split_from: u64,
    /// Split direction.
    pub axis: Axis,
    /// Agent to run; `nil` opens a shell.
    #[uniffi(default = None)]
    pub agent: Option<AgentKind>,
}

// --- files ----------------------------------------------------------------------------------

/// What a path is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
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

impl From<proto::FileKind> for FileKind {
    fn from(k: proto::FileKind) -> Self {
        match k {
            proto::FileKind::File => Self::File,
            proto::FileKind::Dir => Self::Dir,
            proto::FileKind::Symlink => Self::Symlink,
            proto::FileKind::Other => Self::Other,
        }
    }
}

/// `lstat` of a path.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileStat {
    /// Absolute path.
    pub path: String,
    /// File name.
    pub name: String,
    /// What it is.
    pub kind: FileKind,
    /// Size in bytes.
    pub size: u64,
    /// Modification time, Unix ms.
    pub modified_ms: u64,
    /// Permission bits.
    pub mode: u32,
    /// Dot file.
    pub hidden: bool,
    /// Symlink target as stored.
    pub link_target: Option<String>,
    /// What the symlink points at; `nil` if dangling.
    pub target_kind: Option<FileKind>,
    /// Opaque version for `WriteTarget.if_match`.
    pub version: String,
}

impl From<proto::FileStat> for FileStat {
    fn from(s: proto::FileStat) -> Self {
        Self {
            path: s.path,
            name: s.name,
            kind: s.kind.into(),
            size: s.size,
            modified_ms: s.modified.0,
            mode: s.mode,
            hidden: s.hidden,
            link_target: s.link_target,
            target_kind: s.target_kind.map(Into::into),
            version: s.version,
        }
    }
}

/// A directory listing: directories first, then by name.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DirListing {
    /// The directory, absolute.
    pub path: String,
    /// Entries.
    pub entries: Vec<FileStat>,
    /// More than 10 000 entries; the rest were left out.
    pub truncated: bool,
}

impl From<proto::DirListing> for DirListing {
    fn from(d: proto::DirListing) -> Self {
        Self {
            path: d.path,
            entries: d.entries.into_iter().map(Into::into).collect(),
            truncated: d.truncated,
        }
    }
}

/// Part of a file.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileChunk {
    /// The file when read.
    pub stat: FileStat,
    /// Offset of `data`.
    pub offset: u64,
    /// The bytes.
    pub data: Bytes,
    /// Reaches the end of the file.
    pub eof: bool,
}

impl From<proto::FileChunk> for FileChunk {
    fn from(c: proto::FileChunk) -> Self {
        Self {
            stat: c.stat.into(),
            offset: c.offset,
            data: c.data.into(),
            eof: c.eof,
        }
    }
}

/// How to delete.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DeleteMode {
    /// Into the user's trash.
    Trash,
    /// For good.
    Permanent,
}

impl From<DeleteMode> for proto::DeleteMode {
    fn from(m: DeleteMode) -> Self {
        match m {
            DeleteMode::Trash => Self::Trash,
            DeleteMode::Permanent => Self::Permanent,
        }
    }
}

/// Where a write or upload goes (written to a temporary file, then renamed over the target).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WriteTarget {
    /// The file.
    pub path: String,
    /// Only replace the file if it still has this [`FileStat::version`].
    #[uniffi(default = None)]
    pub if_match: Option<String>,
    /// Fail if the file exists.
    #[uniffi(default = false)]
    pub create_new: bool,
    /// Create missing parent directories.
    #[uniffi(default = false)]
    pub mkdirs: bool,
    /// Permission bits for a new file.
    #[uniffi(default = None)]
    pub mode: Option<u32>,
}

impl From<WriteTarget> for proto::WriteTarget {
    fn from(t: WriteTarget) -> Self {
        Self {
            path: t.path,
            if_match: t.if_match,
            create_new: t.create_new,
            mkdirs: t.mkdirs,
            mode: t.mode,
        }
    }
}

/// Changes in a watched directory (debounced).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FsChange {
    /// The watch.
    pub watch_id: u64,
    /// Changed paths (absolute).
    pub paths: Vec<String>,
    /// Too many to name: list the directory again.
    pub rescan: bool,
}

// --- attention ------------------------------------------------------------------------------

/// What an attention item is about.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AttentionKind {
    /// An agent waits for a decision or an answer.
    AgentBlocked {
        /// `claude`, `codex`.
        agent: String,
        /// Answer with `decide` when set.
        request_id: Option<u64>,
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
    /// A long command finished unseen.
    CommandFinished {
        /// The command.
        mark: CommandMark,
    },
}

/// One item of the attention feed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AttentionItem {
    /// Increasing id.
    pub id: u64,
    /// When, Unix ms.
    pub at_ms: u64,
    /// The pane.
    pub pane_id: u64,
    /// The pane's session.
    pub session_id: Option<u64>,
    /// What happened.
    pub kind: AttentionKind,
    /// Notification title.
    pub title: String,
    /// Body.
    pub body: String,
    /// Seen on some device.
    pub seen: bool,
    /// A client showed the pane when it happened.
    pub while_viewed: bool,
}

impl From<proto::AttentionItem> for AttentionItem {
    fn from(i: proto::AttentionItem) -> Self {
        Self {
            id: i.id,
            at_ms: i.at.0,
            pane_id: i.pane_id.0,
            session_id: i.session_id.map(|s| s.0),
            kind: match i.kind {
                proto::AttentionKind::AgentBlocked { agent, request_id } => {
                    AttentionKind::AgentBlocked {
                        agent,
                        request_id: request_id.map(|r| r.0),
                    }
                }
                proto::AttentionKind::AgentDone { agent } => AttentionKind::AgentDone { agent },
                proto::AttentionKind::AgentFailed { agent } => AttentionKind::AgentFailed { agent },
                proto::AttentionKind::CommandFinished(mark) => {
                    AttentionKind::CommandFinished { mark: mark.into() }
                }
            },
            title: i.title,
            body: i.body,
            seen: i.seen,
            while_viewed: i.while_viewed,
        }
    }
}

/// The feed and this host's badge count.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AttentionList {
    /// The last 500 items, oldest first.
    pub items: Vec<AttentionItem>,
    /// Unseen items.
    pub unseen: u32,
}

impl From<proto::AttentionList> for AttentionList {
    fn from(l: proto::AttentionList) -> Self {
        Self {
            items: l.items.into_iter().map(Into::into).collect(),
            unseen: l.unseen,
        }
    }
}

/// Which items to mark seen (all conditions add up).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AttentionSeen {
    /// These ids.
    #[uniffi(default = [])]
    pub ids: Vec<u64>,
    /// Every item up to and including this id.
    #[uniffi(default = None)]
    pub up_to: Option<u64>,
    /// Every item of this pane.
    #[uniffi(default = None)]
    pub pane_id: Option<u64>,
}

impl From<AttentionSeen> for proto::AttentionSeen {
    fn from(s: AttentionSeen) -> Self {
        Self {
            ids: s.ids,
            up_to: s.up_to,
            pane_id: s.pane_id.map(proto::PaneId),
        }
    }
}

/// A change to the attention feed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AttentionUpdate {
    /// A new item.
    Added {
        /// The item.
        item: AttentionItem,
        /// Unseen items now.
        unseen: u32,
    },
    /// Items were marked seen.
    Seen {
        /// The items.
        ids: Vec<u64>,
        /// Unseen items now.
        unseen: u32,
    },
}

impl From<proto::AttentionUpdate> for AttentionUpdate {
    fn from(u: proto::AttentionUpdate) -> Self {
        match u {
            proto::AttentionUpdate::Added { item, unseen } => Self::Added {
                item: item.into(),
                unseen,
            },
            proto::AttentionUpdate::Seen { ids, unseen } => Self::Seen { ids, unseen },
        }
    }
}

// --- editor ---------------------------------------------------------------------------------

/// Which editor server.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum EditorKind {
    /// Microsoft's VS Code through `code serve-web` (the default; no sign-in).
    VsCode,
    /// Gitpod's openvscode-server (explicit fallback only).
    OpenVsCode,
    /// VSCodium's Web Host (MIT, Open VSX extensions): downloaded by the host on first use,
    /// never a licence prompt or sign-in.
    Vscodium,
}

impl From<proto::EditorKind> for EditorKind {
    fn from(k: proto::EditorKind) -> Self {
        match k {
            proto::EditorKind::VsCode => Self::VsCode,
            proto::EditorKind::OpenVsCode => Self::OpenVsCode,
            proto::EditorKind::Vscodium => Self::Vscodium,
        }
    }
}

impl From<EditorKind> for proto::EditorKind {
    fn from(k: EditorKind) -> Self {
        match k {
            EditorKind::VsCode => Self::VsCode,
            EditorKind::OpenVsCode => Self::OpenVsCode,
            EditorKind::Vscodium => Self::Vscodium,
        }
    }
}

/// Which editor a launch uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EditorChoice {
    /// The host's configured default (`[editor] default`): `code serve-web` unless the
    /// owner chose VSCodium. For VS Code it fails with `Unavailable` without the CLI and
    /// `Denied` without the licence accepted; it never switches editors silently.
    Auto,
    /// Exactly this one.
    Only {
        /// The editor.
        kind: EditorKind,
    },
}

impl From<EditorChoice> for proto::EditorChoice {
    fn from(c: EditorChoice) -> Self {
        match c {
            EditorChoice::Auto => Self::Auto,
            EditorChoice::Only { kind } => Self::Only(kind.into()),
        }
    }
}

/// Starts an editor server.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorLaunch {
    /// The folder to open.
    pub folder: String,
    /// Which editor.
    pub choice: EditorChoice,
    /// The user accepted the VS Code Server licence in the app.
    pub accept_vscode_license: bool,
}

impl From<EditorLaunch> for proto::EditorLaunch {
    fn from(l: EditorLaunch) -> Self {
        Self {
            folder: l.folder,
            choice: l.choice.into(),
            accept_vscode_license: l.accept_vscode_license,
        }
    }
}

/// A running editor server on the host's `127.0.0.1:port`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorInstance {
    /// Which editor.
    pub kind: EditorKind,
    /// The folder it serves.
    pub folder: String,
    /// Port on the host's loopback.
    pub port: u16,
    /// The connection token.
    pub token: String,
    /// Path and query to load (token and folder included).
    pub url_path: String,
    /// The server's pid.
    pub pid: u32,
    /// Start, Unix ms.
    pub started_at_ms: u64,
}

impl From<proto::EditorInstance> for EditorInstance {
    fn from(e: proto::EditorInstance) -> Self {
        Self {
            kind: e.kind.into(),
            folder: e.folder,
            port: e.port,
            token: e.token,
            url_path: e.url_path,
            pid: e.pid,
            started_at_ms: e.started_at.0,
        }
    }
}

/// Whether an editor can run on the host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorAvailability {
    /// The editor.
    pub kind: EditorKind,
    /// Installed (the `code` CLI found; openvscode-server downloaded).
    pub installed: bool,
    /// Downloadable on demand.
    pub downloadable: bool,
    /// The executable.
    pub path: Option<String>,
    /// Version, if known.
    pub version: Option<String>,
    /// Why it cannot run, or licence notes.
    pub note: Option<String>,
}

/// What the host offers and runs.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorList {
    /// Each editor and whether it can run.
    pub available: Vec<EditorAvailability>,
    /// Running servers.
    pub running: Vec<EditorInstance>,
}

impl From<proto::EditorList> for EditorList {
    fn from(l: proto::EditorList) -> Self {
        Self {
            available: l
                .available
                .into_iter()
                .map(|a| EditorAvailability {
                    kind: a.kind.into(),
                    installed: a.installed,
                    downloadable: a.downloadable,
                    path: a.path,
                    version: a.version,
                    note: a.note,
                })
                .collect(),
            running: l.running.into_iter().map(Into::into).collect(),
        }
    }
}

/// How `editor_open` reached the editor.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorOpened {
    /// The editor used.
    pub instance: EditorInstance,
    /// Opened in an already-open window; just show the editor.
    pub in_window: bool,
    /// Otherwise load this path and query.
    pub url_path: String,
}

impl From<proto::EditorOpened> for EditorOpened {
    fn from(o: proto::EditorOpened) -> Self {
        Self {
            instance: o.instance.into(),
            in_window: o.in_window,
            url_path: o.url_path,
        }
    }
}

// --- VS Code tunnel (opt-in fallback) -------------------------------------------------------

/// Which account a tunnel signs in with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TunnelProvider {
    /// GitHub (device code at `github.com/login/device`).
    GitHub,
    /// Microsoft.
    Microsoft,
}

impl From<proto::TunnelProvider> for TunnelProvider {
    fn from(p: proto::TunnelProvider) -> Self {
        match p {
            proto::TunnelProvider::GitHub => Self::GitHub,
            proto::TunnelProvider::Microsoft => Self::Microsoft,
        }
    }
}

impl From<TunnelProvider> for proto::TunnelProvider {
    fn from(p: TunnelProvider) -> Self {
        match p {
            TunnelProvider::GitHub => Self::GitHub,
            TunnelProvider::Microsoft => Self::Microsoft,
        }
    }
}

/// Starts the tunnel.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VsCodeTunnelStart {
    /// The user accepted the VS Code Server licence and Microsoft's privacy statement.
    pub accept_server_license: bool,
    /// Account to sign in with if needed.
    pub provider: TunnelProvider,
    /// Machine name on vscode.dev; `nil` keeps the last one or derives one.
    #[uniffi(default = None)]
    pub name: Option<String>,
}

/// Opens a folder or file through the tunnel.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VsCodeTunnelOpen {
    /// Workspace folder; `nil` picks the enclosing git work tree.
    #[uniffi(default = None)]
    pub folder: Option<String>,
    /// A folder or a file.
    pub path: String,
    /// 1-based line.
    #[uniffi(default = None)]
    pub line: Option<u32>,
    /// 1-based column.
    #[uniffi(default = None)]
    pub column: Option<u32>,
}

/// The `code` CLI on the host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VsCodeCli {
    /// The executable.
    pub path: String,
    /// Product version.
    pub version: Option<String>,
    /// Build commit.
    pub commit: Option<String>,
    /// SHA-256 of the archive (daemon installs only).
    pub sha256: Option<String>,
    /// Installed by the daemon from Microsoft, else the user's own.
    pub managed: bool,
}

/// A device-code sign-in waiting for the user (tunnel only; the default editor path never
/// asks for one).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeviceLogin {
    /// The account kind.
    pub provider: TunnelProvider,
    /// Where to enter the code.
    pub verification_url: String,
    /// The code.
    pub user_code: String,
    /// When printed, Unix ms.
    pub at_ms: u64,
}

/// What the tunnel is doing.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TunnelState {
    /// Not running.
    Stopped,
    /// Signing in or connecting.
    Starting,
    /// Show the URL and code.
    NeedsLogin {
        /// The sign-in.
        login: DeviceLogin,
    },
    /// Connected.
    Running {
        /// Machine name.
        name: String,
        /// `https://vscode.dev/tunnel/<name>…`.
        web_url: String,
        /// Not started by the daemon.
        adopted: bool,
    },
    /// Failed.
    Failed {
        /// Why.
        message: String,
        /// The daemon restarts it.
        retrying: bool,
    },
}

/// The host's VS Code tunnel.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VsCodeTunnelStatus {
    /// The CLI, if installed.
    pub cli: Option<VsCodeCli>,
    /// Microsoft publishes a CLI for this host (`vscode_cli_install` can fetch it).
    pub cli_downloadable: bool,
    /// The tunnel.
    pub state: TunnelState,
    /// The account kind last used.
    pub provider: Option<TunnelProvider>,
}

impl From<proto::VsCodeTunnelStatus> for VsCodeTunnelStatus {
    fn from(s: proto::VsCodeTunnelStatus) -> Self {
        Self {
            cli: s.cli.map(|c| VsCodeCli {
                path: c.path,
                version: c.version,
                commit: c.commit,
                sha256: c.sha256,
                managed: c.managed,
            }),
            cli_downloadable: s.cli_downloadable,
            state: match s.state {
                proto::TunnelState::Stopped => TunnelState::Stopped,
                proto::TunnelState::Starting => TunnelState::Starting,
                proto::TunnelState::NeedsLogin(l) => TunnelState::NeedsLogin {
                    login: DeviceLogin {
                        provider: l.provider.into(),
                        verification_url: l.verification_url,
                        user_code: l.user_code,
                        at_ms: l.at.0,
                    },
                },
                proto::TunnelState::Running {
                    name,
                    web_url,
                    adopted,
                } => TunnelState::Running {
                    name,
                    web_url,
                    adopted,
                },
                proto::TunnelState::Failed { message, retrying } => {
                    TunnelState::Failed { message, retrying }
                }
            },
            provider: s.provider.map(Into::into),
        }
    }
}

/// Where a folder or file opens through the tunnel.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VsCodeTunnelOpened {
    /// Machine name.
    pub name: String,
    /// Workspace folder.
    pub folder: String,
    /// `https://vscode.dev/tunnel/<name>/<folder>` (top-level web view; vscode.dev refuses
    /// framing).
    pub web_url: String,
    /// `vscode://vscode-remote/tunnel+…` for desktop VS Code.
    pub desktop_uri: String,
    /// Opened in a window already connected.
    pub in_window: bool,
}

impl From<proto::VsCodeTunnelOpened> for VsCodeTunnelOpened {
    fn from(o: proto::VsCodeTunnelOpened) -> Self {
        Self {
            name: o.name,
            folder: o.folder,
            web_url: o.web_url,
            desktop_uri: o.desktop_uri,
            in_window: o.in_window,
        }
    }
}

// --- push -----------------------------------------------------------------------------------

/// Which attention items a device wants pushed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PushPrefs {
    /// Approval requests (Approve / Deny actions).
    #[uniffi(default = true)]
    pub approvals: bool,
    /// An agent waits in the terminal.
    #[uniffi(default = true)]
    pub blocked: bool,
    /// An agent finished.
    #[uniffi(default = true)]
    pub done: bool,
    /// An agent's turn failed.
    #[uniffi(default = true)]
    pub failed: bool,
    /// A long command finished unseen.
    #[uniffi(default = true)]
    pub commands: bool,
}

impl From<PushPrefs> for proto::PushPrefs {
    fn from(p: PushPrefs) -> Self {
        Self {
            approvals: p.approvals,
            blocked: p.blocked,
            done: p.done,
            failed: p.failed,
            commands: p.commands,
        }
    }
}

impl From<proto::PushPrefs> for PushPrefs {
    fn from(p: proto::PushPrefs) -> Self {
        Self {
            approvals: p.approvals,
            blocked: p.blocked,
            done: p.done,
            failed: p.failed,
            commands: p.commands,
        }
    }
}

/// A device's push registration with one daemon.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushRegistration {
    /// The capability the push relay issued (`POST /v1/register`; see
    /// `push_relay_register_body`).
    pub cap: String,
    /// The device's X25519 public key (32 bytes, `generate_push_seal_key`).
    pub seal_key: Bytes,
    /// The relay that issued `cap`; the daemon's default when `nil`.
    #[uniffi(default = None)]
    pub relay_url: Option<String>,
    /// What to push.
    pub prefs: PushPrefs,
    /// A push-to-start capability for the agents Live Activity.
    #[uniffi(default = None)]
    pub activity_cap: Option<String>,
}

/// Push settings on the daemon and this device's registration.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushStatus {
    /// Pushes are on.
    pub enabled: bool,
    /// The daemon's default relay.
    pub relay_url: String,
    /// This device's preferences, if registered.
    pub registered: Option<PushPrefs>,
    /// Registered devices.
    pub devices: u32,
    /// The last delivery failure for this device.
    pub last_error: Option<String>,
}

impl From<proto::PushStatus> for PushStatus {
    fn from(s: proto::PushStatus) -> Self {
        Self {
            enabled: s.enabled,
            relay_url: s.relay_url,
            registered: s.registered.map(Into::into),
            devices: s.devices,
            last_error: s.last_error,
        }
    }
}

// --- events ---------------------------------------------------------------------------------

/// A workspace push from the daemon.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum WorkspaceEvent {
    /// The detected ports (the whole list).
    PortsChanged {
        /// Every detected port.
        ports: Vec<PortInfo>,
    },
    /// A watched directory changed.
    FsChanged {
        /// What changed.
        change: FsChange,
    },
    /// The attention feed changed.
    Attention {
        /// The change.
        update: AttentionUpdate,
    },
    /// The VS Code tunnel changed state (a device code to show, running, failed).
    VsCodeTunnel {
        /// The whole status.
        status: VsCodeTunnelStatus,
    },
}

impl From<client_core::WorkspaceEvent> for WorkspaceEvent {
    fn from(e: client_core::WorkspaceEvent) -> Self {
        use client_core::WorkspaceEvent as E;
        match e {
            E::PortsChanged { ports } => Self::PortsChanged {
                ports: ports.into_iter().map(Into::into).collect(),
            },
            E::FsChanged { change } => Self::FsChanged {
                change: FsChange {
                    watch_id: change.watch_id,
                    paths: change.paths,
                    rescan: change.rescan,
                },
            },
            E::Attention { update } => Self::Attention {
                update: update.into(),
            },
            E::VsCodeTunnel { status } => Self::VsCodeTunnel {
                status: status.into(),
            },
        }
    }
}
