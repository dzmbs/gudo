use std::time::Duration;

use pty::{SpawnOptions, TryWriteError, WinSize};
use tokio::sync::oneshot;

use crate::support::{spawn_with, within};

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
