//! Test environment and helpers: credentials from `target/ssh-test/env`, a TCP proxy that
//! can silently blackhole traffic (a NAT mapping dropped on the floor), and quick connects.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use ssh::{
    AuthMethod, ConnectOptions, Connection, Credentials, HostKeyPolicy, HostSpec, KnownHosts,
    SecretKey, Target,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

pub struct Env {
    pub host: String,
    pub user: String,
    pub password: String,
    pub keys: PathBuf,
}

/// The test sshd. Panics with instructions if the environment is missing (the tests are
/// ignored then unless run explicitly).
pub fn env() -> Env {
    let var = |name: &str| {
        std::env::var(name).unwrap_or_else(|_| {
            panic!("{name} is not set: run scripts/ssh-test-vm.sh and source target/ssh-test/env")
        })
    };
    Env {
        host: var("GUDO_SSH_TEST_HOST"),
        user: var("GUDO_SSH_TEST_USER"),
        password: var("GUDO_SSH_TEST_PASSWORD"),
        keys: PathBuf::from(var("GUDO_SSH_TEST_KEYS")),
    }
}

impl Env {
    pub fn spec(&self) -> HostSpec {
        HostSpec::new(&self.host, &self.user)
    }

    pub fn target(&self) -> Target {
        Target::direct(self.spec())
    }

    pub fn key(&self, name: &str) -> SecretKey {
        SecretKey::load(self.keys.join(name), None).unwrap()
    }

    pub fn key_creds(&self) -> Credentials {
        Credentials::new().with(AuthMethod::Key(self.key("id_ed25519")))
    }

    pub fn options(&self, creds: Credentials) -> ConnectOptions {
        ConnectOptions::new(
            creds,
            Arc::new(KnownHosts::in_memory()),
            HostKeyPolicy::AcceptNew,
        )
    }

    pub async fn connect(&self) -> Connection {
        Connection::connect(&self.target(), &self.options(self.key_creds()))
            .await
            .unwrap()
    }
}

/// A TCP forwarder to `upstream` whose traffic can be frozen without closing sockets.
pub struct Proxy {
    pub addr: SocketAddr,
    blackhole: Arc<AtomicBool>,
}

impl Proxy {
    pub async fn start(upstream: String) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let blackhole = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&blackhole);
        tokio::spawn(async move {
            while let Ok((client, _)) = listener.accept().await {
                let upstream = upstream.clone();
                let flag = Arc::clone(&flag);
                tokio::spawn(async move {
                    let Ok(server) = TcpStream::connect(&upstream).await else {
                        return;
                    };
                    let (cr, cw) = client.into_split();
                    let (sr, sw) = server.into_split();
                    tokio::join!(
                        pump(cr, sw, Arc::clone(&flag)),
                        pump(sr, cw, Arc::clone(&flag))
                    );
                });
            }
        });
        Self { addr, blackhole }
    }

    /// Drops all traffic from now on (both directions), keeping the sockets open.
    pub fn blackhole(&self, on: bool) {
        self.blackhole.store(on, Ordering::SeqCst);
    }

    pub fn spec(&self, user: &str) -> HostSpec {
        HostSpec {
            host: self.addr.ip().to_string(),
            port: self.addr.port(),
            user: user.to_owned(),
            host_key_alias: None,
        }
    }
}

async fn pump(
    mut from: tokio::net::tcp::OwnedReadHalf,
    mut to: tokio::net::tcp::OwnedWriteHalf,
    blackhole: Arc<AtomicBool>,
) {
    let mut buf = vec![0u8; 32 * 1024];
    loop {
        let n = match from.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        if blackhole.load(Ordering::SeqCst) {
            // Swallow it, like a dead NAT mapping, and never close: the peer only learns
            // from its own timers.
            continue;
        }
        if to.write_all(&buf[..n]).await.is_err() {
            return;
        }
    }
}

/// Polls `f` until it is true or `timeout` passes.
pub async fn eventually(timeout: Duration, mut f: impl FnMut() -> bool) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    while tokio::time::Instant::now() < deadline {
        if f() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    f()
}
