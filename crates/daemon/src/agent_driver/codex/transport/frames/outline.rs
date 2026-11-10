//! The shape of a server message too large to observe: its JSON with every array emptied and
//! every long string blanked, so the turn a skipped message starts or ends can still be read.

const MAX_STRING: usize = 1024;
const MAX_OUTLINE: usize = 64 * 1024;

#[derive(Default)]
pub(super) struct Outline {
    text: Vec<u8>,
    string: Vec<u8>,
    in_string: bool,
    escaped: bool,
    is_long_string: bool,
    /// Brackets open inside the outermost array being emptied.
    array_depth: usize,
    overflowed: bool,
}

impl Outline {
    pub fn feed(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            if self.overflowed {
                return;
            }
            self.feed_byte(byte);
        }
    }

    /// The outline, unless the message was no complete JSON or its outline is too large.
    pub fn finish(self) -> Option<String> {
        if self.overflowed || self.in_string || self.array_depth > 0 {
            return None;
        }
        String::from_utf8(self.text).ok()
    }

    fn feed_byte(&mut self, byte: u8) {
        if self.in_string {
            if self.escaped {
                self.escaped = false;
            } else if byte == b'\\' {
                self.escaped = true;
            } else if byte == b'"' {
                self.in_string = false;
                if self.array_depth == 0 {
                    self.end_string();
                }
                return;
            }
            if self.array_depth == 0 {
                if self.string.len() < MAX_STRING {
                    self.string.push(byte);
                } else {
                    self.is_long_string = true;
                }
            }
            return;
        }
        match byte {
            b'"' => {
                self.in_string = true;
                self.is_long_string = false;
                self.string.clear();
            }
            b'[' | b'{' if self.array_depth > 0 => self.array_depth += 1,
            b']' | b'}' if self.array_depth > 0 => {
                self.array_depth -= 1;
                if self.array_depth == 0 {
                    self.push(b"[]");
                }
            }
            _ if self.array_depth > 0 => {}
            b'[' => self.array_depth = 1,
            byte if byte.is_ascii_whitespace() => {}
            byte => self.push(&[byte]),
        }
    }

    fn end_string(&mut self) {
        let string = std::mem::take(&mut self.string);
        self.push(b"\"");
        if !self.is_long_string {
            self.push(&string);
        }
        self.push(b"\"");
        self.string = string;
    }

    fn push(&mut self, bytes: &[u8]) {
        if self.text.len() + bytes.len() > MAX_OUTLINE {
            self.overflowed = true;
            self.text = Vec::new();
            return;
        }
        self.text.extend_from_slice(bytes);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn outline(message: &str, chunk: usize) -> Option<String> {
        let mut outline = Outline::default();
        for part in message.as_bytes().chunks(chunk) {
            outline.feed(part);
        }
        outline.finish()
    }

    #[test]
    fn arrays_are_emptied_and_long_strings_blanked() {
        let long = "y".repeat(MAX_STRING + 1);
        let message = format!(
            r#"{{"method": "turn/completed", "params": {{"threadId": "a \"quoted\" id",
            "turn": {{"id": "turn", "items": [{{"text": "]}}["}}, [1, [2]]],
            "status": "completed", "error": {{"message": "{long}"}}}}}}}}"#
        );
        let expected = r#"{"method":"turn/completed","params":{"threadId":"a \"quoted\" id","turn":{"id":"turn","items":[],"status":"completed","error":{"message":""}}}}"#;
        for chunk in [1, 7, message.len()] {
            assert_eq!(outline(&message, chunk).as_deref(), Some(expected));
        }
    }

    #[test]
    fn an_outline_too_large_or_incomplete_is_none() {
        let wide = format!(
            "{{{}\"end\":0}}",
            r#""key":"value","#.repeat(MAX_OUTLINE / 10)
        );
        assert_eq!(outline(&wide, 4096), None);
        assert_eq!(
            outline(r#"{"method":"turn/completed","params":["#, 4096),
            None
        );
        assert_eq!(outline(r#"{"method":"turn/comp"#, 4096), None);
    }
}
