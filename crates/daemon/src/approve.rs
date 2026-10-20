//! Approval extras (`proto::approve`, docs/DAEMON.md §6.9): auto-approve rules ("approve
//! all like this for this task") and approving with edited input.
//!
//! Rules live per pane, in memory only: a daemon restart ends them, as does the agent
//! session they were made in (it ends, restarts or changes id), the pane closing, their
//! expiry and their turn limit. A rule answers only requests a hook holds open (the answer
//! must reach the agent), always with the "allow once" option, as the person who made it,
//! and every answer is in the audit log with the rule's signature.

use std::collections::HashMap;
use std::sync::Mutex;

use proto::{
    ActiveRule, Actor, ApprovalAudit, ApprovalError, ApprovalInfo, ApprovalPush, AuditKind,
    AutoApproveRule, Decide, PaneId, RequestId, RuleId, UnixMillis,
};

use crate::core::{Core, Event, lock};
use crate::identity::now_millis;

/// The rules in force and the open requests' extras, per pane.
#[derive(Default)]
pub(crate) struct Approvals {
    rules: Mutex<HashMap<PaneId, Vec<ActiveRule>>>,
    open: Mutex<HashMap<PaneId, ApprovalInfo>>,
}

fn now() -> UnixMillis {
    UnixMillis(now_millis())
}

impl Approvals {
    /// The rules in force on `pane`, oldest first (expired ones dropped).
    pub fn rules(&self, pane: PaneId) -> Vec<ActiveRule> {
        let now = now();
        let mut rules = lock(&self.rules);
        let list = rules.entry(pane).or_default();
        list.retain(|r| r.rule.expires_at > now);
        let out = list.clone();
        if list.is_empty() {
            rules.remove(&pane);
        }
        out
    }

    /// Every pane with rules or an open request, for a connection that just arrived.
    pub fn snapshot(&self) -> (Vec<ApprovalInfo>, Vec<PaneId>) {
        let open = lock(&self.open).values().cloned().collect();
        let panes = lock(&self.rules).keys().copied().collect();
        (open, panes)
    }

    /// The request `pane` is no longer blocked on.
    pub fn clear_request(&self, pane: PaneId) {
        lock(&self.open).remove(&pane);
    }

    /// The pane closed.
    pub fn forget_pane(&self, pane: PaneId) {
        lock(&self.open).remove(&pane);
        lock(&self.rules).remove(&pane);
    }

    /// The pane of rule `id`, if it is in force.
    fn pane_of(&self, id: RuleId) -> Option<PaneId> {
        lock(&self.rules)
            .iter()
            .find(|(_, list)| list.iter().any(|r| r.rule.rule_id == id))
            .map(|(pane, _)| *pane)
    }
}

/// Tells clients `pane`'s rules.
fn emit_rules(core: &Core, pane: PaneId) {
    let rules = core.approvals.rules(pane);
    core.emit(Event::Approval(ApprovalPush::Rules {
        pane_id: pane,
        rules,
    }));
}

/// A hook now holds `pane`'s permission request open: answer it from a rule if one covers
/// it, else tell clients what they may do with it.
pub(crate) fn request_held(core: &Core, pane: PaneId) {
    let Some(held) = core.hooks.held(pane) else {
        return;
    };
    let Some((wire, _, allow)) = core
        .pane(pane)
        .and_then(|e| lock(&e.agent).as_mut().and_then(|rt| rt.blocked_wire()))
    else {
        return;
    };
    let input = held.command().unwrap_or_default().to_owned();
    if let Some(allow) = allow
        && auto_approve(core, pane, wire, allow, &held.tool, &input)
    {
        return;
    }
    let info = ApprovalInfo {
        pane_id: pane,
        request_id: wire,
        tool: held.tool.clone(),
        input: held.editable().map(str::to_owned),
        like: allow.and_then(|_| grants::like_this(&held.tool, &input)),
    };
    lock(&core.approvals.open).insert(pane, info.clone());
    core.emit(Event::Approval(ApprovalPush::Request(info)));
}

/// Answers request `wire` on `pane` with option `allow` if a rule covers `tool` + `input`.
fn auto_approve(
    core: &Core,
    pane: PaneId,
    wire: RequestId,
    allow: proto::OptionId,
    tool: &str,
    input: &str,
) -> bool {
    let now = now();
    let rule = {
        let mut rules = lock(&core.approvals.rules);
        let Some(list) = rules.get_mut(&pane) else {
            return false;
        };
        list.retain(|r| r.rule.expires_at > now);
        let Some(active) = list
            .iter_mut()
            .find(|r| grants::permits(&r.rule, pane, tool, input, now, r.turns_used))
        else {
            return false;
        };
        active.uses += 1;
        active.clone()
    };
    let decided = decide_by_rule(core, &rule, wire, allow);
    if !decided {
        // Not answered after all: give the use back.
        if let Some(r) = lock(&core.approvals.rules)
            .get_mut(&pane)
            .and_then(|l| l.iter_mut().find(|r| r.rule.rule_id == rule.rule.rule_id))
        {
            r.uses = r.uses.saturating_sub(1);
        }
    }
    emit_rules(core, pane);
    decided
}

/// Decides `wire` with `allow` as the rule's author, recording the rule in the audit log.
fn decide_by_rule(core: &Core, rule: &ActiveRule, wire: RequestId, allow: proto::OptionId) -> bool {
    let actor = rule.rule.actor;
    let signed = proto::auto_approve_signing_bytes(core.identity.daemon_id(), &rule.rule);
    let record = |decided: &proto::Decided, details: &crate::agent::DecidedRequest| {
        core.mp.audit.append(
            AuditKind::Approval,
            crate::mp::AuditEntry {
                actor: Some(actor),
                pane_id: Some(decided.pane_id),
                detail: format!(
                    "auto-approved {} by {}'s rule (allow all {})",
                    details.summary,
                    display_name(&rule.granted_by),
                    describe(&rule.rule.matcher)
                ),
                approval: Some(ApprovalAudit {
                    request_id: wire,
                    agent_request: details.request.to_string(),
                    option_id: allow,
                    option: details.option.clone(),
                    tool: details.tool.clone(),
                    summary: details.summary.clone(),
                    signed: signed.clone(),
                    sig: rule.rule.sig.clone(),
                }),
                ..crate::mp::AuditEntry::default()
            },
        );
    };
    let decide = Decide {
        request_id: wire,
        option_id: allow,
        actor,
        sig: rule.rule.sig.clone(),
    };
    let ok = core.decide(actor, &decide, record).is_ok();
    if ok {
        core.approvals.clear_request(rule.rule.pane_id);
    }
    ok
}

fn display_name(name: &str) -> &str {
    if name.is_empty() { "someone" } else { name }
}

/// "`cargo test` (Bash)" or "Edit".
pub(crate) fn describe(m: &proto::RuleMatch) -> String {
    if m.prefix.is_empty() {
        m.tool.clone()
    } else {
        format!("`{}` ({})", m.prefix, m.tool)
    }
}

/// An agent turn started on `pane`: rules count it and lapse past their limit.
pub(crate) fn turn_started(core: &Core, pane: PaneId) {
    {
        let mut rules = lock(&core.approvals.rules);
        let Some(list) = rules.get_mut(&pane) else {
            return;
        };
        for r in list.iter_mut() {
            r.turns_used += 1;
        }
        list.retain(|r| r.turns_used <= r.rule.max_turns);
    }
    // Clients show the turns left, so tell them even when no rule lapsed.
    emit_rules(core, pane);
}

/// The agent session on `pane` ended, restarted or changed: its rules end with it.
pub(crate) fn session_over(core: &Core, pane: PaneId) {
    let had = lock(&core.approvals.rules).remove(&pane).is_some();
    if had {
        emit_rules(core, pane);
    }
}

/// Adds `rule` for `granted_by` (already checked: role, actor, signature, bounds), then
/// approves the request it names if that request is open and covered.
pub(crate) fn add_rule(
    core: &Core,
    rule: AutoApproveRule,
    granted_by: String,
) -> Result<(), ApprovalError> {
    let pane = rule.pane_id;
    if !core.is_agent_pane(pane) {
        return Err(ApprovalError::NotFound);
    }
    let active = ActiveRule {
        rule,
        turns_used: 1,
        uses: 0,
        granted_by,
    };
    core.mp.audit.append(
        AuditKind::Approval,
        crate::mp::AuditEntry {
            actor: Some(active.rule.actor),
            pane_id: Some(pane),
            detail: format!(
                "{} allowed all {} for this task (until {} ms, {} turns)",
                display_name(&active.granted_by),
                describe(&active.rule.matcher),
                active.rule.expires_at,
                active.rule.max_turns
            ),
            ..crate::mp::AuditEntry::default()
        },
    );
    let request = active.rule.request_id;
    {
        let mut rules = lock(&core.approvals.rules);
        let list = rules.entry(pane).or_default();
        list.retain(|r| r.rule.rule_id != active.rule.rule_id);
        list.push(active);
    }
    // "Approve this and all like it": answer the open request now if the rule covers it.
    if let Some(request) = request
        && let Some(held) = core.hooks.held(pane)
        && let Some((wire, _, Some(allow))) = core
            .pane(pane)
            .and_then(|e| lock(&e.agent).as_mut().and_then(|rt| rt.blocked_wire()))
        && wire == request
    {
        let input = held.command().unwrap_or_default().to_owned();
        auto_approve(core, pane, wire, allow, &held.tool, &input);
    }
    emit_rules(core, pane);
    Ok(())
}

/// Revokes rule `id`; returns its pane. The caller checks the role on that pane first.
pub(crate) fn revoke(
    core: &Core,
    id: RuleId,
    by: Actor,
    name: &str,
) -> Result<PaneId, ApprovalError> {
    let pane = core.approvals.pane_of(id).ok_or(ApprovalError::NotFound)?;
    let removed = {
        let mut rules = lock(&core.approvals.rules);
        let list = rules.get_mut(&pane).ok_or(ApprovalError::NotFound)?;
        let at = list
            .iter()
            .position(|r| r.rule.rule_id == id)
            .ok_or(ApprovalError::NotFound)?;
        list.remove(at)
    };
    core.mp.audit.append(
        AuditKind::Revoked,
        crate::mp::AuditEntry {
            actor: Some(by),
            pane_id: Some(pane),
            detail: format!(
                "{} revoked {}'s rule (allow all {})",
                display_name(name),
                display_name(&removed.granted_by),
                describe(&removed.rule.matcher)
            ),
            ..crate::mp::AuditEntry::default()
        },
    );
    emit_rules(core, pane);
    Ok(pane)
}

/// The pane rule `id` is on, for the caller's role check.
pub(crate) fn rule_pane(core: &Core, id: RuleId) -> Option<PaneId> {
    core.approvals.pane_of(id)
}

/// The held request `wire` on `pane`, when it takes edited input: the agent's request id, the
/// original command and the option that allows it.
pub(crate) fn editable(
    core: &Core,
    pane: PaneId,
    wire: RequestId,
) -> Result<(String, proto::OptionId), ApprovalError> {
    let (current, request, allow) = core
        .pane(pane)
        .and_then(|e| lock(&e.agent).as_mut().and_then(|rt| rt.blocked_wire()))
        .ok_or(ApprovalError::NotFound)?;
    if current != wire {
        return Err(ApprovalError::NotFound);
    }
    let held = core
        .hooks
        .held(pane)
        .filter(|h| h.request == request)
        .ok_or(ApprovalError::NotEditable)?;
    let original = held
        .editable()
        .ok_or(ApprovalError::NotEditable)?
        .to_owned();
    let allow = allow.ok_or(ApprovalError::NotEditable)?;
    Ok((original, allow))
}
