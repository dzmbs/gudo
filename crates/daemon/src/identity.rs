//! Daemon key, owner principal, paired devices and pairing secrets.
//!
//! Everything is a small file in the state directory, so `hostd pair` (a separate process)
//! can mint a secret that the running daemon accepts:
//!
//! | file | contents |
//! |---|---|
//! | `daemon.key` | iroh Ed25519 secret key, 32 raw bytes, mode 0600 |
//! | `owner.json` | the owner principal |
//! | `devices.json` | the device allowlist |
//! | `unpaired.json` | when each removed device was removed (changed under `devices.lock`) |
//! | `pairing.json` | pending pairing secrets with expiry and uses (changed under `pairing.lock`) |
//! | `endpoint.json` | where the running daemon listens (written by `run`) |

use std::collections::BTreeMap;
use std::io;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use proto::{
    DaemonId, DeviceId, PairingSecret, PrincipalId, RefuseReason, SignedGrant, Ticket, UnixMillis,
};
use serde::{Deserialize, Serialize};

use crate::fsutil::{self, hex, read_optional, unhex, write_atomic};

const KEY_FILE: &str = "daemon.key";
const OWNER_FILE: &str = "owner.json";
const DEVICES_FILE: &str = "devices.json";
const REMOVED_FILE: &str = "unpaired.json";
const PAIRING_FILE: &str = "pairing.json";
const ENDPOINT_FILE: &str = "endpoint.json";

/// Default lifetime of a pairing ticket.
pub const PAIRING_TTL: Duration = Duration::from_secs(10 * 60);

/// The most devices one reusable ticket may pair.
pub const MAX_TICKET_USES: u32 = 20;

/// The longest a reusable ticket may stay valid.
pub const MAX_REUSABLE_TICKET_TTL: Duration = Duration::from_secs(30 * 24 * 60 * 60);

#[derive(Debug, Serialize, Deserialize)]
struct OwnerFile {
    principal: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DeviceEntry {
    device: String,
    principal: String,
    paired_at: u64,
    /// What the device calls itself (its first `SetName`).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    name: String,
    /// What the owner named it; shown instead of `name`, which the device may say again.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    label: String,
    /// When it last connected or disconnected, Unix ms.
    #[serde(default, skip_serializing_if = "is_zero")]
    last_seen: u64,
    /// Paired with a ticket minted for the app on this computer (`pair --local`).
    #[serde(default, skip_serializing_if = "is_false")]
    this_computer: bool,
}

impl DeviceEntry {
    fn display_name(&self) -> &str {
        if self.label.is_empty() {
            &self.name
        } else {
            &self.label
        }
    }
}

fn is_zero(value: &u64) -> bool {
    *value == 0
}

fn is_false(value: &bool) -> bool {
    !*value
}

/// How long a connection's arrival may go unrecorded in `last_seen`, so reconnects do not
/// rewrite `devices.json` each time.
const SEEN_GRANULARITY_MS: u64 = 5 * 60 * 1000;

/// The longest device name kept, in characters.
pub const DEVICE_NAME_MAX: usize = 64;

/// When each device was last removed from the allowlist, Unix ms, by device hex.
type Removed = BTreeMap<String, u64>;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PairingEntry {
    secret: String,
    principal: String,
    expires: u64,
    #[serde(default, skip_serializing_if = "is_false")]
    this_computer: bool,
    /// Names the ticket for `pair --list` and `pair --revoke`; unrelated to the secret.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    id: String,
    /// How many devices it may pair; 0 (older files) and 1 mean once. A daemon that predates
    /// this field consumes the whole entry on first use, which fails safe.
    #[serde(default, skip_serializing_if = "is_single_use")]
    uses: u32,
    /// The devices a reusable ticket paired, hex: each counts once.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    paired: Vec<String>,
    /// When it was minted, Unix ms; a device removed since then cannot reuse it.
    #[serde(default, skip_serializing_if = "is_zero")]
    minted: u64,
}

impl PairingEntry {
    fn reusable(&self) -> bool {
        self.uses > 1
    }
}

fn is_single_use(uses: &u32) -> bool {
    *uses <= 1
}

/// What a consumed pairing secret was minted for.
#[derive(Debug, PartialEq, Eq)]
struct Pairing {
    principal: PrincipalId,
    this_computer: bool,
}

/// Where a running daemon can be reached; written at startup for `pair` and `status`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EndpointInfo {
    /// The daemon's endpoint id, hex.
    pub daemon_id: String,
    pub addrs: Vec<SocketAddr>,
    pub relay_url: Option<String>,
    /// The relays the daemon uses (default, self-hosted or none), for pairing tickets.
    #[serde(default)]
    pub relays: proto::TicketRelays,
    pub pid: u32,
    /// Unix ms.
    pub started_at: u64,
    /// The UDP sockets the endpoint bound (`0.0.0.0:p`, `[::]:p`). The next start binds the
    /// same ports again, so the direct addresses in tickets already handed out keep working
    /// across restarts and upgrades (a device dialling with relays off has nothing else).
    #[serde(default)]
    pub bound: Vec<SocketAddr>,
}

pub(crate) fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as u64)
}

fn json_error(error: serde_json::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error)
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> io::Result<Option<T>> {
    read_optional(path)?
        .map(|bytes| serde_json::from_slice(&bytes).map_err(json_error))
        .transpose()
}

fn write_json<T: Serialize>(path: &Path, value: &T) -> io::Result<()> {
    write_atomic(path, &serde_json::to_vec_pretty(value).map_err(json_error)?)
}

/// Identifies one version of `devices.json`: every write is an atomic rename, so a new
/// inode means new contents even within the file system's timestamp granularity.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Stamp {
    dev: u64,
    ino: u64,
    mtime_ns: i128,
    len: u64,
}

fn stamp(path: &Path) -> io::Result<Option<Stamp>> {
    use std::os::unix::fs::MetadataExt;
    match std::fs::metadata(path) {
        Ok(metadata) => Ok(Some(Stamp {
            dev: metadata.dev(),
            ino: metadata.ino(),
            mtime_ns: i128::from(metadata.mtime()) * 1_000_000_000
                + i128::from(metadata.mtime_nsec()),
            len: metadata.len(),
        })),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

/// The allowlist as last read, with the file version it came from.
#[derive(Debug, Default)]
struct Devices {
    list: Vec<DeviceEntry>,
    removed: Removed,
    stamp: Option<Stamp>,
}

/// A paired owner device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Owner {
    pub device: DeviceId,
    pub principal: PrincipalId,
    pub name: String,
    pub paired_at: UnixMillis,
}

/// The daemon's long-lived identity and authorisation state.
#[derive(Debug)]
pub(crate) struct Identity {
    pub secret: iroh::SecretKey,
    dir: PathBuf,
    devices: Mutex<Devices>,
}

impl Identity {
    /// Loads the key and owner from `dir`, creating them on first run.
    pub fn load_or_create(dir: &Path) -> io::Result<Self> {
        fsutil::create_private_dir(dir)?;
        let secret = load_or_create_key(dir)?;
        load_or_create_owner(dir)?;
        let identity = Self {
            secret,
            dir: dir.to_owned(),
            devices: Mutex::default(),
        };
        identity.load_devices()?;
        Ok(identity)
    }

    pub fn daemon_id(&self) -> DaemonId {
        DaemonId(*self.secret.public().as_bytes())
    }

    fn devices_path(&self) -> PathBuf {
        self.dir.join(DEVICES_FILE)
    }

    fn removed_path(&self) -> PathBuf {
        self.dir.join(REMOVED_FILE)
    }

    fn lock_devices(&self) -> MutexGuard<'_, Devices> {
        self.devices.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Reads `devices.json` (and `unpaired.json`, always written first) if it changed since
    /// the last read, so `hostd unpair` (another process) takes effect for every check at once.
    fn load_devices(&self) -> io::Result<()> {
        let path = self.devices_path();
        let now = stamp(&path)?;
        let mut devices = self.lock_devices();
        if now.is_some() && devices.stamp == now {
            return Ok(());
        }
        devices.list = read_json(&path)?.unwrap_or_default();
        devices.removed = read_json(&self.removed_path())?.unwrap_or_default();
        devices.stamp = now;
        Ok(())
    }

    /// [`Self::load_devices`], keeping the last good list if the file is unreadable.
    fn refresh(&self) {
        if let Err(error) = self.load_devices() {
            tracing::warn!("reading paired devices: {error}");
        }
    }

    /// Changes the allowlist under its file lock, starting from the file's current contents,
    /// so a change here never undoes one another process just made. `change` says whether it
    /// changed anything; only then is the file written.
    fn update_devices(
        &self,
        change: impl FnOnce(&mut Vec<DeviceEntry>, &mut Removed) -> bool,
    ) -> io::Result<bool> {
        let path = self.devices_path();
        let removed_path = self.removed_path();
        fsutil::with_lock(&path, || {
            let mut list: Vec<DeviceEntry> = read_json(&path)?.unwrap_or_default();
            let mut removed: Removed = read_json(&removed_path)?.unwrap_or_default();
            let changed = change(&mut list, &mut removed);
            if changed {
                write_json(&removed_path, &removed)?;
                write_json(&path, &list)?;
            }
            let mut devices = self.lock_devices();
            devices.stamp = stamp(&path)?;
            devices.list = list;
            devices.removed = removed;
            Ok(changed)
        })
    }

    /// Checks a `Hello`'s grant for `device` (already authenticated by the handshake) and
    /// returns the principal it acts as.
    pub fn authorize(
        &self,
        device: DeviceId,
        claimed: PrincipalId,
        grant: &SignedGrant,
    ) -> Result<PrincipalId, RefuseReason> {
        let device_hex = hex(&device.0);
        match grant.v {
            SignedGrant::PAIRING => {
                let secret: [u8; 16] = grant
                    .token
                    .as_slice()
                    .try_into()
                    .map_err(|_| RefuseReason::InvalidGrant)?;
                let removed_at = self.removed_at(device).map(|at| at.0);
                let Pairing {
                    principal,
                    this_computer,
                } = consume_pairing_secret(
                    &self.dir,
                    PairingSecret(secret),
                    &device_hex,
                    removed_at,
                )
                .map_err(|_| RefuseReason::InvalidGrant)?
                .ok_or(RefuseReason::InvalidGrant)?;
                let entry = DeviceEntry {
                    device: device_hex.clone(),
                    principal: hex(&principal.0),
                    paired_at: now_millis(),
                    name: String::new(),
                    label: String::new(),
                    last_seen: 0,
                    this_computer,
                };
                // A fresh ticket brings a removed device back, but not its old invites: they
                // stay void by its removal time (`removed_at`) and its new `paired_at`. A
                // device still paired keeps its pairing time, and so its invites.
                self.update_devices(|list, _| {
                    let paired_at = list
                        .iter()
                        .find(|paired| paired.device == device_hex)
                        .map_or(entry.paired_at, |paired| paired.paired_at);
                    list.retain(|paired| paired.device != device_hex);
                    list.push(DeviceEntry {
                        paired_at,
                        ..entry
                    });
                    true
                })
                .map_err(|error| {
                    tracing::warn!("saving paired devices: {error}");
                    RefuseReason::InvalidGrant
                })?;
                tracing::info!(?device, "paired new device");
                Ok(principal)
            }
            SignedGrant::DEVICE => {
                self.refresh();
                let devices = self.lock_devices();
                let entry = devices
                    .list
                    .iter()
                    .find(|paired| paired.device == device_hex)
                    .ok_or(RefuseReason::InvalidGrant)?;
                let principal =
                    PrincipalId(unhex(&entry.principal).ok_or(RefuseReason::InvalidGrant)?);
                // One principal per device; a client claiming another is refused.
                if claimed != principal {
                    return Err(RefuseReason::InvalidGrant);
                }
                Ok(principal)
            }
            _ => Err(RefuseReason::InvalidGrant),
        }
    }

    pub fn device_count(&self) -> usize {
        self.refresh();
        self.lock_devices().list.len()
    }

    /// The daemon key as a device id: it may sign root grants (`gudo-hostd invite`).
    pub fn daemon_device(&self) -> DeviceId {
        DeviceId(self.daemon_id().0)
    }

    /// Whether `device` is a paired owner device (it may sign root grants).
    pub fn is_owner_device(&self, device: DeviceId) -> bool {
        self.refresh();
        let hex_id = hex(&device.0);
        self.lock_devices()
            .list
            .iter()
            .any(|paired| paired.device == hex_id)
    }

    /// When `device`'s current pairing began, if it is a paired owner device.
    pub fn paired_at(&self, device: DeviceId) -> Option<UnixMillis> {
        self.refresh();
        let hex_id = hex(&device.0);
        self.lock_devices()
            .list
            .iter()
            .find(|paired| paired.device == hex_id)
            .map(|paired| UnixMillis(paired.paired_at))
    }

    pub fn paired(&self) -> Vec<Owner> {
        self.refresh();
        self.lock_devices()
            .list
            .iter()
            .filter_map(|paired| {
                Some(Owner {
                    device: DeviceId(unhex(&paired.device)?),
                    principal: PrincipalId(unhex(&paired.principal)?),
                    name: paired.display_name().to_owned(),
                    paired_at: UnixMillis(paired.paired_at),
                })
            })
            .collect()
    }

    /// When `device` was last removed from the allowlist, if ever.
    pub fn removed_at(&self, device: DeviceId) -> Option<UnixMillis> {
        self.refresh();
        self.lock_devices()
            .removed
            .get(&hex(&device.0))
            .map(|&at| UnixMillis(at))
    }

    /// Records what a paired device calls itself. No-op for other devices or an unchanged
    /// name.
    pub fn set_name(&self, device: DeviceId, name: &str) {
        let hex_id = hex(&device.0);
        let known = self
            .lock_devices()
            .list
            .iter()
            .any(|paired| paired.device == hex_id && paired.name != name);
        if !known {
            return;
        }
        let saved = self.update_devices(|list, _| {
            list.iter_mut()
                .find(|paired| paired.device == hex_id && paired.name != name)
                .map(|paired| paired.name = name.to_owned())
                .is_some()
        });
        if let Err(error) = saved {
            tracing::warn!("saving paired devices: {error}");
        }
    }

    /// Names a paired device as the owner wants it listed; empty goes back to the name the
    /// device gave. Returns whether it is paired.
    pub fn rename(&self, device: DeviceId, label: &str) -> io::Result<bool> {
        let hex_id = hex(&device.0);
        let label = clean_device_name(label);
        let mut found = false;
        self.update_devices(|list, _| {
            let Some(paired) = list.iter_mut().find(|paired| paired.device == hex_id) else {
                return false;
            };
            found = true;
            if paired.label == label {
                return false;
            }
            paired.label = label;
            true
        })?;
        Ok(found)
    }

    /// Records that `device` connected (at most once per [`SEEN_GRANULARITY_MS`]) or, with
    /// `leaving`, disconnected.
    pub fn seen(&self, device: DeviceId, leaving: bool) {
        let hex_id = hex(&device.0);
        let now = now_millis();
        let due = |paired: &DeviceEntry| {
            paired.device == hex_id
                && (leaving || now.saturating_sub(paired.last_seen) >= SEEN_GRANULARITY_MS)
        };
        if !self.lock_devices().list.iter().any(due) {
            return;
        }
        let saved = self.update_devices(|list, _| {
            list.iter_mut()
                .find(|paired| due(paired))
                .map(|paired| paired.last_seen = now)
                .is_some()
        });
        if let Err(error) = saved {
            tracing::warn!("saving paired devices: {error}");
        }
    }

    /// Removes a paired device. Returns whether it was paired.
    pub fn unpair(&self, device: DeviceId) -> bool {
        let hex_id = hex(&device.0);
        self.update_devices(|list, removed| remove_device(list, removed, &hex_id))
            .unwrap_or_else(|error| {
                tracing::warn!("saving paired devices: {error}");
                false
            })
    }
}

/// Takes `device` off the allowlist and records when, so everything it signed until now stays
/// void even if it pairs again.
fn remove_device(list: &mut Vec<DeviceEntry>, removed: &mut Removed, device: &str) -> bool {
    let before = list.len();
    list.retain(|paired| paired.device != device);
    if list.len() == before {
        return false;
    }
    removed.insert(device.to_owned(), now_millis());
    true
}

fn load_or_create_key(dir: &Path) -> io::Result<iroh::SecretKey> {
    let path = dir.join(KEY_FILE);
    if let Some(bytes) = read_optional(&path)? {
        let bytes: [u8; 32] = bytes.try_into().map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidData, "daemon.key is not 32 bytes")
        })?;
        return Ok(iroh::SecretKey::from_bytes(&bytes));
    }
    let key = iroh::SecretKey::from_bytes(&fsutil::random::<32>());
    write_atomic(&path, &key.to_bytes())?;
    Ok(key)
}

fn load_or_create_owner(dir: &Path) -> io::Result<PrincipalId> {
    let path = dir.join(OWNER_FILE);
    if let Some(owner) = read_json::<OwnerFile>(&path)? {
        return unhex(&owner.principal)
            .map(PrincipalId)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "bad owner principal"));
    }
    let principal = PrincipalId(fsutil::random::<16>());
    write_json(
        &path,
        &OwnerFile {
            principal: hex(&principal.0),
        },
    )?;
    Ok(principal)
}

/// Uses `secret` for `device` if it is pending and unexpired, returning what it was minted for.
/// A single-use secret is removed. A reusable one counts each distinct device once, is removed
/// when its last use is taken, and refuses a device removed (`removed_at`) since it was minted.
fn consume_pairing_secret(
    dir: &Path,
    secret: PairingSecret,
    device: &str,
    removed_at: Option<u64>,
) -> io::Result<Option<Pairing>> {
    let path = dir.join(PAIRING_FILE);
    fsutil::with_lock(&path, || {
        let mut entries: Vec<PairingEntry> = read_json(&path)?.unwrap_or_default();
        let before = entries.len();
        let now = now_millis();
        entries.retain(|entry| entry.expires > now);
        let mut changed = entries.len() != before;
        let found = entries.iter().position(|entry| {
            unhex::<16>(&entry.secret).is_some_and(|stored| fsutil::constant_eq(&stored, &secret.0))
        });
        let pairing = match found {
            None => None,
            Some(index) if !entries[index].reusable() => {
                changed = true;
                Some(entries.remove(index))
            }
            Some(index) => {
                let entry = &mut entries[index];
                if removed_at.is_some_and(|removed| removed >= entry.minted) {
                    None
                } else {
                    if !entry.paired.iter().any(|paired| paired == device) {
                        entry.paired.push(device.to_owned());
                        changed = true;
                    }
                    let entry = entry.clone();
                    if entry.paired.len() >= entry.uses as usize {
                        entries.remove(index);
                    }
                    Some(entry)
                }
            }
        };
        // A wrong guess costs no disk write: anyone who knows the daemon id can send them.
        if changed {
            write_json(&path, &entries)?;
        }
        Ok(pairing.and_then(|entry| {
            unhex(&entry.principal).map(|principal| Pairing {
                principal: PrincipalId(principal),
                this_computer: entry.this_computer,
            })
        }))
    })
}

/// Records where the running daemon listens.
pub(crate) fn write_endpoint_info(dir: &Path, info: &EndpointInfo) -> io::Result<()> {
    write_json(&dir.join(ENDPOINT_FILE), info)
}

/// Reads what the running (or last) daemon recorded about its endpoint.
///
/// # Errors
///
/// Returns an error if the file is unreadable or malformed; `Ok(None)` if no daemon has run.
pub fn endpoint_info(state_dir: &Path) -> io::Result<Option<EndpointInfo>> {
    read_json(&state_dir.join(ENDPOINT_FILE))
}

/// Mints a one-time pairing secret valid for `ttl` and returns the ticket for it.
///
/// Works whether or not the daemon is running (the daemon re-reads the pending secrets on
/// every pairing attempt), but the ticket's addresses come from the last `endpoint.json`, so
/// the daemon must have started at least once.
///
/// # Errors
///
/// Returns [`io::ErrorKind::NotFound`] if no daemon has recorded its endpoint yet, or any
/// error reading or writing the state files.
pub fn mint_ticket(state_dir: &Path, ttl: Duration) -> io::Result<Ticket> {
    mint(state_dir, ttl, false, 1).map(|(ticket, _)| ticket)
}

fn mint(
    state_dir: &Path,
    ttl: Duration,
    this_computer: bool,
    uses: u32,
) -> io::Result<(Ticket, String)> {
    let info = endpoint_info(state_dir)?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "no endpoint recorded; start the daemon first",
        )
    })?;
    let daemon_id = DaemonId(
        unhex(&info.daemon_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "bad daemon id"))?,
    );
    let owner = load_or_create_owner(state_dir)?;
    let secret = PairingSecret(fsutil::random::<16>());
    let id = hex(&fsutil::random::<4>());
    let minted = now_millis();
    let expires = minted + ttl.as_millis() as u64;
    let path = state_dir.join(PAIRING_FILE);
    fsutil::with_lock(&path, || {
        let mut entries: Vec<PairingEntry> = read_json(&path)?.unwrap_or_default();
        let now = now_millis();
        entries.retain(|entry| entry.expires > now);
        entries.push(PairingEntry {
            secret: hex(&secret.0),
            principal: hex(&owner.0),
            expires,
            this_computer,
            id: id.clone(),
            uses,
            paired: Vec::new(),
            minted,
        });
        write_json(&path, &entries)
    })?;
    let ticket = Ticket {
        v: Ticket::VERSION,
        daemon_id,
        addrs: info.addrs,
        relay_url: info.relay_url,
        principal: owner,
        secret,
        expires: UnixMillis(expires),
    };
    Ok((ticket, id))
}

/// [`mint_ticket`] as text, with the running daemon's relay choice appended
/// ([`proto::TicketExtras`]) so the app dials through the same self-hosted relays, or none.
///
/// # Errors
///
/// As [`mint_ticket`].
pub fn mint_ticket_text(state_dir: &Path, ttl: Duration) -> io::Result<String> {
    ticket_text(state_dir, mint(state_dir, ttl, false, 1)?.0)
}

/// A ticket that pairs up to `uses` distinct devices within `ttl`, for a host shared on
/// purpose (a demo host). Its secret is shared by everyone who sees it: see
/// docs/security/transport-identity.md. Returns the ticket text and its id for
/// [`revoke_pairing_tickets`].
///
/// # Errors
///
/// [`io::ErrorKind::InvalidInput`] unless `uses` is 2 to [`MAX_TICKET_USES`] and `ttl` at most
/// [`MAX_REUSABLE_TICKET_TTL`]; otherwise as [`mint_ticket`].
pub fn mint_reusable_ticket_text(
    state_dir: &Path,
    ttl: Duration,
    uses: u32,
) -> io::Result<(String, String)> {
    if !(2..=MAX_TICKET_USES).contains(&uses) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("a reusable ticket pairs 2 to {MAX_TICKET_USES} devices"),
        ));
    }
    if ttl > MAX_REUSABLE_TICKET_TTL {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "a reusable ticket lasts at most {} days",
                MAX_REUSABLE_TICKET_TTL.as_secs() / 86_400
            ),
        ));
    }
    let (ticket, id) = mint(state_dir, ttl, false, uses)?;
    Ok((ticket_text(state_dir, ticket)?, id))
}

/// [`mint_ticket_text`] for the app on this computer: the device it pairs is listed as such.
///
/// # Errors
///
/// As [`mint_ticket`].
pub fn mint_this_computer_ticket_text(state_dir: &Path, ttl: Duration) -> io::Result<String> {
    ticket_text(state_dir, mint(state_dir, ttl, true, 1)?.0)
}

/// An unexpired pairing ticket, as `hostd pair --list` shows it. The secret is never listed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingTicket {
    /// Names the ticket for [`revoke_pairing_tickets`]; empty for tickets minted by older
    /// builds.
    pub id: String,
    /// How many devices it may pair in all.
    pub uses: u32,
    /// How many it has paired.
    pub used: u32,
    /// Unix ms.
    pub expires: u64,
    /// Minted for the app on this computer (`pair --local`).
    pub this_computer: bool,
}

/// The pairing tickets still able to pair a device.
///
/// # Errors
///
/// Returns an error if `pairing.json` is unreadable.
pub fn pending_pairing_tickets(state_dir: &Path) -> io::Result<Vec<PendingTicket>> {
    let now = now_millis();
    Ok(
        read_json::<Vec<PairingEntry>>(&state_dir.join(PAIRING_FILE))?
            .unwrap_or_default()
            .into_iter()
            .filter(|entry| entry.expires > now)
            .map(|entry| PendingTicket {
                uses: entry.uses.max(1),
                used: entry.paired.len() as u32,
                id: entry.id,
                expires: entry.expires,
                this_computer: entry.this_computer,
            })
            .collect(),
    )
}

/// Withdraws the pending ticket named `id`, or every pending ticket when `id` is `None`, so it
/// pairs no more devices. Devices it already paired stay paired: remove them with
/// [`unpair_device`]. Returns how many were withdrawn.
///
/// # Errors
///
/// [`io::ErrorKind::NotFound`] if `id` names no pending ticket, or any error reading or
/// writing `pairing.json`.
pub fn revoke_pairing_tickets(state_dir: &Path, id: Option<&str>) -> io::Result<usize> {
    let path = state_dir.join(PAIRING_FILE);
    let id = id.map(|id| id.trim().to_ascii_lowercase());
    fsutil::with_lock(&path, || {
        let mut entries: Vec<PairingEntry> = read_json(&path)?.unwrap_or_default();
        let before = entries.len();
        let now = now_millis();
        let mut revoked = 0;
        entries.retain(|entry| {
            let unexpired = entry.expires > now;
            let named = id.as_deref().is_none_or(|id| entry.id == id);
            if unexpired && named {
                revoked += 1;
            }
            unexpired && !named
        });
        if let Some(id) = &id
            && revoked == 0
        {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("no pending ticket {id}"),
            ));
        }
        if entries.len() != before {
            write_json(&path, &entries)?;
        }
        Ok(revoked)
    })
}

fn ticket_text(state_dir: &Path, ticket: Ticket) -> io::Result<String> {
    let relays = endpoint_info(state_dir)?
        .map(|info| info.relays)
        .unwrap_or_default();
    Ok(ticket.to_string_with(&proto::TicketExtras {
        v: proto::TicketExtras::VERSION,
        relays,
    }))
}

/// A device on the owner allowlist, as `hostd devices` lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairedDevice {
    /// The device's key, lowercase hex.
    pub device: String,
    /// When it paired, Unix ms.
    pub paired_at: u64,
    /// What the owner named it, else what it calls itself; empty until either said.
    pub name: String,
    /// What it calls itself (an iPhone says "iPhone" unless its owner set otherwise).
    pub own_name: String,
    /// When it last connected or disconnected, Unix ms; 0 if never recorded.
    pub last_seen: u64,
    /// The app on this computer (paired with `pair --local`).
    pub this_computer: bool,
}

impl From<DeviceEntry> for PairedDevice {
    fn from(entry: DeviceEntry) -> Self {
        Self {
            name: entry.display_name().to_owned(),
            own_name: entry.name,
            device: entry.device,
            paired_at: entry.paired_at,
            last_seen: entry.last_seen,
            this_computer: entry.this_computer,
        }
    }
}

/// A device name as stored: trimmed, without control characters, at most
/// [`DEVICE_NAME_MAX`] characters.
pub fn clean_device_name(name: &str) -> String {
    name.trim()
        .chars()
        .filter(|character| !character.is_control())
        .take(DEVICE_NAME_MAX)
        .collect::<String>()
        .trim_end()
        .to_owned()
}

/// The devices on the owner allowlist.
///
/// # Errors
///
/// Returns an error if `devices.json` is unreadable.
pub fn list_paired(state_dir: &Path) -> io::Result<Vec<PairedDevice>> {
    Ok(
        read_json::<Vec<DeviceEntry>>(&state_dir.join(DEVICES_FILE))?
            .unwrap_or_default()
            .into_iter()
            .map(PairedDevice::from)
            .collect(),
    )
}

/// Number of devices on the allowlist.
///
/// # Errors
///
/// Returns an error if `devices.json` is unreadable.
pub fn paired_devices(state_dir: &Path) -> io::Result<usize> {
    list_paired(state_dir).map(|devices| devices.len())
}

/// Removes the paired device whose key starts with `prefix` (at least 8 hex digits). A
/// running daemon closes its connections within a second, refuses it from then on, and stops
/// trusting invites it signed; it needs a new pairing ticket to come back, and those invites
/// stay void even then.
///
/// # Errors
///
/// [`io::ErrorKind::InvalidInput`] if the prefix is too short or matches several devices,
/// [`io::ErrorKind::NotFound`] if it matches none, or any error reading or writing the file.
pub fn unpair_device(state_dir: &Path, prefix: &str) -> io::Result<PairedDevice> {
    let prefix = device_prefix(prefix)?;
    let path = state_dir.join(DEVICES_FILE);
    let removed_path = state_dir.join(REMOVED_FILE);
    fsutil::with_lock(&path, || {
        let mut list: Vec<DeviceEntry> = read_json(&path)?.unwrap_or_default();
        let mut removed: Removed = read_json(&removed_path)?.unwrap_or_default();
        let entry = list[find_device(&list, &prefix)?].clone();
        remove_device(&mut list, &mut removed, &entry.device);
        write_json(&removed_path, &removed)?;
        write_json(&path, &list)?;
        Ok(entry.into())
    })
}

/// Names the paired device whose key starts with `prefix` (at least 8 hex digits) as the owner
/// wants it listed, here and in the apps; an empty name goes back to what the device calls
/// itself. A running daemon picks it up on its next check.
///
/// # Errors
///
/// As [`unpair_device`].
pub fn rename_device(state_dir: &Path, prefix: &str, name: &str) -> io::Result<PairedDevice> {
    let prefix = device_prefix(prefix)?;
    let path = state_dir.join(DEVICES_FILE);
    fsutil::with_lock(&path, || {
        let mut list: Vec<DeviceEntry> = read_json(&path)?.unwrap_or_default();
        let index = find_device(&list, &prefix)?;
        let label = clean_device_name(name);
        if list[index].label != label {
            list[index].label = label;
            write_json(&path, &list)?;
        }
        Ok(list[index].clone().into())
    })
}

fn device_prefix(prefix: &str) -> io::Result<String> {
    let prefix = prefix.trim().to_ascii_lowercase();
    if prefix.len() < 8 || !prefix.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "give at least 8 hex digits of the device key",
        ));
    }
    Ok(prefix)
}

fn find_device(list: &[DeviceEntry], prefix: &str) -> io::Result<usize> {
    let matches: Vec<usize> = (0..list.len())
        .filter(|&i| list[i].device.starts_with(prefix))
        .collect();
    match matches[..] {
        [index] => Ok(index),
        [] => Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("no paired device starts with {prefix}"),
        )),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("several paired devices start with {prefix}; give more digits"),
        )),
    }
}

#[cfg(test)]
mod tests {
    use std::thread;

    use super::*;

    /// Uses `secret` for a fresh device, as a single-use ticket sees it.
    fn consume(dir: &Path, secret: PairingSecret) -> io::Result<Option<Pairing>> {
        consume_pairing_secret(dir, secret, &hex(&fsutil::random::<32>()), None)
    }

    /// A state dir as a started daemon leaves it: key, owner and `endpoint.json`.
    fn started_daemon() -> tempfile::TempDir {
        let dir = tempfile::tempdir().expect("temp dir");
        let identity = Identity::load_or_create(dir.path()).expect("identity");
        let info = EndpointInfo {
            daemon_id: hex(&identity.daemon_id().0),
            addrs: vec!["127.0.0.1:1".parse().expect("addr")],
            relay_url: None,
            relays: proto::TicketRelays::default(),
            pid: std::process::id(),
            started_at: now_millis(),
            bound: Vec::new(),
        };
        write_endpoint_info(dir.path(), &info).expect("endpoint");
        dir
    }

    /// The daemon mints its startup ticket while `hostd pair` (another process) mints one, and
    /// devices pair while others are minted: every secret handed out stays valid, once.
    #[test]
    fn concurrent_mints_and_consumes_lose_no_secret() {
        let dir = started_daemon();
        let dir = dir.path();
        let minted: Vec<PairingSecret> = thread::scope(|scope| {
            let minters: Vec<_> = (0..6)
                .map(|_| {
                    scope.spawn(|| {
                        (0..10)
                            .map(|_| mint_ticket(dir, PAIRING_TTL).expect("mint").secret)
                            .collect::<Vec<_>>()
                    })
                })
                .collect();
            minters
                .into_iter()
                .flat_map(|minter| minter.join().expect("minter"))
                .collect()
        });
        assert_eq!(minted.len(), 60);

        let consumed: usize = thread::scope(|scope| {
            let consumers: Vec<_> = minted
                .chunks(10)
                .map(|chunk| {
                    scope.spawn(move || {
                        chunk
                            .iter()
                            .filter(|secret| {
                                consume(dir, PairingSecret(secret.0))
                                    .expect("consume")
                                    .is_some()
                            })
                            .count()
                    })
                })
                .collect();
            // Tickets minted meanwhile must survive the consumers' rewrites.
            let late: Vec<_> = (0..10)
                .map(|_| mint_ticket(dir, PAIRING_TTL).expect("mint").secret)
                .collect();
            let consumed = consumers
                .into_iter()
                .map(|consumer| consumer.join().expect("consumer"))
                .sum();
            for secret in late {
                assert!(
                    consume(dir, secret).expect("consume").is_some(),
                    "a ticket minted while others paired is still valid"
                );
            }
            consumed
        });
        assert_eq!(consumed, minted.len(), "every minted secret pairs");
        for secret in &minted {
            assert_eq!(
                consume(dir, PairingSecret(secret.0)).expect("consume"),
                None,
                "a secret pairs once"
            );
        }
    }

    fn pairing_grant(secret: PairingSecret) -> SignedGrant {
        SignedGrant {
            v: SignedGrant::PAIRING,
            grant_id: proto::GrantId([0; 16]),
            token: secret.0.to_vec(),
        }
    }

    fn device_grant() -> SignedGrant {
        SignedGrant {
            v: SignedGrant::DEVICE,
            grant_id: proto::GrantId([0; 16]),
            token: Vec::new(),
        }
    }

    /// `hostd unpair` (another process) removes a device while the daemon pairs another:
    /// the removed device stays removed, and the daemon stops trusting it at once.
    #[test]
    fn an_unpaired_device_stays_unpaired() {
        let dir = started_daemon();
        let identity = Identity::load_or_create(dir.path()).expect("identity");
        let owner = load_or_create_owner(dir.path()).expect("owner");
        let lost = DeviceId([1; 32]);
        let new = DeviceId([2; 32]);
        let pair = |device| {
            let secret = mint_ticket(dir.path(), PAIRING_TTL).expect("mint").secret;
            identity
                .authorize(device, owner, &pairing_grant(secret))
                .expect("pairs")
        };
        pair(lost);
        assert!(identity.is_owner_device(lost));

        let removed = unpair_device(dir.path(), &hex(&lost.0)[..12]).expect("unpair");
        assert_eq!(removed.device, hex(&lost.0));
        assert!(
            !identity.is_owner_device(lost),
            "trust ends without a restart"
        );
        assert_eq!(
            identity.authorize(lost, owner, &device_grant()),
            Err(RefuseReason::InvalidGrant)
        );

        pair(new);
        let listed: Vec<String> = list_paired(dir.path())
            .expect("list")
            .into_iter()
            .map(|paired| paired.device)
            .collect();
        assert_eq!(
            listed,
            [hex(&new.0)],
            "pairing did not bring the lost device back"
        );
        assert!(!identity.is_owner_device(lost));
        assert!(identity.is_owner_device(new));

        pair(lost);
        assert!(
            identity.is_owner_device(lost),
            "a ticket minted after the removal pairs the device again"
        );
    }

    /// The app on this computer pairs with its own kind of ticket and is listed as such; a
    /// device paired with a plain ticket is not.
    #[test]
    fn the_app_on_this_computer_is_marked() {
        let dir = started_daemon();
        let identity = Identity::load_or_create(dir.path()).expect("identity");
        let owner = load_or_create_owner(dir.path()).expect("owner");
        let app = DeviceId([4; 32]);
        let phone = DeviceId([5; 32]);
        let local = mint_this_computer_ticket_text(dir.path(), PAIRING_TTL).expect("mint");
        let local = Ticket::parse_with_extras(&local).expect("ticket").0;
        identity
            .authorize(app, owner, &pairing_grant(local.secret))
            .expect("pairs");
        let plain = mint_ticket(dir.path(), PAIRING_TTL).expect("mint").secret;
        identity
            .authorize(phone, owner, &pairing_grant(plain))
            .expect("pairs");
        let marked: Vec<(String, bool)> = list_paired(dir.path())
            .expect("list")
            .into_iter()
            .map(|paired| (paired.device, paired.this_computer))
            .collect();
        assert_eq!(marked, [(hex(&app.0), true), (hex(&phone.0), false)]);
    }

    #[test]
    fn unpairing_needs_an_unambiguous_prefix() {
        let dir = started_daemon();
        let identity = Identity::load_or_create(dir.path()).expect("identity");
        let owner = load_or_create_owner(dir.path()).expect("owner");
        for device in [DeviceId([0xab; 32]), DeviceId([0xaa; 32])] {
            let secret = mint_ticket(dir.path(), PAIRING_TTL).expect("mint").secret;
            identity
                .authorize(device, owner, &pairing_grant(secret))
                .expect("pairs");
        }
        let kind = |prefix| unpair_device(dir.path(), prefix).unwrap_err().kind();
        assert_eq!(kind("ab"), io::ErrorKind::InvalidInput);
        assert_eq!(kind("zzzzzzzz"), io::ErrorKind::InvalidInput);
        assert_eq!(kind("cccccccc"), io::ErrorKind::NotFound);
        assert_eq!(list_paired(dir.path()).expect("list").len(), 2);
        unpair_device(dir.path(), "ABABABAB").expect("case-insensitive");
        assert_eq!(list_paired(dir.path()).expect("list").len(), 1);
    }

    /// Wrong guesses, which anyone who knows the daemon id can send, never rewrite the file;
    /// the right secret still pairs once.
    #[test]
    fn wrong_pairing_secrets_cost_no_write() {
        let dir = started_daemon();
        let secret = mint_ticket(dir.path(), PAIRING_TTL).expect("mint").secret;
        let path = dir.path().join(PAIRING_FILE);
        let before = stamp(&path).expect("stat");
        for i in 0..20u8 {
            let mut guess = secret.0;
            guess[15] ^= i + 1;
            assert_eq!(
                consume(dir.path(), PairingSecret(guess)).expect("consume"),
                None
            );
        }
        assert_eq!(stamp(&path).expect("stat"), before);
        assert!(consume(dir.path(), secret).expect("consume").is_some());
        assert_eq!(consume(dir.path(), secret).expect("consume"), None);
    }

    /// An expired ticket is refused by the daemon, whatever the ticket text says.
    #[test]
    fn expired_pairing_secrets_are_refused() {
        let dir = started_daemon();
        let secret = mint_ticket(dir.path(), Duration::ZERO)
            .expect("mint")
            .secret;
        thread::sleep(Duration::from_millis(5));
        assert_eq!(consume(dir.path(), secret).expect("consume"), None);
    }

    /// The owner's name for a device stands over what the device says about itself, from the
    /// daemon or from `hostd rename`; arrivals are recorded at most every few minutes.
    #[test]
    fn owner_names_stand_and_arrivals_are_recorded() {
        let dir = started_daemon();
        let identity = Identity::load_or_create(dir.path()).expect("identity");
        let secret = mint_ticket(dir.path(), PAIRING_TTL).expect("mint").secret;
        let device = DeviceId([9; 32]);
        let owner = load_or_create_owner(dir.path()).expect("owner");
        identity
            .authorize(device, owner, &pairing_grant(secret))
            .expect("paired");
        identity.set_name(device, "iPhone");
        assert!(identity.rename(device, " Work\nphone ").expect("rename"));
        identity.set_name(device, "iPhone 16");
        let listed = &list_paired(dir.path()).expect("list")[0];
        assert_eq!(
            (listed.name.as_str(), listed.own_name.as_str()),
            ("Workphone", "iPhone 16")
        );
        assert_eq!(identity.paired()[0].name, "Workphone");

        let renamed = rename_device(dir.path(), &hex(&device.0)[..8], "").expect("rename");
        assert_eq!(renamed.name, "iPhone 16", "empty goes back to its own name");
        assert!(matches!(
            rename_device(dir.path(), "abc", "x").map_err(|error| error.kind()),
            Err(io::ErrorKind::InvalidInput)
        ));
        assert!(!identity.rename(DeviceId([8; 32]), "x").expect("rename"));

        identity.seen(device, false);
        let first = list_paired(dir.path()).expect("list")[0].last_seen;
        assert!(first > 0);
        let before = stamp(&dir.path().join(DEVICES_FILE)).expect("stat");
        identity.seen(device, false);
        assert_eq!(
            stamp(&dir.path().join(DEVICES_FILE)).expect("stat"),
            before,
            "a quick reconnect writes nothing"
        );
        identity.seen(device, true);
        assert_ne!(stamp(&dir.path().join(DEVICES_FILE)).expect("stat"), before);
    }

    /// Key and allowlist are private to the user.
    #[test]
    fn state_files_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = started_daemon();
        let identity = Identity::load_or_create(dir.path()).expect("identity");
        let owner = load_or_create_owner(dir.path()).expect("owner");
        let secret = mint_ticket(dir.path(), PAIRING_TTL).expect("mint").secret;
        identity
            .authorize(DeviceId([3; 32]), owner, &pairing_grant(secret))
            .expect("pairs");
        let mode = |name: &str| {
            std::fs::metadata(dir.path().join(name))
                .expect("stat")
                .permissions()
                .mode()
                & 0o777
        };
        assert_eq!(mode(""), 0o700);
        for file in [KEY_FILE, OWNER_FILE, DEVICES_FILE, PAIRING_FILE] {
            assert_eq!(mode(file), 0o600, "{file}");
        }
    }

    fn reusable_secret(dir: &Path, ttl: Duration, uses: u32) -> (PairingSecret, String) {
        let (text, id) = mint_reusable_ticket_text(dir, ttl, uses).expect("mint");
        (
            Ticket::parse_with_extras(&text).expect("ticket").0.secret,
            id,
        )
    }

    /// A reusable ticket pairs up to its number of distinct devices, each counted once, then
    /// nothing more; the default ticket stays single use.
    #[test]
    fn a_reusable_ticket_pairs_distinct_devices_up_to_its_uses() {
        let dir = started_daemon();
        let identity = Identity::load_or_create(dir.path()).expect("identity");
        let owner = load_or_create_owner(dir.path()).expect("owner");
        let (secret, id) = reusable_secret(dir.path(), PAIRING_TTL, 3);
        let pair = |byte| identity.authorize(DeviceId([byte; 32]), owner, &pairing_grant(secret));

        assert_eq!(pair(1), Ok(owner));
        assert_eq!(pair(1), Ok(owner), "the same device again takes no use");
        assert_eq!(pair(2), Ok(owner));
        let pending = pending_pairing_tickets(dir.path()).expect("list");
        assert_eq!(
            (pending[0].id.as_str(), pending[0].used, pending[0].uses),
            (id.as_str(), 2, 3),
            "the count is kept on disk"
        );
        assert_eq!(pair(3), Ok(owner));
        assert_eq!(pair(4), Err(RefuseReason::InvalidGrant), "all uses taken");
        assert!(
            pending_pairing_tickets(dir.path())
                .expect("list")
                .is_empty()
        );
        assert_eq!(identity.device_count(), 3);

        let single = mint_ticket(dir.path(), PAIRING_TTL).expect("mint").secret;
        let listed = pending_pairing_tickets(dir.path()).expect("list");
        assert_eq!((listed[0].uses, listed[0].used), (1, 0));
        assert!(consume(dir.path(), single).expect("consume").is_some());
        assert_eq!(consume(dir.path(), single).expect("consume"), None);
    }

    /// Reusable tickets are bounded in uses and lifetime.
    #[test]
    fn reusable_tickets_are_bounded() {
        let dir = started_daemon();
        let kind = |ttl, uses| {
            mint_reusable_ticket_text(dir.path(), ttl, uses)
                .unwrap_err()
                .kind()
        };
        assert_eq!(kind(PAIRING_TTL, 1), io::ErrorKind::InvalidInput);
        assert_eq!(
            kind(PAIRING_TTL, MAX_TICKET_USES + 1),
            io::ErrorKind::InvalidInput
        );
        assert_eq!(
            kind(MAX_REUSABLE_TICKET_TTL + Duration::from_secs(1), 2),
            io::ErrorKind::InvalidInput
        );
        assert!(
            pending_pairing_tickets(dir.path())
                .expect("list")
                .is_empty()
        );
        mint_reusable_ticket_text(dir.path(), MAX_REUSABLE_TICKET_TTL, MAX_TICKET_USES)
            .expect("the bounds themselves are allowed");
    }

    /// An expired reusable ticket pairs nobody, even with uses left.
    #[test]
    fn an_expired_reusable_ticket_is_refused() {
        let dir = started_daemon();
        let (secret, _) = reusable_secret(dir.path(), Duration::ZERO, 5);
        thread::sleep(Duration::from_millis(5));
        assert_eq!(consume(dir.path(), secret).expect("consume"), None);
        assert!(
            pending_pairing_tickets(dir.path())
                .expect("list")
                .is_empty()
        );
    }

    /// Revoking stops a ticket at once, by id or all together; devices it paired stay paired
    /// until removed.
    #[test]
    fn revoked_tickets_pair_no_more_devices() {
        let dir = started_daemon();
        let identity = Identity::load_or_create(dir.path()).expect("identity");
        let owner = load_or_create_owner(dir.path()).expect("owner");
        let (first, first_id) = reusable_secret(dir.path(), PAIRING_TTL, 5);
        let (second, _) = reusable_secret(dir.path(), PAIRING_TTL, 5);
        let single = mint_ticket(dir.path(), PAIRING_TTL).expect("mint").secret;
        identity
            .authorize(DeviceId([1; 32]), owner, &pairing_grant(first))
            .expect("pairs");

        assert_eq!(
            revoke_pairing_tickets(dir.path(), Some("00000000"))
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound
        );
        assert_eq!(
            revoke_pairing_tickets(dir.path(), Some(&first_id.to_ascii_uppercase()))
                .expect("revoke"),
            1
        );
        assert_eq!(
            identity.authorize(DeviceId([2; 32]), owner, &pairing_grant(first)),
            Err(RefuseReason::InvalidGrant)
        );
        assert!(identity.is_owner_device(DeviceId([1; 32])));

        assert_eq!(revoke_pairing_tickets(dir.path(), None).expect("revoke"), 2);
        for secret in [second, single] {
            assert_eq!(
                identity.authorize(DeviceId([3; 32]), owner, &pairing_grant(secret)),
                Err(RefuseReason::InvalidGrant)
            );
        }
    }

    /// A device removed from the allowlist cannot come back on a reusable ticket minted before
    /// its removal; other devices still can, and a newer ticket brings it back.
    #[test]
    fn an_unpaired_device_cannot_reuse_a_shared_ticket() {
        let dir = started_daemon();
        let identity = Identity::load_or_create(dir.path()).expect("identity");
        let owner = load_or_create_owner(dir.path()).expect("owner");
        let (secret, _) = reusable_secret(dir.path(), PAIRING_TTL, 5);
        let lost = DeviceId([1; 32]);
        identity
            .authorize(lost, owner, &pairing_grant(secret))
            .expect("pairs");
        unpair_device(dir.path(), &hex(&lost.0)).expect("unpair");

        assert_eq!(
            identity.authorize(lost, owner, &pairing_grant(secret)),
            Err(RefuseReason::InvalidGrant)
        );
        assert!(!identity.is_owner_device(lost));
        identity
            .authorize(DeviceId([2; 32]), owner, &pairing_grant(secret))
            .expect("another device still pairs");

        thread::sleep(Duration::from_millis(2));
        let (newer, _) = reusable_secret(dir.path(), PAIRING_TTL, 2);
        identity
            .authorize(lost, owner, &pairing_grant(newer))
            .expect("a newer ticket pairs it again");
    }

    /// Many devices race one reusable ticket: exactly its number of uses pair, and the count on
    /// disk matches.
    #[test]
    fn a_raced_reusable_ticket_pairs_exactly_its_uses() {
        let dir = started_daemon();
        let dir = dir.path();
        let (secret, _) = reusable_secret(dir, PAIRING_TTL, MAX_TICKET_USES);
        let other = mint_ticket(dir, PAIRING_TTL).expect("mint").secret;
        let paired: usize = thread::scope(|scope| {
            let racers: Vec<_> = (0..MAX_TICKET_USES as u8 + 10)
                .map(|byte| {
                    scope.spawn(move || {
                        consume_pairing_secret(dir, secret, &hex(&[byte; 32]), None)
                            .expect("consume")
                            .is_some()
                    })
                })
                .collect();
            let late = mint_ticket(dir, PAIRING_TTL).expect("mint").secret;
            let paired = racers
                .into_iter()
                .map(|racer| racer.join().expect("racer"))
                .filter(|&paired| paired)
                .count();
            assert!(
                consume(dir, late).expect("consume").is_some(),
                "a ticket minted during the race survives it"
            );
            paired
        });
        assert_eq!(paired, MAX_TICKET_USES as usize);
        assert!(consume(dir, other).expect("consume").is_some());
        assert!(pending_pairing_tickets(dir).expect("list").is_empty());
    }
}
