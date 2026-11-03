//! Limits on connections that have not sent their `Hello` yet.
//!
//! Anyone who knows the daemon id can connect with a fresh key, so what strangers may hold
//! open is bounded, overall and per remote address. Devices the daemon already trusts (paired
//! owner devices, guests bound to a grant) are recognised by their key, which the TLS
//! handshake proves before the `Hello` (and a relay names even before that), and are never
//! counted against strangers: a crowd of strangers cannot lock their owner out.
//!
//! Strangers whose `Hello` was refused spend a failure budget, per address and per key; with
//! it spent, they are turned away right after the handshake, before any grant is checked or
//! audited.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

/// How many pre-`Hello` connections are allowed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PreAuthLimits {
    /// Connections still in the QUIC handshake (key not yet known).
    pub handshakes: usize,
    /// Of those, from one address (IPv6: one /64).
    pub handshakes_per_addr: usize,
    /// Unknown keys past the handshake, waiting for their `Hello`.
    pub strangers: usize,
    /// Of those, from one address.
    pub strangers_per_addr: usize,
    /// Refused `Hello`s one address or key may have in a burst ...
    pub failures: u32,
    /// ... and then one per this long.
    pub failure_every: Duration,
}

impl Default for PreAuthLimits {
    fn default() -> Self {
        Self {
            handshakes: 1024,
            handshakes_per_addr: 32,
            strangers: 128,
            strangers_per_addr: 16,
            failures: 20,
            failure_every: Duration::from_secs(3),
        }
    }
}

/// Where a connection comes from, as counted: an IPv4 address, or an IPv6 /64 (one host
/// usually holds a whole /64). IPv4-mapped IPv6 counts as the IPv4 address.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Source {
    V4([u8; 4]),
    V6([u8; 8]),
}

impl From<IpAddr> for Source {
    fn from(ip: IpAddr) -> Self {
        match ip.to_canonical() {
            IpAddr::V4(v4) => Self::V4(v4.octets()),
            IpAddr::V6(v6) => Self::V6(v6.octets()[..8].try_into().expect("8 bytes")),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    Handshake,
    Stranger,
    Known,
}

#[derive(Debug, Default)]
struct Counts {
    handshakes: usize,
    strangers: usize,
    /// (handshakes, strangers) per source.
    by_source: HashMap<Source, (usize, usize)>,
}

/// Whose refusals are counted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Offender {
    Source(Source),
    Key([u8; 32]),
}

#[derive(Debug, Clone, Copy)]
struct Budget {
    left: f64,
    refilled_at: Instant,
}

/// Failure budgets; only offenders with some of theirs spent are kept.
#[derive(Debug, Default)]
struct Failures {
    budgets: HashMap<Offender, Budget>,
}

/// How many offenders are remembered; past this, the one with most budget left is forgotten.
const MAX_OFFENDERS: usize = 4096;

impl Budget {
    fn left(&self, limits: &PreAuthLimits, now: Instant) -> f64 {
        let refill = now.duration_since(self.refilled_at).as_secs_f64()
            / limits.failure_every.as_secs_f64().max(f64::EPSILON);
        (self.left + refill).min(f64::from(limits.failures))
    }
}

impl Failures {
    fn left(&self, limits: &PreAuthLimits, offender: Offender, now: Instant) -> f64 {
        self.budgets
            .get(&offender)
            .map_or(f64::from(limits.failures), |budget| {
                budget.left(limits, now)
            })
    }

    fn spent(&self, limits: &PreAuthLimits, offender: Offender, now: Instant) -> bool {
        self.left(limits, offender, now) < 1.0
    }

    fn record(&mut self, limits: &PreAuthLimits, offender: Offender, now: Instant) {
        let left = (self.left(limits, offender, now) - 1.0).max(0.0);
        if self.budgets.len() >= MAX_OFFENDERS && !self.budgets.contains_key(&offender) {
            let full = f64::from(limits.failures);
            self.budgets
                .retain(|_, budget| budget.left(limits, now) < full);
            let most_left = self
                .budgets
                .iter()
                .max_by(|a, b| a.1.left(limits, now).total_cmp(&b.1.left(limits, now)))
                .map(|(known, _)| *known);
            if self.budgets.len() >= MAX_OFFENDERS
                && let Some(most_left) = most_left
            {
                self.budgets.remove(&most_left);
            }
        }
        self.budgets.insert(
            offender,
            Budget {
                left,
                refilled_at: now,
            },
        );
    }
}

#[derive(Debug)]
pub(crate) struct Gate {
    limits: PreAuthLimits,
    counts: Mutex<Counts>,
    failures: Mutex<Failures>,
}

/// A connection's place before its `Hello`; released on drop.
#[derive(Debug)]
pub(crate) struct Slot {
    gate: Arc<Gate>,
    source: Option<Source>,
    stage: Stage,
}

impl Gate {
    pub fn new(limits: PreAuthLimits) -> Arc<Self> {
        Arc::new(Self {
            limits,
            counts: Mutex::default(),
            failures: Mutex::default(),
        })
    }

    fn take(self: &Arc<Self>, source: Option<Source>, stage: Stage) -> Option<Slot> {
        let mut counts = self.counts.lock().unwrap_or_else(PoisonError::into_inner);
        let limits = &self.limits;
        let (source_handshakes, source_strangers) = source.map_or((0, 0), |source| {
            counts.by_source.get(&source).copied().unwrap_or_default()
        });
        let fits = match stage {
            Stage::Known => true,
            Stage::Handshake => {
                counts.handshakes < limits.handshakes
                    && (source.is_none() || source_handshakes < limits.handshakes_per_addr)
            }
            Stage::Stranger => {
                counts.strangers < limits.strangers
                    && (source.is_none() || source_strangers < limits.strangers_per_addr)
            }
        };
        if !fits {
            return None;
        }
        counts.add(source, stage, 1);
        Some(Slot {
            gate: Arc::clone(self),
            source,
            stage,
        })
    }

    /// Whether a stranger from `source` or with `key` has spent its failure budget. Only
    /// checked once the handshake proved the key, so a trusted device behind the same
    /// address is never turned away.
    fn barred(&self, source: Option<Source>, key: [u8; 32]) -> bool {
        let failures = self.failures.lock().unwrap_or_else(PoisonError::into_inner);
        let now = Instant::now();
        source
            .map(Offender::Source)
            .into_iter()
            .chain([Offender::Key(key)])
            .any(|offender| failures.spent(&self.limits, offender, now))
    }

    /// A connection arriving: `known` when a relay already named a trusted key. `None`
    /// refuses it.
    pub fn arrive(self: &Arc<Self>, ip: Option<IpAddr>, known: bool) -> Option<Slot> {
        let source = ip.map(Source::from);
        self.take(
            source,
            if known {
                Stage::Known
            } else {
                Stage::Handshake
            },
        )
    }
}

impl Counts {
    fn add(&mut self, source: Option<Source>, stage: Stage, delta: isize) {
        let bump = |count: &mut usize| *count = count.saturating_add_signed(delta);
        match stage {
            Stage::Known => return,
            Stage::Handshake => bump(&mut self.handshakes),
            Stage::Stranger => bump(&mut self.strangers),
        }
        if let Some(source) = source {
            let entry = self.by_source.entry(source).or_default();
            match stage {
                Stage::Handshake => bump(&mut entry.0),
                _ => bump(&mut entry.1),
            }
            if *entry == (0, 0) {
                self.by_source.remove(&source);
            }
        }
    }
}

impl Slot {
    /// The handshake proved the peer's `key`: a trusted one stops counting, a stranger moves
    /// to the strangers' pool. `None` refuses it.
    pub fn authenticated(self, key: [u8; 32], known: bool) -> Option<Self> {
        if !known && self.gate.barred(self.source, key) {
            return None;
        }
        let next = if known { Stage::Known } else { Stage::Stranger };
        if self.stage == next {
            return Some(self);
        }
        // Released first, so the move never needs two slots from one source at once.
        let (gate, source) = (Arc::clone(&self.gate), self.source);
        drop(self);
        gate.take(source, next)
    }
}

impl Slot {
    /// The peer's `Hello` with `key` was refused: it spends the failure budget of its address
    /// and of its key.
    pub fn refused(&self, key: [u8; 32]) {
        let mut failures = self
            .gate
            .failures
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let now = Instant::now();
        for offender in self
            .source
            .map(Offender::Source)
            .into_iter()
            .chain([Offender::Key(key)])
        {
            failures.record(&self.gate.limits, offender, now);
        }
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        self.gate
            .counts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .add(self.source, self.stage, -1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits() -> PreAuthLimits {
        PreAuthLimits {
            handshakes: 4,
            handshakes_per_addr: 2,
            strangers: 3,
            strangers_per_addr: 2,
            failures: 2,
            failure_every: Duration::from_secs(3600),
        }
    }

    fn ip(text: &str) -> Option<IpAddr> {
        Some(text.parse().unwrap())
    }

    #[test]
    fn one_address_cannot_take_every_slot() {
        let gate = Gate::new(limits());
        let first_host: Vec<_> = (0..2).map(|_| gate.arrive(ip("10.0.0.1"), false)).collect();
        assert!(first_host.iter().all(Option::is_some));
        assert!(gate.arrive(ip("10.0.0.1"), false).is_none());
        // The same host over IPv4-mapped IPv6 is the same source.
        assert!(gate.arrive(ip("::ffff:10.0.0.1"), false).is_none());
        // Another /64 is not; the same /64 is.
        let one_subnet: Vec<_> = ["2001:db8:0:1::1", "2001:db8:0:1::2"]
            .into_iter()
            .map(|address| gate.arrive(ip(address), false))
            .collect();
        assert!(one_subnet.iter().all(Option::is_some));
        assert!(gate.arrive(ip("2001:db8:0:1::3"), false).is_none());
        // Global limit.
        assert!(gate.arrive(ip("10.0.0.9"), false).is_none());
        drop(first_host);
        assert!(gate.arrive(ip("10.0.0.1"), false).is_some());
    }

    #[test]
    fn trusted_keys_never_wait_behind_strangers() {
        let gate = Gate::new(limits());
        let strangers: Vec<_> = ["10.0.0.1", "10.0.0.2", "10.0.0.3"]
            .into_iter()
            .map(|address| {
                gate.arrive(ip(address), false)
                    .and_then(|slot| slot.authenticated([1; 32], false))
                    .expect("room")
            })
            .collect();
        // Strangers are full…
        let next = gate.arrive(ip("10.0.0.4"), false).expect("handshake slot");
        assert!(next.authenticated([2; 32], false).is_none());
        // …but a trusted key from a stranger's own address still gets in.
        let owner = gate.arrive(ip("10.0.0.1"), false).expect("handshake slot");
        assert!(owner.authenticated([3; 32], true).is_some());
        // So does one a relay already named.
        assert!(gate.arrive(None, true).is_some());
        drop(strangers);
        let counts = gate.counts.lock().unwrap();
        assert_eq!((counts.handshakes, counts.strangers), (0, 0));
        assert!(counts.by_source.is_empty(), "{:?}", counts.by_source);
    }

    #[test]
    fn refused_strangers_spend_their_address_and_key() {
        let gate = Gate::new(limits());
        let key = [7; 32];
        for _ in 0..2 {
            let slot = gate.arrive(ip("10.0.0.1"), false).expect("handshake slot");
            slot.refused(key);
        }
        // The address has spent its budget: a new key from it is turned away…
        let same_address = gate.arrive(ip("10.0.0.1"), false).expect("handshake slot");
        assert!(same_address.authenticated([8; 32], false).is_none());
        // …and so is the key from another address.
        let elsewhere = gate.arrive(ip("10.0.0.2"), false).expect("handshake slot");
        assert!(elsewhere.authenticated(key, false).is_none());
        // A fresh key from a fresh address is a fresh stranger.
        let fresh = gate.arrive(ip("10.0.0.3"), false).expect("handshake slot");
        assert!(fresh.authenticated([8; 32], false).is_some());
        // A trusted device behind the spent address still gets in.
        let owner = gate.arrive(ip("10.0.0.1"), false).expect("handshake slot");
        assert!(owner.authenticated([9; 32], true).is_some());
    }

    #[test]
    fn failure_budgets_refill_and_stay_bounded() {
        let limits = PreAuthLimits {
            failures: 1,
            failure_every: Duration::from_secs(10),
            ..limits()
        };
        let mut failures = Failures::default();
        let start = Instant::now();
        let source = Offender::Source(Source::V4([10, 0, 0, 1]));
        failures.record(&limits, source, start);
        assert!(failures.spent(&limits, source, start));
        assert!(!failures.spent(&limits, source, start + Duration::from_secs(10)));
        for index in 0..(MAX_OFFENDERS as u32 + 100) {
            let mut key = [0; 32];
            key[..4].copy_from_slice(&index.to_le_bytes());
            failures.record(&limits, Offender::Key(key), start);
        }
        assert!(failures.budgets.len() <= MAX_OFFENDERS);
    }
}
