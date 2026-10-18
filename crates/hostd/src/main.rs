//! `unnamed-hostd`: the host daemon. A thin main over the `daemon` crate.
//!
//! ```text
//! unnamed-hostd run                 serve until SIGINT/SIGTERM
//! unnamed-hostd pair                print a one-time pairing ticket (text + QR)
//! unnamed-hostd pair --json --wait 30   the same as JSON, once the daemon is up
//! unnamed-hostd status              is it running, where, how many devices
//! unnamed-hostd service install     run at login (systemd --user / launchd)
//! unnamed-hostd service uninstall
//! ```

mod service;

use std::fs::OpenOptions;
use std::net::SocketAddr;
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use daemon::{Config, Daemon, RelayMode};

#[derive(Parser)]
#[command(name = brand::DAEMON_BIN, version, about = "Terminal and coding-agent host daemon")]
struct Cli {
    /// State directory (keys, paired devices, layout). Defaults to `$UN_STATE_DIR`, then the
    /// XDG state dir on Linux and ~/Library/Application Support on macOS.
    #[arg(long, global = true)]
    state_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Run the daemon in the foreground.
    Run {
        /// UDP address to bind (default: every interface, random port).
        #[arg(long)]
        bind: Option<SocketAddr>,
        /// Direct connections only: no relays, no address lookup.
        #[arg(long)]
        no_relay: bool,
        /// Shell for new panes (default: $SHELL, then the passwd entry).
        #[arg(long)]
        shell: Option<PathBuf>,
    },
    /// Print a one-time pairing ticket as text and QR code.
    Pair {
        /// Minutes the ticket stays valid.
        #[arg(long, default_value_t = 10)]
        minutes: u64,
        /// Print one JSON object (ticket, daemon id, expiry, addresses) instead, for tools
        /// such as the app's SSH bootstrap.
        #[arg(long)]
        json: bool,
        /// Wait up to this many seconds for a running daemon to record its endpoint (and
        /// its home relay) before minting, e.g. right after `service install`.
        #[arg(long, default_value_t = 0)]
        wait: u64,
    },
    /// Show whether the daemon is running.
    Status,
    /// Install or remove a per-user service that runs the daemon at login.
    Service {
        #[command(subcommand)]
        action: ServiceAction,
    },
}

#[derive(Subcommand)]
enum ServiceAction {
    /// Install and start (systemd --user on Linux, a LaunchAgent on macOS).
    Install,
    /// Stop and remove.
    Uninstall,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let state_dir = cli
        .state_dir
        .or_else(|| std::env::var_os(brand::env_var("STATE_DIR")).map(PathBuf::from))
        .unwrap_or_else(daemon::default_state_dir);
    match cli.command {
        Command::Run {
            bind,
            no_relay,
            shell,
        } => run(state_dir, bind, no_relay, shell),
        Command::Pair {
            minutes,
            json,
            wait,
        } => pair(
            &state_dir,
            Duration::from_secs(minutes * 60),
            json,
            Duration::from_secs(wait),
        ),
        Command::Status => status(&state_dir),
        Command::Service { action } => match action {
            ServiceAction::Install => service::install(&state_dir),
            ServiceAction::Uninstall => service::uninstall(),
        },
    }
}

fn run(
    state_dir: PathBuf,
    bind: Option<SocketAddr>,
    no_relay: bool,
    shell: Option<PathBuf>,
) -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env(brand::env_var("LOG"))
                .unwrap_or_else(|_| "info".into()),
        )
        .with_writer(std::io::stderr)
        .init();
    std::fs::create_dir_all(&state_dir)
        .with_context(|| format!("creating {}", state_dir.display()))?;
    let _lock = lock_instance(&state_dir)?;

    let mut config = Config::new(&state_dir);
    config.bind = bind;
    config.relay = if no_relay {
        RelayMode::Disabled
    } else {
        RelayMode::Default
    };
    config.shell = shell.or_else(login_shell);

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("hostd")
        .build()?;
    runtime.block_on(async move {
        let daemon = Daemon::start(config).await?;
        eprintln!(
            "{} {} serving as {}",
            brand::DAEMON_BIN,
            env!("CARGO_PKG_VERSION"),
            hex(&daemon.daemon_id().0)
        );
        if daemon.paired_devices() == 0 {
            daemon.wait_online(Duration::from_secs(5)).await;
            eprintln!(
                "No devices paired yet. Scan this with the app, or run `{} pair` later:",
                brand::DAEMON_BIN
            );
            print_ticket(&daemon.pairing_ticket(daemon::PAIRING_TTL)?.to_string());
        }
        wait_for_signal().await?;
        eprintln!("shutting down");
        daemon.shutdown().await;
        anyhow::Ok(())
    })
}

async fn wait_for_signal() -> Result<()> {
    use tokio::signal::unix::{SignalKind, signal};
    let mut term = signal(SignalKind::terminate())?;
    let mut int = signal(SignalKind::interrupt())?;
    // Ignore SIGHUP so closing the terminal that started us does not stop the panes.
    let mut hup = signal(SignalKind::hangup())?;
    loop {
        tokio::select! {
            _ = term.recv() => return Ok(()),
            _ = int.recv() => return Ok(()),
            _ = hup.recv() => continue,
        }
    }
}

/// Holds an exclusive lock on `<state>/hostd.lock` for the process lifetime, so two daemons
/// never share a key, socket and layout.
fn lock_instance(state_dir: &Path) -> Result<OwnedFd> {
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(state_dir.join("hostd.lock"))?;
    let fd = OwnedFd::from(file);
    if rustix::fs::flock(&fd, rustix::fs::FlockOperation::NonBlockingLockExclusive).is_err() {
        bail!(
            "another {} is already running with state dir {}",
            brand::DAEMON_BIN,
            state_dir.display()
        );
    }
    Ok(fd)
}

/// The user's login shell from the passwd database, for service managers that set no $SHELL.
fn login_shell() -> Option<PathBuf> {
    if let Some(shell) = std::env::var_os("SHELL").filter(|s| !s.is_empty()) {
        return Some(PathBuf::from(shell));
    }
    // SAFETY: getpwuid returns a pointer into static storage or NULL; we copy the string out
    // immediately and call nothing else in between.
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if pw.is_null() || (*pw).pw_shell.is_null() {
            return None;
        }
        let shell = std::ffi::CStr::from_ptr((*pw).pw_shell);
        Some(PathBuf::from(shell.to_string_lossy().into_owned()))
    }
}

fn pair(state_dir: &Path, ttl: Duration, json: bool, wait: Duration) -> Result<()> {
    if !wait.is_zero() {
        wait_for_endpoint(state_dir, wait)?;
    }
    let ticket = daemon::mint_ticket(state_dir, ttl)
        .with_context(|| format!("minting a ticket in {}", state_dir.display()))?;
    if json {
        let info = daemon::endpoint_info(state_dir)?;
        let out = serde_json::json!({
            "ticket": ticket.to_string(),
            "daemon_id": hex(&ticket.daemon_id.0),
            "expires_unix_ms": ticket.expires.0,
            "addrs": ticket.addrs,
            "relay_url": ticket.relay_url,
            "running": info.is_some_and(|i| pid_alive(i.pid)),
            "version": env!("CARGO_PKG_VERSION"),
        });
        println!("{out}");
        return Ok(());
    }
    if daemon::endpoint_info(state_dir)?.is_some_and(|info| !pid_alive(info.pid)) {
        eprintln!(
            "warning: the daemon is not running; start it with `{} run`",
            brand::DAEMON_BIN
        );
    }
    print_ticket(&ticket.to_string());
    eprintln!("Valid for {} minutes, for one device.", ttl.as_secs() / 60);
    Ok(())
}

/// Waits until a live daemon has recorded its endpoint, then (up to `RELAY_GRACE` longer)
/// until it has a home relay, so the ticket works from networks without a direct path.
fn wait_for_endpoint(state_dir: &Path, wait: Duration) -> Result<()> {
    const RELAY_GRACE: Duration = Duration::from_secs(10);
    let start = std::time::Instant::now();
    let mut live_since = None;
    loop {
        let info = daemon::endpoint_info(state_dir).ok().flatten();
        if let Some(info) = info.filter(|i| pid_alive(i.pid)) {
            let since = *live_since.get_or_insert_with(std::time::Instant::now);
            if info.relay_url.is_some() || since.elapsed() >= RELAY_GRACE {
                return Ok(());
            }
        }
        if start.elapsed() >= wait {
            if live_since.is_some() {
                return Ok(());
            }
            bail!(
                "no running {} recorded an endpoint in {} within {} s",
                brand::DAEMON_BIN,
                state_dir.display(),
                wait.as_secs()
            );
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Prints the ticket as a QR code (Unicode half blocks, works over SSH) and as text.
fn print_ticket(ticket: &str) {
    // Upper case lets the QR use alphanumeric mode, about 40 % smaller; parsing ignores case.
    match qrcode::QrCode::new(ticket.to_ascii_uppercase().as_bytes()) {
        Ok(code) => {
            let qr = code
                .render::<qrcode::render::unicode::Dense1x2>()
                .dark_color(qrcode::render::unicode::Dense1x2::Light)
                .light_color(qrcode::render::unicode::Dense1x2::Dark)
                .quiet_zone(true)
                .build();
            println!("{qr}");
        }
        Err(e) => eprintln!("(no QR code: {e})"),
    }
    println!("{ticket}");
}

fn status(state_dir: &Path) -> Result<()> {
    let Some(info) = daemon::endpoint_info(state_dir)? else {
        println!(
            "not running (never started with state dir {})",
            state_dir.display()
        );
        return Ok(());
    };
    let running = pid_alive(info.pid);
    println!(
        "{} (pid {}, state dir {})",
        if running { "running" } else { "not running" },
        info.pid,
        state_dir.display()
    );
    println!("daemon id: {}", info.daemon_id);
    for addr in &info.addrs {
        println!("address:   {addr}");
    }
    if let Some(relay) = &info.relay_url {
        println!("relay:     {relay}");
    }
    println!("paired devices: {}", daemon::paired_devices(state_dir)?);
    Ok(())
}

fn pid_alive(pid: u32) -> bool {
    // SAFETY: kill with signal 0 only checks for existence and permission.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
