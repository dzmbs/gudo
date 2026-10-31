//! control leases, presence and the audit log. See docs/DAEMON.md §6.
//!
//! - Every connection has an [`Authz`]: its actor, roles, scope and grant chain. Paired owner
//!   devices get `OWNER` on the whole daemon; guests get what their verified chain says.
//! - [`policy::check`] gates every request; [`Mp::still_valid`] re-checks revocation and
//!   expiry on every message, so a revocation takes effect without waiting for a reconnect.
//! - `<state>/grants.json` holds registered grants, first-use bindings, revocations and the
//!   guest devices; `<state>/audit/audit.jsonl` the audit log.

pub(crate) mod approvals;
pub(crate) mod audit;
pub(crate) mod policy;
mod presence;
pub(crate) mod prompt;

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use grants::{Authority, DeviceKey, GrantError, GrantSpec};
use proto::{
    Actor, Admit, ApprovalPolicy, AuditKind, Caps, CursorPos, DeviceId, DeviceInfo, DeviceKind,
    GrantChain, GrantId, GrantInfo, History, InviteTerms, JoinInfo, Knock, KnockAnswer, KnockId,
    KnockOutcome, KnockUpdate, Lease, LeaseMode, LeaseOutcome, MpError, MpResponse, PaneId,
    Participant, Presence, PresenceState, PrincipalId, RefuseReason, RevokeTarget, Roles, Scope,
    ServerCtl, SessionId, UnixMillis,
};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

pub(crate) use audit::{Audit, Entry as AuditEntry};
pub(crate) use policy::{Need, Target};
pub(crate) use presence::Mailbox;

use crate::core::{ConnId, Core, Event, lock};
use crate::fsutil::{hex, read_optional, unhex, write_atomic};
use crate::identity::{Identity, now_millis};

const STORE_FILE: &str = "grants.json";
/// How long a guest admitted from a knock keeps access unless the owner says otherwise
const KNOCK_ADMIT_TTL: Duration = Duration::from_secs(7 * 24 * 3600);
/// How long an answered knock's connection may stay open: the knocker reads the answer and
/// hangs up itself; closing sooner could drop the answer in flight.
const KNOCK_LINGER: Duration = Duration::from_secs(5);
/// Pending knocks per invite, so a leaked knock link cannot flood the owner.
const MAX_KNOCKS_PER_GRANT: usize = 8;
/// How long a new owner device has to say its name before its pairing is announced without
/// one.
const PAIRING_NAME_WAIT: Duration = Duration::from_secs(3);
/// Presence updates per connection are coalesced to at most one per this interval
const PRESENCE_INTERVAL: Duration = Duration::from_millis(100);

/// What a connection may do, fixed at the handshake.
#[derive(Debug, Clone)]
pub(crate) struct Authz {
    pub actor: Actor,
    pub roles: Roles,
    pub scope: Scope,
    /// Every link of the presented chain, root first (empty for owner devices).
    pub grant_ids: Vec<GrantId>,
    /// Who signed each link, root first (empty for owner devices).
    pub issuers: Vec<DeviceId>,
    /// When the chain's root was signed: a removal of any device in it after this voids it.
    pub root_signed: UnixMillis,
    pub expires: Option<UnixMillis>,
    pub name: String,
    /// How much scrollback it sees (the invite's terms).
    pub history: History,
    /// When this device first redeemed its grant: with [`History::SinceJoin`] it sees only
    /// what panes that existed then wrote afterwards.
    pub joined_at: UnixMillis,
}

impl Authz {
    /// A paired owner device.
    pub fn owner(actor: Actor) -> Self {
        Self {
            actor,
            roles: Roles::OWNER,
            scope: Scope::Daemon,
            grant_ids: Vec::new(),
            issuers: Vec::new(),
            root_signed: UnixMillis(0),
            expires: None,
            name: "owner".into(),
            history: History::Full,
            joined_at: UnixMillis(0),
        }
    }

    /// The leaf grant, if the connection presented one.
    pub fn grant_id(&self) -> Option<GrantId> {
        self.grant_ids.last().copied()
    }

    pub fn join_info(&self, name: &str) -> JoinInfo {
        JoinInfo {
            actor: self.actor,
            name: name.to_owned(),
            roles: self.roles,
            scope: self.scope,
            grant_id: self.grant_id(),
            expires: self.expires,
        }
    }

    pub fn audit(&self) -> AuditEntry {
        AuditEntry {
            actor: Some(self.actor),
            grant_id: self.grant_id(),
            ..AuditEntry::default()
        }
    }
}

// --- persisted state ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Store {
    #[serde(default)]
    grants: Vec<StoredGrant>,
    #[serde(default)]
    revoked_grants: BTreeSet<String>,
    /// The keys of `removed_devices`, as releases before removal times read them.
    #[serde(default)]
    revoked_devices: BTreeSet<String>,
    /// When each revoked guest device was revoked, Unix ms, by device hex: chains it takes
    /// part in count only if their root is newer (owner devices: `unpaired.json`).
    #[serde(default)]
    removed_devices: BTreeMap<String, u64>,
    /// Chains whose root was signed at or before this are void: the store was found
    /// unreadable then, and the revocations and use counts it held are unknown.
    #[serde(default)]
    void_before: Option<u64>,
    /// The reset that set `void_before`, for the owner's alert.
    #[serde(default)]
    reset: Option<Reset>,
    #[serde(default)]
    guests: Vec<GuestRecord>,
    /// Approval policies by session id.
    #[serde(default)]
    policies: BTreeMap<u64, ApprovalPolicy>,
}

/// A grant store found unreadable at startup and replaced.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Reset {
    at: u64,
    /// Where the unreadable file was kept.
    kept_as: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredGrant {
    id: String,
    /// The chain ending in this grant, postcard, hex.
    chain: String,
    /// Devices that redeemed it, hex.
    #[serde(default)]
    bound: Vec<String>,
    registered_at: u64,
    /// Terms the daemon enforces on this grant and everything attenuated from it.
    #[serde(default)]
    terms: InviteTerms,
    /// When each bound device first redeemed it, Unix ms, by device hex.
    #[serde(default)]
    redeemed_at: BTreeMap<String, u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct GuestRecord {
    device: String,
    name: String,
    grant: String,
    first_seen: u64,
    /// When it last redeemed a grant.
    #[serde(default)]
    joined: u64,
}

impl Store {
    /// Reads the store. An unreadable or malformed file is an error, never an empty store:
    /// that would forget every revocation and use count, and readmit whoever they kept out.
    fn load(path: &Path) -> std::io::Result<Self> {
        let Some(bytes) = read_optional(path)? else {
            return Ok(Self::default());
        };
        let mut store: Self = serde_json::from_slice(&bytes)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        // Revocations from before removal times were kept: void everything up to now.
        let now = now_millis();
        for device in std::mem::take(&mut store.revoked_devices) {
            store.removed_devices.entry(device).or_insert(now);
        }
        Ok(store)
    }

    /// The store to start with when `path` cannot be read: the file is moved aside (never
    /// overwritten), owner devices keep working, and every chain signed until now is void,
    /// since which of them were revoked or used up is unknown. Returns whether the new store
    /// may be saved (not if the file could not be moved).
    fn reset(path: &Path, error: &std::io::Error) -> (Self, bool) {
        let now = now_millis();
        let kept = path.with_file_name(format!(
            "{}.unreadable-{now}",
            path.file_name().and_then(|n| n.to_str()).unwrap_or(STORE_FILE)
        ));
        let moved = std::fs::rename(path, &kept);
        match &moved {
            Ok(()) => tracing::error!(
                "{} is unreadable ({error}); kept it as {} and refusing every guest invite \
                 issued until now",
                path.display(),
                kept.display()
            ),
            Err(e) => tracing::error!(
                "{} is unreadable ({error}) and could not be moved aside ({e}); refusing \
                 every guest invite issued until now, and leaving the file as it is",
                path.display()
            ),
        }
        let store = Self {
            void_before: Some(now),
            reset: Some(Reset {
                at: now,
                kept_as: if moved.is_ok() { kept } else { path.to_owned() }
                    .display()
                    .to_string(),
            }),
            ..Self::default()
        };
        (store, moved.is_ok())
    }

    fn save(&mut self, path: &Path) {
        self.revoked_devices = self.removed_devices.keys().cloned().collect();
        let result = serde_json::to_vec_pretty(self)
            .map_err(std::io::Error::other)
            .and_then(|bytes| write_atomic(path, &bytes));
        if let Err(e) = result {
            tracing::warn!("saving {}: {e}", path.display());
        }
    }

    fn grant(&self, id: GrantId) -> Option<&StoredGrant> {
        let id = hex(&id.0);
        self.grants.iter().find(|g| g.id == id)
    }

    fn grant_revoked(&self, id: GrantId) -> bool {
        self.revoked_grants.contains(&hex(&id.0))
    }

    fn guest_removed_at(&self, device: DeviceId) -> Option<UnixMillis> {
        self.removed_devices
            .get(&hex(&device.0))
            .map(|&at| UnixMillis(at))
    }

    /// Records `chain`'s leaf if new; returns its record.
    fn upsert(&mut self, chain: &GrantChain) -> &mut StoredGrant {
        let id = hex(&chain.grant_id().0);
        if let Some(i) = self.grants.iter().position(|g| g.id == id) {
            return &mut self.grants[i];
        }
        self.grants.push(StoredGrant {
            id,
            chain: hex(&chain.to_token()),
            bound: Vec::new(),
            registered_at: now_millis(),
            terms: InviteTerms::default(),
            redeemed_at: BTreeMap::new(),
        });
        self.grants.last_mut().expect("just pushed")
    }

    /// The terms in force for a chain: the strictest of every registered link's.
    fn terms(&self, ids: &[GrantId]) -> InviteTerms {
        ids.iter()
            .filter_map(|&id| self.grant(id))
            .fold(InviteTerms::default(), |acc, g| acc.strictest(g.terms))
    }

    fn chain_of(g: &StoredGrant) -> Option<GrantChain> {
        let bytes = unhex_vec(&g.chain)?;
        GrantChain::from_token(&bytes).ok()
    }
}

/// An owner device's display name: what it called itself, or "owner" until it said.
fn owner_name(name: String) -> String {
    if name.is_empty() { "owner".into() } else { name }
}

fn unhex_vec(s: &str) -> Option<Vec<u8>> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok())
        .collect()
}

/// The daemon's view for [`grants::verify`].
struct DaemonAuthority<'a> {
    core: &'a Core,
    store: &'a Store,
}

impl Authority for DaemonAuthority<'_> {
    fn is_root(&self, issuer: DeviceId) -> bool {
        issuer == self.core.identity.daemon_device() || self.core.identity.is_owner_device(issuer)
    }

    fn holds(&self, grant: GrantId, device: DeviceId) -> bool {
        let device = hex(&device.0);
        self.store
            .grant(grant)
            .is_some_and(|g| g.bound.contains(&device))
    }

    fn scope_within(&self, inner: Scope, outer: Scope) -> bool {
        self.core.scope_within(inner, outer)
    }

    fn grant_revoked(&self, grant: GrantId) -> bool {
        self.store.grant_revoked(grant)
    }

    fn removed_at(&self, device: DeviceId) -> Option<UnixMillis> {
        removed_at(&self.core.identity, self.store, device)
    }

    fn void_before(&self) -> Option<UnixMillis> {
        self.store.void_before.map(UnixMillis)
    }
}

/// When `device` was last unpaired or revoked.
fn removed_at(identity: &Identity, store: &Store, device: DeviceId) -> Option<UnixMillis> {
    identity
        .removed_at(device)
        .max(store.guest_removed_at(device))
}

// --- live state --------------------------------------------------------------------------------

struct Live {
    authz: Authz,
    name: String,
    since: UnixMillis,
    state: PresenceState,
    focus: Option<PaneId>,
    typing: bool,
    cursor: Option<CursorPos>,
    last_presence: Option<Instant>,
    peer: presence::PeerState,
    ctl: mpsc::UnboundedSender<ServerCtl>,
    conn: iroh::endpoint::Connection,
}

struct LeaseState {
    holder: Option<Actor>,
    since: UnixMillis,
    last_input: Instant,
    pending: Option<(Actor, String)>,
}

impl LeaseState {
    fn free() -> Self {
        Self {
            holder: None,
            since: UnixMillis(0),
            last_input: Instant::now(),
            pending: None,
        }
    }

    fn wire(&self, pane_id: PaneId) -> Lease {
        Lease {
            pane_id,
            holder: self.holder.map(|a| a.principal),
            since: self.since,
            mode: if self.holder.is_some() {
                LeaseMode::Leased
            } else {
                LeaseMode::Free
            },
        }
    }
}

/// What redeeming a grant chain led to.
pub(crate) enum Redeemed {
    /// The connection joins with these rights.
    Joined(Authz),
    /// The chain is a knock invite: the connection waits for an owner.
    Knock(Knocker),
}

/// Someone presenting a knock invite.
#[derive(Debug, Clone)]
pub(crate) struct Knocker {
    pub actor: Actor,
    pub name: String,
    /// Every link of the presented chain, root first.
    pub grant_ids: Vec<GrantId>,
    /// Who signed each link, root first.
    pub issuers: Vec<DeviceId>,
    pub root_signed: UnixMillis,
    pub roles: Roles,
    pub scope: Scope,
    pub expires: Option<UnixMillis>,
}

/// A knock waiting for an owner, with the knocking connection.
struct PendingKnock {
    knock: Knock,
    grant_ids: Vec<GrantId>,
    issuers: Vec<DeviceId>,
    root_signed: UnixMillis,
    expires: Option<UnixMillis>,
    ctl: mpsc::UnboundedSender<ServerCtl>,
    conn: iroh::endpoint::Connection,
}

/// Multiplayer state owned by the core.
pub(crate) struct Mp {
    /// Which owner devices may root a grant chain.
    identity: Arc<Identity>,
    store_path: PathBuf,
    store: Mutex<Store>,
    /// False while an unreadable store sits where it would be saved.
    persist: bool,
    live: Mutex<HashMap<ConnId, Live>>,
    leases: Mutex<HashMap<PaneId, LeaseState>>,
    knocks: Mutex<BTreeMap<KnockId, PendingKnock>>,
    /// Owner devices that just paired and were not announced yet, with when.
    unannounced: Mutex<HashMap<DeviceId, (PrincipalId, UnixMillis)>>,
    next_knock: AtomicU64,
    /// Votes and claims of open approval requests.
    pub approvals: approvals::Approvals,
    pub audit: Audit,
    lease_idle: Duration,
    times: crate::config::PresenceTimes,
    /// The newest live-presence revision handed out.
    peer_rev: AtomicU64,
}

impl Mp {
    pub fn open(
        state_dir: &Path,
        identity: Arc<Identity>,
        lease_idle: Duration,
        times: crate::config::PresenceTimes,
    ) -> std::io::Result<Self> {
        let store_path = state_dir.join(STORE_FILE);
        let audit = Audit::open(state_dir)?;
        let (mut store, persist) = match Store::load(&store_path) {
            Ok(store) => (store, true),
            Err(e) => {
                let (store, persist) = Store::reset(&store_path, &e);
                audit.append(
                    AuditKind::Revoked,
                    AuditEntry {
                        detail: format!(
                            "{STORE_FILE} was unreadable ({e}); every invite issued until now \
                             is refused"
                        ),
                        ..AuditEntry::default()
                    },
                );
                (store, persist)
            }
        };
        if persist {
            store.save(&store_path);
        }
        Ok(Self {
            identity,
            store: Mutex::new(store),
            persist,
            store_path,
            live: Mutex::new(HashMap::new()),
            leases: Mutex::new(HashMap::new()),
            knocks: Mutex::new(BTreeMap::new()),
            unannounced: Mutex::new(HashMap::new()),
            next_knock: AtomicU64::new(1),
            approvals: approvals::Approvals::default(),
            audit,
            lease_idle,
            times,
            peer_rev: AtomicU64::new(0),
        })
    }

    fn save(&self, store: &mut Store) {
        if self.persist {
            store.save(&self.store_path);
        }
    }

    /// A device just paired: audit it now, and announce it to the other owner devices once
    /// it says its name (or after [`PAIRING_NAME_WAIT`]), so the alert can name it.
    pub fn paired(&self, core: &Arc<Core>, actor: Actor) {
        self.audit.append(
            AuditKind::Paired,
            AuditEntry {
                actor: Some(actor),
                detail: "paired a new owner device".into(),
                ..AuditEntry::default()
            },
        );
        lock(&self.unannounced).insert(actor.device, (actor.principal, UnixMillis(now_millis())));
        let core = Arc::clone(core);
        tokio::spawn(async move {
            tokio::time::sleep(PAIRING_NAME_WAIT).await;
            core.mp.announce_pairing(&core, actor.device);
        });
    }

    /// Tells every other owner device that `device` paired, once: a phished ticket must not
    /// pair unnoticed.
    fn announce_pairing(&self, core: &Core, device: DeviceId) {
        let Some((principal, at)) = lock(&self.unannounced).remove(&device) else {
            return;
        };
        let name = self
            .identity
            .paired()
            .into_iter()
            .find(|o| o.device == device)
            .map(|o| o.name)
            .unwrap_or_default();
        core.emit(Event::DevicePaired(DeviceInfo {
            device,
            principal,
            kind: DeviceKind::Owner,
            name: owner_name(name),
            first_seen: at,
            grant_id: None,
            revoked: false,
            connected: 1,
        }));
    }

    /// What owner devices should be told about the store when they connect.
    pub fn host_alert(&self) -> Option<proto::HostAlert> {
        let store = lock(&self.store);
        let reset = store.reset.as_ref()?;
        Some(proto::HostAlert {
            kind: proto::HostAlertKind::GrantStoreReset,
            at: UnixMillis(reset.at),
            title: "Sharing was reset on this host".into(),
            body: format!(
                "The host could not read its list of invites, so every invite made before \
                 then no longer works. Owner devices are not affected. Send new invites to \
                 people who should still have access. The unreadable file was kept as {}.",
                reset.kept_as
            ),
        })
    }

    /// Whether `device` was removed or revoked and is not paired now: it is told it was
    /// revoked rather than that its grant is unknown.
    pub fn device_removed(&self, device: DeviceId) -> bool {
        !self.identity.is_owner_device(device)
            && removed_at(&self.identity, &lock(&self.store), device).is_some()
    }

    /// Whether the chain `ids`, signed by `issuers` (root first, root signed at
    /// `root_signed`) and presented by `presenter`, is still in force: unexpired, no link
    /// revoked, its root still trusted, and no device in it removed since the root was
    /// signed.
    fn chain_live(
        &self,
        store: &Store,
        ids: &[GrantId],
        issuers: &[DeviceId],
        root_signed: UnixMillis,
        presenter: DeviceId,
        expires: Option<UnixMillis>,
    ) -> bool {
        expires.is_none_or(|e| e.0 > now_millis())
            && self.chain_trusted(issuers)
            && store.void_before.is_none_or(|t| root_signed.0 > t)
            && !ids.iter().any(|&g| store.grant_revoked(g))
            && issuers
                .iter()
                .chain([&presenter])
                .all(|&d| removed_at(&self.identity, store, d).is_none_or(|t| root_signed > t))
    }

    /// Verifies a presented grant chain for `device`, binding an unbound leaf on first use.
    /// A knock invite neither binds nor uses up anything: the device waits for an owner
    /// (only clients announcing [`Caps::KNOCK`] can).
    pub fn redeem(
        &self,
        core: &Core,
        device: DeviceId,
        claimed: PrincipalId,
        token: &[u8],
        caps: Caps,
    ) -> Result<Redeemed, RefuseReason> {
        let actor = grants::guest_actor(device);
        let deny = |why: String| {
            self.audit.append(
                AuditKind::Denied,
                AuditEntry {
                    actor: Some(actor),
                    detail: format!("join refused: {why}"),
                    ..AuditEntry::default()
                },
            );
        };
        let Ok(chain) = GrantChain::from_token(token) else {
            deny("malformed grant".into());
            return Err(RefuseReason::InvalidGrant);
        };
        if claimed != actor.principal {
            deny("principal does not match the device key".into());
            return Err(RefuseReason::InvalidGrant);
        }
        let now = UnixMillis(now_millis());
        let mut store = lock(&self.store);
        let verified = {
            let auth = DaemonAuthority {
                core,
                store: &store,
            };
            grants::verify(&chain, core.identity.daemon_id(), device, now, &auth)
        };
        let verified = match verified {
            Ok(v) => v,
            Err(e) => {
                drop(store);
                deny(e.to_string());
                return Err(match e {
                    GrantError::Revoked(_) | GrantError::DeviceRevoked => RefuseReason::Revoked,
                    _ => RefuseReason::InvalidGrant,
                });
            }
        };
        let device_hex = hex(&device.0);
        let issuers: Vec<DeviceId> = chain.links.iter().map(|l| l.grant.issuer).collect();
        let root_signed = chain.links[0].grant.issued_at;
        let leaf = &verified.leaf;
        let terms = store.terms(&verified.ids);
        let admitted = store
            .grant(leaf.grant_id)
            .is_some_and(|g| g.bound.contains(&device_hex));
        if terms.knock && !admitted {
            drop(store);
            if !caps.contains(Caps::KNOCK) {
                deny("knock invite from an app that cannot wait for the owner".into());
                return Err(RefuseReason::InvalidGrant);
            }
            return Ok(Redeemed::Knock(Knocker {
                actor,
                name: leaf.label.clone(),
                grant_ids: verified.ids,
                issuers,
                root_signed,
                roles: verified.roles,
                scope: verified.scope,
                expires: verified.expires,
            }));
        }
        let record = store.upsert(&chain);
        let first_use = !record.bound.contains(&device_hex);
        if first_use {
            if leaf
                .max_uses
                .is_some_and(|max| record.bound.len() as u32 >= max)
            {
                drop(store);
                deny("grant used up".into());
                return Err(RefuseReason::InvalidGrant);
            }
            record.bound.push(device_hex.clone());
            record.redeemed_at.insert(device_hex.clone(), now.0);
        }
        let joined_at = UnixMillis(
            record
                .redeemed_at
                .get(&device_hex)
                .copied()
                .unwrap_or(now.0),
        );
        let name = if leaf.label.is_empty() {
            format!("guest-{}", &device_hex[..6])
        } else {
            leaf.label.clone()
        };
        if let Some(g) = store.guests.iter_mut().find(|g| g.device == device_hex) {
            g.grant = hex(&leaf.grant_id.0);
            g.joined = now.0;
        } else {
            store.guests.push(GuestRecord {
                device: device_hex,
                name: name.clone(),
                grant: hex(&leaf.grant_id.0),
                first_seen: now.0,
                joined: now.0,
            });
        }
        self.save(&mut store);
        drop(store);
        let authz = Authz {
            actor,
            roles: verified.roles,
            scope: verified.scope,
            grant_ids: verified.ids,
            issuers,
            root_signed,
            expires: verified.expires,
            name,
            history: terms.history,
            joined_at,
        };
        if first_use {
            self.audit.append(
                AuditKind::GrantRedeemed,
                AuditEntry {
                    detail: format!(
                        "{} redeemed {} on {}",
                        authz.name,
                        authz.roles.names(),
                        authz.scope
                    ),
                    ..authz.audit()
                },
            );
        }
        Ok(Redeemed::Joined(authz))
    }

    /// Whether `authz` is still in force: unexpired, no link, signer or device revoked, and
    /// its root still trusted (an owner device unpaired, even by `hostd unpair`, takes the
    /// connection and every invite it signed with it).
    pub fn still_valid(&self, authz: &Authz) -> bool {
        if authz.grant_ids.is_empty() {
            return self.identity.is_owner_device(authz.actor.device);
        }
        self.chain_live(
            &lock(&self.store),
            &authz.grant_ids,
            &authz.issuers,
            authz.root_signed,
            authz.actor.device,
            authz.expires,
        )
    }

    /// Whether a chain signed by `issuers` (root first) still has a trusted root.
    fn chain_trusted(&self, issuers: &[DeviceId]) -> bool {
        issuers.first().is_some_and(|&root| {
            root == self.identity.daemon_device() || self.identity.is_owner_device(root)
        })
    }

    // --- participants -----------------------------------------------------------------------

    /// A connection joined; `heartbeats` when it announced live presence.
    pub fn join(
        &self,
        core: &Core,
        id: ConnId,
        authz: &Authz,
        heartbeats: bool,
        ctl: mpsc::UnboundedSender<ServerCtl>,
        conn: iroh::endpoint::Connection,
    ) {
        lock(&self.live).insert(
            id,
            Live {
                authz: authz.clone(),
                name: authz.name.clone(),
                since: UnixMillis(now_millis()),
                state: PresenceState::Active,
                focus: None,
                typing: false,
                cursor: None,
                last_presence: None,
                peer: presence::PeerState::new(heartbeats),
                ctl,
                conn,
            },
        );
        self.audit.append(
            AuditKind::Join,
            AuditEntry {
                detail: format!(
                    "{} joined as {} on {}",
                    authz.name,
                    authz.roles.names(),
                    authz.scope
                ),
                ..authz.audit()
            },
        );
        core.emit(Event::Participants);
    }

    pub fn leave(&self, core: &Core, id: ConnId) {
        let Some(live) = lock(&self.live).remove(&id) else {
            return;
        };
        self.audit.append(
            AuditKind::Leave,
            AuditEntry {
                detail: format!("{} left", live.name),
                ..live.authz.audit()
            },
        );
        // The lease goes when the holder's last device leaves.
        let principal = live.authz.actor.principal;
        if !self.principal_connected(principal) {
            let released: Vec<Lease> = {
                let mut leases = lock(&self.leases);
                leases
                    .iter_mut()
                    .filter(|(_, l)| l.holder.is_some_and(|h| h.principal == principal))
                    .map(|(pane, l)| {
                        l.holder = None;
                        l.pending = None;
                        l.since = UnixMillis(now_millis());
                        l.wire(*pane)
                    })
                    .collect()
            };
            for lease in released {
                core.emit(Event::Lease(lease));
            }
        }
        core.emit(Event::Participants);
    }

    fn principal_connected(&self, principal: PrincipalId) -> bool {
        lock(&self.live)
            .values()
            .any(|l| l.authz.actor.principal == principal)
    }

    /// The participant list as `viewer` may see it: focus and cursor outside its scope are
    /// hidden.
    pub fn participants(&self, core: &Core, viewer: &Authz) -> Vec<Participant> {
        let live: Vec<Participant> = lock(&self.live)
            .values()
            .map(|l| Participant {
                actor: l.authz.actor,
                name: l.name.clone(),
                roles: l.authz.roles,
                scope: l.authz.scope,
                grant_id: l.authz.grant_id(),
                since: l.since,
                // Live presence knows better than the old self-reported state.
                state: if l.peer.rev > 0 {
                    self.state_of(l)
                } else {
                    l.state
                },
                focus: l.focus,
                typing: l.typing || l.peer.typing.is_some(),
                cursor: l.cursor,
            })
            .collect();
        let mut out: Vec<Participant> = live
            .into_iter()
            .map(|mut p| {
                if p.focus
                    .is_some_and(|f| !core.scope_within(Scope::Pane(f), viewer.scope))
                {
                    p.focus = None;
                    p.typing = false;
                }
                if p.cursor
                    .is_some_and(|c| !core.scope_within(Scope::Pane(c.pane_id), viewer.scope))
                {
                    p.cursor = None;
                }
                p
            })
            .collect();
        out.sort_by_key(|p| p.since);
        out
    }

    pub fn name_of(&self, id: ConnId) -> String {
        lock(&self.live)
            .get(&id)
            .map(|l| l.name.clone())
            .unwrap_or_default()
    }

    pub fn set_name(&self, core: &Core, id: ConnId, name: String) {
        let name: String = name.trim().chars().take(64).collect();
        let owner_device = lock(&self.live).get_mut(&id).and_then(|l| {
            l.name.clone_from(&name);
            l.authz.grant_ids.is_empty().then_some(l.authz.actor.device)
        });
        if let Some(device) = owner_device.filter(|_| !name.is_empty()) {
            self.identity.set_name(device, &name);
            self.announce_pairing(core, device);
        }
        core.emit(Event::Participants);
    }

    /// The connection's focused pane changed (from `Focus`).
    pub fn set_focus(&self, core: &Core, id: ConnId, focus: Option<PaneId>) {
        let changed = lock(&self.live).get_mut(&id).is_some_and(|l| {
            let changed = l.focus != focus;
            l.focus = focus;
            l.state = PresenceState::Active;
            l.peer.active = Instant::now();
            if changed {
                self.bump(l);
            }
            changed
        });
        if changed {
            core.emit(Event::Participants);
        }
    }

    /// A `Presence` from the client. The daemon stamps the actor and the focus it knows.
    pub fn presence(&self, core: &Core, id: ConnId, p: Presence) {
        let out = {
            let mut live = lock(&self.live);
            let Some(l) = live.get_mut(&id) else { return };
            let typing_changed = l.typing != p.typing;
            if !typing_changed
                && l.last_presence
                    .is_some_and(|t| t.elapsed() < PRESENCE_INTERVAL)
            {
                return;
            }
            l.last_presence = Some(Instant::now());
            l.state = p.state;
            l.typing = p.typing;
            l.cursor = p.cursor;
            if let Some(f) = p.focus {
                l.focus = Some(f);
            }
            Presence {
                actor: l.authz.actor,
                state: l.state,
                focus: l.focus,
                typing: l.typing,
                viewport: p.viewport,
                cursor: l.cursor,
            }
        };
        core.emit(Event::Presence(out));
    }

    // --- grants -----------------------------------------------------------------------------

    /// Records a chain so it is listed and revocable before first use, with `terms` the
    /// daemon enforces on it and its descendants (terms only ever get stricter).
    pub fn register(
        &self,
        core: &Core,
        by: &Authz,
        chain: &GrantChain,
        terms: InviteTerms,
    ) -> Result<GrantInfo, MpError> {
        let leaf = chain
            .leaf()
            .ok_or_else(|| MpError::Invalid("empty grant chain".into()))?;
        let owner = by.roles.allows_any(Roles::OWNER) && by.scope == Scope::Daemon;
        if !owner && leaf.issuer != by.actor.device {
            return Err(MpError::Forbidden(
                "only an owner or the grant's issuer may register it".into(),
            ));
        }
        let presenter = leaf.bind.unwrap_or(by.actor.device);
        let now = UnixMillis(now_millis());
        let mut store = lock(&self.store);
        {
            let auth = DaemonAuthority {
                core,
                store: &store,
            };
            grants::verify(chain, core.identity.daemon_id(), presenter, now, &auth)
                .map_err(|e| MpError::Invalid(e.to_string()))?;
        }
        let record = store.upsert(chain);
        record.terms = record.terms.strictest(terms);
        let terms = record.terms;
        self.save(&mut store);
        let info = self.info(&store, chain);
        drop(store);
        let mut extra = String::new();
        if terms.knock {
            extra.push_str(", knock to join");
        }
        if terms.history == History::SinceJoin {
            extra.push_str(", scrollback since joining");
        }
        self.audit.append(
            AuditKind::GrantRegistered,
            AuditEntry {
                detail: if leaf.label.is_empty() {
                    format!(
                        "grant {}: {} on {}{extra}",
                        short(&leaf.grant_id.0),
                        leaf.roles.names(),
                        leaf.scope
                    )
                } else {
                    format!(
                        "grant {} for {:?}: {} on {}{extra}",
                        short(&leaf.grant_id.0),
                        leaf.label,
                        leaf.roles.names(),
                        leaf.scope
                    )
                },
                ..by.audit()
            },
        );
        Ok(info)
    }

    fn info(&self, store: &Store, chain: &GrantChain) -> GrantInfo {
        let leaf = chain.leaf().cloned().expect("non-empty chain");
        let bound = store
            .grant(leaf.grant_id)
            .map(|g| {
                g.bound
                    .iter()
                    .filter_map(|d| unhex(d).map(DeviceId))
                    .collect()
            })
            .unwrap_or_default();
        GrantInfo {
            parent: chain
                .links
                .len()
                .checked_sub(2)
                .map(|i| chain.links[i].grant.grant_id),
            revoked: chain
                .links
                .iter()
                .any(|l| store.grant_revoked(l.grant.grant_id))
                || !self.chain_live(
                    store,
                    &[],
                    &chain.links.iter().map(|l| l.grant.issuer).collect::<Vec<_>>(),
                    chain.links[0].grant.issued_at,
                    leaf.issuer,
                    None,
                ),
            grant: leaf,
            bound,
        }
    }

    pub fn list_grants(&self) -> Vec<GrantInfo> {
        let store = lock(&self.store);
        store
            .grants
            .iter()
            .filter_map(Store::chain_of)
            .map(|c| self.info(&store, &c))
            .collect()
    }

    /// A registered grant's chain and terms, for sharing its link again.
    pub fn invite_link(&self, id: GrantId) -> Result<MpResponse, MpError> {
        let store = lock(&self.store);
        let stored = store
            .grant(id)
            .ok_or_else(|| MpError::NotFound(format!("grant {}", hex(&id.0))))?;
        let chain = Store::chain_of(stored)
            .ok_or_else(|| MpError::Failed("stored grant chain is unreadable".into()))?;
        Ok(MpResponse::InviteLink {
            chain,
            terms: stored.terms,
        })
    }

    pub fn list_devices(&self, core: &Core) -> Vec<DeviceInfo> {
        let connected = |d: DeviceId| {
            lock(&self.live)
                .values()
                .filter(|l| l.authz.actor.device == d)
                .count() as u32
        };
        let store = lock(&self.store).clone();
        let mut out: Vec<DeviceInfo> = core
            .identity
            .paired()
            .into_iter()
            .map(|o| DeviceInfo {
                device: o.device,
                principal: o.principal,
                kind: DeviceKind::Owner,
                name: owner_name(o.name),
                first_seen: o.paired_at,
                grant_id: None,
                revoked: false,
                connected: connected(o.device),
            })
            .collect();
        out.extend(store.guests.iter().filter_map(|g| {
            let device = DeviceId(unhex(&g.device)?);
            Some(DeviceInfo {
                device,
                principal: grants::guest_principal(device),
                kind: DeviceKind::Guest,
                name: g.name.clone(),
                first_seen: UnixMillis(g.first_seen),
                grant_id: unhex(&g.grant).map(GrantId),
                revoked: store.guest_removed_at(device).is_some_and(|t| g.joined <= t.0),
                connected: connected(device),
            })
        }));
        out
    }

    /// Revokes and disconnects everyone it affects.
    pub fn revoke(
        &self,
        core: &Core,
        by: &Authz,
        target: RevokeTarget,
    ) -> Result<MpResponse, MpError> {
        let mut grants_hit = Vec::new();
        let mut devices_hit = Vec::new();
        match target {
            RevokeTarget::Grant(g) => grants_hit.push(g),
            RevokeTarget::Device(d) => devices_hit.push(d),
            RevokeTarget::Principal(p) => {
                devices_hit.extend(
                    core.identity
                        .paired()
                        .into_iter()
                        .filter(|o| o.principal == p)
                        .map(|o| o.device),
                );
                let store = lock(&self.store);
                devices_hit.extend(
                    store
                        .guests
                        .iter()
                        .filter_map(|g| unhex(&g.device).map(DeviceId))
                        .filter(|&d| grants::guest_principal(d) == p),
                );
                drop(store);
                devices_hit.extend(
                    lock(&self.live)
                        .values()
                        .map(|l| l.authz.actor)
                        .filter(|a| a.principal == p)
                        .map(|a| a.device),
                );
                devices_hit.sort();
                devices_hit.dedup();
            }
        }
        if devices_hit.contains(&by.actor.device) {
            return Err(MpError::Conflict(
                "refusing to revoke the device making the request".into(),
            ));
        }
        if grants_hit.is_empty() && devices_hit.is_empty() {
            return Err(MpError::NotFound("nothing to revoke".into()));
        }
        {
            let mut store = lock(&self.store);
            // Descendants: registered chains that pass through a revoked grant.
            let hit: HashSet<GrantId> = grants_hit.iter().copied().collect();
            let descendants: Vec<GrantId> = store
                .grants
                .iter()
                .filter_map(Store::chain_of)
                .filter(|c| c.links.iter().any(|l| hit.contains(&l.grant.grant_id)))
                .map(|c| c.grant_id())
                .filter(|g| !hit.contains(g))
                .collect();
            for g in &grants_hit {
                store.revoked_grants.insert(hex(&g.0));
            }
            grants_hit.extend(descendants);
            // An owner device is unpaired (`unpaired.json` keeps when); a guest's removal
            // is kept here. Either way what it signed or joined with until now stays void.
            let now = now_millis();
            for &d in &devices_hit {
                if !core.identity.unpair(d) {
                    store.removed_devices.insert(hex(&d.0), now);
                }
            }
            self.save(&mut store);
        }
        let disconnected = self.kick_invalid();
        let detail = format!(
            "revoked {} grant(s) {}, {} device(s) {}; {disconnected} connection(s) closed",
            grants_hit.len(),
            grants_hit
                .iter()
                .map(|g| short(&g.0))
                .collect::<Vec<_>>()
                .join(","),
            devices_hit.len(),
            devices_hit
                .iter()
                .map(|d| short(&d.0))
                .collect::<Vec<_>>()
                .join(","),
        );
        self.audit.append(
            AuditKind::Revoked,
            AuditEntry {
                detail,
                ..by.audit()
            },
        );
        Ok(MpResponse::Revoked {
            grants: grants_hit,
            devices: devices_hit,
            disconnected,
        })
    }

    /// Disconnects every connection whose grant is no longer valid. Returns how many.
    pub fn kick_invalid(&self) -> u32 {
        let doomed: Vec<(
            Option<GrantId>,
            mpsc::UnboundedSender<ServerCtl>,
            iroh::endpoint::Connection,
        )> = {
            let live = lock(&self.live);
            live.values()
                .filter(|l| !self.still_valid(&l.authz))
                .map(|l| (l.authz.grant_id(), l.ctl.clone(), l.conn.clone()))
                .collect()
        };
        let n = doomed.len() as u32;
        for (grant, ctl, conn) in doomed {
            kick(grant, &ctl, conn);
        }
        n
    }


    /// Puts a knock in front of the owners. The same device knocking again replaces its
    /// earlier knock.
    ///
    /// # Errors
    ///
    /// [`RefuseReason::InvalidGrant`] when the invite already has
    /// [`MAX_KNOCKS_PER_GRANT`] knocks waiting.
    pub fn knock(
        &self,
        core: &Core,
        knocker: Knocker,
        ctl: mpsc::UnboundedSender<ServerCtl>,
        conn: iroh::endpoint::Connection,
    ) -> Result<KnockId, RefuseReason> {
        let leaf = knocker
            .grant_ids
            .last()
            .copied()
            .unwrap_or(GrantId([0; 16]));
        let name = if knocker.name.is_empty() {
            format!("guest-{}", &hex(&knocker.actor.device.0)[..6])
        } else {
            knocker.name.clone()
        };
        let mut knocks = lock(&self.knocks);
        let replaced: Vec<KnockId> = knocks
            .iter()
            .filter(|(_, k)| k.knock.actor.device == knocker.actor.device)
            .map(|(id, _)| *id)
            .collect();
        for id in &replaced {
            knocks.remove(id);
        }
        let waiting = knocks.values().filter(|k| k.knock.grant_id == leaf).count();
        if waiting >= MAX_KNOCKS_PER_GRANT {
            drop(knocks);
            self.audit.append(
                AuditKind::Denied,
                AuditEntry {
                    actor: Some(knocker.actor),
                    grant_id: Some(leaf),
                    detail: format!("knock from {name} refused: too many waiting on this invite"),
                    ..AuditEntry::default()
                },
            );
            return Err(RefuseReason::InvalidGrant);
        }
        let knock_id = KnockId(self.next_knock.fetch_add(1, Ordering::Relaxed));
        let knock = Knock {
            knock_id,
            actor: knocker.actor,
            name,
            grant_id: leaf,
            roles: knocker.roles,
            scope: knocker.scope,
            at: UnixMillis(now_millis()),
        };
        knocks.insert(
            knock_id,
            PendingKnock {
                knock: knock.clone(),
                grant_ids: knocker.grant_ids,
                issuers: knocker.issuers,
                root_signed: knocker.root_signed,
                expires: knocker.expires,
                ctl,
                conn,
            },
        );
        drop(knocks);
        for id in replaced {
            core.emit(Event::Knock(KnockUpdate::Gone {
                knock_id: id,
                outcome: KnockOutcome::Withdrawn,
                by: None,
            }));
        }
        self.audit.append(
            AuditKind::Knock,
            AuditEntry {
                actor: Some(knock.actor),
                grant_id: Some(leaf),
                detail: format!(
                    "{} knocked to join as {} on {}",
                    knock.name,
                    knock.roles.names(),
                    knock.scope
                ),
                ..AuditEntry::default()
            },
        );
        core.emit(Event::Knock(KnockUpdate::Added(knock)));
        Ok(knock_id)
    }

    /// The knocker gave their name.
    pub fn rename_knock(&self, core: &Core, id: KnockId, name: &str) {
        let name: String = name.trim().chars().take(64).collect();
        if name.is_empty() {
            return;
        }
        let updated = lock(&self.knocks).get_mut(&id).map(|k| {
            k.knock.name = name;
            k.knock.clone()
        });
        if let Some(knock) = updated {
            core.emit(Event::Knock(KnockUpdate::Added(knock)));
        }
    }

    /// The knocker stopped waiting (disconnected). No-op once answered.
    pub fn withdraw_knock(&self, core: &Core, id: KnockId) {
        let Some(gone) = lock(&self.knocks).remove(&id) else {
            return;
        };
        self.audit.append(
            AuditKind::KnockAnswered,
            AuditEntry {
                actor: Some(gone.knock.actor),
                grant_id: Some(gone.knock.grant_id),
                detail: format!("{} stopped waiting", gone.knock.name),
                ..AuditEntry::default()
            },
        );
        core.emit(Event::Knock(KnockUpdate::Gone {
            knock_id: id,
            outcome: KnockOutcome::Withdrawn,
            by: None,
        }));
    }

    /// Knocks waiting for an owner, oldest first.
    pub fn knocks(&self) -> Vec<Knock> {
        lock(&self.knocks)
            .values()
            .map(|k| k.knock.clone())
            .collect()
    }

    /// An owner's answer: admit with roles (a fresh grant bound to the knocking device, signed
    /// by the daemon, on the invite's scope) or deny. The knocking connection is told and
    /// closed; an admitted guest reconnects with the new grant.
    ///
    /// # Errors
    ///
    /// [`MpError::NotFound`] if the knock is no longer waiting, [`MpError::Invalid`] for an
    /// admission without roles, [`MpError::Conflict`] if the invite was revoked meanwhile.
    pub fn answer_knock(
        &self,
        core: &Core,
        by: &Authz,
        id: KnockId,
        admit: Option<Admit>,
    ) -> Result<MpResponse, MpError> {
        if admit.is_some_and(|a| a.roles == Roles::EMPTY) {
            return Err(MpError::Invalid("admit with at least one role".into()));
        }
        let pending = lock(&self.knocks)
            .remove(&id)
            .ok_or_else(|| MpError::NotFound("that knock is no longer waiting".into()))?;
        let knock = &pending.knock;
        let now = UnixMillis(now_millis());
        let invite_valid = self.chain_live(
            &lock(&self.store),
            &pending.grant_ids,
            &pending.issuers,
            pending.root_signed,
            knock.actor.device,
            pending.expires,
        );
        let (answer, outcome, response) = match admit {
            Some(admit) if invite_valid => {
                let (chain, info) = self.admit(core, knock, admit, now)?;
                (
                    KnockAnswer::Admitted(chain),
                    KnockOutcome::Admitted { roles: admit.roles },
                    MpResponse::Admitted(info),
                )
            }
            Some(_) => {
                let _ = pending
                    .ctl
                    .send(ServerCtl::KnockAnswer(KnockAnswer::Denied));
                close_soon(pending.conn.clone(), KNOCK_LINGER, b"invite revoked");
                core.emit(Event::Knock(KnockUpdate::Gone {
                    knock_id: id,
                    outcome: KnockOutcome::Denied,
                    by: Some(by.actor),
                }));
                return Err(MpError::Conflict(
                    "the invite was revoked or expired while they waited".into(),
                ));
            }
            None => (KnockAnswer::Denied, KnockOutcome::Denied, MpResponse::Done),
        };
        let _ = pending.ctl.send(ServerCtl::KnockAnswer(answer));
        close_soon(pending.conn.clone(), KNOCK_LINGER, b"knock answered");
        let detail = match outcome {
            KnockOutcome::Admitted { roles } => format!(
                "admitted {} as {} on {}",
                knock.name,
                roles.names(),
                knock.scope
            ),
            _ => format!("turned {} away", knock.name),
        };
        self.audit.append(
            AuditKind::KnockAnswered,
            AuditEntry {
                detail,
                ..by.audit()
            },
        );
        core.emit(Event::Knock(KnockUpdate::Gone {
            knock_id: id,
            outcome,
            by: Some(by.actor),
        }));
        Ok(response)
    }

    /// Mints and records the grant an admitted knocker joins with.
    fn admit(
        &self,
        core: &Core,
        knock: &Knock,
        admit: Admit,
        now: UnixMillis,
    ) -> Result<(GrantChain, GrantInfo), MpError> {
        let key = DeviceKey::from_seed(&core.identity.secret.to_bytes())
            .map_err(|e| MpError::Failed(e.to_string()))?;
        let mut spec = GrantSpec::new(admit.roles, knock.scope);
        spec.expires = Some(
            admit
                .expires
                .unwrap_or(UnixMillis(now.0 + KNOCK_ADMIT_TTL.as_millis() as u64)),
        );
        spec.max_uses = Some(1);
        spec.bind = Some(knock.actor.device);
        spec.label = knock.name.clone();
        let chain = grants::issue(&key, core.identity.daemon_id(), &spec, now);
        let device = hex(&knock.actor.device.0);
        let mut store = lock(&self.store);
        let record = store.upsert(&chain);
        record.bound.push(device.clone());
        record.redeemed_at.insert(device, now.0);
        record.terms = InviteTerms {
            knock: false,
            history: admit.history,
        };
        self.save(&mut store);
        let info = self.info(&store, &chain);
        Ok((chain, info))
    }

    /// Knocks whose invite was revoked or expired: tell the knocker and drop them.
    fn drop_invalid_knocks(&self, core: &Core) {
        let doomed: Vec<PendingKnock> = {
            let store = lock(&self.store);
            let mut knocks = lock(&self.knocks);
            let ids: Vec<KnockId> = knocks
                .iter()
                .filter(|(_, k)| {
                    !self.chain_live(
                        &store,
                        &k.grant_ids,
                        &k.issuers,
                        k.root_signed,
                        k.knock.actor.device,
                        k.expires,
                    )
                })
                .map(|(id, _)| *id)
                .collect();
            ids.iter().filter_map(|id| knocks.remove(id)).collect()
        };
        for k in doomed {
            let _ = k.ctl.send(ServerCtl::KnockAnswer(KnockAnswer::Denied));
            close_soon(k.conn, KNOCK_LINGER, b"revoked");
            core.emit(Event::Knock(KnockUpdate::Gone {
                knock_id: k.knock.knock_id,
                outcome: KnockOutcome::Withdrawn,
                by: None,
            }));
        }
    }


    /// A session's approval policy (the default: any approver, any risk).
    pub fn policy(&self, session: SessionId) -> ApprovalPolicy {
        lock(&self.store)
            .policies
            .get(&session.0)
            .copied()
            .unwrap_or_default()
    }

    /// The policy of the session a pane belongs to.
    pub fn policy_of_pane(&self, core: &Core, pane: PaneId) -> ApprovalPolicy {
        core.session_of_pane(pane)
            .map(|s| self.policy(s))
            .unwrap_or_default()
    }

    /// Sets a session's approval policy (the caller checked the owner role), audits and
    /// broadcasts it.
    pub fn set_policy(
        &self,
        core: &Core,
        by: &Authz,
        session: SessionId,
        policy: ApprovalPolicy,
    ) -> ApprovalPolicy {
        {
            let mut store = lock(&self.store);
            if policy == ApprovalPolicy::default() {
                store.policies.remove(&session.0);
            } else {
                store.policies.insert(session.0, policy);
            }
            self.save(&mut store);
        }
        self.audit.append(
            AuditKind::Policy,
            AuditEntry {
                detail: format!(
                    "approvals in session {session}: {}",
                    approvals::describe(policy)
                ),
                ..by.audit()
            },
        );
        core.emit(Event::ApprovalPolicy(session, policy));
        policy
    }

    /// Whether a guest principal still holds a valid grant somewhere (since-join views of
    /// principals without one are dropped).
    pub fn principal_has_access(&self, principal: PrincipalId) -> bool {
        if self.principal_connected(principal) {
            return true;
        }
        let store = lock(&self.store);
        store.guests.iter().any(|g| {
            let Some(device) = unhex(&g.device).map(DeviceId) else {
                return false;
            };
            if grants::guest_principal(device) != principal {
                return false;
            }
            store
                .grants
                .iter()
                .filter(|s| s.bound.contains(&g.device))
                .filter_map(Store::chain_of)
                .any(|chain| {
                    let ids: Vec<GrantId> = chain.links.iter().map(|l| l.grant.grant_id).collect();
                    let issuers: Vec<DeviceId> =
                        chain.links.iter().map(|l| l.grant.issuer).collect();
                    let expires = chain.links.iter().filter_map(|l| l.grant.expires).min();
                    self.chain_live(
                        &store,
                        &ids,
                        &issuers,
                        chain.links[0].grant.issued_at,
                        device,
                        expires,
                    )
                })
        })
    }

    // --- leases -----------------------------------------------------------------------------

    pub fn lease(&self, pane: PaneId) -> Lease {
        lock(&self.leases)
            .get(&pane)
            .map_or_else(|| LeaseState::free().wire(pane), |l| l.wire(pane))
    }

    pub fn leases(&self) -> Vec<Lease> {
        lock(&self.leases).iter().map(|(p, l)| l.wire(*p)).collect()
    }

    /// Whether `principal` may size the pane's PTY: nobody holds the lease, or it does.
    pub fn may_size(&self, pane: PaneId, principal: PrincipalId) -> bool {
        lock(&self.leases)
            .get(&pane)
            .and_then(|l| l.holder)
            .is_none_or(|h| h.principal == principal)
    }

    /// Raw input from `actor`: allowed if it holds the lease, or takes a free lease (also one
    /// whose holder left). Otherwise returns the lease so the client can show who drives.
    pub fn input(&self, core: &Core, pane: PaneId, actor: Actor) -> Result<(), Lease> {
        let holder = lock(&self.leases).get(&pane).and_then(|l| l.holder);
        let holder_here = holder.is_some_and(|h| self.principal_connected(h.principal));
        let mut leases = lock(&self.leases);
        let state = leases.entry(pane).or_insert_with(LeaseState::free);
        match state.holder {
            Some(h) if h.principal == actor.principal => {
                state.last_input = Instant::now();
                Ok(())
            }
            Some(_) if holder_here => Err(state.wire(pane)),
            _ => {
                drop(leases);
                self.transfer(core, pane, actor, "took the free lease");
                Ok(())
            }
        }
    }

    fn transfer(&self, core: &Core, pane: PaneId, to: Actor, why: &str) -> Lease {
        let lease = {
            let mut leases = lock(&self.leases);
            let state = leases.entry(pane).or_insert_with(LeaseState::free);
            state.holder = Some(to);
            state.since = UnixMillis(now_millis());
            state.last_input = Instant::now();
            state.pending = None;
            state.wire(pane)
        };
        let name = self.principal_name(to.principal);
        self.audit.append(
            AuditKind::Lease,
            AuditEntry {
                actor: Some(to),
                pane_id: Some(pane),
                detail: format!("{name} {why}"),
                ..AuditEntry::default()
            },
        );
        core.emit(Event::Lease(lease));
        lease
    }

    fn principal_name(&self, principal: PrincipalId) -> String {
        lock(&self.live)
            .values()
            .find(|l| l.authz.actor.principal == principal)
            .map(|l| l.name.clone())
            .unwrap_or_else(|| short(&principal.0))
    }

    pub fn take_control(
        &self,
        core: &Core,
        conn: ConnId,
        by: &Authz,
        pane: PaneId,
        force: bool,
    ) -> Result<LeaseOutcome, MpError> {
        let need = if force { Need::Own } else { Need::Drive };
        policy::check(core, by, need, Target::Pane(pane))?;
        core.pane(pane)
            .ok_or_else(|| MpError::NotFound(format!("pane {pane}")))?;
        let (holder, idle) = {
            let leases = lock(&self.leases);
            let l = leases.get(&pane);
            (
                l.and_then(|l| l.holder),
                l.map_or(Duration::MAX, |l| l.last_input.elapsed()),
            )
        };
        let free = match holder {
            None => true,
            Some(h) => h.principal == by.actor.principal || !self.principal_connected(h.principal),
        };
        if free || force || idle >= self.lease_idle {
            let why = if force && !free {
                "forced take control"
            } else {
                "took control"
            };
            return Ok(LeaseOutcome::Granted(
                self.transfer(core, pane, by.actor, why),
            ));
        }
        let holder = holder.expect("not free");
        let name = self.name_of(conn);
        if let Some(l) = lock(&self.leases).get_mut(&pane) {
            l.pending = Some((by.actor, name.clone()));
        }
        self.send_to_principal(
            holder.principal,
            &ServerCtl::LeaseRequested {
                pane_id: pane,
                by: by.actor,
                name,
            },
        );
        Ok(LeaseOutcome::Pending {
            holder: holder.principal,
        })
    }

    /// The holder answers a pending request.
    pub fn answer_control(
        &self,
        core: &Core,
        by: &Authz,
        pane: PaneId,
        give: bool,
    ) -> Result<LeaseOutcome, MpError> {
        let (holder, pending) = {
            let leases = lock(&self.leases);
            let l = leases
                .get(&pane)
                .ok_or_else(|| MpError::NotFound("no lease on that pane".into()))?;
            (l.holder, l.pending.clone())
        };
        if holder.is_none_or(|h| h.principal != by.actor.principal) {
            return Err(MpError::Forbidden(
                "only the lease holder can answer".into(),
            ));
        }
        let (asker, _) = pending.ok_or_else(|| MpError::NotFound("no pending request".into()))?;
        if give {
            Ok(LeaseOutcome::Granted(self.transfer(
                core,
                pane,
                asker,
                "was given control",
            )))
        } else {
            let lease = {
                let mut leases = lock(&self.leases);
                let l = leases.get_mut(&pane).expect("checked");
                l.pending = None;
                l.wire(pane)
            };
            self.send_to_principal(asker.principal, &ServerCtl::Lease(lease));
            Ok(LeaseOutcome::Kept(lease))
        }
    }

    /// The holder or an owner hands the lease to a connected driver.
    pub fn give_control(
        &self,
        core: &Core,
        by: &Authz,
        pane: PaneId,
        to: PrincipalId,
    ) -> Result<LeaseOutcome, MpError> {
        let holder = lock(&self.leases).get(&pane).and_then(|l| l.holder);
        let holds = holder.is_some_and(|h| h.principal == by.actor.principal);
        if !holds {
            policy::check(core, by, Need::Own, Target::Pane(pane))?;
        }
        let target = lock(&self.live)
            .values()
            .find(|l| l.authz.actor.principal == to)
            .map(|l| l.authz.clone())
            .ok_or_else(|| MpError::NotFound("that principal is not connected".into()))?;
        policy::check(core, &target, Need::Drive, Target::Pane(pane))
            .map_err(|e| MpError::Conflict(format!("cannot give control: {e}")))?;
        Ok(LeaseOutcome::Granted(self.transfer(
            core,
            pane,
            target.actor,
            "was given control",
        )))
    }

    pub fn release_control(&self, core: &Core, by: &Authz, pane: PaneId) -> Result<(), MpError> {
        let lease = {
            let mut leases = lock(&self.leases);
            let l = leases
                .get_mut(&pane)
                .ok_or_else(|| MpError::NotFound("no lease on that pane".into()))?;
            if l.holder.is_none_or(|h| h.principal != by.actor.principal) {
                return Err(MpError::Forbidden(
                    "only the lease holder can release".into(),
                ));
            }
            l.holder = None;
            l.pending = None;
            l.since = UnixMillis(now_millis());
            l.wire(pane)
        };
        self.audit.append(
            AuditKind::Lease,
            AuditEntry {
                pane_id: Some(pane),
                detail: "released control".into(),
                ..by.audit()
            },
        );
        core.emit(Event::Lease(lease));
        Ok(())
    }

    pub fn forget_pane(&self, pane: PaneId) {
        lock(&self.leases).remove(&pane);
    }

    fn send_to_principal(&self, principal: PrincipalId, msg: &ServerCtl) {
        for l in lock(&self.live).values() {
            if l.authz.actor.principal == principal {
                let _ = l.ctl.send(msg.clone());
            }
        }
    }

    /// Periodic work: hand pending leases over once the holder went idle; disconnect
    /// connections whose grant expired.
    pub fn tick(&self, core: &Core) {
        let due: Vec<(PaneId, Actor)> = lock(&self.leases)
            .iter()
            .filter(|(_, l)| l.last_input.elapsed() >= self.lease_idle)
            .filter_map(|(p, l)| Some((*p, l.pending.as_ref()?.0)))
            .collect();
        for (pane, to) in due {
            self.transfer(core, pane, to, "took control (holder idle)");
        }
        self.kick_invalid();
        self.drop_invalid_knocks(core);
        self.tick_presence(core);
    }
}

/// What a decision may do under its session's approval policy.
pub(crate) enum Gate {
    /// Apply it.
    Proceed,
    /// Counted; the request waits for a second person. The vote is audited (with the
    /// decider's signature) and broadcast; the agent is not answered yet.
    Held,
}

/// reaches the agent. `signed` is what the decider signed and `sig` its signature, kept in
/// the audit record of a held vote.
///
/// # Errors
///
/// The policy's refusal ([`MpError::Forbidden`] or [`MpError::Conflict`]), audited as
/// [`AuditKind::Denied`]; [`MpError::NotFound`] when the request is no longer open.
pub(crate) fn gate_decision(
    core: &Core,
    ballot: approvals::Ballot<'_>,
    request: proto::RequestId,
    option: proto::OptionId,
    signed: (Vec<u8>, Vec<u8>),
) -> Result<Gate, MpError> {
    let (pane, facts) = core
        .request_facts(request, Some(option))
        .ok_or_else(|| MpError::NotFound("the request is no longer open".into()))?;
    let mp = &core.mp;
    let policy = mp.policy_of_pane(core, pane);
    let risk = proto::Risk::of_tool(facts.tool.as_deref());
    let allow = facts.allows.unwrap_or(true);
    let verdict = mp
        .approvals
        .judge(policy, pane, request, risk, allow, ballot)
        .inspect_err(|e| {
            mp.audit.append(
                AuditKind::Denied,
                AuditEntry {
                    actor: Some(ballot.actor),
                    pane_id: Some(pane),
                    detail: format!("{} could not answer {}: {e}", ballot.name, facts.summary),
                    ..AuditEntry::default()
                },
            );
        })?;
    match verdict {
        approvals::Verdict::Decide => Ok(Gate::Proceed),
        approvals::Verdict::Held(status) => {
            let (signed, sig) = signed;
            mp.audit.append(
                AuditKind::Approval,
                AuditEntry {
                    actor: Some(ballot.actor),
                    pane_id: Some(pane),
                    detail: format!(
                        "{} approved {} (1 of 2; waiting for a second person)",
                        ballot.name, facts.summary
                    ),
                    approval: Some(proto::ApprovalAudit {
                        request_id: request,
                        agent_request: facts.request.to_string(),
                        option_id: option,
                        option: facts.option.unwrap_or_default(),
                        tool: facts.tool,
                        summary: facts.summary,
                        signed,
                        sig,
                    }),
                    ..AuditEntry::default()
                },
            );
            core.emit(Event::ApprovalStatus(status));
            Ok(Gate::Held)
        }
    }
}

/// Tells a connection its grant is gone and closes it shortly after (so the message lands).
fn kick(
    grant: Option<GrantId>,
    ctl: &mpsc::UnboundedSender<ServerCtl>,
    conn: iroh::endpoint::Connection,
) {
    let _ = ctl.send(ServerCtl::Revoked {
        grant_id: grant.unwrap_or(GrantId([0; 16])),
    });
    close_soon(conn, Duration::from_millis(150), b"revoked");
}

/// Closes a connection after `delay`, so the last message sent on it lands first.
fn close_soon(conn: iroh::endpoint::Connection, delay: Duration, why: &'static [u8]) {
    tokio::spawn(async move {
        tokio::time::sleep(delay).await;
        conn.close(1u32.into(), why);
    });
}

fn short(bytes: &[u8]) -> String {
    hex(&bytes[..bytes.len().min(4)])
}

/// Runs [`Mp::tick`] twice a second.
pub(crate) async fn run(core: std::sync::Arc<Core>) {
    let mut interval = tokio::time::interval(Duration::from_millis(500));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut ticks: u64 = 0;
    loop {
        interval.tick().await;
        core.mp.tick(&core);
        ticks += 1;
        if ticks.is_multiple_of(120) {
            prune_views(&core);
        }
    }
}

/// Drops since-join views of principals whose access ended (revoked, expired): each is a
/// whole terminal's worth of memory.
fn prune_views(core: &Core) {
    for (_, entry) in core.pane_entries() {
        for principal in entry.pane.view_principals() {
            if !core.mp.principal_has_access(principal) {
                entry.pane.close_view(principal);
            }
        }
    }
}
