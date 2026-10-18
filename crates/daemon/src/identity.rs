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
//! | `pairing.json` | unused pairing secrets with expiry |
//! | `endpoint.json` | where the running daemon listens (written by `run`) |

use std::io;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
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

/// The daemon's long-lived identity and authorisation state.
#[derive(Debug)]
pub(crate) struct Identity {
    pub secret: iroh::SecretKey,
    dir: PathBuf,
    devices: Mutex<Vec<DeviceEntry>>,
}

impl Identity {
    /// Loads the key and owner from `dir`, creating them on first run.
    pub fn load_or_create(dir: &Path) -> io::Result<Self> {
        fsutil::create_private_dir(dir)?;
        let secret = load_or_create_key(dir)?;
        load_or_create_owner(dir)?;
        let devices = read_json(&dir.join(DEVICES_FILE))?.unwrap_or_default();
        Ok(Self {
            secret,
            dir: dir.to_owned(),
            devices: Mutex::new(devices),
        })
    }

    pub fn daemon_id(&self) -> DaemonId {
        DaemonId(*self.secret.public().as_bytes())
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
                let mut devices = self.devices.lock().expect("devices lock");
                devices.retain(|d| d.device != device_hex);
                devices.push(DeviceEntry {
                    device: device_hex,
                    principal: hex(&principal.0),
                    paired_at: now_millis(),
                });
                if let Err(e) = write_json(&self.dir.join(DEVICES_FILE), &*devices) {
                    tracing::warn!("saving paired devices: {e}");
                }
                tracing::info!(?device, "paired new device");
                Ok(principal)
            }
            SignedGrant::DEVICE => {
                // Re-read so `hostd` CLI edits (unpair) apply to new connections at once.
                if let Ok(Some(fresh)) = read_json::<Vec<DeviceEntry>>(&self.dir.join(DEVICES_FILE))
                {
                    *self.devices.lock().expect("devices lock") = fresh;
                }
                let devices = self.devices.lock().expect("devices lock");
                let entry = devices
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
        self.devices.lock().expect("devices lock").len()
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
    let mut entries: Vec<PairingEntry> = read_json(&path)?.unwrap_or_default();
    let now = now_millis();
    let wanted = hex(&secret.0);
    let found = entries
        .iter()
        .position(|e| e.secret == wanted && e.expires > now);
    let principal = found.and_then(|i| unhex(&entries.remove(i).principal).map(PrincipalId));
    entries.retain(|e| e.expires > now);
    write_json(&path, &entries)?;
    Ok(principal)
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
    let mut entries: Vec<PairingEntry> = read_json(&path)?.unwrap_or_default();
    let now = now_millis();
    entries.retain(|e| e.expires > now);
    entries.push(PairingEntry {
        secret: hex(&secret.0),
        principal: hex(&owner.0),
        expires,
    });
    write_json(&path, &entries)?;
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

/// Number of devices on the allowlist.
///
/// # Errors
///
/// Returns an error if `devices.json` is unreadable.
pub fn paired_devices(state_dir: &Path) -> io::Result<usize> {
    Ok(
        read_json::<Vec<DeviceEntry>>(&state_dir.join(DEVICES_FILE))?
            .unwrap_or_default()
            .len(),
    )
}
