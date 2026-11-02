//! Daemon and client in one process over iroh, relays off, on loopback.

use std::time::{Duration, Instant};

use client_core::ClientConfig;
use client_core::proto::{AttachVia, Axis, LayoutOp, OpOutcome, PaneLaunch, SessionId};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::support::{TestClient, leaves, ms, shape, start, ticket};

fn shell() -> PaneLaunch {
    PaneLaunch::Shell { cwd: None }
}

#[tokio::test(flavor = "multi_thread")]
async fn attach_type_and_see_echo() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let ticket = ticket(&daemon);

    let started = Instant::now();
    let mut owner = TestClient::connect(&ticket, ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let attach = started.elapsed();

    owner.type_line(pane, "echo abc$((1+2))");
    owner.wait_text(pane, "abc3").await;
    let echo = started.elapsed() - attach;
    println!(
        "attach (connect + pair + attach + first snapshot): {:.1} ms; type → echo: {:.1} ms",
        ms(attach),
        ms(echo)
    );
    assert_eq!(daemon.paired_devices(), 1);
    drop(owner);
    daemon.shutdown().await;
}

/// A client that remembered a session the daemon no longer has (closed elsewhere, or lost with
/// the daemon's state) lands in the most recent one, or a new one, and is told which.
#[tokio::test(flavor = "multi_thread")]
async fn attach_to_a_gone_session_falls_back_and_says_so() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let gone = SessionId(99);

    let mut first = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    first.client.attach(Some(gone));
    first
        .until("attached", |client| !client.attached.is_empty())
        .await;
    let (created, via, missing) = first.attached[0];
    assert_eq!((via, missing), (AttachVia::Created, Some(gone)));
    first
        .until("layout", |client| client.layout.is_some())
        .await;

    let mut second = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    second.client.attach(Some(gone));
    second
        .until("attached", |client| !client.attached.is_empty())
        .await;
    assert_eq!(
        second.attached[0],
        (created, AttachVia::MostRecent, Some(gone))
    );

    let mut third = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    third.client.attach(Some(created));
    third
        .until("attached", |client| !client.attached.is_empty())
        .await;
    assert_eq!(third.attached[0], (created, AttachVia::Requested, None));
    assert!(first.attach_failed.is_empty() && second.attach_failed.is_empty());
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn split_and_both_panes_work() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let first = owner.attach_and_follow().await;

    let OpOutcome::PaneCreated { pane_id: second } = owner
        .op(LayoutOp::Split {
            pane_id: first,
            axis: Axis::Horizontal,
            launch: shell(),
        })
        .await
    else {
        panic!("split failed");
    };
    assert_eq!(leaves(&owner.tab().root), vec![first, second]);
    assert_eq!(owner.focused(), second, "the new pane takes focus");
    owner.follow(second).await;

    owner.type_line(first, "echo left$((40+2))");
    owner.type_line(second, "echo right$((50+5))");
    owner.wait_text(first, "left42").await;
    owner.wait_text(second, "right55").await;
    assert!(!owner.text(first).contains("right55"));

    // Closing a pane collapses the split.
    owner.op(LayoutOp::ClosePane { pane_id: second }).await;
    owner
        .until("collapsed layout", |owner| {
            leaves(&owner.tab().root) == vec![first]
        })
        .await;
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn reconnect_resumes_from_ring() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    owner.type_line(pane, "echo ready$((1+1))");
    owner.wait_text(pane, "ready2").await;
    let snapshots = owner.client.stats().snapshots;

    // Output produced while the client is away must come from the ring, not a snapshot.
    owner.type_line(pane, "sleep 0.3; echo later$((2+2))");
    tokio::time::sleep(Duration::from_millis(50)).await;
    owner.client.suspend();
    tokio::time::sleep(Duration::from_millis(700)).await;
    assert!(!owner.text(pane).contains("later4"));

    let started = Instant::now();
    owner.client.reconnect();
    owner.wait_text(pane, "later4").await;
    let resume = started.elapsed();
    assert_eq!(
        owner.client.stats().snapshots,
        snapshots,
        "resumed from the ring"
    );
    assert_eq!(owner.client.stats().connections, 2);
    println!(
        "resume from ring (reconnect → missed output shown): {:.1} ms",
        ms(resume)
    );

    // And the pane still takes input.
    owner.type_line(pane, "echo again$((3+3))");
    owner.wait_text(pane, "again6").await;
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn eviction_forces_a_snapshot() {
    let dir = tempfile::tempdir().unwrap();
    let mut config = crate::support::config(dir.path());
    config.ring_capacity = 64 * 1024;
    crate::support::init_tracing();
    let daemon = daemon::Daemon::start(config).await.unwrap();
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let snapshots = owner.client.stats().snapshots;

    // ~190 KB of output while away: three times the ring.
    owner.type_line(pane, "sleep 0.3; seq 1 30000; echo done$((5+5))");
    tokio::time::sleep(Duration::from_millis(50)).await;
    owner.client.suspend();
    tokio::time::sleep(Duration::from_millis(1500)).await;

    let started = Instant::now();
    owner.client.reconnect();
    owner.wait_text(pane, "done10").await;
    println!(
        "resume after eviction (snapshot): {:.1} ms",
        ms(started.elapsed())
    );
    assert_eq!(
        owner.client.stats().snapshots,
        snapshots + 1,
        "the ring could not serve the resume point"
    );
    assert!(owner.text(pane).contains("30000"));
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn layout_changes_reach_every_client() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut laptop = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = laptop.attach_and_follow().await;
    let mut tablet = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    tablet.client.attach(None);
    tablet
        .until("b attached", |tablet| tablet.layout.is_some())
        .await;
    assert_eq!(daemon.paired_devices(), 2);

    let OpOutcome::PaneCreated { pane_id } = laptop
        .op(LayoutOp::Split {
            pane_id: pane,
            axis: Axis::Vertical,
            launch: shell(),
        })
        .await
    else {
        panic!("split failed");
    };
    tablet
        .until("split seen by b", |tablet| {
            leaves(&tablet.tab().root) == vec![pane, pane_id]
        })
        .await;

    // A tab created by B shows up at A.
    let OpOutcome::TabCreated { tab_id, .. } = tablet
        .op(LayoutOp::NewTab {
            session_id: tablet.layout.as_ref().unwrap().session_id,
            name: "logs".into(),
            launch: shell(),
        })
        .await
    else {
        panic!("new tab failed");
    };
    laptop
        .until("tab seen by a", |laptop| {
            laptop.layout.as_ref().unwrap().tabs.len() == 2
                && laptop.layout.as_ref().unwrap().active_tab == Some(tab_id)
        })
        .await;
    // Both see the same revision.
    tablet
        .until("same revision", |tablet| {
            tablet.layout.as_ref().unwrap().revision == laptop.layout.as_ref().unwrap().revision
        })
        .await;
    drop((laptop, tablet));
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn port_forward_to_a_local_echo_server() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;

    let server = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let remote_port = server.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut tcp, _)) = server.accept().await {
            tokio::spawn(async move {
                let (mut reader, mut writer) = tcp.split();
                let _ = tokio::io::copy(&mut reader, &mut writer).await;
            });
        }
    });

    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.until("connected", |owner| owner.connected > 0).await;
    let local = owner.client.forward_port(0, remote_port).unwrap();
    for round in 0..2 {
        let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", local))
            .await
            .unwrap();
        let message = format!("ping {round} through the daemon");
        tcp.write_all(message.as_bytes()).await.unwrap();
        let mut back = vec![0; message.len()];
        tokio::time::timeout(Duration::from_secs(10), tcp.read_exact(&mut back))
            .await
            .expect("echo in time")
            .unwrap();
        assert_eq!(back, message.as_bytes());
    }

    // A closed remote port is refused, and the local socket is closed.
    let closed = {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.local_addr().unwrap().port()
    };
    let local = owner.client.forward_port(0, closed).unwrap();
    let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", local))
        .await
        .unwrap();
    let mut byte = [0; 1];
    let bytes_read = tokio::time::timeout(Duration::from_secs(10), tcp.read(&mut byte))
        .await
        .expect("closed in time")
        .unwrap_or(0);
    assert_eq!(bytes_read, 0);
    drop(owner);
    daemon.shutdown().await;
}

/// A device that dials direct addresses only (`gudo --no-relay`, the app's local-only switch)
/// has nothing but the ticket it paired with, so a restart must keep listening where that
/// ticket points.
#[tokio::test(flavor = "multi_thread")]
async fn a_direct_only_ticket_still_reaches_the_daemon_after_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let key = ClientConfig::generate_key();
    let daemon = start(dir.path()).await;
    let old = ticket(&daemon);
    let mut owner = TestClient::connect(&old, key.clone());
    owner.client.attach(None);
    owner.until("layout", |owner| owner.layout.is_some()).await;
    drop(owner);
    daemon.shutdown().await;

    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&old, key);
    owner.client.attach(None);
    owner
        .until("layout over the old ticket", |owner| owner.layout.is_some())
        .await;
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn daemon_restart_restores_the_layout() {
    let dir = tempfile::tempdir().unwrap();
    let key = ClientConfig::generate_key();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), key.clone());
    let pane = owner.attach_and_follow().await;
    owner.type_line(pane, "cd /tmp");
    let OpOutcome::PaneCreated { .. } = owner
        .op(LayoutOp::Split {
            pane_id: pane,
            axis: Axis::Horizontal,
            launch: shell(),
        })
        .await
    else {
        panic!()
    };
    owner
        .op(LayoutOp::Resize {
            pane_id: pane,
            axis: Axis::Horizontal,
            delta: 0.2,
        })
        .await;
    let session_id = owner.layout.as_ref().unwrap().session_id;
    owner
        .op(LayoutOp::NewTab {
            session_id,
            name: "second".into(),
            launch: shell(),
        })
        .await;
    owner
        .op(LayoutOp::RenameSession {
            session_id,
            name: "work".into(),
        })
        .await;
    let before = owner.layout.clone().unwrap();
    // The shell reports no cwd without integration, so give persistence a moment.
    tokio::time::sleep(Duration::from_millis(200)).await;
    drop(owner);
    daemon.shutdown().await;

    let daemon = start(dir.path()).await;
    // Same device key: already paired, so a fresh ticket only supplies the new address.
    let mut owner = TestClient::connect(&ticket(&daemon), key);
    owner.client.attach(None);
    owner
        .until("restored layout", |owner| owner.layout.is_some())
        .await;
    let after = owner.layout.clone().unwrap();
    assert_eq!(after.name, "work");
    assert_eq!(shape(&after), shape(&before));
    assert_eq!(after.active_tab, before.active_tab);

    // The restored panes run fresh shells that take input.
    let pane = owner.focused();
    owner.follow(pane).await;
    owner.type_line(pane, "echo back$((6+1))");
    owner.wait_text(pane, "back7").await;
    assert_eq!(daemon.paired_devices(), 1);
    drop(owner);
    daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn typing_stays_responsive_next_to_a_flooding_pane() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let flood = owner.attach_and_follow().await;
    let OpOutcome::PaneCreated { pane_id: typing } = owner
        .op(LayoutOp::Split {
            pane_id: flood,
            axis: Axis::Horizontal,
            launch: shell(),
        })
        .await
    else {
        panic!()
    };
    owner.follow(typing).await;
    owner.client.set_view(Some(typing), vec![typing, flood]);

    // ~40 MB of output in the visible, unfocused pane.
    owner.type_line(
        flood,
        "yes 0123456789abcdefghijklmnopqrstuvwxyz | head -c 40000000; echo flood-$((1+1))-done",
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    let mut worst = Duration::ZERO;
    for i in 0..10 {
        let started = Instant::now();
        owner.type_line(typing, &format!("echo k{i}x$((1000+{i}))"));
        owner.wait_text(typing, &format!("k{i}x{}", 1000 + i)).await;
        worst = worst.max(started.elapsed());
    }
    println!(
        "worst keystroke-to-echo during a 40 MB flood: {:.1} ms",
        ms(worst)
    );
    owner.wait_text(flood, "flood-2-done").await;
    let stats = owner.client.stats();
    println!(
        "flood: {} snapshots, {} byte frames",
        stats.snapshots, stats.byte_frames
    );
    drop(owner);
    daemon.shutdown().await;
}
