//! Approval extras (`proto::approve`, docs/DAEMON.md §6.10): auto-approve rules ("approve
//! all like this for this task") and approving with edited input.
//!
//! Rules live per pane, in memory only: a daemon restart ends them, as does the agent
//! session they were made in (it ends, restarts or changes id), the pane closing, their
//! expiry and their turn limit. A rule answers only a live request the adapter can deliver to,
//! always with the "allow once" option, as the person who made it, and only while that person
//! still holds Approver on the pane and the session's approval policy would let them allow the
//! call alone. Revoking the person ends their rules. Every answer is in the audit log with the
//! rule's signature.

use std::collections::HashMap;
use std::sync::Mutex;

use proto::{
    ActiveRule, Actor, ApprovalAudit, ApprovalError, ApprovalInfo, ApprovalPush, AuditKind,
    AutoApproveRule, Decide, PaneId, RequestId, RuleId, UnixMillis,
};

use crate::core::{Core, Event, lock};
use crate::identity::now_millis;
use crate::mp::{Authz, Need, Target};

/// A rule in force and the grant of the person who made it, rechecked each time it answers.
#[derive(Clone)]
struct HeldRule {
    active: ActiveRule,
    author: Authz,
}

/// The rules in force and the open requests' extras, per pane.
#[derive(Default)]
pub(crate) struct Approvals {
    rules: Mutex<HashMap<PaneId, Vec<HeldRule>>>,
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
        list.retain(|held| held.active.rule.expires_at > now);
        let in_force = list.iter().map(|held| held.active.clone()).collect();
        if list.is_empty() {
            rules.remove(&pane);
        }
        in_force
    }

    /// Every pane with rules or an open request, for a connection that just arrived.
    pub fn snapshot(&self) -> (Vec<ApprovalInfo>, Vec<PaneId>) {
        let open = lock(&self.open).values().cloned().collect();
        let panes = lock(&self.rules).keys().copied().collect();
        (open, panes)
    }

    pub fn clear_request(&self, pane: PaneId) {
        lock(&self.open).remove(&pane);
    }

    pub fn forget_pane(&self, pane: PaneId) {
        lock(&self.open).remove(&pane);
        lock(&self.rules).remove(&pane);
    }

    fn pane_of(&self, id: RuleId) -> Option<PaneId> {
        lock(&self.rules)
            .iter()
            .find(|(_, list)| list.iter().any(|held| held.active.rule.rule_id == id))
            .map(|(pane, _)| *pane)
    }

    /// Drops the rules whose author fails `keeps`; returns the panes that lost one.
    fn drop_authors(&self, keeps: impl Fn(&Authz) -> bool) -> Vec<PaneId> {
        let mut rules = lock(&self.rules);
        let mut changed = Vec::new();
        for (pane, list) in rules.iter_mut() {
            let before = list.len();
            list.retain(|held| keeps(&held.author));
            if list.len() != before {
                changed.push(*pane);
            }
        }
        rules.retain(|_, list| !list.is_empty());
        changed
    }
}

fn emit_rules(core: &Core, pane: PaneId) {
    let rules = core.approvals.rules(pane);
    core.emit(Event::Approval(ApprovalPush::Rules {
        pane_id: pane,
        rules,
    }));
}

/// Answers a live permission request from a matching rule, or publishes its available actions.
pub(crate) fn request_held(core: &Core, pane: PaneId) {
    let Some(held) = crate::agent_driver::pending_approval(core, pane) else {
        return;
    };
    let Some((wire, _, allow)) = core.pane(pane).and_then(|entry| {
        lock(&entry.agent)
            .as_mut()
            .and_then(|agent| agent.blocked_wire())
    }) else {
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
    drop_revoked(core);
    let rule = {
        let mut rules = lock(&core.approvals.rules);
        let Some(list) = rules.get_mut(&pane) else {
            return false;
        };
        list.retain(|held| held.active.rule.expires_at > now);
        let Some(held) = list.iter_mut().find(|held| {
            let active = &held.active;
            grants::permits(&active.rule, pane, tool, input, now, active.turns_used)
        }) else {
            return false;
        };
        held.active.uses += 1;
        held.clone()
    };
    let decided = author_may_allow(core, &rule.author, pane, wire, tool)
        && decide_by_rule(core, &rule.active, wire, allow);
    if !decided {
        // Not answered after all: give the use back.
        if let Some(held) = lock(&core.approvals.rules).get_mut(&pane).and_then(|list| {
            list.iter_mut()
                .find(|held| held.active.rule.rule_id == rule.active.rule.rule_id)
        }) {
            held.active.uses = held.active.uses.saturating_sub(1);
        }
    }
    emit_rules(core, pane);
    decided
}

/// Whether the rule's author could allow `tool` on `pane` alone right now: their grant still
/// holds Approver there and the session's approval policy, as it is now, lets them.
fn author_may_allow(
    core: &Core,
    author: &Authz,
    pane: PaneId,
    request: RequestId,
    tool: &str,
) -> bool {
    let ballot = crate::mp::approvals::Ballot {
        actor: author.actor,
        name: &author.name,
        owner: author.is_owner_device(core),
        authorization: Some(author),
    };
    crate::mp::policy::check(core, author, Need::Approve, Target::Pane(pane)).is_ok()
        && crate::mp::gate_allow_alone(
            core,
            ballot,
            pane,
            Some(request),
            tool,
            "auto-approve with a rule",
        )
        .is_ok()
}

/// Ends the rules of everyone whose grant was revoked or expired, or whose device was removed.
pub(crate) fn drop_revoked(core: &Core) {
    for pane in core
        .approvals
        .drop_authors(|author| core.mp.still_valid(author))
    {
        emit_rules(core, pane);
    }
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
    let decided = core
        .decide_authorized(
            actor,
            &decide,
            None,
            Some(crate::agent_driver::ApprovalEvidence::Rule(rule)),
            record,
        )
        .is_ok();
    if decided {
        core.approvals.clear_request(rule.rule.pane_id);
    }
    decided
}

fn display_name(name: &str) -> &str {
    if name.is_empty() { "someone" } else { name }
}

/// "`cargo test` (Bash)" or "Edit".
pub(crate) fn describe(matcher: &proto::RuleMatch) -> String {
    if matcher.prefix.is_empty() {
        matcher.tool.clone()
    } else {
        format!("`{}` ({})", matcher.prefix, matcher.tool)
    }
}

/// An agent turn started on `pane`: rules count it and lapse past their limit.
pub(crate) fn turn_started(core: &Core, pane: PaneId) {
    {
        let mut rules = lock(&core.approvals.rules);
        let Some(list) = rules.get_mut(&pane) else {
            return;
        };
        for held in list.iter_mut() {
            held.active.turns_used += 1;
        }
        list.retain(|held| held.active.turns_used <= held.active.rule.max_turns);
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

/// Adds `rule` for `author`, named `granted_by` (already checked: role, actor, signature,
/// bounds, policy), then approves the request it names if that request is open and covered.
pub(crate) fn add_rule(
    core: &Core,
    rule: AutoApproveRule,
    granted_by: String,
    author: Authz,
) -> Result<(), ApprovalError> {
    let pane = rule.pane_id;
    if !core.is_agent_pane(pane) {
        return Err(ApprovalError::NotFound);
    }
    // A native Codex answer is delivered later and must carry its author's grant; only the
    // owner's is held for the life of a rule.
    if core
        .pane(pane)
        .is_some_and(|entry| lock(&entry.codex).is_some())
        && !core.identity.is_owner_device(rule.actor.device)
    {
        return Err(ApprovalError::Forbidden(
            "only the owner can allow all on this Codex pane".into(),
        ));
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
        list.retain(|existing| existing.active.rule.rule_id != active.rule.rule_id);
        list.push(HeldRule { active, author });
    }
    // "Approve this and all like it": answer the open request now if the rule covers it.
    if let Some(request) = request
        && let Some(held) = crate::agent_driver::pending_approval(core, pane)
        && let Some((wire, _, Some(allow))) = core.pane(pane).and_then(|entry| {
            lock(&entry.agent)
                .as_mut()
                .and_then(|agent| agent.blocked_wire())
        })
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
            .position(|held| held.active.rule.rule_id == id)
            .ok_or(ApprovalError::NotFound)?;
        list.remove(at).active
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

/// A held request that takes edited input.
pub(crate) struct Editable {
    pub tool: String,
    pub original: String,
    pub allow: proto::OptionId,
}

/// The held request `wire` on `pane`, when it takes edited input.
pub(crate) fn editable(
    core: &Core,
    pane: PaneId,
    wire: RequestId,
) -> Result<Editable, ApprovalError> {
    let (current, request, allow) = core
        .pane(pane)
        .and_then(|entry| {
            lock(&entry.agent)
                .as_mut()
                .and_then(|agent| agent.blocked_wire())
        })
        .ok_or(ApprovalError::NotFound)?;
    if current != wire {
        return Err(ApprovalError::NotFound);
    }
    let held = crate::agent_driver::pending_approval(core, pane)
        .filter(|held| held.request == request)
        .ok_or(ApprovalError::NotEditable)?;
    let original = held
        .editable()
        .ok_or(ApprovalError::NotEditable)?
        .to_owned();
    let allow = allow.ok_or(ApprovalError::NotEditable)?;
    Ok(Editable {
        tool: held.tool,
        original,
        allow,
    })
}
