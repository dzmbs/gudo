#[cfg(test)]
mod tests;

const MAX_HEADER: usize = 16 * 1024;
const MAX_MESSAGE: usize = 64 * 1024;

struct Frame {
    consumed: usize,
    final_frame: bool,
    opcode: u8,
    payload: Vec<u8>,
}

pub(super) struct Decoder {
    buffer: Vec<u8>,
    message: Vec<u8>,
    handshake: bool,
    fragmented: bool,
    masked: bool,
}

impl Decoder {
    pub fn new(masked: bool) -> Self {
        Self {
            buffer: Vec::new(),
            message: Vec::new(),
            handshake: true,
            fragmented: false,
            masked,
        }
    }

    pub fn feed(&mut self, bytes: &[u8], mut emit: impl FnMut(&str)) -> Result<(), ()> {
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
            if !header.starts_with(if self.masked { "GET " } else { "HTTP/1.1 101 " }) {
                return Err(());
            }
            self.buffer.drain(..end + 4);
            self.handshake = false;
        }
        while let Some(Frame {
            consumed,
            final_frame,
            opcode,
            payload,
        }) = self.frame()?
        {
            self.buffer.drain(..consumed);
            match opcode {
                1 if !self.fragmented => {
                    self.message = payload;
                    self.fragmented = !final_frame;
                }
                0 if self.fragmented => {
                    self.message.extend(payload);
                    self.fragmented = !final_frame;
                }
                8..=10 => continue,
                _ => return Err(()),
            }
            if self.message.len() > MAX_MESSAGE {
                return Err(());
            }
            if final_frame {
                emit(std::str::from_utf8(&self.message).map_err(|_| ())?);
                self.message.clear();
            }
        }
        Ok(())
    }

    fn frame(&self) -> Result<Option<Frame>, ()> {
        if self.buffer.len() < 2 {
            return Ok(None);
        }
        let first = self.buffer[0];
        let second = self.buffer[1];
        if first & 0x70 != 0 || (second & 128 != 0) != self.masked {
            return Err(());
        }
        let opcode = first & 15;
        let final_frame = first & 128 != 0;
        let (length, offset) = match second & 127 {
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
                (u64::from_be_bytes(bytes.try_into().map_err(|_| ())?), 10)
            }
            length => (u64::from(length), 2),
        };
        if length > MAX_MESSAGE as u64 || (opcode >= 8 && (!final_frame || length > 125)) {
            return Err(());
        }
        let payload_start = offset + if self.masked { 4 } else { 0 };
        let end = payload_start + length as usize;
        if self.buffer.len() < end {
            return Ok(None);
        }
        let mut payload = self.buffer[payload_start..end].to_vec();
        if self.masked {
            for (index, byte) in payload.iter_mut().enumerate() {
                *byte ^= self.buffer[offset + index % 4];
            }
        }
        Ok(Some(Frame {
            consumed: end,
            final_frame,
            opcode,
            payload,
        }))
    }
}
