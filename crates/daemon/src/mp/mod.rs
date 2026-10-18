//! control leases, presence and the audit log. See docs/DAEMON.md §6.
//!
//! - Every connection has an [`Authz`]: its actor, roles, scope and grant chain. Paired owner
//!   devices get `OWNER` on the whole daemon; guests get what their verified chain says.
//! - [`policy::check`] gates every request; [`Mp::still_valid`] re-checks revocation and
//!   expiry on every message, so a revocation takes effect without waiting for a reconnect.
//! - `<state>/grants.json` holds registered grants, first-use bindings, revocations and the
//!   guest devices; `<state>/audit/audit.jsonl` the audit log.

pub(crate) mod audit;
pub(crate) mod policy;
pub(crate) mod prompt;

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use grants::{Authority, GrantError};
use proto::{
    Actor, AuditKind, CursorPos, DeviceId, DeviceInfo, DeviceKind, GrantChain, GrantId, GrantInfo,
    JoinInfo, Lease, LeaseMode, LeaseOutcome, MpError, MpResponse, PaneId, Participant, Presence,
    PresenceState, PrincipalId, RefuseReason, RevokeTarget, Roles, Scope, ServerCtl, UnixMillis,
};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

pub(crate) use audit::{Audit, Entry as AuditEntry};
pub(crate) use policy::{Need, Target};

use crate::core::{ConnId, Core, Event, lock};
use crate::fsutil::{hex, read_optional, unhex, write_atomic};
use crate::identity::now_millis;

const STORE_FILE: &str = "grants.json";
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
    pub expires: Option<UnixMillis>,
    pub name: String,
}

impl Authz {
    /// A paired owner device.
    pub fn owner(actor: Actor) -> Self {
        Self {
            actor,
            roles: Roles::OWNER,
            scope: Scope::Daemon,
            grant_ids: Vec::new(),
            expires: None,
            name: "owner".into(),
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
    #[serde(default)]
    revoked_devices: BTreeSet<String>,
    #[serde(default)]
    guests: Vec<GuestRecord>,
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct GuestRecord {
    device: String,
    name: String,
    grant: String,
    first_seen: u64,
}

impl Store {
    fn load(path: &Path) -> Self {
        match read_optional(path) {
            Ok(Some(bytes)) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                // Never silently forget revocations: refuse to start with an unreadable file
                // is harsh, so keep a copy aside and log loudly.
                tracing::error!("{}: {e}; moved aside", path.display());
                let _ = std::fs::rename(path, path.with_extension("json.bad"));
                Self::default()
            }),
            Ok(None) => Self::default(),
            Err(e) => {
                tracing::error!("{}: {e}", path.display());
                Self::default()
            }
        }
    }

    fn save(&self, path: &Path) {
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

    fn device_revoked(&self, device: DeviceId) -> bool {
        self.revoked_devices.contains(&hex(&device.0))
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
        });
        self.grants.last_mut().expect("just pushed")
    }

    fn chain_of(g: &StoredGrant) -> Option<GrantChain> {
        let bytes = unhex_vec(&g.chain)?;
        GrantChain::from_token(&bytes).ok()
    }
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

    fn device_revoked(&self, device: DeviceId) -> bool {
        self.store.device_revoked(device)
    }
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

/// Multiplayer state owned by the core.
pub(crate) struct Mp {
    store_path: PathBuf,
    store: Mutex<Store>,
    live: Mutex<HashMap<ConnId, Live>>,
    leases: Mutex<HashMap<PaneId, LeaseState>>,
    pub audit: Audit,
    lease_idle: Duration,
}

impl Mp {
    pub fn open(state_dir: &Path, lease_idle: Duration) -> std::io::Result<Self> {
        let store_path = state_dir.join(STORE_FILE);
        Ok(Self {
            store: Mutex::new(Store::load(&store_path)),
            store_path,
            live: Mutex::new(HashMap::new()),
            leases: Mutex::new(HashMap::new()),
            audit: Audit::open(state_dir)?,
            lease_idle,
        })
    }

    // --- handshake --------------------------------------------------------------------------

    /// Whether a paired device was revoked (pairing alone does not override a revocation).
    pub fn device_revoked(&self, device: DeviceId) -> bool {
        lock(&self.store).device_revoked(device)
    }

    /// Verifies a presented grant chain for `device`, binding an unbound leaf on first use.
    pub fn redeem(
        &self,
        core: &Core,
        device: DeviceId,
        claimed: PrincipalId,
        token: &[u8],
    ) -> Result<Authz, RefuseReason> {
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
        let leaf = &verified.leaf;
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
        }
        let name = if leaf.label.is_empty() {
            format!("guest-{}", &device_hex[..6])
        } else {
            leaf.label.clone()
        };
        if !store.guests.iter().any(|g| g.device == device_hex) {
            store.guests.push(GuestRecord {
                device: device_hex,
                name: name.clone(),
                grant: hex(&leaf.grant_id.0),
                first_seen: now.0,
            });
        } else if let Some(g) = store.guests.iter_mut().find(|g| g.device == device_hex) {
            g.grant = hex(&leaf.grant_id.0);
        }
        store.save(&self.store_path);
        drop(store);
        let authz = Authz {
            actor,
            roles: verified.roles,
            scope: verified.scope,
            grant_ids: verified.ids,
            expires: verified.expires,
            name,
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
        Ok(authz)
    }

    /// Whether `authz` is still in force: unexpired, no link or device revoked.
    pub fn still_valid(&self, authz: &Authz) -> bool {
        if authz.expires.is_some_and(|e| e.0 <= now_millis()) {
            return false;
        }
        let store = lock(&self.store);
        !store.device_revoked(authz.actor.device)
            && !authz.grant_ids.iter().any(|&g| store.grant_revoked(g))
    }

    // --- participants -----------------------------------------------------------------------

    pub fn join(
        &self,
        core: &Core,
        id: ConnId,
        authz: &Authz,
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
                state: l.state,
                focus: l.focus,
                typing: l.typing,
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
        if let Some(l) = lock(&self.live).get_mut(&id) {
            l.name = name.chars().take(64).collect();
        }
        core.emit(Event::Participants);
    }

    /// The connection's focused pane changed (from `Focus`).
    pub fn set_focus(&self, core: &Core, id: ConnId, focus: Option<PaneId>) {
        let changed = lock(&self.live).get_mut(&id).is_some_and(|l| {
            let changed = l.focus != focus;
            l.focus = focus;
            l.state = PresenceState::Active;
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

    /// Records a chain so it is listed and revocable before first use.
    pub fn register(
        &self,
        core: &Core,
        by: &Authz,
        chain: &GrantChain,
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
        store.upsert(chain);
        store.save(&self.store_path);
        let info = self.info(&store, chain);
        drop(store);
        self.audit.append(
            AuditKind::GrantRegistered,
            AuditEntry {
                detail: format!(
                    "grant {} for {:?}: {} on {}",
                    short(&leaf.grant_id.0),
                    leaf.label,
                    leaf.roles.names(),
                    leaf.scope
                ),
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
                || store.device_revoked(leaf.issuer),
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
            .map(|(device, principal, at)| DeviceInfo {
                device,
                principal,
                kind: DeviceKind::Owner,
                name: "owner".into(),
                first_seen: at,
                grant_id: None,
                revoked: store.device_revoked(device),
                connected: connected(device),
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
                revoked: store.device_revoked(device),
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
                        .filter(|(_, principal, _)| *principal == p)
                        .map(|(d, _, _)| d),
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
            for d in &devices_hit {
                store.revoked_devices.insert(hex(&d.0));
            }
            store.save(&self.store_path);
        }
        for &d in &devices_hit {
            core.identity.unpair(d);
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
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(150)).await;
        conn.close(1u32.into(), b"revoked");
    });
}

fn short(bytes: &[u8]) -> String {
    hex(&bytes[..bytes.len().min(4)])
}

/// Runs [`Mp::tick`] twice a second.
pub(crate) async fn run(core: std::sync::Arc<Core>) {
    let mut interval = tokio::time::interval(Duration::from_millis(500));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        interval.tick().await;
        core.mp.tick(&core);
    }
}
