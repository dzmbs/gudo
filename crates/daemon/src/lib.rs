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

mod agent;
mod anchor;
mod approve;
mod art;
mod askpass;
mod assist;
mod browser;
mod codex_session;
mod commands;
mod config;
mod conn;
mod core;
mod forward;
mod fsutil;
mod identity;
mod input;
mod layout;
mod mp;
mod net;
mod notifier;
mod osc;
mod pane;
mod persist;
mod procinfo;
mod scan;
mod shell;
mod stream;
mod term;
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
use proto::{DaemonId, Ticket};
use tokio::task::JoinHandle;

pub use agent::{HookRequest, HookResponse, PERMISSION_WAIT, STATUS_LINE_EVENT};
pub use art::pull::{
    PULL_FORMATS, PULL_MAX, PULL_VERSION, PullCall, PullExport, PullFormat, PullOp, PullReply,
    PullSummary,
};
pub use askpass::{ASKPASS_VERSION, AskpassCall, HelperQuery, HelperReply};
pub use assist::HistoryConfig;
pub use browser::{
    BROWSER_VERSION, BrowserAsk, BrowserCall, BrowserReply, CALL_TIMEOUT as BROWSER_CALL_TIMEOUT,
};
pub use config::{ArtifactLimits, AskpassConfig, Config, RelayMode, default_state_dir};
pub use config::{CustomRelays, PresenceTimes, PushConfig, RepoConfig};
pub use identity::{
    EndpointInfo, PAIRING_TTL, endpoint_info, mint_ticket, mint_ticket_text, paired_devices,
};
pub use procinfo::inherited_env_var;
pub use term::{ErrorCode as TermErrorCode, TERM_VERSION, TermAsk, TermCall, TermReply, ToolError};
pub use upgrade::prev_path as upgrade_prev_path;
pub use usage::UsageConfig;

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
    pub async fn start(mut config: Config) -> Result<Self, StartError> {
        config.apply_user_file()?;
        let identity = Identity::load_or_create(&config.state_dir)?;
        let (layout, records) = persist::load(&config.state_dir)?
            .map(persist::Saved::into_parts)
            .unwrap_or_default();
        let hooks = HookServer::new(&config.state_dir, config.hook_bin())?;
        let shell = match shell::ShellIntegration::install(&config.state_dir) {
            Ok(si) => Some(si),
            Err(e) => {
                tracing::warn!("installing shell integration scripts: {e}");
                None
            }
        };
        let mp = mp::Mp::open(&config.state_dir, config.lease_idle, config.presence)?;
        let core = Core::new(config, identity, layout, hooks, shell, mp);
        let mut tasks = vec![HookServer::listen(&core)?];
        core::restore(&core, records);

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
        tasks.push(tokio::spawn(persist::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(ws::ports::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(ws::turns::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(ws::repo::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(notifier::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(mp::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(art::run(Arc::clone(&core))));
        tasks.push(tokio::spawn(assist::run(Arc::clone(&core))));
        core.ws.tunnel.autostart(&core.cfg);
        core.mark_dirty();
        Ok(Self {
            core,
            endpoint,
            tasks,
        })
    }

    /// The daemon's endpoint id.
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
            if let Err(e) = identity::write_endpoint_info(&self.core.cfg.state_dir, &info) {
                tracing::warn!("recording endpoint: {e}");
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

    /// Number of paired devices.
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

    /// Stops serving: saves the layout, closes connections and hangs up every pane.
    pub async fn shutdown(self) {
        self.core.shutting_down.store(true, Ordering::Release);
        for task in &self.tasks {
            task.abort();
        }
        self.core.art.flush();
        if let Err(e) = persist::save(&self.core).await {
            tracing::warn!("saving layout on shutdown: {e}");
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
        let _ = std::fs::remove_file(self.core.hooks.socket());
    }
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
                .map_err(|e| StartError::Bind(e.to_string()))?;
        }
        match builder.bind().await {
            Ok(endpoint) => return Ok(endpoint),
            Err(e) => tracing::warn!(
                ?wanted,
                "binding the previous ports failed, using new ones: {e}"
            ),
        }
    }
    let mut builder = endpoint_builder(core)?;
    if let Some(addr) = core.cfg.bind {
        builder = builder
            .bind_addr(addr)
            .map_err(|e| StartError::Bind(e.to_string()))?;
    }
    builder
        .bind()
        .await
        .map_err(|e| StartError::Bind(e.to_string()))
}

/// The sockets to bind so this run listens where the last one did: for `--bind` with port 0
/// (or the default `0.0.0.0` + `[::]`), the same address on the port the last run had for
/// that address family. Empty when there is nothing to reuse (first run, a fixed port).
fn sticky_binds(bind: Option<SocketAddr>, previous: &[SocketAddr]) -> Vec<SocketAddr> {
    let port_of = |v4: bool| {
        previous
            .iter()
            .find(|a| a.is_ipv4() == v4 && a.port() != 0)
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

fn endpoint_builder(core: &Core) -> Result<iroh::endpoint::Builder, StartError> {
    let builder = match &core.cfg.relay {
        RelayMode::Default => Endpoint::builder(presets::N0),
        RelayMode::Disabled => Endpoint::builder(presets::Minimal),
        RelayMode::Custom(custom) => {
            let map = iroh::RelayMap::try_from_iter(custom.urls.iter().map(String::as_str))
                .map_err(|e| StartError::Bind(format!("relay urls: {e}")))?;
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
        .alpns(vec![proto::ALPN.to_vec()]);
    // A fixed `--bind` replaces the default sockets; `bind_addr` per family does the same.
    Ok(if core.cfg.bind.is_some() {
        builder.clear_ip_transports()
    } else {
        builder
    })
}

/// The certificates in a PEM file.
fn read_pem_certs(
    path: &std::path::Path,
) -> Result<Vec<rustls_pki_types::CertificateDer<'static>>, StartError> {
    use rustls_pki_types::pem::PemObject;
    let certs = rustls_pki_types::CertificateDer::pem_file_iter(path)
        .and_then(|it| it.collect::<Result<Vec<_>, _>>())
        .map_err(|e| StartError::Bind(format!("relay CA file {}: {e}", path.display())))?;
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
        if let Err(e) = identity::write_endpoint_info(&core.cfg.state_dir, &info) {
            tracing::warn!("recording endpoint: {e}");
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
            .map(|mut a| {
                if a.ip().is_unspecified() {
                    a.set_ip(IpAddr::V4(Ipv4Addr::LOCALHOST));
                }
                a
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
    while let Some(incoming) = endpoint.accept().await {
        let core = Arc::clone(&core);
        tokio::spawn(async move {
            let conn = match incoming.accept() {
                Ok(connecting) => connecting.await,
                Err(e) => {
                    tracing::debug!("refusing incoming connection: {e}");
                    return;
                }
            };
            match conn {
                Ok(conn) => conn::serve(core, conn).await,
                Err(e) => tracing::debug!("handshake failed: {e}"),
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rebinds_the_ports_the_last_run_had() {
        let addr = |s: &str| s.parse::<SocketAddr>().unwrap();
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
