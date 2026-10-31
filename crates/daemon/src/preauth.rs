//! Limits on connections that have not sent their `Hello` yet.
//!
//! Anyone who knows the daemon id can connect with a fresh key, so what strangers may hold
//! open is bounded, overall and per remote address. Devices the daemon already trusts (paired
//! owner devices, guests bound to a grant) are recognised by their key, which the TLS
//! handshake proves before the `Hello` (and a relay names even before that), and are never
//! counted against strangers: a crowd of strangers cannot lock their owner out.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex, PoisonError};

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
}

impl Default for PreAuthLimits {
    fn default() -> Self {
        Self {
            handshakes: 1024,
            handshakes_per_addr: 32,
            strangers: 128,
            strangers_per_addr: 16,
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
    by_source: HashMap<Source, (usize, usize)>,
}

/// The daemon's pre-`Hello` accounting.
#[derive(Debug)]
pub(crate) struct Gate {
    limits: PreAuthLimits,
    counts: Mutex<Counts>,
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
        })
    }

    fn take(self: &Arc<Self>, source: Option<Source>, stage: Stage) -> Option<Slot> {
        let mut counts = self.counts.lock().unwrap_or_else(PoisonError::into_inner);
        let l = &self.limits;
        let per = source.map_or((0, 0), |s| {
            counts.by_source.get(&s).copied().unwrap_or_default()
        });
        let fits = match stage {
            Stage::Known => true,
            Stage::Handshake => {
                counts.handshakes < l.handshakes
                    && (source.is_none() || per.0 < l.handshakes_per_addr)
            }
            Stage::Stranger => {
                counts.strangers < l.strangers
                    && (source.is_none() || per.1 < l.strangers_per_addr)
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

    /// A connection arriving: `known` when a relay already named a trusted key. `None`
    /// refuses it.
    pub fn arrive(self: &Arc<Self>, ip: Option<IpAddr>, known: bool) -> Option<Slot> {
        let source = ip.map(Source::from);
        self.take(source, if known { Stage::Known } else { Stage::Handshake })
    }
}

impl Counts {
    fn add(&mut self, source: Option<Source>, stage: Stage, n: isize) {
        let bump = |v: &mut usize| *v = v.saturating_add_signed(n);
        match stage {
            Stage::Known => return,
            Stage::Handshake => bump(&mut self.handshakes),
            Stage::Stranger => bump(&mut self.strangers),
        }
        if let Some(s) = source {
            let entry = self.by_source.entry(s).or_default();
            match stage {
                Stage::Handshake => bump(&mut entry.0),
                _ => bump(&mut entry.1),
            }
            if *entry == (0, 0) {
                self.by_source.remove(&s);
            }
        }
    }
}

impl Slot {
    /// The handshake proved the peer's key: a trusted one stops counting, a stranger moves
    /// to the strangers' pool. `None` refuses it.
    pub fn authenticated(self, known: bool) -> Option<Self> {
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
        }
    }

    fn ip(s: &str) -> Option<IpAddr> {
        Some(s.parse().unwrap())
    }

    #[test]
    fn one_address_cannot_take_every_slot() {
        let gate = Gate::new(limits());
        let a: Vec<_> = (0..2).map(|_| gate.arrive(ip("10.0.0.1"), false)).collect();
        assert!(a.iter().all(Option::is_some));
        assert!(gate.arrive(ip("10.0.0.1"), false).is_none());
        // The same host over IPv4-mapped IPv6 is the same source.
        assert!(gate.arrive(ip("::ffff:10.0.0.1"), false).is_none());
        // Another /64 is not; the same /64 is.
        assert!(gate.arrive(ip("2001:db8:0:1::1"), false).is_some());
        let b = gate.arrive(ip("2001:db8:0:1::2"), false);
        assert!(b.is_some());
        assert!(gate.arrive(ip("2001:db8:0:1::3"), false).is_none());
        // Global limit.
        assert!(gate.arrive(ip("10.0.0.9"), false).is_none());
        drop(a);
        assert!(gate.arrive(ip("10.0.0.1"), false).is_some());
    }

    #[test]
    fn trusted_keys_never_wait_behind_strangers() {
        let gate = Gate::new(limits());
        let strangers: Vec<_> = ["10.0.0.1", "10.0.0.2", "10.0.0.3"]
            .into_iter()
            .map(|a| {
                gate.arrive(ip(a), false)
                    .and_then(|s| s.authenticated(false))
                    .expect("room")
            })
            .collect();
        // Strangers are full…
        let next = gate.arrive(ip("10.0.0.4"), false).expect("handshake slot");
        assert!(next.authenticated(false).is_none());
        // …but a trusted key from a stranger's own address still gets in.
        let owner = gate.arrive(ip("10.0.0.1"), false).expect("handshake slot");
        assert!(owner.authenticated(true).is_some());
        // So does one a relay already named.
        assert!(gate.arrive(None, true).is_some());
        drop(strangers);
        let counts = gate.counts.lock().unwrap();
        assert_eq!((counts.handshakes, counts.strangers), (0, 0));
        assert!(counts.by_source.is_empty(), "{:?}", counts.by_source);
    }
}
