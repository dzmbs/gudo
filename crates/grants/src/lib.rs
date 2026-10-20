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

use std::collections::HashSet;

mod auto_approve;

pub use auto_approve::{
    CLOCK_SKEW_MS, RuleError, check_rule, is_shell_tool, like_this, permits, rule_matches,
    sign_auto_approve, verify_auto_approve,
};

use proto::{
    Actor, DaemonId, Decide, DeviceId, Grant, GrantChain, GrantId, GrantLink, PrincipalId, Roles,
    Scope, UnixMillis,
};
use ring::signature::{ED25519, Ed25519KeyPair, KeyPair, UnparsedPublicKey};

/// The longest chain the daemon accepts (root included).
pub const MAX_DEPTH: usize = 8;

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
pub fn verify_signature(device: DeviceId, msg: &[u8], sig: &[u8]) -> bool {
    UnparsedPublicKey::new(&ED25519, device.0)
        .verify(msg, sig)
        .is_ok()
}

/// SHA-256 over the concatenation of `parts`.
pub fn sha256(parts: &[&[u8]]) -> [u8; 32] {
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    for part in parts {
        ctx.update(part);
    }
    ctx.finish()
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
    /// Roles.
    pub roles: Roles,
    /// Scope.
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
    if leaf.bind.is_some_and(|b| b != key.device_id()) {
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
}

/// What the daemon knows that a chain alone does not say.
pub trait Authority {
    /// Whether `issuer` may sign root grants (an owner device or the daemon).
    fn is_root(&self, issuer: DeviceId) -> bool;

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

    /// Whether `device` was revoked.
    fn device_revoked(&self, device: DeviceId) -> bool {
        let _ = device;
        false
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
    /// Revoked devices.
    pub revoked_devices: HashSet<DeviceId>,
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

    fn device_revoked(&self, device: DeviceId) -> bool {
        self.revoked_devices.contains(&device)
    }
}

/// Scope order without a layout: undecidable pairs pass (the daemon decides them).
struct LocalScopes;

impl LocalScopes {
    fn within(inner: Scope, outer: Scope) -> bool {
        match (inner, outer) {
            (_, Scope::Daemon) => true,
            (Scope::Daemon, _) => false,
            (a, b) if a == b => true,
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
    i: usize,
    scopes: &impl ScopeOrder,
) -> Result<(), GrantError> {
    if !parent.delegate {
        return Err(GrantError::NotDelegable(i));
    }
    if child.roles.effective() == Roles::EMPTY || !parent.roles.covers(child.roles) {
        return Err(GrantError::Escalation(i));
    }
    if !scopes.within(child.scope, parent.scope) {
        return Err(GrantError::ScopeWidened(i));
    }
    match (parent.expires, child.expires) {
        (Some(_), None) => return Err(GrantError::ExpiryWidened(i)),
        (Some(p), Some(c)) if c > p => return Err(GrantError::ExpiryWidened(i)),
        _ => {}
    }
    match (parent.max_uses, child.max_uses) {
        (Some(_), None) => return Err(GrantError::UsesWidened(i)),
        (Some(p), Some(c)) if c > p => return Err(GrantError::UsesWidened(i)),
        _ => {}
    }
    if child.daemon_id != parent.daemon_id {
        return Err(GrantError::WrongDaemon(i));
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
    auth: &impl Authority,
) -> Result<Verified, GrantError> {
    let leaf = chain.leaf().ok_or(GrantError::Empty)?;
    if chain.links.len() > MAX_DEPTH {
        return Err(GrantError::TooDeep);
    }
    if auth.device_revoked(presenter) {
        return Err(GrantError::DeviceRevoked);
    }
    let mut seen = HashSet::new();
    let mut roles = Roles::ALL;
    let mut expires: Option<UnixMillis> = None;
    for (i, link) in chain.links.iter().enumerate() {
        let g = &link.grant;
        if g.v != Grant::VERSION {
            return Err(GrantError::Version(i));
        }
        if g.daemon_id != daemon {
            return Err(GrantError::WrongDaemon(i));
        }
        if !verify_signature(g.issuer, &g.signing_bytes(), &link.sig) {
            return Err(GrantError::BadSignature(i));
        }
        if !seen.insert(g.grant_id) {
            return Err(GrantError::Duplicate(i));
        }
        if auth.device_revoked(g.issuer) || g.bind.is_some_and(|b| auth.device_revoked(b)) {
            return Err(GrantError::DeviceRevoked);
        }
        if auth.grant_revoked(g.grant_id) {
            return Err(GrantError::Revoked(i));
        }
        if g.expires.is_some_and(|e| e <= now) {
            return Err(GrantError::Expired(i));
        }
        if i == 0 {
            if !auth.is_root(g.issuer) {
                return Err(GrantError::UntrustedRoot);
            }
        } else {
            let parent = &chain.links[i - 1].grant;
            let held = match parent.bind {
                Some(bound) => bound == g.issuer,
                None => auth.holds(parent.grant_id, g.issuer),
            };
            if !held {
                return Err(GrantError::NotHolder(i));
            }
            check_narrowing(parent, g, i, &auth)?;
        }
        roles = Roles(roles.0 & g.roles.effective().0);
        expires = match (expires, g.expires) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
    }
    if leaf.bind.is_some_and(|b| b != presenter) {
        return Err(GrantError::BoundElsewhere);
    }
    if roles == Roles::EMPTY {
        return Err(GrantError::Escalation(chain.links.len() - 1));
    }
    Ok(Verified {
        roles,
        scope: leaf.scope,
        expires,
        ids: chain.links.iter().map(|l| l.grant.grant_id).collect(),
        leaf: leaf.clone(),
    })
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

    #[test]
    fn local_scope_order() {
        use proto::{PaneId, SessionId, TabId};
        let s = Scope::Session(SessionId(1));
        let t = Scope::Tab(TabId(1));
        let p = Scope::Pane(PaneId(1));
        assert!(LocalScopes::within(p, Scope::Daemon));
        assert!(LocalScopes::within(t, s));
        assert!(!LocalScopes::within(s, t));
        assert!(!LocalScopes::within(Scope::Daemon, p));
        assert!(!LocalScopes::within(Scope::Pane(PaneId(2)), p));
    }
}
