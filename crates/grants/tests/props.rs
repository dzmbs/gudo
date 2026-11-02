//! Property tests for grant chains: valid narrowing chains verify; any widening, tampering,
//! expiry, revocation, foreign signature or wrong presenter is rejected.

use grants::{DeviceKey, GrantError, GrantSpec, SimpleAuthority, attenuate, issue, verify};
use proptest::prelude::*;
use proto::{DaemonId, GrantChain, PaneId, Roles, Scope, SessionId, UnixMillis};

const DAEMON: DaemonId = DaemonId([9; 32]);
const NOW: UnixMillis = UnixMillis(1_000_000);

fn roles() -> impl Strategy<Value = Roles> {
    (1u8..32).prop_map(Roles)
}

/// A non-empty subset of `of` (owner expanded).
fn subset(of: Roles, mask: u8) -> Roles {
    let narrowed = Roles(of.effective().0 & mask & !Roles::OWNER.0);
    if narrowed == Roles::EMPTY {
        // Fall back to one role `of` confers.
        Roles(1 << of.effective().0.trailing_zeros())
    } else {
        narrowed
    }
}

/// Scopes from wide to narrow that the default authority can order.
fn scope_for(level: u8) -> Scope {
    match level {
        0 => Scope::Daemon,
        _ => Scope::Pane(PaneId(7)),
    }
}

#[derive(Debug, Clone)]
struct Step {
    mask: u8,
    narrow_scope: bool,
    expiry_cut: u64,
    uses_cut: u32,
}

fn step() -> impl Strategy<Value = Step> {
    (any::<u8>(), any::<bool>(), 0u64..10_000, 0u32..3).prop_map(
        |(mask, narrow_scope, expiry_cut, uses_cut)| Step {
            mask,
            narrow_scope,
            expiry_cut,
            uses_cut,
        },
    )
}

/// Builds a valid chain: owner root bound to holder 0, then each step narrows, signed by
/// holder `i` and bound to holder `i + 1`. Returns (chain, owner, presenter = last holder).
fn build(root_roles: Roles, steps: &[Step]) -> (GrantChain, DeviceKey, DeviceKey) {
    let owner = DeviceKey::generate();
    let mut holders: Vec<DeviceKey> = (0..=steps.len()).map(|_| DeviceKey::generate()).collect();
    let mut spec = GrantSpec::new(root_roles, Scope::Daemon);
    spec.expires = Some(UnixMillis(NOW.0 + 100_000));
    spec.max_uses = Some(5);
    spec.delegate = true;
    spec.bind = Some(holders[0].device_id());
    let mut chain = issue(&owner, DAEMON, &spec, NOW);
    let mut level = 0;
    for (i, step) in steps.iter().enumerate() {
        let parent = chain.leaf().unwrap().clone();
        if step.narrow_scope {
            level = 1;
        }
        let mut child = GrantSpec::new(subset(parent.roles, step.mask), scope_for(level));
        child.expires = parent
            .expires
            .map(|expiry| UnixMillis(expiry.0 - step.expiry_cut));
        child.max_uses = parent
            .max_uses
            .map(|uses| uses.saturating_sub(step.uses_cut).max(1));
        child.delegate = true;
        child.bind = Some(holders[i + 1].device_id());
        chain = attenuate(&chain, &holders[i], &child, NOW).expect("narrowing child");
    }
    let presenter = holders.pop().unwrap();
    (chain, owner, presenter)
}

fn owner_authority(owner: &DeviceKey) -> SimpleAuthority {
    SimpleAuthority::new([owner.device_id()])
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    #[test]
    fn narrowing_chains_verify(root in roles(), steps in prop::collection::vec(step(), 0..6)) {
        let (chain, owner, presenter) = build(root, &steps);
        let verified = verify(&chain, DAEMON, presenter.device_id(), NOW, &owner_authority(&owner)).unwrap();
        // Effective roles never exceed the root's, and equal the leaf's.
        prop_assert!(root.covers(verified.roles));
        prop_assert_eq!(verified.roles, chain.leaf().unwrap().roles.effective());
        prop_assert_eq!(verified.ids.len(), chain.links.len());
    }

    #[test]
    fn any_tampered_byte_is_rejected(
        root in roles(),
        steps in prop::collection::vec(step(), 0..4),
        link in any::<prop::sample::Index>(),
        byte in any::<prop::sample::Index>(),
        flip in 1u8..=255,
    ) {
        let (mut chain, owner, presenter) = build(root, &steps);
        let index = link.index(chain.links.len());
        let authority = owner_authority(&owner);
        // Flip a byte either in the signature or in a field the signature covers.
        if byte.index(2) == 0 {
            let sig = &mut chain.links[index].sig;
            let position = byte.index(sig.len());
            sig[position] ^= flip;
        } else {
            let grant = &mut chain.links[index].grant;
            grant.label.push(char::from(b'a' + flip % 26));
        }
        prop_assert!(verify(&chain, DAEMON, presenter.device_id(), NOW, &authority).is_err());
    }

    #[test]
    fn widening_roles_is_rejected(root in roles(), extra in roles(), steps in prop::collection::vec(step(), 0..3)) {
        let (chain, owner, presenter) = build(root, &steps);
        let parent = chain.leaf().unwrap();
        prop_assume!(!parent.roles.covers(extra));
        let mut child = GrantSpec::new(extra, parent.scope);
        child.expires = parent.expires;
        child.max_uses = parent.max_uses;
        child.bind = Some(DeviceKey::generate().device_id());
        // The client-side helper refuses…
        prop_assert_eq!(
            attenuate(&chain, &presenter, &child, NOW).unwrap_err(),
            GrantError::Escalation(chain.links.len())
        );
        // …and a hand-signed escalation fails verification.
        let forged = force_child(&chain, &presenter, &child);
        let next = DeviceKey::generate();
        let result = verify(&forged, DAEMON, child.bind.unwrap_or(next.device_id()), NOW, &owner_authority(&owner));
        prop_assert_eq!(result.unwrap_err(), GrantError::Escalation(chain.links.len()));
    }

    #[test]
    fn widening_expiry_or_uses_or_scope_is_rejected(root in roles(), which in 0u8..4) {
        let (chain, owner, presenter) = build(root, &[Step { mask: 0xff, narrow_scope: true, expiry_cut: 1, uses_cut: 1 }]);
        let parent = chain.leaf().unwrap().clone();
        let mut child = GrantSpec::new(parent.roles, parent.scope);
        child.expires = parent.expires;
        child.max_uses = parent.max_uses;
        let expected_at = chain.links.len();
        let want = match which {
            0 => { child.expires = Some(UnixMillis(parent.expires.unwrap().0 + 1)); GrantError::ExpiryWidened(expected_at) }
            1 => { child.expires = None; GrantError::ExpiryWidened(expected_at) }
            2 => { child.max_uses = Some(parent.max_uses.unwrap() + 1); GrantError::UsesWidened(expected_at) }
            _ => { child.scope = Scope::Daemon; GrantError::ScopeWidened(expected_at) }
        };
        prop_assert_eq!(attenuate(&chain, &presenter, &child, NOW).unwrap_err(), want);
        let forged = force_child(&chain, &presenter, &child);
        let result = verify(&forged, DAEMON, presenter.device_id(), NOW, &owner_authority(&owner));
        prop_assert_eq!(result.unwrap_err(), want);
    }

    #[test]
    fn expiry_revocation_and_presenter_are_enforced(
        root in roles(),
        steps in prop::collection::vec(step(), 1..4),
        link in any::<prop::sample::Index>(),
    ) {
        let (chain, owner, presenter) = build(root, &steps);
        let index = link.index(chain.links.len());
        let mut authority = owner_authority(&owner);
        // Past the earliest expiry.
        let late = chain.links.iter().filter_map(|link| link.grant.expires).min().unwrap();
        prop_assert!(matches!(
            verify(&chain, DAEMON, presenter.device_id(), late, &authority),
            Err(GrantError::Expired(_))
        ));
        // Another device presenting a bound chain.
        prop_assert_eq!(
            verify(&chain, DAEMON, DeviceKey::generate().device_id(), NOW, &authority).unwrap_err(),
            GrantError::BoundElsewhere
        );
        // Wrong daemon.
        prop_assert_eq!(
            verify(&chain, DaemonId([1; 32]), presenter.device_id(), NOW, &authority).unwrap_err(),
            GrantError::WrongDaemon(0)
        );
        // Revoking any link revokes the chain.
        authority.revoked.insert(chain.links[index].grant.grant_id);
        prop_assert_eq!(
            verify(&chain, DAEMON, presenter.device_id(), NOW, &authority).unwrap_err(),
            GrantError::Revoked(index)
        );
        // Revoking any issuer's device does too.
        let mut device_revoked = owner_authority(&owner);
        device_revoked.revoked_devices.insert(chain.links[index].grant.issuer, NOW);
        prop_assert_eq!(
            verify(&chain, DAEMON, presenter.device_id(), NOW, &device_revoked).unwrap_err(),
            GrantError::DeviceRevoked
        );
    }

    #[test]
    fn roots_must_be_trusted_and_children_signed_by_holders(root in roles()) {
        let (chain, owner, presenter) = build(root, &[]);
        let stranger = DeviceKey::generate();
        prop_assert_eq!(
            verify(&chain, DAEMON, presenter.device_id(), NOW, &SimpleAuthority::new([stranger.device_id()])).unwrap_err(),
            GrantError::UntrustedRoot
        );
        // A stranger (not the parent's bound holder) signing a child.
        let parent = chain.leaf().unwrap();
        let mut child = GrantSpec::new(Roles::VIEWER, parent.scope);
        child.expires = parent.expires;
        child.max_uses = parent.max_uses;
        let forged = force_child(&chain, &stranger, &child);
        prop_assert_eq!(
            verify(&forged, DAEMON, presenter.device_id(), NOW, &owner_authority(&owner)).unwrap_err(),
            GrantError::NotHolder(1)
        );
    }
}

#[test]
fn unbound_parent_needs_a_recorded_binding_and_delegation() {
    let owner = DeviceKey::generate();
    let guest = DeviceKey::generate();
    let mut spec = GrantSpec::new(Roles::DRIVER | Roles::VIEWER, Scope::Session(SessionId(1)));
    spec.delegate = true;
    let chain = issue(&owner, DAEMON, &spec, NOW);
    let child = GrantSpec::new(Roles::VIEWER, Scope::Session(SessionId(1)));
    let delegated = attenuate(&chain, &guest, &child, NOW).unwrap();
    let third = DeviceKey::generate();
    let mut authority = SimpleAuthority::new([owner.device_id()]);
    assert_eq!(
        verify(&delegated, DAEMON, third.device_id(), NOW, &authority).unwrap_err(),
        GrantError::NotHolder(1)
    );
    authority
        .bindings
        .insert((chain.grant_id(), guest.device_id()));
    let verified = verify(&delegated, DAEMON, third.device_id(), NOW, &authority).unwrap();
    assert_eq!(verified.roles, Roles::VIEWER);

    // Without `delegate` the child is refused even by its holder.
    let fixed = issue(
        &owner,
        DAEMON,
        &GrantSpec::new(Roles::DRIVER, Scope::Daemon),
        NOW,
    );
    authority
        .bindings
        .insert((fixed.grant_id(), guest.device_id()));
    assert_eq!(
        attenuate(&fixed, &guest, &child, NOW).unwrap_err(),
        GrantError::NotDelegable(1)
    );
    let forged = force_child(&fixed, &guest, &child);
    assert_eq!(
        verify(&forged, DAEMON, third.device_id(), NOW, &authority).unwrap_err(),
        GrantError::NotDelegable(1)
    );
}

#[test]
fn owner_role_covers_everything_and_approvals_verify() {
    assert!(Roles::OWNER.covers(Roles::ALL));
    assert!(!Roles::DRIVER.covers(Roles::OWNER));
    let key = DeviceKey::generate();
    let mut decide = proto::Decide {
        request_id: proto::RequestId(4),
        option_id: proto::OptionId(0),
        actor: grants::guest_actor(key.device_id()),
        sig: vec![],
    };
    grants::sign_approval(&key, DAEMON, &mut decide);
    assert!(grants::verify_approval(DAEMON, &decide));
    assert!(!grants::verify_approval(DaemonId([0; 32]), &decide));
    decide.option_id = proto::OptionId(1);
    assert!(!grants::verify_approval(DAEMON, &decide));
}

/// Appends a child signed by `key` without the client-side checks (a forger's chain).
fn force_child(chain: &GrantChain, key: &DeviceKey, spec: &GrantSpec) -> GrantChain {
    let mut parent = chain.clone();
    // Make the parent delegable-looking only if it already is; we never re-sign ancestors.
    let leaf = parent.leaf().unwrap().clone();
    let grant = proto::Grant {
        v: proto::Grant::VERSION,
        grant_id: proto::GrantId(grants::random()),
        daemon_id: leaf.daemon_id,
        issuer: key.device_id(),
        roles: spec.roles,
        scope: spec.scope,
        issued_at: NOW,
        expires: spec.expires,
        max_uses: spec.max_uses,
        bind: spec.bind,
        delegate: spec.delegate,
        label: spec.label.clone(),
    };
    let sig = key.sign(&grant.signing_bytes());
    parent.links.push(proto::GrantLink { grant, sig });
    parent
}

proptest! {
    /// A shell rule never covers a command with a chaining, redirecting or expanding
    /// character anywhere in it, whatever surrounds it.
    #[test]
    fn auto_approve_never_matches_compound_commands(
        prefix in prop::sample::select(vec!["cargo test", "rm", "npm run", "ls"]),
        before in "[a-z -]{0,12}",
        meta in prop::sample::select(vec![";", "&", "|", ">", "<", "`", "$", "\n", "(", "\\"]),
        after in "[a-z /-]{0,12}",
    ) {
        let matcher = proto::RuleMatch { tool: "Bash".into(), prefix: prefix.into() };
        let input = format!("{prefix} {before}{meta}{after}");
        prop_assert!(!grants::rule_matches(&matcher, "Bash", &input));
    }

    /// What `like_this` proposes always covers the request it was made from.
    #[test]
    fn like_this_covers_its_own_request(
        program in prop::sample::select(vec!["cargo", "git", "rm", "ls", "make", "python3"]),
        words in prop::collection::vec("[a-z][a-z0-9.]{0,6}", 1..4),
    ) {
        let input = format!("{program} {}", words.join(" "));
        if let Some(matcher) = grants::like_this("Bash", &input) {
            prop_assert!(grants::rule_matches(&matcher, "Bash", &input));
        }
    }
}

/// Ed25519 signatures are malleable without the `S < L` check: `S + L` satisfies the plain
/// verification equation. Strict verification refuses it, so a grant has one signature.
#[test]
fn non_canonical_signatures_are_refused() {
    const L: [u8; 32] = [
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde,
        0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
    ];
    let key = DeviceKey::generate();
    let sig = key.sign(b"grant");
    assert!(grants::verify_signature(key.device_id(), b"grant", &sig));
    let mut forged = sig.clone();
    let mut carry = 0u16;
    for (scalar_byte, order_byte) in forged[32..].iter_mut().zip(L) {
        let sum = u16::from(*scalar_byte) + u16::from(order_byte) + carry;
        *scalar_byte = sum as u8;
        carry = sum >> 8;
    }
    assert_eq!(carry, 0);
    assert_ne!(forged, sig);
    assert!(!grants::verify_signature(
        key.device_id(),
        b"grant",
        &forged
    ));
    // Nor are short, long or all-zero signatures.
    let long = [sig.clone(), vec![0]].concat();
    assert!(!grants::verify_signature(
        key.device_id(),
        b"grant",
        &sig[..63]
    ));
    assert!(!grants::verify_signature(key.device_id(), b"grant", &long));
    assert!(!grants::verify_signature(
        key.device_id(),
        b"grant",
        &[0; 64]
    ));
}

/// A removed device voids every chain it is part of whose root predates the removal, as
/// signer, holder or presenter; a root signed afterwards counts again. Forward-dating its own
/// child link does not help a removed delegate: only the root's time counts.
#[test]
fn removal_voids_older_chains_only() {
    let owner = DeviceKey::generate();
    let delegate = DeviceKey::generate();
    let third = DeviceKey::generate();
    let mut spec = GrantSpec::new(Roles::VIEWER, Scope::Daemon);
    spec.delegate = true;
    spec.max_uses = None;
    spec.bind = Some(delegate.device_id());
    let root = issue(&owner, DAEMON, &spec, NOW);
    let mut child = GrantSpec::new(Roles::VIEWER, Scope::Daemon);
    child.max_uses = None;
    let future = UnixMillis(NOW.0 + 10_000_000);
    let delegated = attenuate(&root, &delegate, &child, future).unwrap();

    let mut authority = owner_authority(&owner);
    authority
        .revoked_devices
        .insert(delegate.device_id(), UnixMillis(NOW.0 + 1));
    let later = UnixMillis(NOW.0 + 20_000_000);
    assert_eq!(
        verify(&root, DAEMON, delegate.device_id(), later, &authority).unwrap_err(),
        GrantError::DeviceRevoked
    );
    assert_eq!(
        verify(&delegated, DAEMON, third.device_id(), later, &authority).unwrap_err(),
        GrantError::DeviceRevoked
    );
    // The owner re-invites the delegate after the removal.
    let again = issue(&owner, DAEMON, &spec, UnixMillis(NOW.0 + 2));
    assert!(verify(&again, DAEMON, delegate.device_id(), later, &authority).is_ok());

    // A reset store voids every chain up to its time.
    let mut reset = owner_authority(&owner);
    reset.void_before = Some(NOW);
    assert_eq!(
        verify(&root, DAEMON, delegate.device_id(), later, &reset).unwrap_err(),
        GrantError::Revoked(0)
    );
    assert!(verify(&again, DAEMON, delegate.device_id(), later, &reset).is_ok());
}
