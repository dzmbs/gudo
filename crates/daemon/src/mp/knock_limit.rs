//! How many knocks one invite may bring to the owners, and how its refusals are audited.
//!
//! A knock link can leak; anyone holding it can knock from fresh keys as fast as the pre-auth
//! gate lets them connect. Each invite gets a small burst and then one knock every few seconds,
//! and refusals go to the audit log at most once a minute with the number left out, so neither
//! the owners' screens nor the audit file grow with the flood.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use proto::GrantId;

/// Knocks an invite may bring at once ...
const BURST: f64 = 8.0;
/// ... and then one per this long.
const EVERY: Duration = Duration::from_secs(10);
/// Refusals of one invite are audited at most this often.
const AUDIT_EVERY: Duration = Duration::from_secs(60);
const MAX_INVITES: usize = 1024;

#[derive(Debug)]
struct Limit {
    tokens: f64,
    refilled_at: Instant,
    audited_at: Option<Instant>,
    /// Refusals since the last audited one.
    unaudited: u64,
}

/// What to do with a refusal.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Refusal {
    /// Audit it, mentioning this many earlier refusals that were not.
    Audit { left_out: u64 },
    /// Count it for the next audited one.
    Quiet,
}

#[derive(Debug, Default)]
pub(crate) struct KnockLimits {
    invites: HashMap<GrantId, Limit>,
}

impl KnockLimits {
    fn limit(&mut self, invite: GrantId, now: Instant) -> &mut Limit {
        if self.invites.len() >= MAX_INVITES && !self.invites.contains_key(&invite) {
            self.invites.retain(|_, limit| {
                now.duration_since(limit.refilled_at) < AUDIT_EVERY.max(EVERY.mul_f64(BURST))
            });
        }
        self.invites.entry(invite).or_insert(Limit {
            tokens: BURST,
            refilled_at: now,
            audited_at: None,
            unaudited: 0,
        })
    }

    /// Takes a knock from `invite`'s budget; false if it has none left.
    pub fn admit(&mut self, invite: GrantId, now: Instant) -> bool {
        let limit = self.limit(invite, now);
        let refill = now.duration_since(limit.refilled_at).as_secs_f64() / EVERY.as_secs_f64();
        limit.tokens = (limit.tokens + refill).min(BURST);
        limit.refilled_at = now;
        if limit.tokens < 1.0 {
            return false;
        }
        limit.tokens -= 1.0;
        true
    }

    /// Whether a refusal of `invite`'s knock goes to the audit log now.
    pub fn refused(&mut self, invite: GrantId, now: Instant) -> Refusal {
        let limit = self.limit(invite, now);
        if limit
            .audited_at
            .is_some_and(|audited_at| now.duration_since(audited_at) < AUDIT_EVERY)
        {
            limit.unaudited += 1;
            return Refusal::Quiet;
        }
        limit.audited_at = Some(now);
        Refusal::Audit {
            left_out: std::mem::take(&mut limit.unaudited),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_flood_of_knocks_is_cut_to_a_trickle() {
        let mut limits = KnockLimits::default();
        let invite = GrantId([1; 16]);
        let t0 = Instant::now();
        let admitted = (0..1000).filter(|_| limits.admit(invite, t0)).count();
        assert_eq!(admitted, 8);
        assert!(limits.admit(invite, t0 + EVERY), "one more every 10 s");
        assert!(
            limits.admit(GrantId([2; 16]), t0),
            "each invite has its own budget"
        );
    }

    #[test]
    fn refusals_are_audited_once_a_minute_with_a_count() {
        let mut limits = KnockLimits::default();
        let invite = GrantId([1; 16]);
        let t0 = Instant::now();
        assert_eq!(limits.refused(invite, t0), Refusal::Audit { left_out: 0 });
        for i in 1..=500 {
            assert_eq!(
                limits.refused(invite, t0 + Duration::from_millis(i)),
                Refusal::Quiet
            );
        }
        assert_eq!(
            limits.refused(invite, t0 + AUDIT_EVERY),
            Refusal::Audit { left_out: 500 }
        );
    }
}
