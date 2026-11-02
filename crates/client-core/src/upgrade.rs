//! What the daemon is ([`proto::DaemonInfo`]) and replacing it with a newer build over the
//! connection (`proto::info`).

use std::io::Read;
use std::sync::Arc;
use std::time::Duration;

use proto::{
    DaemonInfo, StreamHeader, UpgradeEncoding, UpgradeFailure, UpgradeHeader, UpgradeReply,
};

use crate::workspace::TransferProgress;
use crate::{Client, Inner, lock};

/// How long [`Client::upgrade_daemon`] waits for a connection before giving up.
const CONNECT_WAIT: Duration = Duration::from_secs(20);
/// Bytes per write on the upgrade stream.
const CHUNK: usize = 64 * 1024;

/// Why [`Client::upgrade_daemon`] did not install the build.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UpgradeError {
    /// The daemon refused or failed; it keeps running the build it had.
    #[error("{message}")]
    Daemon {
        /// Machine-readable reason.
        code: UpgradeFailure,
        /// Why, in words.
        message: String,
    },
    /// The build could not be read or decoded here.
    #[error("{0}")]
    Local(String),
    /// The connection was lost or never came up; the daemon may or may not have it.
    #[error("{0}")]
    Connection(String),
}

/// A daemon build ready to send: the bytes as stored (raw or gzip) and the SHA-256 of the
/// executable they decode to.
#[derive(Debug, Clone)]
pub struct DaemonBuild {
    /// What goes on the wire.
    pub data: Vec<u8>,
    /// Its encoding.
    pub encoding: UpgradeEncoding,
    /// SHA-256 of the executable.
    pub sha256: [u8; 32],
    /// Its build id, for the daemon's log (may be empty).
    pub build: String,
    /// Whether the owner explicitly accepts a build older than the running one; otherwise
    /// the daemon refuses it ([`UpgradeFailure::Older`]). Off by default.
    pub downgrade: bool,
}

impl DaemonBuild {
    /// Prepares `data`, a raw executable or a gzip of one (detected by its magic bytes).
    ///
    /// # Errors
    ///
    /// [`UpgradeError::Local`] if a gzip does not decode.
    pub fn new(data: Vec<u8>, build: String) -> Result<Self, UpgradeError> {
        let (encoding, sha256) = if data.starts_with(&[0x1f, 0x8b]) {
            let mut exe = Vec::with_capacity(data.len() * 3);
            flate2::read::GzDecoder::new(data.as_slice())
                .read_to_end(&mut exe)
                .map_err(|e| {
                    UpgradeError::Local(format!("the bundled build does not decode: {e}"))
                })?;
            (UpgradeEncoding::Gzip, grants::sha256(&[exe.as_slice()]))
        } else {
            (UpgradeEncoding::Raw, grants::sha256(&[data.as_slice()]))
        };
        Ok(Self {
            data,
            encoding,
            sha256,
            build,
            downgrade: false,
        })
    }

    /// Reads [`DaemonBuild::new`]'s input from a file.
    ///
    /// # Errors
    ///
    /// [`UpgradeError::Local`] if the file cannot be read or decoded.
    pub fn from_file(path: &str, build: String) -> Result<Self, UpgradeError> {
        let data = std::fs::read(path).map_err(|e| UpgradeError::Local(format!("{path}: {e}")))?;
        Self::new(data, build)
    }
}

impl Client {
    /// What the daemon said about itself on the current (or last) connection: `None` until
    /// connected, and for daemons from before [`DaemonInfo`] existed.
    pub fn daemon_info(&self) -> Option<DaemonInfo> {
        lock(&self.inner.daemon_info).clone()
    }

    /// The kitty image storage per pane and screen this client's terminals keep for the
    /// current (or last) host ([`image_storage_limit`](crate::image_storage_limit)).
    pub fn image_storage_limit(&self) -> u64 {
        crate::image_storage_limit(*lock(&self.inner.image_storage_bytes))
    }

    /// Whether the last connection was let in only to upgrade the daemon (its snapshot
    /// format differs; see [`crate::ClientEvent::Incompatible`]).
    pub fn is_incompatible(&self) -> bool {
        *lock(&self.inner.incompatible)
    }

    /// Sends `build` to the daemon, which verifies it, swaps it in and restarts into it
    /// (owner devices only). Returns what the new build reported about itself; the
    /// connection then drops and the client redials the new daemon by itself (panes come back
    /// from the daemon's saved layout; their shells restart).
    ///
    /// # Errors
    ///
    /// [`UpgradeError::Daemon`] when the daemon refuses or the build fails its checks (the
    /// old daemon keeps running), [`UpgradeError::Connection`] when the link fails.
    pub async fn upgrade_daemon(
        &self,
        build: DaemonBuild,
        progress: Option<Arc<dyn TransferProgress>>,
    ) -> Result<DaemonInfo, UpgradeError> {
        let inner = Arc::clone(&self.inner);
        self.handle
            .spawn(async move { send_build(&inner, build, progress).await })
            .await
            .unwrap_or_else(|e| Err(UpgradeError::Connection(e.to_string())))
    }
}

fn link(e: impl std::fmt::Display) -> UpgradeError {
    UpgradeError::Connection(e.to_string())
}

async fn send_build(
    inner: &Inner,
    build: DaemonBuild,
    progress: Option<Arc<dyn TransferProgress>>,
) -> Result<DaemonInfo, UpgradeError> {
    let conn = tokio::time::timeout(CONNECT_WAIT, async {
        loop {
            if let Some(c) = lock(&inner.connection).clone() {
                return c;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .map_err(|_| UpgradeError::Connection("the host is not connected".into()))?;
    let (mut send, mut recv) = conn.open_bi().await.map_err(link)?;
    let _ = send.set_priority(1);
    let size = build.data.len() as u64;
    let header = UpgradeHeader {
        size,
        encoding: build.encoding,
        sha256: build.sha256,
        build: build.build,
    };
    let header = if build.downgrade {
        StreamHeader::Downgrade(header)
    } else {
        StreamHeader::Upgrade(header)
    };
    crate::conn::send(&mut send, &header).await.map_err(link)?;
    match crate::conn::recv::<UpgradeReply>(&mut recv)
        .await
        .map_err(link)?
    {
        Some(UpgradeReply::Ready) => {}
        Some(UpgradeReply::Failed { code, message }) => {
            return Err(UpgradeError::Daemon { code, message });
        }
        other => {
            return Err(UpgradeError::Connection(format!(
                "unexpected answer {other:?}"
            )));
        }
    }
    let mut sent = 0u64;
    for chunk in build.data.chunks(CHUNK) {
        send.write_all(chunk).await.map_err(link)?;
        sent += chunk.len() as u64;
        if let Some(p) = &progress {
            p.on_progress(sent, size);
        }
    }
    send.finish().map_err(link)?;
    match crate::conn::recv::<UpgradeReply>(&mut recv)
        .await
        .map_err(link)?
    {
        Some(UpgradeReply::Installed(info)) => Ok(info),
        Some(UpgradeReply::Failed { code, message }) => Err(UpgradeError::Daemon { code, message }),
        other => Err(UpgradeError::Connection(format!(
            "the host did not confirm the update ({other:?})"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::*;

    #[test]
    fn gzip_builds_hash_the_executable() {
        let exe = b"\x7fELF pretend executable".repeat(100);
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::best());
        gz.write_all(&exe).unwrap();
        let packed = gz.finish().unwrap();
        let build = DaemonBuild::new(packed.clone(), "b1".into()).unwrap();
        assert_eq!(build.encoding, UpgradeEncoding::Gzip);
        assert_eq!(build.sha256, grants::sha256(&[exe.as_slice()]));
        assert_eq!(build.data, packed);
        let raw = DaemonBuild::new(exe.clone(), String::new()).unwrap();
        assert_eq!(raw.encoding, UpgradeEncoding::Raw);
        assert_eq!(raw.sha256, build.sha256);
        assert!(matches!(
            DaemonBuild::new(vec![0x1f, 0x8b, 0, 1, 2], String::new()),
            Err(UpgradeError::Local(_))
        ));
    }
}
