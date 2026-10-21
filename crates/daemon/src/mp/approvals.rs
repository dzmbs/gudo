//! call a non-owner may allow, the two-person rule and claims. The policies live in the grant
//! store; the votes and claims of open requests live here, in memory, until the request is
//! decided or goes away.
//!
//! [`rule`] is the whole decision table and is pure, so it is tested without a daemon.

use std::collections::HashMap;
use std::sync::Mutex;

use proto::{
    Actor, ApprovalMode, ApprovalPolicy, ApprovalStatus, ApprovalVote, MpError, PaneId, RequestId,
    Risk, UnixMillis,
};

use crate::core::lock;
use crate::identity::now_millis;

/// Someone answering or claiming a request.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Ballot<'a> {
    pub actor: Actor,
    pub name: &'a str,
    /// A paired owner device on the whole daemon: not held back by `max_risk`, may answer
    /// under `OwnerOnly` and over someone else's claim.
    pub owner: bool,
}

impl Ballot<'_> {
    fn vote(&self) -> ApprovalVote {
        ApprovalVote {
            actor: self.actor,
            name: self.name.to_owned(),
            at: UnixMillis(now_millis()),
        }
    }
}

/// What to do with a decision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// Apply it: the agent gets the answer.
    Decide,
    /// It was counted, and the request now waits for a second person (two-person rule).
    Held(ApprovalStatus),
}

/// The votes and claim of one open request.
#[derive(Debug, Clone)]
struct Open {
    pane: PaneId,
    risk: Risk,
    approvals: Vec<ApprovalVote>,
    claimed: Option<ApprovalVote>,
}

impl Open {
    fn status(&self, request: RequestId, policy: ApprovalPolicy) -> ApprovalStatus {
        ApprovalStatus {
            pane_id: self.pane,
            request_id: request,
            risk: self.risk,
            mode: policy.mode,
            approvals: self.approvals.clone(),
            needed: needed(policy, self.risk),
            claimed_by: self.claimed.clone(),
        }
    }
}

/// Distinct approvals an "allow" needs.
fn needed(policy: ApprovalPolicy, risk: Risk) -> u8 {
    if policy.mode == ApprovalMode::TwoPerson && risk == Risk::Any {
        2
    } else {
        1
    }
}

/// Open requests' votes and claims.
#[derive(Debug, Default)]
pub(crate) struct Approvals {
    open: Mutex<HashMap<RequestId, Open>>,
}

impl Approvals {
    /// Judges a decision on `request` under `policy`; records the vote when it is held.
    ///
    /// # Errors
    ///
    /// [`MpError::Forbidden`] or [`MpError::Conflict`] with the reason in words.
    pub fn judge(
        &self,
        policy: ApprovalPolicy,
        pane: PaneId,
        request: RequestId,
        risk: Risk,
        allow: bool,
        ballot: Ballot<'_>,
    ) -> Result<Verdict, MpError> {
        let mut open = lock(&self.open);
        let entry = open.entry(request).or_insert_with(|| Open {
            pane,
            risk,
            approvals: Vec::new(),
            claimed: None,
        });
        let verdict = rule(policy, entry, allow, ballot)?;
        if verdict == Outcome::Hold {
            entry.approvals.push(ballot.vote());
            return Ok(Verdict::Held(entry.status(request, policy)));
        }
        Ok(Verdict::Decide)
    }

    /// Claims `request` for `ballot`'s principal, or releases a claim.
    ///
    /// # Errors
    ///
    /// [`MpError::Conflict`] when someone else holds the claim (owners may take it over or
    /// release it), [`MpError::Forbidden`] under `OwnerOnly` for non-owners.
    pub fn claim(
        &self,
        policy: ApprovalPolicy,
        pane: PaneId,
        request: RequestId,
        risk: Risk,
        ballot: Ballot<'_>,
        claim: bool,
    ) -> Result<ApprovalStatus, MpError> {
        if policy.mode == ApprovalMode::OwnerOnly && !ballot.owner {
            return Err(MpError::Forbidden(
                "only the owner answers approvals in this session".into(),
            ));
        }
        let mut open = lock(&self.open);
        let entry = open.entry(request).or_insert_with(|| Open {
            pane,
            risk,
            approvals: Vec::new(),
            claimed: None,
        });
        let theirs = entry
            .claimed
            .as_ref()
            .filter(|c| c.actor.principal != ballot.actor.principal);
        if let Some(other) = theirs
            && !ballot.owner
        {
            return Err(MpError::Conflict(format!(
                "{} claimed this request",
                other.name
            )));
        }
        entry.claimed = claim.then(|| ballot.vote());
        Ok(entry.status(request, policy))
    }

    /// Starts tracking a request the agent just blocked on; returns its state when it is new.
    pub fn open(
        &self,
        policy: ApprovalPolicy,
        pane: PaneId,
        request: RequestId,
        risk: Risk,
    ) -> Option<ApprovalStatus> {
        let mut open = lock(&self.open);
        if open.contains_key(&request) {
            return None;
        }
        let entry = open.entry(request).or_insert(Open {
            pane,
            risk,
            approvals: Vec::new(),
            claimed: None,
        });
        Some(entry.status(request, policy))
    }

    /// Every open request, for a client that just attached.
    pub fn all(&self, policy_of: impl Fn(PaneId) -> ApprovalPolicy) -> Vec<ApprovalStatus> {
        lock(&self.open)
            .iter()
            .map(|(id, o)| o.status(*id, policy_of(o.pane)))
            .collect()
    }

    /// Who claimed an open request on `pane`, if anyone (screen answers have no request id).
    pub fn claimant_on(&self, pane: PaneId) -> Option<ApprovalVote> {
        lock(&self.open)
            .values()
            .filter(|o| o.pane == pane)
            .find_map(|o| o.claimed.clone())
    }

    /// The request was decided or went away.
    pub fn forget(&self, request: RequestId) {
        lock(&self.open).remove(&request);
    }

    /// Requests on `pane` other than `current` went away (the agent moved on).
    pub fn forget_pane_except(&self, pane: PaneId, current: Option<RequestId>) {
        lock(&self.open).retain(|id, o| o.pane != pane || Some(*id) == current);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Decide,
    Hold,
}

/// The decision table. `open` holds the votes and claim so far.
fn rule(
    policy: ApprovalPolicy,
    open: &Open,
    allow: bool,
    ballot: Ballot<'_>,
) -> Result<Outcome, MpError> {
    if policy.mode == ApprovalMode::OwnerOnly && !ballot.owner {
        return Err(MpError::Forbidden(
            "only the owner answers approvals in this session".into(),
        ));
    }
    if allow && !ballot.owner && open.risk > policy.max_risk {
        return Err(MpError::Forbidden(format!(
            "allowing {} needs the owner in this session (approvers may allow {})",
            open.risk,
            allowed(policy.max_risk)
        )));
    }
    if policy.mode == ApprovalMode::Claim
        && !ballot.owner
        && let Some(claim) = &open.claimed
        && claim.actor.principal != ballot.actor.principal
    {
        return Err(MpError::Conflict(format!(
            "{} claimed this request",
            claim.name
        )));
    }
    if !allow || needed(policy, open.risk) < 2 {
        return Ok(Outcome::Decide);
    }
    if open
        .approvals
        .iter()
        .any(|v| v.actor.principal == ballot.actor.principal)
    {
        return Err(MpError::Conflict(
            "you already approved this; it needs a second person".into(),
        ));
    }
    Ok(if open.approvals.is_empty() {
        Outcome::Hold
    } else {
        Outcome::Decide
    })
}

/// "read-only calls", "reads and edits", "anything".
fn allowed(max: Risk) -> &'static str {
    match max {
        Risk::ReadOnly => "read-only calls",
        Risk::Edits => "reads and edits",
        Risk::Any => "anything",
    }
}

/// Whether a non-owner may answer a dialog read off the screen (no hook, so no request id or
/// tool): only when the policy has nothing to enforce that the screen path could bypass.
///
/// # Errors
///
/// [`MpError::Forbidden`] naming the rule.
pub(crate) fn screen_answer(policy: ApprovalPolicy, owner: bool) -> Result<(), MpError> {
    if owner {
        return Ok(());
    }
    match policy.mode {
        ApprovalMode::OwnerOnly => Err(MpError::Forbidden(
            "only the owner answers approvals in this session".into(),
        )),
        ApprovalMode::TwoPerson => Err(MpError::Forbidden(
            "this session needs two people to approve; answer from the approval card".into(),
        )),
        ApprovalMode::AnyApprover | ApprovalMode::Claim if policy.max_risk < Risk::Any => {
            Err(MpError::Forbidden(
                "this dialog's risk is unknown and this session caps what approvers may allow"
                    .into(),
            ))
        }
        ApprovalMode::AnyApprover | ApprovalMode::Claim => Ok(()),
    }
}

/// One line for the audit log: "two-person rule; approvers allow reads and edits".
pub(crate) fn describe(policy: ApprovalPolicy) -> String {
    let mode = match policy.mode {
        ApprovalMode::AnyApprover => "any approver",
        ApprovalMode::OwnerOnly => "owner only",
        ApprovalMode::TwoPerson => "two-person rule for commands",
        ApprovalMode::Claim => "claim before answering",
    };
    format!("{mode}; approvers may allow {}", allowed(policy.max_risk))
}

#[cfg(test)]
mod tests {
    use proto::{DeviceId, PrincipalId};

    use super::*;

    fn actor(n: u8) -> Actor {
        Actor {
            principal: PrincipalId([n; 16]),
            device: DeviceId([n; 32]),
        }
    }

    fn ballot(n: u8, owner: bool) -> Ballot<'static> {
        Ballot {
            actor: actor(n),
            name: if owner { "owner" } else { "guest" },
            owner,
        }
    }

    const PANE: PaneId = PaneId(1);

    fn policy(mode: ApprovalMode, max_risk: Risk) -> ApprovalPolicy {
        ApprovalPolicy { mode, max_risk }
    }

    #[test]
    fn any_approver_decides_at_once() {
        let a = Approvals::default();
        let p = ApprovalPolicy::default();
        let v = a.judge(p, PANE, RequestId(1), Risk::Any, true, ballot(2, false));
        assert_eq!(v, Ok(Verdict::Decide));
    }

    #[test]
    fn owner_only_refuses_guests_but_not_the_owner() {
        let a = Approvals::default();
        let p = policy(ApprovalMode::OwnerOnly, Risk::Any);
        let guest = a.judge(
            p,
            PANE,
            RequestId(1),
            Risk::ReadOnly,
            false,
            ballot(2, false),
        );
        assert!(matches!(guest, Err(MpError::Forbidden(_))));
        let owner = a.judge(p, PANE, RequestId(1), Risk::Any, true, ballot(1, true));
        assert_eq!(owner, Ok(Verdict::Decide));
    }

    #[test]
    fn max_risk_caps_allowing_but_not_denying() {
        let a = Approvals::default();
        let p = policy(ApprovalMode::AnyApprover, Risk::Edits);
        let bash = a.judge(p, PANE, RequestId(1), Risk::Any, true, ballot(2, false));
        assert!(matches!(bash, Err(MpError::Forbidden(m)) if m.contains("needs the owner")));
        let deny = a.judge(p, PANE, RequestId(1), Risk::Any, false, ballot(2, false));
        assert_eq!(deny, Ok(Verdict::Decide));
        let edit = a.judge(p, PANE, RequestId(2), Risk::Edits, true, ballot(2, false));
        assert_eq!(edit, Ok(Verdict::Decide));
        let owner = a.judge(p, PANE, RequestId(3), Risk::Any, true, ballot(1, true));
        assert_eq!(owner, Ok(Verdict::Decide));
    }

    #[test]
    fn two_person_holds_the_first_approval_of_a_command() {
        let a = Approvals::default();
        let p = policy(ApprovalMode::TwoPerson, Risk::Any);
        let first = a.judge(p, PANE, RequestId(1), Risk::Any, true, ballot(1, true));
        let Ok(Verdict::Held(status)) = first else {
            panic!("first approval should be held: {first:?}");
        };
        assert_eq!((status.approvals.len(), status.needed), (1, 2));
        // The same person again is not a second person, even from another device.
        let again = Ballot {
            actor: Actor {
                device: DeviceId([9; 32]),
                ..actor(1)
            },
            ..ballot(1, true)
        };
        let twice = a.judge(p, PANE, RequestId(1), Risk::Any, true, again);
        assert!(matches!(twice, Err(MpError::Conflict(_))));
        let second = a.judge(p, PANE, RequestId(1), Risk::Any, true, ballot(2, false));
        assert_eq!(second, Ok(Verdict::Decide));
    }

    #[test]
    fn two_person_lets_one_deny_and_one_approve_safer_calls() {
        let a = Approvals::default();
        let p = policy(ApprovalMode::TwoPerson, Risk::Any);
        let deny = a.judge(p, PANE, RequestId(1), Risk::Any, false, ballot(2, false));
        assert_eq!(deny, Ok(Verdict::Decide));
        let edit = a.judge(p, PANE, RequestId(2), Risk::Edits, true, ballot(2, false));
        assert_eq!(edit, Ok(Verdict::Decide));
    }

    #[test]
    fn a_claim_reserves_the_request() {
        let a = Approvals::default();
        let p = policy(ApprovalMode::Claim, Risk::Any);
        let status = a
            .claim(p, PANE, RequestId(1), Risk::Any, ballot(2, false), true)
            .unwrap();
        assert_eq!(status.claimed_by.map(|c| c.actor), Some(actor(2)));
        let other = a.judge(p, PANE, RequestId(1), Risk::Any, true, ballot(3, false));
        assert!(matches!(other, Err(MpError::Conflict(m)) if m.contains("claimed")));
        let steal = a.claim(p, PANE, RequestId(1), Risk::Any, ballot(3, false), true);
        assert!(matches!(steal, Err(MpError::Conflict(_))));
        let claimer = a.judge(p, PANE, RequestId(1), Risk::Any, true, ballot(2, false));
        assert_eq!(claimer, Ok(Verdict::Decide));
        let owner = a.judge(p, PANE, RequestId(1), Risk::Any, false, ballot(1, true));
        assert_eq!(owner, Ok(Verdict::Decide));
        // Releasing frees it for others.
        let released = a
            .claim(p, PANE, RequestId(1), Risk::Any, ballot(2, false), false)
            .unwrap();
        assert!(released.claimed_by.is_none());
        let now_free = a.judge(p, PANE, RequestId(1), Risk::Any, true, ballot(3, false));
        assert_eq!(now_free, Ok(Verdict::Decide));
    }

    #[test]
    fn screen_answers_follow_the_policy() {
        assert!(screen_answer(ApprovalPolicy::default(), false).is_ok());
        assert!(screen_answer(policy(ApprovalMode::TwoPerson, Risk::Any), false).is_err());
        assert!(screen_answer(policy(ApprovalMode::OwnerOnly, Risk::Any), false).is_err());
        assert!(screen_answer(policy(ApprovalMode::Claim, Risk::Edits), false).is_err());
        assert!(screen_answer(policy(ApprovalMode::OwnerOnly, Risk::ReadOnly), true).is_ok());
    }
}
