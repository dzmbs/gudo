use std::os::unix::process::ExitStatusExt;

use pty::{RecvError, Seq, Signal, SignalError, SpawnOptions, WinSize};

use crate::support::{read_to_end, read_until, spawn, spawn_with, within};

/// A program that never reads its input used to let queued input grow without bound.
#[tokio::test]
async fn input_for_a_program_that_never_reads_is_bounded() {
    // Raw mode: a canonical tty discards input past its line limit, so writes would never back
    // up into our queue and the bound would go untested.
    let pty = spawn(&[
        "/bin/sh",
        "-c",
        "stty raw -echo; echo ready; exec sleep 100",
    ]);
    let mut out = pty.subscribe_from(Seq::ZERO).unwrap();
    read_until(&mut out, "ready").await;
    let chunk = vec![b'x'; 64 * 1024];
    let mut accepted = 0;
    let end = std::time::Instant::now() + std::time::Duration::from_millis(500);
    while std::time::Instant::now() < end {
        if pty.try_write(chunk.clone()).is_ok() {
            accepted += chunk.len();
        } else {
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
        // What the kernel's tty buffer takes on top of the queue is small.
        assert!(
            accepted <= 2 * pty::MAX_QUEUED_INPUT,
            "accepted {accepted} bytes"
        );
    }
    assert!(
        accepted >= pty::MAX_QUEUED_INPUT / 2,
        "accepted only {accepted} bytes"
    );
}

#[tokio::test]
async fn echo_round_trip() {
    let pty = spawn(&["/bin/cat"]);
    let mut out = pty.subscribe_from(Seq::ZERO).unwrap();
    pty.write("hello pty\n").await.unwrap();
    // Once from the line discipline's echo, once from cat; the tty maps \n to \r\n.
    let seen = read_until(&mut out, "hello pty\r\nhello pty\r\n").await;
    assert_eq!(seen, "hello pty\r\nhello pty\r\n");
    assert_eq!(pty.head(), Seq::new(seen.len() as u64));
}

#[tokio::test]
async fn large_input_does_not_block_and_stays_ordered() {
    // 256 KiB is far beyond the kernel's PTY input queue (about 1 KiB on macOS in canonical
    // mode), so this only passes if writes are queued and flushed as the child reads.
    // Raw mode first: a canonical-mode line longer than MAX_CANON would be truncated.
    let pty = spawn(&[
        "/bin/sh",
        "-c",
        "stty raw -echo; echo READY; head -c 262144 | cksum",
    ]);
    let mut out = pty.subscribe_from(Seq::ZERO).unwrap();
    read_until(&mut out, "READY").await;
    let data: Vec<u8> = (0..262_144u32).map(|i| b'a' + (i % 26) as u8).collect();
    for piece in data.chunks(1000) {
        pty.write(piece.to_vec()).await.unwrap();
    }
    let expected = {
        let mut cksum = std::process::Command::new("/usr/bin/cksum")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        use std::io::Write;
        cksum.stdin.take().unwrap().write_all(&data).unwrap();
        String::from_utf8(cksum.wait_with_output().unwrap().stdout).unwrap()
    };
    let seen = read_to_end(&mut out).await;
    assert_eq!(seen.trim(), expected.trim());
}

#[tokio::test]
async fn resize_updates_winsize_and_signals_child() {
    let pty = spawn_with(
        &[
            "/bin/sh",
            "-c",
            "trap 'echo WINCH; stty size' WINCH; echo READY; while :; do sleep 0.05; done",
        ],
        SpawnOptions::new(WinSize::new(24, 80)),
    );
    let mut out = pty.subscribe_from(Seq::ZERO).unwrap();
    read_until(&mut out, "READY").await;
    assert_eq!(pty.size().unwrap(), WinSize::new(24, 80));

    let size = WinSize {
        rows: 40,
        cols: 132,
        pixel_width: 1320,
        pixel_height: 800,
    };
    pty.resize(size).unwrap();
    assert_eq!(pty.size().unwrap(), size);
    read_until(&mut out, "WINCH\r\n40 132").await;
    pty.signal(Signal::Kill).unwrap();
}

#[tokio::test]
async fn exit_status_and_output_close() {
    let pty = spawn(&["/bin/sh", "-c", "echo bye; exit 7"]);
    let mut out = pty.subscribe_from(Seq::ZERO).unwrap();
    let status = within("wait", pty.wait()).await.unwrap();
    assert_eq!(status.code(), Some(7));
    assert_eq!(read_to_end(&mut out).await, "bye\r\n");
    assert_eq!(out.recv().await, Err(RecvError::Closed));
    assert_eq!(pty.try_wait().unwrap().unwrap().code(), Some(7));
}

#[tokio::test]
async fn signal_terminates_and_is_refused_after_reap() {
    let pty = spawn(&["/bin/sleep", "60"]);
    assert!(pty.try_wait().is_none());
    pty.signal(Signal::Terminate).unwrap();
    let status = within("wait", pty.wait()).await.unwrap();
    assert_eq!(status.signal(), Some(libc::SIGTERM));
    assert!(matches!(
        pty.signal(Signal::Terminate),
        Err(SignalError::Exited)
    ));
}

#[tokio::test]
async fn write_after_exit_reports_closed() {
    let pty = spawn(&["/usr/bin/true"]);
    let mut out = pty.subscribe();
    within("wait", pty.wait()).await.unwrap();
    read_to_end(&mut out).await;
    // The I/O thread has stopped, so the queue's receiver is gone.
    assert!(pty.write("x").await.is_err());
}

#[tokio::test]
async fn dropping_the_actor_hangs_up_the_child() {
    let pty = spawn(&["/bin/sleep", "60"]);
    let pid = pty.pid() as libc::pid_t;
    drop(pty);
    // SIGHUP from the master closing kills `sleep`; the wait thread reaps it, after which the
    // pid no longer names our child.
    within("child reaped", async {
        // SAFETY: signal 0 only probes for existence.
        while unsafe { libc::kill(pid, 0) } == 0 {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await;
}
