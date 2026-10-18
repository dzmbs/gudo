//! Per-pane client state: the resume point and an optional libghostty-vt mirror.

use ghostty_vt::{SnapshotDecoder, Terminal, TextRegion};
use proto::{PaneSize, SnapGen};

/// Where a pane's output stands on this client.
pub(crate) struct Mirror {
    pub snap_gen: SnapGen,
    seq: u64,
    pub acked: u64,
    vt: Option<Terminal>,
}

/// What applying a `Bytes` frame did.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Applied {
    /// These bytes (possibly a suffix of the frame) are new.
    New { seq: u64, start: usize },
    /// Already applied.
    Duplicate,
    /// Bytes are missing before this frame; a snapshot is needed.
    Gap,
}

impl Mirror {
    /// A mirror restored from a READY snapshot.
    pub fn from_snapshot(snap_gen: SnapGen, seq: u64, snapshot: &[u8], keep_vt: bool) -> Self {
        let vt = keep_vt
            .then(|| {
                SnapshotDecoder::new(snapshot)
                    .and_then(SnapshotDecoder::ready)
                    .map(ghostty_vt::Restore::into_terminal)
                    .map_err(|e| tracing::warn!("decoding snapshot: {e}"))
                    .ok()
            })
            .flatten();
        Self {
            snap_gen,
            seq,
            acked: 0,
            vt,
        }
    }

    pub fn seq(&self) -> u64 {
        self.seq
    }

    /// Applies output at `seq`, trimming any part already applied.
    pub fn apply(&mut self, seq: u64, data: &[u8]) -> Applied {
        let end = seq + data.len() as u64;
        if end <= self.seq {
            return Applied::Duplicate;
        }
        if seq > self.seq {
            return Applied::Gap;
        }
        let start = (self.seq - seq) as usize;
        if let Some(vt) = &mut self.vt {
            vt.write(&data[start..]);
        }
        self.seq = end;
        Applied::New {
            seq: seq + start as u64,
            start,
        }
    }

    pub fn resize(&mut self, size: PaneSize) {
        if let Some(vt) = &mut self.vt
            && let Err(e) = vt.resize(size.cols, size.rows)
        {
            tracing::warn!("resizing mirror: {e}");
        }
    }

    pub fn text(&self) -> Option<String> {
        self.vt.as_ref()?.text(TextRegion::Active).ok()
    }

    pub fn vt(&self) -> Option<String> {
        self.vt.as_ref()?.vt(TextRegion::Active).ok()
    }

    pub fn snapshot(&self) -> Option<Vec<u8>> {
        self.vt.as_ref()?.encode_snapshot().ok()
    }
}
