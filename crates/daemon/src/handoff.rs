//! Hot upgrade: running panes survive the daemon replacing itself with `exec`.
//!
//! The running daemon stops serving, stops every pane's PTY without closing it
//! ([`pty::PtyActor::hand_off`]), captures each terminal with the snapshot format clients
//! use, and writes everything to an anonymous file (a `memfd` on Linux; on macOS a 0600 file
//! in the state directory, unlinked as soon as it is created). Right before `exec` it clears
//! `FD_CLOEXEC` on that file and on the pane masters, and only on those, and names the file in
//! [`HANDOFF_ENV`], passed to the new build alone (never set in this process, so panes never
//! see it). `exec` keeps the pid, so the children stay the new build's children.
//!
//! The new build ([`Inherited::claim`], first thing in `run`) takes the variable out of its
//! environment, makes every inherited descriptor close-on-exec again before anything else can
//! start a program, and reads the file. Its header is fixed for every version: the masters and
//! child pids it carries. So a build that cannot read the rest (another payload version, or
//! damage) still ends those panes cleanly ([`pty::abandon`]: hang up, kill the group after a
//! grace period, reap) and starts as after a plain restart. A pane it can read is adopted
//! when it is checked to be a PTY master and an unreaped child of this process.
//!
//! The session epoch and the input numbers applied per client stream carry over too, so a
//! client reconnects as after a network change: streams resume from their offsets (the
//! output ring carries over), input it sends again is applied once.

use std::collections::HashMap;
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use proto::{AgentKind, DeviceId, PaneId, PaneSize, Seq, SessionEpoch, SnapGen};
use serde::{Deserialize, Serialize};

use crate::core::Core;
use crate::pane::{PaneHandOff, ResizeRecord};

/// The payload version this build writes and reads.
pub const HANDOFF_VERSION: u32 = 1;
/// The payload versions this build can adopt, as `build-info --json` reports them
/// (`"handoff"`): a running daemon hands off only to a build that reads its version.
pub const HANDOFF_READS: &[u32] = &[HANDOFF_VERSION];

/// The suffix of the environment variable naming the inherited hand-off descriptor.
pub const HANDOFF_ENV: &str = "HANDOFF_FD";

const MAGIC: [u8; 8] = *b"HOSTDHO\0";
const MAX_PANES: u32 = 1 << 16;
const MAX_FILE: u64 = 8 << 30;
const MAX_BLOB: u64 = 2 << 30;
/// How long a pane nobody continues may outlive its hangup before its group is killed.
const ABANDON_GRACE: Duration = Duration::from_secs(3);
const ZSTD_LEVEL: i32 = 1;

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
struct Blob {
    offset: u64,
    len: u64,
    raw_len: u64,
}

#[derive(Debug, Serialize, Deserialize)]
struct Payload {
    epoch: u64,
    inputs: Vec<InputRecord>,
    panes: Vec<PaneRecord>,
}

#[derive(Debug, Serialize, Deserialize)]
struct InputRecord {
    device: String,
    stream: u64,
    applied: u64,
}

#[derive(Debug, Serialize, Deserialize)]
struct PaneRecord {
    pane_id: u64,
    fd: RawFd,
    pid: u32,
    snap_gen: u64,
    ring_capacity: u64,
    head: u64,
    retained: Blob,
    unsent_input: Blob,
    exit_status: Option<i32>,
    snapshot: Option<Blob>,
    size: PaneSize,
    resize_count: u64,
    resizes: Vec<(u64, u64, PaneSize)>,
    last_command_id: u64,
    title: String,
    cwd: Option<String>,
    at_prompt: bool,
    launched_at_ms: u64,
    agent: Option<AgentKind>,
}

/// A pane as one build hands it to the next.
#[derive(Debug)]
pub(crate) struct CarriedPane {
    pub id: PaneId,
    pub state: PaneHandOff,
    pub title: String,
    pub cwd: Option<String>,
    pub at_prompt: bool,
    pub launched_at: SystemTime,
    /// The agent the pane ran (launched or detected), resumed in its unknown state.
    pub agent: Option<AgentKind>,
}

/// Everything a hand-off carries.
#[derive(Debug, Default)]
pub(crate) struct Carried {
    pub epoch: Option<SessionEpoch>,
    pub inputs: Vec<(DeviceId, u64, u64)>,
    pub panes: Vec<CarriedPane>,
}

/// Serializes `carried`: the fixed header (masters and pids), then the payload.
pub(crate) fn encode(carried: &Carried) -> io::Result<Vec<u8>> {
    let mut blobs = Vec::new();
    let mut add = |raw: &[u8]| -> io::Result<Blob> {
        let compressed = zstd::bulk::compress(raw, ZSTD_LEVEL)?;
        let blob = Blob {
            offset: blobs.len() as u64,
            len: compressed.len() as u64,
            raw_len: raw.len() as u64,
        };
        blobs.extend_from_slice(&compressed);
        Ok(blob)
    };
    let mut panes = Vec::with_capacity(carried.panes.len());
    for pane in &carried.panes {
        let state = &pane.state;
        panes.push(PaneRecord {
            pane_id: pane.id.0,
            fd: state.pty.master,
            pid: state.pty.pid,
            snap_gen: state.snap_gen.0,
            ring_capacity: state.pty.ring_capacity as u64,
            head: state.pty.head.get(),
            retained: add(&state.pty.retained)?,
            unsent_input: add(&state.pty.unsent_input)?,
            exit_status: state.pty.exit_status,
            snapshot: state.snapshot.as_deref().map(&mut add).transpose()?,
            size: state.size,
            resize_count: state.resize_count,
            resizes: state
                .resizes
                .iter()
                .map(|record| (record.index, record.at.0, record.size))
                .collect(),
            last_command_id: state.last_command_id,
            title: pane.title.clone(),
            cwd: pane.cwd.clone(),
            at_prompt: pane.at_prompt,
            launched_at_ms: pane
                .launched_at
                .duration_since(UNIX_EPOCH)
                .map_or(0, |since| since.as_millis() as u64),
            agent: pane.agent,
        });
    }
    let payload = Payload {
        epoch: carried.epoch.map_or(0, |epoch| epoch.0),
        inputs: carried
            .inputs
            .iter()
            .map(|(device, stream, applied)| InputRecord {
                device: crate::fsutil::hex(&device.0),
                stream: *stream,
                applied: *applied,
            })
            .collect(),
        panes,
    };
    let meta = serde_json::to_vec(&payload).map_err(io::Error::other)?;
    let mut out = Vec::with_capacity(32 + meta.len() + blobs.len());
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&HANDOFF_VERSION.to_le_bytes());
    out.extend_from_slice(&(carried.panes.len() as u32).to_le_bytes());
    for pane in &carried.panes {
        out.extend_from_slice(&pane.state.pty.master.to_le_bytes());
        out.extend_from_slice(&pane.state.pty.pid.to_le_bytes());
    }
    out.extend_from_slice(&(meta.len() as u64).to_le_bytes());
    out.extend_from_slice(&meta);
    out.extend_from_slice(&(blobs.len() as u64).to_le_bytes());
    out.extend_from_slice(&blobs);
    Ok(out)
}

/// The fixed header: the payload version and the (master, pid) pairs.
fn read_header(file: &mut impl Read) -> io::Result<(u32, Vec<(RawFd, u32)>)> {
    let mut magic = [0; 8];
    file.read_exact(&mut magic)?;
    if magic != MAGIC {
        return Err(invalid("not a hand-off"));
    }
    let version = read_u32(file)?;
    let count = read_u32(file)?;
    if count > MAX_PANES {
        return Err(invalid("too many panes"));
    }
    let mut panes = Vec::with_capacity(count as usize);
    for _ in 0..count {
        let fd = read_u32(file)? as RawFd;
        let pid = read_u32(file)?;
        panes.push((fd, pid));
    }
    Ok((version, panes))
}

fn read_u32(file: &mut impl Read) -> io::Result<u32> {
    let mut bytes = [0; 4];
    file.read_exact(&mut bytes)?;
    Ok(u32::from_le_bytes(bytes))
}

fn read_section(file: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut len = [0; 8];
    file.read_exact(&mut len)?;
    let len = u64::from_le_bytes(len);
    if len > MAX_FILE {
        return Err(invalid("section too large"));
    }
    let mut section = Vec::new();
    file.take(len).read_to_end(&mut section)?;
    if section.len() as u64 != len {
        return Err(invalid("truncated"));
    }
    Ok(section)
}

fn unblob(blobs: &[u8], blob: Blob) -> io::Result<Vec<u8>> {
    let end = blob
        .offset
        .checked_add(blob.len)
        .ok_or_else(|| invalid("blob"))?;
    if end > blobs.len() as u64 || blob.raw_len > MAX_BLOB {
        return Err(invalid("blob out of range"));
    }
    let raw = zstd::bulk::decompress(
        &blobs[blob.offset as usize..end as usize],
        blob.raw_len as usize,
    )?;
    if raw.len() as u64 != blob.raw_len {
        return Err(invalid("blob length"));
    }
    Ok(raw)
}

fn invalid(what: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("hand-off: {what}"))
}

/// Creates the anonymous, private file the hand-off is written to: close-on-exec until
/// [`HandOff::prepare_exec`].
pub(crate) fn create_file(state_dir: &std::path::Path) -> io::Result<File> {
    #[cfg(target_os = "linux")]
    if let Ok(fd) = rustix::fs::memfd_create(c"hostd-handoff", rustix::fs::MemfdFlags::CLOEXEC) {
        return Ok(File::from(fd));
    }
    use std::os::unix::fs::OpenOptionsExt;
    let path = state_dir.join(format!(
        ".handoff-{}",
        crate::fsutil::hex(&crate::fsutil::random::<8>())
    ));
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)?;
    std::fs::remove_file(&path)?;
    Ok(file)
}

/// A daemon stopped for the build it `exec`s next, its panes still running.
///
/// Dropping it (or [`abandon`](Self::abandon)) when no `exec` follows ends the panes.
pub struct HandOff {
    file: File,
    masters: Vec<(RawFd, u32)>,
    core: Arc<Core>,
}

impl HandOff {
    pub(crate) fn new(file: File, masters: Vec<(RawFd, u32)>, core: Arc<Core>) -> Self {
        Self {
            file,
            masters,
            core,
        }
    }

    /// The environment variable to pass to the next build, and its value.
    pub fn env(&self) -> (OsString, OsString) {
        (
            brand::env_var(HANDOFF_ENV).into(),
            self.file.as_raw_fd().to_string().into(),
        )
    }

    /// How many panes it carries.
    pub fn panes(&self) -> usize {
        self.masters.len()
    }

    /// Clears `FD_CLOEXEC` on the hand-off file and the pane masters, and on nothing else:
    /// call it right before `exec`.
    ///
    /// # Errors
    ///
    /// If a flag cannot be changed; nothing should be `exec`ed with the hand-off then.
    pub fn prepare_exec(&self) -> io::Result<()> {
        rustix::io::fcntl_setfd(&self.file, rustix::io::FdFlags::empty())?;
        for (master, _) in &self.masters {
            // SAFETY: the panes' actors (kept alive by `core`) own these descriptors.
            let fd = unsafe { BorrowedFd::borrow_raw(*master) };
            rustix::io::fcntl_setfd(fd, rustix::io::FdFlags::empty())?;
        }
        Ok(())
    }

    /// No `exec` follows (it failed): ends the panes it carried as closing them would, and
    /// waits until they are gone.
    pub fn abandon(self) {
        let _ = rustix::io::fcntl_setfd(&self.file, rustix::io::FdFlags::CLOEXEC);
        end_panes(&self.core, ABANDON_GRACE);
    }
}

impl Drop for HandOff {
    fn drop(&mut self) {
        // Ends nothing more on a second call: each pane is reaped once.
        end_panes(&self.core, Duration::ZERO);
    }
}

/// Hangs up every handed-off pane, kills what still runs after `grace`, and reaps them.
pub(crate) fn end_panes(core: &Core, grace: Duration) {
    let panes: Vec<_> = core
        .pane_entries()
        .into_iter()
        .map(|(_, entry)| Arc::clone(&entry.pane))
        .collect();
    std::thread::scope(|scope| {
        for pane in &panes {
            scope.spawn(move || pane.pty().end_handed_off(grace));
        }
    });
}

/// What the previous build handed over, claimed at startup.
pub struct Inherited {
    file: File,
    version: u32,
    masters: Vec<(OwnedFd, u32)>,
}

impl std::fmt::Debug for Inherited {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Inherited")
            .field("version", &self.version)
            .field("panes", &self.masters.len())
            .finish_non_exhaustive()
    }
}

impl Inherited {
    /// Takes over what the previous build handed off, if it did: removes [`HANDOFF_ENV`] from
    /// the environment, makes every inherited descriptor close-on-exec, and takes the masters
    /// the hand-off names. Call it first thing in the process, while it has one thread and
    /// before it starts any program.
    ///
    /// Returns `None` without a hand-off, or when its header is unreadable (the inherited
    /// descriptors then stay open, close-on-exec, and nothing is adopted).
    pub fn claim() -> Option<Self> {
        let name = brand::env_var(HANDOFF_ENV);
        let value = std::env::var_os(&name)?;
        // SAFETY: called while the process has a single thread (see above), so nothing reads
        // the environment concurrently.
        unsafe { std::env::remove_var(&name) };
        close_inherited_on_exec();
        let fd: RawFd = value.to_str()?.parse().ok().filter(|&fd| fd > 2)?;
        // SAFETY: only reads the flags of a descriptor number.
        if rustix::io::fcntl_getfd(unsafe { BorrowedFd::borrow_raw(fd) }).is_err() {
            tracing::warn!("the hand-off descriptor is not open");
            return None;
        }
        // SAFETY: the descriptor is open and nothing else in this process owns it: it was
        // inherited across `exec` and named only by the variable just removed.
        let mut file = unsafe { File::from_raw_fd(fd) };
        let header = file
            .seek(SeekFrom::Start(0))
            .and_then(|_| read_header(&mut file));
        let (version, listed) = match header {
            Ok(header) => header,
            Err(error) => {
                tracing::error!("the previous build's hand-off is unreadable: {error}");
                return None;
            }
        };
        let mut masters: Vec<(OwnedFd, u32)> = Vec::with_capacity(listed.len());
        for (master, pid) in listed {
            let open = master > 2
                && master != fd
                && !masters.iter().any(|(owned, _)| owned.as_raw_fd() == master)
                // SAFETY: only reads the flags of a descriptor number.
                && rustix::io::fcntl_getfd(unsafe { BorrowedFd::borrow_raw(master) })
                    .is_ok();
            if open {
                // SAFETY: open, inherited, listed once, and owned by nothing else here.
                masters.push((unsafe { OwnedFd::from_raw_fd(master) }, pid));
            }
        }
        Some(Self {
            file,
            version,
            masters,
        })
    }

    /// How many panes were handed over.
    pub fn panes(&self) -> usize {
        self.masters.len()
    }

    /// Reads the payload. Panes it cannot read are ended ([`pty::abandon`]); everything is
    /// ended, and nothing carried, when the version is not one this build reads.
    pub(crate) fn read(mut self) -> Adopted {
        if !HANDOFF_READS.contains(&self.version) {
            tracing::warn!(
                version = self.version,
                "the previous build handed off in a format this build does not read; its panes end"
            );
            abandon_all(self.masters);
            return Adopted::default();
        }
        match read_payload(&mut self.file, &mut self.masters) {
            Ok(carried) => {
                abandon_all(std::mem::take(&mut self.masters));
                carried
            }
            Err(error) => {
                tracing::error!("reading the hand-off: {error}; its panes end");
                abandon_all(self.masters);
                Adopted::default()
            }
        }
    }
}

fn abandon_all(masters: Vec<(OwnedFd, u32)>) {
    for (master, pid) in masters {
        pty::abandon(master, pid, ABANDON_GRACE);
    }
}

/// What a new build continues: the carried state, with each pane's master.
#[derive(Debug, Default)]
pub(crate) struct Adopted {
    pub carried: Carried,
    pub masters: HashMap<PaneId, OwnedFd>,
}

impl Adopted {
    /// Takes the pane `id` with its master, if it was carried.
    pub fn take(&mut self, id: PaneId) -> Option<(CarriedPane, OwnedFd)> {
        let master = self.masters.remove(&id)?;
        let index = self.carried.panes.iter().position(|pane| pane.id == id)?;
        Some((self.carried.panes.swap_remove(index), master))
    }

    /// Ends the panes nothing took.
    pub fn abandon_rest(&mut self) {
        for pane in std::mem::take(&mut self.carried.panes) {
            if let Some(master) = self.masters.remove(&pane.id) {
                tracing::info!(pane = %pane.id, "a carried pane is not in the layout; it ends");
                pty::abandon(master, pane.state.pty.pid, ABANDON_GRACE);
            }
        }
        self.masters.clear();
    }
}

fn read_payload(file: &mut File, masters: &mut Vec<(OwnedFd, u32)>) -> io::Result<Adopted> {
    let meta = read_section(file)?;
    let blobs = read_section(file)?;
    let payload: Payload =
        serde_json::from_slice(&meta).map_err(|error| invalid(&error.to_string()))?;
    let mut adopted = Adopted {
        carried: Carried {
            epoch: (payload.epoch != 0).then_some(SessionEpoch(payload.epoch)),
            inputs: payload
                .inputs
                .iter()
                .filter_map(|input| {
                    let device = crate::fsutil::unhex::<32>(&input.device)?;
                    Some((DeviceId(device), input.stream, input.applied))
                })
                .collect(),
            panes: Vec::new(),
        },
        masters: HashMap::new(),
    };
    for record in payload.panes {
        let id = PaneId(record.pane_id);
        let Some(index) = masters
            .iter()
            .position(|(master, pid)| master.as_raw_fd() == record.fd && *pid == record.pid)
        else {
            continue;
        };
        if adopted.masters.contains_key(&id) {
            continue;
        }
        let pane = match carried_pane(&record, &blobs) {
            Ok(pane) => pane,
            Err(error) => {
                tracing::warn!(pane = %id, "a carried pane is unreadable: {error}; it ends");
                continue;
            }
        };
        let (master, _) = masters.swap_remove(index);
        adopted.masters.insert(id, master);
        adopted.carried.panes.push(pane);
    }
    Ok(adopted)
}

fn carried_pane(record: &PaneRecord, blobs: &[u8]) -> io::Result<CarriedPane> {
    let ring_capacity = usize::try_from(record.ring_capacity)
        .ok()
        .filter(|&capacity| capacity > 0 && capacity as u64 <= MAX_BLOB)
        .ok_or_else(|| invalid("ring capacity"))?;
    Ok(CarriedPane {
        id: PaneId(record.pane_id),
        state: PaneHandOff {
            pty: pty::HandedOff {
                master: record.fd,
                pid: record.pid,
                ring_capacity,
                head: pty::Seq::new(record.head),
                retained: Bytes::from(unblob(blobs, record.retained)?),
                unsent_input: unblob(blobs, record.unsent_input)?,
                exit_status: record.exit_status,
            },
            snapshot: record
                .snapshot
                .map(|blob| unblob(blobs, blob))
                .transpose()?,
            snap_gen: SnapGen(record.snap_gen),
            size: record.size,
            resize_count: record.resize_count,
            resizes: record
                .resizes
                .iter()
                .map(|&(index, at, size)| ResizeRecord {
                    index,
                    at: Seq(at),
                    size,
                })
                .collect(),
            last_command_id: record.last_command_id,
        },
        title: record.title.clone(),
        cwd: record.cwd.clone(),
        at_prompt: record.at_prompt,
        launched_at: UNIX_EPOCH + Duration::from_millis(record.launched_at_ms),
        agent: record.agent,
    })
}

/// Writes the hand-off to `file` and rewinds it for the reader.
pub(crate) fn write_file(file: &mut File, bytes: &[u8]) -> io::Result<()> {
    file.write_all(bytes)?;
    file.seek(SeekFrom::Start(0))?;
    Ok(())
}

/// Marks every descriptor above stderr close-on-exec: whatever the previous build passed on
/// (or leaked) never reaches a program this one starts.
fn close_inherited_on_exec() {
    let Ok(entries) = std::fs::read_dir("/dev/fd") else {
        return;
    };
    let fds: Vec<RawFd> = entries
        .filter_map(|entry| entry.ok()?.file_name().to_str()?.parse().ok())
        .filter(|&fd: &RawFd| fd > 2)
        .collect();
    for fd in fds {
        // SAFETY: only changes the flags of a descriptor number; one that is no longer open
        // (the directory's own) fails harmlessly.
        let borrowed = unsafe { BorrowedFd::borrow_raw(fd) };
        if let Ok(flags) = rustix::io::fcntl_getfd(borrowed) {
            let _ = rustix::io::fcntl_setfd(borrowed, flags | rustix::io::FdFlags::CLOEXEC);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Carried {
        Carried {
            epoch: Some(SessionEpoch(42)),
            inputs: vec![(DeviceId([7; 32]), 3, 99)],
            panes: vec![CarriedPane {
                id: PaneId(5),
                state: PaneHandOff {
                    pty: pty::HandedOff {
                        master: 17,
                        pid: 4242,
                        ring_capacity: 16,
                        head: pty::Seq::new(20),
                        retained: Bytes::from_static(b"0123456789abcdef"),
                        unsent_input: b"ls\r".to_vec(),
                        exit_status: None,
                    },
                    snapshot: Some(vec![9; 1000]),
                    snap_gen: SnapGen(11),
                    size: PaneSize {
                        cols: 80,
                        rows: 24,
                        width_px: 800,
                        height_px: 480,
                    },
                    resize_count: 1,
                    resizes: vec![ResizeRecord {
                        index: 0,
                        at: Seq(4),
                        size: PaneSize {
                            cols: 80,
                            rows: 24,
                            width_px: 800,
                            height_px: 480,
                        },
                    }],
                    last_command_id: 8,
                },
                title: "vim".into(),
                cwd: Some("/tmp".into()),
                at_prompt: true,
                launched_at: UNIX_EPOCH + Duration::from_millis(1_700_000_000_000),
                agent: Some(AgentKind::Claude),
            }],
        }
    }

    #[test]
    fn the_header_lists_masters_and_pids_whatever_the_payload() {
        let bytes = encode(&sample()).unwrap();
        let (version, panes) = read_header(&mut bytes.as_slice()).unwrap();
        assert_eq!(version, HANDOFF_VERSION);
        assert_eq!(panes, [(17, 4242)]);
        let mut damaged = bytes.clone();
        damaged[0] ^= 1;
        assert!(read_header(&mut damaged.as_slice()).is_err());
    }

    #[test]
    fn the_payload_round_trips() {
        let carried = sample();
        let bytes = encode(&carried).unwrap();
        let mut reader = bytes.as_slice();
        read_header(&mut reader).unwrap();
        let meta = read_section(&mut reader).unwrap();
        let blobs = read_section(&mut reader).unwrap();
        let payload: Payload = serde_json::from_slice(&meta).unwrap();
        assert_eq!(payload.epoch, 42);
        let pane = carried_pane(&payload.panes[0], &blobs).unwrap();
        assert_eq!(pane.state, carried.panes[0].state);
        assert_eq!(pane.title, "vim");
        assert_eq!(pane.launched_at, carried.panes[0].launched_at);
        assert_eq!(pane.agent, Some(AgentKind::Claude));
    }

    #[test]
    fn damaged_blobs_are_refused() {
        let blobs = zstd::bulk::compress(b"hello", 1).unwrap();
        let blob = Blob {
            offset: 0,
            len: blobs.len() as u64,
            raw_len: 5,
        };
        assert_eq!(unblob(&blobs, blob).unwrap(), b"hello");
        assert!(unblob(&blobs, Blob { len: 999, ..blob }).is_err());
        assert!(unblob(&blobs, Blob { raw_len: 4, ..blob }).is_err());
        assert!(
            unblob(
                &blobs,
                Blob {
                    offset: u64::MAX,
                    ..blob
                }
            )
            .is_err()
        );
    }

    #[test]
    fn the_file_is_private_and_nameless() {
        let dir = tempfile::tempdir().unwrap();
        let mut file = create_file(dir.path()).unwrap();
        write_file(&mut file, b"state").unwrap();
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
        let flags = rustix::io::fcntl_getfd(&file).unwrap();
        assert!(flags.contains(rustix::io::FdFlags::CLOEXEC));
        let mut back = String::new();
        file.read_to_string(&mut back).unwrap();
        assert_eq!(back, "state");
    }
}
