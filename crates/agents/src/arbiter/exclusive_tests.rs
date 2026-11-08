use super::*;
use crate::{AgentKind, Lane};

fn structured() -> Arbiter {
    let mut config = ArbiterConfig::new(HookCoverage::FullLifecycle);
    config.exclusive_source = Some(Source::Structured);
    Arbiter::new(
        config,
        None,
        SessionInfo::new(AgentKind::Codex, Lane::AppServer),
        UnixMillis(0),
    )
}

#[test]
fn a_live_structured_claim_is_not_completed_by_notify_screen_or_time() {
    let mut arbiter = structured();
    let working = Signal::new(
        Source::Structured,
        Confidence::Authoritative,
        EventKind::TurnStarted,
    )
    .with_claim(Claim::Working);
    let _ = arbiter.apply(working, UnixMillis(1));
    for source in [
        Source::Hook,
        Source::Osc9,
        Source::Osc7501,
        Source::Title,
        Source::Screen,
    ] {
        let ended = Signal::new(source, Confidence::Authoritative, EventKind::TurnEnded)
            .with_claim(Claim::Idle);
        assert_eq!(arbiter.apply(ended, UnixMillis(2)), Update::default());
    }
    for state in [AgentState::Blocked, AgentState::Idle] {
        let verdict = ScreenVerdict::State(ScreenMatch::new(state, Source::Screen, None, true));
        assert_eq!(
            arbiter.observe_screen(&verdict, UnixMillis(3)),
            Update::default()
        );
    }
    let _ = arbiter.tick(UnixMillis(24 * 60 * 60 * 1000));
    assert_eq!(arbiter.status().state(), AgentState::Working);
    assert_eq!(arbiter.next_deadline(), None);
    let released = Signal::new(
        Source::Structured,
        Confidence::Authoritative,
        EventKind::Stale,
    )
    .with_claim(Claim::Release);
    let _ = arbiter.apply(released, UnixMillis(24 * 60 * 60 * 1000 + 1));
    assert_eq!(arbiter.status().state(), AgentState::Unknown);
}

#[test]
fn actual_process_exit_still_retires_an_exclusive_source() {
    let mut arbiter = structured();
    let _ = arbiter.apply(
        Signal::new(
            Source::Structured,
            Confidence::Authoritative,
            EventKind::TurnStarted,
        )
        .with_claim(Claim::Working),
        UnixMillis(1),
    );
    let _ = arbiter.process_exited(UnixMillis(2));
    assert_eq!(arbiter.status().state(), AgentState::Unknown);
    assert_eq!(
        arbiter.apply(
            Signal::new(
                Source::Structured,
                Confidence::Authoritative,
                EventKind::TurnEnded
            )
            .with_claim(Claim::Idle),
            UnixMillis(3)
        ),
        Update::default()
    );
}
