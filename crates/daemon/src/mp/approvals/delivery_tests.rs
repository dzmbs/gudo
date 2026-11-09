use super::*;
use proto::{DeviceId, GrantId, PrincipalId, Roles, Scope};

fn authorization(seed: u8) -> super::super::Authz {
    super::super::Authz::owner(Actor {
        principal: PrincipalId([seed; 16]),
        device: DeviceId([seed; 32]),
    })
}

fn ballot(authz: &super::super::Authz) -> Ballot<'_> {
    Ballot {
        actor: authz.actor,
        name: &authz.name,
        owner: authz.grant_ids.is_empty(),
        authorization: Some(authz),
    }
}

#[test]
fn deferred_delivery_retains_the_exact_two_person_grants() {
    let votes = Approvals::default();
    let policy = ApprovalPolicy {
        mode: ApprovalMode::TwoPerson,
        max_risk: Risk::Any,
    };
    let (pane, request) = (PaneId(1), RequestId(8));
    let mut first = authorization(1);
    first.roles = Roles::APPROVER;
    first.scope = Scope::Pane(pane);
    first.grant_ids.push(GrantId([9; 16]));
    first.issuers.push(DeviceId([7; 32]));
    first.expires = Some(UnixMillis(1000));
    let second = authorization(2);
    assert!(matches!(
        votes
            .judge(policy, pane, request, Risk::Any, true, ballot(&first))
            .unwrap(),
        Verdict::Held(_)
    ));
    assert!(
        votes
            .delivery_signers(policy, request, true, ballot(&first))
            .is_none()
    );
    let signers = votes
        .delivery_signers(policy, request, true, ballot(&second))
        .unwrap();
    assert_eq!(signers.len(), 2);
    assert_eq!(signers[0].actor, second.actor);
    assert_eq!(signers[1].actor, first.actor);
    assert_eq!(signers[1].grant_ids, first.grant_ids);
    assert_eq!(signers[1].issuers, first.issuers);
    assert_eq!(signers[1].scope, first.scope);
    assert_eq!(signers[1].expires, first.expires);
    votes.forget(request);
    assert!(
        votes
            .delivery_signers(policy, request, true, ballot(&second))
            .is_none()
    );
}

#[test]
fn a_missing_witness_authorization_is_not_reconstructed_from_its_actor() {
    let votes = Approvals::default();
    let policy = ApprovalPolicy {
        mode: ApprovalMode::TwoPerson,
        max_risk: Risk::Any,
    };
    let first = authorization(1);
    let second = authorization(2);
    let request = RequestId(8);
    votes
        .judge(
            policy,
            PaneId(1),
            request,
            Risk::Any,
            true,
            Ballot {
                authorization: None,
                ..ballot(&first)
            },
        )
        .unwrap();
    assert!(
        votes
            .delivery_signers(policy, request, true, ballot(&second))
            .is_none()
    );
    assert_eq!(
        votes
            .delivery_signers(policy, request, false, ballot(&second))
            .unwrap()
            .len(),
        1,
        "one authorized person may still deny"
    );
}

#[test]
fn delivery_rechecks_a_policy_or_claim_that_changed_after_admission() {
    let votes = Approvals::default();
    let mut guest = authorization(1);
    guest.roles = Roles::APPROVER;
    guest.grant_ids.push(GrantId([1; 16]));
    let other = authorization(2);
    let (pane, request) = (PaneId(1), RequestId(8));
    let policy = ApprovalPolicy::default();
    votes.open(policy, pane, request, Risk::Any).unwrap();
    assert!(
        votes
            .delivery_signers(policy, request, true, ballot(&guest))
            .is_some()
    );
    let owner_only = ApprovalPolicy {
        mode: ApprovalMode::OwnerOnly,
        ..policy
    };
    assert!(
        votes
            .delivery_signers(owner_only, request, true, ballot(&guest))
            .is_none()
    );
    let claimed = ApprovalPolicy {
        mode: ApprovalMode::Claim,
        ..policy
    };
    votes
        .claim(claimed, pane, request, Risk::Any, ballot(&other), true)
        .unwrap();
    assert!(
        votes
            .delivery_signers(claimed, request, true, ballot(&guest))
            .is_none()
    );
}
