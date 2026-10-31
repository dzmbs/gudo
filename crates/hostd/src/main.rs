//! `unnamed-hostd`: the host daemon. A thin main over the `daemon` crate.
//!
//! ```text
//! unnamed-hostd run                 serve until SIGINT/SIGTERM
//! unnamed-hostd pair                print a one-time pairing ticket (text + QR)
//! unnamed-hostd pair --json --wait 30   the same as JSON, once the daemon is up
//! unnamed-hostd status              is it running, where, how many devices
//! unnamed-hostd devices             the paired owner devices
//! unnamed-hostd unpair <key>        remove one (a lost phone); live connections close at once
//! unnamed-hostd service install     run at login (systemd --user / launchd)
//! unnamed-hostd service uninstall
//! unnamed-hostd build-info --json   this build (version, protocol level, OS, CPU, host name)
//! unnamed-hostd licenses           third-party licence notices for this binary
//! unnamed-hostd askpass <prompt>    the askpass helper (normally run as `un-hook askpass`)
//! ```
//!
//! `run` restarts itself in place (`exec`, same PID) when its owner installs a new build over
//! the connection (docs/DAEMON.md "Updating the daemon").

mod askpass;
mod service;

use std::fs::OpenOptions;
use std::io::IsTerminal;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
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
        /// Also list loopback addresses, for an app on this machine: it reaches the daemon
        /// even with no network.
        #[arg(long)]
        local: bool,
    },
    /// Show whether the daemon is running.
    Status,
    /// List the paired owner devices (guests are managed in the app).
    Devices,
    /// Remove a paired device, for example a lost phone: its connections close within a
    /// second, invites it signed stop working, and it needs a new ticket to come back.
    Unpair {
        /// The device key, or its first 8 or more hex digits (see `devices`).
        device: String,
    },
    /// Install or remove a per-user service that runs the daemon at login.
    Service {
        #[command(subcommand)]
        action: ServiceAction,
    },
    /// Print this build's version, protocol level, OS, CPU and the host name. A running daemon
    /// runs a new build with this before switching to it.
    BuildInfo {
        /// One JSON object instead of text.
        #[arg(long)]
        json: bool,
    },
    /// Print the licence notices of the third-party code in this binary.
    Licenses,
}

#[derive(Subcommand)]
enum ServiceAction {
    /// Install and start (systemd --user on Linux, a LaunchAgent on macOS).
    Install,
    /// Stop and remove.
    Uninstall,
}

fn main() -> Result<()> {
    // Not a clap subcommand: the prompt is free text that may start with `-`.
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|a| a == "askpass") {
        std::process::exit(askpass::main(&args[1..]));
    }
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
            local,
        } => pair(
            &state_dir,
            Duration::from_secs(minutes * 60),
            json,
            Duration::from_secs(wait),
            local,
        ),
        Command::Status => status(&state_dir),
        Command::Devices => devices(&state_dir),
        Command::Unpair { device } => {
            let removed = daemon::unpair_device(&state_dir, &device)
                .with_context(|| format!("unpairing in {}", state_dir.display()))?;
            println!("unpaired {}", removed.device);
            Ok(())
        }
        Command::BuildInfo { json } => build_info(json),
        Command::Licenses => {
            // Generated by `cargo xtask notices`.
            print!("{}", include_str!("../THIRD_PARTY_NOTICES.txt"));
            Ok(())
        }
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
    // Captured now: once a new build is renamed over this file, /proc/self/exe reads
    // "… (deleted)".
    let exe = upgradable_exe();
    config.self_exe.clone_from(&exe);

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
            // A ticket makes its holder an owner: only to a person at a terminal, never into
            // a service's log file or journal, which others may read.
            if std::io::stderr().is_terminal() {
                daemon.wait_online(Duration::from_secs(5)).await;
                eprintln!(
                    "No devices paired yet. Scan this with the app, or run `{} pair` later:",
                    brand::DAEMON_BIN
                );
                print_ticket(&daemon.pairing_link(daemon::PAIRING_TTL)?);
            } else {
                eprintln!(
                    "No devices paired yet: run `{} pair` to pair one.",
                    brand::DAEMON_BIN
                );
            }
        }
        let restart = tokio::select! {
            signal = wait_for_signal() => {
                signal?;
                None
            }
            exe = daemon.restart_requested() => Some(exe),
        };
        eprintln!(
            "{}",
            if restart.is_some() {
                "restarting into the new build"
            } else {
                "shutting down"
            }
        );
        daemon.shutdown().await;
        if let Some(exe) = restart {
            restart_into(&exe);
        }
        anyhow::Ok(())
    })
}

/// The executable, if the daemon may replace it: it exists, its directory is writable (the new
/// build is written next to it and renamed over it), and it is not inside an app bundle, whose
/// signature a swapped binary would break (the app updates its own helper).
fn upgradable_exe() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    if in_app_bundle(&exe) {
        return None;
    }
    let dir = exe.parent()?;
    rustix::fs::access(dir, rustix::fs::Access::WRITE_OK).ok()?;
    Some(exe)
}

/// Whether `exe` lives in a macOS app bundle (`….app/Contents/…`).
fn in_app_bundle(exe: &Path) -> bool {
    let parts: Vec<_> = exe.components().map(|c| c.as_os_str()).collect();
    parts
        .windows(2)
        .any(|pair| pair[0].to_string_lossy().ends_with(".app") && pair[1] == "Contents")
}

/// Replaces this process with `exe` and the same arguments (same PID, so systemd or launchd
/// keep supervising it). Falls back to the previous build if the new one cannot be executed,
/// and exits with an error (the service manager restarts it) if neither can.
fn restart_into(exe: &Path) -> ! {
    use std::os::unix::process::CommandExt;
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let err = std::process::Command::new(exe).args(&args).exec();
    eprintln!("could not start the new build {}: {err}", exe.display());
    let prev = daemon::upgrade_prev_path(exe);
    if std::fs::rename(&prev, exe).is_ok() {
        let err = std::process::Command::new(exe).args(&args).exec();
        eprintln!("could not start the previous build either: {err}");
    }
    std::process::exit(1)
}

fn build_info(json: bool) -> Result<()> {
    let info = daemon::info::build_info(proto::DaemonFeatures::EMPTY);
    if json {
        println!("{}", serde_json::to_string(&info)?);
    } else {
        println!("{} {} ({})", brand::DAEMON_BIN, info.version, info.build);
        println!(
            "protocol:  {} (serves clients from {})",
            info.protocol, info.min_client_protocol
        );
        println!("platform:  {} {} {}", info.os, info.arch, info.os_name);
        println!("host name: {}", info.hostname);
    }
    Ok(())
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

fn pair(state_dir: &Path, ttl: Duration, json: bool, wait: Duration, local: bool) -> Result<()> {
    if !wait.is_zero() {
        wait_for_endpoint(state_dir, wait)?;
    }
    let mut text = daemon::mint_ticket_text(state_dir, ttl)
        .with_context(|| format!("minting a ticket in {}", state_dir.display()))?;
    let (mut ticket, extras) = proto::Ticket::parse_with_extras(&text)?;
    if local {
        let bound = daemon::endpoint_info(state_dir)?
            .map(|info| info.bound)
            .unwrap_or_default();
        let loopback: Vec<_> = loopback_addrs(&bound)
            .into_iter()
            .filter(|addr| !ticket.addrs.contains(addr))
            .collect();
        ticket.addrs.splice(0..0, loopback);
        text = ticket.to_string_with(&extras);
    }
    if json {
        let info = daemon::endpoint_info(state_dir)?;
        let out = serde_json::json!({
            "ticket": text,
            "daemon_id": hex(&ticket.daemon_id.0),
            "expires_unix_ms": ticket.expires.0,
            "addrs": ticket.addrs,
            "relay_url": ticket.relay_url,
            "relays": relays_label(&extras.relays),
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
    print_ticket(&text);
    eprintln!("Valid for {} minutes, for one device.", ttl.as_secs() / 60);
    Ok(())
}

/// Loopback addresses on the ports of the sockets bound on every interface (or on loopback).
fn loopback_addrs(bound: &[SocketAddr]) -> Vec<SocketAddr> {
    bound
        .iter()
        .filter(|addr| addr.ip().is_unspecified() || addr.ip().is_loopback())
        .map(|addr| {
            let ip: IpAddr = if addr.is_ipv4() {
                Ipv4Addr::LOCALHOST.into()
            } else {
                Ipv6Addr::LOCALHOST.into()
            };
            SocketAddr::new(ip, addr.port())
        })
        .collect()
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
    println!("relays:    {}", relays_label(&info.relays));
    if let Some(relay) = &info.relay_url {
        println!("relay:     {relay}");
    }
    println!("paired devices: {}", daemon::paired_devices(state_dir)?);
    Ok(())
}

fn devices(state_dir: &Path) -> Result<()> {
    let devices = daemon::list_paired(state_dir)?;
    if devices.is_empty() {
        println!("no paired devices; run `{} pair`", brand::DAEMON_BIN);
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    for d in devices {
        let days = now.saturating_sub(d.paired_at) / 86_400_000;
        println!("{}  paired {days} day(s) ago", d.device);
    }
    Ok(())
}

fn relays_label(relays: &proto::TicketRelays) -> String {
    match relays {
        proto::TicketRelays::Default => "default".into(),
        proto::TicketRelays::Disabled => "none (local only)".into(),
        proto::TicketRelays::Custom { urls, .. } => format!("self-hosted ({})", urls.join(", ")),
    }
}

fn pid_alive(pid: u32) -> bool {
    // SAFETY: kill with signal 0 only checks for existence and permission.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_bundles_are_not_upgraded_in_place() {
        assert!(in_app_bundle(Path::new(
            "/Applications/X.app/Contents/MacOS/unnamed-hostd"
        )));
        assert!(!in_app_bundle(Path::new(
            "/home/u/.local/bin/unnamed-hostd"
        )));
        assert!(!in_app_bundle(Path::new("/opt/Contents/X.app/hostd")));
    }

    #[test]
    fn loopback_addresses_follow_the_bound_ports() {
        let bound = [
            "0.0.0.0:4100".parse().unwrap(),
            "[::]:4101".parse().unwrap(),
            "192.168.1.2:4102".parse().unwrap(),
        ];
        assert_eq!(
            loopback_addrs(&bound),
            [
                "127.0.0.1:4100".parse::<SocketAddr>().unwrap(),
                "[::1]:4101".parse().unwrap()
            ]
        );
    }
}
