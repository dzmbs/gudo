//! A self-healing SSH session: one logical handle whose connection underneath is redialled
//! with backoff whenever it dies (04 R7–R10).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use tokio::sync::{Notify, watch};

use crate::SshError;
use crate::client::{ConnectOptions, Connection};
use crate::target::Target;

/// Where a [`Session`] is. Every change is delivered to the [`SessionListener`] in order.
#[derive(Debug, Clone)]
pub enum ConnectionState {
    /// Dialling (attempt 1 is the first try after start or after a drop).
    Connecting {
        /// Attempt number since the last success.
        attempt: u32,
    },
    /// Authenticated, and keepalives are being answered.
    Connected {
        /// Increases with every new connection; a change means channels were lost.
        generation: u64,
    },
    /// The last attempt failed or the connection died; the next attempt is scheduled.
    Reconnecting {
        /// Failed attempts since the last success.
        attempt: u32,
        /// Delay before the next attempt.
        retry_in: Duration,
        /// Why the previous connection or attempt failed.
        reason: String,
    },
    /// In the background with the attempt budget spent; waits for
    /// [`Session::set_foreground`], [`Session::network_changed`] or
    /// [`Session::reconnect_now`].
    Offline {
        /// The last failure.
        reason: String,
    },
    /// Needs the user (wrong credentials, host key changed or refused). Not retried
    /// until [`Session::reconnect_now`].
    NeedsAttention {
        /// The error, e.g. [`SshError::HostKeyMismatch`] with both fingerprints.
        error: SshError,
    },
    /// [`Session::close`] was called.
    Closed,
}

/// Receives [`ConnectionState`] changes. Runs on the session's task; return quickly.
pub trait SessionListener: Send + Sync {
    /// Called on every state change, in order.
    fn on_state(&self, state: ConnectionState);
}

/// Redial timing (docs/SSH.md §2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReconnectPolicy {
    /// Delay after the first failed attempt; doubles per failure.
    pub initial_delay: Duration,
    /// Cap on the delay.
    pub max_delay: Duration,
    /// Random spread applied to each delay, in percent (±).
    pub jitter_percent: u8,
    /// In the background, give up (go [`ConnectionState::Offline`]) after this many failed
    /// attempts. `None` retries forever. In the foreground there is no limit: the session
    /// never gives up while the user is looking at it.
    pub background_attempts: Option<u32>,
    /// A connection that lived at least this long resets the backoff, and its loss is
    /// redialled at once; shorter ones count as failures (no hot loop against a server
    /// that accepts and then drops).
    pub stable_after: Duration,
}

impl Default for ReconnectPolicy {
    fn default() -> Self {
        Self {
            initial_delay: Duration::from_millis(250),
            max_delay: Duration::from_secs(8),
            jitter_percent: 20,
            background_attempts: Some(3),
            stable_after: Duration::from_secs(10),
        }
    }
}

impl ReconnectPolicy {
    /// The delay before attempt `failures + 1`, without jitter:
    /// `min(max_delay, initial_delay × 2^(failures − 1))`, and zero for `failures == 0`.
    ///
    /// # Examples
    ///
    /// ```
    /// use std::time::Duration;
    /// let p = ssh::ReconnectPolicy::default();
    /// assert_eq!(p.delay(0), Duration::ZERO);
    /// assert_eq!(p.delay(1), Duration::from_millis(250));
    /// assert_eq!(p.delay(4), Duration::from_secs(2));
    /// assert_eq!(p.delay(30), Duration::from_secs(8));
    /// ```
    pub fn delay(&self, failures: u32) -> Duration {
        if failures == 0 {
            return Duration::ZERO;
        }
        let factor = 1u32 << (failures - 1).min(20);
        self.initial_delay
            .saturating_mul(factor)
            .min(self.max_delay)
    }

    /// [`delay`](Self::delay) spread by `±jitter_percent`, using `unit` in `[0, 1)` as the
    /// random draw.
    pub fn jittered(&self, failures: u32, unit: f64) -> Duration {
        let base = self.delay(failures);
        let spread = f64::from(self.jitter_percent) / 100.0;
        base.mul_f64((1.0 - spread + 2.0 * spread * unit.clamp(0.0, 1.0)).max(0.0))
    }
}

struct Inner {
    target: Target,
    options: ConnectOptions,
    policy: ReconnectPolicy,
    listener: Option<Arc<dyn SessionListener>>,
    state: watch::Sender<ConnectionState>,
    conn: watch::Sender<Option<Connection>>,
    foreground: AtomicBool,
    force: AtomicBool,
    closed: AtomicBool,
    wake: Notify,
    generation: AtomicU64,
}

impl Inner {
    fn set_state(&self, state: ConnectionState) {
        tracing::debug!(target = %self.target, ?state, "ssh session");
        if let Some(listener) = &self.listener {
            listener.on_state(state.clone());
        }
        self.state.send_replace(state);
    }
}

/// A logical SSH session to one target that keeps itself connected.
///
/// Views hold the `Session`, never a socket (04 R7); the [`Connection`] underneath is
/// swapped on every redial. Cheap to clone.
#[derive(Clone)]
pub struct Session {
    inner: Arc<Inner>,
}

impl Session {
    /// Starts connecting in the background on the current tokio runtime.
    ///
    /// # Panics
    ///
    /// Panics if called outside a tokio runtime.
    pub fn start(
        target: Target,
        options: ConnectOptions,
        policy: ReconnectPolicy,
        listener: Option<Arc<dyn SessionListener>>,
    ) -> Self {
        Self::start_on(
            &tokio::runtime::Handle::current(),
            target,
            options,
            policy,
            listener,
        )
    }

    /// Starts connecting in the background on `runtime`.
    pub fn start_on(
        runtime: &tokio::runtime::Handle,
        target: Target,
        options: ConnectOptions,
        policy: ReconnectPolicy,
        listener: Option<Arc<dyn SessionListener>>,
    ) -> Self {
        let inner = Arc::new(Inner {
            target,
            options,
            policy,
            listener,
            state: watch::channel(ConnectionState::Connecting { attempt: 1 }).0,
            conn: watch::channel(None).0,
            foreground: AtomicBool::new(true),
            force: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            wake: Notify::new(),
            generation: AtomicU64::new(0),
        });
        runtime.spawn(supervise(Arc::clone(&inner)));
        Self { inner }
    }

    /// The target.
    pub fn target(&self) -> &Target {
        &self.inner.target
    }

    /// The current state.
    pub fn state(&self) -> ConnectionState {
        self.inner.state.borrow().clone()
    }

    /// A receiver that sees every state change.
    pub fn subscribe(&self) -> watch::Receiver<ConnectionState> {
        self.inner.state.subscribe()
    }

    /// The live connection, if there is one right now.
    pub fn connection(&self) -> Option<Connection> {
        self.inner.conn.borrow().clone()
    }

    /// Waits for a live connection.
    ///
    /// # Errors
    ///
    /// The error behind [`ConnectionState::NeedsAttention`], or [`SshError::Closed`].
    pub async fn connected(&self) -> Result<Connection, SshError> {
        let mut conn = self.inner.conn.subscribe();
        let mut state = self.inner.state.subscribe();
        loop {
            if let Some(c) = conn.borrow_and_update().clone()
                && !c.is_dead()
            {
                return Ok(c);
            }
            match &*state.borrow_and_update() {
                ConnectionState::NeedsAttention { error } => return Err(error.clone()),
                ConnectionState::Closed => return Err(SshError::Closed),
                _ => {}
            }
            tokio::select! {
                r = conn.changed() => if r.is_err() { return Err(SshError::Closed) },
                r = state.changed() => if r.is_err() { return Err(SshError::Closed) },
            }
        }
    }

    /// Tells the session whether the UI is in the foreground. Coming to the foreground
    /// probes a live connection at once and cuts any backoff wait short (04 R1, R10).
    pub fn set_foreground(&self, foreground: bool) {
        self.inner.foreground.store(foreground, Ordering::SeqCst);
        if foreground {
            self.network_changed();
        }
    }

    /// The network path changed (Wi-Fi ↔ cellular): probe a live connection, or redial now.
    pub fn network_changed(&self) {
        if let Some(c) = self.connection() {
            c.probe();
        }
        self.inner.wake.notify_one();
    }

    /// Drops the current connection (if any) and dials again immediately; also retries
    /// after [`ConnectionState::NeedsAttention`] (e.g. once the user accepted a new key).
    pub fn reconnect_now(&self) {
        self.inner.force.store(true, Ordering::SeqCst);
        self.inner.wake.notify_one();
    }

    /// Closes the session for good.
    pub fn close(&self) {
        self.inner.closed.store(true, Ordering::SeqCst);
        self.inner.wake.notify_one();
    }
}

/// How a wait ended.
enum Woken {
    Timer,
    Wake,
}

async fn wait(inner: &Inner, delay: Option<Duration>) -> Woken {
    match delay {
        Some(d) => tokio::select! {
            () = tokio::time::sleep(d) => Woken::Timer,
            () = inner.wake.notified() => Woken::Wake,
        },
        None => {
            inner.wake.notified().await;
            Woken::Wake
        }
    }
}

async fn supervise(inner: Arc<Inner>) {
    let mut failures: u32 = 0;
    loop {
        if inner.closed.load(Ordering::SeqCst) {
            break;
        }
        inner.force.store(false, Ordering::SeqCst);
        inner.set_state(ConnectionState::Connecting {
            attempt: failures + 1,
        });
        let attempt = Connection::connect(&inner.target, &inner.options);
        let result = tokio::select! {
            r = attempt => Some(r),
            () = wait_closed(&inner) => None,
        };
        let reason = match result {
            None => break,
            Some(Ok(conn)) => {
                inner.force.store(false, Ordering::SeqCst);
                let generation = inner.generation.fetch_add(1, Ordering::SeqCst) + 1;
                inner.conn.send_replace(Some(conn.clone()));
                inner.set_state(ConnectionState::Connected { generation });
                let since = Instant::now();
                let reason = loop {
                    tokio::select! {
                        why = conn.closed() => break why,
                        () = inner.wake.notified() => {
                            if inner.closed.load(Ordering::SeqCst) {
                                break "closed".into();
                            }
                            if inner.force.load(Ordering::SeqCst) {
                                break "reconnect requested".into();
                            }
                            // Foreground or network change: check the link is really alive.
                            conn.probe();
                        }
                    }
                };
                inner.conn.send_replace(None);
                conn.mark_dead(reason.clone());
                if inner.closed.load(Ordering::SeqCst) {
                    conn.disconnect().await;
                    break;
                }
                tokio::spawn(async move { conn.disconnect().await });
                if since.elapsed() >= inner.policy.stable_after
                    || inner.force.load(Ordering::SeqCst)
                {
                    // A healthy connection dropped: redial at once.
                    failures = 0;
                    continue;
                }
                reason
            }
            Some(Err(e)) if e.is_fatal() => {
                inner.set_state(ConnectionState::NeedsAttention { error: e });
                loop {
                    wait(&inner, None).await;
                    if inner.closed.load(Ordering::SeqCst) || inner.force.load(Ordering::SeqCst) {
                        break;
                    }
                }
                failures = 0;
                continue;
            }
            Some(Err(e)) => e.to_string(),
        };

        failures = failures.saturating_add(1);
        let foreground = inner.foreground.load(Ordering::SeqCst);
        if !foreground
            && inner
                .policy
                .background_attempts
                .is_some_and(|n| failures >= n)
        {
            inner.set_state(ConnectionState::Offline { reason });
            // Wait for the foreground, a network change or an explicit reconnect.
            wait(&inner, None).await;
            failures = 0;
            continue;
        }
        let delay = inner.policy.jittered(failures, random_unit());
        inner.set_state(ConnectionState::Reconnecting {
            attempt: failures,
            retry_in: delay,
            reason,
        });
        if let Woken::Wake = wait(&inner, Some(delay)).await {
            // User action or network change: dial now with a fresh budget (04 R10).
            failures = 0;
        }
    }
    inner.set_state(ConnectionState::Closed);
}

/// Resolves once [`Session::close`] is called. Other wake-ups during a dial are dropped:
/// the dial in progress is already the freshest attempt.
async fn wait_closed(inner: &Inner) {
    loop {
        inner.wake.notified().await;
        if inner.closed.load(Ordering::SeqCst) {
            return;
        }
    }
}

fn random_unit() -> f64 {
    let mut b = [0u8; 4];
    let _ = getrandom::fill(&mut b);
    f64::from(u32::from_le_bytes(b)) / (f64::from(u32::MAX) + 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_doubles_and_caps() {
        let p = ReconnectPolicy::default();
        let ms: Vec<u128> = (0..9).map(|n| p.delay(n).as_millis()).collect();
        assert_eq!(ms, [0, 250, 500, 1000, 2000, 4000, 8000, 8000, 8000]);
        assert_eq!(p.delay(u32::MAX), Duration::from_secs(8));
    }

    #[test]
    fn jitter_stays_in_band() {
        let p = ReconnectPolicy::default();
        assert_eq!(p.jittered(3, 0.0), Duration::from_millis(800));
        assert_eq!(p.jittered(3, 0.5), Duration::from_millis(1000));
        assert!(p.jittered(3, 0.999_999) <= Duration::from_millis(1200));
        assert_eq!(p.jittered(0, 0.7), Duration::ZERO);
        for _ in 0..1000 {
            let d = p.jittered(6, random_unit());
            assert!(d >= Duration::from_millis(6400) && d <= Duration::from_millis(9600));
        }
    }

    #[derive(Default)]
    struct Recorder(std::sync::Mutex<Vec<String>>);
    impl SessionListener for Recorder {
        fn on_state(&self, state: ConnectionState) {
            let s = match state {
                ConnectionState::Connecting { attempt } => format!("connecting {attempt}"),
                ConnectionState::Reconnecting { attempt, .. } => format!("reconnecting {attempt}"),
                ConnectionState::Offline { .. } => "offline".into(),
                ConnectionState::Connected { .. } => "connected".into(),
                ConnectionState::NeedsAttention { .. } => "attention".into(),
                ConnectionState::Closed => "closed".into(),
            };
            self.0.lock().unwrap().push(s);
        }
    }

    fn unreachable_session(policy: ReconnectPolicy, recorder: Arc<Recorder>) -> Session {
        // A closed local port: every attempt fails fast with "connection refused".
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let target = Target::direct(crate::HostSpec::new("127.0.0.1", "nobody").with_port(port));
        let options = ConnectOptions::new(
            crate::Credentials::new(),
            Arc::new(crate::KnownHosts::in_memory()),
            crate::HostKeyPolicy::Strict,
        );
        Session::start(target, options, policy, Some(recorder))
    }

    #[tokio::test]
    async fn foreground_never_gives_up_background_goes_offline() {
        let policy = ReconnectPolicy {
            initial_delay: Duration::from_millis(5),
            max_delay: Duration::from_millis(10),
            jitter_percent: 0,
            background_attempts: Some(3),
            stable_after: Duration::from_secs(10),
        };
        let recorder = Arc::new(Recorder::default());
        let session = unreachable_session(policy, Arc::clone(&recorder));
        let mut states = session.subscribe();
        // Foreground: many attempts, never offline.
        let mut seen = 0;
        while seen < 8 {
            states.changed().await.unwrap();
            if let ConnectionState::Reconnecting { .. } = &*states.borrow() {
                seen += 1;
            }
        }
        assert!(!recorder.0.lock().unwrap().iter().any(|s| s == "offline"));
        // Background: the budget runs out and the session parks.
        session.set_foreground(false);
        tokio::time::timeout(
            Duration::from_secs(5),
            states.wait_for(|s| matches!(s, ConnectionState::Offline { .. })),
        )
        .await
        .unwrap()
        .unwrap();
        // Foreground again: it dials immediately.
        session.set_foreground(true);
        tokio::time::timeout(
            Duration::from_secs(5),
            states.wait_for(|s| matches!(s, ConnectionState::Connecting { .. })),
        )
        .await
        .unwrap()
        .unwrap();
        session.close();
        tokio::time::timeout(
            Duration::from_secs(5),
            states.wait_for(|s| matches!(s, ConnectionState::Closed)),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(matches!(session.connected().await, Err(SshError::Closed)));
    }

    #[tokio::test]
    async fn reconnect_now_cuts_the_backoff() {
        let policy = ReconnectPolicy {
            initial_delay: Duration::from_secs(60),
            max_delay: Duration::from_secs(60),
            jitter_percent: 0,
            ..ReconnectPolicy::default()
        };
        let recorder = Arc::new(Recorder::default());
        let session = unreachable_session(policy, Arc::clone(&recorder));
        let mut states = session.subscribe();
        states
            .wait_for(|s| matches!(s, ConnectionState::Reconnecting { .. }))
            .await
            .unwrap();
        let started = Instant::now();
        session.reconnect_now();
        states
            .wait_for(|s| matches!(s, ConnectionState::Connecting { .. }))
            .await
            .unwrap();
        assert!(started.elapsed() < Duration::from_secs(5));
        session.close();
    }
}
