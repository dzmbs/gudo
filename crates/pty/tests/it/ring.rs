use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use pty::{ReadError, RecvError, Seq, SpawnOptions};

use crate::support::{read_to_end, spawn_with, within};

const CAPACITY: usize = 1024;
const PRODUCED: u64 = 5000;

fn flood() -> SpawnOptions {
    SpawnOptions::default().ring_capacity(CAPACITY)
}

/// `PRODUCED` bytes of `a` with no newlines (so the tty expands nothing), in ten 500-byte bursts
/// paced so that a subscriber that is reading can keep up with a 1 KiB ring.
const FLOOD: &[&str] = &[
    "/bin/sh",
    "-c",
    "i=0; while [ $i -lt 10 ]; do head -c 500 /dev/zero | tr '\\0' a; sleep 0.05; i=$((i+1)); done",
];

#[tokio::test]
async fn slow_subscriber_is_evicted_and_can_resync() {
    let hook_total = Arc::new(AtomicU64::new(0));
    let options = flood().output_hook({
        let hook_total = Arc::clone(&hook_total);
        move |seq, data| {
            // The hook sees every byte, in order, regardless of the ring.
            assert_eq!(seq.get(), hook_total.load(Ordering::Relaxed));
            hook_total.fetch_add(data.len() as u64, Ordering::Relaxed);
        }
    });
    let pty = spawn_with(FLOOD, options);
    let mut fast = pty.subscribe_from(Seq::ZERO).unwrap();
    let mut slow = pty.subscribe_from(Seq::ZERO).unwrap();

    // A subscriber that keeps up sees the full stream even though the ring is smaller.
    let all = read_to_end(&mut fast).await;
    assert_eq!(all.len() as u64, PRODUCED);
    assert!(all.bytes().all(|b| b == b'a'));
    within("wait", pty.wait()).await.unwrap();

    assert_eq!(pty.head(), Seq::new(PRODUCED));
    assert_eq!(pty.oldest(), Seq::new(PRODUCED - CAPACITY as u64));
    assert_eq!(hook_total.load(Ordering::Relaxed), PRODUCED);

    // The one that never read has fallen out of the ring; its cursor does not move.
    let evicted = RecvError::Evicted {
        requested: Seq::ZERO,
        oldest: pty.oldest(),
    };
    assert_eq!(slow.recv().await, Err(evicted));
    assert_eq!(slow.recv().await, Err(evicted));
    assert_eq!(slow.position(), Seq::ZERO);

    // Resync at the oldest retained byte (in the daemon: after sending a snapshot).
    slow.seek(pty.oldest()).unwrap();
    assert_eq!(read_to_end(&mut slow).await.len(), CAPACITY);
}

#[tokio::test]
async fn read_from_serves_ring_and_reports_out_of_range() {
    let pty = spawn_with(FLOOD, flood());
    let mut out = pty.subscribe();
    within("wait", pty.wait()).await.unwrap();
    // Wait for output to end, skipping whatever this subscriber missed.
    within("output end", async {
        loop {
            match out.recv().await {
                Ok(_) => {}
                Err(RecvError::Evicted { oldest, .. }) => out.seek(oldest).unwrap(),
                Err(RecvError::Closed) => break,
            }
        }
    })
    .await;
    assert_eq!(pty.head(), Seq::new(PRODUCED));

    let oldest = pty.oldest();
    let chunk = pty.read_from(oldest).unwrap();
    assert_eq!((chunk.seq, chunk.data.len()), (oldest, CAPACITY));
    assert_eq!(chunk.end(), pty.head());
    assert!(pty.read_from(pty.head()).unwrap().data.is_empty());
    assert_eq!(
        pty.read_from(Seq::new(10)),
        Err(ReadError::Evicted {
            requested: Seq::new(10),
            oldest
        })
    );
    assert!(matches!(
        pty.read_from(pty.head() + 1),
        Err(ReadError::Ahead { .. })
    ));
    assert!(pty.subscribe_from(Seq::ZERO).is_err());
}
