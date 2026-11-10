//! The host daemon as a library: sessions, tabs and split trees of PTY panes, each mirrored
//! into an authoritative libghostty-vt terminal, served to clients over iroh (QUIC).
//!
//! Architecture and threading are described in `docs/DAEMON.md`. In short:
//!
//! - [`Daemon::start`] loads the identity and saved layout from the state directory, respawns
//!   panes (agents resume their sessions), binds the iroh endpoint ([`brand::ALPN`]) and the
//!   agent hook socket, and serves until [`Daemon::shutdown`].
//! - Each pane has two PTY threads (I/O, wait) from the `pty` crate; the I/O thread feeds the
//!   pane's VT through the output hook. Everything else runs on tokio.
//! - Each connection has a `ctl` reader and writer, an `input` reader and one task per
//!   subscribed pane stream, which applies the unacked budget and snapshot rate limits.
//!
//! # Examples
//!
//! ```no_run
//! # async fn demo() -> Result<(), daemon::StartError> {
//! let mut config = daemon::Config::new(daemon::default_state_dir());
//! config.relay = daemon::RelayMode::Disabled;
//! let daemon = daemon::Daemon::start(config).await?;
//! println!("{}", daemon.pairing_ticket(daemon::PAIRING_TTL)?);
//! daemon.shutdown().await;
//! # Ok(())
//! # }
//! ```

mod accounts;
mod agent;
mod agent_driver;
pub mod agent_input;
mod agent_integration;
mod anchor;
mod approve;
mod art;
mod askpass;
mod assist;
mod browser;
mod claude_display;
mod claude_session;
mod clock;
mod codex_session;
mod commands;
mod config;
mod conn;
mod core;
mod forward;
mod fsutil;
mod handoff;
mod hook_launcher;
mod identity;
mod input;
mod layout;
mod limits;
mod loopback_port;
pub mod migrate;
mod mp;
mod net;
mod notifier;
mod osc;
mod pane;
mod persist;
mod power;
mod preauth;
mod procinfo;
mod resumable;
mod resume;
mod scan;
mod screens;
mod shell;
mod sizing;
mod stream;
mod term;
mod theme;
mod timeline;
mod upgrade;
mod usage;
mod ws;

pub mod info;

use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use iroh::Endpoint;
use iroh::endpoint::presets;
use proto::{DaemonId, DeviceId, Ticket};
use tokio::task::JoinHandle;

pub use agent::{HookRequest, HookResponse, PERMISSION_WAIT, STATUS_LINE_EVENT};
pub use agent_integration::install_agent_integration;
pub use agents::CODEX_NOTIFY_EVENT;
pub use art::pull::{
    PULL_FORMATS, PULL_MAX, PULL_VERSION, PullCall, PullExport, PullFormat, PullOp, PullReply,
    PullSummary,
};
pub use askpass::{ASKPASS_VERSION, AskpassCall, HelperQuery, HelperReply};
pub use assist::HistoryConfig;
pub use browser::{
    BROWSER_VERSION, BrowserAsk, BrowserCall, BrowserReply, CALL_TIMEOUT as BROWSER_CALL_TIMEOUT,
};
pub use clock::boot_nanos as hook_seq;
pub use config::{
    AgentIntegration, ArtifactLimits, AskpassConfig, Config, RelayMode, default_state_dir,
};
pub use config::{CustomRelays, PresenceTimes, PushConfig, RepoConfig};
pub use fsutil::create_private_temp_file;
pub use handoff::{HANDOFF_ENV, HANDOFF_READS, HANDOFF_VERSION, HandOff, Inherited};
pub use identity::{
    DEVICE_NAME_MAX, EndpointInfo, MAX_REUSABLE_TICKET_TTL, MAX_TICKET_USES, PAIRING_TTL,
    PairedDevice, PendingTicket, clean_display_name, endpoint_info, list_paired,
    mint_reusable_ticket_text, mint_this_computer_ticket_text, mint_ticket, mint_ticket_text,
    paired_devices, pending_pairing_tickets, rename_device, revoke_pairing_tickets, unpair_device,
};
pub use preauth::PreAuthLimits;
pub use procinfo::inherited_env_var;
pub use term::SOURCE_SHARED as TERM_SOURCE_SHARED;
pub use term::{ErrorCode as TermErrorCode, TERM_VERSION, TermAsk, TermCall, TermReply, ToolError};
pub use upgrade::prev_path as upgrade_prev_path;
pub use upgrade::{RestartAsk, RestartCall, RestartReply};
pub use usage::UsageConfig;
pub use ws::Policy as PathPolicy;

use crate::agent::HookServer;
use crate::core::Core;
use crate::identity::Identity;

/// Why the daemon could not start.
#[derive(Debug, thiserror::Error)]
pub enum StartError {
    /// Reading or writing the state directory, or binding the hook socket, failed.
    #[error("state directory: {0}")]
    Io(#[from] io::Error),
    /// The iroh endpoint could not be bound.
    #[error("binding the iroh endpoint: {0}")]
    Bind(String),
}

/// A running daemon.
pub struct Daemon {
    core: Arc<Core>,
    endpoint: Endpoint,
    tasks: Vec<JoinHandle<()>>,
}

impl Daemon {
    /// Starts a daemon: restores the saved layout, binds the endpoint and serves clients.
    ///
    /// # Errors
    ///
    /// Returns [`StartError`] if the state directory is unusable or the endpoint cannot bind.
    pub async fn start(config: Config) -> Result<Self, StartError> {
        Self::start_inheriting(config, None).await
    }

    /// Like [`start`](Self::start), continuing the panes the previous build of this process
    /// handed over before its `exec` ([`Inherited::claim`]): same programs, screens, history
    /// and stream offsets, so clients resume as after a network change. Panes it cannot
    /// continue end as closed panes do and start afresh, as after a plain restart.
    ///
    /// # Errors
    ///
    /// As for [`start`](Self::start); the inherited panes have been ended then.
    pub async fn start_inheriting(
        config: Config,
        inherited: Option<Inherited>,
    ) -> Result<Self, StartError> {
        let mut adopted = inherited.map(Inherited::read).unwrap_or_default();
        let started = Self::start_with(config, &mut adopted).await;
        adopted.abandon_rest();
        started
    }

    async fn start_with(
        mut config: Config,
        adopted: &mut handoff::Adopted,
    ) -> Result<Self, StartError> {
        limits::raise_fd_limit();
        agent_driver::codex::process::sweep_stale_directories(std::time::SystemTime::now());
        config.apply_user_file()?;
        config.hook_shim = Some(config.hook_bin());
        match hook_launcher::install(&config) {
            Ok(launcher) => config.hook_bin = Some(launcher),
            Err(error) => tracing::warn!("writing the hook launcher: {error}"),
        }
        let identity = Arc::new(Identity::load_or_create(&config.state_dir)?);
        let (creators, (layout, restore)) = match persist::load(&config.state_dir)? {
            Some(mut saved) => (saved.take_creators(), saved.into_parts()),
            None => Default::default(),
        };
        let mut hooks = HookServer::new(&config.state_dir, config.hook_bin())?;
        if config.claude_chat_streaming {
            match claude_display::http::HttpListener::bind(&config.state_dir) {
                Ok(listener) => {
                    tracing::debug!(endpoint = %listener.url(), "Claude display receiver ready");
                    hooks.display_http = Some(listener);
                }
                Err(error) => tracing::warn!(%error, "Claude live display is unavailable"),
            }
        }
        let shell = match shell::ShellIntegration::install(&config.state_dir) {
            Ok(mut integration) => {
                if let Some(exe) = &config.cli_exe
                    && let Err(error) = integration.link_cli(&config.state_dir, exe)
                {
                    tracing::warn!("linking {} for panes: {error}", brand::CLI_BIN);
                }
                Some(integration)
            }
            Err(error) => {
                tracing::warn!("installing shell integration scripts: {error}");
                None
            }
        };
        let mp = mp::Mp::open(
            &config.state_dir,
            Arc::clone(&identity),
            config.lease_idle,
            config.presence,
        )?;
        let core = Core::new(
            config,
            identity,
            layout,
            hooks,
            shell,
            mp,
            adopted.carried.epoch,
        );
        core.inputs
            .carry_on(std::mem::take(&mut adopted.carried.inputs));
        repair_hook_paths(&core);
        let mut tasks = vec![HookServer::listen(&core)?];
        if let Some(listener) = &core.hooks.display_http {
            tasks.push(listener.listen(&core)?);
        }
        core::restore(&core, restore, adopted);
        core.term
            .restore(creators, |pane| core.pane(pane).is_some());

        let endpoint = bind(&core).await?;
        let info = endpoint_info_of(&endpoint, &core.cfg.relay);
        identity::write_endpoint_info(&core.cfg.state_dir, &info)?;
        tracing::info!(
            daemon = %endpoint.id(),
            addrs = ?info.addrs,
            "listening"
        );
        tasks.push(tokio::spawn(track_addresses(
            Arc::clone(&core),
            endpoint.clone(),
        )));

        tasks.push(tokio::spawn(accept_loop(
            Arc::clone(&core),
            endpoint.clone(),
        )));
        tasks.push(tokio::spawn(power::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(persist::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(screens::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(ws::ports::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(ws::turns::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(ws::repo::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(notifier::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(term::events::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(mp::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(art::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(assist::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(ws::editor::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(ws::editor::prewarm_on_connect(Arc::clone(
            &core,
        ))));
        core.ws.tunnel.autostart(&core.cfg);
        core.mark_dirty();
        Ok(Self {
            core,
            endpoint,
            tasks,
        })
    }

    pub fn daemon_id(&self) -> DaemonId {
        self.core.identity.daemon_id()
    }

    /// The UDP sockets the endpoint is bound to.
    pub fn bound_sockets(&self) -> Vec<SocketAddr> {
        self.endpoint.bound_sockets()
    }

    /// The hook socket agents report to.
    pub fn hook_socket(&self) -> &std::path::Path {
        self.core.hooks.socket()
    }

    /// Waits (at most `timeout`) until the endpoint has a home relay, so a ticket minted next
    /// works across NATs. Returns at once with relays disabled.
    pub async fn wait_online(&self, timeout: Duration) {
        if self.core.cfg.relay != RelayMode::Disabled {
            let _ = tokio::time::timeout(timeout, self.endpoint.online()).await;
            let info = endpoint_info_of(&self.endpoint, &self.core.cfg.relay);
            if let Err(error) = identity::write_endpoint_info(&self.core.cfg.state_dir, &info) {
                tracing::warn!("recording endpoint: {error}");
            }
        }
    }

    /// Mints a one-time pairing ticket valid for `ttl`.
    ///
    /// # Errors
    ///
    /// Returns an error if the pairing state cannot be written.
    pub fn pairing_ticket(&self, ttl: Duration) -> io::Result<Ticket> {
        mint_ticket(&self.core.cfg.state_dir, ttl)
    }

    /// Mints a one-time pairing ticket valid for `ttl` and returns its text, with the
    /// daemon's relay choice (self-hosted relays, local-only) appended for the app.
    ///
    /// # Errors
    ///
    /// Returns an error if the pairing state cannot be written.
    pub fn pairing_link(&self, ttl: Duration) -> io::Result<String> {
        mint_ticket_text(&self.core.cfg.state_dir, ttl)
    }

    pub fn paired_devices(&self) -> usize {
        self.core.identity.device_count()
    }

    /// Resolves once the owner installed a new build of the daemon over a connection
    /// ([`Config::self_exe`], `proto::info`), with the executable to run instead. The host
    /// process then calls [`Daemon::shutdown`] (which saves the layout and stops the panes) and
    /// `exec`s it with its own arguments; never resolves otherwise.
    pub fn restart_requested(&self) -> impl Future<Output = std::path::PathBuf> + Send + 'static {
        self.core.upgrade.restart_requested()
    }

    /// This daemon's build and machine, as clients see it.
    pub fn info(&self) -> proto::DaemonInfo {
        conn::daemon_info(&self.core)
    }

    /// Whether the build [`restart_requested`](Self::restart_requested) names continues
    /// running panes ([`HANDOFF_READS`]); [`hand_off`](Self::hand_off) is only for one that
    /// does.
    pub fn successor_adopts(&self) -> bool {
        self.core.upgrade.successor_adopts()
    }

    /// Stops serving for the next build of this program, which this process becomes with
    /// `exec`, and leaves every pane's program running for it to continue
    /// ([`start_inheriting`](Self::start_inheriting)): saves the layout, closes connections,
    /// stops each PTY where its output stands and captures its terminal.
    ///
    /// Returns `None` after stopping the usual way ([`shutdown`](Self::shutdown): the panes
    /// end) if the hand-off could not be written. Dropping the [`HandOff`] without `exec`
    /// ends the panes too.
    pub async fn hand_off(self) -> Option<HandOff> {
        let mut file = match handoff::create_file(&self.core.cfg.state_dir) {
            Ok(file) => file,
            Err(error) => {
                tracing::warn!("cannot hand off the panes: {error}; they end");
                self.shutdown().await;
                return None;
            }
        };
        self.core.shutting_down.store(true, Ordering::Release);
        for task in &self.tasks {
            task.abort();
        }
        for (_, entry) in self.core.pane_entries() {
            entry.stop_task();
        }
        self.core.art.flush();
        if let Err(error) = persist::save(&self.core).await {
            tracing::warn!("saving layout on hand-off: {error}");
        }
        self.endpoint.close().await;
        self.core.ws.editors.stop_all().await;
        self.core.ws.tunnel.shutdown();
        let core = Arc::clone(&self.core);
        let carried = tokio::task::spawn_blocking(move || handoff::Carried {
            epoch: Some(core.epoch),
            inputs: core.inputs.applied(),
            panes: core.hand_off_panes(),
        })
        .await
        .unwrap_or_default();
        self.core.hooks.remove_socket();
        let masters: Vec<_> = carried
            .panes
            .iter()
            .map(|pane| (pane.state.pty.master, pane.state.pty.pid))
            .collect();
        let written =
            handoff::encode(&carried).and_then(|bytes| handoff::write_file(&mut file, &bytes));
        let hand_off = HandOff::new(file, masters, Arc::clone(&self.core));
        match written {
            Ok(()) => {
                tracing::info!(
                    panes = hand_off.panes(),
                    "handing the panes to the new build"
                );
                Some(hand_off)
            }
            Err(error) => {
                tracing::warn!("writing the hand-off: {error}; the panes end");
                tokio::task::spawn_blocking(move || hand_off.abandon())
                    .await
                    .ok();
                None
            }
        }
    }

    /// Stops serving: saves the layout, closes connections and hangs up every pane.
    pub async fn shutdown(self) {
        self.core.shutting_down.store(true, Ordering::Release);
        for task in &self.tasks {
            task.abort();
        }
        self.core.art.flush();
        let saving = Arc::clone(&self.core);
        let screens = tokio::task::spawn_blocking(move || saving.screens.save_all(&saving));
        let screens = match tokio::time::timeout(SHUTDOWN_SCREENS_WAIT, screens).await {
            Ok(_) => persist::ScreensSaving::Done,
            Err(_) => {
                tracing::warn!("saving the screens took too long; the newest may be missing");
                persist::ScreensSaving::StillRunning
            }
        };
        if let Err(error) = persist::save_on_shutdown(&self.core, screens).await {
            tracing::warn!("saving layout on shutdown: {error}");
        }
        self.endpoint.close().await;
        self.core.ws.editors.stop_all().await;
        self.core.ws.tunnel.shutdown();
        let panes: Vec<_> = self
            .core
            .pane_entries()
            .into_iter()
            .map(|(id, _)| id)
            .collect();
        self.core.kill_panes(&panes);
        self.core.hooks.remove_socket();
    }
}

/// How long shutdown waits for the panes' screens to be saved: well within the time a
/// service manager gives a stopping daemon (launchd's 20 s, systemd's 90 s).
const SHUTDOWN_SCREENS_WAIT: Duration = Duration::from_secs(5);

/// Points hook and MCP server paths that earlier daemons wrote at this daemon's launcher.
fn repair_hook_paths(core: &Core) {
    let config = &core.cfg;
    let home = config.home();
    let account_dirs = |agent: proto::AgentKind| -> Vec<std::path::PathBuf> {
        core.ws
            .accounts
            .list()
            .into_iter()
            .filter(|account| account.agent == agent && !account.is_system())
            .map(|account| core.ws.accounts.dir(agent, &account.id))
            .collect()
    };
    let system_dir = |var: &str| config.pane_var(var).map(std::path::PathBuf::from);
    let claude_configs: Vec<_> = std::iter::once(agents::ClaudeCode::user_config_file(
        &home,
        system_dir(agents::CLAUDE_DIR_VAR).as_deref(),
    ))
    .chain(
        account_dirs(proto::AgentKind::Claude)
            .iter()
            .map(|dir| agents::ClaudeCode::user_config_file(&home, Some(dir))),
    )
    .collect();
    let codex_configs: Vec<_> = std::iter::once(agents::Codex::config_file(
        &home,
        system_dir(agents::CODEX_DIR_VAR).as_deref(),
    ))
    .chain(
        account_dirs(proto::AgentKind::Codex)
            .iter()
            .map(|dir| agents::Codex::config_file(&home, Some(dir))),
    )
    .collect();
    hook_launcher::repair(
        &config.state_dir,
        &config.hook_bin(),
        &claude_configs,
        &codex_configs,
    );
}

async fn bind(core: &Core) -> Result<Endpoint, StartError> {
    // The ports the last run bound, so tickets already handed out still reach this daemon
    // directly. Taken by something else since: fresh ports (relays and address lookup still
    // find it; a direct-only device needs a new ticket).
    let previous = identity::endpoint_info(&core.cfg.state_dir)
        .ok()
        .flatten()
        .map(|info| info.bound)
        .unwrap_or_default();
    let wanted = sticky_binds(core.cfg.bind, &previous);
    if !wanted.is_empty() {
        let mut builder = endpoint_builder(core)?;
        for addr in &wanted {
            builder = builder
                .bind_addr(*addr)
                .map_err(|error| StartError::Bind(error.to_string()))?;
        }
        match builder.bind().await {
            Ok(endpoint) => return Ok(endpoint),
            Err(error) => tracing::warn!(
                ?wanted,
                "binding the previous ports failed, using new ones: {error}"
            ),
        }
    }
    let mut builder = endpoint_builder(core)?;
    if let Some(addr) = core.cfg.bind {
        builder = builder
            .bind_addr(addr)
            .map_err(|error| StartError::Bind(error.to_string()))?;
    }
    builder
        .bind()
        .await
        .map_err(|error| StartError::Bind(error.to_string()))
}

/// The sockets to bind so this run listens where the last one did: for `--bind` with port 0
/// (or the default `0.0.0.0` + `[::]`), the same address on the port the last run had for
/// that address family. Empty when there is nothing to reuse (first run, a fixed port).
fn sticky_binds(bind: Option<SocketAddr>, previous: &[SocketAddr]) -> Vec<SocketAddr> {
    let port_of = |v4: bool| {
        previous
            .iter()
            .find(|addr| addr.is_ipv4() == v4 && addr.port() != 0)
            .map(SocketAddr::port)
    };
    let wanted = match bind {
        Some(addr) if addr.port() != 0 => return Vec::new(),
        Some(addr) => vec![addr],
        None => vec![
            SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0)),
            SocketAddr::from((Ipv6Addr::UNSPECIFIED, 0)),
        ],
    };
    // Every family needs its old port (a run without IPv6 left none): otherwise the plain
    // bind below is just as good.
    wanted
        .into_iter()
        .map(|mut addr| {
            port_of(addr.is_ipv4()).map(|port| {
                addr.set_port(port);
                addr
            })
        })
        .collect::<Option<Vec<_>>>()
        .unwrap_or_default()
}

/// The product's own relay ([`brand::RELAY_URL`]), the default unless `config.toml` names others.
fn default_relays() -> iroh::RelayMap {
    iroh::RelayMap::try_from_iter([brand::RELAY_URL])
        .expect("the default relay URL parses")
        .with_auth_token(brand::RELAY_TOKEN.to_owned())
}

fn endpoint_builder(core: &Core) -> Result<iroh::endpoint::Builder, StartError> {
    let builder = match &core.cfg.relay {
        RelayMode::Default => {
            Endpoint::builder(presets::N0).relay_mode(iroh::RelayMode::Custom(default_relays()))
        }
        RelayMode::Disabled => Endpoint::builder(presets::Minimal),
        RelayMode::Custom(custom) => {
            let map = iroh::RelayMap::try_from_iter(custom.urls.iter().map(String::as_str))
                .map_err(|error| StartError::Bind(format!("relay urls: {error}")))?;
            let map = match &custom.auth_token {
                Some(token) => map.with_auth_token(token.clone()),
                None => map,
            };
            let mut builder =
                Endpoint::builder(presets::Minimal).relay_mode(iroh::RelayMode::Custom(map));
            if !custom.ca_files.is_empty() {
                let mut roots = Vec::new();
                for file in &custom.ca_files {
                    roots.extend(read_pem_certs(file)?);
                }
                builder = builder
                    .ca_tls_config(iroh::tls::CaTlsConfig::embedded().with_extra_roots(roots));
            }
            builder
        }
    };
    let builder = builder
        .secret_key(core.identity.secret.clone())
        .alpns(vec![proto::ALPN.to_vec(), proto::LEGACY_ALPN.to_vec()])
        .transport_config(transport_config());
    // A fixed `--bind` replaces the default sockets; `bind_addr` per family does the same.
    Ok(if core.cfg.bind.is_some() {
        builder.clear_ip_transports()
    } else {
        builder
    })
}

/// Keep-alive and idle timeout shared with the clients ([`proto::IDLE_TIMEOUT`]): a client that
/// vanished stops holding its attachment within seconds.
fn transport_config() -> iroh::endpoint::QuicTransportConfig {
    let idle = iroh::endpoint::IdleTimeout::try_from(proto::IDLE_TIMEOUT)
        .expect("the idle timeout fits QUIC's varint");
    iroh::endpoint::QuicTransportConfig::builder()
        .keep_alive_interval(proto::KEEP_ALIVE)
        .max_idle_timeout(Some(idle))
        .build()
}

fn read_pem_certs(
    path: &std::path::Path,
) -> Result<Vec<rustls_pki_types::CertificateDer<'static>>, StartError> {
    use rustls_pki_types::pem::PemObject;
    let certs = rustls_pki_types::CertificateDer::pem_file_iter(path)
        .and_then(|certs| certs.collect::<Result<Vec<_>, _>>())
        .map_err(|error| StartError::Bind(format!("relay CA file {}: {error}", path.display())))?;
    if certs.is_empty() {
        return Err(StartError::Bind(format!(
            "relay CA file {} has no certificates",
            path.display()
        )));
    }
    Ok(certs)
}

/// Keeps `endpoint.json` current as iroh learns addresses and picks a home relay, so tickets
/// minted by `hostd pair` carry what works now.
async fn track_addresses(core: Arc<Core>, endpoint: Endpoint) {
    use iroh::Watcher;
    let mut watcher = endpoint.watch_addr();
    while watcher.updated().await.is_ok() {
        let info = endpoint_info_of(&endpoint, &core.cfg.relay);
        tracing::debug!(addrs = ?info.addrs, relay = ?info.relay_url, "endpoint address changed");
        if let Err(error) = identity::write_endpoint_info(&core.cfg.state_dir, &info) {
            tracing::warn!("recording endpoint: {error}");
        }
    }
}

fn endpoint_info_of(endpoint: &Endpoint, relays: &RelayMode) -> EndpointInfo {
    let addr = endpoint.addr();
    let mut addrs: Vec<SocketAddr> = addr.ip_addrs().copied().collect();
    if addrs.is_empty() {
        addrs = endpoint
            .bound_sockets()
            .into_iter()
            .map(|mut addr| {
                if addr.ip().is_unspecified() {
                    addr.set_ip(IpAddr::V4(Ipv4Addr::LOCALHOST));
                }
                addr
            })
            .collect();
    }
    EndpointInfo {
        daemon_id: fsutil::hex(endpoint.id().as_bytes()),
        addrs,
        relay_url: addr.relay_urls().next().map(ToString::to_string),
        relays: relays.ticket_relays(),
        pid: std::process::id(),
        started_at: identity::now_millis(),
        bound: endpoint.bound_sockets(),
    }
}

async fn accept_loop(core: Arc<Core>, endpoint: Endpoint) {
    let gate = preauth::Gate::new(core.cfg.pre_auth);
    while let Some(incoming) = endpoint.accept().await {
        let (ip, named) = match incoming.remote_addr() {
            iroh::endpoint::IncomingAddr::Ip(addr) => (Some(addr.ip()), None),
            iroh::endpoint::IncomingAddr::Relay { endpoint_id, .. } => {
                (None, Some(DeviceId(*endpoint_id.as_bytes())))
            }
            _ => (None, None),
        };
        // A relay names the peer's key up front; the handshake below still proves it.
        let known = named.is_some_and(|device| core.mp.known_device(device));
        let Some(slot) = gate.arrive(ip, known) else {
            tracing::debug!(
                ?ip,
                "refusing incoming connection: too many unauthenticated"
            );
            incoming.refuse();
            continue;
        };
        let core = Arc::clone(&core);
        tokio::spawn(async move {
            // The whole handshake, never 0-RTT: nothing is read before the client's key is
            // proven, so early data cannot be replayed into a request.
            let handshake = match incoming.accept() {
                Ok(connecting) => tokio::time::timeout(core.cfg.hello_timeout, connecting).await,
                Err(error) => {
                    tracing::debug!("refusing incoming connection: {error}");
                    return;
                }
            };
            match handshake {
                Ok(Ok(connection)) => {
                    let key = *connection.remote_id().as_bytes();
                    let known = core.mp.known_device(DeviceId(key));
                    match slot.authenticated(key, known) {
                        Some(slot) => conn::serve(core, connection, slot).await,
                        None => {
                            tracing::debug!("closing connection: too many unauthenticated");
                            connection.close(0u32.into(), b"busy");
                        }
                    }
                }
                Ok(Err(error)) => tracing::debug!("handshake failed: {error}"),
                Err(_) => tracing::debug!("handshake timed out"),
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rebinds_the_ports_the_last_run_had() {
        let addr = |text: &str| text.parse::<SocketAddr>().unwrap();
        let previous = [addr("0.0.0.0:51482"), addr("[::]:59205")];
        assert_eq!(
            sticky_binds(None, &previous),
            [addr("0.0.0.0:51482"), addr("[::]:59205")]
        );
        // `--bind` with port 0 keeps its address and takes the old port.
        assert_eq!(
            sticky_binds(Some(addr("127.0.0.1:0")), &previous),
            [addr("127.0.0.1:51482")]
        );
        // A fixed port is the user's; a first run, or a family without an old port, binds
        // as before.
        assert!(sticky_binds(Some(addr("127.0.0.1:7000")), &previous).is_empty());
        assert!(sticky_binds(None, &[]).is_empty());
        assert!(sticky_binds(None, &previous[..1]).is_empty());
    }
}
