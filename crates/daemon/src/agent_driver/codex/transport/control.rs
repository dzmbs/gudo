use super::{Live, rpc};
use crate::agent_driver::{
    ApprovalAuthority, ApprovalDecision, PendingApproval, SendAcknowledgement, UnconfirmedSend,
};
use crate::core::lock;
use agents::{ApprovalChoice, CodexRpcId, CodexThreadBinding};
use futures_util::SinkExt;
use proto::{Actor, WsError};
use serde_json::{Value, json};
use std::io;
use std::sync::Weak;
use tokio::sync::mpsc;
use tokio_websockets::Message;

#[cfg(test)]
mod tests;

pub(in crate::agent_driver::codex) type Sender = mpsc::Sender<Command>;

pub(in crate::agent_driver::codex) struct Command {
    binding: CodexThreadBinding,
    turn: Option<String>,
    revision: u64,
    actor: Actor,
    action: Action,
    acknowledgement: Option<SendAcknowledgement>,
    deadline: tokio::time::Instant,
    policy: Option<proto::ApprovalPolicy>,
    signers: Vec<crate::mp::Authz>,
    rule: Option<proto::AutoApproveRule>,
}

enum Action {
    Send(String),
    Stop,
    Approve {
        request: CodexRpcId,
        common: agents::RequestId,
        choice: ApprovalChoice,
    },
}

impl Drop for Command {
    fn drop(&mut self) {
        if let Some(acknowledgement) = self.acknowledgement.take() {
            let _ = acknowledgement
                .receipt
                .send(crate::agent_input::Receipt::NotConfirmed);
        }
    }
}

impl Live {
    pub(crate) fn control_failed(self: &std::sync::Arc<Self>) {
        let effects = {
            let mut state = lock(&self.state);
            state.fail();
            std::mem::take(&mut state.effects)
        };
        self.publish(effects);
    }

    pub(crate) fn send_prompt(
        &self,
        session: Option<&str>,
        text: &str,
        acknowledgement: SendAcknowledgement,
    ) -> Result<UnconfirmedSend, WsError> {
        let command = self.command(
            session,
            acknowledgement.revision,
            acknowledgement.actor,
            Action::Send(text.to_owned()),
            Some(acknowledgement),
        )?;
        self.enqueue(command)?;
        Ok(UnconfirmedSend::NotConfirmed)
    }

    pub(crate) fn interrupt(
        &self,
        session: Option<&str>,
        revision: u64,
        actor: Actor,
    ) -> Result<(), WsError> {
        let command = self.command(session, revision, actor, Action::Stop, None)?;
        if command.turn.is_none() {
            return Err(unavailable());
        }
        self.enqueue(command)
    }

    pub(crate) fn pending_approval(&self) -> Option<PendingApproval> {
        let runtime = lock(&self.runtime);
        let pending = runtime.pending.first()?;
        if pending.admitted {
            return None;
        }
        Some(PendingApproval {
            request: pending.common.clone()?,
            tool: pending.tool().into(),
            command: pending.details.command.clone(),
            editable: None,
        })
    }

    pub(crate) fn approval_pending(&self, request: &agents::RequestId) -> bool {
        lock(&self.runtime)
            .pending
            .first()
            .is_some_and(|pending| pending.common.as_ref() == Some(request) && !pending.admitted)
    }

    pub(crate) fn approve(
        &self,
        request: &agents::RequestId,
        decision: ApprovalDecision<'_>,
        authority: ApprovalAuthority,
    ) -> bool {
        let ApprovalDecision::Choice(choice @ (ApprovalChoice::AllowOnce | ApprovalChoice::Deny)) =
            decision
        else {
            return false;
        };
        let Some(owner) = self.owner.borrow().clone() else {
            return false;
        };
        let Some(entry) = owner.entry.upgrade() else {
            return false;
        };
        if authority.signers.is_empty() || authority.signers[0].actor != authority.actor {
            return false;
        }
        let gate = lock(&entry.pane.agent_input_gate);
        let Some(revision) = gate.control_revision() else {
            return false;
        };
        let mut runtime = lock(&self.runtime);
        let Some(pending) = runtime
            .pending
            .first_mut()
            .filter(|pending| pending.common.as_ref() == Some(request) && !pending.admitted)
        else {
            return false;
        };
        let action = Action::Approve {
            request: pending.id.clone(),
            common: request.clone(),
            choice,
        };
        let Ok(mut command) = self.command(None, revision, authority.actor, action, None) else {
            return false;
        };
        command.policy = Some(authority.policy);
        command.signers = authority.signers;
        command.rule = authority.rule;
        if self.enqueue(command).is_err() {
            return false;
        }
        pending.admitted = true;
        true
    }

    fn command(
        &self,
        session: Option<&str>,
        revision: u64,
        actor: Actor,
        action: Action,
        acknowledgement: Option<SendAcknowledgement>,
    ) -> Result<Command, WsError> {
        let state = lock(&self.state);
        if !state.is_ready() || self.fault.load(std::sync::atomic::Ordering::Acquire) {
            return Err(unavailable());
        }
        let binding = state.current.clone().ok_or_else(unavailable)?;
        if session.is_some_and(|session| session != binding.thread_id()) {
            return Err(unavailable());
        }
        Ok(Command {
            binding,
            turn: state
                .events
                .as_ref()
                .and_then(|events| events.active_turn().map(str::to_owned)),
            revision,
            actor,
            action,
            acknowledgement,
            deadline: tokio::time::Instant::now() + std::time::Duration::from_secs(4),
            policy: None,
            signers: Vec::new(),
            rule: None,
        })
    }

    fn enqueue(&self, command: Command) -> Result<(), WsError> {
        lock(&self.controls)
            .as_ref()
            .ok_or_else(unavailable)?
            .try_send(command)
            .map_err(|_| unavailable())
    }
}

pub(super) async fn run(source: Weak<Live>, mut receiver: mpsc::Receiver<Command>) {
    while let Some(mut command) = receiver.recv().await {
        let result = tokio::time::timeout_at(command.deadline, execute(&source, &command)).await;
        if !matches!(result, Ok(Ok(())))
            && matches!(command.action, Action::Approve { .. })
            && let Some(source) = source.upgrade()
        {
            source.control_failed();
        }
        if matches!(result, Ok(Ok(())))
            && let Some(acknowledgement) = command.acknowledgement.take()
        {
            let _ = acknowledgement
                .receipt
                .send(crate::agent_input::Receipt::Confirmed);
        }
    }
}

async fn execute(source: &Weak<Live>, command: &Command) -> io::Result<()> {
    let (path, server) = {
        let source = source
            .upgrade()
            .ok_or_else(|| io::Error::other("Codex source ended"))?;
        let server = lock(&source.process)
            .as_ref()
            .and_then(tokio::process::Child::id)
            .ok_or_else(|| io::Error::other("Codex server ended"))?;
        (source.directory.join("server.sock"), server)
    };
    let mut connection = rpc::connect(&path, server).await?;
    let request = serialize(source, command)?;
    connection
        .send(Message::text(request))
        .await
        .map_err(io::Error::other)?;
    if matches!(command.action, Action::Approve { .. }) {
        return Ok(());
    }
    let reply = rpc::reply(&mut connection, 2).await?;
    let reply: Value = serde_json::from_str(&reply).map_err(io::Error::other)?;
    match &command.action {
        Action::Send(_) => {
            let turn = if command.turn.is_some() {
                reply["result"]["turnId"].as_str()
            } else {
                reply["result"]["turn"]["id"].as_str()
            };
            if turn.is_none_or(|turn| {
                turn.is_empty()
                    || turn.len() > 128
                    || command
                        .turn
                        .as_deref()
                        .is_some_and(|expected| expected != turn)
            }) {
                return Err(io::Error::other("invalid Codex turn receipt"));
            }
        }
        Action::Stop => {
            if !reply["result"].is_object() {
                return Err(io::Error::other("invalid Codex interrupt receipt"));
            }
        }
        Action::Approve { .. } => {}
    }
    let source = source
        .upgrade()
        .ok_or_else(|| io::Error::other("Codex source ended"))?;
    let (core, _) = source
        .target()
        .ok_or_else(|| io::Error::other("Codex pane changed"))?;
    if !core.identity.is_owner_device(command.actor.device)
        || !lock(&source.state).binding.is_current(&command.binding)
    {
        return Err(io::Error::other("Codex binding changed"));
    }
    Ok(())
}

fn serialize(source: &Weak<Live>, command: &Command) -> io::Result<String> {
    let source = source
        .upgrade()
        .ok_or_else(|| io::Error::other("Codex source ended"))?;
    let (core, entry) = source
        .target()
        .ok_or_else(|| io::Error::other("Codex pane changed"))?;
    let gate = lock(&entry.pane.agent_input_gate);
    if gate.control_revision() != Some(command.revision) || !core.agent_has_terminal(entry.pane.id)
    {
        return Err(io::Error::other("Codex input fence changed"));
    }
    let state = lock(&source.state);
    if !state.is_ready() || !state.binding.is_current(&command.binding) {
        return Err(io::Error::other("Codex binding changed"));
    }
    let events = state
        .events
        .as_ref()
        .ok_or_else(|| io::Error::other("Codex events unavailable"))?;
    if events.active_turn() != command.turn.as_deref() {
        return Err(io::Error::other("Codex turn changed"));
    }
    let thread = command.binding.thread_id();
    let request = match &command.action {
        Action::Send(text) => {
            if !core.identity.is_owner_device(command.actor.device) || events.has_pending_approval()
            {
                return Err(io::Error::other("Codex prompt is not authorized"));
            }
            let input = json!([{"type":"text","text":text,"text_elements":[]}]);
            if let Some(turn) = &command.turn {
                json!({"id":2,"method":"turn/steer","params":{"threadId":thread,"expectedTurnId":turn,"input":input}})
            } else {
                json!({"id":2,"method":"turn/start","params":{"threadId":thread,"input":input}})
            }
        }
        Action::Stop => {
            if !core.identity.is_owner_device(command.actor.device) || events.has_pending_approval()
            {
                return Err(io::Error::other("Codex interrupt is not authorized"));
            }
            json!({"id":2,"method":"turn/interrupt","params":{"threadId":thread,"turnId":command.turn}})
        }
        Action::Approve {
            request,
            common,
            choice,
        } => {
            let runtime = lock(&source.runtime);
            let pending = runtime
                .pending
                .first()
                .filter(|pending| {
                    pending.common.as_ref() == Some(common)
                        && pending.id == *request
                        && pending.admitted
                })
                .ok_or_else(|| io::Error::other("Codex approval changed"))?;
            if !events.approval_pending(request)
                || command.policy != Some(core.mp.policy_of_pane(&core, entry.pane.id))
                || command.signers.is_empty()
                || command.rule.as_ref().is_some_and(|rule| {
                    !core
                        .approvals
                        .rules(entry.pane.id)
                        .iter()
                        .any(|active| active.rule == *rule)
                })
                || command.signers.iter().any(|signer| {
                    !core.mp.still_valid(signer)
                        || crate::mp::policy::check(
                            &core,
                            signer,
                            crate::mp::Need::Approve,
                            crate::mp::Target::Pane(entry.pane.id),
                        )
                        .is_err()
                })
            {
                return Err(io::Error::other("Codex approval policy changed"));
            }
            let decision = if *choice == ApprovalChoice::AllowOnce {
                "accept"
            } else {
                pending
                    .details
                    .denial()
                    .ok_or_else(|| io::Error::other("Codex denial unavailable"))?
            };
            if !pending.details.offers(decision) {
                return Err(io::Error::other("Codex decision is not offered"));
            }
            json!({"id":request,"result":{"decision":decision}})
        }
    };
    let request = request.to_string();
    if request.len() > 60 * 1024 {
        return Err(io::Error::other(
            "Codex control exceeds the observation budget",
        ));
    }
    Ok(request)
}

fn unavailable() -> WsError {
    WsError::Unavailable("Codex control is unavailable. Check Terminal.".into())
}
