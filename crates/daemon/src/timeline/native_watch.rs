use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use notify::Watcher;
use notify::event::{AccessKind, AccessMode};
use proto::WsError;
use tokio::sync::mpsc;

#[cfg(test)]
#[path = "native_watch_tests.rs"]
mod tests;

pub(super) struct NativeWatch {
    pub(super) _watcher: notify::RecommendedWatcher,
    pub(super) failed: Arc<AtomicBool>,
}

impl NativeWatch {
    /// Attaches before the initial read and queues one reconciliation for the attachment race.
    pub(super) fn new(path: &Path, wake: mpsc::Sender<()>) -> Result<Self, WsError> {
        let failed = Arc::new(AtomicBool::new(false));
        let callback_failed = Arc::clone(&failed);
        let callback_wake = wake.clone();
        let mut watcher = notify::recommended_watcher(move |event| {
            deliver(event, &callback_failed, &callback_wake);
        })
        .map_err(|_| unavailable())?;
        watcher
            .watch(path, notify::RecursiveMode::NonRecursive)
            .map_err(|_| unavailable())?;
        // File/agent changes during attachment are reconciled even before run subscribes.
        let _ = wake.try_send(());
        Ok(Self {
            _watcher: watcher,
            failed,
        })
    }

    /// Fails closed if the backend lost coverage; a clock cannot repair a failed subscription.
    pub(super) fn check(&self) -> Result<(), WsError> {
        if self.failed.load(Ordering::Acquire) {
            Err(unavailable())
        } else {
            Ok(())
        }
    }
}

fn deliver(event: notify::Result<notify::Event>, failed: &AtomicBool, wake: &mpsc::Sender<()>) {
    match event {
        // Observing a transcript must not recursively wake its own reader on Linux.
        Ok(event)
            if matches!(
                event.kind,
                notify::EventKind::Access(
                    AccessKind::Read | AccessKind::Open(_) | AccessKind::Close(AccessMode::Read)
                )
            ) =>
        {
            return;
        }
        Ok(_) => {}
        Err(_) => failed.store(true, Ordering::Release),
    }
    // Failure is sticky, including when a successful event already occupies the single slot.
    let _ = wake.try_send(());
}

fn unavailable() -> WsError {
    WsError::Unavailable("Chat could not watch this session. Open Terminal to continue.".into())
}
