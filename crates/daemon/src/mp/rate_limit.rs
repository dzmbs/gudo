//! Token buckets for what guests can repeat at line rate, and how their refusals are audited.
//!
//! A knock link can leak, and anyone holding it can knock from fresh keys as fast as the
//! pre-auth gate lets them connect; a prompter can paste prompts into the owner's agent (and
//! its quota) as fast as it can send them. Each key gets a small burst and then one action
//! every so often, and refusals go to the audit log at most once a minute with the number left
//! out, so neither the owners' screens nor the audit file grow with the flood.

use std::collections::HashMap;
use std::hash::Hash;
use std::time::{Duration, Instant};

use proto::{GrantId, PrincipalId};

/// A burst, then one more per `every`.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Budget {
    pub burst: f64,
    pub every: Duration,
}

/// Knocks one invite may bring to the owners.
pub(crate) const KNOCKS: Budget = Budget {
    burst: 8.0,
    every: Duration::from_secs(10),
};

/// Prompts and review notes one guest may send: more than a person types, far less than a
/// script.
pub(crate) const PROMPTS: Budget = Budget {
    burst: 5.0,
    every: Duration::from_secs(2),
};

/// Joins and leaves one guest device may put in the audit log before they are counted.
pub(crate) const VISITS: Budget = Budget {
    burst: 10.0,
    every: Duration::from_secs(60),
};

/// Refusals of one key are audited at most this often.
const AUDIT_EVERY: Duration = Duration::from_secs(60);
const MAX_KEYS: usize = 1024;

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

impl Refusal {
    /// What an audited refusal adds about the quiet ones before it.
    pub fn left_out_note(left_out: u64) -> String {
        match left_out {
            0 => String::new(),
            left_out => format!(" ({left_out} more refused since the last record)"),
        }
    }
}

#[derive(Debug)]
pub(crate) struct RateLimits<Key> {
    budget: Budget,
    keys: HashMap<Key, Limit>,
}

pub(crate) type KnockLimits = RateLimits<GrantId>;
pub(crate) type PrincipalLimits = RateLimits<PrincipalId>;

impl<Key: Hash + Eq + Copy> RateLimits<Key> {
    pub fn new(budget: Budget) -> Self {
        Self {
            budget,
            keys: HashMap::new(),
        }
    }

    fn limit(&mut self, key: Key, now: Instant) -> &mut Limit {
        let budget = self.budget;
        if self.keys.len() >= MAX_KEYS && !self.keys.contains_key(&key) {
            let idle = AUDIT_EVERY.max(budget.every.mul_f64(budget.burst));
            self.keys
                .retain(|_, limit| now.duration_since(limit.refilled_at) < idle);
        }
        self.keys.entry(key).or_insert(Limit {
            tokens: budget.burst,
            refilled_at: now,
            audited_at: None,
            unaudited: 0,
        })
    }

    /// Takes one action from `key`'s budget; false if it has none left.
    pub fn admit(&mut self, key: Key, now: Instant) -> bool {
        let budget = self.budget;
        let limit = self.limit(key, now);
        let refill =
            now.duration_since(limit.refilled_at).as_secs_f64() / budget.every.as_secs_f64();
        limit.tokens = (limit.tokens + refill).min(budget.burst);
        limit.refilled_at = now;
        if limit.tokens < 1.0 {
            return false;
        }
        limit.tokens -= 1.0;
        true
    }

    /// Whether a refusal of `key`'s action goes to the audit log now.
    pub fn refused(&mut self, key: Key, now: Instant) -> Refusal {
        let limit = self.limit(key, now);
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
        let mut limits = KnockLimits::new(KNOCKS);
        let invite = GrantId([1; 16]);
        let t0 = Instant::now();
        let admitted = (0..1000).filter(|_| limits.admit(invite, t0)).count();
        assert_eq!(admitted, 8);
        assert!(
            limits.admit(invite, t0 + KNOCKS.every),
            "one more every 10 s"
        );
        assert!(
            limits.admit(GrantId([2; 16]), t0),
            "each invite has its own budget"
        );
    }

    #[test]
    fn a_person_prompting_is_never_held_back() {
        let mut limits = PrincipalLimits::new(PROMPTS);
        let guest = PrincipalId([1; 16]);
        let t0 = Instant::now();
        let typed = (0..60)
            .filter(|i| limits.admit(guest, t0 + Duration::from_secs(i * 3)))
            .count();
        assert_eq!(typed, 60, "a prompt every 3 s for 3 minutes");
        let scripted = (0..1000)
            .filter(|i| {
                limits.admit(
                    guest,
                    t0 + Duration::from_secs(180) + Duration::from_millis(*i),
                )
            })
            .count();
        assert_eq!(scripted, 5);
    }

    #[test]
    fn refusals_are_audited_once_a_minute_with_a_count() {
        let mut limits = KnockLimits::new(KNOCKS);
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
