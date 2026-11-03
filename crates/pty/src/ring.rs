//! Fixed-capacity output history addressed by absolute byte offset.

use std::fmt;
use std::ops::Add;

use bytes::Bytes;

/// Default ring capacity per pane: 1 MiB.
pub const DEFAULT_RING_CAPACITY: usize = 1 << 20;

/// An absolute byte offset into a pane's output stream.
///
/// The first byte the child ever writes has offset 0. Offsets never wrap and never repeat for
/// the lifetime of a pane, so a client can resume by sending the offset of the first byte it has
/// not yet applied.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Seq(u64);

impl Seq {
    /// The offset of the first byte of a stream.
    pub const ZERO: Seq = Seq(0);

    /// Wraps a raw offset.
    pub const fn new(offset: u64) -> Self {
        Self(offset)
    }

    /// Returns the raw offset.
    pub const fn get(self) -> u64 {
        self.0
    }
}

impl From<u64> for Seq {
    fn from(offset: u64) -> Self {
        Self(offset)
    }
}

impl From<Seq> for u64 {
    fn from(seq: Seq) -> Self {
        seq.0
    }
}

impl Add<u64> for Seq {
    type Output = Seq;

    fn add(self, rhs: u64) -> Seq {
        Seq(self.0 + rhs)
    }
}

impl fmt::Display for Seq {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

/// A run of output bytes and the offset of its first byte.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chunk {
    /// Offset of `data[0]`.
    pub seq: Seq,
    /// The bytes. May be empty when the reader is already at the head.
    pub data: Bytes,
}

impl Chunk {
    /// Returns the offset one past the last byte, i.e. where the next read should start.
    pub fn end(&self) -> Seq {
        self.seq + self.data.len() as u64
    }
}

/// Why an offset cannot be served from the ring.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ReadError {
    /// The bytes at `requested` were overwritten. The caller needs a terminal snapshot; the
    /// oldest offset still retained is `oldest`.
    #[error("offset {requested} was evicted; oldest retained offset is {oldest}")]
    Evicted {
        /// The offset that was asked for.
        requested: Seq,
        /// The oldest offset still in the ring.
        oldest: Seq,
    },
    /// The offset has not been produced yet (for example a client resuming against a restarted
    /// daemon). The caller needs a snapshot too.
    #[error("offset {requested} is past the head {head}")]
    Ahead {
        /// The offset that was asked for.
        requested: Seq,
        /// One past the newest byte written.
        head: Seq,
    },
}

/// A fixed-capacity circular byte buffer that remembers the last `capacity` bytes written and
/// the absolute offset of each.
///
/// # Examples
///
/// ```
/// use pty::{OutputRing, ReadError, Seq};
///
/// let mut ring = OutputRing::new(4);
/// ring.push(b"abcdef");
/// assert_eq!(ring.oldest(), Seq::new(2));
/// assert_eq!(ring.head(), Seq::new(6));
/// assert_eq!(&ring.read_from(Seq::new(3)).unwrap().data[..], b"def");
/// assert!(matches!(ring.read_from(Seq::new(1)), Err(ReadError::Evicted { .. })));
/// ```
pub struct OutputRing {
    bytes: Box<[u8]>,
    head: u64,
}

impl OutputRing {
    /// Creates an empty ring that retains up to `capacity` bytes.
    ///
    /// # Panics
    ///
    /// Panics if `capacity` is zero.
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "ring capacity must be non-zero");
        Self {
            bytes: vec![0; capacity].into_boxed_slice(),
            head: 0,
        }
    }

    /// Recreates a ring of `capacity` whose head is `head` and whose retained bytes are
    /// `retained`, as [`read_from`](Self::read_from) at [`oldest`](Self::oldest) returned them:
    /// offsets carry on where an earlier ring left off.
    ///
    /// Returns `None` unless `retained` is exactly what such a ring holds (the last
    /// `min(head, capacity)` bytes), so no offset ever reads bytes that were not written.
    ///
    /// # Panics
    ///
    /// Panics if `capacity` is zero.
    ///
    /// # Examples
    ///
    /// ```
    /// use pty::{OutputRing, Seq};
    ///
    /// let mut ring = OutputRing::new(4);
    /// ring.push(b"abcdef");
    /// let retained = ring.read_from(ring.oldest()).unwrap().data;
    /// let resumed = OutputRing::resume(4, ring.head(), &retained).unwrap();
    /// assert_eq!(resumed.oldest(), Seq::new(2));
    /// assert_eq!(&resumed.read_from(Seq::new(3)).unwrap().data[..], b"def");
    /// ```
    pub fn resume(capacity: usize, head: Seq, retained: &[u8]) -> Option<Self> {
        let mut ring = Self::new(capacity);
        if retained.len() as u64 != head.0.min(capacity as u64) {
            return None;
        }
        ring.head = head.0 - retained.len() as u64;
        ring.push(retained);
        Some(ring)
    }

    /// Returns the maximum number of bytes retained.
    pub fn capacity(&self) -> usize {
        self.bytes.len()
    }

    /// Returns the number of bytes currently retained.
    pub fn len(&self) -> usize {
        (self.head - self.oldest().0) as usize
    }

    /// Returns `true` if nothing has been written yet.
    pub fn is_empty(&self) -> bool {
        self.head == 0
    }

    /// Returns the offset one past the newest byte written.
    pub fn head(&self) -> Seq {
        Seq(self.head)
    }

    /// Returns the offset of the oldest byte still retained (equal to [`head`](Self::head) when
    /// nothing is retained).
    pub fn oldest(&self) -> Seq {
        Seq(self.head.saturating_sub(self.bytes.len() as u64))
    }

    /// Appends bytes, evicting the oldest bytes beyond capacity.
    pub fn push(&mut self, data: &[u8]) {
        let capacity = self.bytes.len();
        let total = data.len() as u64;
        // Only the tail that fits can survive; skip the rest without copying it.
        let data = &data[data.len().saturating_sub(capacity)..];
        let start = self.head + (total - data.len() as u64);
        let position = (start % capacity as u64) as usize;
        let first = data.len().min(capacity - position);
        self.bytes[position..position + first].copy_from_slice(&data[..first]);
        self.bytes[..data.len() - first].copy_from_slice(&data[first..]);
        self.head += total;
    }

    /// Returns every retained byte from `seq` to the head.
    ///
    /// Reading at exactly the head returns an empty chunk.
    ///
    /// # Errors
    ///
    /// Returns [`ReadError::Evicted`] if `seq` is older than [`oldest`](Self::oldest) and
    /// [`ReadError::Ahead`] if it is past [`head`](Self::head).
    pub fn read_from(&self, seq: Seq) -> Result<Chunk, ReadError> {
        self.read_at_most(seq, usize::MAX)
    }

    /// Like [`read_from`](Self::read_from), but returns at most `max_len` bytes.
    ///
    /// # Errors
    ///
    /// Same as [`read_from`](Self::read_from).
    pub fn read_at_most(&self, seq: Seq, max_len: usize) -> Result<Chunk, ReadError> {
        if seq.0 > self.head {
            return Err(ReadError::Ahead {
                requested: seq,
                head: self.head(),
            });
        }
        if seq < self.oldest() {
            return Err(ReadError::Evicted {
                requested: seq,
                oldest: self.oldest(),
            });
        }
        let capacity = self.bytes.len();
        let len = ((self.head - seq.0) as usize).min(max_len);
        let position = (seq.0 % capacity as u64) as usize;
        let first = len.min(capacity - position);
        let mut data = Vec::with_capacity(len);
        data.extend_from_slice(&self.bytes[position..position + first]);
        data.extend_from_slice(&self.bytes[..len - first]);
        Ok(Chunk {
            seq,
            data: data.into(),
        })
    }
}

impl fmt::Debug for OutputRing {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OutputRing")
            .field("capacity", &self.capacity())
            .field("oldest", &self.oldest())
            .field("head", &self.head())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;

    #[test]
    fn empty_ring_reads_empty_at_zero() {
        let ring = OutputRing::new(8);
        assert!(ring.is_empty());
        assert_eq!(ring.read_from(Seq::ZERO).unwrap().data.len(), 0);
        assert_eq!(
            ring.read_from(Seq::new(1)),
            Err(ReadError::Ahead {
                requested: Seq::new(1),
                head: Seq::ZERO
            })
        );
    }

    #[test]
    fn wraps_and_evicts() {
        let mut ring = OutputRing::new(5);
        ring.push(b"abc");
        ring.push(b"defg");
        assert_eq!(ring.head(), Seq::new(7));
        assert_eq!(ring.oldest(), Seq::new(2));
        assert_eq!(ring.len(), 5);
        assert_eq!(&ring.read_from(Seq::new(2)).unwrap().data[..], b"cdefg");
        assert_eq!(&ring.read_at_most(Seq::new(3), 2).unwrap().data[..], b"de");
        assert_eq!(
            ring.read_from(Seq::new(1)),
            Err(ReadError::Evicted {
                requested: Seq::new(1),
                oldest: Seq::new(2)
            })
        );
    }

    #[test]
    fn resumes_where_another_ring_left_off() {
        for written in [0usize, 3, 5, 12] {
            let mut ring = OutputRing::new(5);
            let data: Vec<u8> = (0..written as u8).collect();
            ring.push(&data);
            let retained = ring.read_from(ring.oldest()).unwrap().data;
            let mut resumed = OutputRing::resume(5, ring.head(), &retained).unwrap();
            assert_eq!(resumed.head(), ring.head());
            assert_eq!(resumed.oldest(), ring.oldest());
            assert_eq!(resumed.read_from(ring.oldest()).unwrap().data, retained);
            resumed.push(b"xy");
            ring.push(b"xy");
            assert_eq!(
                resumed.read_from(ring.oldest()).unwrap(),
                ring.read_from(ring.oldest()).unwrap()
            );
        }
        assert!(OutputRing::resume(5, Seq::new(12), b"abc").is_none());
        assert!(OutputRing::resume(5, Seq::new(2), b"abc").is_none());
    }

    #[test]
    fn push_larger_than_capacity_keeps_tail() {
        let mut ring = OutputRing::new(3);
        ring.push(b"x");
        ring.push(b"0123456789");
        assert_eq!(ring.head(), Seq::new(11));
        assert_eq!(&ring.read_from(ring.oldest()).unwrap().data[..], b"789");
    }

    #[test]
    #[should_panic(expected = "non-zero")]
    fn zero_capacity_panics() {
        let _ = OutputRing::new(0);
    }

    proptest! {
        /// The ring agrees with an unbounded `Vec` model on every in-range read and reports
        /// the right error out of range.
        #[test]
        fn matches_unbounded_model(
            cap in 1usize..64,
            pushes in prop::collection::vec(prop::collection::vec(any::<u8>(), 0..100), 0..20),
            probes in prop::collection::vec((0u64..2200, 0usize..80), 1..20),
        ) {
            let mut ring = OutputRing::new(cap);
            let mut model = Vec::new();
            for push in &pushes {
                ring.push(push);
                model.extend_from_slice(push);
            }
            let head = model.len() as u64;
            let oldest = head.saturating_sub(cap as u64);
            prop_assert_eq!(ring.head(), Seq::new(head));
            prop_assert_eq!(ring.oldest(), Seq::new(oldest));
            prop_assert_eq!(ring.len() as u64, head - oldest);

            for (at, max) in probes {
                let at = at % (head + 2);
                match ring.read_at_most(Seq::new(at), max) {
                    Ok(chunk) => {
                        prop_assert!(at >= oldest && at <= head);
                        let end = (at as usize + max).min(model.len());
                        prop_assert_eq!(&chunk.data[..], &model[at as usize..end]);
                        prop_assert_eq!(chunk.seq, Seq::new(at));
                    }
                    Err(ReadError::Evicted { requested, oldest: reported_oldest }) => {
                        prop_assert!(at < oldest);
                        prop_assert_eq!(requested, Seq::new(at));
                        prop_assert_eq!(reported_oldest, Seq::new(oldest));
                    }
                    Err(ReadError::Ahead { head: reported_head, .. }) => {
                        prop_assert!(at > head);
                        prop_assert_eq!(reported_head, Seq::new(head));
                    }
                }
            }
        }

        /// Reading in arbitrary-sized steps from `oldest` reassembles the retained suffix.
        #[test]
        fn stepwise_reads_reassemble_suffix(
            cap in 1usize..64,
            data in prop::collection::vec(any::<u8>(), 0..300),
            step in 1usize..17,
        ) {
            let mut ring = OutputRing::new(cap);
            for piece in data.chunks(7) {
                ring.push(piece);
            }
            let mut at = ring.oldest();
            let mut reassembled = Vec::new();
            loop {
                let chunk = ring.read_at_most(at, step).unwrap();
                if chunk.data.is_empty() {
                    break;
                }
                reassembled.extend_from_slice(&chunk.data);
                at = chunk.end();
            }
            prop_assert_eq!(&reassembled[..], &data[data.len().saturating_sub(cap)..]);
        }
    }
}
