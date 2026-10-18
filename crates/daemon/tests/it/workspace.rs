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

    // A server nobody printed a URL for is probed.
    let port2 = free_port();
    let OpOutcome::PaneCreated { pane_id: pane2 } = c
        .op(LayoutOp::Split {
            pane_id: pane,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Command {
                argv: vec![
                    "python3".into(),
                    "-m".into(),
                    "http.server".into(),
                    port2.to_string(),
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
    assert!(
        b.branch.as_deref().unwrap().starts_with("unnamed/"),
        "{b:?}"
    );
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
token = args[args.index("--connection-token") + 1]
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
        c.openvscode_dir = Some(ovs2);
    })
    .await;
    let c = connected(&daemon).await;
    let project = home.join("project");
    std::fs::create_dir_all(project.join("src")).unwrap();
    std::fs::write(project.join("src/main.rs"), "fn main() {}\n").unwrap();

    let status = c.client.editor_status().await.unwrap();
    assert!(status.available.iter().all(|a| a.installed), "{status:?}");

    // serve-web needs the licence accepted; Auto then falls back to openvscode.
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
    let e = c
        .client
        .editor_launch(launch(EditorChoice::Auto, false))
        .await
        .unwrap();
    assert_eq!(e.kind, EditorKind::OpenVsCode);
    let args = std::fs::read_to_string(ovs.join("bin/args.txt")).unwrap();
    assert!(args.contains("--host 127.0.0.1"), "{args}");
    assert!(
        args.contains(&format!("--connection-token {}", e.token)),
        "{args}"
    );
    // Reused for the same folder.
    let again = c
        .client
        .editor_launch(launch(EditorChoice::Auto, false))
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
