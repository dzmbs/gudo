//! Signing and verification of attenuable capability grants (ARCHITECTURE D17) and
//! of signed approvals.
//!
//! The wire types ([`Grant`], [`GrantChain`], [`Invite`](proto::Invite)) live in `proto`; this
//! crate holds the Ed25519 operations and the rules:
//!
//! - A **root** grant is signed by a key the daemon trusts as owner: a paired owner device or
//!   the daemon itself ([`Authority::is_root`]).
//! - An **attenuated** grant is signed by the device holding its parent: the parent's `bind`,
//!   or a device the daemon bound it to on first use ([`Authority::holds`]). The parent must
//!   allow delegation, and the child may only narrow it: roles ([`Roles::covers`]), scope
//!   ([`Authority::scope_within`]), expiry and use count. A child can never widen anything.
//! - Every link must be unexpired and unrevoked, every signature valid, and a bound leaf may
//!   only be presented by its device.
//!
//! Keys are the devices' iroh keys: a 32-byte Ed25519 seed, the same key the QUIC handshake
//! proves, so a grant bound to a device is bound to the connection's authenticated identity.
//!
//! # Examples
//!
//! ```
//! use grants::{DeviceKey, GrantSpec, SimpleAuthority, issue, attenuate, verify};
//! use proto::{DaemonId, Roles, Scope, UnixMillis};
//!
//! let daemon = DaemonId([9; 32]);
//! let owner = DeviceKey::generate();
//! let guest = DeviceKey::generate();
//! let now = UnixMillis(1_000);
//!
//! // The owner invites a guest as a driver who may share further.
//! let mut spec = GrantSpec::new(Roles::DRIVER | Roles::VIEWER, Scope::Daemon);
//! spec.bind = Some(guest.device_id());
//! spec.delegate = true;
//! let chain = issue(&owner, daemon, &spec, now);
//!
//! // The guest hands a third person a viewer-only link.
//! let viewer = attenuate(&chain, &guest, &GrantSpec::new(Roles::VIEWER, Scope::Daemon), now)?;
//!
//! let auth = SimpleAuthority::new([owner.device_id()]);
//! let third = DeviceKey::generate();
//! let verified = verify(&viewer, daemon, third.device_id(), now, &auth)?;
//! assert_eq!(verified.roles, Roles::VIEWER);
//! # Ok::<(), grants::GrantError>(())
//! ```

use std::collections::{HashMap, HashSet};

mod auto_approve;

pub use auto_approve::{
    CLOCK_SKEW_MS, RuleError, check_rule, is_shell_tool, like_this, permits, rule_matches,
    sign_auto_approve, verify_auto_approve,
};

use proto::{
    Actor, DaemonId, Decide, DeviceId, Grant, GrantChain, GrantId, GrantLink, PrincipalId, Roles,
    Scope, UnixMillis,
};
use ring::signature::{Ed25519KeyPair, KeyPair};

/// The longest chain the daemon accepts (root included).
pub const MAX_DEPTH: usize = 8;

/// How far ahead of the verifier's clock a root grant may be dated. Removal voids chains by
/// their root's date, so a root dated far ahead would outlive the removal of its signer.
pub const MAX_CLOCK_SKEW_MS: u64 = 5 * 60 * 1000;

/// A device's Ed25519 signing key.
pub struct DeviceKey {
    pair: Ed25519KeyPair,
    id: DeviceId,
}

impl std::fmt::Debug for DeviceKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeviceKey").field("id", &self.id).finish()
    }
}

/// The seed was not 32 bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("an Ed25519 seed is 32 bytes")]
pub struct KeyError;

impl DeviceKey {
    /// The key for a 32-byte seed (an iroh `SecretKey`'s bytes).
    ///
    /// # Errors
    ///
    /// Returns [`KeyError`] if `seed` is not 32 bytes.
    pub fn from_seed(seed: &[u8]) -> Result<Self, KeyError> {
        let pair = Ed25519KeyPair::from_seed_unchecked(seed).map_err(|_| KeyError)?;
        let id = DeviceId(
            pair.public_key()
                .as_ref()
                .try_into()
                .map_err(|_| KeyError)?,
        );
        Ok(Self { pair, id })
    }

    /// A fresh random key.
    pub fn generate() -> Self {
        Self::from_seed(&random::<32>()).expect("32-byte seed")
    }

    /// The public key, which is the device's id.
    pub fn device_id(&self) -> DeviceId {
        self.id
    }

    /// Signs `msg`.
    pub fn sign(&self, msg: &[u8]) -> Vec<u8> {
        self.pair.sign(msg).as_ref().to_vec()
    }
}

/// Whether `sig` is `device`'s Ed25519 signature over `msg`.
///
/// Strict: small-order keys and non-canonical points are refused. With a small-order key,
/// one signature verifies for any message, so a grant or approval "signed" by one would
/// prove nothing.
pub fn verify_signature(device: DeviceId, msg: &[u8], sig: &[u8]) -> bool {
    let Ok(key) = ed25519_dalek::VerifyingKey::from_bytes(&device.0) else {
        return false;
    };
    let Ok(sig) = <[u8; 64]>::try_from(sig) else {
        return false;
    };
    key.verify_strict(msg, &ed25519_dalek::Signature::from_bytes(&sig))
        .is_ok()
}

/// Whether `device` is a usable Ed25519 public key: a valid point not of small order. A
/// small-order key "signs" with forgeable signatures, so no one holds it in any real sense.
pub fn is_strong_key(device: DeviceId) -> bool {
    ed25519_dalek::VerifyingKey::from_bytes(&device.0).is_ok_and(|key| !key.is_weak())
}

/// SHA-256 over the concatenation of `parts`.
pub fn sha256(parts: &[&[u8]]) -> [u8; 32] {
    let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
    for part in parts {
        digest.update(part);
    }
    digest
        .finish()
        .as_ref()
        .try_into()
        .expect("SHA-256 is 32 bytes")
}

/// The principal a guest device acts as: derived from its key, so the device and the daemon
/// agree on it without a round trip, and two guests never share one.
pub fn guest_principal(device: DeviceId) -> PrincipalId {
    let hash = sha256(&[b"guest-principal-v1\0", &device.0]);
    PrincipalId(hash[..16].try_into().expect("16 bytes"))
}

/// Random bytes from the OS.
pub fn random<const N: usize>() -> [u8; N] {
    let mut out = [0; N];
    getrandom::fill(&mut out).expect("the OS random source is available");
    out
}

/// Signs an approval: fills `decide.sig` for `daemon`.
pub fn sign_approval(key: &DeviceKey, daemon: DaemonId, decide: &mut Decide) {
    let bytes =
        proto::approval_signing_bytes(daemon, decide.request_id, decide.option_id, decide.actor);
    decide.sig = key.sign(&bytes);
}

/// Whether `decide.sig` is a valid signature by `decide.actor.device` for `daemon`.
pub fn verify_approval(daemon: DaemonId, decide: &Decide) -> bool {
    let bytes =
        proto::approval_signing_bytes(daemon, decide.request_id, decide.option_id, decide.actor);
    verify_signature(decide.actor.device, &bytes, &decide.sig)
}

/// What a new grant should say. Ids, issuer, daemon and timestamps are filled in by
/// [`issue`] and [`attenuate`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrantSpec {
    pub roles: Roles,
    pub scope: Scope,
    /// Expiry; `None` never expires.
    pub expires: Option<UnixMillis>,
    /// Distinct devices that may redeem it; `None` is unlimited.
    pub max_uses: Option<u32>,
    /// Bind to one device now instead of on first use.
    pub bind: Option<DeviceId>,
    /// Let the holder delegate narrower grants.
    pub delegate: bool,
    /// Who it is for.
    pub label: String,
}

impl GrantSpec {
    /// A single-use, non-delegable, non-expiring grant with no label.
    pub fn new(roles: Roles, scope: Scope) -> Self {
        Self {
            roles,
            scope,
            expires: None,
            max_uses: Some(1),
            bind: None,
            delegate: false,
            label: String::new(),
        }
    }

    fn sign(&self, key: &DeviceKey, daemon: DaemonId, now: UnixMillis) -> GrantLink {
        let grant = Grant {
            v: Grant::VERSION,
            grant_id: GrantId(random()),
            daemon_id: daemon,
            issuer: key.device_id(),
            roles: self.roles,
            scope: self.scope,
            issued_at: now,
            expires: self.expires,
            max_uses: self.max_uses,
            bind: self.bind,
            delegate: self.delegate,
            label: self.label.clone(),
        };
        let sig = key.sign(&grant.signing_bytes());
        GrantLink { grant, sig }
    }
}

/// Signs a root grant with an owner device key (or the daemon key).
pub fn issue(key: &DeviceKey, daemon: DaemonId, spec: &GrantSpec, now: UnixMillis) -> GrantChain {
    GrantChain {
        links: vec![spec.sign(key, daemon, now)],
    }
}

/// Signs a narrower child of `parent`'s leaf with the holder's key and returns the longer
/// chain.
///
/// Checks what can be checked without the daemon: the parent allows delegation, is not bound
/// to another device, and the child is no wider in roles, expiry or uses, and in scope where
/// that is decidable without the layout (an equal scope, or a daemon-wide parent). The daemon
/// verifies everything again.
///
/// # Errors
///
/// The [`GrantError`] the daemon would also return for this child.
pub fn attenuate(
    parent: &GrantChain,
    key: &DeviceKey,
    spec: &GrantSpec,
    now: UnixMillis,
) -> Result<GrantChain, GrantError> {
    let leaf = parent.leaf().ok_or(GrantError::Empty)?;
    let depth = parent.links.len();
    if depth >= MAX_DEPTH {
        return Err(GrantError::TooDeep);
    }
    if leaf.bind.is_some_and(|bound| bound != key.device_id()) {
        return Err(GrantError::NotHolder(depth));
    }
    let link = spec.sign(key, leaf.daemon_id, now);
    check_narrowing(leaf, &link.grant, depth, &LocalScopes)?;
    let mut chain = parent.clone();
    chain.links.push(link);
    Ok(chain)
}

/// Why a chain was rejected. Indexes count links from the root (0).
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum GrantError {
    /// No links.
    #[error("empty grant chain")]
    Empty,
    /// More than [`MAX_DEPTH`] links.
    #[error("grant chain longer than {MAX_DEPTH}")]
    TooDeep,
    /// A link's format version is unknown.
    #[error("link {0}: unsupported grant version")]
    Version(usize),
    /// A link is for another daemon.
    #[error("link {0}: grant is for another daemon")]
    WrongDaemon(usize),
    /// A signature does not verify.
    #[error("link {0}: bad signature")]
    BadSignature(usize),
    /// The root is not signed by an owner device or the daemon.
    #[error("root grant not signed by an owner device")]
    UntrustedRoot,
    /// A child is not signed by the device holding its parent.
    #[error("link {0}: not signed by the parent's holder")]
    NotHolder(usize),
    /// A child's parent does not allow delegation.
    #[error("link {0}: parent does not allow delegation")]
    NotDelegable(usize),
    /// A child has roles its parent lacks, or none.
    #[error("link {0}: roles wider than the parent's")]
    Escalation(usize),
    /// A child's scope is not inside its parent's.
    #[error("link {0}: scope wider than the parent's")]
    ScopeWidened(usize),
    /// A child expires later than its parent (or never while the parent does).
    #[error("link {0}: expires later than the parent")]
    ExpiryWidened(usize),
    /// A child allows more uses than its parent.
    #[error("link {0}: more uses than the parent")]
    UsesWidened(usize),
    /// A link has expired.
    #[error("link {0}: expired")]
    Expired(usize),
    /// A link was revoked.
    #[error("link {0}: revoked")]
    Revoked(usize),
    /// A link's issuer or the presenting device was revoked.
    #[error("device revoked")]
    DeviceRevoked,
    /// The leaf is bound to another device.
    #[error("grant bound to another device")]
    BoundElsewhere,
    /// The same grant id appears twice.
    #[error("link {0}: duplicate grant id")]
    Duplicate(usize),
    /// The root is dated further ahead than [`MAX_CLOCK_SKEW_MS`].
    #[error("root grant dated ahead of the daemon's clock")]
    FutureDated,
}

/// What the daemon knows that a chain alone does not say.
pub trait Authority {
    /// Whether `issuer` may sign root grants (an owner device or the daemon).
    fn is_root(&self, issuer: DeviceId) -> bool;

    /// Whether `root` is a root grant to honour. The default asks only [`Authority::is_root`]
    /// of its issuer; the daemon also checks that it was signed under the issuer's current
    /// pairing.
    fn root_trusted(&self, root: &Grant) -> bool {
        self.is_root(root.issuer)
    }

    /// Whether `device` redeemed (was bound to) the unbound grant `grant`.
    fn holds(&self, grant: GrantId, device: DeviceId) -> bool;

    /// Whether `inner` lies within `outer`. The default knows only that every scope lies in
    /// [`Scope::Daemon`] and in itself; the daemon also consults its layout.
    fn scope_within(&self, inner: Scope, outer: Scope) -> bool {
        inner == outer || outer == Scope::Daemon
    }

    /// Whether `grant` was revoked.
    fn grant_revoked(&self, grant: GrantId) -> bool {
        let _ = grant;
        false
    }

    /// When `device` was last revoked or unpaired. A chain it takes part in (as signer,
    /// holder or presenter) counts only if its root was signed after that, so its old grants
    /// stay void while a fresh invite (or pairing) can bring it back.
    fn removed_at(&self, device: DeviceId) -> Option<UnixMillis> {
        let _ = device;
        None
    }

    /// Chains whose root was signed at or before this are void (the record of revocations
    /// before it was lost).
    fn void_before(&self) -> Option<UnixMillis> {
        None
    }
}

/// An [`Authority`] from plain sets, for tests and offline checks.
#[derive(Debug, Clone, Default)]
pub struct SimpleAuthority {
    /// Root keys.
    pub roots: HashSet<DeviceId>,
    /// `(grant, device)` bindings.
    pub bindings: HashSet<(GrantId, DeviceId)>,
    /// Revoked grants.
    pub revoked: HashSet<GrantId>,
    /// Revoked devices, with when.
    pub revoked_devices: HashMap<DeviceId, UnixMillis>,
    /// [`Authority::void_before`].
    pub void_before: Option<UnixMillis>,
}

impl SimpleAuthority {
    /// An authority trusting `roots`.
    pub fn new(roots: impl IntoIterator<Item = DeviceId>) -> Self {
        Self {
            roots: roots.into_iter().collect(),
            ..Self::default()
        }
    }
}

impl Authority for SimpleAuthority {
    fn is_root(&self, issuer: DeviceId) -> bool {
        self.roots.contains(&issuer)
    }

    fn holds(&self, grant: GrantId, device: DeviceId) -> bool {
        self.bindings.contains(&(grant, device))
    }

    fn grant_revoked(&self, grant: GrantId) -> bool {
        self.revoked.contains(&grant)
    }

    fn removed_at(&self, device: DeviceId) -> Option<UnixMillis> {
        self.revoked_devices.get(&device).copied()
    }

    fn void_before(&self) -> Option<UnixMillis> {
        self.void_before
    }
}

/// Scope order without a layout: undecidable pairs pass (the daemon decides them).
struct LocalScopes;

impl LocalScopes {
    fn within(inner: Scope, outer: Scope) -> bool {
        match (inner, outer) {
            (_, Scope::Daemon) => true,
            (Scope::Daemon, _) => false,
            (inner, outer) if inner == outer => true,
            (Scope::Session(_), _) => false,
            (Scope::Tab(_), Scope::Session(_))
            | (Scope::Pane(_), Scope::Session(_) | Scope::Tab(_)) => true,
            _ => false,
        }
    }
}

trait ScopeOrder {
    fn within(&self, inner: Scope, outer: Scope) -> bool;
}

impl ScopeOrder for LocalScopes {
    fn within(&self, inner: Scope, outer: Scope) -> bool {
        Self::within(inner, outer)
    }
}

impl<A: Authority + ?Sized> ScopeOrder for &A {
    fn within(&self, inner: Scope, outer: Scope) -> bool {
        self.scope_within(inner, outer)
    }
}

fn check_narrowing(
    parent: &Grant,
    child: &Grant,
    index: usize,
    scopes: &impl ScopeOrder,
) -> Result<(), GrantError> {
    if !parent.delegate {
        return Err(GrantError::NotDelegable(index));
    }
    if child.roles.effective() == Roles::EMPTY || !parent.roles.covers(child.roles) {
        return Err(GrantError::Escalation(index));
    }
    if !scopes.within(child.scope, parent.scope) {
        return Err(GrantError::ScopeWidened(index));
    }
    match (parent.expires, child.expires) {
        (Some(_), None) => return Err(GrantError::ExpiryWidened(index)),
        (Some(parent_expiry), Some(child_expiry)) if child_expiry > parent_expiry => {
            return Err(GrantError::ExpiryWidened(index));
        }
        _ => {}
    }
    match (parent.max_uses, child.max_uses) {
        (Some(_), None) => return Err(GrantError::UsesWidened(index)),
        (Some(parent_uses), Some(child_uses)) if child_uses > parent_uses => {
            return Err(GrantError::UsesWidened(index));
        }
        _ => {}
    }
    if child.daemon_id != parent.daemon_id {
        return Err(GrantError::WrongDaemon(index));
    }
    Ok(())
}

/// A chain that passed [`verify`]: what the presenting device may do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verified {
    /// Effective roles: the leaf's, intersected with every ancestor's.
    pub roles: Roles,
    /// The leaf's scope (inside every ancestor's).
    pub scope: Scope,
    /// The earliest expiry in the chain.
    pub expires: Option<UnixMillis>,
    /// Every link's id, root first; revoking any of them revokes this chain.
    pub ids: Vec<GrantId>,
    /// The leaf grant.
    pub leaf: Grant,
}

/// Verifies `chain` presented by `presenter` (already authenticated by the QUIC handshake)
/// to `daemon` at `now`.
///
/// Use counting and first-use binding of an unbound leaf are the caller's job: this checks
/// only that the chain is valid and that a bound leaf is bound to `presenter`.
///
/// # Errors
///
/// The first [`GrantError`] found, checking from the root.
pub fn verify(
    chain: &GrantChain,
    daemon: DaemonId,
    presenter: DeviceId,
    now: UnixMillis,
    authority: &impl Authority,
) -> Result<Verified, GrantError> {
    let leaf = chain.leaf().ok_or(GrantError::Empty)?;
    if chain.links.len() > MAX_DEPTH {
        return Err(GrantError::TooDeep);
    }
    let mut seen = HashSet::new();
    let mut roles = Roles::ALL;
    let mut expires: Option<UnixMillis> = None;
    for (index, link) in chain.links.iter().enumerate() {
        let grant = &link.grant;
        if grant.v != Grant::VERSION {
            return Err(GrantError::Version(index));
        }
        if grant.daemon_id != daemon {
            return Err(GrantError::WrongDaemon(index));
        }
        if !verify_signature(grant.issuer, &grant.signing_bytes(), &link.sig) {
            return Err(GrantError::BadSignature(index));
        }
        if !seen.insert(grant.grant_id) {
            return Err(GrantError::Duplicate(index));
        }
        if authority.grant_revoked(grant.grant_id) {
            return Err(GrantError::Revoked(index));
        }
        if grant.expires.is_some_and(|expiry| expiry <= now) {
            return Err(GrantError::Expired(index));
        }
        if index == 0 {
            if grant.issued_at.0 > now.0.saturating_add(MAX_CLOCK_SKEW_MS) {
                return Err(GrantError::FutureDated);
            }
            if !authority.root_trusted(grant) {
                return Err(GrantError::UntrustedRoot);
            }
        } else {
            let parent = &chain.links[index - 1].grant;
            let held = match parent.bind {
                Some(bound) => bound == grant.issuer,
                None => authority.holds(parent.grant_id, grant.issuer),
            };
            if !held {
                return Err(GrantError::NotHolder(index));
            }
            check_narrowing(parent, grant, index, &authority)?;
        }
        roles = Roles(roles.0 & grant.roles.effective().0);
        expires = match (expires, grant.expires) {
            (Some(earliest), Some(link_expiry)) => Some(earliest.min(link_expiry)),
            (earliest, link_expiry) => earliest.or(link_expiry),
        };
    }
    if leaf.bind.is_some_and(|bound| bound != presenter) {
        return Err(GrantError::BoundElsewhere);
    }
    check_removals(chain, presenter, authority)?;
    if roles == Roles::EMPTY {
        return Err(GrantError::Escalation(chain.links.len() - 1));
    }
    Ok(Verified {
        roles,
        scope: leaf.scope,
        expires,
        ids: chain.links.iter().map(|link| link.grant.grant_id).collect(),
        leaf: leaf.clone(),
    })
}

/// A chain is void if its root was signed no later than the removal of any device in it, or
/// than [`Authority::void_before`]. Only the root's time counts: roots come from owner devices
/// or the daemon, while a guest could date its own links freely.
fn check_removals(
    chain: &GrantChain,
    presenter: DeviceId,
    authority: &impl Authority,
) -> Result<(), GrantError> {
    let Some(root) = chain.links.first() else {
        return Err(GrantError::Empty);
    };
    let signed = root.grant.issued_at;
    if authority
        .void_before()
        .is_some_and(|cutoff| signed <= cutoff)
    {
        return Err(GrantError::Revoked(0));
    }
    let devices = chain
        .links
        .iter()
        .flat_map(|link| [Some(link.grant.issuer), link.grant.bind])
        .flatten()
        .chain([presenter]);
    for device in devices {
        if authority
            .removed_at(device)
            .is_some_and(|removed| signed <= removed)
        {
            return Err(GrantError::DeviceRevoked);
        }
    }
    Ok(())
}

/// The actor a guest device acts as.
pub fn guest_actor(device: DeviceId) -> Actor {
    Actor {
        principal: guest_principal(device),
        device,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_and_iroh_derive_the_same_public_key() {
        let seed = random::<32>();
        let iroh_key = iroh::SecretKey::from_bytes(&seed);
        let ours = DeviceKey::from_seed(&seed).unwrap();
        assert_eq!(ours.device_id().0, *iroh_key.public().as_bytes());
        let sig = ours.sign(b"hello");
        assert!(verify_signature(ours.device_id(), b"hello", &sig));
        assert!(!verify_signature(ours.device_id(), b"hellO", &sig));
    }

    /// The identity point as a key with R = identity, S = 0 satisfies the plain verification
    /// equation for every message.
    #[test]
    fn small_order_keys_prove_nothing() {
        let mut identity = [0u8; 32];
        identity[0] = 1;
        let mut sig = [0u8; 64];
        sig[0] = 1;
        let weak = DeviceId(identity);
        assert!(!verify_signature(weak, b"anything", &sig));
        assert!(!verify_signature(weak, b"anything else", &sig));
        assert!(!is_strong_key(weak));
        assert!(is_strong_key(DeviceKey::generate().device_id()));

        // Nor can a chain be rooted in or pass through such a key.
        let daemon = DaemonId([9; 32]);
        let grant = Grant {
            v: Grant::VERSION,
            grant_id: GrantId([1; 16]),
            daemon_id: daemon,
            issuer: weak,
            roles: Roles::OWNER,
            scope: Scope::Daemon,
            issued_at: UnixMillis(0),
            expires: None,
            max_uses: None,
            bind: None,
            delegate: true,
            label: String::new(),
        };
        let chain = GrantChain {
            links: vec![GrantLink {
                grant,
                sig: sig.to_vec(),
            }],
        };
        let auth = SimpleAuthority::new([weak]);
        let presenter = DeviceKey::generate().device_id();
        assert_eq!(
            verify(&chain, daemon, presenter, UnixMillis(1), &auth),
            Err(GrantError::BadSignature(0))
        );
    }

    #[test]
    fn local_scope_order() {
        use proto::{PaneId, SessionId, TabId};
        let session = Scope::Session(SessionId(1));
        let tab = Scope::Tab(TabId(1));
        let pane = Scope::Pane(PaneId(1));
        assert!(LocalScopes::within(pane, Scope::Daemon));
        assert!(LocalScopes::within(tab, session));
        assert!(!LocalScopes::within(session, tab));
        assert!(!LocalScopes::within(Scope::Daemon, pane));
        assert!(!LocalScopes::within(Scope::Pane(PaneId(2)), pane));
    }
}
