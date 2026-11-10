//! What one connection may have running at once (`Config::connection`), and stream writes
//! and reads that give up on a peer that stopped taking or sending bytes.

use std::sync::Arc;
use std::time::Duration;

use iroh::endpoint::{ReadError, RecvStream, SendStream, WriteError};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use crate::config::ConnectionLimits;

/// Requests of one kind: up to `waiting` accepted at once, `running` of them at a time.
pub(crate) struct RequestGate {
    accepted: Arc<Semaphore>,
    running: Arc<Semaphore>,
}

/// An accepted request waiting for its turn.
pub(crate) struct Accepted {
    accepted: OwnedSemaphorePermit,
    running: Arc<Semaphore>,
}

/// A request's turn to run; the next one starts when this is dropped.
pub(crate) struct Turn {
    _accepted: OwnedSemaphorePermit,
    _running: OwnedSemaphorePermit,
}

impl RequestGate {
    fn new(running: usize, waiting: usize) -> Self {
        Self {
            accepted: Arc::new(Semaphore::new(waiting.max(1))),
            running: Arc::new(Semaphore::new(running.max(1))),
        }
    }

    /// `None` when as many requests as allowed are already in.
    pub fn accept(&self) -> Option<Accepted> {
        let accepted = Arc::clone(&self.accepted).try_acquire_owned().ok()?;
        Some(Accepted {
            accepted,
            running: Arc::clone(&self.running),
        })
    }
}

impl Accepted {
    pub async fn turn(self) -> Turn {
        let running = self
            .running
            .acquire_owned()
            .await
            .expect("a request gate's semaphore is never closed");
        Turn {
            _accepted: self.accepted,
            _running: running,
        }
    }
}

/// The answer to a request refused because as many of its kind are already in.
pub(crate) const BUSY: &str = "busy: too many requests of this kind at once; try again";

/// One connection's budgets.
pub(crate) struct Budgets {
    /// Blob streams served at once.
    pub blobs: Arc<Semaphore>,
    /// File uploads and downloads served at once.
    pub transfers: Arc<Semaphore>,
    pub searches: RequestGate,
    pub links: RequestGate,
    pub commands: RequestGate,
    pub command_outputs: RequestGate,
    pub history_pages: RequestGate,
    pub artifacts: RequestGate,
    pub stall: Duration,
}

impl Budgets {
    pub fn new(limits: &ConnectionLimits) -> Self {
        let gate = || RequestGate::new(limits.requests_running, limits.requests_waiting);
        Self {
            blobs: Arc::new(Semaphore::new(limits.transfers.max(1))),
            transfers: Arc::new(Semaphore::new(limits.transfers.max(1))),
            searches: gate(),
            links: gate(),
            commands: gate(),
            command_outputs: gate(),
            history_pages: gate(),
            artifacts: gate(),
            stall: limits.stall,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum StreamError {
    #[error("the peer took or sent nothing for {} s", .0.as_secs())]
    Stalled(Duration),
    #[error(transparent)]
    Write(#[from] WriteError),
    #[error(transparent)]
    Read(#[from] ReadError),
}

/// Writes all of `bytes`, giving up when the peer takes none of them for `stall`.
pub(crate) async fn write_or_stall(
    send: &mut SendStream,
    bytes: &[u8],
    stall: Duration,
) -> Result<(), StreamError> {
    let mut written = 0;
    while written < bytes.len() {
        written += tokio::time::timeout(stall, send.write(&bytes[written..]))
            .await
            .map_err(|_| StreamError::Stalled(stall))??;
    }
    Ok(())
}

/// Reads into `buffer` (`None` at the end of the stream), giving up when the peer sends
/// nothing for `stall`.
pub(crate) async fn read_or_stall(
    recv: &mut RecvStream,
    buffer: &mut [u8],
    stall: Duration,
) -> Result<Option<usize>, StreamError> {
    Ok(tokio::time::timeout(stall, recv.read(buffer))
        .await
        .map_err(|_| StreamError::Stalled(stall))??)
}
