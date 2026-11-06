use std::time::Duration;

use pty::{Signal, SpawnOptions, TryWriteError, WinSize};
use tokio::sync::oneshot;

use crate::support::{read_until, spawn, spawn_with, within};

#[tokio::test]
async fn flushing_waits_for_kernel_writes_not_just_enqueueing() {
    let directory = tempfile::tempdir().unwrap();
    let release = directory.path().join("read-input");
    let pty = spawn(&[
        "/bin/sh",
        "-c",
        "stty raw -echo; echo ready; while [ ! -e \"$1\" ]; do sleep 0.01; done; head -c 262144 >/dev/null; printf consumed; exec sleep 100",
        "input-test",
        release.to_str().unwrap(),
    ]);
    let mut output = pty.subscribe();
    read_until(&mut output, "ready").await;
    pty.write(vec![b'x'; 262_144]).await.unwrap();
    assert!(
        tokio::time::timeout(Duration::from_millis(20), pty.flush_writes())
            .await
            .is_err()
    );
    std::fs::write(release, []).unwrap();
    within("input flushed", pty.flush_writes()).await.unwrap();
    read_until(&mut output, "consumed").await;
}

#[tokio::test]
async fn a_pending_flush_reports_failure_when_the_child_closes() {
    let pty = spawn(&[
        "/bin/sh",
        "-c",
        "stty raw -echo; echo ready; exec sleep 100",
    ]);
    let mut output = pty.subscribe();
    read_until(&mut output, "ready").await;
    pty.write(vec![b'x'; pty::MAX_QUEUED_INPUT]).await.unwrap();
    let flush = pty.flush_writes();
    tokio::pin!(flush);
    tokio::select! {
        result = &mut flush => panic!("flush finished before the child read input: {result:?}"),
        () = tokio::time::sleep(Duration::from_millis(20)) => {}
    }
    pty.signal(Signal::Kill).unwrap();
    assert!(within("pending flush closed", flush).await.is_err());
}

#[tokio::test]
async fn empty_writes_cannot_bypass_a_stalled_input_queue_bound() {
    let pty = spawn(&[
        "/bin/sh",
        "-c",
        "stty raw -echo; echo ready; exec sleep 100",
    ]);
    let mut output = pty.subscribe();
    read_until(&mut output, "ready").await;
    pty.write(vec![b'x'; pty::MAX_QUEUED_INPUT]).await.unwrap();
    let deadline = std::time::Instant::now() + Duration::from_millis(500);
    let mut accepted = 1;
    while std::time::Instant::now() < deadline {
        match pty.try_write(Vec::new()) {
            Ok(()) => accepted += 1,
            Err(TryWriteError::Full(_)) => tokio::time::sleep(Duration::from_millis(1)).await,
            Err(TryWriteError::Closed(_)) => panic!("child closed before input was queued"),
        }
        assert!(
            accepted <= pty::MAX_QUEUED_WRITES,
            "retained {accepted} writes"
        );
    }
}

#[tokio::test]
async fn cancelling_a_queued_write_returns_its_input_budget() {
    let (entered, waiting) = oneshot::channel();
    let (resume, paused) = std::sync::mpsc::channel::<()>();
    let mut entered = Some(entered);
    let options = SpawnOptions::new(WinSize::new(24, 80)).output_hook(move |_, _| {
        if let Some(entered) = entered.take() {
            let _ = entered.send(());
            // Keep the receiver queue full independently of the kernel's PTY buffer size.
            let _ = paused.recv_timeout(Duration::from_secs(5));
        }
    });
    let pty = spawn_with(
        &[
            "/bin/sh",
            "-c",
            "stty raw -echo; printf ready; exec sleep 100",
        ],
        options,
    );
    within("output hook entered", waiting).await.unwrap();
    let mut queued = 0;
    loop {
        match pty.try_write(vec![b'x']) {
            Ok(()) => queued += 1,
            Err(TryWriteError::Full(_)) => break,
            Err(TryWriteError::Closed(_)) => panic!("child closed before input was queued"),
        }
        assert!(queued < 4_096);
    }
    assert!(queued > 0);
    assert!(
        tokio::time::timeout(Duration::from_millis(20), pty.write(vec![b'y'; 4_096]))
            .await
            .is_err()
    );
    drop(resume);
    within("cancelled input budget returned", async {
        let mut input = vec![b'z'; pty::MAX_QUEUED_INPUT].into();
        loop {
            match pty.try_write(input) {
                Ok(()) => break,
                Err(TryWriteError::Full(returned)) => input = returned,
                Err(TryWriteError::Closed(_)) => panic!("child closed before budget was returned"),
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await;
}
