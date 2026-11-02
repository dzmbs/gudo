//! Per-pane client state: the resume point, the history cursor and an optional libghostty-vt
//! mirror.

use ghostty_vt::{KittyImage, KittyPlacement, StreamingRestore, Terminal, TextRegion};
use proto::{PaneSize, SnapGen};

/// The mirror's terminal: still taking history pages, or complete.
enum Vt {
    Restoring(StreamingRestore),
    Done(Terminal),
}

impl Vt {
    fn terminal(&self) -> &Terminal {
        match self {
            Self::Restoring(r) => r.terminal(),
            Self::Done(t) => t,
        }
    }
}

/// Where paging through a snapshot's history stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct HistoryCursor {
    /// `seq` of the snapshot the history belongs to.
    pub snapshot_seq: u64,
    /// Offset of the next page in that snapshot.
    pub next_offset: u64,
    /// No more history.
    pub done: bool,
    /// A request is outstanding.
    pub in_flight: bool,
}

/// Where a pane's output stands on this client.
pub(crate) struct Mirror {
    pub snap_gen: SnapGen,
    seq: u64,
    pub acked: u64,
    vt: Option<Vt>,
    pub history: HistoryCursor,
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
    /// A mirror restored from a READY snapshot taken at `seq`, keeping `image_storage_bytes`
    /// of kitty images per screen.
    pub fn from_snapshot(
        snap_gen: SnapGen,
        seq: u64,
        snapshot: &[u8],
        keep_vt: bool,
        image_storage_bytes: u64,
    ) -> Self {
        let vt = keep_vt
            .then(|| {
                // The daemon's own limit bounds the history a mirror can receive, so the
                // mirror takes all of it (libghostty-vt's default would drop older pages).
                StreamingRestore::with_image_storage_limit(snapshot, image_storage_bytes)
                    .and_then(|mut r| {
                        r.set_scrollback_max_bytes(None)?;
                        Ok(r)
                    })
                    .map(Vt::Restoring)
                    .map_err(|e| tracing::warn!("decoding snapshot: {e}"))
                    .ok()
            })
            .flatten();
        Self {
            snap_gen,
            seq,
            acked: 0,
            vt,
            history: HistoryCursor {
                snapshot_seq: seq,
                next_offset: snapshot.len() as u64,
                done: false,
                in_flight: false,
            },
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
        match &mut self.vt {
            Some(Vt::Restoring(r)) => r.write(&data[start..]),
            Some(Vt::Done(t)) => t.write(&data[start..]),
            None => {}
        }
        self.seq = end;
        Applied::New {
            seq: seq + start as u64,
            start,
        }
    }

    /// Applies history records at `offset` of snapshot `snapshot_seq`. Returns the rows
    /// prepended to the mirror, or `None` if the page does not continue this mirror's history
    /// (an older snapshot's, or a repeat).
    pub fn apply_history(
        &mut self,
        snapshot_seq: u64,
        offset: u64,
        next_offset: u64,
        done: bool,
        records: &[u8],
    ) -> Option<u64> {
        let h = &mut self.history;
        if snapshot_seq != h.snapshot_seq || offset != h.next_offset || h.done {
            return None;
        }
        h.in_flight = false;
        h.next_offset = next_offset;
        h.done = done;
        let mut rows = 0;
        if let Some(Vt::Restoring(restore)) = &mut self.vt {
            match restore.push(records) {
                Ok(pages) => rows = pages.iter().map(|p| p.rows as u64).sum(),
                Err(e) => {
                    tracing::warn!("restoring history: {e}");
                    self.history.done = true;
                }
            }
        }
        if self.history.done
            && let Some(Vt::Restoring(_)) = &self.vt
            && let Some(Vt::Restoring(restore)) = self.vt.take()
        {
            self.vt = Some(Vt::Done(restore.into_terminal()));
        }
        Some(rows)
    }

    pub fn resize(&mut self, size: PaneSize) {
        let result = match &mut self.vt {
            Some(Vt::Restoring(r)) => r.resize(size.cols, size.rows, size.cell_px()),
            Some(Vt::Done(t)) => t.resize(size.cols, size.rows, size.cell_px()),
            None => Ok(()),
        };
        if let Err(e) = result {
            tracing::warn!("resizing mirror: {e}");
        }
    }

    fn terminal(&self) -> Option<&Terminal> {
        self.vt.as_ref().map(Vt::terminal)
    }

    pub fn text(&self) -> Option<String> {
        self.terminal()?.text(TextRegion::Active).ok()
    }

    pub fn text_all(&self) -> Option<String> {
        self.terminal()?.text(TextRegion::All).ok()
    }

    pub fn vt(&self) -> Option<String> {
        self.terminal()?.vt(TextRegion::Active).ok()
    }

    pub fn images(&self) -> Option<Vec<(KittyPlacement, Option<KittyImage>)>> {
        let terminal = self.terminal()?;
        Some(
            terminal
                .kitty_placements()
                .into_iter()
                .map(|p| (p, terminal.kitty_image(p.image_id)))
                .collect(),
        )
    }

    pub fn snapshot(&self) -> Option<Vec<u8>> {
        self.terminal()?.encode_snapshot().ok()
    }

    pub fn scrollback_rows(&self) -> Option<usize> {
        Some(self.terminal()?.scrollback_rows())
    }
}
