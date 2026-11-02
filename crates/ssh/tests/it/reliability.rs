//! Keepalives, dead-peer detection and reconnects against the real sshd, with failures
//! injected by a blackholing proxy (a silently dropped NAT mapping) and by freezing the
//! server's session process (SIGSTOP).

use std::sync::Arc;
use std::time::{Duration, Instant};

use ssh::{
    ConnectOptions, Connection, ConnectionState, Keepalive, ReconnectPolicy, Session, Target,
};

use crate::common::{Proxy, env};

fn fast_keepalive() -> Keepalive {
    Keepalive {
        interval: Duration::from_secs(1),
        count_max: 3,
        probe_timeout: Duration::from_millis(1500),
    }
}

async fn via_proxy(proxy: &Proxy, keepalive: Keepalive) -> (Connection, ConnectOptions, Target) {
    let env = env();
    let mut options = env.options(env.key_creds());
    options.keepalive = keepalive;
    let target = Target::direct(proxy.spec(&env.user));
    let conn = Connection::connect(&target, &options).await.unwrap();
    (conn, options, target)
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn keepalives_keep_an_idle_connection_and_measure_rtt() {
    let env = env();
    let mut options = env.options(env.key_creds());
    options.keepalive = fast_keepalive();
    let conn = Connection::connect(&env.target(), &options).await.unwrap();
    tokio::time::sleep(Duration::from_millis(3500)).await;
    assert!(!conn.is_dead());
    let rtt = conn.rtt().expect("keepalives were answered");
    assert!(conn.since_last_reply() < Duration::from_millis(1500));
    let ping = conn.ping(Duration::from_secs(2)).await.unwrap();
    eprintln!("keepalive rtt {rtt:?}, ping {ping:?}");
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn silent_drop_is_detected_by_keepalives() {
    let env = env();
    let proxy = Proxy::start(format!("{}:22", env.host)).await;
    let (conn, ..) = via_proxy(&proxy, fast_keepalive()).await;
    assert!(conn.exec("true").await.unwrap().success());
    proxy.blackhole(true);
    let t = Instant::now();
    let why = tokio::time::timeout(Duration::from_secs(10), conn.closed())
        .await
        .expect("dead peer not detected");
    let took = t.elapsed();
    eprintln!("idle silent drop detected in {took:?}: {why}");
    assert!(why.contains("keepalives unanswered"), "{why}");
    // interval × count_max after the last answer, plus at most one interval of phase.
    assert!(
        took >= Duration::from_secs(2) && took <= Duration::from_millis(4500),
        "{took:?}"
    );
    assert!(conn.is_dead());
    // Work on a dead connection fails instead of hanging.
    let r = tokio::time::timeout(Duration::from_secs(5), conn.exec("true")).await;
    assert!(matches!(r, Ok(Err(_))), "{r:?}");
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn fast_probe_and_input_after_silence() {
    let env = env();
    let proxy = Proxy::start(format!("{}:22", env.host)).await;
    // Slow keepalives, so only the probe can catch the drop quickly.
    let keepalive = Keepalive {
        interval: Duration::from_secs(30),
        count_max: 3,
        probe_timeout: Duration::from_millis(1000),
    };
    let (conn, ..) = via_proxy(&proxy, keepalive).await;
    conn.ping(Duration::from_secs(2)).await.unwrap();
    proxy.blackhole(true);
    let t = Instant::now();
    conn.probe(); // what the app does on foreground / network change
    let why = tokio::time::timeout(Duration::from_secs(5), conn.closed())
        .await
        .expect("probe did not detect the dead peer");
    eprintln!("probe detected the drop in {:?}: {why}", t.elapsed());
    assert!(t.elapsed() < Duration::from_millis(1600));
    assert!(why.contains("probe"), "{why}");

    // Typing into a shell after a keepalive interval of silence triggers the same probe.
    let proxy = Proxy::start(format!("{}:22", env.host)).await;
    let keepalive = Keepalive {
        interval: Duration::from_secs(2),
        count_max: 100,
        probe_timeout: Duration::from_millis(1000),
    };
    let (conn, ..) = via_proxy(&proxy, keepalive).await;
    let (shell, _out) = conn
        .open_shell(&ssh::PtyRequest::new(80, 24))
        .await
        .unwrap();
    proxy.blackhole(true);
    tokio::time::sleep(Duration::from_millis(2500)).await;
    let t = Instant::now();
    let _ = shell.write(b"ls\n").await;
    tokio::time::timeout(Duration::from_secs(3), conn.closed())
        .await
        .expect("input after silence did not probe");
    eprintln!(
        "input-triggered probe detected the drop in {:?}",
        t.elapsed()
    );
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn frozen_sshd_is_detected() {
    let env = env();
    let mut options = env.options(env.key_creds());
    options.keepalive = fast_keepalive();
    let conn = Connection::connect(&env.target(), &options).await.unwrap();
    // The shell's parent is this connection's unprivileged sshd process.
    let pid = conn
        .exec("echo $PPID")
        .await
        .unwrap()
        .check()
        .unwrap()
        .stdout_text()
        .trim()
        .to_owned();
    let admin = env.connect().await;
    admin
        .exec(&format!("kill -STOP {pid}"))
        .await
        .unwrap()
        .check()
        .unwrap();
    let t = Instant::now();
    let why = tokio::time::timeout(Duration::from_secs(10), conn.closed()).await;
    admin
        .exec(&format!("kill -CONT {pid}; kill {pid}"))
        .await
        .unwrap();
    let why = why.expect("frozen server not detected");
    eprintln!("frozen sshd detected in {:?}: {why}", t.elapsed());
    assert!(t.elapsed() <= Duration::from_millis(4500));
}

#[derive(Default)]
struct States(std::sync::Mutex<Vec<(Instant, ConnectionState)>>);

impl ssh::SessionListener for States {
    fn on_state(&self, state: ConnectionState) {
        self.0.lock().unwrap().push((Instant::now(), state));
    }
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn session_reconnects_after_a_drop_and_reports_states() {
    let env = env();
    let proxy = Proxy::start(format!("{}:22", env.host)).await;
    let mut options = env.options(env.key_creds());
    options.keepalive = fast_keepalive();
    options.timeouts.handshake = Duration::from_secs(2);
    let states = Arc::new(States::default());
    let session = Session::start(
        Target::direct(proxy.spec(&env.user)),
        options,
        ReconnectPolicy {
            max_delay: Duration::from_secs(1),
            ..ReconnectPolicy::default()
        },
        Some(states.clone()),
    );
    let first = session.connected().await.unwrap();
    assert!(first.exec("true").await.unwrap().success());
    let mut rx = session.subscribe();

    // Drop the path silently; the session notices, retries (the proxy still swallows new
    // connections' bytes, so attempts time out), and comes back once the path heals.
    proxy.blackhole(true);
    let t = Instant::now();
    rx.wait_for(|s| matches!(s, ConnectionState::Reconnecting { .. }))
        .await
        .unwrap();
    let detected = t.elapsed();
    tokio::time::sleep(Duration::from_secs(3)).await;
    proxy.blackhole(false);
    let healed = Instant::now();
    rx.wait_for(|s| matches!(s, ConnectionState::Connected { generation: 2.. }))
        .await
        .unwrap();
    eprintln!(
        "drop detected after {detected:?}; reconnected {:?} after the path healed",
        healed.elapsed()
    );
    let second = session.connected().await.unwrap();
    assert!(first.is_dead());
    assert!(second.exec("true").await.unwrap().success());

    // reconnect_now swaps the connection at once.
    session.reconnect_now();
    rx.wait_for(|s| matches!(s, ConnectionState::Connected { generation: 3.. }))
        .await
        .unwrap();
    session.close();
    rx.wait_for(|s| matches!(s, ConnectionState::Closed))
        .await
        .unwrap();

    let log: Vec<String> = states
        .0
        .lock()
        .unwrap()
        .iter()
        .map(|(_, s)| {
            format!("{s:?}")
                .split([' ', '{'])
                .next()
                .unwrap()
                .to_owned()
        })
        .collect();
    eprintln!("states: {log:?}");
    assert_eq!(log.first().map(String::as_str), Some("Connecting"));
    assert!(log.iter().any(|s| s == "Reconnecting"));
    assert_eq!(log.last().map(String::as_str), Some("Closed"));
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn session_needs_attention_on_bad_credentials() {
    let env = env();
    let session = Session::start(
        env.target(),
        env.options(ssh::Credentials::new().with(ssh::AuthMethod::Password("wrong".into()))),
        ReconnectPolicy::default(),
        None,
    );
    match session.connected().await {
        Err(ssh::SshError::AuthFailed { .. }) => {}
        other => panic!("{other:?}"),
    }
    assert!(matches!(
        session.state(),
        ConnectionState::NeedsAttention { .. }
    ));
    session.close();
}
