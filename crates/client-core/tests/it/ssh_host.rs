//! A host reached over plain SSH (docs/SSH.md §5): the fallback pane, then the one-tap
//! upgrade: bootstrap the daemon and pair with the returned ticket over iroh.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use client_core::proto::{PaneId, PaneSize};
use client_core::ssh::{
    self, AuthMethod, ConnectOptions, Credentials, HostKeyPolicy, HostSpec, Keepalive, KnownHosts,
    ReconnectPolicy, SecretKey, Session, Target,
};
use client_core::{
    Client, ClientConfig, ClientEvent, EventQueue, RESTART_MARKER, SshPane, SshPaneOptions,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::UnboundedReceiver;

struct Env {
    host: String,
    user: String,
    keys: PathBuf,
}

fn env() -> Env {
    let var = |name: &str| {
        std::env::var(name).unwrap_or_else(|_| {
            panic!("{name} is not set: run scripts/ssh-test-vm.sh and source target/ssh-test/env")
        })
    };
    Env {
        host: var("UN_SSH_TEST_HOST"),
        user: var("UN_SSH_TEST_USER"),
        keys: PathBuf::from(var("UN_SSH_TEST_KEYS")),
    }
}

fn options(env: &Env) -> ConnectOptions {
    let key = SecretKey::load(env.keys.join("id_ed25519"), None).unwrap();
    let mut options = ConnectOptions::new(
        Credentials::new().with(AuthMethod::Key(key)),
        Arc::new(KnownHosts::in_memory()),
        HostKeyPolicy::AcceptNew,
    );
    options.keepalive = Keepalive {
        interval: Duration::from_secs(1),
        count_max: 3,
        probe_timeout: Duration::from_secs(1),
    };
    options.timeouts.handshake = Duration::from_secs(2);
    options
}

async fn next_matching(
    events: &mut UnboundedReceiver<ClientEvent>,
    mut f: impl FnMut(&ClientEvent) -> bool,
) -> ClientEvent {
    tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let e = events.recv().await.expect("events flowing");
            if std::env::var_os("UN_TEST_TRACE_EVENTS").is_some() {
                eprintln!("event: {e:?}");
            }
            if f(&e) {
                return e;
            }
        }
    })
    .await
    .expect("event in time")
}

/// A pane's event stream: every `PaneBytes` that passes is checked for `seq` continuity
/// and kept, whatever event is being waited for.
struct Stream {
    events: UnboundedReceiver<ClientEvent>,
    next_seq: u64,
    bytes: Vec<u8>,
    /// Bytes before this offset were already matched by `read_until`.
    cursor: usize,
}

impl Stream {
    fn new(events: UnboundedReceiver<ClientEvent>) -> Self {
        Self {
            events,
            next_seq: 0,
            bytes: Vec::new(),
            cursor: 0,
        }
    }

    async fn until(&mut self, mut f: impl FnMut(&ClientEvent) -> bool) -> ClientEvent {
        let Self {
            events,
            next_seq,
            bytes,
            ..
        } = self;
        next_matching(events, |e| {
            if let ClientEvent::PaneBytes { seq, data, .. } = e {
                assert_eq!(*seq, *next_seq, "the stream has no gaps");
                *next_seq += data.len() as u64;
                bytes.extend_from_slice(data);
            }
            f(e)
        })
        .await
    }

    /// Waits until `needle` appears after the previous match.
    async fn read_until(&mut self, needle: &[u8]) {
        let found = |bytes: &[u8], cursor: usize| {
            bytes[cursor..]
                .windows(needle.len())
                .position(|w| w == needle)
                .map(|i| cursor + i + needle.len())
        };
        if let Some(end) = found(&self.bytes, self.cursor) {
            self.cursor = end;
            return;
        }
        let cursor = self.cursor;
        let mut end = None;
        let mut local = self.bytes.clone();
        self.until(|e| {
            if let ClientEvent::PaneBytes { data, .. } = e {
                local.extend_from_slice(data);
                end = found(&local, cursor);
            }
            end.is_some()
        })
        .await;
        self.cursor = end.expect("matched");
    }

    fn since(&self, from: usize) -> &[u8] {
        &self.bytes[from..]
    }
}

/// Forwards to the sshd; `cut` swallows all traffic without closing (a dead NAT mapping).
async fn proxy(upstream: String, cut: Arc<AtomicBool>) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((client, _)) = listener.accept().await {
            let Ok(server) = TcpStream::connect(&upstream).await else {
                continue;
            };
            let cut = Arc::clone(&cut);
            tokio::spawn(async move {
                let (mut cr, mut cw) = client.into_split();
                let (mut sr, mut sw) = server.into_split();
                let c2 = Arc::clone(&cut);
                let up = async move {
                    let mut buf = vec![0u8; 32 << 10];
                    while let Ok(n @ 1..) = cr.read(&mut buf).await {
                        if !c2.load(Ordering::SeqCst) && sw.write_all(&buf[..n]).await.is_err() {
                            break;
                        }
                    }
                };
                let down = async move {
                    let mut buf = vec![0u8; 32 << 10];
                    while let Ok(n @ 1..) = sr.read(&mut buf).await {
                        if !cut.load(Ordering::SeqCst) && cw.write_all(&buf[..n]).await.is_err() {
                            break;
                        }
                    }
                };
                tokio::join!(up, down);
            });
        }
    });
    port
}

#[tokio::test(flavor = "multi_thread")]
#[cfg_attr(not(ssh_test_host), ignore = "needs UN_SSH_TEST_HOST (docs/SSH.md)")]
async fn fallback_pane_survives_a_drop_with_a_new_shell() {
    let env = env();
    let cut = Arc::new(AtomicBool::new(false));
    let port = proxy(format!("{}:22", env.host), Arc::clone(&cut)).await;
    let session = Session::start(
        Target::direct(HostSpec::new("127.0.0.1", &env.user).with_port(port)),
        options(&env),
        ReconnectPolicy {
            max_delay: Duration::from_millis(500),
            ..ReconnectPolicy::default()
        },
        None,
    );
    let (listener, events) = EventQueue::channel();
    let pane_id = PaneId(9001);
    let size = PaneSize {
        cols: 80,
        rows: 24,
        width_px: 0,
        height_px: 0,
    };
    let pane = SshPane::open(
        session.clone(),
        SshPaneOptions::new(pane_id, size),
        listener,
    );
    let mut events = Stream::new(events);
    let t = Instant::now();
    events
        .until(|e| matches!(e, ClientEvent::Connected { resumed: false, .. }))
        .await;
    eprintln!("ssh pane up in {:?}", t.elapsed());

    pane.send_input(b"echo pane-$((40+2))\n".to_vec());
    events.read_until(b"pane-42").await;

    pane.resize(PaneSize {
        cols: 100,
        rows: 30,
        ..size
    });
    let ClientEvent::PaneResized {
        size: resized, seq, ..
    } = events
        .until(|e| matches!(e, ClientEvent::PaneResized { .. }))
        .await
    else {
        unreachable!()
    };
    assert_eq!((resized.cols, resized.rows), (100, 30));
    assert_eq!(
        seq, events.next_seq,
        "resizes are placed in the byte stream"
    );
    pane.send_input(b"stty size\n".to_vec());
    events.read_until(b"30 100").await;

    // Silent drop: keepalives notice, the pane says so, and comes back with a new shell
    // once the path heals; the byte stream continues without a gap.
    cut.store(true, Ordering::SeqCst);
    let t = Instant::now();
    events
        .until(|e| matches!(e, ClientEvent::Disconnected { .. }))
        .await;
    eprintln!("pane saw the drop after {:?}", t.elapsed());
    // Typed while disconnected: dropped, never replayed into the next shell.
    pane.send_input(b"echo typed-while-$((0+0))-down\n".to_vec());
    cut.store(false, Ordering::SeqCst);
    let t = Instant::now();
    events
        .until(|e| matches!(e, ClientEvent::Connected { resumed: true, .. }))
        .await;
    eprintln!("pane back {:?} after the path healed", t.elapsed());
    let mark = events.bytes.len();
    events.read_until(RESTART_MARKER).await;
    pane.send_input(b"echo again-$((1+1))\n".to_vec());
    events.read_until(b"again-2").await;
    assert!(
        !events
            .since(mark)
            .windows(14)
            .any(|w| w == b"typed-while-0-")
    );

    // The shell exiting closes the pane.
    pane.send_input(b"exit\n".to_vec());
    events
        .until(|e| matches!(e, ClientEvent::PaneClosed { pane_id: p } if *p == pane_id))
        .await;
    session.close();
}

#[tokio::test(flavor = "multi_thread")]
#[cfg_attr(not(ssh_test_host), ignore = "needs UN_SSH_TEST_HOST (docs/SSH.md)")]
async fn tmux_pane_reattaches_after_a_drop() {
    let env = env();
    let session = Session::start(
        Target::direct(HostSpec::new(&env.host, &env.user)),
        options(&env),
        ReconnectPolicy::default(),
        None,
    );
    let conn = session.connected().await.unwrap();
    if !conn.exec("command -v tmux").await.unwrap().success() {
        eprintln!("tmux not installed on the test host; skipping");
        return;
    }
    let name = format!("un-test-{}", std::process::id());
    let (listener, events) = EventQueue::channel();
    let mut opts = SshPaneOptions::new(
        PaneId(1),
        PaneSize {
            cols: 80,
            rows: 24,
            width_px: 0,
            height_px: 0,
        },
    );
    opts.tmux_session = Some(name.clone());
    let pane = SshPane::open(session.clone(), opts, listener);
    let mut events = Stream::new(events);
    events
        .until(|e| matches!(e, ClientEvent::Connected { .. }))
        .await;
    pane.send_input(b"export UN_MARK=kept-$((3*3)); echo set\n".to_vec());
    events.read_until(b"\r\nset").await;
    session.reconnect_now();
    events
        .until(|e| matches!(e, ClientEvent::Connected { resumed: true, .. }))
        .await;
    pane.send_input(b"echo $UN_MARK\n".to_vec());
    events.read_until(b"kept-9").await;
    assert!(
        !events
            .bytes
            .windows(RESTART_MARKER.len())
            .any(|w| w == RESTART_MARKER)
    );
    let conn = session.connected().await.unwrap();
    conn.exec(&format!("tmux kill-session -t {name}"))
        .await
        .unwrap();
    drop(pane);
    session.close();
}

/// The static daemon build for the test VM (made by scripts/ssh-test-vm.sh).
fn hostd_binary(platform: ssh::HostPlatform) -> PathBuf {
    if let Some(p) = std::env::var_os("UN_SSH_TEST_HOSTD") {
        return PathBuf::from(p);
    }
    let arch = match platform {
        ssh::HostPlatform::LinuxAarch64 => "aarch64",
        ssh::HostPlatform::LinuxX86_64 => "x86_64",
        other => panic!("no test build for {other:?}"),
    };
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/ssh-test/bin")
        .join(format!("{}-{arch}-linux", brand::DAEMON_BIN))
}

#[tokio::test(flavor = "multi_thread")]
#[cfg_attr(not(ssh_test_host), ignore = "needs UN_SSH_TEST_HOST (docs/SSH.md)")]
async fn bootstrap_then_pair_over_iroh() {
    let env = env();
    let target = Target::direct(HostSpec::new(&env.host, &env.user));
    let started = Instant::now();
    let conn = ssh::Connection::connect(&target, &options(&env))
        .await
        .unwrap();
    let platform = ssh::detect_platform(&conn).await.unwrap();
    // A host without the daemon: uninstall whatever an earlier run left.
    conn.exec(&format!(
        "systemctl --user disable --now {bin}.service; rm -f ~/.local/bin/{bin}",
        bin = brand::DAEMON_BIN
    ))
    .await
    .unwrap();
    let binaries = ssh::HostdBinaries {
        linux_aarch64: Some(ssh::BinarySource::Path(hostd_binary(platform))),
        linux_x86_64: Some(ssh::BinarySource::Path(hostd_binary(platform))),
        ..ssh::HostdBinaries::default()
    };
    struct Timing(Instant);
    impl ssh::BootstrapListener for Timing {
        fn on_step(&self, step: ssh::BootstrapStep) {
            eprintln!("  {:>8.1?} {step:?}", self.0.elapsed());
        }
    }
    let options = ssh::BootstrapOptions {
        listener: Some(Arc::new(Timing(Instant::now()))),
        ..ssh::BootstrapOptions::default()
    };
    let report = ssh::bootstrap(&conn, &binaries, &options).await.unwrap();
    eprintln!(
        "bootstrap ({:?}, {:?}) in {:?}",
        report.action,
        report.service,
        started.elapsed()
    );
    assert_eq!(report.action, ssh::InstallAction::Installed);
    assert_eq!(report.service, ssh::ServiceMode::Service);

    // Pair with the ticket, exactly as the app would after "install helper".
    let t = Instant::now();
    let (listener, mut events) = EventQueue::channel();
    let client = Client::connect(
        &report.ticket,
        ClientConfig::new(ClientConfig::generate_key()),
        listener,
    )
    .unwrap();
    next_matching(&mut events, |e| matches!(e, ClientEvent::Connected { .. })).await;
    eprintln!("paired over iroh in {:?}", t.elapsed());
    client.attach(None);
    let ClientEvent::Layout { layout } =
        next_matching(&mut events, |e| matches!(e, ClientEvent::Layout { .. })).await
    else {
        unreachable!()
    };
    let pane = layout.tabs[0].focused;
    client.subscribe(pane);
    next_matching(&mut events, |e| {
        matches!(e, ClientEvent::PaneSnapshot { .. })
    })
    .await;
    // A freshly (re)started daemon may still be starting the pane's shell; keystrokes sent
    // before it reads the terminal can be lost, so retype until the answer shows.
    let mut seen = Vec::new();
    let mut echoed = false;
    for _ in 0..6 {
        client.send_input(pane, b"echo daemon-$((5*5))\r".to_vec());
        echoed = tokio::time::timeout(Duration::from_secs(5), async {
            while let Some(e) = events.recv().await {
                if let ClientEvent::PaneBytes { data, .. } = e {
                    seen.extend_from_slice(&data);
                }
                if seen.windows(9).any(|w| w == b"daemon-25") {
                    return;
                }
            }
        })
        .await
        .is_ok();
        if echoed {
            break;
        }
    }
    assert!(
        echoed,
        "no echo from the daemon pane: {:?}",
        String::from_utf8_lossy(&seen)
    );
    eprintln!(
        "ssh → bootstrap → iroh pane echo: {:?} total",
        started.elapsed()
    );
    drop(client);
}
