//! How refused joins reach the audit log.
//!
//! Anyone who knows the daemon id can connect with a fresh key and a made-up grant, so each
//! device's refusals are recorded at most once a minute, and all of them together in a small
//! burst and then one every few seconds; the rest are counted into the next record.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use proto::DeviceId;

/// One device's refusals are audited at most this often.
const PER_DEVICE_EVERY: Duration = Duration::from_secs(60);
/// Refusals audited at once across all devices ...
const BURST: f64 = 20.0;
/// ... and then one per this long.
const EVERY: Duration = Duration::from_secs(3);
const MAX_DEVICES: usize = 4096;

#[derive(Debug)]
pub(crate) struct JoinDenials {
    tokens: f64,
    refilled_at: Option<Instant>,
    audited: HashMap<DeviceId, Instant>,
    left_out: u64,
}

impl Default for JoinDenials {
    fn default() -> Self {
        Self {
            tokens: BURST,
            refilled_at: None,
            audited: HashMap::new(),
            left_out: 0,
        }
    }
}

impl JoinDenials {
    /// Whether a refusal of `device` goes to the audit log now, and if so how many refusals
    /// before it were left out.
    pub fn audit(&mut self, device: DeviceId, now: Instant) -> Option<u64> {
        let refill = self.refilled_at.map_or(0.0, |at| {
            now.duration_since(at).as_secs_f64() / EVERY.as_secs_f64()
        });
        self.tokens = (self.tokens + refill).min(BURST);
        self.refilled_at = Some(now);
        let recently = self
            .audited
            .get(&device)
            .is_some_and(|&at| now.duration_since(at) < PER_DEVICE_EVERY);
        if recently || self.tokens < 1.0 {
            self.left_out += 1;
            return None;
        }
        self.tokens -= 1.0;
        if self.audited.len() >= MAX_DEVICES {
            self.audited
                .retain(|_, &mut at| now.duration_since(at) < PER_DEVICE_EVERY);
            if self.audited.len() >= MAX_DEVICES {
                self.audited.clear();
            }
        }
        self.audited.insert(device, now);
        Some(std::mem::take(&mut self.left_out))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeated_refusals_are_counted_not_written() {
        let mut denials = JoinDenials::default();
        let start = Instant::now();
        let device = DeviceId([1; 32]);
        assert_eq!(denials.audit(device, start), Some(0));
        for _ in 0..5 {
            assert_eq!(denials.audit(device, start), None);
        }
        assert_eq!(denials.audit(device, start + PER_DEVICE_EVERY), Some(5));

        // Fresh keys share one budget.
        let mut denials = JoinDenials::default();
        let written = (0..100u8)
            .filter(|&index| denials.audit(DeviceId([index; 32]), start).is_some())
            .count();
        assert_eq!(written, BURST as usize);
        assert_eq!(denials.audit(DeviceId([200; 32]), start + EVERY), Some(80));
    }
}
