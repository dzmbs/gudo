//! FFI mirrors of the workspace wire types (`proto::workspace`): forwards, ports, git, files,
//! worktrees, attention, the editor, the VS Code tunnel and push registration.
//!
//! Same rules as [`crate::types`]: ids are `u64`, times are Unix milliseconds (`*_ms`),
//! payloads are [`Bytes`].

use client_core::proto;

use crate::bytes::Bytes;
use crate::types::{AgentKind, Axis, CommandMark};

/// Why a workspace request (files, git, worktrees, editor, push, forwards) failed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum WorkspaceError {
    /// Outside the allowed roots, `..` components, or not allowed by the grant's roles.
    #[error("not allowed: {message}")]
    Denied { message: String },
    /// The path, repository, pane, turn or editor does not exist.
    #[error("not found: {message}")]
    NotFound { message: String },
    /// The target changed or exists (`if_match` mismatch, destination exists, dirty worktree).
    #[error("conflict: {message}")]
    Conflict { message: String },
    /// The request was malformed.
    #[error("invalid request: {message}")]
    Invalid { message: String },
    /// A tool the request needs is missing on the host (git, the `code` CLI).
    #[error("unavailable: {message}")]
    Unavailable {
        /// Why, and what to do about it.
        message: String,
    },
    /// Anything else (including local I/O: binding a forward, writing a download).
    #[error("{message}")]
    Failed { message: String },
    /// The connection dropped before the daemon answered.
    #[error("disconnected before the daemon answered")]
    Disconnected,
}

impl From<proto::WsError> for WorkspaceError {
    fn from(ws_error: proto::WsError) -> Self {
        use proto::WsError as E;
        match ws_error {
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
    fn from(client_error: client_core::ClientError) -> Self {
        Self::Failed {
            message: client_error.to_string(),
        }
    }
}

/// Where a forward connects on the daemon's host.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ForwardTarget {
    /// `localhost:port` (IPv4 loopback, then IPv6).
    Tcp { port: u16 },
    /// A Unix domain socket (absolute or `~/…`; path policy applies).
    Unix { path: String },
}

impl From<ForwardTarget> for proto::ForwardTarget {
    fn from(forward_target: ForwardTarget) -> Self {
        match forward_target {
            ForwardTarget::Tcp { port } => Self::Tcp { port },
            ForwardTarget::Unix { path } => Self::Unix { path },
        }
    }
}

impl From<proto::ForwardTarget> for ForwardTarget {
    fn from(forward_target: proto::ForwardTarget) -> Self {
        match forward_target {
            proto::ForwardTarget::Tcp { port } => Self::Tcp { port },
            proto::ForwardTarget::Unix { path } => Self::Unix { path },
        }
    }
}

/// A running forward: `127.0.0.1:local_port` here → `target` on the host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForwardInfo {
    pub local_port: u16,
    pub target: ForwardTarget,
}

/// What a detected port speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PortKind {
    /// HTTP (answered a request, or the pane printed an `http://` URL).
    Http,
    Https,
    Other,
    Unknown,
}

/// A listening TCP port owned by a process in a pane.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PortInfo {
    pub port: u16,
    /// Bound to loopback only, so reachable only through a forward.
    pub loopback_only: bool,
    /// The pane whose process tree owns it.
    pub pane_id: Option<u64>,
    pub pid: u32,
    pub process: String,
    pub kind: PortKind,
    /// A URL the pane printed for it.
    pub url: Option<String>,
}

impl From<proto::PortInfo> for PortInfo {
    fn from(port_info: proto::PortInfo) -> Self {
        Self {
            port: port_info.port,
            loopback_only: port_info.loopback_only,
            pane_id: port_info.pane_id.map(|port_info| port_info.0),
            pid: port_info.pid,
            process: port_info.process,
            kind: match port_info.kind {
                proto::PortKind::Http => PortKind::Http,
                proto::PortKind::Https => PortKind::Https,
                proto::PortKind::Other => PortKind::Other,
                proto::PortKind::Unknown => PortKind::Unknown,
            },
            url: port_info.url,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum FileChange {
    /// No change on this side.
    Unmodified,
    Modified,
    Added,
    Deleted,
    /// Renamed (see the old path).
    Renamed,
    Copied,
    /// File ↔ symlink.
    TypeChanged,
    Unmerged,
    Untracked,
}

impl From<proto::FileChange> for FileChange {
    fn from(file_change: proto::FileChange) -> Self {
        use proto::FileChange as C;
        match file_change {
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

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GitStatus {
    /// Top level of the worktree.
    pub root: String,
    /// Branch; `nil` when detached.
    pub branch: Option<String>,
    /// `HEAD`; `nil` with no commits.
    pub head: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u32,
    pub behind: u32,
    /// Changed, unmerged and untracked paths.
    pub files: Vec<GitFileStatus>,
}

impl From<proto::GitStatus> for GitStatus {
    fn from(git_status: proto::GitStatus) -> Self {
        Self {
            root: git_status.root,
            branch: git_status.branch,
            head: git_status.head,
            upstream: git_status.upstream,
            ahead: git_status.ahead,
            behind: git_status.behind,
            files: git_status
                .files
                .into_iter()
                .map(|file| GitFileStatus {
                    path: file.path,
                    orig_path: file.orig_path,
                    staged: file.staged.into(),
                    unstaged: file.unstaged.into(),
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
    Rev { rev: String },
    /// The merge base of `HEAD` and a branch vs the worktree.
    MergeBase { branch: String },
}

impl From<DiffBase> for proto::DiffBase {
    fn from(diff_base: DiffBase) -> Self {
        match diff_base {
            DiffBase::Head => Self::Head,
            DiffBase::Index => Self::Index,
            DiffBase::Staged => Self::Staged,
            DiffBase::Rev { rev } => Self::Rev(rev),
            DiffBase::MergeBase { branch } => Self::MergeBase(branch),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GitDiffRequest {
    /// Any directory inside the repository.
    pub path: String,
    pub base: DiffBase,
    /// Only these paths (relative to the root); empty for all.
    #[uniffi(default = [])]
    pub files: Vec<String>,
    #[uniffi(default = 3)]
    pub context: u32,
    /// Include hunks (else only the file list with counts).
    #[uniffi(default = true)]
    pub hunks: bool,
}

impl From<GitDiffRequest> for proto::GitDiffRequest {
    fn from(git_diff_request: GitDiffRequest) -> Self {
        Self {
            path: git_diff_request.path,
            base: git_diff_request.base.into(),
            files: git_diff_request.files,
            context: git_diff_request.context,
            hunks: git_diff_request.hunks,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum LineKind {
    Context,
    Added,
    Removed,
    /// `\ No newline at end of file`.
    NoNewline,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DiffLine {
    pub kind: LineKind,
    /// The text without marker or line ending.
    pub text: String,
}

/// One `@@` hunk.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Hunk {
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
    /// Text after the second `@@`.
    pub header: String,
    pub lines: Vec<DiffLine>,
}

/// One file of a [`GitDiff`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileDiff {
    pub path: String,
    /// Path before a rename or copy.
    pub old_path: Option<String>,
    pub change: FileChange,
    /// Binary: no hunks.
    pub binary: bool,
    pub additions: u32,
    pub deletions: u32,
    pub hunks: Vec<Hunk>,
    /// Hunks were left out (too large, or not asked for).
    pub hunks_omitted: bool,
}

/// A diff, file by file.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GitDiff {
    /// Top level of the worktree.
    pub root: String,
    pub from: String,
    pub to: String,
    pub files: Vec<FileDiff>,
    /// Some hunks were left out to stay under the size caps.
    pub truncated: bool,
}

impl From<proto::GitDiff> for GitDiff {
    fn from(git_diff: proto::GitDiff) -> Self {
        Self {
            root: git_diff.root,
            from: git_diff.from,
            to: git_diff.to,
            truncated: git_diff.truncated,
            files: git_diff
                .files
                .into_iter()
                .map(|file| FileDiff {
                    path: file.path,
                    old_path: file.old_path,
                    change: file.change.into(),
                    binary: file.binary,
                    additions: file.additions,
                    deletions: file.deletions,
                    hunks_omitted: file.hunks_omitted,
                    hunks: file
                        .hunks
                        .into_iter()
                        .map(|hunk| Hunk {
                            old_start: hunk.old_start,
                            old_lines: hunk.old_lines,
                            new_start: hunk.new_start,
                            new_lines: hunk.new_lines,
                            header: hunk.header,
                            lines: hunk
                                .lines
                                .into_iter()
                                .map(|line| DiffLine {
                                    kind: match line.kind {
                                        proto::LineKind::Context => LineKind::Context,
                                        proto::LineKind::Added => LineKind::Added,
                                        proto::LineKind::Removed => LineKind::Removed,
                                        proto::LineKind::NoNewline => LineKind::NoNewline,
                                    },
                                    text: line.text,
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
    pub root: String,
    pub started_at_ms: u64,
    /// End, Unix ms; `nil` while running.
    pub ended_at_ms: Option<u64>,
    pub start_tree: String,
    pub end_tree: Option<String>,
}

impl From<proto::TurnInfo> for TurnInfo {
    fn from(turn_info: proto::TurnInfo) -> Self {
        Self {
            turn: turn_info.turn,
            root: turn_info.root,
            started_at_ms: turn_info.started_at.0,
            ended_at_ms: turn_info.ended_at.map(|turn_info| turn_info.0),
            start_tree: turn_info.start_tree,
            end_tree: turn_info.end_tree,
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
    pub note: String,
}

/// Review notes for an agent pane.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReviewRequest {
    pub pane_id: u64,
    /// Text before the notes; a default when `nil`.
    #[uniffi(default = None)]
    pub preamble: Option<String>,
    pub notes: Vec<ReviewNote>,
    /// Press Enter after typing the prompt.
    #[uniffi(default = true)]
    pub submit: bool,
}

impl From<ReviewRequest> for proto::ReviewRequest {
    fn from(review_request: ReviewRequest) -> Self {
        Self {
            pane_id: proto::PaneId(review_request.pane_id),
            preamble: review_request.preamble,
            submit: review_request.submit,
            notes: review_request
                .notes
                .into_iter()
                .map(|note| proto::ReviewNote {
                    path: note.path,
                    start_line: note.start_line,
                    end_line: note.end_line,
                    old_side: note.old_side,
                    quote: note.quote,
                    note: note.note,
                })
                .collect(),
        }
    }
}

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
    fn from(worktree_create: WorktreeCreate) -> Self {
        Self {
            repo: worktree_create.repo,
            branch: worktree_create.branch,
            base: worktree_create.base,
            path: worktree_create.path,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorktreeInfo {
    pub path: String,
    /// Branch; `nil` when detached.
    pub branch: Option<String>,
    /// `HEAD`.
    pub head: Option<String>,
    pub main: bool,
    pub locked: bool,
    pub prunable: bool,
    /// `PORT` given to panes in it.
    pub port: Option<u16>,
}

impl From<proto::WorktreeInfo> for WorktreeInfo {
    fn from(worktree_info: proto::WorktreeInfo) -> Self {
        Self {
            path: worktree_info.path,
            branch: worktree_info.branch,
            head: worktree_info.head,
            main: worktree_info.main,
            locked: worktree_info.locked,
            prunable: worktree_info.prunable,
            port: worktree_info.port,
        }
    }
}

/// What [`DaemonClient::worktree_launch`](crate::DaemonClient::worktree_launch) starts.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorktreeLaunch {
    pub path: String,
    pub split_from: u64,
    pub axis: Axis,
    /// Agent to run; `nil` opens a shell.
    #[uniffi(default = None)]
    pub agent: Option<AgentKind>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum FileKind {
    File,
    Dir,
    Symlink,
    /// Socket, FIFO, device.
    Other,
}

impl From<proto::FileKind> for FileKind {
    fn from(file_kind: proto::FileKind) -> Self {
        match file_kind {
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
    pub path: String,
    pub name: String,
    pub kind: FileKind,
    pub size: u64,
    pub modified_ms: u64,
    pub mode: u32,
    pub hidden: bool,
    /// Symlink target as stored.
    pub link_target: Option<String>,
    /// What the symlink points at; `nil` if dangling.
    pub target_kind: Option<FileKind>,
    /// Opaque version for `WriteTarget.if_match`.
    pub version: String,
}

impl From<proto::FileStat> for FileStat {
    fn from(file_stat: proto::FileStat) -> Self {
        Self {
            path: file_stat.path,
            name: file_stat.name,
            kind: file_stat.kind.into(),
            size: file_stat.size,
            modified_ms: file_stat.modified.0,
            mode: file_stat.mode,
            hidden: file_stat.hidden,
            link_target: file_stat.link_target,
            target_kind: file_stat.target_kind.map(Into::into),
            version: file_stat.version,
        }
    }
}

/// A directory listing: directories first, then by name.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DirListing {
    /// The directory, absolute.
    pub path: String,
    pub entries: Vec<FileStat>,
    /// More than 10 000 entries; the rest were left out.
    pub truncated: bool,
}

impl From<proto::DirListing> for DirListing {
    fn from(dir_listing: proto::DirListing) -> Self {
        Self {
            path: dir_listing.path,
            entries: dir_listing.entries.into_iter().map(Into::into).collect(),
            truncated: dir_listing.truncated,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileChunk {
    pub stat: FileStat,
    /// Offset of `data`.
    pub offset: u64,
    pub data: Bytes,
    /// Reaches the end of the file.
    pub eof: bool,
}

impl From<proto::FileChunk> for FileChunk {
    fn from(file_chunk: proto::FileChunk) -> Self {
        Self {
            stat: file_chunk.stat.into(),
            offset: file_chunk.offset,
            data: file_chunk.data.into(),
            eof: file_chunk.eof,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DeleteMode {
    /// Into the user's trash.
    Trash,
    /// For good.
    Permanent,
}

impl From<DeleteMode> for proto::DeleteMode {
    fn from(delete_mode: DeleteMode) -> Self {
        match delete_mode {
            DeleteMode::Trash => Self::Trash,
            DeleteMode::Permanent => Self::Permanent,
        }
    }
}

/// Where a write or upload goes (written to a temporary file, then renamed over the target).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WriteTarget {
    pub path: String,
    /// Only replace the file if it still has this [`FileStat::version`].
    #[uniffi(default = None)]
    pub if_match: Option<String>,
    /// Fail if the file exists.
    #[uniffi(default = false)]
    pub create_new: bool,
    #[uniffi(default = false)]
    pub mkdirs: bool,
    /// Permission bits for a new file.
    #[uniffi(default = None)]
    pub mode: Option<u32>,
}

impl From<WriteTarget> for proto::WriteTarget {
    fn from(write_target: WriteTarget) -> Self {
        Self {
            path: write_target.path,
            if_match: write_target.if_match,
            create_new: write_target.create_new,
            mkdirs: write_target.mkdirs,
            mode: write_target.mode,
        }
    }
}

/// Changes in a watched directory (debounced).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FsChange {
    pub watch_id: u64,
    pub paths: Vec<String>,
    /// Too many to name: list the directory again.
    pub rescan: bool,
}

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
    AgentDone {
        agent: String,
    },
    /// An agent's turn failed.
    AgentFailed {
        agent: String,
    },
    /// A long command finished unseen.
    CommandFinished {
        mark: CommandMark,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AttentionItem {
    pub id: u64,
    pub at_ms: u64,
    pub pane_id: u64,
    pub session_id: Option<u64>,
    pub kind: AttentionKind,
    pub title: String,
    pub body: String,
    /// Seen on some device.
    pub seen: bool,
    /// A client showed the pane when it happened.
    pub while_viewed: bool,
}

impl From<proto::AttentionItem> for AttentionItem {
    fn from(attention_item: proto::AttentionItem) -> Self {
        Self {
            id: attention_item.id,
            at_ms: attention_item.at.0,
            pane_id: attention_item.pane_id.0,
            session_id: attention_item.session_id.map(|s| s.0),
            kind: match attention_item.kind {
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
            title: attention_item.title,
            body: attention_item.body,
            seen: attention_item.seen,
            while_viewed: attention_item.while_viewed,
        }
    }
}

/// The feed and this host's badge count.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AttentionList {
    /// The last 500 items, oldest first.
    pub items: Vec<AttentionItem>,
    pub unseen: u32,
}

impl From<proto::AttentionList> for AttentionList {
    fn from(attention_list: proto::AttentionList) -> Self {
        Self {
            items: attention_list.items.into_iter().map(Into::into).collect(),
            unseen: attention_list.unseen,
        }
    }
}

/// Which items to mark seen (all conditions add up).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AttentionSeen {
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
    fn from(attention_seen: AttentionSeen) -> Self {
        Self {
            ids: attention_seen.ids,
            up_to: attention_seen.up_to,
            pane_id: attention_seen.pane_id.map(proto::PaneId),
        }
    }
}

/// A change to the attention feed.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AttentionUpdate {
    Added {
        item: AttentionItem,
        /// Unseen items now.
        unseen: u32,
    },
    Seen {
        ids: Vec<u64>,
        /// Unseen items now.
        unseen: u32,
    },
}

impl From<proto::AttentionUpdate> for AttentionUpdate {
    fn from(attention_update: proto::AttentionUpdate) -> Self {
        match attention_update {
            proto::AttentionUpdate::Added { item, unseen } => Self::Added {
                item: item.into(),
                unseen,
            },
            proto::AttentionUpdate::Seen { ids, unseen } => Self::Seen { ids, unseen },
        }
    }
}

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
    fn from(editor_kind: proto::EditorKind) -> Self {
        match editor_kind {
            proto::EditorKind::VsCode => Self::VsCode,
            proto::EditorKind::OpenVsCode => Self::OpenVsCode,
            proto::EditorKind::Vscodium => Self::Vscodium,
        }
    }
}

impl From<EditorKind> for proto::EditorKind {
    fn from(editor_kind: EditorKind) -> Self {
        match editor_kind {
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
    Only {
        kind: EditorKind,
    },
}

impl From<EditorChoice> for proto::EditorChoice {
    fn from(editor_choice: EditorChoice) -> Self {
        match editor_choice {
            EditorChoice::Auto => Self::Auto,
            EditorChoice::Only { kind } => Self::Only(kind.into()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorLaunch {
    pub folder: String,
    pub choice: EditorChoice,
    /// The user accepted the VS Code Server licence in the app.
    pub accept_vscode_license: bool,
}

impl From<EditorLaunch> for proto::EditorLaunch {
    fn from(editor_launch: EditorLaunch) -> Self {
        Self {
            folder: editor_launch.folder,
            choice: editor_launch.choice.into(),
            accept_vscode_license: editor_launch.accept_vscode_license,
        }
    }
}

/// A running editor server on the host's `127.0.0.1:port`. `Debug` leaves the token out.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorInstance {
    pub kind: EditorKind,
    pub folder: String,
    /// Port on the host's loopback.
    pub port: u16,
    pub token: String,
    /// Path and query to load (token and folder included).
    pub url_path: String,
    pub pid: u32,
    pub started_at_ms: u64,
}

impl std::fmt::Debug for EditorInstance {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EditorInstance")
            .field("kind", &self.kind)
            .field("folder", &self.folder)
            .field("port", &self.port)
            .field("pid", &self.pid)
            .field("started_at_ms", &self.started_at_ms)
            .finish_non_exhaustive()
    }
}

impl From<proto::EditorInstance> for EditorInstance {
    fn from(editor_instance: proto::EditorInstance) -> Self {
        Self {
            kind: editor_instance.kind.into(),
            folder: editor_instance.folder,
            port: editor_instance.port,
            token: editor_instance.token,
            url_path: editor_instance.url_path,
            pid: editor_instance.pid,
            started_at_ms: editor_instance.started_at.0,
        }
    }
}

/// Whether an editor can run on the host.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorAvailability {
    pub kind: EditorKind,
    /// Installed (the `code` CLI found; openvscode-server downloaded).
    pub installed: bool,
    pub downloadable: bool,
    pub path: Option<String>,
    pub version: Option<String>,
    /// Why it cannot run, or licence notes.
    pub note: Option<String>,
}

/// What the host offers and runs.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorList {
    /// Each editor and whether it can run.
    pub available: Vec<EditorAvailability>,
    pub running: Vec<EditorInstance>,
}

impl From<proto::EditorList> for EditorList {
    fn from(editor_list: proto::EditorList) -> Self {
        Self {
            available: editor_list
                .available
                .into_iter()
                .map(|availability| EditorAvailability {
                    kind: availability.kind.into(),
                    installed: availability.installed,
                    downloadable: availability.downloadable,
                    path: availability.path,
                    version: availability.version,
                    note: availability.note,
                })
                .collect(),
            running: editor_list.running.into_iter().map(Into::into).collect(),
        }
    }
}

/// How `editor_open` reached the editor.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditorOpened {
    pub instance: EditorInstance,
    /// Opened in an already-open window; just show the editor.
    pub in_window: bool,
    /// Otherwise load this path and query.
    pub url_path: String,
}

impl From<proto::EditorOpened> for EditorOpened {
    fn from(editor_opened: proto::EditorOpened) -> Self {
        Self {
            instance: editor_opened.instance.into(),
            in_window: editor_opened.in_window,
            url_path: editor_opened.url_path,
        }
    }
}

/// Which account a tunnel signs in with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TunnelProvider {
    /// GitHub (device code at `github.com/login/device`).
    GitHub,
    Microsoft,
}

impl From<proto::TunnelProvider> for TunnelProvider {
    fn from(tunnel_provider: proto::TunnelProvider) -> Self {
        match tunnel_provider {
            proto::TunnelProvider::GitHub => Self::GitHub,
            proto::TunnelProvider::Microsoft => Self::Microsoft,
        }
    }
}

impl From<TunnelProvider> for proto::TunnelProvider {
    fn from(tunnel_provider: TunnelProvider) -> Self {
        match tunnel_provider {
            TunnelProvider::GitHub => Self::GitHub,
            TunnelProvider::Microsoft => Self::Microsoft,
        }
    }
}

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
    pub path: String,
    pub version: Option<String>,
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
    pub provider: TunnelProvider,
    /// Where to enter the code.
    pub verification_url: String,
    pub user_code: String,
    pub at_ms: u64,
}

/// What the tunnel is doing.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TunnelState {
    Stopped,
    Starting,
    /// Show the URL and code.
    NeedsLogin {
        login: DeviceLogin,
    },
    Running {
        name: String,
        /// `https://vscode.dev/tunnel/<name>…`.
        web_url: String,
        /// Not started by the daemon.
        adopted: bool,
    },
    Failed {
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
    pub state: TunnelState,
    /// The account kind last used.
    pub provider: Option<TunnelProvider>,
}

impl From<proto::VsCodeTunnelStatus> for VsCodeTunnelStatus {
    fn from(status: proto::VsCodeTunnelStatus) -> Self {
        Self {
            cli: status.cli.map(|cli| VsCodeCli {
                path: cli.path,
                version: cli.version,
                commit: cli.commit,
                sha256: cli.sha256,
                managed: cli.managed,
            }),
            cli_downloadable: status.cli_downloadable,
            state: match status.state {
                proto::TunnelState::Stopped => TunnelState::Stopped,
                proto::TunnelState::Starting => TunnelState::Starting,
                proto::TunnelState::NeedsLogin(login) => TunnelState::NeedsLogin {
                    login: DeviceLogin {
                        provider: login.provider.into(),
                        verification_url: login.verification_url,
                        user_code: login.user_code,
                        at_ms: login.at.0,
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
            provider: status.provider.map(Into::into),
        }
    }
}

/// Where a folder or file opens through the tunnel.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VsCodeTunnelOpened {
    pub name: String,
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
    fn from(opened: proto::VsCodeTunnelOpened) -> Self {
        Self {
            name: opened.name,
            folder: opened.folder,
            web_url: opened.web_url,
            desktop_uri: opened.desktop_uri,
            in_window: opened.in_window,
        }
    }
}

/// Which attention items a device wants pushed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PushPrefs {
    /// Approval requests (Approve / Deny actions).
    #[uniffi(default = true)]
    pub approvals: bool,
    /// An agent waits in the terminal.
    #[uniffi(default = true)]
    pub blocked: bool,
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
    fn from(push_prefs: PushPrefs) -> Self {
        Self {
            approvals: push_prefs.approvals,
            blocked: push_prefs.blocked,
            done: push_prefs.done,
            failed: push_prefs.failed,
            commands: push_prefs.commands,
        }
    }
}

impl From<proto::PushPrefs> for PushPrefs {
    fn from(push_prefs: proto::PushPrefs) -> Self {
        Self {
            approvals: push_prefs.approvals,
            blocked: push_prefs.blocked,
            done: push_prefs.done,
            failed: push_prefs.failed,
            commands: push_prefs.commands,
        }
    }
}

/// A device's push registration with one daemon. `Debug` leaves the capabilities out.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushRegistration {
    /// The capability the push relay issued (`POST /v1/register`; see
    /// `push_relay_register_body`).
    pub cap: String,
    /// The device's X25519 public key (32 bytes, `generate_push_seal_key`).
    pub seal_key: Bytes,
    /// The relay that issued `cap`; the daemon's default when `nil`.
    #[uniffi(default = None)]
    pub relay_url: Option<String>,
    pub prefs: PushPrefs,
    /// A push-to-start capability for the agents Live Activity.
    #[uniffi(default = None)]
    pub activity_cap: Option<String>,
}

impl std::fmt::Debug for PushRegistration {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PushRegistration")
            .field("seal_key", &self.seal_key)
            .field("relay_url", &self.relay_url)
            .field("prefs", &self.prefs)
            .finish_non_exhaustive()
    }
}

/// Push settings on the daemon and this device's registration.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PushStatus {
    pub enabled: bool,
    /// The daemon's default relay.
    pub relay_url: String,
    /// This device's preferences, if registered.
    pub registered: Option<PushPrefs>,
    pub devices: u32,
    /// The last delivery failure for this device.
    pub last_error: Option<String>,
}

impl From<proto::PushStatus> for PushStatus {
    fn from(push_status: proto::PushStatus) -> Self {
        Self {
            enabled: push_status.enabled,
            relay_url: push_status.relay_url,
            registered: push_status.registered.map(Into::into),
            devices: push_status.devices,
            last_error: push_status.last_error,
        }
    }
}

/// A workspace push from the daemon.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum WorkspaceEvent {
    /// The detected ports (the whole list).
    PortsChanged {
        ports: Vec<PortInfo>,
    },
    FsChanged {
        change: FsChange,
    },
    Attention {
        update: AttentionUpdate,
    },
    /// The VS Code tunnel changed state (a device code to show, running, failed).
    VsCodeTunnel {
        status: VsCodeTunnelStatus,
    },
    /// Agent plan usage changed (while watching, `DaemonClient::usage_watch`).
    AgentUsage {
        report: crate::usage::AgentUsageReport,
    },
    /// The repositories, worktrees, branches and pull requests of the panes (whole).
    Repos {
        snapshot: crate::repo::RepoSnapshot,
    },
    /// A workflow file the daemon listed changed: list again (`DaemonClient::workflow_list`).
    WorkflowsChanged {
        rev: u64,
    },
    /// The host's agent accounts or the panes' accounts changed (owner devices).
    Accounts {
        report: crate::accounts::AccountsReport,
    },
    /// Usage per account changed (owner devices, while watching usage).
    AccountUsage {
        report: crate::accounts::AccountUsageReport,
    },
}

impl From<client_core::WorkspaceEvent> for WorkspaceEvent {
    fn from(workspace_event: client_core::WorkspaceEvent) -> Self {
        use client_core::WorkspaceEvent as E;
        match workspace_event {
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
            E::AgentUsage { report } => Self::AgentUsage {
                report: report.into(),
            },
            E::Accounts { report } => Self::Accounts {
                report: report.into(),
            },
            E::AccountUsage { report } => Self::AccountUsage {
                report: report.into(),
            },
            E::Repos { snapshot } => Self::Repos {
                snapshot: snapshot.into(),
            },
            E::WorkflowsChanged { rev } => Self::WorkflowsChanged { rev },
        }
    }
}
