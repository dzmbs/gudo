//! Daemon key, owner principal, paired devices and one-time pairing secrets.
//!
//! Everything is a small file in the state directory, so `hostd pair` (a separate process)
//! can mint a secret that the running daemon accepts:
//!
//! | file | contents |
//! |---|---|
//! | `daemon.key` | iroh Ed25519 secret key, 32 raw bytes, mode 0600 |
//! | `owner.json` | the owner principal |
//! | `devices.json` | the device allowlist |
//! | `pairing.json` | unused pairing secrets with expiry (changed under `pairing.lock`) |
//! | `endpoint.json` | where the running daemon listens (written by `run`) |

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
const PAIRING_FILE: &str = "pairing.json";
const ENDPOINT_FILE: &str = "endpoint.json";

/// Default lifetime of a pairing ticket.
pub const PAIRING_TTL: Duration = Duration::from_secs(10 * 60);

#[derive(Debug, Serialize, Deserialize)]
struct OwnerFile {
    principal: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DeviceEntry {
    device: String,
    principal: String,
    paired_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PairingEntry {
    secret: String,
    principal: String,
    expires: u64,
}

/// Where a running daemon can be reached; written at startup for `pair` and `status`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EndpointInfo {
    /// The daemon's endpoint id, hex.
    pub daemon_id: String,
    /// Direct addresses.
    pub addrs: Vec<SocketAddr>,
    /// Home relay, if any.
    pub relay_url: Option<String>,
    /// The relays the daemon uses (default, self-hosted or none), for pairing tickets.
    #[serde(default)]
    pub relays: proto::TicketRelays,
    /// Process id of the daemon.
    pub pid: u32,
    /// When it started.
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
        .map_or(0, |d| d.as_millis() as u64)
}

fn json_error(e: serde_json::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, e)
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
        Ok(m) => Ok(Some(Stamp {
            dev: m.dev(),
            ino: m.ino(),
            mtime_ns: i128::from(m.mtime()) * 1_000_000_000 + i128::from(m.mtime_nsec()),
            len: m.len(),
        })),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// The allowlist as last read, with the file version it came from.
#[derive(Debug, Default)]
struct Devices {
    list: Vec<DeviceEntry>,
    stamp: Option<Stamp>,
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

    fn lock_devices(&self) -> MutexGuard<'_, Devices> {
        self.devices.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Reads `devices.json` if it changed since the last read, so `hostd unpair` (another
    /// process) takes effect for every check at once.
    fn load_devices(&self) -> io::Result<()> {
        let path = self.devices_path();
        let now = stamp(&path)?;
        let mut devices = self.lock_devices();
        if now.is_some() && devices.stamp == now {
            return Ok(());
        }
        devices.list = read_json(&path)?.unwrap_or_default();
        devices.stamp = now;
        Ok(())
    }

    /// [`Self::load_devices`], keeping the last good list if the file is unreadable.
    fn refresh(&self) {
        if let Err(e) = self.load_devices() {
            tracing::warn!("reading paired devices: {e}");
        }
    }

    /// Changes the allowlist under its file lock, starting from the file's current contents,
    /// so a change here never undoes one another process just made. `change` says whether it
    /// changed anything; only then is the file written.
    fn update_devices(
        &self,
        change: impl FnOnce(&mut Vec<DeviceEntry>) -> bool,
    ) -> io::Result<bool> {
        let path = self.devices_path();
        fsutil::with_lock(&path, || {
            let mut list: Vec<DeviceEntry> = read_json(&path)?.unwrap_or_default();
            let changed = change(&mut list);
            if changed {
                write_json(&path, &list)?;
            }
            let mut devices = self.lock_devices();
            devices.stamp = stamp(&path)?;
            devices.list = list;
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
                let principal = consume_pairing_secret(&self.dir, PairingSecret(secret))
                    .map_err(|_| RefuseReason::InvalidGrant)?
                    .ok_or(RefuseReason::InvalidGrant)?;
                let entry = DeviceEntry {
                    device: device_hex.clone(),
                    principal: hex(&principal.0),
                    paired_at: now_millis(),
                };
                self.update_devices(|list| {
                    list.retain(|d| d.device != device_hex);
                    list.push(entry);
                    true
                })
                .map_err(|e| {
                    tracing::warn!("saving paired devices: {e}");
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
                    .find(|d| d.device == device_hex)
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

    /// Number of paired devices.
    pub fn device_count(&self) -> usize {
        self.refresh();
        self.lock_devices().list.len()
    }

    /// The daemon key as a device id: it may sign root grants (`unnamed-hostd invite`).
    pub fn daemon_device(&self) -> DeviceId {
        DeviceId(self.daemon_id().0)
    }

    /// Whether `device` is a paired owner device (it may sign root grants).
    pub fn is_owner_device(&self, device: DeviceId) -> bool {
        self.refresh();
        let hex_id = hex(&device.0);
        self.lock_devices().list.iter().any(|d| d.device == hex_id)
    }

    /// Paired devices: key, principal and when they paired.
    pub fn paired(&self) -> Vec<(DeviceId, PrincipalId, UnixMillis)> {
        self.refresh();
        self.lock_devices()
            .list
            .iter()
            .filter_map(|d| {
                Some((
                    DeviceId(unhex(&d.device)?),
                    PrincipalId(unhex(&d.principal)?),
                    UnixMillis(d.paired_at),
                ))
            })
            .collect()
    }

    /// Removes a paired device. Returns whether it was paired.
    pub fn unpair(&self, device: DeviceId) -> bool {
        let hex_id = hex(&device.0);
        self.update_devices(|list| {
            let before = list.len();
            list.retain(|d| d.device != hex_id);
            list.len() != before
        })
        .unwrap_or_else(|e| {
            tracing::warn!("saving paired devices: {e}");
            false
        })
    }
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

/// Removes `secret` from the pending list if present and unexpired, returning its principal.
fn consume_pairing_secret(dir: &Path, secret: PairingSecret) -> io::Result<Option<PrincipalId>> {
    let path = dir.join(PAIRING_FILE);
    fsutil::with_lock(&path, || {
        let mut entries: Vec<PairingEntry> = read_json(&path)?.unwrap_or_default();
        let before = entries.len();
        let now = now_millis();
        let found = entries.iter().position(|e| {
            e.expires > now
                && unhex::<16>(&e.secret).is_some_and(|s| fsutil::constant_eq(&s, &secret.0))
        });
        let principal = found.and_then(|i| unhex(&entries.remove(i).principal).map(PrincipalId));
        entries.retain(|e| e.expires > now);
        // A wrong guess costs no disk write: anyone who knows the daemon id can send them.
        if entries.len() != before {
            write_json(&path, &entries)?;
        }
        Ok(principal)
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
    let expires = now_millis() + ttl.as_millis() as u64;
    let path = state_dir.join(PAIRING_FILE);
    fsutil::with_lock(&path, || {
        let mut entries: Vec<PairingEntry> = read_json(&path)?.unwrap_or_default();
        let now = now_millis();
        entries.retain(|e| e.expires > now);
        entries.push(PairingEntry {
            secret: hex(&secret.0),
            principal: hex(&owner.0),
            expires,
        });
        write_json(&path, &entries)
    })?;
    Ok(Ticket {
        v: Ticket::VERSION,
        daemon_id,
        addrs: info.addrs,
        relay_url: info.relay_url,
        principal: owner,
        secret,
        expires: UnixMillis(expires),
    })
}

/// [`mint_ticket`] as text, with the running daemon's relay choice appended
/// ([`proto::TicketExtras`]) so the app dials through the same self-hosted relays, or none.
///
/// # Errors
///
/// As [`mint_ticket`].
pub fn mint_ticket_text(state_dir: &Path, ttl: Duration) -> io::Result<String> {
    let ticket = mint_ticket(state_dir, ttl)?;
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
}

impl From<DeviceEntry> for PairedDevice {
    fn from(d: DeviceEntry) -> Self {
        Self {
            device: d.device,
            paired_at: d.paired_at,
        }
    }
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
    list_paired(state_dir).map(|d| d.len())
}

/// Removes the paired device whose key starts with `prefix` (at least 8 hex digits). A
/// running daemon closes its connections within a second, refuses it from then on, and stops
/// trusting invites it signed; it needs a new pairing ticket to come back.
///
/// # Errors
///
/// [`io::ErrorKind::InvalidInput`] if the prefix is too short or matches several devices,
/// [`io::ErrorKind::NotFound`] if it matches none, or any error reading or writing the file.
pub fn unpair_device(state_dir: &Path, prefix: &str) -> io::Result<PairedDevice> {
    let prefix = prefix.trim().to_ascii_lowercase();
    if prefix.len() < 8 || !prefix.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "give at least 8 hex digits of the device key",
        ));
    }
    let path = state_dir.join(DEVICES_FILE);
    fsutil::with_lock(&path, || {
        let mut list: Vec<DeviceEntry> = read_json(&path)?.unwrap_or_default();
        let matches: Vec<usize> = (0..list.len())
            .filter(|&i| list[i].device.starts_with(&prefix))
            .collect();
        let i = match matches[..] {
            [i] => i,
            [] => {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("no paired device starts with {prefix}"),
                ));
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("several paired devices start with {prefix}; give more digits"),
                ));
            }
        };
        let removed = list.remove(i);
        write_json(&path, &list)?;
        Ok(removed.into())
    })
}

#[cfg(test)]
mod tests {
    use std::thread;

    use super::*;

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
    /// devices pair while others are minted: every secret handed out stays valid, once. (A
    /// lost write here was a ticket the daemon refused with `InvalidGrant`.)
    #[test]
    fn concurrent_mints_and_consumes_lose_no_secret() {
        let dir = started_daemon();
        let dir = dir.path();
        let minted: Vec<PairingSecret> = thread::scope(|s| {
            let minters: Vec<_> = (0..6)
                .map(|_| {
                    s.spawn(|| {
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

        let consumed: usize = thread::scope(|s| {
            let consumers: Vec<_> = minted
                .chunks(10)
                .map(|chunk| {
                    s.spawn(move || {
                        chunk
                            .iter()
                            .filter(|secret| {
                                consume_pairing_secret(dir, PairingSecret(secret.0))
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
                .map(|c| c.join().expect("consumer"))
                .sum();
            for secret in late {
                assert!(
                    consume_pairing_secret(dir, secret)
                        .expect("consume")
                        .is_some(),
                    "a ticket minted while others paired is still valid"
                );
            }
            consumed
        });
        assert_eq!(consumed, minted.len(), "every minted secret pairs");
        for secret in &minted {
            assert_eq!(
                consume_pairing_secret(dir, PairingSecret(secret.0)).expect("consume"),
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
            .map(|d| d.device)
            .collect();
        assert_eq!(
            listed,
            [hex(&new.0)],
            "pairing did not bring the lost device back"
        );
        assert!(!identity.is_owner_device(lost));
        assert!(identity.is_owner_device(new));
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
                consume_pairing_secret(dir.path(), PairingSecret(guess)).expect("consume"),
                None
            );
        }
        assert_eq!(stamp(&path).expect("stat"), before);
        assert!(
            consume_pairing_secret(dir.path(), secret)
                .expect("consume")
                .is_some()
        );
        assert_eq!(
            consume_pairing_secret(dir.path(), secret).expect("consume"),
            None
        );
    }

    /// An expired ticket is refused by the daemon, whatever the ticket text says.
    #[test]
    fn expired_pairing_secrets_are_refused() {
        let dir = started_daemon();
        let secret = mint_ticket(dir.path(), Duration::ZERO)
            .expect("mint")
            .secret;
        thread::sleep(Duration::from_millis(5));
        assert_eq!(
            consume_pairing_secret(dir.path(), secret).expect("consume"),
            None
        );
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
}
