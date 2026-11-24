//! Frozen wire bytes for Chat's agent controls (`proto::agent_control`):
//! `MoreDaemonFeatures::AGENT_CONTROLS` (bit 6), the `AgentControlsWatch`, `AgentControlsUnwatch`
//! and `SetAgentConfig` requests (appended after `ChatSendImages`), `WorkspaceResponse::AgentControls`
//! (after `RepoRoot`), `ServerCtl::AgentControls` (after `RunAgainOffers`), and
//! `ApprovalRequest::AnswerQuestion` and `Refuse` (after `RevokeRule`). Same rule as
//! `golden.rs`: never edit an existing hex string; add a case instead.

use proto::{
    Actor, AgentChoice, AgentConfig, AgentConfigSupport, AgentConfigTiming, AgentConfigValues,
    AgentControls, AgentModeChoice, AgentModeRisk, AgentPlan, AgentPrompt, AgentQuestion,
    AgentQuestionOption, AgentQuestions, ApprovalRequest, ClientCtl, Decide, DeviceId,
    MoreDaemonFeatures, OptionId, PaneId, PrincipalId, QuestionAnswer, RequestId, ServerCtl,
    WorkspaceRequest, WorkspaceResponse,
};

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn check<T>(value: &T, expected: &str)
where
    T: serde::Serialize + serde::de::DeserializeOwned + PartialEq + std::fmt::Debug,
{
    let encoded = postcard::to_allocvec(value).unwrap();
    assert_eq!(hex(&encoded), expected, "{value:?}");
    assert_eq!(&postcard::from_bytes::<T>(&encoded).unwrap(), value);
}

fn choice(id: &str, label: &str) -> AgentChoice {
    AgentChoice {
        id: id.into(),
        label: label.into(),
        detail: String::new(),
    }
}

fn controls(prompt: Option<AgentPrompt>) -> AgentControls {
    AgentControls {
        pane_id: PaneId(3),
        config: AgentConfig {
            support: AgentConfigSupport::Supported,
            current: AgentConfigValues {
                model: Some("opus".into()),
                mode: Some("default".into()),
                effort: None,
            },
            pending: Some(AgentConfigValues {
                model: Some("sonnet".into()),
                mode: None,
                effort: None,
            }),
            models: vec![choice("sonnet", "Sonnet")],
            modes: vec![AgentModeChoice {
                choice: choice("plan", "Plan"),
                risk: AgentModeRisk::Plans,
            }],
            efforts: vec![choice("high", "High")],
            timing: AgentConfigTiming::Restart,
        },
        prompt,
    }
}

fn decide() -> Decide {
    Decide {
        request_id: RequestId(9),
        option_id: OptionId(1),
        actor: Actor {
            principal: PrincipalId([1; 16]),
            device: DeviceId([2; 32]),
        },
        sig: vec![7],
    }
}

#[test]
fn agent_controls_keeps_its_bit() {
    check(&MoreDaemonFeatures::AGENT_CONTROLS, "40");
}

#[test]
fn requests_are_appended_after_chat_send_images() {
    check(
        &WorkspaceRequest::AgentControlsWatch { pane_id: PaneId(3) },
        "4c03",
    );
    check(
        &WorkspaceRequest::AgentControlsUnwatch { pane_id: PaneId(3) },
        "4d03",
    );
    check(
        &ClientCtl::Workspace {
            req_id: 5,
            req: WorkspaceRequest::SetAgentConfig {
                pane_id: PaneId(3),
                change: AgentConfigValues {
                    model: None,
                    mode: Some("plan".into()),
                    effort: Some("max".into()),
                },
            },
        },
        "15054e03000104706c616e01036d6178",
    );
}

#[test]
fn modes_and_timing_keep_their_order() {
    for (risk, byte) in [
        (AgentModeRisk::Asks, "00"),
        (AgentModeRisk::Plans, "01"),
        (AgentModeRisk::Edits, "02"),
        (AgentModeRisk::Automatic, "03"),
        (AgentModeRisk::Bypass, "04"),
    ] {
        check(&risk, byte);
    }
    check(&AgentConfigTiming::Restart, "00");
    check(&AgentConfigTiming::NextTurn, "01");
    check(&AgentConfigSupport::Unsupported("no".into()), "01026e6f");
}

#[test]
fn controls_reply_and_push_keep_their_bytes() {
    let config = "0300\
        0104 6f707573 0107 64656661756c74 00\
        01 0106 736f6e6e6574 00 00\
        01 06736f6e6e6574 06536f6e6e6574 00\
        01 04706c616e 04506c616e 00 01\
        01 0468696768 0448696768 00\
        00";
    let config: String = config.split_whitespace().collect();
    check(
        &WorkspaceResponse::AgentControls(controls(None)),
        &format!("2a{config}00"),
    );
    check(
        &ServerCtl::AgentControls(controls(None)),
        &format!("43{config}00"),
    );
}

#[test]
fn prompts_keep_their_bytes() {
    let questions = AgentPrompt::Questions(AgentQuestions {
        request_id: RequestId(9),
        questions: vec![AgentQuestion {
            header: "Auth".into(),
            question: "Which?".into(),
            options: vec![AgentQuestionOption {
                label: "JWT".into(),
                description: "d".into(),
            }],
            multi_select: true,
        }],
        answer: OptionId(0),
        skip: OptionId(1),
    });
    check(
        &questions,
        "00090104417574680657686963683f01034a5754016401 0001"
            .replace(' ', "")
            .as_str(),
    );
    check(
        &AgentPrompt::Plan(AgentPlan {
            request_id: RequestId(9),
            plan: "# P".into(),
            approve: OptionId(0),
            keep_planning: OptionId(1),
        }),
        "0109032320500001",
    );
}

#[test]
fn answers_are_appended_after_revoke_rule() {
    let signed = "09 01 01010101010101010101010101010101 \
        0202020202020202020202020202020202020202020202020202020202020202 0107";
    let signed: String = signed.split_whitespace().collect();
    check(
        &ApprovalRequest::AnswerQuestion {
            decide: decide(),
            answers: vec![QuestionAnswer {
                question: "Which?".into(),
                answer: "JWT".into(),
            }],
        },
        &format!("03{signed}010657686963683f034a5754"),
    );
    check(
        &ApprovalRequest::Refuse {
            decide: decide(),
            message: "more".into(),
        },
        &format!("04{signed}046d6f7265"),
    );
}
