//! Loopback ports that stay the same across restarts. They come from ranges below the ephemeral
//! ones of macOS (49152+) and Linux (32768+), so the system never hands them to another
//! program's outgoing connection.

use std::io;
use std::ops::RangeInclusive;
use std::time::{Duration, Instant};

use crate::fsutil;

/// How long a saved port is retried while the server that held it lets go.
const SAVED_PORT_WAIT: Duration = Duration::from_secs(1);
const SAVED_PORT_RETRY: Duration = Duration::from_millis(50);
const ATTEMPTS: usize = 32;

/// Binds `saved`, retrying for a moment in case its last owner is still letting go of it.
pub(crate) async fn bind_saved<Listener>(
    saved: u16,
    bind: impl Fn(u16) -> io::Result<Listener>,
) -> io::Result<Listener> {
    let deadline = Instant::now() + SAVED_PORT_WAIT;
    loop {
        match bind(saved) {
            Ok(listener) => return Ok(listener),
            Err(error) if Instant::now() >= deadline => return Err(error),
            Err(_) => tokio::time::sleep(SAVED_PORT_RETRY).await,
        }
    }
}

/// Binds a random free port from `range` that `is_taken` does not claim, else any port.
pub(crate) fn bind_new<Listener>(
    range: &RangeInclusive<u16>,
    is_taken: impl Fn(u16) -> bool,
    bind: impl Fn(u16) -> io::Result<Listener>,
) -> io::Result<Listener> {
    match (0..ATTEMPTS)
        .map(|_| random_port(range))
        .filter(|&port| !is_taken(port))
        .find_map(|port| bind(port).ok())
    {
        Some(listener) => Ok(listener),
        None => bind(0),
    }
}

fn random_port(range: &RangeInclusive<u16>) -> u16 {
    let span = range.end() - range.start() + 1;
    range.start() + u16::from_le_bytes(fsutil::random::<2>()) % span
}
