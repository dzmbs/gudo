//! The agents Live Activity (docs/PUSH.md §6): one activity on the device for all agents of
//! all hosts; this host keeps its own row up to date.
//!
//! The daemon summarises its agents ([`Summary`]: working, needing the user, finished
//! unseen, and one headline), seals it to each registered device as a
//! [`push::ActivityState`] and sends it through the relay as a Live Activity push:
//!
//! - **start** (push-to-start, `PushRegistration::activity_cap`) when agents become active and
//!   the device has no running activity; once per active spell, so a dismissed activity is
//!   not forced back while the same agents work on;
//! - **update** to the running activity's capability (`PushActivity`) when the summary
//!   changes, at most once per [`activity_interval`](crate::PushConfig::activity_interval)
//!   unless an agent newly needs the user (then at once, with high priority);
//! - **end** once every agent stayed idle for
//!   [`activity_end_after`](crate::PushConfig::activity_end_after); the device's activity
//!   capability is then forgotten.
//!
//! Changes settle for [`activity_debounce`](crate::PushConfig::activity_debounce) first, so a
//! burst of agent events becomes one push. A `410` (the token is gone) forgets that
//! capability.

use std::sync::Arc;
use std::time::Duration;

use proto::{AgentState, AttentionKind};
use tokio::sync::broadcast::error::RecvError;
use tokio::time::Instant;

use super::{Registration, SendError, post};
use crate::core::{Core, Event, lock};
use crate::fsutil::unhex;
use crate::identity::now_millis;

/// Attempts per Live Activity push: a later summary replaces a lost one anyway.
const ATTEMPTS: u32 = 2;
/// The activity looks stale on the device if no update arrives for this long.
const STALE_AFTER: Duration = Duration::from_secs(15 * 60);
/// An ended activity stays on the Lock Screen this long.
const DISMISS_AFTER: Duration = Duration::from_secs(10 * 60);
/// Longest headline sent.
const MAX_HEADLINE: usize = 120;

/// What this host's agents are doing, as the activity shows it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Summary {
    pub running: u32,
    pub blocked: u32,
    pub done: u32,
    pub headline: String,
}

impl Summary {
    /// Agents are working or waiting for the user.
    fn active(&self) -> bool {
        self.running + self.blocked > 0
    }
}

/// Reads the agents of every pane and the unseen "finished" items.
pub(crate) fn summarize(core: &Core) -> Summary {
    let mut summary = Summary::default();
    let mut blocked_line = None;
    let mut running_line = None;
    let mut active_panes = Vec::new();
    let mut entries = core.pane_entries();
    entries.sort_by_key(|(id, _)| id.0);
    for (id, entry) in entries {
        let Some(status) = lock(&entry.agent)
            .as_mut()
            .map(|runtime| runtime.wire_status())
        else {
            continue;
        };
        let title = lock(&entry.meta).title.clone();
        match status.state {
            AgentState::Running => {
                summary.running += 1;
                active_panes.push(id);
                running_line.get_or_insert_with(|| {
                    if title.is_empty() {
                        format!("{} is working", status.kind)
                    } else {
                        format!("{} is working · {title}", status.kind)
                    }
                });
            }
            AgentState::Blocked(blocker) => {
                summary.blocked += 1;
                active_panes.push(id);
                blocked_line.get_or_insert_with(|| {
                    if blocker.summary.is_empty() {
                        format!("{} needs you", status.kind)
                    } else {
                        format!("{}: {}", status.kind, blocker.summary)
                    }
                });
            }
            AgentState::Idle | AgentState::Done => {}
        }
    }
    // Finished turns nobody has looked at yet, one per pane, unless that agent works again.
    let mut done_panes = Vec::new();
    let mut done_line = None;
    for item in core
        .ws
        .attention
        .list_for(crate::ws::Viewer::Owner)
        .items
        .iter()
        .rev()
    {
        let agent = match &item.kind {
            AttentionKind::AgentDone { agent } => format!("{agent} finished"),
            AttentionKind::AgentFailed { agent } => format!("{agent} failed"),
            _ => continue,
        };
        if item.seen || done_panes.contains(&item.pane_id) || active_panes.contains(&item.pane_id) {
            continue;
        }
        done_panes.push(item.pane_id);
        done_line.get_or_insert_with(|| {
            if item.body.is_empty() {
                agent
            } else {
                format!("{agent}: {}", item.body)
            }
        });
    }
    summary.done = done_panes.len() as u32;
    let headline = blocked_line
        .or(running_line)
        .or(done_line)
        .unwrap_or_default();
    summary.headline = shorten(headline.lines().next().unwrap_or_default());
    summary
}

fn shorten(line: &str) -> String {
    if line.chars().count() <= MAX_HEADLINE {
        return line.to_owned();
    }
    line.chars().take(MAX_HEADLINE - 1).collect::<String>() + "…"
}

/// One push decided for one device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Send {
    Start { urgent: bool },
    Update { urgent: bool },
    End,
}

/// What was sent to one device.
#[derive(Debug, Default)]
pub(crate) struct DeviceState {
    /// The summary the device's activity shows.
    sent: Option<Summary>,
    sent_at: Option<Instant>,
    /// A start was sent in the current active spell (reset once agents go idle).
    started: bool,
    /// Since when every agent is idle.
    idle_since: Option<Instant>,
}

/// Decides what to send one device now, given whether it has a push-to-start and a running
/// activity's capability. Returns the push (if any) and when to look again (if a decision
/// is only deferred).
pub(crate) fn decide(
    state: &mut DeviceState,
    summary: &Summary,
    can_start: bool,
    running: bool,
    now: Instant,
    interval: Duration,
    end_after: Duration,
) -> (Option<Send>, Option<Instant>) {
    if summary.active() {
        state.idle_since = None;
    } else {
        state.started = false;
        state.idle_since.get_or_insert(now);
    }
    if !running {
        if summary.active() && can_start && !state.started {
            return (
                Some(Send::Start {
                    urgent: summary.blocked > 0,
                }),
                None,
            );
        }
        return (None, None);
    }
    if !summary.active() {
        let idle_since = state.idle_since.unwrap_or(now);
        if now.duration_since(idle_since) >= end_after {
            return (Some(Send::End), None);
        }
        let recheck = Some(idle_since + end_after);
        if state.sent.as_ref() == Some(summary) {
            return (None, recheck);
        }
        // Finished: say so now (non-urgent), end later.
        return match state.sent_at {
            Some(at) if now.duration_since(at) < interval => (None, Some(at + interval)),
            _ => (Some(Send::Update { urgent: false }), recheck),
        };
    }
    if state.sent.as_ref() == Some(summary) {
        return (None, None);
    }
    let urgent = summary.blocked > state.sent.as_ref().map_or(0, |shown| shown.blocked);
    match state.sent_at {
        Some(at) if !urgent && now.duration_since(at) < interval => (None, Some(at + interval)),
        _ => (Some(Send::Update { urgent }), None),
    }
}

/// A device's activity token changed (`PushActivity`): remember it, and send the current
/// summary to a new one at once.
pub(super) fn token_changed(core: &Core, device: &str, cap: Option<String>) {
    let ended = cap.is_none();
    core.push.update(device, |registration| {
        let changed = registration.activity_update_cap != cap;
        registration.activity_update_cap = cap;
        changed
    });
    {
        let mut devices = lock(&core.push.activities);
        let state = devices.entry(device.to_owned()).or_default();
        state.sent = None;
        state.sent_at = None;
        // Ended or dismissed by the user: no new start until the agents go idle and busy again.
        state.started = ended || state.started;
    }
    core.push.activity_wake.notify_one();
    tracing::info!(device = %&device[..8], ended, "live activity token");
}

fn relevant(event: &Event) -> bool {
    matches!(
        event,
        Event::PaneMeta(_)
            | Event::PaneClosed(_)
            | Event::Agent { .. }
            | Event::Attention(_)
            | Event::AttentionSeen { .. }
    )
}

/// Follows the agents and keeps every device's activity up to date.
pub(crate) async fn run(core: Arc<Core>) {
    if !core.cfg.push.live_activity {
        return;
    }
    let mut events = core.events.subscribe();
    let mut next: Option<Instant> = None;
    loop {
        let wait = async {
            match next {
                Some(at) => tokio::time::sleep_until(at).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            event = events.recv() => match event {
                Ok(event) if !relevant(&event) => continue,
                Ok(_) | Err(RecvError::Lagged(_)) => {
                    let settle = Instant::now() + core.cfg.push.activity_debounce;
                    next = Some(next.map_or(settle, |pending| pending.min(settle)));
                }
                Err(RecvError::Closed) => return,
            },
            () = core.push.activity_wake.notified() => {
                let settle = Instant::now() + core.cfg.push.activity_debounce;
                next = Some(next.map_or(settle, |pending| pending.min(settle)));
            }
            () = wait => next = evaluate(&core).await,
        }
    }
}

/// Sends what each device needs now; returns when to look again.
async fn evaluate(core: &Arc<Core>) -> Option<Instant> {
    if !core.cfg.push.enabled {
        return None;
    }
    let summary = summarize(core);
    let now = Instant::now();
    let mut next: Option<Instant> = None;
    for registration in super::targets(core) {
        let can_start = registration.activity_cap.is_some();
        let running = registration.activity_update_cap.is_some();
        if !can_start && !running {
            continue;
        }
        let (send, recheck) = {
            let mut devices = lock(&core.push.activities);
            let state = devices.entry(registration.device.clone()).or_default();
            decide(
                state,
                &summary,
                can_start,
                running,
                now,
                core.cfg.push.activity_interval,
                core.cfg.push.activity_end_after,
            )
        };
        if let Some(at) = recheck {
            next = Some(next.map_or(at, |pending| pending.min(at)));
        }
        let Some(send) = send else { continue };
        let result = deliver(core, &registration, &summary, send).await;
        let mut devices = lock(&core.push.activities);
        let state = devices.entry(registration.device.clone()).or_default();
        match result {
            Ok(()) => {
                lock(&core.push.errors).remove(&registration.device);
                match send {
                    Send::Start { .. } => state.started = true,
                    Send::Update { .. } => {}
                    Send::End => {
                        *state = DeviceState::default();
                        drop(devices);
                        core.push.update(&registration.device, |stored| {
                            stored.activity_update_cap.take().is_some()
                        });
                        continue;
                    }
                }
                state.sent = Some(summary.clone());
                state.sent_at = Some(now);
            }
            Err(SendError::Gone) => {
                tracing::info!(device = %&registration.device[..8], ?send, "live activity token gone");
                *state = DeviceState::default();
                drop(devices);
                core.push.update(&registration.device, |stored| match send {
                    Send::Start { .. } => stored.activity_cap.take().is_some(),
                    _ => stored.activity_update_cap.take().is_some(),
                });
            }
            Err(SendError::Failed(why)) => {
                tracing::warn!(device = %&registration.device[..8], "live activity push failed: {why}");
                // Not marked sent: the next change (or this recheck) tries again.
                if matches!(send, Send::Start { .. }) {
                    state.started = true;
                }
                lock(&core.push.errors).insert(registration.device.clone(), why);
                let retry = now + core.cfg.push.activity_interval;
                next = Some(next.map_or(retry, |pending| pending.min(retry)));
            }
        }
    }
    next
}

/// Seals the summary for the device and posts it as a Live Activity push.
async fn deliver(
    core: &Core,
    registration: &Registration,
    summary: &Summary,
    send: Send,
) -> Result<(), SendError> {
    let seal_key = unhex::<32>(&registration.seal_key)
        .ok_or_else(|| SendError::Failed("bad sealing key on file".into()))?;
    let seed = core.identity.secret.to_bytes();
    let at = now_millis();
    let state = push::ActivityState {
        v: push::Notification::VERSION,
        daemon: crate::fsutil::hex(&core.identity.daemon_id().0),
        host: crate::ws::tunnel::hostname(),
        running: summary.running,
        blocked: summary.blocked,
        done: summary.done,
        headline: summary.headline.clone(),
        at,
    };
    let json = serde_json::to_vec(&state).map_err(|error| SendError::Failed(error.to_string()))?;
    let sealed = push::seal(&seal_key, &seed, &json)
        .map_err(|error| SendError::Failed(format!("sealing: {error}")))?;
    let (cap, event, urgent) = match send {
        Send::Start { urgent } => (
            registration.activity_cap.clone(),
            push::ActivityEvent::Start,
            urgent,
        ),
        Send::Update { urgent } => (
            registration.activity_update_cap.clone(),
            push::ActivityEvent::Update,
            urgent,
        ),
        Send::End => (
            registration.activity_update_cap.clone(),
            push::ActivityEvent::End,
            false,
        ),
    };
    let cap = cap.ok_or_else(|| SendError::Failed("no activity capability".into()))?;
    let seconds = at / 1000;
    let (stale, dismiss) = match event {
        push::ActivityEvent::End => (None, Some(seconds + DISMISS_AFTER.as_secs())),
        _ => (Some(seconds + STALE_AFTER.as_secs()), None),
    };
    tracing::debug!(device = %&registration.device[..8], ?send, ?summary, "live activity");
    post(core, registration, ATTEMPTS, || push::RelayRequest {
        v: push::RelayRequest::VERSION,
        daemon: String::new(),
        cap: cap.clone(),
        push_type: push::PushType::LiveActivity,
        category: None,
        collapse: None,
        sealed: sealed.clone(),
        ts: 0,
        nonce: String::new(),
        event: Some(event),
        stale,
        dismiss,
        urgent,
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECOND: Duration = Duration::from_secs(1);

    fn summary(running: u32, blocked: u32, done: u32) -> Summary {
        Summary {
            running,
            blocked,
            done,
            headline: format!("{running}/{blocked}/{done}"),
        }
    }

    fn step(
        state: &mut DeviceState,
        shown: &Summary,
        can_start: bool,
        running: bool,
        now: Instant,
    ) -> (Option<Send>, Option<Instant>) {
        let decision = decide(
            state,
            shown,
            can_start,
            running,
            now,
            10 * SECOND,
            60 * SECOND,
        );
        if let (Some(send), _) = decision {
            if matches!(send, Send::Start { .. }) {
                state.started = true;
            }
            state.sent = Some(shown.clone());
            state.sent_at = Some(now);
        }
        decision
    }

    #[test]
    fn starts_once_per_active_spell() {
        let start = Instant::now();
        let mut state = DeviceState::default();
        // Nothing runs: nothing to start.
        assert_eq!(
            step(&mut state, &summary(0, 0, 0), true, false, start).0,
            None
        );
        // An agent works: push-to-start, routine priority.
        assert_eq!(
            step(&mut state, &summary(1, 0, 0), true, false, start).0,
            Some(Send::Start { urgent: false })
        );
        // The device never registered the started activity (dismissed, or failed): no
        // second start while the same spell lasts.
        assert_eq!(
            step(&mut state, &summary(1, 1, 0), true, false, start + SECOND).0,
            None
        );
        // Idle, then busy again: a new spell starts again, urgent when someone waits.
        assert_eq!(
            step(
                &mut state,
                &summary(0, 0, 1),
                true,
                false,
                start + 2 * SECOND
            )
            .0,
            None
        );
        assert_eq!(
            step(
                &mut state,
                &summary(0, 1, 0),
                true,
                false,
                start + 3 * SECOND
            )
            .0,
            Some(Send::Start { urgent: true })
        );
        // Without a push-to-start capability nothing starts.
        let mut other = DeviceState::default();
        assert_eq!(
            step(&mut other, &summary(1, 0, 0), false, false, start).0,
            None
        );
    }

    #[test]
    fn updates_are_rate_limited_but_needing_you_goes_at_once() {
        let start = Instant::now();
        let mut state = DeviceState::default();
        assert_eq!(
            step(&mut state, &summary(1, 0, 0), false, true, start).0,
            Some(Send::Update { urgent: false })
        );
        // The same summary again: nothing.
        assert_eq!(
            step(&mut state, &summary(1, 0, 0), false, true, start + SECOND),
            (None, None)
        );
        // A routine change inside the interval waits for its end.
        assert_eq!(
            step(
                &mut state,
                &summary(2, 0, 0),
                false,
                true,
                start + 2 * SECOND
            ),
            (None, Some(start + 10 * SECOND))
        );
        // An agent needing the user goes at once, with high priority.
        assert_eq!(
            step(
                &mut state,
                &summary(1, 1, 0),
                false,
                true,
                start + 3 * SECOND
            )
            .0,
            Some(Send::Update { urgent: true })
        );
        // Answered (fewer blocked): routine again, after the interval.
        assert_eq!(
            step(
                &mut state,
                &summary(2, 0, 0),
                false,
                true,
                start + 4 * SECOND
            ),
            (None, Some(start + 13 * SECOND))
        );
        assert_eq!(
            step(
                &mut state,
                &summary(2, 0, 0),
                false,
                true,
                start + 13 * SECOND
            )
            .0,
            Some(Send::Update { urgent: false })
        );
    }

    #[test]
    fn ends_after_staying_idle() {
        let start = Instant::now();
        let mut state = DeviceState::default();
        step(&mut state, &summary(1, 0, 0), false, true, start);
        // Finished: shown at once (outside the interval), the end is scheduled.
        assert_eq!(
            step(
                &mut state,
                &summary(0, 0, 1),
                false,
                true,
                start + 20 * SECOND
            ),
            (
                Some(Send::Update { urgent: false }),
                Some(start + 80 * SECOND)
            )
        );
        assert_eq!(
            step(
                &mut state,
                &summary(0, 0, 1),
                false,
                true,
                start + 30 * SECOND
            ),
            (None, Some(start + 80 * SECOND))
        );
        // Busy again before the end: the clock resets.
        step(
            &mut state,
            &summary(1, 0, 0),
            false,
            true,
            start + 40 * SECOND,
        );
        assert_eq!(
            step(
                &mut state,
                &summary(0, 0, 0),
                false,
                true,
                start + 50 * SECOND
            )
            .1,
            Some(start + 110 * SECOND)
        );
        assert_eq!(
            step(
                &mut state,
                &summary(0, 0, 0),
                false,
                true,
                start + 110 * SECOND
            )
            .0,
            Some(Send::End)
        );
    }

    #[test]
    fn headlines_are_one_short_line() {
        assert_eq!(shorten("short"), "short");
        let long = "x".repeat(300);
        assert_eq!(shorten(&long).chars().count(), MAX_HEADLINE);
        assert!(shorten(&long).ends_with('…'));
    }
}
