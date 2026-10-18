//! Length-prefixed, versioned framing.
//!
//! A frame is `[u32 LE body length][body]`. The body is the postcard encoding of
//! `(WIRE_VERSION as u16, message)`: a varint version (one byte while it is below 128) and then
//! the message. A decoder rejects a body whose version it does not speak, a length above its
//! limit (before allocating), and trailing bytes after the message.
//!
//! The helpers are transport-agnostic: [`encode`] / [`decode_body`] work on buffers,
//! [`write_frame`] / [`read_frame`] on blocking `std::io`, and [`FrameDecoder`] turns any chunked
//! byte source (a QUIC stream read loop, for example) into messages without an async runtime.
//!
//! # Examples
//!
//! ```
//! use proto::frame::{self, FrameDecoder};
//! use proto::{ClientCtl, MAX_FRAME_LEN};
//!
//! let mut wire = Vec::new();
//! frame::encode(&ClientCtl::Ping { nonce: 7 }, &mut wire)?;
//! frame::encode(&ClientCtl::Ping { nonce: 8 }, &mut wire)?;
//!
//! let mut decoder = FrameDecoder::new(MAX_FRAME_LEN);
//! // Bytes may arrive in arbitrary chunks.
//! decoder.extend(&wire[..3]);
//! assert_eq!(decoder.decode::<ClientCtl>()?, None);
//! decoder.extend(&wire[3..]);
//! assert_eq!(decoder.decode::<ClientCtl>()?, Some(ClientCtl::Ping { nonce: 7 }));
//! assert_eq!(decoder.decode::<ClientCtl>()?, Some(ClientCtl::Ping { nonce: 8 }));
//! assert_eq!(decoder.decode::<ClientCtl>()?, None);
//! # Ok::<(), proto::FrameError>(())
//! ```

use std::error::Error;
use std::fmt;
use std::io::{self, Read, Write};

use postcard::ser_flavors::Flavor;
use serde::Serialize;
use serde::de::DeserializeOwned;

/// Version written at the start of every frame body.
///
/// Bumped when any message's shape changes incompatibly. Appending an enum variant does not
/// need a bump: old peers fail to decode only the new variant, which a capability gates.
pub const WIRE_VERSION: u16 = 1;

/// Size of the length prefix in bytes.
pub const LEN_PREFIX: usize = 4;

/// Default upper bound on a frame body. A snapshot's READY section is expected well below
/// 1 MiB; larger payloads are chunked on `bulk`.
pub const MAX_FRAME_LEN: usize = 4 * 1024 * 1024;

/// Errors from encoding or decoding a frame.
#[derive(Debug)]
pub enum FrameError {
    /// The length prefix announces a body larger than the decoder's limit.
    Oversized {
        /// Announced (or, when encoding, actual) body length.
        len: usize,
        /// The limit.
        max: usize,
    },
    /// The body's version is not [`WIRE_VERSION`].
    UnsupportedVersion(u16),
    /// The body is not a valid encoding of the expected message.
    Decode(postcard::Error),
    /// Bytes were left over after the message.
    TrailingBytes(usize),
    /// The underlying reader or writer failed (`read_frame` / `write_frame` only).
    Io(io::Error),
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Oversized { len, max } => write!(f, "frame of {len} bytes exceeds limit {max}"),
            Self::UnsupportedVersion(v) => {
                write!(f, "unsupported wire version {v} (speak {WIRE_VERSION})")
            }
            Self::Decode(e) => write!(f, "malformed frame body: {e}"),
            Self::TrailingBytes(n) => write!(f, "{n} trailing bytes after message"),
            Self::Io(e) => write!(f, "frame i/o: {e}"),
        }
    }
}

impl Error for FrameError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Decode(e) => Some(e),
            Self::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<postcard::Error> for FrameError {
    fn from(e: postcard::Error) -> Self {
        Self::Decode(e)
    }
}

impl From<io::Error> for FrameError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}

/// Appends postcard output to a borrowed `Vec`, so frames encode in place with no extra copy.
struct AppendVec<'a>(&'a mut Vec<u8>);

impl Flavor for AppendVec<'_> {
    type Output = ();

    fn try_extend(&mut self, data: &[u8]) -> postcard::Result<()> {
        self.0.extend_from_slice(data);
        Ok(())
    }

    fn try_push(&mut self, data: u8) -> postcard::Result<()> {
        self.0.push(data);
        Ok(())
    }

    fn finalize(self) -> postcard::Result<()> {
        Ok(())
    }
}

/// Appends one complete frame (prefix and body) for `msg` to `out`.
///
/// # Errors
///
/// Returns [`FrameError::Oversized`] if the body exceeds [`MAX_FRAME_LEN`], or
/// [`FrameError::Decode`] if serialization fails. On error `out` is left as it was.
pub fn encode<T: Serialize>(msg: &T, out: &mut Vec<u8>) -> Result<(), FrameError> {
    let start = out.len();
    out.extend_from_slice(&[0; LEN_PREFIX]);
    if let Err(e) = postcard::serialize_with_flavor(&(WIRE_VERSION, msg), AppendVec(out)) {
        out.truncate(start);
        return Err(e.into());
    }
    let len = out.len() - start - LEN_PREFIX;
    if len > MAX_FRAME_LEN {
        out.truncate(start);
        return Err(FrameError::Oversized {
            len,
            max: MAX_FRAME_LEN,
        });
    }
    // Cannot truncate: `len <= MAX_FRAME_LEN < u32::MAX`.
    let prefix = (len as u32).to_le_bytes();
    out[start..start + LEN_PREFIX].copy_from_slice(&prefix);
    Ok(())
}

/// Returns the encoded frame for `msg` as a new buffer.
///
/// # Errors
///
/// As for [`encode`].
pub fn to_vec<T: Serialize>(msg: &T) -> Result<Vec<u8>, FrameError> {
    let mut out = Vec::new();
    encode(msg, &mut out)?;
    Ok(out)
}

/// Parses a length prefix, checking it against `max` before anything is allocated.
///
/// # Errors
///
/// Returns [`FrameError::Oversized`] if the announced length exceeds `max`.
pub fn body_len(prefix: [u8; LEN_PREFIX], max: usize) -> Result<usize, FrameError> {
    let len = u32::from_le_bytes(prefix) as usize;
    if len > max {
        return Err(FrameError::Oversized { len, max });
    }
    Ok(len)
}

/// Decodes a frame body (everything after the length prefix).
///
/// # Errors
///
/// Returns [`FrameError::UnsupportedVersion`] for a foreign version, [`FrameError::Decode`] for
/// a malformed message and [`FrameError::TrailingBytes`] if the body is longer than the message.
pub fn decode_body<T: DeserializeOwned>(body: &[u8]) -> Result<T, FrameError> {
    let (version, rest) = postcard::take_from_bytes::<u16>(body)?;
    if version != WIRE_VERSION {
        return Err(FrameError::UnsupportedVersion(version));
    }
    let (msg, rest) = postcard::take_from_bytes::<T>(rest)?;
    if !rest.is_empty() {
        return Err(FrameError::TrailingBytes(rest.len()));
    }
    Ok(msg)
}

/// Writes one frame to a blocking writer.
///
/// # Errors
///
/// As for [`encode`], plus [`FrameError::Io`] if the write fails.
pub fn write_frame<W: Write, T: Serialize>(writer: &mut W, msg: &T) -> Result<(), FrameError> {
    let buf = to_vec(msg)?;
    writer.write_all(&buf)?;
    Ok(())
}

/// Reads one frame from a blocking reader.
///
/// # Errors
///
/// As for [`body_len`] and [`decode_body`], plus [`FrameError::Io`] if the read fails (an
/// `UnexpectedEof` at a frame boundary means the peer closed the stream).
pub fn read_frame<R: Read, T: DeserializeOwned>(
    reader: &mut R,
    max: usize,
) -> Result<T, FrameError> {
    let mut prefix = [0; LEN_PREFIX];
    reader.read_exact(&mut prefix)?;
    let mut body = vec![0; body_len(prefix, max)?];
    reader.read_exact(&mut body)?;
    decode_body(&body)
}

/// Incremental decoder for frames arriving in arbitrary chunks.
///
/// Feed bytes with [`extend`](Self::extend) and pull messages with
/// [`decode`](Self::decode) until it returns `Ok(None)`. See the [module docs](self) for an
/// example.
#[derive(Debug)]
pub struct FrameDecoder {
    buf: Vec<u8>,
    /// Start of unconsumed data in `buf`. Consumed bytes are dropped lazily so decoding many
    /// small frames from one chunk does not shift the buffer once per frame.
    pos: usize,
    max: usize,
}

impl FrameDecoder {
    /// Creates a decoder that rejects bodies longer than `max` bytes.
    pub fn new(max: usize) -> Self {
        Self {
            buf: Vec::new(),
            pos: 0,
            max,
        }
    }

    /// Appends received bytes.
    pub fn extend(&mut self, data: &[u8]) {
        if self.pos > 0 && self.pos * 2 >= self.buf.len() {
            self.buf.drain(..self.pos);
            self.pos = 0;
        }
        self.buf.extend_from_slice(data);
    }

    /// Number of buffered bytes not yet decoded.
    pub fn buffered(&self) -> usize {
        self.buf.len() - self.pos
    }

    /// Returns the body of the next complete frame without decoding it, or `None` if more
    /// bytes are needed.
    ///
    /// # Errors
    ///
    /// Returns [`FrameError::Oversized`] if the next frame announces a body over the limit. The
    /// stream cannot be resynchronised after that; close it.
    pub fn next_body(&mut self) -> Result<Option<&[u8]>, FrameError> {
        let pending = &self.buf[self.pos..];
        let Some(prefix) = pending.first_chunk::<LEN_PREFIX>() else {
            return Ok(None);
        };
        let len = body_len(*prefix, self.max)?;
        if pending.len() < LEN_PREFIX + len {
            return Ok(None);
        }
        let body_start = self.pos + LEN_PREFIX;
        self.pos = body_start + len;
        Ok(Some(&self.buf[body_start..self.pos]))
    }

    /// Decodes the next complete frame, or returns `None` if more bytes are needed.
    ///
    /// # Errors
    ///
    /// As for [`next_body`](Self::next_body) and [`decode_body`]. A frame that fails to decode
    /// is consumed.
    pub fn decode<T: DeserializeOwned>(&mut self) -> Result<Option<T>, FrameError> {
        match self.next_body()? {
            Some(body) => decode_body(body).map(Some),
            None => Ok(None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ClientCtl;

    #[test]
    fn oversized_prefix_is_rejected_before_allocating() {
        let mut d = FrameDecoder::new(16);
        d.extend(&17u32.to_le_bytes());
        assert!(matches!(
            d.next_body(),
            Err(FrameError::Oversized { len: 17, max: 16 })
        ));
    }

    #[test]
    fn foreign_version_is_rejected() {
        let mut wire = to_vec(&ClientCtl::Ping { nonce: 1 }).unwrap();
        wire[LEN_PREFIX] = 2;
        let err = decode_body::<ClientCtl>(&wire[LEN_PREFIX..]).unwrap_err();
        assert!(matches!(err, FrameError::UnsupportedVersion(2)));
    }

    #[test]
    fn trailing_bytes_are_rejected() {
        let wire = to_vec(&ClientCtl::Ping { nonce: 1 }).unwrap();
        let mut body = wire[LEN_PREFIX..].to_vec();
        body.push(0);
        assert!(matches!(
            decode_body::<ClientCtl>(&body),
            Err(FrameError::TrailingBytes(1))
        ));
    }

    #[test]
    fn byte_at_a_time_decoding() {
        let msgs: Vec<_> = (0..50).map(|nonce| ClientCtl::Ping { nonce }).collect();
        let mut wire = Vec::new();
        for m in &msgs {
            encode(m, &mut wire).unwrap();
        }
        let mut d = FrameDecoder::new(MAX_FRAME_LEN);
        let mut out = Vec::new();
        for b in &wire {
            d.extend(std::slice::from_ref(b));
            while let Some(m) = d.decode::<ClientCtl>().unwrap() {
                out.push(m);
            }
        }
        assert_eq!(out, msgs);
        assert_eq!(d.buffered(), 0);
    }

    #[test]
    fn io_round_trip() {
        let mut wire = Vec::new();
        write_frame(&mut wire, &ClientCtl::Ping { nonce: 9 }).unwrap();
        let back: ClientCtl = read_frame(&mut wire.as_slice(), MAX_FRAME_LEN).unwrap();
        assert_eq!(back, ClientCtl::Ping { nonce: 9 });
    }
}
