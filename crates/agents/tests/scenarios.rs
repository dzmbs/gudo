//! End-to-end scenarios: adapter parsers feeding the arbiter, with injected time.

use agents::{
    AgentAdapter, AgentState, Arbiter, ArbiterConfig, ClaudeCode, Codex, EventKind, Lane, Notify,
    PaneId, ScreenInput, Seq, SessionInfo, Source, Status, UnixMillis, Update,
};

fn fixture(agent: &str, name: &str) -> Vec<u8> {
    let path = format!(
        "{}/tests/fixtures/{agent}/{name}.json",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read(path).expect("fixture exists")
}

struct Pane<A: AgentAdapter> {
    adapter: A,
    arbiter: Arbiter,
    log: Vec<(EventKind, AgentState, Source)>,
    notified: Vec<Notify>,
}

impl<A: AgentAdapter> Pane<A> {
    fn new(adapter: A) -> Self {
        let arbiter = Arbiter::new(
            ArbiterConfig::new(adapter.hook_coverage()),
            Some(PaneId::new("p1")),
            SessionInfo::new(adapter.kind(), Lane::Pty),
            UnixMillis(0),
        );
        Self {
            adapter,
            arbiter,
            log: Vec::new(),
            notified: Vec::new(),
        }
    }

    fn record(&mut self, update: Update) {
        if let Some(event) = update.event {
            self.log
                .push((event.kind, event.status.state(), event.source));
        }
        self.notified.extend(update.notify);
    }

    fn hook(&mut self, payload: &[u8], seq: u64, now: u64) {
        if let Some(signal) = self.adapter.parse_hook(payload, Seq(seq)).unwrap() {
            let update = self.arbiter.apply(signal, UnixMillis(now));
            self.record(update);
        }
    }

    fn screen(&mut self, screen: &str, title: &str, now: u64) {
        let verdict = self.adapter.detect_screen(ScreenInput {
            screen,
            osc_title: title,
            osc_progress: "",
        });
        let update = self.arbiter.observe_screen(&verdict, UnixMillis(now));
        self.record(update);
    }

    fn osc9(&mut self, body: &str, now: u64) {
        if let Some(signal) = self.adapter.parse_osc9(body) {
            let update = self.arbiter.apply(signal, UnixMillis(now));
            self.record(update);
        }
    }

    fn tick(&mut self, now: u64) {
        let update = self.arbiter.tick(UnixMillis(now));
        self.record(update);
    }
}

const CLAUDE_IDLE: &str = "\
⏺ Done.

────────────────────────────────────────
❯
────────────────────────────────────────
  ? for shortcuts";

const CLAUDE_DIALOG: &str = "\
────────────────────────────────────────
 Bash command

   rm -rf node_modules

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for rm -rf commands in /src/app
   3. No, and tell Claude what to do differently (esc)

 Esc to cancel · Tab to amend";

#[test]
fn claude_permission_answered_in_terminal_then_cancelled() {
    let mut pane = Pane::new(ClaudeCode::new());
    pane.hook(&fixture("claude", "session_start_resume"), 1, 0);
    pane.screen(CLAUDE_IDLE, "✳ Claude Code", 10);
    pane.hook(&fixture("claude", "user_prompt_submit"), 2, 1000);
    pane.screen("", "◐ Working", 1100);
    pane.hook(&fixture("claude", "permission_request"), 3, 5000);
    pane.hook(
        &fixture("claude", "notification_permission_prompt"),
        4,
        5010,
    );
    pane.screen(CLAUDE_DIALOG, "✳ Claude Code", 5100);
    let request = pane.arbiter.status().blocked().unwrap().clone();
    assert_eq!(request.blocker.tool.as_deref(), Some("Bash"));
    assert_eq!(
        request.blocker.summary.as_deref(),
        Some("rm -rf node_modules")
    );

    // The user presses 1 at the Mac; Claude works again.
    pane.screen("", "◑ Working", 7000);
    assert_eq!(pane.arbiter.status(), &Status::Working);
    // The screen retired the hook claim, so the screen alone decides the rest of this turn.
    pane.screen(CLAUDE_IDLE, "✳ Claude Code", 9000);
    assert_eq!(pane.arbiter.status(), &Status::Idle);

    // Next turn: the user hits Esc. No hook fires; the idle prompt must outlast the
    // still-standing hook claim by 2 s.
    pane.hook(&fixture("claude", "user_prompt_submit"), 5, 12_000);
    pane.screen("", "◐ Working", 12_100);
    pane.screen(CLAUDE_IDLE, "✳ Claude Code", 15_000);
    assert_eq!(pane.arbiter.next_deadline(), Some(UnixMillis(17_000)));
    pane.tick(16_999);
    assert_eq!(pane.arbiter.status(), &Status::Working);
    pane.tick(17_000);
    assert_eq!(pane.arbiter.status(), &Status::Idle);

    assert_eq!(
        pane.log,
        [
            (EventKind::SessionStarted, AgentState::Unknown, Source::Hook),
            (EventKind::TurnEnded, AgentState::Idle, Source::Screen),
            (EventKind::TurnStarted, AgentState::Working, Source::Hook),
            (EventKind::Blocked, AgentState::Blocked, Source::Hook),
            (EventKind::Unblocked, AgentState::Working, Source::Title),
            (EventKind::TurnEnded, AgentState::Idle, Source::Screen),
            (EventKind::TurnStarted, AgentState::Working, Source::Hook),
            (EventKind::TurnEnded, AgentState::Idle, Source::Screen),
        ]
    );
    assert_eq!(
        pane.notified,
        [
            Notify::Blocked {
                request_id: request.request_id
            },
            Notify::Done,
            Notify::Done
        ]
    );
    assert_eq!(
        pane.arbiter
            .session()
            .native_id
            .as_ref()
            .map(|id| id.as_str()),
        Some("abc123")
    );
}

#[test]
fn codex_without_hooks_runs_on_title_screen_and_osc9() {
    let mut pane = Pane::new(Codex::new());
    pane.screen("› ", "app", 0);
    pane.screen("• Working (2s • esc to interrupt)\n› ", "⠋ app", 1000);
    pane.osc9("Approval requested: cargo publish", 3000);
    // The title flips after the notification.
    pane.screen("", "[ ! ] Action Required", 3050);
    let blocked = pane.arbiter.status().blocked().unwrap().clone();
    assert_eq!(blocked.blocker.summary.as_deref(), Some("cargo publish"));
    assert_eq!(
        pane.notified.len(),
        0,
        "OSC 9 is not authoritative: debounced"
    );
    pane.tick(4500);
    assert_eq!(
        pane.notified,
        [Notify::Blocked {
            request_id: blocked.request_id
        }]
    );
    pane.screen("• Working (9s • esc to interrupt)\n› ", "⠙ app", 6000);
    pane.osc9("Published the crate.", 9000);
    pane.screen("• Published.\n› ", "app", 9050);
    assert_eq!(pane.arbiter.status(), &Status::Idle);
    assert_eq!(pane.notified.last(), Some(&Notify::Done));
    let kinds: Vec<EventKind> = pane.log.iter().map(|(kind, _, _)| *kind).collect();
    assert_eq!(
        kinds,
        [
            EventKind::TurnEnded,
            EventKind::TurnStarted,
            EventKind::Blocked,
            EventKind::Unblocked,
            EventKind::TurnEnded,
        ]
    );
}

#[test]
fn codex_opt_in_hooks_are_authoritative_for_blocking() {
    let mut pane = Pane::new(Codex::new());
    pane.hook(&fixture("codex", "session_start"), 1, 0);
    pane.hook(&fixture("codex", "user_prompt_submit"), 2, 100);
    pane.hook(&fixture("codex", "permission_request"), 3, 200);
    assert!(matches!(pane.notified.as_slice(), [Notify::Blocked { .. }]));
    pane.hook(&fixture("codex", "interrupt"), 4, 300);
    assert_eq!(pane.arbiter.status(), &Status::Idle);
    assert_eq!(pane.log.last().unwrap().0, EventKind::Interrupted);
}

#[test]
fn captured_claude_2_1_302_payloads_parse() {
    let cases = [
        ("session_start", Some(EventKind::SessionStarted)),
        ("user_prompt_submit", Some(EventKind::TurnStarted)),
        ("pre_tool_use", Some(EventKind::ToolStarted)),
        ("post_tool_use", None),
        ("stop", Some(EventKind::TurnEnded)),
        ("session_end", Some(EventKind::SessionEnded)),
    ];
    for (name, expected) in cases {
        let payload = fixture("claude", &format!("captured-2.1.302/{name}"));
        let signal = ClaudeCode::default()
            .parse_hook(&payload, Seq(1))
            .unwrap_or_else(|err| panic!("{name}: {err}"));
        assert_eq!(signal.map(|signal| signal.kind), expected, "{name}");
    }
}
