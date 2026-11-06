//! Input not yet acknowledged, sent again after a reconnect (`Caps::INPUT_RESUME`).
//!
//! Keystrokes written to a connection that then dies (a frozen host, a dead network) are gone
//! with it. With a daemon that offers `DaemonFeatures::INPUT_RESUME`, input keeps its number
//! across connections and is kept here until an `InputAck` or `InputRejected` at or past it
//! arrives; a reconnect to the same daemon run sends it again, and the daemon applies each
//! number once.

use std::collections::VecDeque;

use proto::{InputPayload, PaneId};

/// Input kept at most; past it the oldest goes (it could then be lost, never doubled).
const MAX_BYTES: usize = 4 << 20;
const MAX_ENTRIES: usize = 8192;

/// An input kept with its original provenance for reconnects.
#[derive(Debug, Clone)]
pub(crate) struct Sent {
    pub seq: u64,
    pub pane_id: PaneId,
    pub payload: InputPayload,
    len: usize,
}

/// This client's input numbering and what of it is unacknowledged.
#[derive(Debug, Default)]
pub(crate) struct InputLog {
    last_seq: u64,
    unacked: VecDeque<Sent>,
    bytes: usize,
}

fn payload_len(payload: &InputPayload) -> usize {
    match payload {
        InputPayload::Bytes(bytes) | InputPayload::GeneratedBytes(bytes) => bytes.len(),
        InputPayload::Paste(text) => text.len(),
        _ => 64,
    }
}

impl InputLog {
    /// Numbers `payload`; keeps it for resending when `keep`.
    pub fn send(&mut self, pane_id: PaneId, payload: &InputPayload, keep: bool) -> u64 {
        self.last_seq += 1;
        if keep {
            let len = payload_len(payload);
            self.unacked.push_back(Sent {
                seq: self.last_seq,
                pane_id,
                payload: payload.clone(),
                len,
            });
            self.bytes += len;
            while self.bytes > MAX_BYTES || self.unacked.len() > MAX_ENTRIES {
                let Some(oldest) = self.unacked.pop_front() else {
                    break;
                };
                self.bytes -= oldest.len;
            }
        }
        self.last_seq
    }

    /// The daemon has handled everything up to `seq` (input is handled in order).
    pub fn confirm(&mut self, seq: u64) {
        while self.unacked.front().is_some_and(|sent| sent.seq <= seq) {
            let done = self.unacked.pop_front().expect("checked");
            self.bytes -= done.len;
        }
    }

    /// What to send again on a new connection: everything kept, if the daemon is the same
    /// run and applies input once; otherwise nothing, and the rest is dropped.
    pub fn resend(&mut self, same_run: bool) -> Vec<Sent> {
        if same_run {
            self.unacked.iter().cloned().collect()
        } else {
            self.unacked.clear();
            self.bytes = 0;
            Vec::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(byte: u8) -> InputPayload {
        InputPayload::Bytes(vec![byte])
    }

    #[test]
    fn unacknowledged_input_is_sent_again_in_order() {
        let mut log = InputLog::default();
        for byte in 1..=5 {
            log.send(PaneId(1), &key(byte), true);
        }
        log.confirm(2);
        let again: Vec<u64> = log.resend(true).iter().map(|sent| sent.seq).collect();
        assert_eq!(again, [3, 4, 5]);
        assert_eq!(log.send(PaneId(1), &key(6), true), 6, "numbering goes on");
        assert!(log.resend(false).is_empty(), "never to another daemon run");
        assert!(log.resend(true).is_empty());
    }

    #[test]
    fn reconnects_preserve_generated_input_provenance_and_sequence() {
        let mut log = InputLog::default();
        let payload = InputPayload::GeneratedBytes(b"report".to_vec());
        let sequence = log.send(PaneId(1), &payload, true);
        let replay = log.resend(true);
        assert_eq!(replay.len(), 1);
        assert_eq!(replay[0].seq, sequence);
        assert_eq!(replay[0].payload, payload);
        log.confirm(sequence);
        assert!(log.resend(true).is_empty());
    }

    #[test]
    fn the_log_is_bounded_for_raw_and_generated_bytes() {
        for piece in [
            InputPayload::Bytes(vec![0; 1 << 20]),
            InputPayload::GeneratedBytes(vec![0; 1 << 20]),
        ] {
            let mut log = InputLog::default();
            for _ in 0..10 {
                log.send(PaneId(1), &piece, true);
            }
            assert!(log.bytes <= MAX_BYTES);
            assert_eq!(log.resend(true).first().map(|sent| sent.seq), Some(7));
        }
    }
}
