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
mod net;
mod osc;
mod pane;
mod persist;
mod procinfo;
mod scan;
mod shell;
mod stream;
mod ws;

use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use iroh::Endpoint;
use iroh::endpoint::presets;
use proto::{DaemonId, Ticket};
use tokio::task::JoinHandle;

pub use agent::{HookRequest, HookResponse, PERMISSION_WAIT};
pub use config::{Config, RelayMode, default_state_dir};
pub use identity::{EndpointInfo, PAIRING_TTL, endpoint_info, mint_ticket, paired_devices};

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
        let core = Core::new(config, identity, layout, hooks, shell);
        let mut tasks = vec![HookServer::listen(&core)?];
        core::restore(&core, records);

        let endpoint = bind(&core).await?;
        let info = endpoint_info_of(&endpoint);
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
        if self.core.cfg.relay == RelayMode::Default {
            let _ = tokio::time::timeout(timeout, self.endpoint.online()).await;
            let info = endpoint_info_of(&self.endpoint);
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

    /// Number of paired devices.
    pub fn paired_devices(&self) -> usize {
        self.core.identity.device_count()
    }

    /// Stops serving: saves the layout, closes connections and hangs up every pane.
    pub async fn shutdown(self) {
        self.core.shutting_down.store(true, Ordering::Release);
        for task in &self.tasks {
            task.abort();
        }
        if let Err(e) = persist::save(&self.core).await {
            tracing::warn!("saving layout on shutdown: {e}");
        }
        self.endpoint.close().await;
        self.core.ws.editors.stop_all().await;
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
    let builder = match core.cfg.relay {
        RelayMode::Default => Endpoint::builder(presets::N0),
        RelayMode::Disabled => Endpoint::builder(presets::Minimal),
    };
    let mut builder = builder
        .secret_key(core.identity.secret.clone())
        .alpns(vec![proto::ALPN.to_vec()]);
    if let Some(addr) = core.cfg.bind {
        builder = builder
            .clear_ip_transports()
            .bind_addr(addr)
            .map_err(|e| StartError::Bind(e.to_string()))?;
    }
    builder
        .bind()
        .await
        .map_err(|e| StartError::Bind(e.to_string()))
}

/// Keeps `endpoint.json` current as iroh learns addresses and picks a home relay, so tickets
/// minted by `hostd pair` carry what works now.
async fn track_addresses(core: Arc<Core>, endpoint: Endpoint) {
    use iroh::Watcher;
    let mut watcher = endpoint.watch_addr();
    while watcher.updated().await.is_ok() {
        let info = endpoint_info_of(&endpoint);
        tracing::debug!(addrs = ?info.addrs, relay = ?info.relay_url, "endpoint address changed");
        if let Err(e) = identity::write_endpoint_info(&core.cfg.state_dir, &info) {
            tracing::warn!("recording endpoint: {e}");
        }
    }
}

fn endpoint_info_of(endpoint: &Endpoint) -> EndpointInfo {
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
        pid: std::process::id(),
        started_at: identity::now_millis(),
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
