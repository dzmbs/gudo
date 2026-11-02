//! Time that keeps going forward when someone sets the system clock.
//!
//! Wall time (`identity::now_millis`) is right for timestamps people read and for absolute
//! expiries, but anything measured between two moments (debounces, staleness, ordering) must not
//! freeze for an hour when the clock is set back, or fire at once when it is set forward. Those use
//! the boot clock, which counts from boot, includes sleep, and is shared by every process on the
//! host, so a hook shim and the daemon read the same one.

use std::sync::LazyLock;

/// Nanoseconds since boot, including time asleep (Darwin's `CLOCK_MONOTONIC`, Linux's
/// `CLOCK_BOOTTIME`). Never goes back, whatever happens to the wall clock.
pub fn boot_nanos() -> u64 {
    #[cfg(target_os = "linux")]
    const CLOCK: libc::clockid_t = libc::CLOCK_BOOTTIME;
    #[cfg(not(target_os = "linux"))]
    const CLOCK: libc::clockid_t = libc::CLOCK_MONOTONIC;
    let mut timespec = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `timespec` is a valid, writable timespec; the clock id exists on this OS.
    let status = unsafe { libc::clock_gettime(CLOCK, &mut timespec) };
    debug_assert_eq!(status, 0, "clock_gettime");
    (timespec.tv_sec as u64)
        .saturating_mul(1_000_000_000)
        .saturating_add(timespec.tv_nsec as u64)
}

/// Wall-clock milliseconds as of the daemon's start, carried forward by the boot clock: close
/// to wall time (it follows sleep), but steps of the system clock do not move it.
pub(crate) fn steady_millis() -> u64 {
    static ANCHOR: LazyLock<Steady> =
        LazyLock::new(|| Steady::new(crate::identity::now_millis(), boot_nanos()));
    ANCHOR.at(boot_nanos())
}

/// A wall-clock reading tied to a boot-clock reading.
#[derive(Debug, Clone, Copy)]
struct Steady {
    wall_ms: u64,
    boot_ns: u64,
}

impl Steady {
    fn new(wall_ms: u64, boot_ns: u64) -> Self {
        Self { wall_ms, boot_ns }
    }

    fn at(self, boot_ns: u64) -> u64 {
        self.wall_ms + boot_ns.saturating_sub(self.boot_ns) / 1_000_000
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_boot_clock_moves_forward() {
        let before = boot_nanos();
        std::thread::sleep(std::time::Duration::from_millis(5));
        let after = boot_nanos();
        assert!(after >= before + 4_000_000, "{before} → {after}");
    }

    #[test]
    fn steady_time_follows_the_boot_clock_only() {
        let steady = Steady::new(1_000_000, 50_000_000_000);
        assert_eq!(steady.at(50_000_000_000), 1_000_000);
        assert_eq!(steady.at(53_500_000_000), 1_003_500);
        let first = steady_millis();
        assert!(steady_millis() >= first);
    }
}
