//! When a pane's timeline refreshes. The first change after a quiet window refreshes at once;
//! while the agent streams text, the rest of the burst waits for the window to close, so a
//! streaming agent costs at most one push per window however many deltas it sends. Deltas wait
//! in the session's own row text, which its producer already bounds. An agent event (a turn
//! ending, a tool starting) refreshes at once, carrying the text before it.

use std::time::Duration;

use proto::{TimelineBody, TimelineField, TimelineOp};
use tokio::time::Instant;

/// At most one push per window while an agent streams text.
pub(crate) const STREAM_WINDOW: Duration = Duration::from_millis(60);
/// Coalesces a burst of transcript writes or other changes that are not streamed text.
pub(crate) const MIN_REFRESH_INTERVAL: Duration = Duration::from_millis(35);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Wake {
    /// The session's own wake: streamed text, a transcript write, a backlog continuation.
    Session,
    /// An agent event for the pane, such as its turn ending.
    Agent,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum LastPush {
    #[default]
    Other,
    Stream,
}

#[derive(Debug, Default)]
pub(crate) struct RefreshPace {
    last_refresh: Option<Instant>,
    last_push: LastPush,
}

impl RefreshPace {
    /// The earliest time a refresh for `wake` may run, or `None` for now.
    pub fn due(&self, wake: Wake) -> Option<Instant> {
        let last_refresh = self.last_refresh?;
        match (wake, self.last_push) {
            (Wake::Agent, _) => None,
            (Wake::Session, LastPush::Stream) => Some(last_refresh + STREAM_WINDOW),
            (Wake::Session, LastPush::Other) => Some(last_refresh + MIN_REFRESH_INTERVAL),
        }
    }

    pub fn refreshed(&mut self, at: Instant, operations: &[TimelineOp]) {
        debug_assert!(self.last_refresh.is_none_or(|last| last <= at));
        self.last_refresh = Some(at);
        self.last_push = if is_stream(operations) {
            LastPush::Stream
        } else {
            LastPush::Other
        };
    }
}

/// Only streamed text: appended reply or thinking text, or a reply or thinking row still
/// streaming.
fn is_stream(operations: &[TimelineOp]) -> bool {
    let mut has_text = false;
    for operation in operations {
        match operation {
            TimelineOp::Append {
                field: TimelineField::Text | TimelineField::Thinking,
                ..
            } => has_text = true,
            TimelineOp::Upsert { item, .. } => match &item.body {
                TimelineBody::Assistant {
                    streaming: true, ..
                }
                | TimelineBody::Thinking {
                    duration_ms: None, ..
                } => has_text = true,
                _ => return false,
            },
            TimelineOp::Checkpoint { .. } => {}
            _ => return false,
        }
    }
    has_text
}

#[cfg(test)]
mod tests {
    use proto::{TimelineCursor, TimelineItem, TimelineOrigin, UnixMillis};

    use super::*;

    fn cursor() -> TimelineCursor {
        TimelineCursor {
            epoch: 1,
            sequence: 1,
        }
    }

    fn delta() -> TimelineOp {
        TimelineOp::Append {
            cursor: cursor(),
            id: "reply".into(),
            field: TimelineField::Text,
            text: "more".into(),
        }
    }

    fn item(body: TimelineBody) -> TimelineOp {
        TimelineOp::Upsert {
            cursor: cursor(),
            item: Box::new(TimelineItem {
                id: "item".into(),
                revision: 1,
                turn: None,
                parent: None,
                at: UnixMillis(0),
                origin: TimelineOrigin::Agent,
                body,
            }),
        }
    }

    fn turn_end() -> TimelineOp {
        item(TimelineBody::TurnEnd {
            duration_ms: 1,
            input_tokens: None,
            output_tokens: None,
        })
    }

    #[test]
    fn the_first_change_after_a_quiet_window_refreshes_at_once() {
        assert_eq!(RefreshPace::default().due(Wake::Session), None);
    }

    #[test]
    fn streamed_text_waits_for_the_window_and_then_refreshes_with_the_rest() {
        let mut pace = RefreshPace::default();
        let start = Instant::now();
        pace.refreshed(start, &[delta()]);
        assert_eq!(pace.due(Wake::Session), Some(start + STREAM_WINDOW));

        pace.refreshed(start + STREAM_WINDOW, &[delta(), delta()]);
        assert_eq!(pace.due(Wake::Session), Some(start + 2 * STREAM_WINDOW));
    }

    #[test]
    fn other_changes_keep_the_shorter_interval() {
        let mut pace = RefreshPace::default();
        let start = Instant::now();
        pace.refreshed(start, &[delta(), turn_end()]);
        assert_eq!(pace.due(Wake::Session), Some(start + MIN_REFRESH_INTERVAL));
    }

    #[test]
    fn an_agent_event_refreshes_without_waiting_for_the_window() {
        let mut pace = RefreshPace::default();
        let start = Instant::now();
        pace.refreshed(start, &[delta()]);
        assert_eq!(pace.due(Wake::Agent), None);
    }

    #[test]
    fn a_refresh_that_found_nothing_ends_the_stream_window() {
        let mut pace = RefreshPace::default();
        let start = Instant::now();
        pace.refreshed(start, &[delta()]);
        pace.refreshed(start + Duration::from_millis(5), &[]);
        assert_eq!(
            pace.due(Wake::Session),
            Some(start + Duration::from_millis(5) + MIN_REFRESH_INTERVAL)
        );
    }

    #[test]
    fn a_streaming_row_counts_as_text_and_a_finished_one_does_not() {
        assert!(is_stream(&[item(TimelineBody::Assistant {
            text: "a".into(),
            streaming: true,
        })]));
        assert!(is_stream(&[item(TimelineBody::Thinking {
            text: Some("a".into()),
            duration_ms: None,
        })]));
        assert!(!is_stream(&[item(TimelineBody::Assistant {
            text: "a".into(),
            streaming: false,
        })]));
        assert!(!is_stream(&[TimelineOp::Checkpoint { cursor: cursor() }]));
        assert!(!is_stream(&[]));
    }

    /// However many deltas arrive, a streaming agent refreshes once per window.
    #[test]
    fn a_fast_stream_refreshes_once_per_window() {
        let mut pace = RefreshPace::default();
        let start = Instant::now();
        let mut refreshes = Vec::new();
        for millisecond in 0..=600u64 {
            let now = start + Duration::from_millis(millisecond);
            if pace.due(Wake::Session).is_none_or(|due| due <= now) {
                pace.refreshed(now, &[delta()]);
                refreshes.push(millisecond);
            }
        }
        assert_eq!(refreshes.first(), Some(&0));
        assert_eq!(refreshes.len(), 11);
        for pair in refreshes.windows(2) {
            assert_eq!(pair[1] - pair[0], 60);
        }
    }
}
