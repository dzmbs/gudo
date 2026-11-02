//! The foreground program of each pane, debounced.
//!
//! The PTY's foreground process group (`tcgetpgrp` on the master) is sampled every
//! [`SAMPLE`]; a new program is reported once it has been in front for [`STABLE`], so `ls`
//! or a prompt's `git` call never flickers the client's key bar.

use std::time::{Duration, Instant};

use proto::{Foreground, PaneId, ProgramProfile, UnixMillis};

use crate::identity::now_millis;

/// How often foreground groups are sampled.
pub(crate) const SAMPLE: Duration = Duration::from_millis(100);
/// How long a program must stay in front before it is reported.
pub(crate) const STABLE: Duration = Duration::from_millis(150);

/// One pane's reported and candidate foreground programs.
#[derive(Debug, Default)]
pub(crate) struct Tracker {
    current: Option<Foreground>,
    candidate: Option<(Foreground, Instant)>,
}

fn same(one: &Foreground, other: &Foreground) -> bool {
    one.pid == other.pid && one.name == other.name && one.argv == other.argv
}

impl Tracker {
    pub fn current(&self) -> Option<&Foreground> {
        self.current.as_ref()
    }

    /// Feeds one sample; returns the program to report when it changed.
    pub fn sample(
        &mut self,
        pane: PaneId,
        process: Option<pty::ForegroundProcess>,
        now: Instant,
    ) -> Option<Foreground> {
        let seen = process.map(|process| foreground(pane, process))?;
        if self
            .current
            .as_ref()
            .is_some_and(|current| same(current, &seen))
        {
            self.candidate = None;
            return None;
        }
        let first = match &self.candidate {
            Some((candidate, at)) if same(candidate, &seen) => *at,
            _ => {
                self.candidate = Some((seen, now));
                // The very first sample of a pane is reported at once.
                if self.current.is_some() {
                    return None;
                }
                now.checked_sub(STABLE).unwrap_or(now)
            }
        };
        if now.duration_since(first) < STABLE {
            return None;
        }
        let (program, _) = self.candidate.take()?;
        self.current = Some(program.clone());
        Some(program)
    }
}

/// Converts the PTY crate's view of the foreground group.
pub(crate) fn foreground(pane: PaneId, process: pty::ForegroundProcess) -> Foreground {
    let profile = ProgramProfile::classify(&process.name, &process.argv);
    Foreground {
        pane_id: pane,
        pid: process.pid,
        name: process.program().to_owned(),
        argv: process.argv,
        profile,
        since: UnixMillis(now_millis()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(pid: u32, name: &str) -> Option<pty::ForegroundProcess> {
        Some(pty::ForegroundProcess {
            pid,
            name: name.into(),
            argv: vec![name.into()],
        })
    }

    #[test]
    fn short_lived_programs_are_not_reported() {
        let mut tracker = Tracker::default();
        let start = Instant::now();
        let first = tracker
            .sample(PaneId(1), process(10, "zsh"), start)
            .unwrap();
        assert_eq!(first.profile, ProgramProfile::Shell);
        // `ls` for one sample, then the shell again: nothing.
        assert!(
            tracker
                .sample(PaneId(1), process(11, "ls"), start + SAMPLE)
                .is_none()
        );
        assert!(
            tracker
                .sample(PaneId(1), process(10, "zsh"), start + SAMPLE * 2)
                .is_none()
        );
        // `vim` for long enough: reported once.
        assert!(
            tracker
                .sample(PaneId(1), process(12, "vim"), start + SAMPLE * 3)
                .is_none()
        );
        let vim = tracker
            .sample(PaneId(1), process(12, "vim"), start + SAMPLE * 5)
            .unwrap();
        assert_eq!(vim.profile, ProgramProfile::Vim);
        assert!(
            tracker
                .sample(PaneId(1), process(12, "vim"), start + SAMPLE * 6)
                .is_none()
        );
        assert_eq!(tracker.current().unwrap().pid, 12);
    }
}
