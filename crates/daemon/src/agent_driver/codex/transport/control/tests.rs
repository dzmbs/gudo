use super::super::Direction;
use super::*;
use crate::agent_driver::codex;
use crate::agent_input::chat_tests::{RawFixture, raw_fixture};
use std::sync::Arc;

struct Fixture {
    raw: RawFixture,
    source: Arc<Live>,
    actor: Actor,
}

impl Fixture {
    async fn new() -> Self {
        let raw = raw_fixture().await;
        let pane = raw.entry.pane.id;
        *lock(&raw.entry.agent) = Some(crate::agent::AgentRuntime::structured(
            proto::AgentKind::Codex,
            pane,
            crate::agent::adapter(proto::AgentKind::Codex),
        ));
        lock(&raw.entry.record).agent.as_mut().unwrap().kind = proto::AgentKind::Codex;
        let source = codex::tests::source();
        *lock(&raw.entry.codex) = Some(Arc::clone(&source));
        source.set_owner(&raw.daemon.core, &raw.entry);
        source.capture_context(
            raw.root.path().to_owned(),
            raw.entry.pane.pty().foreground_pgid().unwrap(),
        );
        let recording: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../agents/tests/fixtures/codex-live/pane-stream-0.166.0.json"
        )))
        .unwrap();
        let effects = {
            let mut state = lock(&source.state);
            state.observe(&recording["request"].to_string(), Direction::FromTui);
            state.observe(&recording["response"].to_string(), Direction::FromServer);
            std::mem::take(&mut state.effects)
        };
        source.publish(effects);
        let paired = raw.daemon.core.identity.paired().remove(0);
        let actor = Actor {
            principal: paired.principal,
            device: paired.device,
        };
        Self { raw, source, actor }
    }

    fn prompt(&self, text: &str) -> Command {
        self.source
            .command(
                None,
                lock(&self.raw.entry.pane.agent_input_gate)
                    .control_revision()
                    .unwrap(),
                self.actor,
                Action::Send(text.into()),
                None,
            )
            .unwrap()
    }

    fn approval(&self) -> Command {
        let thread = lock(&self.source.state)
            .current
            .as_ref()
            .unwrap()
            .thread_id()
            .to_owned();
        let effects = {
            let mut state = lock(&self.source.state);
            state.observe(&json!({"method":"turn/started","params":{"threadId":thread,"turn":{"id":"active","status":"inProgress"}}}).to_string(), Direction::FromServer);
            state.observe(&json!({"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":thread,"turnId":"active","itemId":"command","command":"printf fixture","cwd":"/fixture","kind":"command","availableDecisions":["accept","cancel"]}}).to_string(), Direction::FromServer);
            std::mem::take(&mut state.effects)
        };
        self.source.publish(effects);
        let detail = lock(&self.raw.entry.agent)
            .as_mut()
            .unwrap()
            .blocked_detail()
            .unwrap();
        lock(&self.source.runtime).pending[0].admitted = true;
        let mut command = self
            .source
            .command(
                None,
                lock(&self.raw.entry.pane.agent_input_gate)
                    .control_revision()
                    .unwrap(),
                self.actor,
                Action::Approve {
                    request: CodexRpcId::Integer(7),
                    common: detail.request,
                    choice: ApprovalChoice::AllowOnce,
                },
                None,
            )
            .unwrap();
        command.policy = Some(
            self.raw
                .daemon
                .core
                .mp
                .policy_of_pane(&self.raw.daemon.core, self.raw.entry.pane.id),
        );
        command.signers.push(crate::mp::Authz::owner(self.actor));
        command
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn serialization_rechecks_the_input_fence_source_and_encoded_budget() {
    let fixture = Fixture::new().await;
    let source = Arc::downgrade(&fixture.source);
    let command = fixture.prompt("fixture");
    let request: Value = serde_json::from_str(&serialize(&source, &command).unwrap()).unwrap();
    assert_eq!(request["method"], "turn/start");
    assert_eq!(request["params"]["input"][0]["text"], "fixture");
    assert!(serialize(&source, &fixture.prompt(&"\"".repeat(40 * 1024))).is_err());
    {
        let _write = crate::agent_input::begin_unproven_write(
            &fixture.raw.entry.pane.agent_input_gate,
            b"x",
        );
    }
    assert!(
        serialize(&source, &command).is_err(),
        "an intervening Terminal write retires the authorization"
    );
    let command = fixture.prompt("replacement");
    *lock(&fixture.raw.entry.codex) = Some(codex::tests::source());
    assert!(
        serialize(&source, &command).is_err(),
        "a replaced producer cannot serialize controls"
    );
    fixture.raw.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn approval_serialization_rechecks_policy_scope_and_all_signer_liveness() {
    let fixture = Fixture::new().await;
    let source = Arc::downgrade(&fixture.source);
    let mut command = fixture.approval();
    let request: Value = serde_json::from_str(&serialize(&source, &command).unwrap()).unwrap();
    assert_eq!(request, json!({"id":7,"result":{"decision":"accept"}}));
    let core = &fixture.raw.daemon.core;
    let session = core.session_of_pane(fixture.raw.entry.pane.id).unwrap();
    let authz = crate::mp::Authz::owner(fixture.actor);
    core.mp.set_policy(
        core,
        &authz,
        session,
        proto::ApprovalPolicy {
            mode: proto::ApprovalMode::TwoPerson,
            ..proto::ApprovalPolicy::default()
        },
    );
    assert!(
        serialize(&source, &command).is_err(),
        "a policy changed during RPC initialize"
    );
    core.mp
        .set_policy(core, &authz, session, proto::ApprovalPolicy::default());
    command.signers[0].scope = proto::Scope::Pane(proto::PaneId(u64::MAX));
    assert!(
        serialize(&source, &command).is_err(),
        "the exact retained grant must cover this pane"
    );
    command.signers[0].scope = proto::Scope::Daemon;
    let mut witness = crate::mp::Authz::owner(Actor {
        principal: proto::PrincipalId([8; 16]),
        device: proto::DeviceId([8; 32]),
    });
    witness.roles = proto::Roles::APPROVER;
    command.signers.push(witness);
    assert!(
        serialize(&source, &command).is_err(),
        "an unpaired witness cannot contribute authority"
    );
    command.signers.pop();
    assert!(core.identity.unpair(fixture.actor.device));
    assert!(
        serialize(&source, &command).is_err(),
        "unpairing after admission retires the signed actor"
    );
    fixture.raw.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_deferred_rule_answer_requires_the_exact_unexpired_unrevoked_rule() {
    let fixture = Fixture::new().await;
    let source = Arc::downgrade(&fixture.source);
    let mut command = fixture.approval();
    let core = &fixture.raw.daemon.core;
    let mut rule = proto::AutoApproveRule {
        rule_id: proto::RuleId([3; 16]),
        pane_id: fixture.raw.entry.pane.id,
        request_id: None,
        matcher: proto::RuleMatch {
            tool: "Bash".into(),
            prefix: "printf".into(),
        },
        expires_at: proto::UnixMillis(crate::identity::now_millis() + 60_000),
        max_turns: 1,
        actor: fixture.actor,
        sig: Vec::new(),
    };
    // Synthetic already-admitted evidence: these tests exercise serialization, not signature verification.
    crate::approve::add_rule(core, rule.clone(), "fixture".into()).unwrap();
    command.rule = Some(rule.clone());
    assert!(serialize(&source, &command).is_ok());
    command.rule.as_mut().unwrap().matcher.prefix = "different".into();
    assert!(
        serialize(&source, &command).is_err(),
        "the same rule ID with different consent is not sufficient"
    );
    command.rule = Some(rule.clone());
    crate::approve::revoke(core, rule.rule_id, fixture.actor, "fixture").unwrap();
    assert!(
        serialize(&source, &command).is_err(),
        "revocation during RPC initialize retires the broad grant"
    );
    rule.expires_at = proto::UnixMillis(0);
    crate::approve::add_rule(core, rule.clone(), "expired fixture".into()).unwrap();
    command.rule = Some(rule);
    assert!(
        serialize(&source, &command).is_err(),
        "an expired grant cannot deliver a queued answer"
    );
    fixture.raw.daemon.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn terminal_resolution_retires_an_admitted_native_answer_before_serialization() {
    let fixture = Fixture::new().await;
    let source = Arc::downgrade(&fixture.source);
    let command = fixture.approval();
    assert!(serialize(&source, &command).is_ok());
    lock(&fixture.source.state).observe(&json!({"method":"serverRequest/resolved","params":{"threadId":command.binding.thread_id(),"requestId":7}}).to_string(), Direction::FromServer);
    assert!(serialize(&source, &command).is_err());
    fixture.raw.daemon.shutdown().await;
}
