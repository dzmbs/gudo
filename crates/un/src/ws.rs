//! Developer-workflow subcommands: ports, editor, git, agent turns, review notes, worktrees,
//! files and the attention feed.

use std::time::Duration;

use anyhow::{Context, Result};
use clap::{Subcommand, ValueEnum};
use client_core::proto::{
    AgentKind, AttentionKind, AttentionSeen, Axis, DeleteMode, DiffBase, EditorChoice, EditorKind,
    EditorLaunch, FileKind, GitDiff, GitDiffRequest, LineKind, PaneId, ReviewNote, ReviewRequest,
    WorktreeCreate, WriteTarget,
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
    /// The editor server (VS Code serve-web or openvscode-server).
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

fn print_tunnel(s: &client_core::proto::VsCodeTunnelStatus) {
    use client_core::proto::TunnelState;
    match &s.cli {
        Some(c) => println!(
            "cli: {} {} {}{}",
            c.path,
            c.version.as_deref().unwrap_or("?"),
            c.commit.as_deref().unwrap_or(""),
            if c.managed {
                " (installed by the daemon)"
            } else {
                ""
            }
        ),
        None => println!("cli: not installed (downloadable: {})", s.cli_downloadable),
    }
    match &s.state {
        TunnelState::NeedsLogin(l) => println!(
            "sign in ({:?}): open {} and enter {}",
            l.provider, l.verification_url, l.user_code
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
        let Ok(pane) = self.tab().map(|t| t.focused) else {
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

fn print_diff(diff: &GitDiff, stat: bool) {
    for f in &diff.files {
        let name = match &f.old_path {
            Some(old) => format!("{old} → {}", f.path),
            None => f.path.clone(),
        };
        let counts = if f.binary {
            "binary".to_owned()
        } else {
            format!("+{} -{}", f.additions, f.deletions)
        };
        println!("{:?} {name} ({counts})", f.change);
        if stat {
            continue;
        }
        if f.hunks_omitted {
            println!("  (hunks omitted: too large)");
        }
        for h in &f.hunks {
            println!(
                "@@ -{},{} +{},{} @@ {}",
                h.old_start, h.old_lines, h.new_start, h.new_lines, h.header
            );
            for l in &h.lines {
                let mark = match l.kind {
                    LineKind::Context => ' ',
                    LineKind::Added => '+',
                    LineKind::Removed => '-',
                    LineKind::NoNewline => '\\',
                };
                println!("{mark}{}", l.text);
            }
        }
    }
    if diff.truncated {
        println!("(some hunks were left out; ask for single files)");
    }
}

/// `path[:line[:col]]`.
fn split_target(target: &str) -> (String, Option<u32>, Option<u32>) {
    let mut parts = target.rsplitn(3, ':').collect::<Vec<_>>();
    parts.reverse();
    let nums: Vec<Option<u32>> = parts.iter().map(|p| p.parse().ok()).collect();
    match (parts.len(), nums.as_slice()) {
        (3, [_, Some(l), Some(c)]) => (parts[0].to_owned(), Some(*l), Some(*c)),
        (3, [_, _, Some(l)]) => (format!("{}:{}", parts[0], parts[1]), Some(*l), None),
        (2, [_, Some(l)]) => (parts[0].to_owned(), Some(*l), None),
        _ => (target.to_owned(), None, None),
    }
}

/// `path:START[-END]:text`.
fn parse_note(spec: &str) -> Result<ReviewNote> {
    let (path, rest) = spec.split_once(':').context("note needs path:LINE:text")?;
    let (lines, note) = rest.split_once(':').context("note needs path:LINE:text")?;
    let (start, end) = match lines.split_once('-') {
        Some((a, b)) => (a.parse()?, b.parse()?),
        None => {
            let l = lines.parse()?;
            (l, l)
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

pub(crate) async fn run(conn: &mut Conn, cmd: WsCmd) -> Result<()> {
    let c = &conn.client;
    match cmd {
        WsCmd::Ports { watch } => {
            let (listener, mut events) = WorkspaceEventQueue::channel();
            c.set_workspace_listener(listener);
            let ports = c.list_ports().await?;
            print_ports(&ports);
            while watch && let Some(event) = events.recv().await {
                if let WorkspaceEvent::PortsChanged { ports } = event {
                    println!("--");
                    print_ports(&ports);
                }
            }
        }
        WsCmd::Editor { action } => match action {
            EditorCmd::Status => {
                let list = c.editor_status().await?;
                for a in &list.available {
                    println!(
                        "{:?}: installed {} downloadable {} {} {}",
                        a.kind,
                        a.installed,
                        a.downloadable,
                        a.path.as_deref().unwrap_or(""),
                        a.note.as_deref().unwrap_or("")
                    );
                }
                for r in &list.running {
                    println!(
                        "running {:?} :{} {} (pid {})",
                        r.kind, r.port, r.folder, r.pid
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
                    Some(f) => f,
                    None => conn.focused_cwd().await,
                };
                let c = &conn.client;
                let choice = match kind {
                    None => EditorChoice::Auto,
                    Some(Editor::Vscode) => EditorChoice::Only(EditorKind::VsCode),
                    Some(Editor::Openvscode) => EditorChoice::Only(EditorKind::OpenVsCode),
                };
                let e = c
                    .editor_launch(EditorLaunch {
                        folder,
                        choice,
                        accept_vscode_license: accept_license,
                    })
                    .await?;
                let port = c.forward(
                    local,
                    client_core::proto::ForwardTarget::Tcp { port: e.port },
                )?;
                println!(
                    "{:?} serving {} on the host's :{}",
                    e.kind, e.folder, e.port
                );
                println!(
                    "open http://localhost:{port}{} (Ctrl-C to stop forwarding)",
                    e.url_path
                );
                tokio::signal::ctrl_c().await?;
            }
            EditorCmd::Stop { folder } => c.editor_stop(folder).await?,
            EditorCmd::Tunnel { action } => match action {
                TunnelCmd::Status => print_tunnel(&c.vscode_tunnel_status().await?),
                TunnelCmd::Install { accept_license } => {
                    print_tunnel(&c.vscode_cli_install(accept_license).await?);
                }
                TunnelCmd::Start {
                    accept_license,
                    microsoft,
                    name,
                } => {
                    use client_core::proto::{TunnelProvider, TunnelState, VsCodeTunnelStart};
                    let (listener, mut events) = WorkspaceEventQueue::channel();
                    c.set_workspace_listener(listener);
                    let provider = if microsoft {
                        TunnelProvider::Microsoft
                    } else {
                        TunnelProvider::GitHub
                    };
                    let mut status = c
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
                            Some(WorkspaceEvent::VsCodeTunnel { status: s }) => status = s,
                            Some(_) => continue,
                            None => break,
                        }
                    }
                }
                TunnelCmd::Stop => print_tunnel(&c.vscode_tunnel_stop().await?),
                TunnelCmd::Open { target } => {
                    let (path, line, column) = split_target(&target);
                    let o = c
                        .vscode_tunnel_open(client_core::proto::VsCodeTunnelOpen {
                            folder: None,
                            path,
                            line,
                            column,
                        })
                        .await?;
                    println!("web:     {}", o.web_url);
                    println!("desktop: {}", o.desktop_uri);
                    if o.in_window {
                        println!("opened in the connected window");
                    }
                }
            },
            EditorCmd::Open { target } => {
                let (path, line, col) = split_target(&target);
                let opened = c.editor_open(None, path, line, col).await?;
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
                    Some(p) => p,
                    None => conn.focused_cwd().await,
                };
                let s = conn.client.git_status(path).await?;
                println!(
                    "{} on {} (upstream {}, +{} -{})",
                    s.root,
                    s.branch.as_deref().unwrap_or("(detached)"),
                    s.upstream.as_deref().unwrap_or("-"),
                    s.ahead,
                    s.behind
                );
                for f in &s.files {
                    let orig = f
                        .orig_path
                        .as_ref()
                        .map(|o| format!(" (from {o})"))
                        .unwrap_or_default();
                    println!("  {:?}/{:?} {}{orig}", f.staged, f.unstaged, f.path);
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
                    Some(p) => p,
                    None => conn.focused_cwd().await,
                };
                let base = if staged {
                    DiffBase::Staged
                } else if index {
                    DiffBase::Index
                } else if let Some(r) = rev {
                    DiffBase::Rev(r)
                } else if let Some(b) = merge_base {
                    DiffBase::MergeBase(b)
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
                print_diff(&diff, stat);
            }
        },
        WsCmd::Turns { pane, diff, stat } => {
            let pane_id = pane.map_or(conn.tab()?.focused, PaneId);
            match diff {
                Some(turn) => {
                    let turn = (turn != 0).then_some(turn);
                    let d = c.turn_diff(pane_id, turn, 3, !stat).await?;
                    print_diff(&d, stat);
                }
                None => {
                    for t in c.list_turns(pane_id).await? {
                        let state = if t.end_tree.is_some() {
                            "done"
                        } else {
                            "running"
                        };
                        println!(
                            "turn {} {state} in {} ({}..{:?})",
                            t.turn, t.root, t.started_at, t.ended_at
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
                .map(|n| parse_note(n))
                .collect::<Result<Vec<_>>>()?;
            let prompt = c
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
                    Some(r) => r,
                    None => conn.focused_cwd().await,
                };
                let w = conn
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
                    w.path,
                    w.branch.as_deref().unwrap_or("?"),
                    w.port.map_or("-".into(), |p| p.to_string())
                );
            }
            WorktreeCmd::List { repo } => {
                let repo = match repo {
                    Some(r) => r,
                    None => conn.focused_cwd().await,
                };
                for w in conn.client.worktree_list(repo).await? {
                    println!(
                        "{}{} {} PORT={}",
                        if w.main { "* " } else { "  " },
                        w.path,
                        w.branch.as_deref().unwrap_or("(detached)"),
                        w.port.map_or("-".into(), |p| p.to_string())
                    );
                }
            }
            WorktreeCmd::Remove {
                path,
                force,
                delete_branch,
            } => c.worktree_remove(path, force, delete_branch).await?,
            WorktreeCmd::Launch {
                path,
                agent,
                vertical,
            } => {
                let pane = conn.tab()?.focused;
                let agent = agent.map(|a| match a {
                    crate::Agent::Claude => AgentKind::Claude,
                    crate::Agent::Codex => AgentKind::Codex,
                });
                let axis = if vertical {
                    Axis::Vertical
                } else {
                    Axis::Horizontal
                };
                let new = conn.client.worktree_launch(path, pane, axis, agent).await?;
                println!("pane {new}");
            }
        },
        WsCmd::Fs { action } => fs(conn, action).await?,
        WsCmd::Inbox { seen, watch } => {
            let (listener, mut events) = WorkspaceEventQueue::channel();
            c.set_workspace_listener(listener);
            let list = if seen {
                c.attention_seen(AttentionSeen {
                    ids: vec![],
                    up_to: Some(u64::MAX),
                    pane_id: None,
                })
                .await?
            } else {
                c.attention_list().await?
            };
            for item in &list.items {
                print_item(item);
            }
            println!("{} unseen", list.unseen);
            while watch && let Some(event) = events.recv().await {
                if let WorkspaceEvent::Attention { update } = event {
                    println!("{update:?}");
                }
            }
        }
    }
    Ok(())
}

fn print_ports(ports: &[client_core::proto::PortInfo]) {
    if ports.is_empty() {
        println!("no listening ports in panes");
    }
    for p in ports {
        println!(
            ":{:<6} {:<8?} pane {:<4} {} (pid {}){}{}",
            p.port,
            p.kind,
            p.pane_id.map_or("-".into(), |p| p.to_string()),
            p.process,
            p.pid,
            if p.loopback_only { " loopback" } else { "" },
            p.url.as_ref().map(|u| format!(" {u}")).unwrap_or_default()
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
    let c = &conn.client;
    match action {
        FsCmd::Ls { path, all } => {
            let dir = c.fs_list(path, all).await?;
            for e in &dir.entries {
                let kind = match e.kind {
                    FileKind::Dir => "d",
                    FileKind::Symlink => "l",
                    FileKind::File => "-",
                    FileKind::Other => "?",
                };
                let link = e
                    .link_target
                    .as_ref()
                    .map(|t| format!(" -> {t}"))
                    .unwrap_or_default();
                println!("{kind} {:o} {:>10} {}{link}", e.mode, e.size, e.name);
            }
            if dir.truncated {
                println!("(truncated)");
            }
        }
        FsCmd::Stat { path } => println!("{:#?}", c.fs_stat(path).await?),
        FsCmd::Cat { path, offset, len } => {
            use std::io::Write;
            let chunk = c.fs_read(path, offset, len).await?;
            std::io::stdout().write_all(&chunk.data)?;
        }
        FsCmd::Put {
            local,
            remote,
            if_match,
            new,
        } => {
            let start = std::time::Instant::now();
            let stat = c
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
            let stat = c.download_file(remote, local, 0, None, None).await?;
            let secs = start.elapsed().as_secs_f64();
            println!(
                "{} bytes in {secs:.2}s ({:.1} MB/s)",
                stat.size,
                stat.size as f64 / secs / 1e6
            );
        }
        FsCmd::Mkdir { path, parents } => {
            c.fs_mkdir(path, parents).await?;
        }
        FsCmd::Mv { from, to, force } => {
            c.fs_rename(from, to, force).await?;
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
            c.fs_delete(path, mode, recursive).await?;
        }
        FsCmd::Watch { path } => {
            let (listener, mut events) = WorkspaceEventQueue::channel();
            c.set_workspace_listener(listener);
            let id = c.fs_watch(path).await?;
            println!("watching (id {id}); Ctrl-C to stop");
            loop {
                tokio::select! {
                    e = events.recv() => match e {
                        Some(WorkspaceEvent::FsChanged { change }) => {
                            if change.rescan {
                                println!("(many changes)");
                            }
                            for p in change.paths {
                                println!("{p}");
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
    use super::*;

    #[test]
    fn parses_targets_and_notes() {
        assert_eq!(split_target("a.rs:3:4"), ("a.rs".into(), Some(3), Some(4)));
        assert_eq!(split_target("a.rs:3"), ("a.rs".into(), Some(3), None));
        assert_eq!(split_target("a.rs"), ("a.rs".into(), None, None));
        let n = parse_note("src/x.rs:3-5:fix this: please").unwrap();
        assert_eq!((n.start_line, n.end_line), (3, 5));
        assert_eq!(n.note, "fix this: please");
        assert!(parse_note("nope").is_err());
    }
}
