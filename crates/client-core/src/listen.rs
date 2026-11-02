//! The local listener behind a port forward.
//!
//! iOS defuncts a suspended app's sockets, listening ones included: after a resume the old
//! listener accepts nothing (or only fails) while the port still looks taken by us. So a
//! forward's listener is bound again on the same port each time the client resumes
//! ([`crate::Client::reconnect`] after [`crate::Client::suspend`]), and whenever accepting
//! fails for a reason other than one aborted connection.

use std::io;
use std::net::TcpListener as StdTcpListener;
use std::time::Duration;

use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;

/// Longest wait between attempts to bind the port again.
const MAX_REBIND_WAIT: Duration = Duration::from_secs(2);

/// A `127.0.0.1` listener that comes back after the app was suspended.
pub(crate) struct LocalListener {
    port: u16,
    listener: Option<TcpListener>,
    resumed: watch::Receiver<u64>,
}

impl LocalListener {
    /// Takes over a bound, non-blocking listener; `resumed` changes on each resume.
    pub(crate) fn new(listener: StdTcpListener, resumed: watch::Receiver<u64>) -> io::Result<Self> {
        let port = listener.local_addr()?.port();
        Ok(Self {
            port,
            listener: Some(TcpListener::from_std(listener)?),
            resumed,
        })
    }

    pub(crate) async fn accept(&mut self) -> TcpStream {
        loop {
            let Some(listener) = &self.listener else {
                self.rebind().await;
                continue;
            };
            tokio::select! {
                accepted = listener.accept() => match accepted {
                    Ok((stream, _)) => return stream,
                    Err(err) if matches!(
                        err.kind(),
                        io::ErrorKind::ConnectionAborted | io::ErrorKind::Interrupted
                    ) => {}
                    Err(err) => {
                        tracing::debug!("forward accept on {}: {err}", self.port);
                        // Out of file descriptors and the like: no spinning.
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        self.rebind().await;
                    }
                },
                Ok(()) = self.resumed.changed() => self.rebind().await,
            }
        }
    }

    /// Closes the listener and binds the same port again, retrying until it works.
    async fn rebind(&mut self) {
        // The old socket must be closed before its port can be bound again.
        self.listener = None;
        let mut wait = Duration::from_millis(20);
        loop {
            match TcpListener::bind(("127.0.0.1", self.port)).await {
                Ok(listener) => {
                    tracing::debug!("forward listener on {} bound again", self.port);
                    self.listener = Some(listener);
                    return;
                }
                Err(err) => {
                    tracing::debug!("forward rebind on {}: {err}", self.port);
                    tokio::time::sleep(wait).await;
                    wait = (wait * 2).min(MAX_REBIND_WAIT);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn binds_the_same_port_again_on_resume() {
        let bound = StdTcpListener::bind(("127.0.0.1", 0)).unwrap();
        bound.set_nonblocking(true).unwrap();
        let port = bound.local_addr().unwrap().port();
        let (resumed, resumed_rx) = watch::channel(0);
        let mut listener = LocalListener::new(bound, resumed_rx).unwrap();

        let (accepted, mut seen) = tokio::sync::mpsc::unbounded_channel();
        tokio::spawn(async move {
            loop {
                let stream = listener.accept().await;
                let _ = accepted.send(stream);
            }
        });
        let _first = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        assert!(seen.recv().await.is_some());

        resumed.send_modify(|resumes| *resumes += 1);
        // A connection that reached the old listener just before it closed is lost: try again
        // until the new one accepts.
        let mut again = false;
        for _ in 0..50 {
            if let Ok(_stream) = TcpStream::connect(("127.0.0.1", port)).await
                && tokio::time::timeout(Duration::from_millis(100), seen.recv())
                    .await
                    .is_ok()
            {
                again = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(again, "the port accepts again after a resume");
    }
}
