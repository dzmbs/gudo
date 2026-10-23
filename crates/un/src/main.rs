//! `un`: a small developer client for testing the daemon end to end without the app.
//!
//! ```text
//! un pair <ticket>            remember a daemon (and create this machine's device key)
//! un attach                   show the focused pane in this terminal (Ctrl-] detaches)
//! un ls                       sessions, tabs and panes
//! un split [-v] [--agent claude|codex]
//! un close | zoom | focus <left|right|up|down|PANE>
//! un resize <h|v> <delta>
//! un tab new|close|next|prev|select <n>|move <n>|rename <name>
//! un session new <name>|rename <name>|close
//! un forward <remote-port> | --unix <path> [--local <port>]
//! un ports [--watch]          un inbox [--seen] [--watch]
//! un editor status|launch [folder]|stop <folder>|open <path[:line[:col]]>
//! un git status [path]        un git diff [--staged|--index|--rev R|--merge-base B] [--stat]
//! un turns [--diff N]         un review --pane P --note 'path:L[-L]:text' [--submit]
//! un worktree create|list|remove|launch
//! un fs ls|stat|cat|put|get|mkdir|mv|rm|watch
//! un search <pattern> [-e] [--case sensitive|insensitive|smart]
//! un links [--commands N]      un marks      un output [--command N]
//! un invite [--role R+R] [--scope daemon|session|tab|pane[:ID]] [--ttl 24h] [--uses N]
//!           [--name N] [--delegate]           un join <invite>
//! un daemon info              the daemon's build, protocol level and host
//! un daemon upgrade <file>    send a new build (raw or .gz) to the daemon, which restarts
//! un who [--watch]            un take-control [--force] [--wait]   un release-control
//! un prompt <text>            un grants [--devices]   un revoke <grant>|--device K   un audit
//! un draft <text> [--cps N] [--then-focus PANE] [--hold S]   a live draft others watch
//! ```

use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand, ValueEnum};
use client_core::proto::{
    AgentKind, Axis, CaseMode, Direction, LayoutNode, LayoutOp, LinkSource, OpOutcome, PaneId,
    PaneLaunch, PaneSize, SearchMode, SearchQuery, SessionId, SessionLayout, SessionSummary,
    TabLayout,
};
use client_core::{Client, ClientConfig, ClientEvent, EventQueue, RelayMode};
use tokio::io::AsyncReadExt;
use tokio::sync::mpsc::UnboundedReceiver;

mod draw;
mod mp;
mod ws;

const TIMEOUT: Duration = Duration::from_secs(15);
/// Ctrl-] detaches, like telnet, in every encoding the outer terminal may use for it: the legacy
/// byte, the kitty keyboard protocol (`CSI 93;5u`, optionally with an event type) and xterm's
/// modifyOtherKeys (`CSI 27;5;93~`). The remote program can switch the outer terminal into the
/// latter two because `attach` passes its output through raw.
const DETACH_SEQUENCES: [&[u8]; 4] = [b"\x1d", b"\x1b[93;5u", b"\x1b[93;5:1u", b"\x1b[27;5;93~"];

/// Turns off the input and screen modes a remote program may have enabled on the outer terminal:
/// kitty keyboard flags, modifyOtherKeys, bracketed paste, mouse reporting, focus events, the
/// alternate screen, and a hidden cursor.
const RESTORE_MODES: &[u8] =
    b"\x1b[=0;1u\x1b[>4;0m\x1b[?2004l\x1b[?1000;1002;1003;1006l\x1b[?1004l\x1b[?1049l\x1b[?25h";

/// Returns where the first detach sequence in `input` starts, if any.
fn detach_position(input: &[u8]) -> Option<usize> {
    DETACH_SEQUENCES
        .iter()
        .filter_map(|seq| input.windows(seq.len()).position(|w| w == *seq))
        .min()
}

#[derive(Parser)]
#[command(name = brand::CLI_BIN, version, about = "Developer client for the host daemon")]
struct Cli {
    /// Pairing ticket; defaults to the one saved by `pair`.
    #[arg(long, global = true)]
    ticket: Option<String>,
    /// Invite to connect with as a guest; defaults to the one saved by `join` (used when no
    /// ticket is saved).
    #[arg(long, global = true, conflicts_with = "ticket")]
    invite: Option<String>,
    /// Session name; defaults to the most recently used one.
    #[arg(long, short = 's', global = true)]
    session: Option<String>,
    /// Direct connections only (no relays).
    #[arg(long, global = true)]
    no_relay: bool,
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Save a pairing ticket and pair this machine with the daemon.
    Pair { ticket: String },
    /// Save an invite and join the daemon as a guest under its grant. A knock invite asks
    /// the owner first and waits for their answer.
    Join {
        invite: String,
        /// Your name, shown to the owner when knocking.
        #[arg(long)]
        name: Option<String>,
    },
    /// Show the focused pane in this terminal; follows focus changes. Ctrl-] detaches.
    Attach,
    /// List sessions, and the attached session's tabs and panes.
    Ls,
    /// Split the focused pane.
    Split {
        /// Stack vertically (default: side by side).
        #[arg(short, long)]
        vertical: bool,
        /// Launch a coding agent in the new pane.
        #[arg(long)]
        agent: Option<Agent>,
        /// Pane to split (default: focused).
        #[arg(long)]
        pane: Option<u64>,
    },
    /// Close the focused pane (or `--pane`).
    Close {
        #[arg(long)]
        pane: Option<u64>,
    },
    /// Toggle zoom of the focused pane.
    Zoom,
    /// Move focus in a direction, or to a pane id.
    Focus { target: String },
    /// Grow (positive) or shrink the focused pane: `h` for width, `v` for height.
    Resize {
        axis: String,
        #[arg(allow_hyphen_values = true)]
        delta: f32,
    },
    /// Tab operations.
    Tab {
        #[command(subcommand)]
        action: TabCmd,
    },
    /// Session operations.
    Session {
        #[command(subcommand)]
        action: SessionCmd,
    },
    /// Forward a local TCP port to `localhost:<remote>` (or a Unix socket) on the daemon's
    /// host.
    Forward {
        #[arg(required_unless_present = "unix")]
        remote: Option<u16>,
        /// A Unix socket on the host instead of a TCP port.
        #[arg(long, conflicts_with = "remote")]
        unix: Option<String>,
        #[arg(long, default_value_t = 0)]
        local: u16,
    },
    /// Splice stdin/stdout onto the host's sshd (`localhost:<port>`) over the daemon link: an
    /// SSH `ProxyCommand` for VS Code Remote - SSH to hosts reachable only through the daemon.
    SshProxy {
        #[arg(long, default_value_t = 22)]
        port: u16,
    },
    #[command(flatten)]
    Ws(ws::WsCmd),
    #[command(flatten)]
    Mp(mp::MpCmd),
    /// Drawings and images: list, show, export, send to an agent.
    Draw {
        #[command(subcommand)]
        action: draw::DrawCmd,
    },
    /// Search a pane's whole scrollback on the daemon (newest match first).
    Search {
        pattern: String,
        /// Treat the pattern as a regular expression.
        #[arg(long, short = 'e')]
        regex: bool,
        /// Case handling.
        #[arg(long, value_enum, default_value_t = Case::Smart)]
        case: Case,
        /// Matches to show.
        #[arg(long, default_value_t = 20)]
        limit: u32,
        /// Pane to search (default: focused).
        #[arg(long)]
        pane: Option<u64>,
    },
    /// Hyperlinks, URLs and file paths on screen and in recent command output.
    Links {
        /// Recent commands whose output to scan.
        #[arg(long, default_value_t = 3)]
        commands: u16,
        #[arg(long)]
        pane: Option<u64>,
    },
    /// Shell-integration commands: exit status, duration, directory.
    Marks {
        #[arg(long)]
        pane: Option<u64>,
    },
    /// The daemon itself: what build it runs, and replacing it with another.
    Daemon {
        #[command(subcommand)]
        action: DaemonCmd,
    },
    /// Print a command's output (default: the last finished command).
    Output {
        /// Command number from `marks`.
        #[arg(long)]
        command: Option<u64>,
        #[arg(long)]
        pane: Option<u64>,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum Case {
    Sensitive,
    Insensitive,
    Smart,
}

#[derive(Subcommand)]
enum TabCmd {
    New { name: Option<String> },
    Close,
    Next,
    Prev,
    Select { index: usize },
    Move { index: u32 },
    Rename { name: String },
}

#[derive(Subcommand)]
enum DaemonCmd {
    /// Version, build, protocol level, OS, CPU and host name.
    Info,
    /// Send a new build (an `unnamed-hostd` executable or its .gz) to the daemon, which
    /// checks it, swaps it in and restarts into it. Panes come back from its saved layout;
    /// shells restart.
    Upgrade {
        file: PathBuf,
        /// Build id to log on the daemon.
        #[arg(long, default_value = "")]
        build: String,
    },
}

#[derive(Subcommand)]
enum SessionCmd {
    New { name: String },
    Rename { name: String },
    Close,
}

#[derive(Clone, Copy, ValueEnum)]
pub(crate) enum Agent {
    Claude,
    Codex,
}

fn config_dir() -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config")
        })
        .join(brand::DIR_NAME)
}

/// Knocks with a knock invite and waits for the owner; returns the invite to join with.
async fn knock(cli: &Cli, invite: &str, name: Option<String>) -> Result<String> {
    use client_core::knock::{KnockOutcome, knock};
    let mut config = ClientConfig::new(device_key()?);
    if cli.no_relay {
        config.relay = RelayMode::Disabled;
    }
    let outcome = knock(
        invite,
        config,
        client_core::ConnectOptions::default(),
        name,
        |id| eprintln!("knocked (#{id}); waiting for the owner to let you in…"),
    )
    .await?;
    match outcome {
        KnockOutcome::Admitted(invite) => {
            eprintln!("let in");
            Ok(invite.to_string())
        }
        KnockOutcome::Denied => bail!("the owner turned you away"),
    }
}

fn device_key() -> Result<Vec<u8>> {
    use std::os::unix::fs::OpenOptionsExt;
    let path = config_dir().join("un.key");
    if let Ok(key) = std::fs::read(&path)
        && key.len() == 32
    {
        return Ok(key);
    }
    std::fs::create_dir_all(config_dir())?;
    let key = ClientConfig::generate_key();
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)?
        .write_all(&key)?;
    Ok(key)
}

/// How to dial: a pairing ticket (owner device) or an invite (guest).
enum Dial {
    Ticket(String),
    Invite(String),
}

fn dial(cli: &Cli) -> Result<Dial> {
    if let Some(t) = &cli.ticket {
        return Ok(Dial::Ticket(t.clone()));
    }
    if let Some(i) = &cli.invite {
        return Ok(Dial::Invite(i.clone()));
    }
    match saved_ticket() {
        Ok(t) => Ok(Dial::Ticket(t)),
        Err(e) => std::fs::read_to_string(config_dir().join("un.invite"))
            .map(|i| Dial::Invite(i.trim().to_owned()))
            .map_err(|_| e),
    }
}

fn saved_ticket() -> Result<String> {
    std::fs::read_to_string(config_dir().join("un.ticket"))
        .map(|t| t.trim().to_owned())
        .with_context(|| format!("no ticket: run `{} pair <ticket>` first", brand::CLI_BIN))
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    runtime.block_on(run(cli))
}

/// A connected, attached client and what it has heard.
struct Conn {
    client: Client,
    events: UnboundedReceiver<ClientEvent>,
    layout: Option<SessionLayout>,
    sessions: Vec<SessionSummary>,
    /// Working directories from pane metadata.
    cwds: std::collections::HashMap<PaneId, String>,
    /// Authenticated at least once.
    connected: bool,
    /// Why the last dial or connection failed, for the timeout message.
    last_error: Option<String>,
    /// Dialling the ticket's direct addresses only (`--no-relay`).
    direct_only: bool,
}

impl Conn {
    /// Starts dialling; nothing is awaited yet.
    fn dial(cli: &Cli) -> Result<Self> {
        let (listener, events) = EventQueue::channel();
        let mut config = ClientConfig::new(device_key()?);
        if cli.no_relay {
            config.relay = RelayMode::Disabled;
        }
        let client = match dial(cli)? {
            Dial::Ticket(ticket) => Client::connect(&ticket, config, listener)?,
            Dial::Invite(invite) => Client::join(&invite, config, listener)?,
        };
        Ok(Self {
            client,
            events,
            layout: None,
            sessions: Vec::new(),
            cwds: std::collections::HashMap::new(),
            connected: false,
            last_error: None,
            direct_only: cli.no_relay,
        })
    }

    /// Connects without attaching (forwards need no session).
    async fn connect(cli: &Cli) -> Result<Self> {
        let mut conn = Self::dial(cli)?;
        conn.wait("the connection", |c| c.connected).await?;
        Ok(conn)
    }

    /// Connects and attaches to `--session` (or the daemon's choice).
    async fn open(cli: &Cli) -> Result<Self> {
        let mut conn = Self::dial(cli)?;
        let session = match &cli.session {
            Some(name) => {
                conn.client.list_sessions();
                conn.wait("session list", |c| !c.sessions.is_empty())
                    .await?;
                Some(
                    conn.sessions
                        .iter()
                        .find(|s| &s.name == name)
                        .map(|s| s.session_id)
                        .with_context(|| format!("no session named {name:?}"))?,
                )
            }
            None => None,
        };
        conn.client.attach(session);
        conn.wait("layout", |c| c.layout.is_some()).await?;
        Ok(conn)
    }

    fn apply(&mut self, event: &ClientEvent) -> Result<()> {
        match event {
            ClientEvent::Layout { layout } => self.layout = Some(layout.clone()),
            ClientEvent::Connected { .. } => self.connected = true,
            ClientEvent::Disconnected { reason } => self.last_error = Some(reason.clone()),
            ClientEvent::Sessions { sessions } => self.sessions.clone_from(sessions),
            ClientEvent::PaneMeta { meta } => {
                if let Some(cwd) = &meta.cwd {
                    self.cwds.insert(meta.pane_id, cwd.clone());
                }
            }
            ClientEvent::Refused { reason } => bail!("daemon refused the connection: {reason}"),
            _ => {}
        }
        Ok(())
    }

    async fn next(&mut self) -> Result<ClientEvent> {
        let event = self.events.recv().await.context("client stopped")?;
        self.apply(&event)?;
        Ok(event)
    }

    async fn wait(&mut self, what: &str, mut done: impl FnMut(&Self) -> bool) -> Result<()> {
        tokio::time::timeout(TIMEOUT, async {
            while !done(self) {
                self.next().await?;
            }
            anyhow::Ok(())
        })
        .await
        .map_err(|_| self.timed_out(what))?
    }

    /// The timeout error: says when the daemon was never reached, and why.
    fn timed_out(&self, what: &str) -> anyhow::Error {
        if self.connected {
            return anyhow::anyhow!("timed out waiting for {what}");
        }
        let why = self
            .last_error
            .as_deref()
            .map_or_else(String::new, |e| format!(" (last error: {e})"));
        let hint = if self.direct_only {
            "; with --no-relay only the ticket's direct addresses are dialled: if the daemon \
             now listens elsewhere (another network, or an older daemon that changed its port on \
             a restart), pair again with a new ticket or drop --no-relay"
        } else {
            ""
        };
        anyhow::anyhow!(
            "could not reach the daemon within {}s{why}{hint}",
            TIMEOUT.as_secs()
        )
    }

    fn layout(&self) -> &SessionLayout {
        self.layout.as_ref().expect("attached")
    }

    fn tab(&self) -> Result<&TabLayout> {
        let layout = self.layout();
        layout
            .tabs
            .iter()
            .find(|t| Some(t.tab_id) == layout.active_tab)
            .context("session has no tabs")
    }

    /// Waits for the event `pick` accepts and returns what it extracted.
    async fn answer<T>(&mut self, mut pick: impl FnMut(ClientEvent) -> Option<T>) -> Result<T> {
        tokio::time::timeout(TIMEOUT, async {
            loop {
                if let Some(answer) = pick(self.next().await?) {
                    return anyhow::Ok(answer);
                }
            }
        })
        .await
        .context("timed out waiting for the daemon")?
    }

    async fn op(&mut self, op: LayoutOp) -> Result<OpOutcome> {
        let id = self.client.op(op);
        let outcome = tokio::time::timeout(TIMEOUT, async {
            loop {
                if let ClientEvent::OpResult { op_id, outcome } = self.next().await?
                    && op_id == id
                {
                    return anyhow::Ok(outcome);
                }
            }
        })
        .await
        .context("timed out waiting for the daemon")??;
        if let OpOutcome::Failed { code, message } = &outcome {
            bail!("{code:?}: {message}");
        }
        Ok(outcome)
    }
}

async fn run(cli: Cli) -> Result<()> {
    if let Cmd::Daemon { action } = &cli.command {
        return daemon_cmd(&cli, action).await;
    }
    if let Cmd::Pair { ticket } = &cli.command {
        ticket
            .parse::<client_core::proto::Ticket>()
            .context("not a pairing ticket")?;
        std::fs::create_dir_all(config_dir())?;
        std::fs::write(config_dir().join("un.ticket"), ticket)?;
        let cli = Cli {
            ticket: Some(ticket.clone()),
            ..cli
        };
        let conn = Conn::open(&cli).await?;
        println!("paired; attached to session {:?}", conn.layout().name);
        return Ok(());
    }
    if let Cmd::Join { invite, name } = &cli.command {
        let (parsed, terms) =
            client_core::proto::Invite::parse_with_terms(invite).context("not an invite")?;
        let invite = &if terms.knock {
            knock(&cli, invite, name.clone()).await?
        } else {
            invite.clone()
        };
        std::fs::create_dir_all(config_dir())?;
        std::fs::write(config_dir().join("un.invite"), invite)?;
        let cli = Cli {
            ticket: None,
            invite: Some(invite.clone()),
            ..cli
        };
        let conn = Conn::open(&cli).await?;
        let me = conn.client.who_am_i().await?;
        println!(
            "joined {}'s daemon as {} ({} on {}); attached to session {:?}",
            parsed.inviter,
            me.name,
            me.roles.names(),
            me.scope,
            conn.layout().name
        );
        return Ok(());
    }
    let mut conn = if matches!(cli.command, Cmd::Forward { .. }) {
        Conn::connect(&cli).await?
    } else {
        Conn::open(&cli).await?
    };
    let shell = PaneLaunch::Shell { cwd: None };
    let outcome = match cli.command {
        Cmd::Pair { .. } | Cmd::Join { .. } | Cmd::Daemon { .. } => {
            unreachable!("handled above")
        }
        Cmd::Mp(cmd) => return mp::run(&mut conn, cmd).await,
        Cmd::Draw { action } => return draw::run(&mut conn, action).await,
        Cmd::Attach => return attach(conn).await,
        Cmd::SshProxy { port } => {
            conn.client
                .forward_io(
                    client_core::proto::ForwardTarget::Tcp { port },
                    tokio::io::stdin(),
                    tokio::io::stdout(),
                )
                .await?;
            return Ok(());
        }
        Cmd::Ws(cmd) => return ws::run(&mut conn, cmd).await,
        Cmd::Search {
            pattern,
            regex,
            case,
            limit,
            pane,
        } => {
            let pane_id = pane.map_or(conn.tab()?.focused, PaneId);
            let query = SearchQuery {
                pattern,
                mode: if regex {
                    SearchMode::Regex
                } else {
                    SearchMode::Plain
                },
                case: match case {
                    Case::Sensitive => CaseMode::Sensitive,
                    Case::Insensitive => CaseMode::Insensitive,
                    Case::Smart => CaseMode::Smart,
                },
            };
            let id = conn.client.search(pane_id, query, 0, limit);
            let page = conn
                .answer(|e| match e {
                    ClientEvent::SearchResult { req_id, result, .. } if req_id == id => {
                        Some(result)
                    }
                    _ => None,
                })
                .await??;
            println!(
                "{} matches in {} rows (row 0 = oldest scrollback)",
                page.total, page.total_rows
            );
            for m in &page.matches {
                println!("{:>7}:{:<4} {}", m.row, m.col, m.line.trim_end());
            }
            return Ok(());
        }
        Cmd::Links { commands, pane } => {
            let pane_id = pane.map_or(conn.tab()?.focused, PaneId);
            let id = conn.client.links(pane_id, commands);
            let links = conn
                .answer(|e| match e {
                    ClientEvent::Links { req_id, result, .. } if req_id == id => Some(result),
                    _ => None,
                })
                .await??;
            for link in &links.links {
                let place = match link.source {
                    LinkSource::Screen => "screen".to_owned(),
                    LinkSource::Command { command_id } => format!("cmd {command_id}"),
                };
                let mut target = link.target.clone();
                if let Some(line) = link.line {
                    target += &format!(":{line}");
                }
                if let Some(col) = link.column {
                    target += &format!(":{col}");
                }
                let missing = if link.exists == Some(false) {
                    " (missing)"
                } else {
                    ""
                };
                println!(
                    "{:<9} {:<8} {target}{missing}",
                    format!("{:?}", link.kind),
                    place
                );
            }
            return Ok(());
        }
        Cmd::Marks { pane } => {
            let pane_id = pane.map_or(conn.tab()?.focused, PaneId);
            let id = conn.client.commands(pane_id);
            let list = conn
                .answer(|e| match e {
                    ClientEvent::Commands { req_id, result, .. } if req_id == id => Some(result),
                    _ => None,
                })
                .await??;
            for c in &list.commands {
                let m = &c.mark;
                let status = match m.finished {
                    None => "running".to_owned(),
                    Some(f) => format!(
                        "exit {} in {:.1}s",
                        f.exit.map_or("?".into(), |e| e.to_string()),
                        f.duration_ms as f64 / 1000.0
                    ),
                };
                println!(
                    "{:>4}  {:<22} {}  [{}]",
                    m.command_id,
                    status,
                    m.command.as_deref().unwrap_or("?"),
                    m.cwd.as_deref().unwrap_or("")
                );
            }
            return Ok(());
        }
        Cmd::Output { command, pane } => {
            let pane_id = pane.map_or(conn.tab()?.focused, PaneId);
            let id = conn.client.command_output(pane_id, command);
            let out = conn
                .answer(|e| match e {
                    ClientEvent::CommandOutput { req_id, result, .. } if req_id == id => {
                        Some(result)
                    }
                    _ => None,
                })
                .await??;
            println!("{}", out.text);
            return Ok(());
        }
        Cmd::Ls => {
            conn.client.list_sessions();
            conn.wait("session list", |c| !c.sessions.is_empty())
                .await?;
            print_ls(&conn);
            return Ok(());
        }
        Cmd::Split {
            vertical,
            agent,
            pane,
        } => {
            let pane_id = pane.map_or(conn.tab()?.focused, PaneId);
            let launch = match agent {
                None => shell,
                Some(a) => PaneLaunch::Agent {
                    agent: match a {
                        Agent::Claude => AgentKind::Claude,
                        Agent::Codex => AgentKind::Codex,
                    },
                    resume: None,
                    cwd: None,
                },
            };
            let axis = if vertical {
                Axis::Vertical
            } else {
                Axis::Horizontal
            };
            conn.op(LayoutOp::Split {
                pane_id,
                axis,
                launch,
            })
            .await?
        }
        Cmd::Close { pane } => {
            let pane_id = pane.map_or(conn.tab()?.focused, PaneId);
            conn.op(LayoutOp::ClosePane { pane_id }).await?
        }
        Cmd::Zoom => {
            let pane_id = conn.tab()?.focused;
            conn.op(LayoutOp::ToggleZoom { pane_id }).await?
        }
        Cmd::Focus { target } => {
            let tab_id = conn.tab()?.tab_id;
            let direction = match target.as_str() {
                "left" | "l" => Some(Direction::Left),
                "right" | "r" => Some(Direction::Right),
                "up" | "u" => Some(Direction::Up),
                "down" | "d" => Some(Direction::Down),
                _ => None,
            };
            match direction {
                Some(direction) => {
                    conn.op(LayoutOp::FocusDirection { tab_id, direction })
                        .await?
                }
                None => {
                    let pane_id =
                        PaneId(target.parse().context("expected a direction or pane id")?);
                    conn.op(LayoutOp::Focus { pane_id }).await?
                }
            }
        }
        Cmd::Resize { axis, delta } => {
            let axis = match axis.as_str() {
                "h" | "horizontal" | "width" => Axis::Horizontal,
                "v" | "vertical" | "height" => Axis::Vertical,
                _ => bail!("axis is h or v"),
            };
            let pane_id = conn.tab()?.focused;
            conn.op(LayoutOp::Resize {
                pane_id,
                axis,
                delta,
            })
            .await?
        }
        Cmd::Tab { action } => {
            let session_id = conn.layout().session_id;
            let tabs: Vec<_> = conn.layout().tabs.iter().map(|t| t.tab_id).collect();
            let current = conn.tab()?.tab_id;
            let pos = tabs.iter().position(|&t| t == current).unwrap_or(0);
            match action {
                TabCmd::New { name } => {
                    conn.op(LayoutOp::NewTab {
                        session_id,
                        name: name.unwrap_or_default(),
                        launch: shell,
                    })
                    .await?
                }
                TabCmd::Close => conn.op(LayoutOp::CloseTab { tab_id: current }).await?,
                TabCmd::Next | TabCmd::Prev => {
                    let n = tabs.len();
                    let next = match action {
                        TabCmd::Next => (pos + 1) % n,
                        _ => (pos + n - 1) % n,
                    };
                    conn.op(LayoutOp::SelectTab { tab_id: tabs[next] }).await?
                }
                TabCmd::Select { index } => {
                    let tab_id = *tabs
                        .get(index.saturating_sub(1))
                        .context("no such tab (tabs count from 1)")?;
                    conn.op(LayoutOp::SelectTab { tab_id }).await?
                }
                TabCmd::Move { index } => {
                    conn.op(LayoutOp::MoveTab {
                        tab_id: current,
                        index: index.saturating_sub(1),
                    })
                    .await?
                }
                TabCmd::Rename { name } => {
                    conn.op(LayoutOp::RenameTab {
                        tab_id: current,
                        name,
                    })
                    .await?
                }
            }
        }
        Cmd::Session { action } => {
            let session_id = conn.layout().session_id;
            match action {
                SessionCmd::New { name } => {
                    conn.op(LayoutOp::CreateSession {
                        name,
                        launch: shell,
                    })
                    .await?
                }
                SessionCmd::Rename { name } => {
                    conn.op(LayoutOp::RenameSession { session_id, name })
                        .await?
                }
                SessionCmd::Close => conn.op(LayoutOp::CloseSession { session_id }).await?,
            }
        }
        Cmd::Forward {
            remote,
            unix,
            local,
        } => {
            use client_core::proto::ForwardTarget;
            let target = match (remote, unix) {
                (_, Some(path)) => ForwardTarget::Unix { path },
                (Some(port), None) => ForwardTarget::Tcp { port },
                (None, None) => bail!("give a remote port or --unix"),
            };
            let port = conn.client.forward(local, target.clone())?;
            println!("forwarding 127.0.0.1:{port} -> daemon host {target:?} (Ctrl-C to stop)");
            tokio::signal::ctrl_c().await?;
            return Ok(());
        }
    };
    match outcome {
        OpOutcome::PaneCreated { pane_id } => println!("pane {pane_id}"),
        OpOutcome::TabCreated { tab_id, pane_id } => {
            // Print the tab's position, which is what `tab select` takes, not its internal id.
            let has_tab = |c: &Conn| c.layout().tabs.iter().any(|t| t.tab_id == tab_id);
            conn.wait("the new tab", has_tab).await?;
            let tabs = &conn.layout().tabs;
            let position = tabs.iter().position(|t| t.tab_id == tab_id).unwrap_or(0) + 1;
            println!("tab {position} of {}, pane {pane_id}", tabs.len());
        }
        OpOutcome::SessionCreated {
            session_id,
            tab_id,
            pane_id,
        } => println!("session {session_id}, tab {tab_id}, pane {pane_id}"),
        _ => {}
    }
    Ok(())
}

fn print_ls(conn: &Conn) {
    let attached: Option<SessionId> = conn.layout.as_ref().map(|l| l.session_id);
    for s in &conn.sessions {
        let mark = if Some(s.session_id) == attached {
            "*"
        } else {
            " "
        };
        println!(
            "{mark} {} ({} tabs, {} panes, {} clients)",
            s.name, s.tabs, s.panes, s.clients
        );
    }
    let layout = conn.layout();
    for (i, tab) in layout.tabs.iter().enumerate() {
        let mark = if Some(tab.tab_id) == layout.active_tab {
            "*"
        } else {
            " "
        };
        let name = if tab.name.is_empty() { "-" } else { &tab.name };
        println!(
            "  {mark} tab {} {name}: {}{}",
            i + 1,
            describe(&tab.root, tab.focused),
            tab.zoomed
                .map(|z| format!(" (zoomed {z})"))
                .unwrap_or_default()
        );
    }
}

fn describe(node: &client_core::proto::LayoutNode, focused: PaneId) -> String {
    use client_core::proto::LayoutNode;
    match node {
        LayoutNode::Leaf(p) if *p == focused => format!("[{p}]"),
        LayoutNode::Leaf(p) => p.to_string(),
        LayoutNode::Split {
            axis,
            ratio,
            first,
            second,
        } => {
            let sep = match axis {
                Axis::Horizontal => "|",
                Axis::Vertical => "/",
            };
            format!(
                "({} {sep}{:.0}% {})",
                describe(first, focused),
                ratio * 100.0,
                describe(second, focused)
            )
        }
    }
}

/// Restores the terminal's modes when dropped.
struct RawMode(rustix::termios::Termios);

impl RawMode {
    fn enter() -> Result<Self> {
        let stdin = rustix::stdio::stdin();
        let saved = rustix::termios::tcgetattr(stdin).context("stdin is not a terminal")?;
        let mut raw = saved.clone();
        raw.make_raw();
        rustix::termios::tcsetattr(stdin, rustix::termios::OptionalActions::Now, &raw)?;
        Ok(Self(saved))
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        let _ = rustix::termios::tcsetattr(
            rustix::stdio::stdin(),
            rustix::termios::OptionalActions::Now,
            &self.0,
        );
    }
}

fn local_size() -> PaneSize {
    let ws = rustix::termios::tcgetwinsize(rustix::stdio::stdout()).ok();
    PaneSize {
        cols: ws.map_or(80, |w| w.ws_col.max(1)),
        rows: ws.map_or(24, |w| w.ws_row.max(1)),
        width_px: ws.map_or(0, |w| w.ws_xpixel),
        height_px: ws.map_or(0, |w| w.ws_ypixel),
    }
}

fn write_out(bytes: &[u8]) {
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(bytes);
    let _ = out.flush();
}

/// Proxies the focused pane's raw bytes to this terminal and keystrokes back.
async fn attach(mut conn: Conn) -> Result<()> {
    use tokio::signal::unix::{SignalKind, signal};

    let _raw = RawMode::enter()?;
    let mut winch = signal(SignalKind::window_change())?;
    let mut stdin = tokio::io::stdin();
    let mut buf = [0u8; 4096];
    let mut pane = conn.tab()?.focused;
    follow(&conn.client, pane);
    show_position(conn.layout(), pane);

    loop {
        tokio::select! {
            n = stdin.read(&mut buf) => {
                let n = n?;
                if n == 0 {
                    break;
                }
                let input = &buf[..n];
                if let Some(i) = detach_position(input) {
                    if i > 0 {
                        conn.client.send_input(pane, input[..i].to_vec());
                    }
                    break;
                }
                conn.client.send_input(pane, input.to_vec());
            }
            _ = winch.recv() => conn.client.resize(pane, local_size()),
            event = conn.next() => match event? {
                ClientEvent::PaneBytes { pane_id, data, .. } if pane_id == pane => write_out(&data),
                ClientEvent::PaneSnapshot { pane_id, .. } if pane_id == pane => {
                    // Repaint from the mirror: reset, clear, then the formatter's redraw.
                    let vt = conn.client.pane_vt(pane).unwrap_or_default();
                    let mut out = b"\x1bc\x1b[H\x1b[2J".to_vec();
                    out.extend(vt.replace("\r\n", "\n").replace('\n', "\r\n").as_bytes());
                    write_out(&out);
                }
                ClientEvent::Layout { layout } => {
                    let focused = layout
                        .tabs
                        .iter()
                        .find(|t| Some(t.tab_id) == layout.active_tab)
                        .map(|t| t.focused);
                    if let Some(focused) = focused && focused != pane {
                        conn.client.unsubscribe(pane);
                        pane = focused;
                        follow(&conn.client, pane);
                    }
                    show_position(&layout, pane);
                }
                ClientEvent::Disconnected { .. } => {
                    // Shown in the window title so the screen stays intact.
                    write_out(b"\x1b]2;[reconnecting]\x07");
                }
                ClientEvent::Connected { .. } => write_out(b"\x1b]2;\x07"),
                ClientEvent::PaneClosed { pane_id } if pane_id == pane => {
                    // Wait for the layout to name the next focused pane; quit if none comes.
                    let next = tokio::time::timeout(Duration::from_secs(2), async {
                        loop {
                            if let ClientEvent::Layout { layout } = conn.next().await? {
                                let f = layout
                                    .tabs
                                    .iter()
                                    .find(|t| Some(t.tab_id) == layout.active_tab)
                                    .map(|t| t.focused);
                                return anyhow::Ok(f);
                            }
                        }
                    })
                    .await;
                    match next {
                        Ok(Ok(Some(next))) => {
                            pane = next;
                            follow(&conn.client, pane);
                        }
                        _ => break,
                    }
                }
                _ => {}
            },
        }
    }
    write_out(RESTORE_MODES);
    // The outer terminal may still send the detach key's release event; swallow it rather than
    // leak it into the user's shell.
    tokio::time::sleep(Duration::from_millis(80)).await;
    let _ = rustix::termios::tcflush(
        rustix::stdio::stdin(),
        rustix::termios::QueueSelector::IFlush,
    );
    drop(_raw);
    println!("\r\n[detached]");
    Ok(())
}

/// Names the attached pane in the outer terminal's title, since `attach` shows one pane at a time
/// and fresh panes look identical.
fn show_position(layout: &SessionLayout, pane: PaneId) {
    fn leaves(node: &LayoutNode) -> usize {
        match node {
            LayoutNode::Leaf(_) => 1,
            LayoutNode::Split { first, second, .. } => leaves(first) + leaves(second),
        }
    }
    let Some((index, tab)) = layout
        .tabs
        .iter()
        .enumerate()
        .find(|(_, t)| Some(t.tab_id) == layout.active_tab)
    else {
        return;
    };
    let title = format!(
        "un · {} · tab {}/{} · pane {pane} ({} in tab)",
        layout.name,
        index + 1,
        layout.tabs.len(),
        leaves(&tab.root),
    );
    write_out(format!("\x1b]2;{title}\x07").as_bytes());
}

fn follow(client: &Client, pane: PaneId) {
    client.resize(pane, local_size());
    client.subscribe(pane);
    client.set_view(Some(pane), vec![pane]);
}

/// `un daemon …`: works without attaching, also against a daemon this build cannot otherwise
/// talk to (it admits its owner to upgrade only).
async fn daemon_cmd(cli: &Cli, action: &DaemonCmd) -> Result<()> {
    let (listener, mut events) = EventQueue::channel();
    let mut config = ClientConfig::new(device_key()?);
    if cli.no_relay {
        config.relay = RelayMode::Disabled;
    }
    let client = match dial(cli)? {
        Dial::Ticket(ticket) => Client::connect(&ticket, config, listener)?,
        Dial::Invite(invite) => Client::join(&invite, config, listener)?,
    };
    let mut incompatible = None;
    let info = tokio::time::timeout(TIMEOUT, async {
        let mut info = None;
        loop {
            match events.recv().await.context("client stopped")? {
                ClientEvent::DaemonInfo { info: i } => info = Some(i),
                ClientEvent::Connected { .. } => return anyhow::Ok(info.flatten()),
                ClientEvent::Incompatible { reason } => {
                    incompatible = Some(reason);
                    return Ok(info.flatten());
                }
                ClientEvent::Refused { reason } => bail!("daemon refused the connection: {reason}"),
                _ => {}
            }
        }
    })
    .await
    .context("timed out connecting to the daemon")??;
    match action {
        DaemonCmd::Info => {
            let Some(i) = info else {
                println!("the daemon predates version reporting (protocol level 0)");
                return Ok(());
            };
            println!(
                "{} {} ({}, built {})",
                brand::DAEMON_BIN,
                i.version,
                i.build,
                i.built_unix
            );
            println!(
                "protocol:  {} (this client {}; serves clients from {})",
                i.protocol,
                client_core::proto::PROTOCOL_LEVEL,
                i.min_client_protocol
            );
            println!("platform:  {} {} {}", i.os, i.arch, i.os_name);
            println!("host name: {}", i.hostname);
            println!(
                "self upgrade: {}",
                if i.features
                    .contains(client_core::proto::DaemonFeatures::SELF_UPGRADE)
                {
                    "yes"
                } else {
                    "no"
                }
            );
            if let Some(reason) = incompatible {
                println!("incompatible: {reason}");
            }
        }
        DaemonCmd::Upgrade { file, build } => {
            let data =
                std::fs::read(file).with_context(|| format!("reading {}", file.display()))?;
            let build = client_core::DaemonBuild::new(data, build.clone())?;
            let size = build.data.len();
            let started = std::time::Instant::now();
            let new = client.upgrade_daemon(build, None).await?;
            println!(
                "installed {} {} ({} bytes sent in {:.1}s); the daemon is restarting",
                new.version,
                new.build,
                size,
                started.elapsed().as_secs_f64()
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::detach_position;

    #[test]
    fn detach_is_found_in_every_ctrl_bracket_encoding() {
        assert_eq!(detach_position(b"ab\x1d"), Some(2));
        assert_eq!(detach_position(b"x\x1b[93;5u"), Some(1));
        assert_eq!(detach_position(b"\x1b[93;5:1u"), Some(0));
        assert_eq!(detach_position(b"ls\x1b[27;5;93~"), Some(2));
        assert_eq!(detach_position(b"\x1b[93u plain bracket"), None);
    }
}
