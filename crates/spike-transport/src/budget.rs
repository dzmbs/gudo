//!
//! The client acknowledges output by [`Seq`] (PTY byte offset), but what occupies the network is
//! wire bytes, and a snapshot makes `Seq` jump by the whole skipped range while costing only
//! its blob size. So the budget counts wire bytes per sent frame and releases them when the
//! client's cumulative ack passes the frame's end offset.

use std::collections::VecDeque;

use proto::Seq;

/// Wire bytes sent but not yet acknowledged, keyed by the output offset each frame ends at.
#[derive(Debug, Default)]
pub struct InFlight {
    frames: VecDeque<(Seq, usize)>,
    bytes: usize,
}

impl InFlight {
    /// Records a frame of `wire_len` bytes that brings the client to offset `end`.
    pub fn push(&mut self, end: Seq, wire_len: usize) {
        self.frames.push_back((end, wire_len));
        self.bytes += wire_len;
    }

    /// Releases every frame the cumulative ack `acked` covers.
    pub fn ack(&mut self, acked: Seq) {
        while let Some(&(end, len)) = self.frames.front() {
            if end > acked {
                break;
            }
            self.frames.pop_front();
            self.bytes -= len;
        }
    }

    /// Unacknowledged wire bytes.
    pub fn bytes(&self) -> usize {
        self.bytes
    }

    /// Returns `true` when the client has acknowledged everything sent.
    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_jump_releases_by_offset_not_size() {
        let mut f = InFlight::default();
        f.push(Seq(100), 110);
        // A snapshot taking the client from 100 to 1_000_000 costs only its blob.
        f.push(Seq(1_000_000), 4_000);
        f.ack(Seq(100));
        assert_eq!(f.bytes(), 4_000);
        f.ack(Seq(999_999));
        assert_eq!(f.bytes(), 4_000);
        f.ack(Seq(1_000_000));
        assert!(f.is_empty());
        assert_eq!(f.bytes(), 0);
    }
}
