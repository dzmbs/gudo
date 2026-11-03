//! Input applied exactly once across reconnects (`Caps::INPUT_RESUME`).
//!
//! A client keeps numbering its input over all its connections and, after reconnecting, sends
//! again what it has no acknowledgement for: keystrokes written to a link that died were
//! otherwise lost. The `Welcome`'s resume token names the client's input stream; the daemon
//! remembers the highest number it applied per device and stream and drops anything at or
//! below it, so nothing is applied twice either.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use proto::{DeviceId, ResumeToken, SessionEpoch};

use crate::core::lock;

/// Streams remembered; past this, ones unused for [`IDLE`] go, then the least recently used.
const MAX_STREAMS: usize = 4096;
/// A stream unused this long is forgotten first (its client is long gone or has resumed).
const IDLE: Duration = Duration::from_secs(30 * 60);

/// The highest input number applied, per device and input stream.
#[derive(Default)]
pub(crate) struct InputStreams {
    applied: Mutex<HashMap<(DeviceId, u64), (u64, Instant)>>,
}

impl InputStreams {
    /// The stream a connection continues: the one its token names if the token is from this
    /// run of the daemon, else a new one.
    pub fn stream(&self, epoch: SessionEpoch, token: Option<&ResumeToken>) -> u64 {
        token
            .and_then(|token| {
                let (run, stream) = token.0.split_at_checked(8)?;
                (run == epoch.0.to_le_bytes() && stream.len() == 8)
                    .then(|| u64::from_le_bytes(stream.try_into().expect("8 bytes")))
            })
            .unwrap_or_else(|| u64::from_le_bytes(crate::fsutil::random::<8>()))
    }

    pub fn token(epoch: SessionEpoch, stream: u64) -> ResumeToken {
        let mut bytes = epoch.0.to_le_bytes().to_vec();
        bytes.extend_from_slice(&stream.to_le_bytes());
        ResumeToken(bytes)
    }

    /// The highest number applied per device and stream, for the next daemon build.
    pub fn applied(&self) -> Vec<(DeviceId, u64, u64)> {
        lock(&self.applied)
            .iter()
            .map(|(&(device, stream), &(last, _))| (device, stream, last))
            .collect()
    }

    /// Continues what the previous daemon build applied ([`applied`](Self::applied)).
    pub fn carry_on(&self, applied: Vec<(DeviceId, u64, u64)>) {
        let now = Instant::now();
        let mut streams = lock(&self.applied);
        for (device, stream, last) in applied.into_iter().take(MAX_STREAMS) {
            streams.insert((device, stream), (last, now));
        }
    }

    /// Whether input `seq` of `device`'s `stream` is new; if so it counts as applied.
    pub fn admit(&self, device: DeviceId, stream: u64, seq: u64) -> bool {
        let mut applied = lock(&self.applied);
        let now = Instant::now();
        if let Some((last, used)) = applied.get_mut(&(device, stream)) {
            *used = now;
            if seq <= *last {
                return false;
            }
            *last = seq;
            return true;
        }
        if applied.len() >= MAX_STREAMS {
            applied.retain(|_, (_, used)| now.duration_since(*used) < IDLE);
            if applied.len() >= MAX_STREAMS
                && let Some(oldest) = applied
                    .iter()
                    .min_by_key(|(_, (_, used))| *used)
                    .map(|(key, _)| *key)
            {
                applied.remove(&oldest);
            }
        }
        applied.insert((device, stream), (seq, now));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EPOCH: SessionEpoch = SessionEpoch(7);

    #[test]
    fn a_token_from_this_run_continues_its_stream() {
        let streams = InputStreams::default();
        let stream = streams.stream(EPOCH, None);
        let token = InputStreams::token(EPOCH, stream);
        assert_eq!(streams.stream(EPOCH, Some(&token)), stream);
        assert_ne!(
            streams.stream(SessionEpoch(8), Some(&token)),
            stream,
            "another run starts afresh"
        );
        let epoch_only = ResumeToken(EPOCH.0.to_le_bytes().to_vec());
        assert_ne!(streams.stream(EPOCH, Some(&epoch_only)), stream);
    }

    #[test]
    fn input_resent_after_a_reconnect_is_applied_once() {
        let streams = InputStreams::default();
        let (me, other) = (DeviceId([1; 32]), DeviceId([2; 32]));
        assert!((1..=5).all(|n| streams.admit(me, 9, n)));
        // The link died after 5 arrived; the client sends 3..=7 again on the new one.
        let applied: Vec<u64> = (3..=7).filter(|&n| streams.admit(me, 9, n)).collect();
        assert_eq!(applied, [6, 7]);
        assert!(streams.admit(other, 9, 1), "streams are per device");
        assert!(streams.admit(me, 10, 1), "and per stream");
    }

    #[test]
    fn streams_are_bounded() {
        let streams = InputStreams::default();
        for stream in 0..(MAX_STREAMS as u64 + 100) {
            streams.admit(DeviceId([3; 32]), stream, 1);
        }
        assert!(lock(&streams.applied).len() <= MAX_STREAMS);
    }
}
