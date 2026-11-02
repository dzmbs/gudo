//! Developer-workflow requests end to end: forwards (TCP, Unix, half-close, backpressure,
//! many connections), port detection, git status/diff/turns/review, worktrees with `PORT`,
//! files and transfers, the editor server (with fake `code` / openvscode-server), and the
//! attention feed.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use client_core::proto::{
    AttentionKind, AttentionSeen, AttentionUpdate, Axis, DeleteMode, DiffBase, EditorChoice,
    EditorKind, EditorLaunch, FileChange, FileKind, ForwardTarget, GitDiffRequest, LayoutOp,
    LineKind, OpOutcome, PaneLaunch, PortKind, ReviewNote, ReviewRequest, WorktreeCreate,
    WriteTarget, WsError,
};
use client_core::{ClientConfig, WorkspaceEvent, WorkspaceEventQueue};
use daemon::{Daemon, HookRequest};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UnixListener, UnixStream};
use tokio::sync::mpsc::UnboundedReceiver;

use crate::support::{TestClient, ms, start_with, ticket};

/// A daemon whose panes and policy use `home` as `$HOME`.
async fn start_home(state: &Path, home: &Path) -> Daemon {
    let home = home.to_owned();
    start_with(state, move |c| {
        c.pane_env
            .push(("HOME".into(), home.to_string_lossy().into_owned()));
        c.fs_allow.push(home);
        c.port_scan_interval = Duration::from_millis(300);
    })
    .await
}

fn canonical_tempdir() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().canonicalize().unwrap();
    (dir, path)
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

async fn connected(daemon: &Daemon) -> TestClient {
    let mut c = TestClient::connect(&ticket(daemon), ClientConfig::generate_key());
    c.until("connected", |c| c.connected > 0).await;
    c
}

async fn next_event(
    events: &mut UnboundedReceiver<WorkspaceEvent>,
    what: &str,
    mut pick: impl FnMut(&WorkspaceEvent) -> bool,
) -> WorkspaceEvent {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let e = events.recv().await.expect("listener alive");
            if pick(&e) {
                return e;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for {what}"))
}

// --- forwarding ----------------------------------------------------------------------------

async fn echo_server() -> u16 {
    let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = server.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut tcp, _)) = server.accept().await {
            tokio::spawn(async move {
                let (mut r, mut w) = tcp.split();
                let _ = tokio::io::copy(&mut r, &mut w).await;
            });
        }
    });
    port
}

/// A connection made while the link is down waits for it instead of failing (a browser's
/// first reconnect attempt then works); a link that breaks under an open connection resets
/// both ends, so neither takes it for an orderly close.
#[tokio::test(flavor = "multi_thread")]
async fn forwards_wait_out_a_reconnect_and_reset_on_a_broken_link() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let daemon = start_home(&state, &home).await;
    let mut c = connected(&daemon).await;
    let echo = echo_server().await;
    let local = c
        .client
        .forward(0, ForwardTarget::Tcp { port: echo })
        .unwrap();

    c.client.suspend();
    let mut early = TcpStream::connect(("127.0.0.1", local)).await.unwrap();
    early.write_all(b"before the link").await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    c.client.reconnect();
    let mut got = [0; 15];
    tokio::time::timeout(Duration::from_secs(20), early.read_exact(&mut got))
        .await
        .expect("answered once the link is back")
        .unwrap();
    assert_eq!(&got, b"before the link");
    c.until("connected again", |c| c.connected > 1).await;

    // The host side sees how its connection ended.
    let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = server.local_addr().unwrap().port();
    let (ended_tx, ended_rx) = tokio::sync::oneshot::channel();
    tokio::spawn(async move {
        let (mut tcp, _) = server.accept().await.unwrap();
        let mut buf = [0; 64];
        let ended = loop {
            match tcp.read(&mut buf).await {
                Ok(0) => break Ok(()),
                Ok(_) => tcp.write_all(b"pong").await.unwrap(),
                Err(e) => break Err(e.kind()),
            }
        };
        let _ = ended_tx.send(ended);
    });
    let local = c.client.forward(0, ForwardTarget::Tcp { port }).unwrap();
    let mut tcp = TcpStream::connect(("127.0.0.1", local)).await.unwrap();
    tcp.write_all(b"ping").await.unwrap();
    let mut pong = [0; 4];
    tcp.read_exact(&mut pong).await.unwrap();

    c.client.reconnect();
    let mut rest = Vec::new();
    let here = tokio::time::timeout(Duration::from_secs(10), tcp.read_to_end(&mut rest))
        .await
        .expect("the local end learns the link broke");
    assert_eq!(
        here.map_err(|e| e.kind()),
        Err(std::io::ErrorKind::ConnectionReset),
        "reset, not a clean end"
    );
    let there = tokio::time::timeout(Duration::from_secs(10), ended_rx)
        .await
        .expect("the host end learns it too")
        .unwrap();
    assert_eq!(there, Err(std::io::ErrorKind::ConnectionReset));
}

#[tokio::test(flavor = "multi_thread")]
async fn forwards_tcp_and_unix_with_half_close_and_backpressure() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let daemon = start_home(&state, &home).await;
    let c = connected(&daemon).await;

    // Many concurrent connections through one forward, each echoing its own data.
    let echo = echo_server().await;
    let local = c
        .client
        .forward(0, ForwardTarget::Tcp { port: echo })
        .unwrap();
    let mut tasks = Vec::new();
    for i in 0..64u32 {
        tasks.push(tokio::spawn(async move {
            let mut tcp = TcpStream::connect(("127.0.0.1", local)).await.unwrap();
            let data: Vec<u8> = (0..100_000u32).map(|b| (b ^ i) as u8).collect();
            let (mut r, mut w) = tcp.split();
            let send = async {
                w.write_all(&data).await.unwrap();
                w.shutdown().await.unwrap();
            };
            let mut back = Vec::new();
            let recv = r.read_to_end(&mut back);
            let ((), got) = tokio::join!(send, recv);
            got.unwrap();
            assert_eq!(back, data, "connection {i}");
        }));
    }
    for t in tasks {
        tokio::time::timeout(Duration::from_secs(30), t)
            .await
            .expect("echo in time")
            .unwrap();
    }

    // Half-close: the server answers only after the client's EOF arrives, on the same
    // connection.
    let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let half_port = server.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (mut tcp, _) = server.accept().await.unwrap();
        let mut got = Vec::new();
        tcp.read_to_end(&mut got).await.unwrap();
        tcp.write_all(format!("got {} bytes", got.len()).as_bytes())
            .await
            .unwrap();
    });
    let local_half = c
        .client
        .forward(0, ForwardTarget::Tcp { port: half_port })
        .unwrap();
    let mut tcp = TcpStream::connect(("127.0.0.1", local_half)).await.unwrap();
    tcp.write_all(&[7; 12345]).await.unwrap();
    tcp.shutdown().await.unwrap();
    let mut answer = String::new();
    tokio::time::timeout(Duration::from_secs(10), tcp.read_to_string(&mut answer))
        .await
        .expect("answer after half-close")
        .unwrap();
    assert_eq!(answer, "got 12345 bytes");

    // Backpressure: a server that does not read stalls the sender instead of the forward
    // buffering everything; once it reads, every byte arrives.
    let server = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let slow_port = server.local_addr().unwrap().port();
    let (go_tx, go_rx) = tokio::sync::oneshot::channel::<()>();
    let reader = tokio::spawn(async move {
        let (mut tcp, _) = server.accept().await.unwrap();
        let _ = go_rx.await;
        let mut n = 0usize;
        let mut buf = vec![0; 1 << 16];
        loop {
            match tcp.read(&mut buf).await.unwrap() {
                0 => return n,
                k => n += k,
            }
        }
    });
    let local_slow = c
        .client
        .forward(0, ForwardTarget::Tcp { port: slow_port })
        .unwrap();
    let total = 256usize << 20;
    let writer = tokio::spawn(async move {
        let mut tcp = TcpStream::connect(("127.0.0.1", local_slow)).await.unwrap();
        let chunk = vec![1u8; 1 << 20];
        let mut written = 0usize;
        while written < total {
            tcp.write_all(&chunk).await.unwrap();
            written += chunk.len();
        }
        tcp.shutdown().await.unwrap();
    });
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(
        !writer.is_finished(),
        "256 MiB were accepted while nobody read: no backpressure"
    );
    go_tx.send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(120), writer)
        .await
        .expect("writer finishes once the server reads")
        .unwrap();
    assert_eq!(reader.await.unwrap(), total);

    // A Unix socket inside the allowed directories.
    let sock = home.join("echo.sock");
    let unix = UnixListener::bind(&sock).unwrap();
    tokio::spawn(async move {
        while let Ok((mut s, _)) = unix.accept().await {
            tokio::spawn(async move {
                let (mut r, mut w) = s.split();
                let _ = tokio::io::copy(&mut r, &mut w).await;
            });
        }
    });
    let local_unix = c
        .client
        .forward(0, ForwardTarget::Unix { path: s(&sock) })
        .unwrap();
    let mut tcp = TcpStream::connect(("127.0.0.1", local_unix)).await.unwrap();
    tcp.write_all(b"over a unix socket").await.unwrap();
    let mut back = [0; 18];
    tokio::time::timeout(Duration::from_secs(10), tcp.read_exact(&mut back))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&back, b"over a unix socket");

    // A socket outside them is refused: the local connection just closes.
    let outside = tempfile::tempdir().unwrap();
    let sock2 = outside.path().join("x.sock");
    let _keep = std::os::unix::net::UnixListener::bind(&sock2).unwrap();
    let local_denied = c
        .client
        .forward(0, ForwardTarget::Unix { path: s(&sock2) })
        .unwrap();
    let mut tcp = TcpStream::connect(("127.0.0.1", local_denied))
        .await
        .unwrap();
    let mut buf = [0; 1];
    let n = tokio::time::timeout(Duration::from_secs(10), tcp.read(&mut buf))
        .await
        .unwrap()
        .unwrap_or(0);
    assert_eq!(n, 0);

    // Stopping a forward closes its listener.
    assert!(c.client.stop_forward(local));
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(TcpStream::connect(("127.0.0.1", local)).await.is_err());
    let _unused = UnixStream::connect(&sock).await;
    drop(c);
    daemon.shutdown().await;
}

/// Throughput and added latency of a forward over loopback iroh (printed; run with
/// `--release --nocapture` for meaningful numbers).
#[tokio::test(flavor = "multi_thread")]
async fn forward_throughput_and_latency() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let daemon = start_home(&state, &home).await;
    let c = connected(&daemon).await;

    // A sink that counts bytes and answers with one byte at EOF.
    let sink = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let sink_port = sink.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut tcp, _)) = sink.accept().await {
            tokio::spawn(async move {
                let mut buf = vec![0; 1 << 16];
                while tcp.read(&mut buf).await.unwrap_or(0) > 0 {}
                let _ = tcp.write_all(b"k").await;
            });
        }
    });
    let local = c
        .client
        .forward(0, ForwardTarget::Tcp { port: sink_port })
        .unwrap();
    let size = 128usize << 20;
    let chunk = vec![3u8; 1 << 20];
    let mut rates = Vec::new();
    for _ in 0..3 {
        let mut tcp = TcpStream::connect(("127.0.0.1", local)).await.unwrap();
        let start = Instant::now();
        for _ in 0..size / chunk.len() {
            tcp.write_all(&chunk).await.unwrap();
        }
        tcp.shutdown().await.unwrap();
        let mut k = [0; 1];
        tcp.read_exact(&mut k).await.unwrap();
        rates.push(size as f64 / start.elapsed().as_secs_f64() / 1e6);
    }

    // Round trips of one byte: direct vs through the forward.
    let echo = echo_server().await;
    let fwd = c
        .client
        .forward(0, ForwardTarget::Tcp { port: echo })
        .unwrap();
    let rtts = |port: u16| async move {
        let mut tcp = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        tcp.set_nodelay(true).unwrap();
        let mut samples = Vec::new();
        let mut b = [0u8; 1];
        for i in 0..300 {
            let start = Instant::now();
            tcp.write_all(&[i as u8]).await.unwrap();
            tcp.read_exact(&mut b).await.unwrap();
            samples.push(ms(start.elapsed()));
        }
        samples.sort_by(f64::total_cmp);
        (samples[150], samples[297])
    };
    let (direct50, direct99) = rtts(echo).await;
    let (fwd50, fwd99) = rtts(fwd).await;
    println!(
        "forward throughput MB/s: {:.0} {:.0} {:.0}; RTT direct p50 {direct50:.3} ms p99 \
         {direct99:.3} ms; forwarded p50 {fwd50:.3} ms p99 {fwd99:.3} ms",
        rates[0], rates[1], rates[2]
    );
    assert!(rates.iter().all(|r| *r > 5.0), "{rates:?}");
    drop(c);
    daemon.shutdown().await;
}

// --- ports ---------------------------------------------------------------------------------

fn have(program: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {program}")])
        .output()
        .is_ok_and(|o| o.status.success())
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

#[tokio::test(flavor = "multi_thread")]
async fn detects_listening_ports_and_printed_urls_per_pane() {
    if !have("python3") {
        eprintln!("skipping: python3 not installed");
        return;
    }
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let daemon = start_home(&state, &home).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let (listener, mut events) = WorkspaceEventQueue::channel();
    c.client.set_workspace_listener(listener);
    let pane = c.attach_and_follow().await;

    let port = free_port();
    c.type_line(
        pane,
        &format!(
            "echo '  Local:   http://localhost:{port}/'; exec python3 -m http.server {port} \
             --bind 127.0.0.1"
        ),
    );
    let WorkspaceEvent::PortsChanged { ports } =
        next_event(&mut events, "the server's port", |e| {
            matches!(e, WorkspaceEvent::PortsChanged { ports }
                if ports.iter().any(|p| p.port == port && p.url.is_some()))
        })
        .await
    else {
        unreachable!()
    };
    let info = ports.iter().find(|p| p.port == port).unwrap();
    assert_eq!(info.pane_id, Some(pane));
    assert!(info.loopback_only);
    assert_eq!(info.kind, PortKind::Http);
    assert_eq!(
        info.url.as_deref(),
        Some(format!("http://localhost:{port}/").as_str())
    );
    assert!(!info.process.is_empty());

    // An agent CLI's own listener (its sign-in callback) is never offered. Perl renames
    // itself as Node does for `process.title`.
    let port3 = free_port();
    c.op(LayoutOp::Split {
        pane_id: pane,
        axis: Axis::Vertical,
        launch: PaneLaunch::Command {
            argv: vec![
                "perl".into(),
                "-MIO::Socket::INET".into(),
                "-e".into(),
                "$0 = 'claude'; my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', \
                 LocalPort => shift, Listen => 5, ReuseAddr => 1) or die; \
                 while (my $c = $s->accept) { print $c \"HTTP/1.1 404 Not Found\\r\\n\
                 Content-Length: 0\\r\\n\\r\\n\"; close $c }"
                    .into(),
                port3.to_string(),
            ],
            cwd: None,
        },
    })
    .await;
    tokio::time::timeout(Duration::from_secs(20), async {
        while std::net::TcpStream::connect(("127.0.0.1", port3)).is_err() {
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .expect("the agent's listener is up");

    // A server nobody printed a URL for is probed. Python prints `http://[::]:port/`, which
    // would race the probe, so its output is discarded.
    let port2 = free_port();
    let OpOutcome::PaneCreated { pane_id: pane2 } = c
        .op(LayoutOp::Split {
            pane_id: pane,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Command {
                argv: vec![
                    "sh".into(),
                    "-c".into(),
                    format!("exec python3 -m http.server {port2} >/dev/null 2>&1"),
                ],
                cwd: None,
            },
        })
        .await
    else {
        panic!()
    };
    let ports = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let ports = c.client.list_ports().await.unwrap();
            if ports.iter().any(|p| p.port == port2) {
                return ports;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .expect("second server detected");
    let info = ports.iter().find(|p| p.port == port2).unwrap();
    assert_eq!(info.pane_id, Some(pane2));
    assert!(!info.loopback_only, "bound to all interfaces");
    assert_eq!(info.kind, PortKind::Http);
    assert_eq!(info.url, None);
    assert!(!ports.iter().any(|p| p.port == port3), "{ports:?}");

    // Closing the pane removes its port.
    c.op(LayoutOp::ClosePane { pane_id: pane2 }).await;
    next_event(&mut events, "port gone", |e| {
        matches!(e, WorkspaceEvent::PortsChanged { ports }
            if !ports.iter().any(|p| p.port == port2))
    })
    .await;
    drop(c);
    daemon.shutdown().await;
}

// --- git -----------------------------------------------------------------------------------

fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .current_dir(dir)
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "init.defaultBranch=main",
        ])
        .args(["-c", "commit.gpgsign=false"])
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

fn repo(home: &Path) -> PathBuf {
    let repo = home.join("repo");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-q"]);
    std::fs::write(repo.join("src/a.rs"), "fn a() {}\nfn b() {}\nfn c() {}\n").unwrap();
    let long: String = (0..60)
        .map(|i| format!("line {i} of a file to rename\n"))
        .collect();
    std::fs::write(repo.join("old_name.txt"), long).unwrap();
    std::fs::write(repo.join("gone.txt"), "bye\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "init"]);
    repo
}

async fn hook(daemon: &Daemon, state: &Path, pane: u64, event: &str, payload: serde_json::Value) {
    let token = std::fs::read_to_string(state.join("hook.token")).unwrap();
    let request = HookRequest {
        v: 1,
        token,
        pane: pane.to_string(),
        agent: "claude".into(),
        event: event.into(),
        seq: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64,
        payload,
    };
    let mut stream = UnixStream::connect(daemon.hook_socket()).await.unwrap();
    let mut line = serde_json::to_vec(&request).unwrap();
    line.push(b'\n');
    stream.write_all(&line).await.unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn git_status_diffs_turn_changes_and_review_notes() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let repo = repo(&home);
    let daemon = start_home(&state, &home).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let first = c.attach_and_follow().await;

    // An agent pane in the repository (a shell standing in for the agent: hooks drive it).
    let OpOutcome::PaneCreated { pane_id: pane } = c
        .op(LayoutOp::Split {
            pane_id: first,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Command {
                argv: vec!["cat".into()],
                cwd: Some(s(&repo)),
            },
        })
        .await
    else {
        panic!()
    };
    let payload = |name: &str| {
        serde_json::json!({
            "session_id": "11111111-2222-4333-8444-555555555555",
            "cwd": s(&repo),
            "hook_event_name": name,
            "prompt": "refactor",
            "last_assistant_message": "done",
        })
    };
    hook(
        &daemon,
        &state,
        pane.0,
        "UserPromptSubmit",
        payload("UserPromptSubmit"),
    )
    .await;
    // Wait for the start snapshot before changing anything.
    tokio::time::timeout(Duration::from_secs(10), async {
        while c.client.list_turns(pane).await.unwrap().is_empty() {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("turn recorded");

    // The "agent" edits: modify, rename, delete, add untracked, add a binary, stage one.
    std::fs::write(repo.join("src/a.rs"), "fn a() {}\nfn b2() {}\nfn c() {}\n").unwrap();
    std::fs::rename(repo.join("old_name.txt"), repo.join("new_name.txt")).unwrap();
    std::fs::remove_file(repo.join("gone.txt")).unwrap();
    std::fs::write(repo.join("untracked.md"), "# new\n").unwrap();
    std::fs::write(repo.join("blob.bin"), [0u8, 1, 2, 0, 255, 0]).unwrap();
    let big: String = (0..100_000).map(|i| format!("big line {i}\n")).collect();
    std::fs::write(repo.join("big.txt"), big).unwrap();
    git(&repo, &["add", "src/a.rs"]);
    hook(&daemon, &state, pane.0, "Stop", payload("Stop")).await;

    let status = c.client.git_status(s(&repo.join("src"))).await.unwrap();
    assert_eq!(status.root, s(&repo));
    assert_eq!(status.branch.as_deref(), Some("main"));
    let file = |p: &str| status.files.iter().find(|f| f.path == p).cloned();
    assert_eq!(file("src/a.rs").unwrap().staged, FileChange::Modified);
    assert_eq!(file("gone.txt").unwrap().unstaged, FileChange::Deleted);
    assert_eq!(
        file("untracked.md").unwrap().unstaged,
        FileChange::Untracked
    );

    // HEAD vs worktree: renames detected, untracked included, binary flagged, big capped.
    let diff = c
        .client
        .git_diff(GitDiffRequest {
            path: s(&repo),
            base: DiffBase::Head,
            files: vec![],
            context: 1,
            hunks: true,
        })
        .await
        .unwrap();
    let f = |p: &str| diff.files.iter().find(|f| f.path == p).cloned().unwrap();
    let renamed = f("new_name.txt");
    assert_eq!(renamed.change, FileChange::Renamed);
    assert_eq!(renamed.old_path.as_deref(), Some("old_name.txt"));
    assert_eq!(f("gone.txt").change, FileChange::Deleted);
    assert_eq!(f("untracked.md").change, FileChange::Added);
    assert!(f("blob.bin").binary);
    let big = f("big.txt");
    assert!(big.hunks_omitted, "a >1 MiB patch keeps counts only");
    assert_eq!(big.additions, 100_000);
    assert!(diff.truncated);
    let a = f("src/a.rs");
    assert_eq!((a.additions, a.deletions), (1, 1));
    let lines: Vec<_> = a.hunks[0]
        .lines
        .iter()
        .map(|l| (l.kind, l.text.as_str()))
        .collect();
    assert_eq!(
        lines,
        [
            (LineKind::Context, "fn a() {}"),
            (LineKind::Removed, "fn b() {}"),
            (LineKind::Added, "fn b2() {}"),
            (LineKind::Context, "fn c() {}"),
        ]
    );

    // Staged only.
    let staged = c
        .client
        .git_diff(GitDiffRequest {
            path: s(&repo),
            base: DiffBase::Staged,
            files: vec![],
            context: 3,
            hunks: false,
        })
        .await
        .unwrap();
    assert_eq!(
        staged
            .files
            .iter()
            .map(|f| f.path.as_str())
            .collect::<Vec<_>>(),
        ["src/a.rs"]
    );
    // The user's index was not touched by the worktree snapshots.
    let out = Command::new("git")
        .current_dir(&repo)
        .args(["diff", "--cached", "--name-only"])
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout), "src/a.rs\n");

    // What the turn changed: everything the "agent" did, nothing else.
    let turns = c.client.list_turns(pane).await.unwrap();
    assert_eq!(turns.len(), 1);
    assert!(turns[0].end_tree.is_some(), "{turns:?}");
    let turn = c.client.turn_diff(pane, None, 3, false).await.unwrap();
    let mut changed: Vec<_> = turn.files.iter().map(|f| f.path.as_str()).collect();
    changed.sort_unstable();
    assert_eq!(
        changed,
        [
            "big.txt",
            "blob.bin",
            "gone.txt",
            "new_name.txt",
            "src/a.rs",
            "untracked.md"
        ]
    );
    // Edits after the turn ended are not part of it.
    std::fs::write(repo.join("later.txt"), "after\n").unwrap();
    let turn = c.client.turn_diff(pane, Some(1), 3, false).await.unwrap();
    assert!(!turn.files.iter().any(|f| f.path == "later.txt"));

    // Review notes become one prompt typed into the agent pane.
    c.follow(pane).await;
    let prompt = c
        .client
        .send_review(ReviewRequest {
            pane_id: pane,
            preamble: None,
            notes: vec![ReviewNote {
                path: "src/a.rs".into(),
                start_line: 2,
                end_line: 2,
                old_side: false,
                quote: Some("fn b2() {}".into()),
                note: "Keep the old name".into(),
            }],
            submit: true,
        })
        .await
        .unwrap();
    assert!(prompt.contains("1. src/a.rs:2"), "{prompt}");
    c.wait_flat(pane, "Keep the old name").await;

    // Bad requests.
    assert!(matches!(
        c.client.git_status(s(&home)).await,
        Err(WsError::NotFound(_))
    ));
    assert!(matches!(
        c.client
            .git_diff(GitDiffRequest {
                path: s(&repo),
                base: DiffBase::Rev("--output=/tmp/x".into()),
                files: vec![],
                context: 3,
                hunks: false,
            })
            .await,
        Err(WsError::Invalid(_))
    ));
    drop(c);
    daemon.shutdown().await;
}

// --- worktrees -----------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn worktrees_get_stable_ports_and_dirty_checks() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let repo = repo(&home);
    let daemon = start_home(&state, &home).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = c.attach_and_follow().await;

    let a = c
        .client
        .worktree_create(WorktreeCreate {
            repo: s(&repo),
            branch: Some("feature/a".into()),
            base: None,
            path: None,
        })
        .await
        .unwrap();
    let b = c
        .client
        .worktree_create(WorktreeCreate {
            repo: s(&repo),
            branch: None,
            base: Some("main".into()),
            path: None,
        })
        .await
        .unwrap();
    assert!(a.path.starts_with(&s(&home)), "{a:?}");
    assert!(b.branch.as_deref().unwrap().starts_with("gudo/"), "{b:?}");
    let (pa, pb) = (a.port.unwrap(), b.port.unwrap());
    assert_ne!(pa, pb);
    // Branch exists already.
    assert!(matches!(
        c.client
            .worktree_create(WorktreeCreate {
                repo: s(&repo),
                branch: Some("feature/a".into()),
                base: None,
                path: Some(s(&home.join("elsewhere"))),
            })
            .await,
        Err(WsError::Conflict(_) | WsError::Failed(_))
    ));

    let list = c.client.worktree_list(s(&repo)).await.unwrap();
    assert_eq!(list.len(), 3);
    assert!(list[0].main);
    let listed_a = list.iter().find(|w| w.path == a.path).unwrap();
    assert_eq!(listed_a.port, Some(pa));
    assert_eq!(listed_a.branch.as_deref(), Some("feature/a"));

    // A shell in the worktree has its PORT, recorded in the layout file.
    let new = c
        .client
        .worktree_launch(a.path.clone(), pane, Axis::Horizontal, None)
        .await
        .unwrap();
    c.follow(new).await;
    c.type_line(new, "echo \"P=$PORT\"");
    c.wait_text(new, &format!("P={pa}")).await;
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let layout = std::fs::read_to_string(state.join("layout.json")).unwrap_or_default();
            if layout.contains(&format!("\"port\": {pa}"))
                || layout.contains(&format!("\"port\":{pa}"))
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("PORT recorded in layout.json");

    // Dirty worktrees are kept unless forced.
    std::fs::write(Path::new(&b.path).join("wip.txt"), "wip").unwrap();
    assert!(matches!(
        c.client.worktree_remove(b.path.clone(), false, false).await,
        Err(WsError::Conflict(_))
    ));
    c.client
        .worktree_remove(b.path.clone(), true, true)
        .await
        .unwrap();
    assert!(!Path::new(&b.path).exists());
    // The main worktree is never removed.
    assert!(matches!(
        c.client.worktree_remove(s(&repo), true, false).await,
        Err(WsError::Denied(_))
    ));
    let list = c.client.worktree_list(s(&repo)).await.unwrap();
    assert_eq!(list.len(), 2);

    // Ports are stable: the same worktree keeps its port after a daemon restart.
    drop(c);
    daemon.shutdown().await;
    let daemon = start_home(&state, &home).await;
    let c = connected(&daemon).await;
    let list = c.client.worktree_list(s(&repo)).await.unwrap();
    assert_eq!(
        list.iter().find(|w| w.path == a.path).unwrap().port,
        Some(pa)
    );
    drop(c);
    daemon.shutdown().await;
}

// --- files ---------------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn the_state_dir_stays_out_of_reach_inside_an_allowed_root() {
    let (_home, home) = canonical_tempdir();
    let state = home.join(".local/state/gudo");
    std::fs::create_dir_all(&state).unwrap();
    let daemon = start_home(&state, &home).await;
    let c = connected(&daemon).await;
    let cl = &c.client;
    std::os::unix::fs::symlink(&state, home.join("st")).unwrap();
    let token = s(&state.join("hook.token"));
    fn denied<T>(r: Result<T, WsError>) -> bool {
        matches!(r, Err(WsError::Denied(_)))
    }

    // Other spellings of the same directory, where the volume ignores case (macOS).
    let spelled = [
        home.join(".local/state/GUDO"),
        home.join(".LOCAL/State/gudo"),
    ];
    let spelled: Vec<_> = spelled.iter().filter(|p| p.exists()).collect();
    let mut paths = vec![
        token.clone(),
        s(&home.join("st/hook.token")),
        format!("{}/./hook.token", s(&state)),
        format!("{}//hook.token", s(&state)),
    ];
    paths.extend(spelled.iter().map(|p| s(&p.join("hook.token"))));
    for path in paths {
        assert!(denied(cl.fs_read(path.clone(), 0, 64).await), "{path}");
    }
    assert!(denied(cl.fs_list(s(&state), true).await));
    assert!(denied(cl.fs_list(s(&home.join("st")), true).await));
    for dir in &spelled {
        assert!(denied(cl.fs_list(s(dir), true).await), "{}", dir.display());
    }
    let write = |path: PathBuf| WriteTarget {
        path: s(&path),
        if_match: None,
        create_new: false,
        mkdirs: false,
        mode: None,
    };
    assert!(denied(
        cl.fs_write(write(state.join("devices.json")), b"[]".to_vec())
            .await
    ));
    assert!(denied(
        cl.fs_write(write(home.join("st/devices.json")), b"[]".to_vec())
            .await
    ));

    // Carrying it somewhere unrefused: moving or deleting what holds it.
    let mut holders = vec![home.join(".local"), home.join(".local/state")];
    holders.extend([home.join(".LOCAL")].into_iter().filter(|p| p.exists()));
    for from in holders {
        let from = s(&from);
        let moved = cl
            .fs_rename(from.clone(), s(&home.join("moved")), false)
            .await;
        assert!(
            matches!(moved, Err(WsError::Denied(_))),
            "{from}: {moved:?}"
        );
    }
    let deleted = cl
        .fs_delete(s(&home.join(".local")), DeleteMode::Permanent, true)
        .await;
    assert!(matches!(deleted, Err(WsError::Denied(_))), "{deleted:?}");
    assert!(std::fs::read(state.join("hook.token")).is_ok());

    // Its hook socket is not a forward target.
    let hook = daemon.hook_socket().to_owned();
    if hook.starts_with(&state) {
        let local = cl
            .forward(0, ForwardTarget::Unix { path: s(&hook) })
            .unwrap();
        let mut tcp = TcpStream::connect(("127.0.0.1", local)).await.unwrap();
        let _ = tcp
            .write_all(b"{\"v\":1,\"token\":\"x\",\"pane\":\"1\",\"pull\":{\"op\":\"list\"}}\n")
            .await;
        let mut buf = [0; 1];
        let n = tokio::time::timeout(Duration::from_secs(10), tcp.read(&mut buf))
            .await
            .unwrap()
            .unwrap_or(0);
        assert_eq!(n, 0, "the hook socket answered through a forward");
    }
    drop(c);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn files_are_listed_written_transferred_and_confined() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let daemon = start_home(&state, &home).await;
    let c = connected(&daemon).await;
    let (listener, mut events) = WorkspaceEventQueue::channel();
    c.client.set_workspace_listener(listener);
    let cl = &c.client;

    let dir = home.join("proj");
    cl.fs_mkdir(s(&dir.join("sub/deeper")), true).await.unwrap();
    std::fs::write(dir.join("readme.md"), "hello world").unwrap();
    std::fs::write(dir.join(".hidden"), "").unwrap();
    std::os::unix::fs::symlink("readme.md", dir.join("link")).unwrap();
    std::os::unix::fs::symlink("/", dir.join("root-link")).unwrap();

    let listing = cl.fs_list(s(&dir), false).await.unwrap();
    let names: Vec<_> = listing.entries.iter().map(|e| e.name.as_str()).collect();
    // Directories (and links to directories) first, then by name.
    assert_eq!(names, ["root-link", "sub", "link", "readme.md"]);
    let link = &listing.entries[2];
    assert_eq!(link.kind, FileKind::Symlink);
    assert_eq!(link.link_target.as_deref(), Some("readme.md"));
    assert_eq!(link.target_kind, Some(FileKind::File));
    let all = cl.fs_list(s(&dir), true).await.unwrap();
    assert!(all.entries.iter().any(|e| e.name == ".hidden" && e.hidden));
    // `~` works, and the listing of HOME includes the project.
    let tilde = cl.fs_list("~".into(), false).await.unwrap();
    assert!(tilde.entries.iter().any(|e| e.name == "proj"));

    // Ranged reads.
    let chunk = cl.fs_read(s(&dir.join("readme.md")), 6, 3).await.unwrap();
    assert_eq!(chunk.data, b"wor");
    assert!(!chunk.eof);

    // Path policy: traversal, outside roots, symlink escapes.
    for bad in [
        format!("{}/../../etc/passwd", s(&dir)),
        "/etc/passwd".to_owned(),
        s(&dir.join("root-link/etc/passwd")),
    ] {
        assert!(
            matches!(
                cl.fs_read(bad.clone(), 0, 10).await,
                Err(WsError::Denied(_))
            ),
            "{bad}"
        );
    }
    assert!(matches!(
        cl.fs_read("relative/path".into(), 0, 10).await,
        Err(WsError::Invalid(_))
    ));

    // Small writes with versions.
    let file = dir.join("notes.txt");
    let target = |if_match: Option<String>| WriteTarget {
        path: s(&file),
        if_match,
        create_new: false,
        mkdirs: false,
        mode: Some(0o600),
    };
    let v1 = cl.fs_write(target(None), b"one".to_vec()).await.unwrap();
    assert_eq!(v1.mode, 0o600);
    let v2 = cl
        .fs_write(target(Some(v1.version.clone())), b"two".to_vec())
        .await
        .unwrap();
    assert!(matches!(
        cl.fs_write(target(Some(v1.version)), b"three".to_vec())
            .await,
        Err(WsError::Conflict(_))
    ));
    assert_eq!(std::fs::read(&file).unwrap(), b"two");
    assert_eq!(v2.mode, 0o600, "mode kept on replace");

    // Streamed upload and download (20 MiB), verified byte for byte.
    let data: Vec<u8> = (0..20u32 << 20).map(|i| (i * 7 + i / 4096) as u8).collect();
    let local = home.join("local-upload.bin");
    std::fs::write(&local, &data).unwrap();
    let remote = dir.join("sub/big.bin");
    let start = Instant::now();
    let stat = cl
        .upload_file(
            s(&local),
            WriteTarget {
                path: s(&remote),
                if_match: None,
                create_new: true,
                mkdirs: true,
                mode: None,
            },
            None,
        )
        .await
        .unwrap();
    let up = start.elapsed();
    assert_eq!(stat.size, data.len() as u64);
    assert!(std::fs::read(&remote).unwrap() == data);
    // create_new refuses to replace it.
    assert!(matches!(
        cl.upload_bytes(
            b"x".to_vec(),
            WriteTarget {
                path: s(&remote),
                if_match: None,
                create_new: true,
                mkdirs: false,
                mode: None
            }
        )
        .await,
        Err(WsError::Conflict(_))
    ));
    let back = home.join("downloaded.bin");
    let start = Instant::now();
    cl.download_file(s(&remote), s(&back), 0, None, None)
        .await
        .unwrap();
    let down = start.elapsed();
    assert!(std::fs::read(&back).unwrap() == data);
    // A range.
    cl.download_file(s(&remote), s(&back), 1000, Some(10), None)
        .await
        .unwrap();
    assert_eq!(std::fs::read(&back).unwrap(), &data[1000..1010]);
    println!(
        "20 MiB upload {:.0} ms ({:.0} MB/s), download {:.0} ms ({:.0} MB/s)",
        ms(up),
        20.97 / up.as_secs_f64(),
        ms(down),
        20.97 / down.as_secs_f64()
    );
    // No temporary files left behind.
    let leftovers: Vec<_> = std::fs::read_dir(dir.join("sub"))
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(leftovers.len(), 2, "{leftovers:?}");

    // Watching a directory.
    let watch = cl.fs_watch(s(&dir)).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    std::fs::write(dir.join("created.txt"), "x").unwrap();
    let created = s(&dir.join("created.txt"));
    next_event(&mut events, "watch event", |e| {
        matches!(e, WorkspaceEvent::FsChanged { change }
            if change.watch_id == watch && change.paths.contains(&created))
    })
    .await;
    cl.fs_unwatch(watch).await.unwrap();

    // Rename (no overwrite by default), delete to trash, permanent delete.
    assert!(matches!(
        cl.fs_rename(s(&file), s(&dir.join("readme.md")), false)
            .await,
        Err(WsError::Conflict(_))
    ));
    cl.fs_rename(s(&file), s(&dir.join("renamed.txt")), false)
        .await
        .unwrap();
    assert!(matches!(
        cl.fs_delete(s(&dir.join("sub")), DeleteMode::Permanent, false)
            .await,
        Err(WsError::Conflict(_))
    ));
    cl.fs_delete(s(&dir.join("renamed.txt")), DeleteMode::Trash, false)
        .await
        .unwrap();
    assert!(!dir.join("renamed.txt").exists());
    let trashed = if cfg!(target_os = "macos") {
        home.join(".Trash/renamed.txt")
    } else {
        home.join(".local/share/Trash/files/renamed.txt")
    };
    if std::env::var_os("XDG_DATA_HOME").is_none() {
        assert!(trashed.exists(), "{} missing", trashed.display());
    }
    cl.fs_delete(s(&dir.join("sub")), DeleteMode::Permanent, true)
        .await
        .unwrap();
    assert!(!dir.join("sub").exists());
    assert!(matches!(
        cl.fs_delete(s(&home), DeleteMode::Permanent, true).await,
        Err(WsError::Denied(_))
    ));
    drop(c);
    daemon.shutdown().await;
    let _ = state;
}

// --- editor --------------------------------------------------------------------------------

/// A stand-in for `code serve-web` and openvscode-server: serves HTTP on `--port`, answers
/// 200 only with the right `tkn`.
const FAKE_EDITOR: &str = r#"#!/usr/bin/env python3
import http.server, sys, os
args = sys.argv[1:]
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "args.txt"), "w") as f:
    f.write(" ".join(args))
port = int(args[args.index("--port") + 1])
token = open(args[args.index("--connection-token-file") + 1]).read().strip()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = ("tkn=" + token) in self.path
        self.send_response(200 if ok else 403)
        self.end_headers()
        self.wfile.write(b"fake editor")
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
"#;

fn install_fake(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, FAKE_EDITOR).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

async fn http_get(port: u16, path: &str) -> String {
    let mut tcp = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    tcp.write_all(format!("GET {path} HTTP/1.0\r\nHost: localhost\r\n\r\n").as_bytes())
        .await
        .unwrap();
    let mut out = String::new();
    tokio::time::timeout(Duration::from_secs(10), tcp.read_to_string(&mut out))
        .await
        .unwrap()
        .unwrap();
    out
}

#[tokio::test(flavor = "multi_thread")]
async fn editor_servers_launch_per_folder_and_open_files() {
    if !have("python3") {
        eprintln!("skipping: python3 not installed");
        return;
    }
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let code = home.join("bin/code");
    install_fake(&code);
    let ovs = home.join("ovs");
    install_fake(&ovs.join("bin/openvscode-server"));
    let (code2, ovs2, home2) = (code.clone(), ovs.clone(), home.clone());
    let daemon = start_with(&state, move |c| {
        c.pane_env.push(("HOME".into(), s(&home2)));
        c.fs_allow.push(home2);
        c.code_cli = Some(code2);
        c.vscode_serve_web = true;
        c.openvscode_dir = Some(ovs2);
    })
    .await;
    let c = connected(&daemon).await;
    let project = home.join("project");
    std::fs::create_dir_all(project.join("src")).unwrap();
    std::fs::write(project.join("src/main.rs"), "fn main() {}\n").unwrap();

    let status = c.client.editor_status().await.unwrap();
    assert!(
        status
            .available
            .iter()
            .filter(|a| a.kind != EditorKind::Vscodium)
            .all(|a| a.installed),
        "{status:?}"
    );

    // serve-web needs the licence accepted; Auto never falls back to openvscode, which has
    // to be chosen explicitly.
    let launch = |choice, accept| EditorLaunch {
        folder: s(&project),
        choice,
        accept_vscode_license: accept,
    };
    assert!(matches!(
        c.client
            .editor_launch(launch(EditorChoice::Only(EditorKind::VsCode), false))
            .await,
        Err(WsError::Denied(_))
    ));
    assert!(matches!(
        c.client
            .editor_launch(launch(EditorChoice::Auto, false))
            .await,
        Err(WsError::Denied(_))
    ));
    let ovs_only = EditorChoice::Only(EditorKind::OpenVsCode);
    let e = c
        .client
        .editor_launch(launch(ovs_only, false))
        .await
        .unwrap();
    assert_eq!(e.kind, EditorKind::OpenVsCode);
    let args = std::fs::read_to_string(ovs.join("bin/args.txt")).unwrap();
    assert!(args.contains("--host 127.0.0.1"), "{args}");
    assert!(
        args.contains("--connection-token-file ") && !args.contains(&e.token),
        "{args}"
    );
    // Reused for the same folder.
    let again = c
        .client
        .editor_launch(launch(ovs_only, false))
        .await
        .unwrap();
    assert_eq!(again.port, e.port);

    // Reached through a forward, with the token in the URL.
    let local = c
        .client
        .forward(0, ForwardTarget::Tcp { port: e.port })
        .unwrap();
    let page = http_get(local, &e.url_path).await;
    assert!(page.starts_with("HTTP/1.0 200"), "{page}");
    assert!(http_get(local, "/").await.starts_with("HTTP/1.0 403"));

    // Open at a line: no CLI channel in the fake, so a URL with the payload comes back.
    let opened = c
        .client
        .editor_open(None, s(&project.join("src/main.rs")), Some(1), Some(4))
        .await
        .unwrap();
    assert!(!opened.in_window);
    assert!(opened.url_path.contains("payload="), "{}", opened.url_path);
    assert!(
        opened.url_path.contains("main.rs%3A1%3A4"),
        "{}",
        opened.url_path
    );

    // Replace it with serve-web once the licence is accepted.
    c.client.editor_stop(s(&project)).await.unwrap();
    let e2 = c
        .client
        .editor_launch(launch(EditorChoice::Auto, true))
        .await
        .unwrap();
    assert_eq!(e2.kind, EditorKind::VsCode);
    let args = std::fs::read_to_string(home.join("bin/args.txt")).unwrap();
    assert!(args.starts_with("serve-web"), "{args}");
    assert!(args.contains("--accept-server-license-terms"), "{args}");
    let status = c.client.editor_status().await.unwrap();
    assert_eq!(status.running.len(), 1);
    drop(c);
    daemon.shutdown().await;
    // The server stopped with the daemon.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(TcpStream::connect(("127.0.0.1", e2.port)).await.is_err());
}

/// A stand-in for the VS Code server's static assets and websockets: checks the token
/// cookie like the real one, sends a versioned asset chunked with a one-year `max-age`, and
/// echoes on an upgraded `/ws`.
const FAKE_STATIC_EDITOR: &str = r#"#!/usr/bin/env python3
import http.server, sys
args = sys.argv[1:]
port = int(args[args.index("--port") + 1])
token = open(args[args.index("--connection-token-file") + 1]).read().strip()
JS = "".join("export function f%d(x) { return x * %d; }\n" % (i, i) for i in range(5000)).encode()
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        if ("vscode-tkn=" + token) not in (self.headers.get("Cookie") or ""):
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/ws":
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.end_headers()
            self.wfile.flush()
            while True:
                b = self.connection.recv(4096)
                if not b:
                    return
                self.connection.sendall(b)
        self.send_response(200)
        self.send_header("Content-Type", "text/javascript")
        self.send_header("Cache-Control", "public, max-age=31536000")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for i in range(0, len(JS), 16384):
            c = JS[i:i + 16384]
            self.wfile.write(b"%x\r\n%s\r\n" % (len(c), c))
        self.wfile.write(b"0\r\n\r\n")
    def log_message(self, *a):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
"#;

/// One request through a forward; returns the head and the de-chunked body.
async fn http_exchange(port: u16, path: &str, headers: &str) -> (String, Vec<u8>) {
    let mut tcp = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    tcp.write_all(
        format!(
            "GET {path} HTTP/1.1\r\nHost: localhost:{port}\r\nConnection: close\r\n{headers}\r\n"
        )
        .as_bytes(),
    )
    .await
    .unwrap();
    let mut raw = Vec::new();
    tokio::time::timeout(Duration::from_secs(20), tcp.read_to_end(&mut raw))
        .await
        .unwrap()
        .unwrap();
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    let head = String::from_utf8(raw[..split].to_vec()).unwrap();
    let mut body = raw[split + 4..].to_vec();
    if head
        .to_ascii_lowercase()
        .contains("transfer-encoding: chunked")
    {
        let (mut rest, mut out) = (&body[..], Vec::new());
        loop {
            let line = rest.windows(2).position(|w| w == b"\r\n").unwrap();
            let size =
                usize::from_str_radix(std::str::from_utf8(&rest[..line]).unwrap().trim(), 16)
                    .unwrap();
            if size == 0 {
                break;
            }
            out.extend_from_slice(&rest[line + 2..line + 2 + size]);
            rest = &rest[line + 4 + size..];
        }
        body = out;
    }
    (head, body)
}

fn header<'a>(head: &'a str, name: &str) -> Option<&'a str> {
    head.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.eq_ignore_ascii_case(name).then(|| v.trim())
    })
}

/// The editor's port is the compressing proxy's: through the app's forward, assets come back
/// brotli-encoded (then from the on-disk cache, with a length), the token is still the
/// server's to check, and websockets pass. `editor.compress = false` hands out the server.
#[tokio::test(flavor = "multi_thread")]
async fn editor_traffic_is_compressed_through_the_forward() {
    if !have("python3") {
        eprintln!("skipping: python3 not installed");
        return;
    }
    let commit = "807ba2d6075c29587f884698cd7370c81ab0724c";
    let asset = format!("/stable-{commit}/static/out/workbench.js");
    for compress in [true, false] {
        let (_state, state) = canonical_tempdir();
        let (_home, home) = canonical_tempdir();
        let codium = home.join("codium");
        let server = codium.join("bin/codium-server");
        std::fs::create_dir_all(server.parent().unwrap()).unwrap();
        std::fs::write(&server, FAKE_STATIC_EDITOR).unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&server, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let home2 = home.clone();
        let daemon = start_with(&state, move |c| {
            c.pane_env.push(("HOME".into(), s(&home2)));
            c.fs_allow.push(home2);
            c.vscodium_dir = Some(codium);
            c.editor_compress = compress;
        })
        .await;
        let c = connected(&daemon).await;
        let e = c
            .client
            .editor_launch(EditorLaunch {
                folder: s(&home),
                choice: EditorChoice::Only(EditorKind::Vscodium),
                accept_vscode_license: false,
            })
            .await
            .unwrap();
        let local = c
            .client
            .forward(0, ForwardTarget::Tcp { port: e.port })
            .unwrap();
        let cookie = format!("Cookie: vscode-tkn={}\r\n", e.token);
        let accept = "Accept-Encoding: gzip, deflate, br\r\n";
        let plain_len = (0..5000)
            .map(|i| format!("export function f{i}(x) {{ return x * {i}; }}\n").len())
            .sum::<usize>();

        let (head, body) = http_exchange(local, &asset, &format!("{cookie}{accept}")).await;
        assert!(head.starts_with("HTTP/1.1 200"), "{head}");
        if !compress {
            assert_eq!(header(&head, "content-encoding"), None, "{head}");
            assert_eq!(body.len(), plain_len);
            drop(c);
            daemon.shutdown().await;
            continue;
        }
        assert_eq!(header(&head, "content-encoding"), Some("br"), "{head}");
        let mut plain = Vec::new();
        brotli::BrotliDecompress(&mut &body[..], &mut plain).unwrap();
        assert_eq!(plain.len(), plain_len);
        assert!(body.len() * 5 < plain_len, "{} of {plain_len}", body.len());

        // Without the token the server still refuses, cache or not.
        let (head, _) = http_exchange(local, &asset, accept).await;
        assert!(head.starts_with("HTTP/1.1 403"), "{head}");

        // Once stored (and recompressed), the next load comes from disk with a length.
        let cached = tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let (head, body) = http_exchange(local, &asset, &format!("{cookie}{accept}")).await;
                if header(&head, "content-length").is_some() {
                    return (head, body);
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .expect("served from the cache");
        assert_eq!(header(&cached.0, "content-encoding"), Some("br"));
        let mut again = Vec::new();
        brotli::BrotliDecompress(&mut &cached.1[..], &mut again).unwrap();
        assert_eq!(again, plain);
        assert!(
            std::fs::read_dir(state.join(format!("editors/cache/stable-{commit}")))
                .unwrap()
                .count()
                >= 1
        );

        // A websocket through forward and proxy.
        let mut ws = TcpStream::connect(("127.0.0.1", local)).await.unwrap();
        ws.write_all(
            format!(
                "GET /ws HTTP/1.1\r\nHost: localhost\r\n{cookie}Connection: Upgrade\r\n\
                 Upgrade: websocket\r\n\r\n"
            )
            .as_bytes(),
        )
        .await
        .unwrap();
        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            let mut b = [0; 1];
            ws.read_exact(&mut b).await.unwrap();
            head.push(b[0]);
        }
        assert!(
            head.starts_with(b"HTTP/1.1 101"),
            "{}",
            String::from_utf8_lossy(&head)
        );
        ws.write_all(b"\x81\x04ping").await.unwrap();
        let mut back = [0; 6];
        tokio::time::timeout(Duration::from_secs(10), ws.read_exact(&mut back))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&back, b"\x81\x04ping");
        drop(ws);
        drop(c);
        daemon.shutdown().await;
    }
}

/// VSCodium: chosen explicitly or as the configured default, launched with a token and no
/// licence flag, per folder, stopped with the daemon. A fake `codium-server` stands in.
#[tokio::test(flavor = "multi_thread")]
async fn vscodium_launches_without_a_licence_and_as_the_default() {
    if !have("python3") {
        eprintln!("skipping: python3 not installed");
        return;
    }
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let codium = home.join("codium");
    install_fake(&codium.join("bin/codium-server"));
    let (codium2, home2, state2) = (codium.clone(), home.clone(), state.clone());
    let daemon = start_with(&state, move |c| {
        c.pane_env.push(("HOME".into(), s(&home2)));
        c.fs_allow.push(home2);
        c.code_cli = Some(state2.join("no-such-code"));
        c.vscodium_dir = Some(codium2);
        c.editor_default = EditorKind::Vscodium;
    })
    .await;
    let c = connected(&daemon).await;
    let (a, b) = (home.join("a"), home.join("b"));
    std::fs::create_dir_all(&a).unwrap();
    std::fs::create_dir_all(&b).unwrap();

    let status = c.client.editor_status().await.unwrap();
    let entry = status
        .available
        .iter()
        .find(|e| e.kind == EditorKind::Vscodium)
        .unwrap();
    assert!(entry.installed, "{entry:?}");
    assert!(entry.note.as_deref().unwrap().contains("Open VSX"));

    let launch = |folder: &Path, choice| EditorLaunch {
        folder: s(folder),
        choice,
        accept_vscode_license: false,
    };
    // Auto is the configured default: VSCodium, with no licence accepted and no `code` CLI.
    let ea = c
        .client
        .editor_launch(launch(&a, EditorChoice::Auto))
        .await
        .unwrap();
    assert_eq!(ea.kind, EditorKind::Vscodium);
    let args = std::fs::read_to_string(codium.join("bin/args.txt")).unwrap();
    assert!(args.contains("--host 127.0.0.1"), "{args}");
    assert!(
        args.contains("--connection-token-file ") && !args.contains(&ea.token),
        "{args}"
    );
    assert!(args.contains("--telemetry-level off"), "{args}");
    assert!(!args.contains("license"), "{args}");
    // One server per folder; the same folder reuses it.
    let eb = c
        .client
        .editor_launch(launch(&b, EditorChoice::Only(EditorKind::Vscodium)))
        .await
        .unwrap();
    assert_ne!(eb.port, ea.port);
    assert_ne!(eb.token, ea.token);
    let again = c
        .client
        .editor_launch(launch(&a, EditorChoice::Only(EditorKind::Vscodium)))
        .await
        .unwrap();
    assert_eq!(again.port, ea.port);

    let local = c
        .client
        .forward(0, ForwardTarget::Tcp { port: ea.port })
        .unwrap();
    assert!(
        http_get(local, &ea.url_path)
            .await
            .starts_with("HTTP/1.0 200")
    );
    assert!(http_get(local, "/").await.starts_with("HTTP/1.0 403"));

    // VS Code asked for explicitly still needs its CLI and licence.
    assert!(matches!(
        c.client
            .editor_launch(launch(&b, EditorChoice::Only(EditorKind::VsCode)))
            .await,
        Err(WsError::Unavailable(_))
    ));

    c.client.editor_stop(s(&b)).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(TcpStream::connect(("127.0.0.1", eb.port)).await.is_err());
    drop(c);
    daemon.shutdown().await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(TcpStream::connect(("127.0.0.1", ea.port)).await.is_err());
}

/// Downloads the pinned VSCodium Web Host (about 95 MB), verifies it and serves a folder.
/// Linux and macOS (x86_64, arm64); run with
/// `cargo test -p daemon --test it real_vscodium -- --ignored --nocapture`.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "downloads VSCodium"]
async fn real_vscodium_downloads_and_serves() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let daemon = start_home(&state, &home).await;
    let c = connected(&daemon).await;
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(project.join("main.rs"), "fn main() {}\n").unwrap();
    let start = Instant::now();
    let e = c
        .client
        .editor_launch(EditorLaunch {
            folder: s(&project),
            choice: EditorChoice::Only(EditorKind::Vscodium),
            accept_vscode_license: false,
        })
        .await
        .unwrap();
    println!(
        "VSCodium downloaded, verified and ready in {:.1} s",
        start.elapsed().as_secs_f64()
    );
    let local = c
        .client
        .forward(0, ForwardTarget::Tcp { port: e.port })
        .unwrap();
    let page = http_get(local, &e.url_path).await;
    assert!(
        page.starts_with("HTTP/1.1 302"),
        "{}",
        &page[..page.len().min(300)]
    );
    assert!(page.contains(&format!("vscode-tkn={}", e.token)), "{page}");
    let location = page
        .lines()
        .find_map(|l| l.strip_prefix("Location: "))
        .unwrap()
        .trim()
        .to_owned();
    let get = |path: String| {
        let token = e.token.clone();
        async move {
            let mut tcp = TcpStream::connect(("127.0.0.1", local)).await.unwrap();
            tcp.write_all(
                format!(
                    "GET {path} HTTP/1.0\r\nHost: localhost\r\nCookie: vscode-tkn={token}\r\n\r\n"
                )
                .as_bytes(),
            )
            .await
            .unwrap();
            let mut out = String::new();
            tcp.read_to_string(&mut out).await.unwrap();
            out
        }
    };
    let workbench = get(location).await;
    assert!(
        workbench.starts_with("HTTP/1.1 200"),
        "{}",
        &workbench[..workbench.len().min(300)]
    );
    assert!(workbench.contains("workbench"), "not the workbench");
    // The page sets its title from script; the web manifest names the product.
    let manifest = workbench
        .split('"')
        .find(|p| p.ends_with("/manifest.json"))
        .expect("manifest link")
        .to_owned();
    let manifest = get(manifest).await;
    println!(
        "apple-mobile-web-app-title: {:?}; manifest: {}",
        workbench
            .split("apple-mobile-web-app-title\" content=\"")
            .nth(1)
            .and_then(|r| r.split('"').next()),
        manifest.split("\r\n\r\n").nth(1).unwrap_or_default().trim()
    );
    assert!(manifest.contains("VSCodium"), "{manifest}");
    assert!(!http_get(local, "/").await.contains(" 200 "));
    let opened = c
        .client
        .editor_open(None, s(&project.join("main.rs")), Some(1), None)
        .await
        .unwrap();
    println!("open: in_window {}", opened.in_window);
    drop(c);
    daemon.shutdown().await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(TcpStream::connect(("127.0.0.1", e.port)).await.is_err());
}

// --- attention -----------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn attention_feed_counts_unseen_and_syncs_seen() {
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let daemon = start_home(&state, &home).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let (listener, mut events) = WorkspaceEventQueue::channel();
    c.client.set_workspace_listener(listener);
    let shown = c.attach_and_follow().await;
    let OpOutcome::PaneCreated { pane_id: hidden } = c
        .op(LayoutOp::Split {
            pane_id: shown,
            axis: Axis::Vertical,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!()
    };
    // The split focused the new pane in the layout, but this client shows only `shown`.
    c.client.set_view(Some(shown), vec![shown]);
    tokio::time::sleep(Duration::from_millis(100)).await;

    let working = |name: &str| {
        serde_json::json!({
            "session_id": "s", "cwd": s(&home), "hook_event_name": name,
            "prompt": "go", "tool_name": "Bash", "tool_input": {"command": "ls"},
        })
    };
    hook(
        &daemon,
        &state,
        hidden.0,
        "UserPromptSubmit",
        working("UserPromptSubmit"),
    )
    .await;
    let blocked = serde_json::json!({
        "session_id": "s", "cwd": s(&home), "hook_event_name": "Notification",
        "message": "Claude needs your permission to use Bash",
        "notification_type": "permission_prompt",
    });
    hook(&daemon, &state, hidden.0, "Notification", blocked).await;
    let WorkspaceEvent::Attention {
        update: AttentionUpdate::Added { item, unseen },
    } = next_event(&mut events, "blocked item", |e| {
        matches!(
            e,
            WorkspaceEvent::Attention {
                update: AttentionUpdate::Added { .. }
            }
        )
    })
    .await
    else {
        unreachable!()
    };
    assert!(
        matches!(item.kind, AttentionKind::AgentBlocked { .. }),
        "{item:?}"
    );
    assert_eq!(item.pane_id, hidden);
    assert!(!item.seen);
    assert_eq!(unseen, 1);

    // Work resumes (the blocked item is retired), then the turn ends: a "done" item.
    hook(
        &daemon,
        &state,
        hidden.0,
        "PreToolUse",
        working("PreToolUse"),
    )
    .await;
    let stop = serde_json::json!({
        "session_id": "s", "cwd": s(&home), "hook_event_name": "Stop",
        "last_assistant_message": "All tests pass.",
    });
    hook(&daemon, &state, hidden.0, "Stop", stop).await;
    let WorkspaceEvent::Attention {
        update: AttentionUpdate::Added { item: done, .. },
    } = next_event(&mut events, "done item", |e| {
        matches!(e, WorkspaceEvent::Attention { update: AttentionUpdate::Added { item, .. } }
            if matches!(item.kind, AttentionKind::AgentDone { .. }))
    })
    .await
    else {
        unreachable!()
    };
    assert_eq!(done.body, "All tests pass.");
    let list = c.client.attention_list().await.unwrap();
    assert_eq!(list.unseen, 1, "{list:#?}");

    // Focusing the pane on any device marks its items seen everywhere.
    c.client.set_view(Some(hidden), vec![hidden]);
    next_event(&mut events, "seen update", |e| {
        matches!(
            e,
            WorkspaceEvent::Attention {
                update: AttentionUpdate::Seen { unseen: 0, .. }
            }
        )
    })
    .await;

    let list = c
        .client
        .attention_seen(AttentionSeen {
            ids: vec![],
            up_to: Some(u64::MAX),
            pane_id: None,
        })
        .await
        .unwrap();
    assert_eq!(list.unseen, 0);
    assert!(list.items.len() >= 2);
    drop(c);
    daemon.shutdown().await;
}

/// Downloads the pinned openvscode-server (about 75 MB), verifies it and serves a folder.
/// Linux only; run with `cargo test -p daemon --test it real_openvscode -- --ignored`.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "downloads openvscode-server"]
async fn real_openvscode_server_downloads_and_serves() {
    if !cfg!(target_os = "linux") {
        return;
    }
    let (_state, state) = canonical_tempdir();
    let (_home, home) = canonical_tempdir();
    let daemon = start_home(&state, &home).await;
    let c = connected(&daemon).await;
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(project.join("main.rs"), "fn main() {}\n").unwrap();
    let start = Instant::now();
    let e = c
        .client
        .editor_launch(EditorLaunch {
            folder: s(&project),
            choice: EditorChoice::Only(EditorKind::OpenVsCode),
            accept_vscode_license: false,
        })
        .await
        .unwrap();
    println!(
        "openvscode-server ready in {:.1} s",
        start.elapsed().as_secs_f64()
    );
    let local = c
        .client
        .forward(0, ForwardTarget::Tcp { port: e.port })
        .unwrap();
    // The token URL sets the token cookie and redirects to the folder.
    let page = http_get(local, &e.url_path).await;
    assert!(
        page.starts_with("HTTP/1.1 302"),
        "{}",
        &page[..page.len().min(300)]
    );
    assert!(page.contains(&format!("vscode-tkn={}", e.token)), "{page}");
    let location = page
        .lines()
        .find_map(|l| l.strip_prefix("Location: "))
        .unwrap()
        .trim()
        .to_owned();
    let mut tcp = TcpStream::connect(("127.0.0.1", local)).await.unwrap();
    tcp.write_all(
        format!(
            "GET {location} HTTP/1.0\r\nHost: localhost\r\nCookie: vscode-tkn={}\r\n\r\n",
            e.token
        )
        .as_bytes(),
    )
    .await
    .unwrap();
    let mut workbench = String::new();
    tcp.read_to_string(&mut workbench).await.unwrap();
    assert!(
        workbench.starts_with("HTTP/1.1 200"),
        "{}",
        &workbench[..workbench.len().min(300)]
    );
    assert!(workbench.contains("workbench"), "not the VS Code workbench");
    let denied = http_get(local, "/").await;
    assert!(!denied.contains(" 200 "), "served without the token");
    let opened = c
        .client
        .editor_open(None, s(&project.join("main.rs")), Some(1), None)
        .await
        .unwrap();
    println!(
        "open: in_window {} url {}",
        opened.in_window, opened.url_path
    );
    drop(c);
    daemon.shutdown().await;
}
