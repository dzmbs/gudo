//! Frozen wire bytes for the input-assistance messages (`proto::assist`), kept apart from
//! `golden.rs` so the cases of parallel additions do not collide. Same rule: never edit an
//! existing hex string; add a case instead.
//!
//! To print the current encodings: `PROTO_PRINT_GOLDEN=1 cargo test -p proto --test
//! golden_assist -- --nocapture`.

use std::fmt::Debug;

use proto::frame::{self, FrameDecoder};
use proto::*;
use serde::Serialize;
use serde::de::DeserializeOwned;

const PANE: PaneId = PaneId(3);

struct Checker {
    print: bool,
    failures: Vec<String>,
}

impl Checker {
    fn check<T>(&mut self, name: &str, msg: T, golden: &str)
    where
        T: Serialize + DeserializeOwned + PartialEq + Debug,
    {
        let wire = frame::to_vec(&msg).unwrap();
        let hex: String = wire.iter().map(|byte| format!("{byte:02x}")).collect();
        if self.print {
            println!("{name}: \"{hex}\"");
        }
        if hex != golden {
            self.failures
                .push(format!("{name}\n  want {golden}\n  got  {hex}"));
        }
        let mut decoder = FrameDecoder::new(MAX_FRAME_LEN);
        decoder.extend(&wire);
        let back: T = decoder.decode().unwrap().unwrap();
        assert_eq!(back, msg, "{name} did not round-trip");
        assert_eq!(decoder.buffered(), 0, "{name} left bytes behind");
    }
}

fn prompt_state() -> PromptState {
    PromptState {
        pane_id: PANE,
        prompt_id: 7,
        at_seq: Seq(300),
        phase: PromptPhase::AtPrompt(PromptInput {
            text: "git st".into(),
            cursor: 6,
            confident: true,
            doubt: None,
            suggestion: Some("atus".into()),
            right_prompt: true,
            shell: ShellKind::Zsh,
            bracketed_paste: true,
            keymap: Keymap::Unknown,
        }),
    }
}

fn foreground() -> Foreground {
    Foreground {
        pane_id: PANE,
        pid: 4242,
        name: "vim".into(),
        argv: vec!["vim".into(), "a.rs".into()],
        profile: ProgramProfile::Vim,
        since: UnixMillis(1000),
    }
}

#[test]
fn assist_messages_match_their_frozen_bytes() {
    let mut checker = Checker {
        print: std::env::var_os("PROTO_PRINT_GOLDEN").is_some(),
        failures: vec![],
    };
    let req = |req| ClientCtl::Assist { req_id: 5, req };
    checker.check(
        "ClientCtl::Assist(Watch)",
        req(AssistRequest::Watch {
            pane_id: PANE,
            watch: true,
        }),
        "06000000011905000301",
    );
    checker.check(
        "ClientCtl::Assist(State)",
        req(AssistRequest::State { pane_id: PANE }),
        "050000000119050103",
    );
    checker.check(
        "ClientCtl::Assist(SubmitLine)",
        req(AssistRequest::SubmitLine(SubmitLine {
            pane_id: PANE,
            prompt_id: 7,
            text: "ls".into(),
            run: true,
        })),
        "0a000000011905020307026c7301",
    );
    checker.check(
        "ClientCtl::Assist(History)",
        req(AssistRequest::History(HistoryQuery {
            cwd: Some("/w".into()),
            prefix: Some("gi".into()),
            contains: None,
            since: Some(UnixMillis(9)),
            limit: 20,
        })),
        "100000000119050301022f770102676900010914",
    );
    checker.check(
        "ClientCtl::Assist(Complete)",
        req(AssistRequest::Complete(CompleteRequest {
            pane_id: PANE,
            line: "cat no".into(),
            cursor: 6,
            limit: 10,
        })),
        "0e000000011905040306636174206e6f060a",
    );
    checker.check(
        "ClientCtl::Assist(FileSearch)",
        req(AssistRequest::FileSearch(FileSearch {
            root: "~/p".into(),
            query: "cnr".into(),
            limit: 10,
        })),
        "0d00000001190505037e2f7003636e720a",
    );
    checker.check(
        "ClientCtl::Assist(BlockedOptions)",
        req(AssistRequest::BlockedOptions { pane_id: PANE }),
        "050000000119050603",
    );
    checker.check(
        "ClientCtl::Assist(AnswerBlocked)",
        req(AssistRequest::AnswerBlocked(AnswerBlocked {
            pane_id: PANE,
            index: 1,
            label: "Yes".into(),
        })),
        "0a00000001190507030103596573",
    );

    let ok = |response| ServerCtl::AssistResult {
        req_id: 5,
        result: Ok(response),
    };
    let err = |error| ServerCtl::AssistResult {
        req_id: 5,
        result: Err(error),
    };
    checker.check(
        "ServerCtl::AssistResult(Done)",
        ok(AssistResponse::Done),
        "050000000124050000",
    );
    checker.check(
        "ServerCtl::AssistResult(State)",
        ok(AssistResponse::State(PaneAssist {
            foreground: Some(foreground()),
            prompt: prompt_state(),
        })),
        "330000000124050001010392210376696d020376696d04612e727301e8070307ac02000667697420737406010001046174757301000102",
    );
    checker.check(
        "ServerCtl::AssistResult(Submitted)",
        ok(AssistResponse::Submitted {
            prompt_id: 7,
            at_seq: Seq(301),
        }),
        "08000000012405000207ad02",
    );
    checker.check(
        "ServerCtl::AssistResult(History)",
        ok(AssistResponse::History(vec![HistoryEntry {
            command: "make".into(),
            cwd: Some("/w".into()),
            exit: Some(2),
            duration_ms: Some(1500),
            last_at: UnixMillis(77),
            count: 3,
        }])),
        "16000000012405000301046d616b6501022f77010401dc0b4d03",
    );
    checker.check(
        "ServerCtl::AssistResult(Completions)",
        ok(AssistResponse::Completions(Completions {
            cwd: Some("/w".into()),
            items: vec![Completion {
                text: "notes.txt".into(),
                display: "notes.txt".into(),
                kind: CompletionKind::Path,
                detail: None,
                start: 4,
                end: 6,
            }],
        })),
        "22000000012405000401022f7701096e6f7465732e747874096e6f7465732e74787401000406",
    );
    checker.check(
        "ServerCtl::AssistResult(Files)",
        ok(AssistResponse::Files(FileMatches {
            root: "/w".into(),
            matches: vec![FileMatch {
                path: "src/conn.rs".into(),
                kind: FileKind::File,
                positions: vec![4, 5],
            }],
            scanned: 40,
            truncated: false,
        })),
        "1b0000000124050005022f77010b7372632f636f6e6e2e7273000204052800",
    );
    checker.check(
        "ServerCtl::AssistResult(Blocked)",
        ok(AssistResponse::Blocked(Some(BlockedPrompt {
            pane_id: PANE,
            request_id: Some(RequestId(9)),
            summary: "rm".into(),
            options: vec![BlockedOption {
                label: "Yes".into(),
                choice: BlockedChoice::AllowOnce,
                option_id: Some(OptionId(0)),
                keys: b"1".to_vec(),
                selected: true,
            }],
            source: BlockedSource::Hook,
        }))),
        "1800000001240500060103010902726d010359657300010001310100",
    );
    checker.check(
        "ServerCtl::AssistResult(NotAtPrompt)",
        err(AssistError::NotAtPrompt(PromptState {
            pane_id: PANE,
            prompt_id: 8,
            at_seq: Seq(400),
            phase: PromptPhase::Running { command_id: 8 },
        })),
        "0b0000000124050102030890030108",
    );
    checker.check(
        "ServerCtl::AssistResult(Denied)",
        err(AssistError::Denied("driver".into())),
        "0c000000012405010006647269766572",
    );
    checker.check(
        "ServerCtl::Assist(Foreground)",
        ServerCtl::Assist(AssistPush::Foreground(foreground())),
        "170000000125000392210376696d020376696d04612e727301e807",
    );
    checker.check(
        "ServerCtl::Assist(Prompt)",
        ServerCtl::Assist(AssistPush::Prompt(prompt_state())),
        "1c0000000125010307ac02000667697420737406010001046174757301000102",
    );
    checker.check(
        "ServerCtl::Assist(Prompt unknown, doubtful)",
        ServerCtl::Assist(AssistPush::Prompt(PromptState {
            pane_id: PANE,
            prompt_id: 0,
            at_seq: Seq(0),
            phase: PromptPhase::AtPrompt(PromptInput {
                text: "ls".into(),
                cursor: 2,
                confident: false,
                doubt: Some(InputDoubt::NoInputMark),
                suggestion: None,
                right_prompt: false,
                shell: ShellKind::Fish,
                bracketed_paste: true,
                keymap: Keymap::Emacs,
            }),
        })),
        "1300000001250103000000026c73020001000000020100",
    );
    for (name, profile, golden) in [
        (
            "ProgramProfile::Shell",
            ProgramProfile::Shell,
            "020000000100",
        ),
        (
            "ProgramProfile::Other",
            ProgramProfile::Other,
            "020000000108",
        ),
    ] {
        checker.check(name, profile, golden);
    }
    assert!(
        checker.failures.is_empty(),
        "{}",
        checker.failures.join("\n")
    );
}
