use super::*;
use crate::core::PaneEntry;

pub(super) async fn stop(client: &client_core::Client, entry: &PaneEntry) -> Result<(), String> {
    let pane = entry.pane.id;
    let proto::ChatSendStatus::Prepared {
        ticket, revision, ..
    } = client
        .chat_interrupt_prepare(pane)
        .await
        .map_err(|error| format!("stop prepare: {error:?}"))?
    else {
        return Err("no stop ticket".into());
    };
    let status = client
        .chat_interrupt(pane, ticket, Some(revision))
        .await
        .map_err(|error| format!("stop: {error:?}"))?;
    if status != proto::ChatSendStatus::InterruptRequested {
        return Err(format!("wrong stop status: {status:?}"));
    }
    crate::agent_input::chat_tests::wait_until(|| lock(&entry.meta).turns == 1).await;
    if lock(&entry.meta).last_turn.as_ref().unwrap().outcome != agents::TurnOutcome::Cancelled {
        return Err("interrupt did not end the exact turn".into());
    }
    Ok(())
}

pub(super) async fn approval(
    daemon: &crate::Daemon,
    client: &client_core::Client,
    entry: &PaneEntry,
    source: &Live,
    root: &Path,
    scenario: &str,
) -> Result<(), String> {
    crate::agent_input::chat_tests::wait_until(|| {
        lock(&entry.agent).as_ref().unwrap().is_blocked()
    })
    .await;
    let detail = lock(&entry.agent)
        .as_mut()
        .unwrap()
        .blocked_detail()
        .unwrap();
    if matches!(scenario, "file-approve" | "rule-approve") {
        if lock(&source.runtime)
            .pending
            .first()
            .is_none_or(|pending| pending.kind != agents::CodexApprovalKind::FileChange)
        {
            return Err("fixture did not produce an actual file-change approval".into());
        }
        crate::agent_input::chat_tests::wait_until(|| {
            let screen = entry.pane.screen_text();
            screen.contains("Would you like to make") && screen.contains("approved.txt")
        })
        .await;
        std::fs::write(
            root.join("file-approval-screen.txt"),
            entry.pane.screen_text(),
        )
        .map_err(|error| error.to_string())?;
    }
    std::fs::write(root.join("approval-summary.txt"), &detail.summary)
        .map_err(|error| error.to_string())?;
    let choice = if matches!(
        scenario,
        "approve" | "two-person" | "file-approve" | "rule-approve"
    ) {
        agents::ApprovalChoice::AllowOnce
    } else {
        agents::ApprovalChoice::Deny
    };
    let index = detail
        .options
        .iter()
        .position(|(_, offered)| *offered == choice)
        .ok_or_else(|| {
            format!(
                "missing native choice in {:?}: {}",
                detail.options, detail.summary
            )
        })?;
    let marker = root.join("project/approved.txt");
    if marker.exists() {
        return Err("command ran before signed consent".into());
    }
    if client.chat_prepare(entry.pane.id).await.is_ok() {
        return Err("approval allowed a Send bypass".into());
    }
    if scenario == "terminal-race" {
        crate::agent_input::chat_tests::wait_until(|| {
            entry.pane.screen_text().contains("Would you like to run")
        })
        .await;
        std::fs::write(root.join("approval-screen.txt"), entry.pane.screen_text())
            .map_err(|error| error.to_string())?;
        entry
            .pane
            .write(vec![0x03])
            .await
            .map_err(|error| error.to_string())?;
        tokio::time::timeout(Duration::from_secs(10), async {
            while lock(&entry.agent).as_ref().unwrap().is_blocked() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .map_err(|_| {
            let _ = std::fs::write(
                root.join("approval-after-terminal-choice.txt"),
                entry.pane.screen_text(),
            );
            "Terminal cancellation did not resolve the native approval".to_owned()
        })?;
    }
    let option = proto::OptionId(index as u32);
    if scenario == "two-person" {
        two_person(daemon, client, entry, detail.wire, option, &marker).await?;
    } else if scenario == "rule-approve" {
        let pending = source.pending_approval().ok_or("missing rule target")?;
        let matcher = grants::like_this(&pending.tool, pending.command().unwrap_or_default())
            .ok_or("request cannot safely support a rule")?;
        client
            .add_auto_approve(
                entry.pane.id,
                Some(detail.wire),
                matcher,
                Duration::from_secs(60),
                1,
            )
            .await
            .map_err(|error| format!("native signed rule: {error:?}"))?;
    } else {
        client.decide(detail.wire, option);
        client.decide(detail.wire, option);
    }
    if matches!(
        scenario,
        "approve" | "two-person" | "file-approve" | "rule-approve"
    ) {
        crate::agent_input::chat_tests::wait_until(|| marker.exists()).await;
        crate::agent_input::chat_tests::wait_until(|| lock(&source.runtime).pending.is_empty())
            .await;
        let expected = if matches!(scenario, "file-approve" | "rule-approve") {
            "approved\n"
        } else {
            "approved"
        };
        if std::fs::read_to_string(&marker).map_err(|error| error.to_string())? != expected {
            return Err("signed command did not execute once".into());
        }
    } else {
        crate::agent_input::chat_tests::wait_until(|| lock(&entry.meta).turns == 1).await;
        if marker.exists() {
            return Err("denied or obsolete decision executed a command".into());
        }
        if lock(&entry.meta).last_turn.as_ref().unwrap().outcome != agents::TurnOutcome::Cancelled {
            return Err("denial did not cancel this turn".into());
        }
    }
    Ok(())
}

const DRAFT: &str = "unsent-terminal-draft";

pub(super) async fn draft(entry: &PaneEntry) -> Result<(), String> {
    entry
        .pane
        .write(format!("\x1b[200~{DRAFT}\x1b[201~").into_bytes())
        .await
        .map_err(|error| error.to_string())?;
    crate::agent_input::chat_tests::wait_until(|| entry.pane.screen_text().contains(DRAFT)).await;
    Ok(())
}

pub(super) fn check_draft(entry: &PaneEntry, source: &Live, root: &Path) -> Result<(), String> {
    let screen = entry.pane.screen_text();
    std::fs::write(root.join("terminal-draft-after-send.txt"), &screen)
        .map_err(|error| error.to_string())?;
    if !screen.contains(DRAFT) {
        return Err("the official TUI did not preserve the unrelated Terminal draft".into());
    }
    let snapshot = lock(&source.state).projection.snapshot(60, None);
    if !snapshot.items.iter().any(|item| matches!(&item.body, proto::TimelineBody::User { text, .. } if text == "Reply with a short fixture sentence.")) || snapshot.items.iter().any(|item| matches!(&item.body, proto::TimelineBody::User { text, .. } if text.contains(DRAFT))) {
        return Err("native Send submitted a different prompt or the unrelated Terminal draft".into());
    }
    Ok(())
}

async fn two_person(
    daemon: &crate::Daemon,
    first: &client_core::Client,
    entry: &PaneEntry,
    request: proto::RequestId,
    option: proto::OptionId,
    marker: &Path,
) -> Result<(), String> {
    let core = &daemon.core;
    let paired = core.identity.paired().remove(0);
    let actor = proto::Actor {
        principal: paired.principal,
        device: paired.device,
    };
    core.mp.set_policy(
        core,
        &crate::mp::Authz::owner(actor),
        core.session_of_pane(entry.pane.id).unwrap(),
        proto::ApprovalPolicy {
            mode: proto::ApprovalMode::TwoPerson,
            ..proto::ApprovalPolicy::default()
        },
    );
    first.decide(request, option);
    first.decide(request, option);
    crate::agent_input::chat_tests::wait_until(|| {
        core.mp
            .approvals
            .all(|pane| core.mp.policy_of_pane(core, pane))
            .iter()
            .any(|status| status.request_id == request && status.approvals.len() == 1)
    })
    .await;
    if marker.exists() {
        return Err("the first signature bypassed the two-person policy".into());
    }
    let (second, _events) = approver(first, entry.pane.id).await?;
    second.decide(request, option);
    second.decide(request, option);
    crate::agent_input::chat_tests::wait_until(|| marker.exists()).await;
    Ok(())
}

async fn approver(
    owner: &client_core::Client,
    pane: proto::PaneId,
) -> Result<
    (
        Arc<client_core::Client>,
        tokio::sync::mpsc::UnboundedReceiver<client_core::ClientEvent>,
    ),
    String,
> {
    let mut spec = client_core::GrantSpec::new(proto::Roles::APPROVER, proto::Scope::Pane(pane));
    spec.label = "Private Codex fixture approver".into();
    let terms = proto::InviteTerms::default();
    let invite = owner
        .create_invite_with_terms(spec, "fixture".into(), terms)
        .await
        .map_err(|error| format!("private invite: {error:?}"))?
        .to_string_with_terms(terms);
    let (listener, mut events) = client_core::EventQueue::channel();
    let mut config = client_core::ClientConfig::new(client_core::ClientConfig::generate_key());
    config.relay = client_core::RelayMode::Disabled;
    let client = Arc::new(
        client_core::Client::join_on(
            &tokio::runtime::Handle::current(),
            &invite,
            config,
            listener,
        )
        .map_err(|error| format!("private approver: {error:?}"))?,
    );
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(event) = events.recv().await {
            if matches!(event, client_core::ClientEvent::Connected { .. }) {
                return Ok(());
            }
        }
        Err("private approver closed".to_owned())
    })
    .await
    .map_err(|_| "private approver timed out".to_owned())??;
    Ok((client, events))
}
