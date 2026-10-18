//! Latency percentiles.

use std::time::Duration;

/// Summary of a set of latency samples.
#[derive(Debug, Clone, Copy)]
pub struct Summary {
    /// Number of samples.
    pub n: usize,
    /// Median.
    pub p50: Duration,
    /// 90th percentile.
    pub p90: Duration,
    /// 99th percentile.
    pub p99: Duration,
    /// Worst sample.
    pub max: Duration,
}

impl Summary {
    /// Summarises `samples` (nearest-rank percentiles). Returns `None` for no samples.
    pub fn new(mut samples: Vec<Duration>) -> Option<Self> {
        if samples.is_empty() {
            return None;
        }
        samples.sort_unstable();
        let rank = |p: f64| {
            let i = (p / 100.0 * samples.len() as f64).ceil() as usize;
            samples[i.clamp(1, samples.len()) - 1]
        };
        Some(Self {
            n: samples.len(),
            p50: rank(50.0),
            p90: rank(90.0),
            p99: rank(99.0),
            max: samples[samples.len() - 1],
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nearest_rank() {
        let s = Summary::new((1..=100).map(Duration::from_millis).collect()).unwrap();
        assert_eq!(s.p50, Duration::from_millis(50));
        assert_eq!(s.p99, Duration::from_millis(99));
        assert_eq!(s.max, Duration::from_millis(100));
        assert!(Summary::new(vec![]).is_none());
    }
}
