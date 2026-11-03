//! `gudo-hostd`: the host daemon. A thin main over the `daemon` crate.
//!
//! ```text
//! gudo-hostd run                 serve until SIGINT/SIGTERM
//! gudo-hostd pair                print a one-time pairing ticket (text + QR)
//! gudo-hostd pair --json --wait 30   the same as JSON, once the daemon is up
//! gudo-hostd pair --uses 5 --minutes 1440   one ticket for up to 5 devices (a demo host)
//! gudo-hostd pair --list | --revoke <id|all>   the pending tickets; withdraw them
//! gudo-hostd status              is it running, where, how many devices
//! gudo-hostd devices [--json]    the paired owner devices: in a terminal, pair, rename, remove
//! gudo-hostd rename <key> <name> name one
//! gudo-hostd unpair <key>        remove one (a lost phone); live connections close at once
//! gudo-hostd service install     run at login (systemd --user / launchd)
//! gudo-hostd service uninstall
//! gudo-hostd build-info --json   this build (version, protocol level, OS, CPU, host name)
//! gudo-hostd licenses           third-party licence notices for this binary
//! gudo-hostd askpass <prompt>    the askpass helper (normally run as `gudo-hook askpass`)
//! ```
//!
//! `run` restarts itself in place (`exec`, same PID) when its owner installs a new build over
//! the connection (docs/DAEMON.md "Updating the daemon").
//!
//! Run through a link named `gudo` (the install script and the Mac app make one), it is the
//! same program under the short name: `gudo pair`, `gudo devices`.

mod askpass;
mod devices;
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
    /// State directory (keys, paired devices, layout). Defaults to `$GUDO_STATE_DIR`, then the
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
        /// Devices the ticket may pair, for a host shared on purpose such as a demo host.
        /// Anyone who sees it can pair until it expires, runs out or is revoked. Above 1 it
        /// lasts at most 30 days.
        #[arg(
            long,
            default_value_t = 1,
            value_parser = clap::value_parser!(u32).range(1..=i64::from(daemon::MAX_TICKET_USES)),
            conflicts_with = "local"
        )]
        uses: u32,
        /// List the pending tickets (never their secrets) instead.
        #[arg(long, conflicts_with_all = ["revoke", "local", "wait"])]
        list: bool,
        /// Withdraw the pending ticket with this id (see --list), or every one with `all`.
        /// Devices it paired stay paired; remove them with `unpair`.
        #[arg(long, value_name = "ID", conflicts_with_all = ["json", "local", "wait"])]
        revoke: Option<String>,
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
    /// Restart the running daemon into the build now installed at its path (after a package
    /// or app update), keeping its sessions running. Fails, changing nothing, when that build
    /// cannot take them over.
    Restart,
    /// The paired owner devices (guests are managed in the app). In a terminal: pair a new
    /// one, rename or remove them.
    Devices {
        /// Print one JSON array instead.
        #[arg(long)]
        json: bool,
    },
    /// Name a paired device, here and in the apps. An empty name goes back to the device's
    /// own.
    Rename {
        /// The device key, or its first 8 or more hex digits (see `devices`).
        device: String,
        /// The new name.
        #[arg(num_args = 0..)]
        name: Vec<String>,
    },
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
    if args.first().is_some_and(|arg| arg == "askpass") {
        std::process::exit(askpass::main(&args[1..]));
    }
    let cli = parse_cli();
    let state_dir = daemon::migrate::current_state_dir(
        cli.state_dir
            .or_else(|| brand::var_os("STATE_DIR").map(PathBuf::from))
            .unwrap_or_else(daemon::default_state_dir),
    );
    match cli.command {
        Command::Run {
            bind,
            no_relay,
            shell,
        } => run(state_dir, bind, no_relay, shell),
        Command::Pair {
            list: true, json, ..
        } => pending_tickets(&state_dir, json),
        Command::Pair {
            revoke: Some(id), ..
        } => revoke_tickets(&state_dir, &id),
        Command::Pair {
            minutes,
            uses,
            json,
            wait,
            local,
            ..
        } => pair(
            &state_dir,
            Duration::from_secs(minutes * 60),
            uses,
            json,
            Duration::from_secs(wait),
            local,
        ),
        Command::Status => status(&state_dir),
        Command::Restart => restart(&state_dir),
        Command::Devices { json } => devices::run(&state_dir, json),
        Command::Rename { device, name } => devices::rename(&state_dir, &device, &name.join(" ")),
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

/// The arguments, under the short name when run through a link named [`brand::CLI_BIN`].
fn parse_cli() -> Cli {
    use clap::{CommandFactory, FromArgMatches};
    let invoked_as = std::env::args_os()
        .next()
        .map(PathBuf::from)
        .and_then(|path| path.file_name().map(|name| name.to_owned()));
    if invoked_as.as_deref() != Some(std::ffi::OsStr::new(brand::CLI_BIN)) {
        return Cli::parse();
    }
    let command = ["run", "build-info", "licenses"].into_iter().fold(
        Cli::command()
            .name(brand::CLI_BIN)
            .bin_name(brand::CLI_BIN)
            .about("Pair and manage the devices that open this computer in Gudo"),
        |command, hidden| command.mut_subcommand(hidden, |subcommand| subcommand.hide(true)),
    );
    Cli::from_arg_matches(&command.get_matches()).unwrap_or_else(|error| error.exit())
}

fn run(
    state_dir: PathBuf,
    bind: Option<SocketAddr>,
    no_relay: bool,
    shell: Option<PathBuf>,
) -> Result<()> {
    // First, while this process has one thread and before it starts any program: what the
    // build this process ran before its `exec` handed over.
    let inherited = daemon::Inherited::claim();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env(brand::env_var("LOG"))
                .unwrap_or_else(|_| "info".into()),
        )
        .with_writer(std::io::stderr)
        .init();
    adopt_legacy_install(&state_dir)?;
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
    config.cli_exe = std::env::current_exe()
        .and_then(|exe| exe.canonicalize())
        .ok();
    config.exe.clone_from(&config.cli_exe);
    if let Some(inherited) = &inherited {
        tracing::info!(
            panes = inherited.panes(),
            "continuing the panes of the previous build"
        );
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("hostd")
        .build()?;
    runtime.block_on(async move {
        let daemon = Daemon::start_inheriting(config, inherited).await?;
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
        let Some(exe) = restart else {
            daemon.shutdown().await;
            return anyhow::Ok(());
        };
        let hand_off = if daemon.successor_adopts() {
            daemon.hand_off().await
        } else {
            daemon.shutdown().await;
            None
        };
        restart_into(&exe, hand_off)
    })
}

/// Takes over an install made under the product's earlier name: its state and config
/// directories move to today's, and a build that runs under the old binary name as the old
/// service (it was just upgraded in place) installs itself under today's name and hands over
/// to the new service, which ends this process.
fn adopt_legacy_install(state_dir: &Path) -> Result<()> {
    // Before the move: the executable may live inside the old state directory.
    let exe = upgradable_exe();
    if daemon::migrate::adopt_legacy_state(state_dir, Duration::from_secs(10))? {
        eprintln!("moved the earlier state into {}", state_dir.display());
    }
    let Some(mut exe) = exe else { return Ok(()) };
    if let Ok(rest) = exe.strip_prefix(daemon::migrate::legacy_state_dir()) {
        exe = state_dir.join(rest);
    }
    if exe.file_name() != Some(std::ffi::OsStr::new(brand::legacy::DAEMON_BIN)) {
        // A newer build already took over: the old files next to it are left over.
        let old = exe.with_file_name(brand::legacy::DAEMON_BIN);
        let _ = std::fs::remove_file(daemon::upgrade_prev_path(&old));
        let _ = std::fs::remove_file(old);
        return Ok(());
    }
    if !service::legacy_installed() {
        return Ok(());
    }
    let new = exe.with_file_name(brand::DAEMON_BIN);
    std::fs::copy(&exe, &new).with_context(|| format!("installing {}", new.display()))?;
    eprintln!("handing over to the {} service", brand::DAEMON_BIN);
    service::hand_over(&new, state_dir)?;
    std::process::exit(0)
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
    let parts: Vec<_> = exe
        .components()
        .map(|component| component.as_os_str())
        .collect();
    parts
        .windows(2)
        .any(|pair| pair[0].to_string_lossy().ends_with(".app") && pair[1] == "Contents")
}

/// Replaces this process with `exe` and the same arguments (same PID, so systemd or launchd
/// keep supervising it, and the panes' programs stay its children). With a hand-off the new
/// build continues the running panes. Falls back to the previous build if the new one cannot
/// be executed, and exits with an error (the service manager restarts it) if neither can,
/// after ending the panes it would have handed over.
fn restart_into(exe: &Path, hand_off: Option<daemon::HandOff>) -> ! {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let hand_off = hand_off.and_then(|hand_off| match hand_off.prepare_exec() {
        Ok(()) => Some(hand_off),
        Err(error) => {
            eprintln!("could not pass the running panes on: {error}");
            hand_off.abandon();
            None
        }
    });
    let handed_env = hand_off.as_ref().map(daemon::HandOff::env);
    let error = exec(exe, &args, handed_env.as_ref());
    eprintln!("could not start the new build {}: {error}", exe.display());
    let previous = daemon::upgrade_prev_path(exe);
    if std::fs::rename(&previous, exe).is_ok() {
        let error = exec(exe, &args, handed_env.as_ref());
        eprintln!("could not start the previous build either: {error}");
    }
    if let Some(hand_off) = hand_off {
        hand_off.abandon();
    }
    std::process::exit(1)
}

/// `execve` with `exe` as argv[0], this process's environment and `extra` added to it;
/// returns only on failure.
///
/// Not `Command::exec`: it sets SIGPIPE back to the default before `execve` while the
/// runtime's other threads still run, so one writing to a closed socket or pipe in that window
/// kills the daemon instead of restarting it. Kept ignored, the new build inherits it ignored,
/// as Rust programs run anyway. `extra` is never set in this process's own environment, so
/// only the new build sees it.
fn exec(
    exe: &Path,
    args: &[std::ffi::OsString],
    extra: Option<&(std::ffi::OsString, std::ffi::OsString)>,
) -> std::io::Error {
    use std::ffi::{CString, OsStr, OsString};
    use std::os::unix::ffi::OsStrExt;
    let c_string = |text: &OsStr| CString::new(text.as_bytes());
    let Ok(argv) = std::iter::once(exe.as_os_str())
        .chain(args.iter().map(|arg| arg.as_os_str()))
        .map(c_string)
        .collect::<Result<Vec<_>, _>>()
    else {
        return std::io::ErrorKind::InvalidInput.into();
    };
    let assignment = |name: &OsStr, value: &OsStr| {
        let mut pair = OsString::from(name);
        pair.push("=");
        pair.push(value);
        pair
    };
    let Ok(envp) = std::env::vars_os()
        .filter(|(name, _)| extra.is_none_or(|(extra_name, _)| name != extra_name))
        .map(|(name, value)| assignment(&name, &value))
        .chain(extra.map(|(name, value)| assignment(name, value)))
        .map(|pair| c_string(&pair))
        .collect::<Result<Vec<_>, _>>()
    else {
        return std::io::ErrorKind::InvalidInput.into();
    };
    let mut arg_pointers: Vec<*const libc::c_char> = argv.iter().map(|arg| arg.as_ptr()).collect();
    arg_pointers.push(std::ptr::null());
    let mut env_pointers: Vec<*const libc::c_char> =
        envp.iter().map(|pair| pair.as_ptr()).collect();
    env_pointers.push(std::ptr::null());
    // SAFETY: `argv[0]` and every pointer are NUL-terminated strings that outlive the call,
    // and both arrays end with a null pointer.
    unsafe {
        libc::execve(
            argv[0].as_ptr(),
            arg_pointers.as_ptr(),
            env_pointers.as_ptr(),
        )
    };
    std::io::Error::last_os_error()
}

fn build_info(json: bool) -> Result<()> {
    let info = daemon::info::build_info(proto::DaemonFeatures::EMPTY);
    if json {
        // The hand-off formats it reads: a running daemon hands its panes only to a build
        // that reads its own.
        let mut object = serde_json::to_value(&info)?;
        object["handoff"] = serde_json::json!(daemon::HANDOFF_READS);
        println!("{object}");
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
    let mut sigterm = signal(SignalKind::terminate())?;
    let mut sigint = signal(SignalKind::interrupt())?;
    // Ignore SIGHUP so closing the terminal that started us does not stop the panes.
    let mut sighup = signal(SignalKind::hangup())?;
    loop {
        tokio::select! {
            _ = sigterm.recv() => return Ok(()),
            _ = sigint.recv() => return Ok(()),
            _ = sighup.recv() => continue,
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
    if let Some(shell) = std::env::var_os("SHELL").filter(|shell| !shell.is_empty()) {
        return Some(PathBuf::from(shell));
    }
    // SAFETY: getpwuid returns a pointer into static storage or NULL; we copy the string out
    // immediately and call nothing else in between.
    unsafe {
        let passwd = libc::getpwuid(libc::getuid());
        if passwd.is_null() || (*passwd).pw_shell.is_null() {
            return None;
        }
        let shell = std::ffi::CStr::from_ptr((*passwd).pw_shell);
        Some(PathBuf::from(shell.to_string_lossy().into_owned()))
    }
}

fn pair(
    state_dir: &Path,
    ttl: Duration,
    uses: u32,
    json: bool,
    wait: Duration,
    local: bool,
) -> Result<()> {
    if !wait.is_zero() {
        wait_for_endpoint(state_dir, wait)?;
    }
    let minted = if uses > 1 {
        daemon::mint_reusable_ticket_text(state_dir, ttl, uses).map(|(text, id)| (text, Some(id)))
    } else if local {
        daemon::mint_this_computer_ticket_text(state_dir, ttl).map(|text| (text, None))
    } else {
        daemon::mint_ticket_text(state_dir, ttl).map(|text| (text, None))
    };
    let (mut text, reusable_id) =
        minted.with_context(|| format!("minting a ticket in {}", state_dir.display()))?;
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
            "running": info.is_some_and(|info| pid_alive(info.pid)),
            "version": env!("CARGO_PKG_VERSION"),
            "uses": uses,
            "ticket_id": reusable_id,
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
    eprintln!("On your iPhone or iPad, open Gudo, tap Add Host, then Scan.");
    match reusable_id {
        None => eprintln!("Valid for {} minutes, for one device.", ttl.as_secs() / 60),
        Some(id) => {
            eprintln!(
                "Valid for {}, for up to {uses} devices. Anyone with this code can pair.",
                lifetime_label(ttl.as_secs() / 60)
            );
            eprintln!(
                "Ticket {id}. Revoke it with `{} pair --revoke {id}`.",
                brand::CLI_BIN
            );
        }
    }
    Ok(())
}

fn pending_tickets(state_dir: &Path, json: bool) -> Result<()> {
    let tickets = daemon::pending_pairing_tickets(state_dir)
        .with_context(|| format!("reading tickets in {}", state_dir.display()))?;
    if json {
        let list: Vec<_> = tickets
            .iter()
            .map(|ticket| {
                serde_json::json!({
                    "id": ticket.id,
                    "uses": ticket.uses,
                    "used": ticket.used,
                    "expires_unix_ms": ticket.expires,
                    "this_computer": ticket.this_computer,
                })
            })
            .collect();
        println!("{}", serde_json::Value::Array(list));
        return Ok(());
    }
    if tickets.is_empty() {
        println!("No pending tickets.");
        return Ok(());
    }
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as u64);
    println!("{:<10}{:<8}EXPIRES", "ID", "USED");
    for ticket in &tickets {
        let id = if ticket.id.is_empty() {
            "-"
        } else {
            &ticket.id
        };
        println!(
            "{:<10}{:<8}in {}",
            id,
            format!("{}/{}", ticket.used, ticket.uses),
            lifetime_label(ticket.expires.saturating_sub(now_ms).div_ceil(60_000))
        );
    }
    Ok(())
}

fn revoke_tickets(state_dir: &Path, id: &str) -> Result<()> {
    let id = (!id.eq_ignore_ascii_case("all")).then_some(id);
    let revoked = daemon::revoke_pairing_tickets(state_dir, id)
        .with_context(|| format!("revoking tickets in {}", state_dir.display()))?;
    println!(
        "revoked {revoked} {}",
        if revoked == 1 { "ticket" } else { "tickets" }
    );
    Ok(())
}

/// "under a minute", "45 minutes", "6 hours", "30 days".
fn lifetime_label(minutes: u64) -> String {
    match minutes {
        0 => "under a minute".into(),
        1 => "1 minute".into(),
        2..120 => format!("{minutes} minutes"),
        120..2880 => format!("{} hours", minutes / 60),
        _ => format!("{} days", minutes / 1440),
    }
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
        if let Some(info) = info.filter(|info| pid_alive(info.pid)) {
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
    for line in qr_lines(ticket) {
        println!("{line}");
    }
    println!("{ticket}");
}

/// The ticket as QR code lines of Unicode half blocks; none if it cannot be encoded.
fn qr_lines(ticket: &str) -> Vec<String> {
    // Upper case lets the QR use alphanumeric mode, about 40 % smaller; parsing ignores case.
    match qrcode::QrCode::new(ticket.to_ascii_uppercase().as_bytes()) {
        Ok(code) => code
            .render::<qrcode::render::unicode::Dense1x2>()
            .dark_color(qrcode::render::unicode::Dense1x2::Light)
            .light_color(qrcode::render::unicode::Dense1x2::Dark)
            .quiet_zone(true)
            .build()
            .lines()
            .map(str::to_owned)
            .collect(),
        Err(_) => Vec::new(),
    }
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

/// Asks the running daemon over its hook socket to restart into the installed build and
/// waits until it has (same process, started again).
fn restart(state_dir: &Path) -> Result<()> {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::ffi::OsStrExt;
    const ANSWER_TIMEOUT: Duration = Duration::from_secs(30);
    const RESTART_TIMEOUT: Duration = Duration::from_secs(60);
    let before = daemon::endpoint_info(state_dir)?
        .filter(|info| pid_alive(info.pid))
        .with_context(|| {
            format!(
                "no daemon is running with state dir {}",
                state_dir.display()
            )
        })?;
    let socket = std::fs::read(state_dir.join("hook.endpoint"))
        .map(|bytes| PathBuf::from(std::ffi::OsStr::from_bytes(&bytes)))
        .context("reading the daemon's socket")?;
    let token = std::fs::read_to_string(state_dir.join("hook.token"))
        .context("reading the daemon's token")?;
    let mut stream = std::os::unix::net::UnixStream::connect(&socket)
        .with_context(|| format!("connecting to {}", socket.display()))?;
    stream.set_read_timeout(Some(ANSWER_TIMEOUT))?;
    let call = daemon::RestartCall {
        restart: daemon::RestartAsk {
            token: token.trim().to_owned(),
        },
    };
    let mut line = serde_json::to_vec(&call)?;
    line.push(b'\n');
    stream.write_all(&line)?;
    let mut answer = String::new();
    BufReader::new(&stream).read_line(&mut answer)?;
    let reply: daemon::RestartReply = serde_json::from_str(&answer).map_err(|_| {
        anyhow::anyhow!("the running daemon cannot restart in place; restart it to update")
    })?;
    match reply {
        daemon::RestartReply::Current => {
            println!("already running the installed build");
            Ok(())
        }
        daemon::RestartReply::Refused(reason) => bail!("{reason}"),
        daemon::RestartReply::Restarting => {
            let start = std::time::Instant::now();
            while start.elapsed() < RESTART_TIMEOUT {
                std::thread::sleep(Duration::from_millis(100));
                let now = daemon::endpoint_info(state_dir).ok().flatten();
                match now {
                    Some(info) if info.pid == before.pid && info.started_at > before.started_at => {
                        println!("restarted into the installed build (pid {})", info.pid);
                        return Ok(());
                    }
                    _ if !pid_alive(before.pid) => bail!("the daemon stopped while restarting"),
                    _ => {}
                }
            }
            bail!(
                "the daemon did not come back within {} s",
                RESTART_TIMEOUT.as_secs()
            )
        }
    }
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
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_bundles_are_not_upgraded_in_place() {
        assert!(in_app_bundle(Path::new(
            "/Applications/X.app/Contents/MacOS/gudo-hostd"
        )));
        assert!(!in_app_bundle(Path::new("/home/u/.local/bin/gudo-hostd")));
        assert!(!in_app_bundle(Path::new("/opt/Contents/X.app/hostd")));
    }

    /// The restart keeps SIGPIPE ignored through `exec`, so no thread writing to a closed
    /// socket in the meantime can kill the daemon: the program it becomes still has it ignored.
    #[test]
    fn exec_keeps_sigpipe_ignored() {
        const CHILD: &str = "HOSTD_TEST_EXEC_CHILD";
        if std::env::var_os(CHILD).is_some() {
            // In the re-run test binary: become a shell that sends itself SIGPIPE.
            let error = exec(
                Path::new("/bin/sh"),
                &["-c".into(), "kill -PIPE $$; exit 7".into()],
                None,
            );
            panic!("exec failed: {error}");
        }
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "tests::exec_keeps_sigpipe_ignored",
                "--nocapture",
            ])
            .env(CHILD, "1")
            .stdout(std::process::Stdio::null())
            .status()
            .unwrap();
        assert_eq!(
            status.code(),
            Some(7),
            "SIGPIPE stays ignored through exec: {status}"
        );
    }

    /// The hand-off variable reaches the new program (replacing a stale value), along with
    /// the rest of the environment.
    #[test]
    fn exec_adds_the_variable_to_the_environment() {
        const CHILD: &str = "HOSTD_TEST_EXEC_ENV_CHILD";
        if std::env::var_os(CHILD).is_some() {
            let extra = ("HOSTD_TEST_EXTRA".into(), "new".into());
            let error = exec(
                Path::new("/bin/sh"),
                &[
                    "-c".into(),
                    "[ \"$HOSTD_TEST_EXTRA\" = new ] && [ \"$HOSTD_TEST_KEPT\" = kept ] && exit 7"
                        .into(),
                ],
                Some(&extra),
            );
            panic!("exec failed: {error}");
        }
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "tests::exec_adds_the_variable_to_the_environment",
                "--nocapture",
            ])
            .env(CHILD, "1")
            .env("HOSTD_TEST_EXTRA", "stale")
            .env("HOSTD_TEST_KEPT", "kept")
            .stdout(std::process::Stdio::null())
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(7), "{status}");
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
