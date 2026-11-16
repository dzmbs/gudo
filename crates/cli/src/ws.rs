//! Developer-workflow subcommands: ports, editor, git, agent turns, review notes, worktrees,
//! files and the attention feed.

use std::time::Duration;

use anyhow::{Context, Result};
use clap::{Subcommand, ValueEnum};
use client_core::proto::{
    AgentKind, AttentionKind, AttentionSeen, Axis, DeleteMode, DiffBase, EditorChoice, EditorKind,
    EditorLaunch, FileChange, FileKind, FileStat, GitDiff, GitDiffRequest, GitStatus, LineKind,
    PaneId, ReviewNote, ReviewRequest, WorktreeCreate, WriteTarget,
};
use client_core::{WorkspaceEvent, WorkspaceEventQueue};

use crate::Conn;

#[derive(Subcommand)]
pub(crate) enum WsCmd {
    /// Listening ports in panes (with `--watch`, keep printing changes).
    Ports {
        #[arg(long)]
        watch: bool,
    },
    /// The editor server (VS Code serve-web; VSCodium or openvscode-server).
    Editor {
        #[command(subcommand)]
        action: EditorCmd,
    },
    /// Git status and diffs.
    Git {
        #[command(subcommand)]
        action: GitCmd,
    },
    /// Agent turns recorded in a pane, or what one changed (`--turn`, `--diff`).
    Turns {
        #[arg(long)]
        pane: Option<u64>,
        /// Show the diff of this turn (`0`: the latest).
        #[arg(long)]
        diff: Option<u64>,
        /// Only file names and counts.
        #[arg(long)]
        stat: bool,
    },
    /// Send review notes to an agent pane: `--note 'path:START[-END]:text'` (repeatable).
    Review {
        #[arg(long)]
        pane: u64,
        #[arg(long = "note", required = true)]
        notes: Vec<String>,
        /// Press Enter after typing the prompt.
        #[arg(long)]
        submit: bool,
    },
    /// Worktrees.
    Worktree {
        #[command(subcommand)]
        action: WorktreeCmd,
    },
    /// Files on the host.
    Fs {
        #[command(subcommand)]
        action: FsCmd,
    },
    /// The attention feed (agents blocked/done, long commands); `--seen` marks all seen.
    Inbox {
        #[arg(long)]
        seen: bool,
        /// Keep printing new items.
        #[arg(long)]
        watch: bool,
    },
}

#[derive(Subcommand)]
pub(crate) enum EditorCmd {
    /// What can run and what runs.
    Status,
    /// Start (or reuse) the editor for a folder and forward its port here.
    Launch {
        folder: Option<String>,
        #[arg(long, value_enum)]
        kind: Option<Editor>,
        /// Accept the Microsoft VS Code Server licence (https://aka.ms/vscode-server-license).
        #[arg(long)]
        accept_license: bool,
        /// Local port for the forward.
        #[arg(long, default_value_t = 0)]
        local: u16,
    },
    /// Stop the editor serving a folder.
    Stop { folder: String },
    /// Open `path[:line[:col]]` in the running editor.
    Open { target: String },
    /// Real VS Code through Microsoft's Remote Tunnels (vscode.dev or desktop).
    Tunnel {
        #[command(subcommand)]
        action: TunnelCmd,
    },
}

#[derive(Subcommand)]
pub(crate) enum TunnelCmd {
    /// The CLI and the tunnel.
    Status,
    /// Download Microsoft's `code` CLI onto the host (https://code.visualstudio.com/license).
    Install {
        #[arg(long)]
        accept_license: bool,
    },
    /// Start the tunnel and follow it until it is connected (shows the sign-in code).
    Start {
        /// Accept the VS Code Server licence (https://aka.ms/vscode-server-license) and the
        /// Microsoft Privacy Statement.
        #[arg(long)]
        accept_license: bool,
        /// Sign in with a Microsoft account instead of GitHub.
        #[arg(long)]
        microsoft: bool,
        /// Machine name on vscode.dev.
        #[arg(long)]
        name: Option<String>,
    },
    /// Stop the tunnel.
    Stop,
    /// Print the vscode.dev URL and desktop link for `path[:line[:col]]`.
    Open { target: String },
}

fn print_tunnel(status: &client_core::proto::VsCodeTunnelStatus) {
    use client_core::proto::TunnelState;
    match &status.cli {
        Some(cli) => println!(
            "cli: {} {} {}{}",
            cli.path,
            cli.version.as_deref().unwrap_or("?"),
            cli.commit.as_deref().unwrap_or(""),
            if cli.managed {
                " (installed by the daemon)"
            } else {
                ""
            }
        ),
        None => println!(
            "cli: not installed (downloadable: {})",
            status.cli_downloadable
        ),
    }
    match &status.state {
        TunnelState::NeedsLogin(login) => println!(
            "sign in ({:?}): open {} and enter {}",
            login.provider, login.verification_url, login.user_code
        ),
        TunnelState::Running {
            name,
            web_url,
            adopted,
        } => println!(
            "running: {name} {web_url}{}",
            if *adopted { " (adopted)" } else { "" }
        ),
        other => println!("tunnel: {other:?}"),
    }
}

#[derive(Clone, Copy, ValueEnum)]
pub(crate) enum Editor {
    Vscode,
    Openvscode,
    /// VSCodium's Web Host (MIT, Open VSX): no licence prompt.
    Vscodium,
}

#[derive(Subcommand)]
pub(crate) enum GitCmd {
    /// Branch, ahead/behind, changed files (default: the focused pane's directory).
    Status { path: Option<String> },
    /// Diff vs HEAD (default), the index, staged, a revision or a merge base.
    Diff {
        #[arg(long)]
        path: Option<String>,
        #[arg(long)]
        staged: bool,
        #[arg(long, conflicts_with = "staged")]
        index: bool,
        #[arg(long)]
        rev: Option<String>,
        #[arg(long)]
        merge_base: Option<String>,
        #[arg(long)]
        stat: bool,
        #[arg(short = 'U', default_value_t = 3)]
        context: u32,
        files: Vec<String>,
    },
}

#[derive(Subcommand)]
pub(crate) enum WorktreeCmd {
    /// New worktree on a new branch (default repo: the focused pane's directory).
    Create {
        #[arg(long)]
        repo: Option<String>,
        #[arg(long)]
        branch: Option<String>,
        #[arg(long)]
        base: Option<String>,
    },
    /// List worktrees.
    List { repo: Option<String> },
    /// Remove a worktree (refused when dirty unless --force).
    Remove {
        path: String,
        #[arg(long)]
        force: bool,
        #[arg(long)]
        delete_branch: bool,
    },
    /// Split the focused pane into a shell or agent in the worktree.
    Launch {
        path: String,
        #[arg(long, value_enum)]
        agent: Option<crate::Agent>,
        #[arg(short, long)]
        vertical: bool,
    },
}

#[derive(Subcommand)]
pub(crate) enum FsCmd {
    /// List a directory.
    Ls {
        path: String,
        #[arg(short = 'a')]
        all: bool,
    },
    /// Metadata.
    Stat { path: String },
    /// Print (part of) a file.
    Cat {
        path: String,
        #[arg(long, default_value_t = 0)]
        offset: u64,
        #[arg(long, default_value_t = 1 << 20)]
        len: u32,
    },
    /// Upload a local file.
    Put {
        local: String,
        remote: String,
        /// Only replace this version.
        #[arg(long)]
        if_match: Option<String>,
        /// Fail if it exists.
        #[arg(long)]
        new: bool,
    },
    /// Download a file.
    Get { remote: String, local: String },
    /// Create a directory.
    Mkdir {
        path: String,
        #[arg(short)]
        parents: bool,
    },
    /// Rename or move.
    Mv {
        from: String,
        to: String,
        #[arg(long)]
        force: bool,
    },
    /// Move to the trash (or delete for good with --permanent).
    Rm {
        path: String,
        #[arg(long)]
        permanent: bool,
        #[arg(short)]
        recursive: bool,
    },
    /// Print changes in a directory until Ctrl-C.
    Watch { path: String },
}

impl Conn {
    /// The focused pane's working directory (from its metadata), else `~`.
    async fn focused_cwd(&mut self) -> String {
        let Ok(pane) = self.tab().map(|tab| tab.focused) else {
            return "~".into();
        };
        let _ = tokio::time::timeout(Duration::from_secs(2), async {
            while !self.cwds.contains_key(&pane) {
                if self.next().await.is_err() {
                    break;
                }
            }
        })
        .await;
        self.cwds.get(&pane).cloned().unwrap_or_else(|| "~".into())
    }
}

/// Where a diff whose lines were left out can be read in full.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FullDiff {
    /// Asking for the files one at a time.
    OneFileAtATime,
    /// Only with git on the host.
    OnTheHost,
}

fn print_diff(diff: &GitDiff, stat: bool, full_diff: FullDiff) {
    for file in &diff.files {
        let name = match &file.old_path {
            Some(old) => format!("{old} → {}", file.path),
            None => file.path.clone(),
        };
        let counts = if file.binary {
            "binary".to_owned()
        } else {
            format!("+{} -{}", file.additions, file.deletions)
        };
        println!("{:?} {name} ({counts})", file.change);
        if stat {
            continue;
        }
        if file.hunks_omitted {
            println!("  (lines left out: too large to show)");
        }
        for hunk in &file.hunks {
            println!(
                "@@ -{},{} +{},{} @@ {}",
                hunk.old_start, hunk.old_lines, hunk.new_start, hunk.new_lines, hunk.header
            );
            for line in &hunk.lines {
                let mark = match line.kind {
                    LineKind::Context => ' ',
                    LineKind::Added => '+',
                    LineKind::Removed => '-',
                    LineKind::NoNewline => '\\',
                };
                println!("{mark}{}", line.text);
            }
        }
    }
    if !stat && let Some(note) = left_out_note(diff, full_diff) {
        println!("({note})");
    }
}

/// What was left out of a diff and how to read it.
fn left_out_note(diff: &GitDiff, full_diff: FullDiff) -> Option<String> {
    let left_out = diff
        .files
        .iter()
        .filter(|file| file.hunks_omitted && !file.binary)
        .count();
    if left_out == 0 {
        return None;
    }
    if diff.files.len() == 1 {
        return Some(
            "This file's diff is over 1 MiB, so its lines are left out. Run git diff on the \
             host to read it."
                .into(),
        );
    }
    let count = if left_out == 1 {
        "1 file".to_owned()
    } else {
        format!("{left_out} files")
    };
    Some(match full_diff {
        FullDiff::OneFileAtATime => format!(
            "Lines of {count} were left out to keep the diff small. `{} git diff FILE` shows \
             one file; one over 1 MiB needs git diff on the host.",
            brand::CLI_BIN
        ),
        FullDiff::OnTheHost => format!(
            "Lines of {count} were left out to keep the diff small. Run git diff on the host \
             to read them."
        ),
    })
}

/// `git status --short --branch`.
fn status_lines(status: &GitStatus) -> Vec<String> {
    let mut branch = format!(
        "## {}",
        status.branch.as_deref().unwrap_or("HEAD (no branch)")
    );
    if let Some(upstream) = &status.upstream {
        branch.push_str(&format!("...{upstream}"));
        let counts = [("ahead", status.ahead), ("behind", status.behind)]
            .into_iter()
            .filter(|(_, count)| *count > 0)
            .map(|(word, count)| format!("{word} {count}"))
            .collect::<Vec<_>>();
        if !counts.is_empty() {
            branch.push_str(&format!(" [{}]", counts.join(", ")));
        }
    }
    let files = status.files.iter().map(|file| {
        let code = match (file.staged, file.unstaged) {
            (FileChange::Untracked, _) | (_, FileChange::Untracked) => "??".to_owned(),
            (staged, unstaged) => format!("{}{}", change_code(staged), change_code(unstaged)),
        };
        match &file.orig_path {
            Some(orig_path) => format!("{code} {orig_path} -> {}", file.path),
            None => format!("{code} {}", file.path),
        }
    });
    std::iter::once(branch).chain(files).collect()
}

fn change_code(change: FileChange) -> char {
    match change {
        FileChange::Unmodified => ' ',
        FileChange::Modified => 'M',
        FileChange::Added => 'A',
        FileChange::Deleted => 'D',
        FileChange::Renamed => 'R',
        FileChange::Copied => 'C',
        FileChange::TypeChanged => 'T',
        FileChange::Unmerged => 'U',
        FileChange::Untracked => '?',
    }
}

/// `fs stat` for people: one labelled line each.
fn stat_lines(stat: &FileStat) -> Vec<String> {
    let kind = match (stat.kind, &stat.link_target) {
        (FileKind::Symlink, Some(target)) => {
            let target_kind = stat.target_kind.map_or("missing", kind_name);
            format!("symbolic link to {target} ({target_kind})")
        }
        (kind, _) => kind_name(kind).to_owned(),
    };
    let size = match stat.size {
        1 => "1 byte".to_owned(),
        size => format!("{size} bytes"),
    };
    vec![
        format!("Path:     {}", stat.path),
        format!("Kind:     {kind}"),
        format!("Size:     {size}"),
        format!(
            "Mode:     {:03o} ({})",
            stat.mode & 0o7777,
            permissions(stat.mode)
        ),
        format!("Modified: {}", utc_time(stat.modified.0)),
        format!("Version:  {}", stat.version),
    ]
}

fn kind_name(kind: FileKind) -> &'static str {
    match kind {
        FileKind::File => "file",
        FileKind::Dir => "directory",
        FileKind::Symlink => "symbolic link",
        FileKind::Other => "special file",
    }
}

/// `rwxr-xr-x`.
fn permissions(mode: u32) -> String {
    (0..9)
        .map(|bit| {
            if mode & (0o400 >> bit) == 0 {
                '-'
            } else {
                ['r', 'w', 'x'][bit % 3]
            }
        })
        .collect()
}

/// `2026-11-16 10:40:17 UTC`.
fn utc_time(unix_ms: u64) -> String {
    let seconds = unix_ms / 1000;
    let (days, time_of_day) = (seconds / 86_400, seconds % 86_400);
    // Days to a civil date in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
    let shifted = days + 719_468;
    let era = shifted / 146_097;
    let day_of_era = shifted % 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + u64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02} UTC",
        time_of_day / 3600,
        time_of_day / 60 % 60,
        time_of_day % 60
    )
}

/// `path[:line[:col]]`.
fn split_target(target: &str) -> (String, Option<u32>, Option<u32>) {
    let mut parts = target.rsplitn(3, ':').collect::<Vec<_>>();
    parts.reverse();
    let numbers: Vec<Option<u32>> = parts.iter().map(|part| part.parse().ok()).collect();
    match (parts.len(), numbers.as_slice()) {
        (3, [_, Some(line), Some(col)]) => (parts[0].to_owned(), Some(*line), Some(*col)),
        (3, [_, _, Some(line)]) => (format!("{}:{}", parts[0], parts[1]), Some(*line), None),
        (2, [_, Some(line)]) => (parts[0].to_owned(), Some(*line), None),
        _ => (target.to_owned(), None, None),
    }
}

/// `path:START[-END]:text`.
fn parse_note(spec: &str) -> Result<ReviewNote> {
    let (path, rest) = spec.split_once(':').context("note needs path:LINE:text")?;
    let (lines, note) = rest.split_once(':').context("note needs path:LINE:text")?;
    let (start, end) = match lines.split_once('-') {
        Some((start, end)) => (start.parse()?, end.parse()?),
        None => {
            let line = lines.parse()?;
            (line, line)
        }
    };
    Ok(ReviewNote {
        path: path.to_owned(),
        start_line: start,
        end_line: end,
        old_side: false,
        quote: None,
        note: note.to_owned(),
    })
}

pub(crate) async fn run(conn: &mut Conn, command: WsCmd) -> Result<()> {
    let client = &conn.client;
    match command {
        WsCmd::Ports { watch } => {
            let (listener, mut events) = WorkspaceEventQueue::channel();
            client.set_workspace_listener(listener);
            let ports = client.list_ports().await?;
            print_ports(&ports, conn.json);
            while watch && let Some(event) = events.recv().await {
                if let WorkspaceEvent::PortsChanged { ports } = event {
                    if !conn.json {
                        println!("--");
                    }
                    print_ports(&ports, conn.json);
                }
            }
        }
        WsCmd::Editor { action } => match action {
            EditorCmd::Status => {
                let list = client.editor_status().await?;
                for available in &list.available {
                    println!(
                        "{:?}: installed {} downloadable {} {} {}",
                        available.kind,
                        available.installed,
                        available.downloadable,
                        available.path.as_deref().unwrap_or(""),
                        available.note.as_deref().unwrap_or("")
                    );
                }
                for running in &list.running {
                    println!(
                        "running {:?} :{} {} (pid {})",
                        running.kind, running.port, running.folder, running.pid
                    );
                }
            }
            EditorCmd::Launch {
                folder,
                kind,
                accept_license,
                local,
            } => {
                let folder = match folder {
                    Some(folder) => folder,
                    None => conn.focused_cwd().await,
                };
                let client = &conn.client;
                let choice = match kind {
                    None => EditorChoice::Auto,
                    Some(Editor::Vscode) => EditorChoice::Only(EditorKind::VsCode),
                    Some(Editor::Openvscode) => EditorChoice::Only(EditorKind::OpenVsCode),
                    Some(Editor::Vscodium) => EditorChoice::Only(EditorKind::Vscodium),
                };
                let editor = client
                    .editor_launch(EditorLaunch {
                        folder,
                        choice,
                        accept_vscode_license: accept_license,
                    })
                    .await?;
                let port = client.forward(
                    local,
                    client_core::proto::ForwardTarget::Tcp { port: editor.port },
                )?;
                println!(
                    "{:?} serving {} on the host's :{}",
                    editor.kind, editor.folder, editor.port
                );
                println!(
                    "open http://localhost:{port}{} (Ctrl-C to stop forwarding)",
                    editor.url_path
                );
                tokio::signal::ctrl_c().await?;
            }
            EditorCmd::Stop { folder } => client.editor_stop(folder).await?,
            EditorCmd::Tunnel { action } => match action {
                TunnelCmd::Status => print_tunnel(&client.vscode_tunnel_status().await?),
                TunnelCmd::Install { accept_license } => {
                    print_tunnel(&client.vscode_cli_install(accept_license).await?);
                }
                TunnelCmd::Start {
                    accept_license,
                    microsoft,
                    name,
                } => {
                    use client_core::proto::{TunnelProvider, TunnelState, VsCodeTunnelStart};
                    let (listener, mut events) = WorkspaceEventQueue::channel();
                    client.set_workspace_listener(listener);
                    let provider = if microsoft {
                        TunnelProvider::Microsoft
                    } else {
                        TunnelProvider::GitHub
                    };
                    let mut status = client
                        .vscode_tunnel_start(VsCodeTunnelStart {
                            accept_server_license: accept_license,
                            provider,
                            name,
                        })
                        .await?;
                    loop {
                        print_tunnel(&status);
                        if matches!(
                            status.state,
                            TunnelState::Running { .. }
                                | TunnelState::Stopped
                                | TunnelState::Failed {
                                    retrying: false,
                                    ..
                                }
                        ) {
                            break;
                        }
                        match events.recv().await {
                            Some(WorkspaceEvent::VsCodeTunnel { status: update }) => {
                                status = update
                            }
                            Some(_) => continue,
                            None => break,
                        }
                    }
                }
                TunnelCmd::Stop => print_tunnel(&client.vscode_tunnel_stop().await?),
                TunnelCmd::Open { target } => {
                    let (path, line, column) = split_target(&target);
                    let opened = client
                        .vscode_tunnel_open(client_core::proto::VsCodeTunnelOpen {
                            folder: None,
                            path,
                            line,
                            column,
                        })
                        .await?;
                    println!("web:     {}", opened.web_url);
                    println!("desktop: {}", opened.desktop_uri);
                    if opened.in_window {
                        println!("opened in the connected window");
                    }
                }
            },
            EditorCmd::Open { target } => {
                let (path, line, col) = split_target(&target);
                let opened = client.editor_open(None, path, line, col).await?;
                if opened.in_window {
                    println!("opened in the editor window");
                } else {
                    println!(
                        "load http://localhost:{}{}",
                        opened.instance.port, opened.url_path
                    );
                }
            }
        },
        WsCmd::Git { action } => match action {
            GitCmd::Status { path } => {
                let path = match path {
                    Some(path) => path,
                    None => conn.focused_cwd().await,
                };
                let status = conn.client.git_status(path).await?;
                if conn.json {
                    return crate::json::print("git.status", &crate::json::Git::from(&status));
                }
                for line in status_lines(&status) {
                    println!("{line}");
                }
            }
            GitCmd::Diff {
                path,
                staged,
                index,
                rev,
                merge_base,
                stat,
                context,
                files,
            } => {
                let path = match path {
                    Some(path) => path,
                    None => conn.focused_cwd().await,
                };
                let base = if staged {
                    DiffBase::Staged
                } else if index {
                    DiffBase::Index
                } else if let Some(rev) = rev {
                    DiffBase::Rev(rev)
                } else if let Some(merge_base) = merge_base {
                    DiffBase::MergeBase(merge_base)
                } else {
                    DiffBase::Head
                };
                let diff = conn
                    .client
                    .git_diff(GitDiffRequest {
                        path,
                        base,
                        files,
                        context,
                        hunks: !stat,
                    })
                    .await?;
                print_diff(&diff, stat, FullDiff::OneFileAtATime);
            }
        },
        WsCmd::Turns { pane, diff, stat } => {
            let pane_id = pane.map_or(conn.tab()?.focused, PaneId);
            match diff {
                Some(turn) => {
                    let turn = (turn != 0).then_some(turn);
                    let turn_diff = client.turn_diff(pane_id, turn, 3, !stat).await?;
                    print_diff(&turn_diff, stat, FullDiff::OnTheHost);
                }
                None => {
                    for turn in client.list_turns(pane_id).await? {
                        let state = if turn.end_tree.is_some() {
                            "done"
                        } else {
                            "running"
                        };
                        println!(
                            "turn {} {state} in {} ({}..{:?})",
                            turn.turn, turn.root, turn.started_at, turn.ended_at
                        );
                    }
                }
            }
        }
        WsCmd::Review {
            pane,
            notes,
            submit,
        } => {
            let notes = notes
                .iter()
                .map(|note| parse_note(note))
                .collect::<Result<Vec<_>>>()?;
            let prompt = client
                .send_review(ReviewRequest {
                    pane_id: PaneId(pane),
                    preamble: None,
                    notes,
                    submit,
                })
                .await?;
            println!("sent:\n{prompt}");
        }
        WsCmd::Worktree { action } => match action {
            WorktreeCmd::Create { repo, branch, base } => {
                let repo = match repo {
                    Some(repo) => repo,
                    None => conn.focused_cwd().await,
                };
                let worktree = conn
                    .client
                    .worktree_create(WorktreeCreate {
                        repo,
                        branch,
                        base,
                        path: None,
                    })
                    .await?;
                println!(
                    "{} on {} (PORT={})",
                    worktree.path,
                    worktree.branch.as_deref().unwrap_or("?"),
                    worktree.port.map_or("-".into(), |port| port.to_string())
                );
            }
            WorktreeCmd::List { repo } => {
                let repo = match repo {
                    Some(repo) => repo,
                    None => conn.focused_cwd().await,
                };
                for worktree in conn.client.worktree_list(repo).await? {
                    println!(
                        "{}{} {} PORT={}",
                        if worktree.main { "* " } else { "  " },
                        worktree.path,
                        worktree.branch.as_deref().unwrap_or("(detached)"),
                        worktree.port.map_or("-".into(), |port| port.to_string())
                    );
                }
            }
            WorktreeCmd::Remove {
                path,
                force,
                delete_branch,
            } => client.worktree_remove(path, force, delete_branch).await?,
            WorktreeCmd::Launch {
                path,
                agent,
                vertical,
            } => {
                let pane = conn.tab()?.focused;
                let agent = agent.map(|agent| match agent {
                    crate::Agent::Claude => AgentKind::Claude,
                    crate::Agent::Codex => AgentKind::Codex,
                });
                let axis = if vertical {
                    Axis::Vertical
                } else {
                    Axis::Horizontal
                };
                let new_pane = conn.client.worktree_launch(path, pane, axis, agent).await?;
                println!("pane {new_pane}");
            }
        },
        WsCmd::Fs { action } => fs(conn, action).await?,
        WsCmd::Inbox { seen, watch } => {
            let (listener, mut events) = WorkspaceEventQueue::channel();
            client.set_workspace_listener(listener);
            let list = if seen {
                client
                    .attention_seen(AttentionSeen {
                        ids: vec![],
                        up_to: Some(u64::MAX),
                        pane_id: None,
                    })
                    .await?
            } else {
                client.attention_list().await?
            };
            if conn.json {
                let items = list.items.iter().map(crate::json::Item::from).collect();
                let unseen = list.unseen;
                crate::json::print("inbox", &crate::json::Inbox { items, unseen })?;
            } else {
                for item in &list.items {
                    print_item(item);
                }
                println!("{} unseen", list.unseen);
            }
            while watch && let Some(event) = events.recv().await {
                if let WorkspaceEvent::Attention { update } = event {
                    println!("{update:?}");
                }
            }
        }
    }
    Ok(())
}

fn print_ports(ports: &[client_core::proto::PortInfo], json: bool) {
    if json {
        let ports = ports.iter().map(crate::json::Port::from).collect();
        if let Err(error) = crate::json::print("ports", &crate::json::Ports { ports }) {
            eprintln!("{error}");
        }
        return;
    }
    if ports.is_empty() {
        println!("no listening ports in panes");
    }
    for port in ports {
        println!(
            ":{:<6} {:<8?} pane {:<4} {} (pid {}){}{}",
            port.port,
            port.kind,
            port.pane_id.map_or("-".into(), |pane| pane.to_string()),
            port.process,
            port.pid,
            if port.loopback_only { " loopback" } else { "" },
            port.url
                .as_ref()
                .map(|url| format!(" {url}"))
                .unwrap_or_default()
        );
    }
}

fn print_item(item: &client_core::proto::AttentionItem) {
    let kind = match &item.kind {
        AttentionKind::AgentBlocked { .. } => "blocked",
        AttentionKind::AgentDone { .. } => "done",
        AttentionKind::AgentFailed { .. } => "failed",
        AttentionKind::CommandFinished(_) => "command",
    };
    println!(
        "{:>4} {} {:<8} pane {} {} — {}",
        item.id,
        if item.seen { " " } else { "•" },
        kind,
        item.pane_id,
        item.title,
        item.body
    );
}

async fn fs(conn: &mut Conn, action: FsCmd) -> Result<()> {
    let client = &conn.client;
    match action {
        FsCmd::Ls { path, all } => {
            let dir = client.fs_list(path, all).await?;
            for entry in &dir.entries {
                let kind = match entry.kind {
                    FileKind::Dir => "d",
                    FileKind::Symlink => "l",
                    FileKind::File => "-",
                    FileKind::Other => "?",
                };
                let link = entry
                    .link_target
                    .as_ref()
                    .map(|target| format!(" -> {target}"))
                    .unwrap_or_default();
                println!(
                    "{kind} {:o} {:>10} {}{link}",
                    entry.mode, entry.size, entry.name
                );
            }
            if dir.truncated {
                println!("(truncated)");
            }
        }
        FsCmd::Stat { path } => {
            for line in stat_lines(&client.fs_stat(path).await?) {
                println!("{line}");
            }
        }
        FsCmd::Cat { path, offset, len } => {
            use std::io::Write;
            let chunk = client.fs_read(path, offset, len).await?;
            std::io::stdout().write_all(&chunk.data)?;
        }
        FsCmd::Put {
            local,
            remote,
            if_match,
            new,
        } => {
            let start = std::time::Instant::now();
            let stat = client
                .upload_file(
                    local,
                    WriteTarget {
                        path: remote,
                        if_match,
                        create_new: new,
                        mkdirs: true,
                        mode: None,
                    },
                    None,
                )
                .await?;
            let secs = start.elapsed().as_secs_f64();
            println!(
                "{} bytes in {secs:.2}s ({:.1} MB/s), version {}",
                stat.size,
                stat.size as f64 / secs / 1e6,
                stat.version
            );
        }
        FsCmd::Get { remote, local } => {
            let start = std::time::Instant::now();
            let stat = client.download_file(remote, local, 0, None, None).await?;
            let secs = start.elapsed().as_secs_f64();
            println!(
                "{} bytes in {secs:.2}s ({:.1} MB/s)",
                stat.size,
                stat.size as f64 / secs / 1e6
            );
        }
        FsCmd::Mkdir { path, parents } => {
            client.fs_mkdir(path, parents).await?;
        }
        FsCmd::Mv { from, to, force } => {
            client.fs_rename(from, to, force).await?;
        }
        FsCmd::Rm {
            path,
            permanent,
            recursive,
        } => {
            let mode = if permanent {
                DeleteMode::Permanent
            } else {
                DeleteMode::Trash
            };
            client.fs_delete(path, mode, recursive).await?;
        }
        FsCmd::Watch { path } => {
            let (listener, mut events) = WorkspaceEventQueue::channel();
            client.set_workspace_listener(listener);
            let id = client.fs_watch(path).await?;
            println!("watching (id {id}); Ctrl-C to stop");
            loop {
                tokio::select! {
                    event = events.recv() => match event {
                        Some(WorkspaceEvent::FsChanged { change }) => {
                            if change.rescan {
                                println!("(many changes)");
                            }
                            for path in change.paths {
                                println!("{path}");
                            }
                        }
                        Some(_) => {}
                        None => break,
                    },
                    _ = tokio::signal::ctrl_c() => break,
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use client_core::proto::{FileDiff, GitFileStatus, UnixMillis};

    use super::*;

    fn file(path: &str, staged: FileChange, unstaged: FileChange) -> GitFileStatus {
        GitFileStatus {
            path: path.into(),
            orig_path: None,
            staged,
            unstaged,
        }
    }

    #[test]
    fn status_reads_like_git_status_short() {
        let mut renamed = file("new.rs", FileChange::Renamed, FileChange::Unmodified);
        renamed.orig_path = Some("old.rs".into());
        let status = GitStatus {
            root: "/repo".into(),
            branch: Some("main".into()),
            head: Some("abc123".into()),
            upstream: Some("origin/main".into()),
            ahead: 2,
            behind: 0,
            files: vec![
                file("a.rs", FileChange::Unmodified, FileChange::Modified),
                file("b.rs", FileChange::Added, FileChange::Modified),
                file("notes.txt", FileChange::Untracked, FileChange::Untracked),
                renamed,
            ],
        };
        assert_eq!(
            status_lines(&status),
            [
                "## main...origin/main [ahead 2]",
                " M a.rs",
                "AM b.rs",
                "?? notes.txt",
                "R  old.rs -> new.rs",
            ]
        );
    }

    fn diff_of(files: &[(&str, bool)]) -> GitDiff {
        GitDiff {
            root: "/repo".into(),
            from: "a".into(),
            to: "b".into(),
            files: files
                .iter()
                .map(|(path, hunks_omitted)| FileDiff {
                    path: (*path).into(),
                    old_path: None,
                    change: FileChange::Modified,
                    binary: false,
                    additions: 1,
                    deletions: 0,
                    hunks: Vec::new(),
                    hunks_omitted: *hunks_omitted,
                })
                .collect(),
            truncated: files.iter().any(|(_, hunks_omitted)| *hunks_omitted),
        }
    }

    #[test]
    fn a_diff_says_what_was_left_out_and_how_to_read_it() {
        let one_large_file =
            left_out_note(&diff_of(&[("big.json", true)]), FullDiff::OneFileAtATime).unwrap();
        assert!(!one_large_file.contains("FILE"), "{one_large_file}");
        assert!(one_large_file.contains("over 1 MiB"));
        assert!(one_large_file.contains("git diff on the host"));

        let many = left_out_note(
            &diff_of(&[("a.rs", false), ("b.rs", true), ("c.rs", true)]),
            FullDiff::OneFileAtATime,
        )
        .unwrap();
        assert!(many.contains("Lines of 2 files"), "{many}");
        assert!(many.contains("git diff FILE"), "{many}");
        let turn = left_out_note(
            &diff_of(&[("a.rs", true), ("b.rs", true)]),
            FullDiff::OnTheHost,
        )
        .unwrap();
        assert!(!turn.contains("FILE"), "{turn}");

        assert_eq!(
            left_out_note(&diff_of(&[("a.rs", false)]), FullDiff::OneFileAtATime),
            None
        );
    }

    #[test]
    fn stat_is_labelled_lines() {
        let stat = FileStat {
            path: "/home/u/link".into(),
            name: "link".into(),
            kind: FileKind::Symlink,
            size: 1234,
            modified: UnixMillis(1_763_289_617_000),
            mode: 0o100_644,
            hidden: false,
            link_target: Some("notes.md".into()),
            target_kind: Some(FileKind::File),
            version: "v1".into(),
        };
        assert_eq!(
            stat_lines(&stat),
            [
                "Path:     /home/u/link",
                "Kind:     symbolic link to notes.md (file)",
                "Size:     1234 bytes",
                "Mode:     644 (rw-r--r--)",
                "Modified: 2025-11-16 10:40:17 UTC",
                "Version:  v1",
            ]
        );
        assert_eq!(utc_time(0), "1970-01-01 00:00:00 UTC");
        assert_eq!(utc_time(951_782_400_000), "2000-02-29 00:00:00 UTC");
    }

    #[test]
    fn parses_targets_and_notes() {
        assert_eq!(split_target("a.rs:3:4"), ("a.rs".into(), Some(3), Some(4)));
        assert_eq!(split_target("a.rs:3"), ("a.rs".into(), Some(3), None));
        assert_eq!(split_target("a.rs"), ("a.rs".into(), None, None));
        let note = parse_note("src/x.rs:3-5:fix this: please").unwrap();
        assert_eq!((note.start_line, note.end_line), (3, 5));
        assert_eq!(note.note, "fix this: please");
        assert!(parse_note("nope").is_err());
    }
}
