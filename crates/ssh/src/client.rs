//! One SSH connection (through any jump hosts) and its liveness monitor.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

use russh::client::{self, Handle};
use russh::keys::PublicKey;
use tokio::net::TcpStream;
use tokio::sync::{Notify, watch};
use tokio::task::JoinSet;

use crate::SshError;
use crate::auth::{Credentials, authenticate};
use crate::known_hosts::{HostKeyPolicy, KnownHosts, Undecided};
use crate::target::{HostSpec, Target};

/// Liveness settings (docs/SSH.md §2). The defaults follow 04 R1/R2.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Keepalive {
    /// A `keepalive@openssh.com` request is sent this often (`ServerAliveInterval`).
    /// Each must be answered before the next is due.
    pub interval: Duration,
    /// This many unanswered keepalives in a row declare the peer dead
    /// (`ServerAliveCountMax`).
    pub count_max: u32,
    /// Deadline for a fast probe ([`Connection::probe`], foreground, network change, input
    /// after silence). No answer in time declares the peer dead at once.
    pub probe_timeout: Duration,
}

impl Default for Keepalive {
    fn default() -> Self {
        Self {
            interval: Duration::from_secs(15),
            count_max: 3,
            probe_timeout: Duration::from_secs(5),
        }
    }
}

/// Timeouts for establishing a connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timeouts {
    /// TCP connect per hop (`ConnectTimeout`).
    pub connect: Duration,
    /// Version exchange and key exchange per hop.
    pub handshake: Duration,
    /// Authentication per hop, excluding host-key prompts.
    pub auth: Duration,
}

impl Default for Timeouts {
    fn default() -> Self {
        Self {
            connect: Duration::from_secs(10),
            handshake: Duration::from_secs(15),
            auth: Duration::from_secs(60),
        }
    }
}

/// Everything needed to dial a [`Target`].
#[derive(Clone, Debug)]
pub struct ConnectOptions {
    /// Credentials, tried in order on every hop.
    pub credentials: Credentials,
    /// Host keys on record.
    pub known_hosts: Arc<KnownHosts>,
    /// What to do with unknown hosts.
    pub host_key_policy: HostKeyPolicy,
    /// Liveness monitoring.
    pub keepalive: Keepalive,
    /// Dial timeouts.
    pub timeouts: Timeouts,
    /// Ask for `zlib@openssh.com` compression (helps on slow links, costs CPU).
    pub compression: bool,
}

impl ConnectOptions {
    /// Defaults with these credentials, host-key store and policy.
    pub fn new(
        credentials: Credentials,
        known_hosts: Arc<KnownHosts>,
        host_key_policy: HostKeyPolicy,
    ) -> Self {
        Self {
            credentials,
            known_hosts,
            host_key_policy,
            keepalive: Keepalive::default(),
            timeouts: Timeouts::default(),
            compression: false,
        }
    }
}

/// russh callbacks for one hop.
pub(crate) struct ClientHandler {
    spec: HostSpec,
    known_hosts: Arc<KnownHosts>,
    policy: HostKeyPolicy,
    /// A new host key waiting for the user's verdict after the key exchange.
    pending: Arc<Mutex<Option<(Undecided, PublicKey)>>>,
    dead: Arc<watch::Sender<Option<String>>>,
}

impl client::Handler for ClientHandler {
    type Error = SshError;

    async fn check_server_key(
        &mut self,
        key: &russh::keys::PublicKeyOrCertificate,
    ) -> Result<bool, SshError> {
        // No host certificates are advertised, so a certificate here is unexpected.
        let russh::keys::PublicKeyOrCertificate::PublicKey { key, .. } = key else {
            return Ok(false);
        };
        if let Some(info) = self.known_hosts.verify(&self.spec, key, &self.policy)? {
            *self.pending.lock().unwrap_or_else(PoisonError::into_inner) =
                Some((info, key.clone()));
        }
        Ok(true)
    }

    async fn auth_banner(&mut self, banner: &str, _: &mut client::Session) -> Result<(), SshError> {
        tracing::info!(host = %self.spec.host, "banner: {}", banner.trim_end());
        Ok(())
    }

    async fn disconnected(
        &mut self,
        reason: client::DisconnectReason<SshError>,
    ) -> Result<(), SshError> {
        let why = match &reason {
            client::DisconnectReason::ReceivedDisconnect(info) => {
                format!("{} closed the connection: {}", self.spec.host, info.message)
            }
            client::DisconnectReason::Error(e) => format!("{}: {e}", self.spec.host),
        };
        self.dead
            .send_if_modified(|d| d.is_none().then(|| *d = Some(why)).is_some());
        match reason {
            client::DisconnectReason::ReceivedDisconnect(_) => Ok(()),
            client::DisconnectReason::Error(e) => Err(e),
        }
    }
}

struct Inner {
    handle: Handle<ClientHandler>,
    /// Jump-host sessions, kept open for as long as the tunnel through them is needed.
    jumps: Vec<Handle<ClientHandler>>,
    target: Target,
    keepalive: Keepalive,
    dead: Arc<watch::Sender<Option<String>>>,
    probe: Arc<Notify>,
    born: Instant,
    /// Milliseconds since `born` of the last keepalive answer.
    last_pong: AtomicU64,
    /// Round trip of the last keepalive, in microseconds.
    rtt_us: AtomicU64,
    monitor: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Drop for Inner {
    fn drop(&mut self) {
        if let Some(m) = self
            .monitor
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            m.abort();
        }
    }
}

/// An authenticated SSH connection. Clones share it; it closes when the last clone drops.
///
/// "Connected" is a probe answered recently, never a socket flag (04 R2): a monitor task
/// sends keepalives and marks the connection dead when they go unanswered; see
/// [`Keepalive`].
#[derive(Clone)]
pub struct Connection {
    inner: Arc<Inner>,
}

impl std::fmt::Debug for Connection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Connection")
            .field("target", &self.inner.target.to_string())
            .finish_non_exhaustive()
    }
}

impl Connection {
    /// Dials `target` through its jump hosts, verifies host keys and authenticates.
    ///
    /// An unknown host under [`HostKeyPolicy::Ask`] is prompted for after the key exchange
    /// and before any credential is sent.
    ///
    /// # Errors
    ///
    /// Any [`SshError`]: unreachable hosts, timeouts, host-key problems, failed auth.
    pub async fn connect(target: &Target, options: &ConnectOptions) -> Result<Self, SshError> {
        let dead = Arc::new(watch::channel(None).0);
        let mut jumps: Vec<Handle<ClientHandler>> = Vec::new();
        for (i, spec) in target.hops().enumerate() {
            let previous = jumps.last();
            let handle = match previous {
                None => {
                    let tcp = tcp_connect(spec, options.timeouts.connect).await?;
                    handshake(tcp, spec, options, &dead).await?
                }
                Some(hop) => {
                    let channel = tokio::time::timeout(
                        options.timeouts.connect,
                        hop.channel_open_direct_tcpip(
                            spec.host.as_str(),
                            u32::from(spec.port),
                            "127.0.0.1",
                            0,
                        ),
                    )
                    .await
                    .map_err(|_| SshError::Timeout("opening the jump tunnel"))?
                    .map_err(|e| {
                        SshError::Protocol(format!(
                            "jump host {} could not reach {}:{}: {e}",
                            target.jumps[i - 1].host,
                            spec.host,
                            spec.port
                        ))
                    })?;
                    handshake(channel.into_stream(), spec, options, &dead).await?
                }
            };
            jumps.push(handle);
        }
        let handle = jumps.pop().expect("a target has at least one hop");
        let inner = Arc::new(Inner {
            handle,
            jumps,
            target: target.clone(),
            keepalive: options.keepalive,
            dead,
            probe: Arc::new(Notify::new()),
            born: Instant::now(),
            last_pong: AtomicU64::new(0),
            rtt_us: AtomicU64::new(0),
            monitor: Mutex::new(None),
        });
        let monitor = tokio::spawn(monitor(Arc::downgrade(&inner)));
        *inner.monitor.lock().unwrap_or_else(PoisonError::into_inner) = Some(monitor);
        Ok(Self { inner })
    }

    /// The route this connection took.
    pub fn target(&self) -> &Target {
        &self.inner.target
    }

    /// Whether the connection is dead (closed, or keepalives went unanswered).
    pub fn is_dead(&self) -> bool {
        self.inner.dead.borrow().is_some() || self.inner.handle.is_closed()
    }

    /// Waits until the connection is dead and returns why.
    pub async fn closed(&self) -> String {
        let mut rx = self.inner.dead.subscribe();
        match rx.wait_for(Option::is_some).await {
            Ok(reason) => reason.clone().unwrap_or_default(),
            Err(_) => "closed".into(),
        }
    }

    /// Round trip of the most recent keepalive, if one was answered.
    pub fn rtt(&self) -> Option<Duration> {
        match self.inner.rtt_us.load(Ordering::Relaxed) {
            0 => None,
            us => Some(Duration::from_micros(us)),
        }
    }

    /// Time since the server last answered a keepalive (or since connecting).
    pub fn since_last_reply(&self) -> Duration {
        let pong = Duration::from_millis(self.inner.last_pong.load(Ordering::Relaxed));
        self.inner.born.elapsed().saturating_sub(pong)
    }

    /// Asks the monitor for a fast probe now: if the server does not answer within
    /// [`Keepalive::probe_timeout`] the connection is declared dead. Call it when the app
    /// comes to the foreground or the network changes.
    pub fn probe(&self) {
        self.inner.probe.notify_one();
    }

    /// Notes that the user sent input. After a keepalive interval without any answer, a
    pub fn note_input(&self) {
        if self.since_last_reply() >= self.inner.keepalive.interval {
            self.probe();
        }
    }

    /// Sends one keepalive and waits for the answer.
    ///
    /// # Errors
    ///
    /// [`SshError::Timeout`] if no answer arrives within `timeout`,
    /// [`SshError::Disconnected`] if the connection is gone.
    pub async fn ping(&self, timeout: Duration) -> Result<Duration, SshError> {
        ping(&self.inner, timeout).await
    }

    /// Closes the connection (and the tunnels through its jump hosts).
    pub async fn disconnect(&self) {
        let _ = self
            .inner
            .handle
            .disconnect(russh::Disconnect::ByApplication, "bye", "en")
            .await;
        for hop in self.inner.jumps.iter().rev() {
            let _ = hop
                .disconnect(russh::Disconnect::ByApplication, "bye", "en")
                .await;
        }
        mark_dead(&self.inner.dead, "closed by the client".into());
    }

    /// Runs `work` unless the connection dies first: a dead connection fails fast instead
    pub(crate) async fn guard<T>(
        &self,
        work: impl Future<Output = Result<T, SshError>>,
    ) -> Result<T, SshError> {
        if let Some(why) = self.inner.dead.borrow().clone() {
            return Err(SshError::Disconnected(why));
        }
        tokio::select! {
            r = work => r,
            why = self.closed() => Err(SshError::Disconnected(why)),
        }
    }

    pub(crate) fn handle(&self) -> &Handle<ClientHandler> {
        &self.inner.handle
    }

    pub(crate) fn mark_dead(&self, why: String) {
        mark_dead(&self.inner.dead, why);
    }
}

fn mark_dead(dead: &watch::Sender<Option<String>>, why: String) {
    dead.send_if_modified(|d| d.is_none().then(|| *d = Some(why)).is_some());
}

async fn ping(inner: &Inner, timeout: Duration) -> Result<Duration, SshError> {
    tokio::time::timeout(timeout, ping_once(inner))
        .await
        .map_err(|_| SshError::Timeout("waiting for a keepalive reply"))?
}

/// One `keepalive@openssh.com` round trip; records the reply time and RTT.
async fn ping_once(inner: &Inner) -> Result<Duration, SshError> {
    let start = Instant::now();
    inner.handle.send_ping().await?;
    // russh resolves the ping when its session ends too, so check that it is still up.
    if inner.handle.is_closed() {
        return Err(SshError::Disconnected("the session ended".into()));
    }
    let rtt = start.elapsed();
    let since_born = u64::try_from(inner.born.elapsed().as_millis()).unwrap_or(u64::MAX);
    inner.last_pong.store(since_born, Ordering::Relaxed);
    let us = u64::try_from(rtt.as_micros()).unwrap_or(u64::MAX).max(1);
    inner.rtt_us.store(us, Ordering::Relaxed);
    Ok(rtt)
}

/// Sends keepalives and fast probes until the connection dies or is dropped.
///
/// Every `interval` a keepalive goes out and must be answered within `interval`; each one
/// that is not counts a miss and the next goes out at once, so `count_max` misses take
/// `count_max × interval`. A probe request (foreground, network change, input after
/// silence) sends a keepalive at once, or shortens the one in flight, with a deadline of
/// `probe_timeout`; missing that is fatal at once.
async fn monitor(weak: Weak<Inner>) {
    let mut misses = 0u32;
    let mut overdue = false;
    loop {
        let (keepalive, mut dead, probe) = match weak.upgrade() {
            Some(inner) => (
                inner.keepalive,
                inner.dead.subscribe(),
                Arc::clone(&inner.probe),
            ),
            None => return,
        };
        let mut fast = false;
        if !overdue {
            tokio::select! {
                () = tokio::time::sleep(keepalive.interval) => {}
                () = probe.notified() => fast = true,
                _ = dead.wait_for(Option::is_some) => return,
            }
        }
        let Some(inner) = weak.upgrade() else { return };
        let start = tokio::time::Instant::now();
        let deadline = tokio::time::sleep(if fast {
            keepalive.probe_timeout
        } else {
            keepalive.interval
        });
        tokio::pin!(deadline);
        let reply = ping_once(&inner);
        tokio::pin!(reply);
        let outcome = loop {
            tokio::select! {
                r = &mut reply => break Some(r),
                () = &mut deadline => break None,
                () = probe.notified(), if !fast => {
                    fast = true;
                    let probe_end = tokio::time::Instant::now() + keepalive.probe_timeout;
                    if probe_end < deadline.deadline() {
                        deadline.as_mut().reset(probe_end);
                    }
                }
            }
        };
        match outcome {
            Some(Ok(_)) => {
                misses = 0;
                overdue = false;
            }
            Some(Err(e)) => {
                mark_dead(&inner.dead, e.to_string());
                return;
            }
            None if fast => {
                mark_dead(
                    &inner.dead,
                    format!(
                        "no reply to a probe within {} ms",
                        keepalive.probe_timeout.as_millis()
                    ),
                );
                return;
            }
            None => {
                misses += 1;
                overdue = true;
                tracing::debug!(misses, waited = ?start.elapsed(), "keepalive unanswered");
                if misses >= keepalive.count_max.max(1) {
                    mark_dead(
                        &inner.dead,
                        format!(
                            "{misses} keepalives unanswered ({} s)",
                            (keepalive.interval * misses).as_secs()
                        ),
                    );
                    return;
                }
            }
        }
    }
}

/// Resolves and connects, racing addresses RFC 8305-style (next attempt every 250 ms).
async fn tcp_connect(spec: &HostSpec, timeout: Duration) -> Result<TcpStream, SshError> {
    let what = format!("connecting to {}:{}", spec.host, spec.port);
    let work = async {
        let addrs: Vec<SocketAddr> = tokio::net::lookup_host((spec.host.as_str(), spec.port))
            .await
            .map_err(|e| SshError::io(format!("resolving {}", spec.host), e))?
            .collect();
        let addrs = interleave_families(addrs);
        let mut attempts = JoinSet::new();
        let mut pending = addrs.into_iter();
        let mut last_error = None;
        loop {
            if let Some(addr) = pending.next() {
                attempts.spawn(async move { (addr, TcpStream::connect(addr).await) });
            }
            let stagger = tokio::time::sleep(Duration::from_millis(250));
            tokio::select! {
                Some(done) = attempts.join_next() => {
                    match done {
                        Ok((_, Ok(stream))) => {
                            let _ = stream.set_nodelay(true);
                            return Ok(stream);
                        }
                        Ok((addr, Err(e))) => last_error = Some(SshError::io(format!("{what} ({addr})"), e)),
                        Err(e) => last_error = Some(SshError::Protocol(e.to_string())),
                    }
                    if attempts.is_empty() && pending.len() == 0 {
                        return Err(last_error.unwrap_or_else(|| SshError::Protocol(format!("{what}: no addresses"))));
                    }
                }
                () = stagger, if pending.len() > 0 => {}
                else => return Err(last_error.unwrap_or_else(|| SshError::Protocol(format!("{what}: no addresses")))),
            }
        }
    };
    tokio::time::timeout(timeout, work)
        .await
        .map_err(|_| SshError::Timeout("connecting"))?
}

/// Alternates IPv6 and IPv4 addresses, IPv6 first (RFC 8305 §4).
fn interleave_families(addrs: Vec<SocketAddr>) -> Vec<SocketAddr> {
    let (v6, v4): (Vec<_>, Vec<_>) = addrs.into_iter().partition(SocketAddr::is_ipv6);
    let mut out = Vec::with_capacity(v6.len() + v4.len());
    let (mut a, mut b) = (v6.into_iter(), v4.into_iter());
    loop {
        match (a.next(), b.next()) {
            (None, None) => return out,
            (x, y) => out.extend(x.into_iter().chain(y)),
        }
    }
}

async fn handshake<S>(
    stream: S,
    spec: &HostSpec,
    options: &ConnectOptions,
    dead: &Arc<watch::Sender<Option<String>>>,
) -> Result<Handle<ClientHandler>, SshError>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let mut preferred = russh::Preferred::default();
    // Offer the host-key types already on record first, so a host with several keys
    // presents the one we know (OpenSSH does the same).
    let known = options
        .known_hosts
        .algorithms_for(spec.key_host(), spec.port);
    if !known.is_empty() {
        let mut keys = known.clone();
        keys.extend(preferred.key.iter().filter(|a| !known.contains(a)).cloned());
        preferred.key = keys.into();
    }
    if options.compression {
        preferred.compression = std::borrow::Cow::Borrowed(&[
            russh::compression::ZLIB_LEGACY,
            russh::compression::ZLIB,
            russh::compression::NONE,
        ]);
    }
    let config = Arc::new(client::Config {
        preferred,
        // Liveness is ours (the monitor above), not russh's.
        keepalive_interval: None,
        inactivity_timeout: None,
        nodelay: true,
        ..client::Config::default()
    });
    let pending = Arc::new(Mutex::new(None));
    let handler = ClientHandler {
        spec: spec.clone(),
        known_hosts: Arc::clone(&options.known_hosts),
        policy: options.host_key_policy.clone(),
        pending: Arc::clone(&pending),
        dead: Arc::clone(dead),
    };
    let mut handle = tokio::time::timeout(
        options.timeouts.handshake,
        client::connect_stream(config, stream, handler),
    )
    .await
    .map_err(|_| SshError::Timeout("in the SSH handshake"))??;

    let new_key = pending
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .take();
    if let Some((Undecided { info, expected }, key)) = new_key {
        let HostKeyPolicy::Ask(prompt) = &options.host_key_policy else {
            unreachable!("only Ask defers a decision");
        };
        let prompt = Arc::clone(prompt);
        let shown = info.clone();
        let changed = expected.clone();
        let trusted = tokio::task::spawn_blocking(move || match changed {
            None => prompt.trust_new_host(shown),
            Some(expected) => prompt.trust_changed_host(shown, expected),
        })
        .await
        .unwrap_or(false);
        if !trusted {
            let _ = handle
                .disconnect(russh::Disconnect::HostKeyNotVerifiable, "", "en")
                .await;
            return Err(match expected {
                None => SshError::HostKeyRejected {
                    host: info.host,
                    fingerprint: info.fingerprint,
                },
                Some(expected) => SshError::HostKeyMismatch {
                    host: info.host,
                    expected,
                    actual: info.fingerprint,
                },
            });
        }
        match expected {
            None => options.known_hosts.add(spec.key_host(), spec.port, &key)?,
            Some(_) => options
                .known_hosts
                .replace(spec.key_host(), spec.port, &key)?,
        }
    }

    tokio::time::timeout(
        options.timeouts.auth,
        authenticate(&mut handle, spec, &options.credentials),
    )
    .await
    .map_err(|_| SshError::Timeout("authenticating"))??;
    Ok(handle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn families_interleave_v6_first() {
        let a: Vec<SocketAddr> = ["1.1.1.1:22", "2.2.2.2:22", "[::1]:22"]
            .iter()
            .map(|s| s.parse().unwrap())
            .collect();
        let out = interleave_families(a);
        assert_eq!(
            out.iter().map(ToString::to_string).collect::<Vec<_>>(),
            ["[::1]:22", "1.1.1.1:22", "2.2.2.2:22"]
        );
    }
}
