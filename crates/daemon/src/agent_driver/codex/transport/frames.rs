mod outline;
#[cfg(test)]
mod tests;

use outline::Outline;

const MAX_HEADER: usize = 16 * 1024;
const MAX_MESSAGE: usize = agents::CODEX_FRAME_LIMIT;
const MAX_CONTROL_PAYLOAD: u64 = 125;
const CONTINUATION: u8 = 0;
const TEXT: u8 = 1;
const FINAL_BIT: u8 = 0x80;
const RESERVED_BITS: u8 = 0x70;
const OPCODE_BITS: u8 = 0x0f;
const MASK_BIT: u8 = 0x80;
const LENGTH_BITS: u8 = 0x7f;
const MASK_BYTES: usize = 4;

/// Which side of the relay wrote the bytes, which fixes the handshake and masking rules.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::agent_driver::codex) enum Direction {
    FromTui,
    FromServer,
}

impl Direction {
    fn is_masked(self) -> bool {
        self == Self::FromTui
    }

    fn handshake(self) -> &'static str {
        match self {
            Self::FromTui => "GET ",
            Self::FromServer => "HTTP/1.1 101 ",
        }
    }
}

/// One complete message, or a message too large to observe whose body was dropped, with its
/// outline when the server sent it ([`Outline`]).
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Observed<'a> {
    Text(&'a str),
    Skipped(Option<&'a str>),
}

#[derive(Clone, Copy)]
struct Header {
    final_frame: bool,
    opcode: u8,
    length: u64,
    payload_start: usize,
}

pub(super) struct Decoder {
    direction: Direction,
    buffer: Vec<u8>,
    message: Vec<u8>,
    handshake: bool,
    fragmented: bool,
    skipping: bool,
    discard: u64,
    discard_final: bool,
    outline: Option<Outline>,
}

impl Decoder {
    pub fn new(direction: Direction) -> Self {
        Self {
            direction,
            buffer: Vec::new(),
            message: Vec::new(),
            handshake: true,
            fragmented: false,
            skipping: false,
            discard: 0,
            discard_final: false,
            outline: None,
        }
    }

    pub fn feed(&mut self, bytes: &[u8], mut emit: impl FnMut(Observed<'_>)) -> Result<(), ()> {
        self.buffer.extend_from_slice(bytes);
        if self.handshake {
            let Some(end) = self.buffer.windows(4).position(|part| part == b"\r\n\r\n") else {
                return if self.buffer.len() <= MAX_HEADER {
                    Ok(())
                } else {
                    Err(())
                };
            };
            if end > MAX_HEADER {
                return Err(());
            }
            let header = std::str::from_utf8(&self.buffer[..end]).map_err(|_| ())?;
            if !header.starts_with(self.direction.handshake()) {
                return Err(());
            }
            self.buffer.drain(..end + 4);
            self.handshake = false;
        }
        loop {
            if self.discard > 0 {
                let dropped = usize::try_from(self.discard)
                    .unwrap_or(usize::MAX)
                    .min(self.buffer.len());
                if let Some(outline) = &mut self.outline {
                    outline.feed(&self.buffer[..dropped]);
                }
                self.buffer.drain(..dropped);
                self.discard -= dropped as u64;
                if self.discard > 0 {
                    return Ok(());
                }
                if self.discard_final {
                    self.end_skipping(&mut emit);
                }
                continue;
            }
            let Some(header) = self.header()? else {
                return Ok(());
            };
            match header.opcode {
                8..=10 => {
                    let Some(end) = self.payload_end(&header) else {
                        return Ok(());
                    };
                    self.buffer.drain(..end);
                    continue;
                }
                TEXT if !self.fragmented => {}
                CONTINUATION if self.fragmented => {}
                _ => return Err(()),
            }
            let fits = self
                .message
                .len()
                .checked_add(usize::try_from(header.length).unwrap_or(usize::MAX))
                .is_some_and(|total| total <= MAX_MESSAGE);
            if self.skipping || !fits {
                if !self.skipping && self.direction == Direction::FromServer {
                    let mut outline = Outline::default();
                    outline.feed(&self.message);
                    self.outline = Some(outline);
                }
                self.fragmented = !header.final_frame;
                self.skipping = true;
                self.message = Vec::new();
                self.buffer.drain(..header.payload_start);
                self.discard = header.length;
                self.discard_final = header.final_frame;
                if self.discard == 0 && header.final_frame {
                    self.end_skipping(&mut emit);
                }
                continue;
            }
            let Some(end) = self.payload_end(&header) else {
                return Ok(());
            };
            self.fragmented = !header.final_frame;
            let start = self.message.len();
            self.message
                .extend_from_slice(&self.buffer[header.payload_start..end]);
            if self.direction.is_masked() {
                let mask_start = header.payload_start - MASK_BYTES;
                for (index, byte) in self.message[start..].iter_mut().enumerate() {
                    *byte ^= self.buffer[mask_start + index % MASK_BYTES];
                }
            }
            self.buffer.drain(..end);
            if header.final_frame {
                let message = std::mem::take(&mut self.message);
                emit(Observed::Text(
                    std::str::from_utf8(&message).map_err(|_| ())?,
                ));
            }
        }
    }

    fn end_skipping(&mut self, emit: &mut impl FnMut(Observed<'_>)) {
        self.skipping = false;
        let outline = self.outline.take().and_then(Outline::finish);
        emit(Observed::Skipped(outline.as_deref()));
    }

    fn payload_end(&self, header: &Header) -> Option<usize> {
        let end = header
            .payload_start
            .checked_add(usize::try_from(header.length).ok()?)?;
        (self.buffer.len() >= end).then_some(end)
    }

    fn header(&self) -> Result<Option<Header>, ()> {
        let [first, second, ..] = self.buffer[..] else {
            return Ok(None);
        };
        if first & RESERVED_BITS != 0 || (second & MASK_BIT != 0) != self.direction.is_masked() {
            return Err(());
        }
        let opcode = first & OPCODE_BITS;
        let final_frame = first & FINAL_BIT != 0;
        let (length, offset) = match second & LENGTH_BITS {
            126 => {
                let Some(bytes) = self.buffer.get(2..4) else {
                    return Ok(None);
                };
                (u64::from(u16::from_be_bytes([bytes[0], bytes[1]])), 4)
            }
            127 => {
                let Some(bytes) = self.buffer.get(2..10) else {
                    return Ok(None);
                };
                let length = u64::from_be_bytes(bytes.try_into().map_err(|_| ())?);
                if length > i64::MAX as u64 {
                    return Err(());
                }
                (length, 10)
            }
            length => (u64::from(length), 2),
        };
        if opcode >= 8 && (!final_frame || length > MAX_CONTROL_PAYLOAD) {
            return Err(());
        }
        let payload_start = offset
            + if self.direction.is_masked() {
                MASK_BYTES
            } else {
                0
            };
        if self.buffer.len() < payload_start {
            return Ok(None);
        }
        Ok(Some(Header {
            final_frame,
            opcode,
            length,
            payload_start,
        }))
    }
}
