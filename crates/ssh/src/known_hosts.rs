//! Host key trust: an OpenSSH-format known_hosts store with trust-on-first-use and pinning.
//!
//! Lines are `[marker] hosts keytype base64 [comment]`, where `hosts` is a comma list of
//! patterns (`*`, `?`, `!negation`, `[host]:port`) or a hashed `|1|salt|hmac-sha1` entry.
//! `@revoked` keys are always refused; `@cert-authority` lines are kept but not used (no
//! host certificates yet).
//!
//! A host with recorded keys must present one of them; anything else is a
//! [`SshError::HostKeyMismatch`] carrying both fingerprints. Connections prefer the key
//! types already on record for the host, so a server with several host keys does not trip
//! this by offering a different type first.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};

use data_encoding::BASE64;
use russh::keys::{Algorithm, HashAlg, PublicKey};

use crate::target::{DEFAULT_PORT, HostSpec};
use crate::{SshError, wildcard};

/// A host key as shown to the user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostKeyInfo {
    /// The name the key is stored under: `host`, or `[host]:port` for other ports.
    pub host: String,
    /// Key type, e.g. `ssh-ed25519`.
    pub algorithm: String,
    /// `SHA256:…` fingerprint, as OpenSSH prints it.
    pub fingerprint: String,
    /// The public key in OpenSSH format (`ssh-ed25519 AAAA…`), for pinning.
    pub public_key: String,
}

impl HostKeyInfo {
    pub(crate) fn new(host: String, key: &PublicKey) -> Self {
        Self {
            host,
            algorithm: key.algorithm().as_str().to_owned(),
            fingerprint: fingerprint(key),
            public_key: openssh_line(key),
        }
    }
}

/// Asks the user whether to trust a host seen for the first time.
///
/// Called on a blocking thread, after the key exchange and before any credential is sent,
pub trait HostKeyPrompt: Send + Sync {
    /// `true` trusts and records the key.
    fn trust_new_host(&self, key: HostKeyInfo) -> bool;

    /// The host presented `key`, but other keys are on record for it (`expected`, their
    /// `SHA256:` fingerprints): the server was reinstalled, or someone is in the middle.
    /// `true` replaces the recorded keys with `key` ([`KnownHosts::replace`]) and continues.
    ///
    /// Called like [`trust_new_host`](Self::trust_new_host), only under
    /// [`HostKeyPolicy::Ask`] and never for pinned keys. The default refuses, which fails
    /// the connection with [`SshError::HostKeyMismatch`] (OpenSSH's behaviour).
    fn trust_changed_host(&self, key: HostKeyInfo, expected: Vec<String>) -> bool {
        let _ = (key, expected);
        false
    }
}

/// Told about every change to a [`KnownHosts`] store, so a store the app keeps (in the
/// Keychain, say) can be saved. Runs on the thread that changed it; return quickly.
pub trait KnownHostsListener: Send + Sync {
    /// The store changed; `text` is its new [`to_text`](KnownHosts::to_text).
    fn changed(&self, text: String);
}

/// What to do with a host that has no recorded key.
#[derive(Clone)]
pub enum HostKeyPolicy {
    /// Refuse it (`StrictHostKeyChecking yes`).
    Strict,
    /// Record it and continue (`StrictHostKeyChecking accept-new`).
    AcceptNew,
    /// Ask (trust on first use).
    Ask(Arc<dyn HostKeyPrompt>),
}

impl std::fmt::Debug for HostKeyPolicy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Strict => "Strict",
            Self::AcceptNew => "AcceptNew",
            Self::Ask(_) => "Ask",
        })
    }
}

/// The result of looking a presented key up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostKeyStatus {
    /// The key is on record for this host.
    Trusted,
    /// No key is on record for this host.
    Unknown,
    /// Other keys are on record; these are their fingerprints.
    Mismatch(Vec<String>),
    /// The key is marked `@revoked`.
    Revoked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Marker {
    None,
    Revoked,
    CertAuthority,
}

#[derive(Debug, Clone)]
enum Hosts {
    Patterns(Vec<(bool, String)>),
    Hashed { salt: Vec<u8>, hash: Vec<u8> },
}

#[derive(Debug, Clone)]
struct Entry {
    marker: Marker,
    hosts: Hosts,
    key: PublicKey,
    pinned: bool,
    line: String,
}

/// A key the user has to decide on, found by [`KnownHosts::verify`].
#[derive(Debug, Clone)]
pub(crate) struct Undecided {
    pub info: HostKeyInfo,
    /// Fingerprints on record when the host's key changed; `None` for a new host.
    pub expected: Option<Vec<String>>,
}

/// A known_hosts store, optionally backed by a file that new keys are appended to.
#[derive(Default)]
pub struct KnownHosts {
    entries: Mutex<Vec<Entry>>,
    path: Option<PathBuf>,
    listener: Option<Arc<dyn KnownHostsListener>>,
}

impl std::fmt::Debug for KnownHosts {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KnownHosts")
            .field("entries", &self.lock().len())
            .field("path", &self.path)
            .finish_non_exhaustive()
    }
}

impl KnownHosts {
    /// An empty store kept in memory (the app persists it via [`to_text`](Self::to_text)).
    pub fn in_memory() -> Self {
        Self::default()
    }

    /// Parses known_hosts text. Unparsable lines are skipped.
    pub fn from_text(text: &str) -> Self {
        Self {
            entries: Mutex::new(text.lines().filter_map(parse_line).collect()),
            ..Self::default()
        }
    }

    /// Reports every later change to `listener`.
    #[must_use]
    pub fn with_listener(mut self, listener: Arc<dyn KnownHostsListener>) -> Self {
        self.listener = Some(listener);
        self
    }

    /// Opens a known_hosts file (created on the first new key).
    ///
    /// # Errors
    ///
    /// Returns [`SshError::Io`] if the file exists but cannot be read.
    pub fn open(path: impl Into<PathBuf>) -> Result<Self, SshError> {
        let path = path.into();
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(e) => return Err(SshError::io(format!("reading {}", path.display()), e)),
        };
        let mut store = Self::from_text(&text);
        store.path = Some(path);
        Ok(store)
    }

    /// The store as known_hosts text (pins included as ordinary lines).
    pub fn to_text(&self) -> String {
        let entries = self.lock();
        let mut out = String::new();
        for e in entries.iter() {
            out.push_str(&e.line);
            out.push('\n');
        }
        out
    }

    /// Looks a presented key up for `host:port`.
    pub fn check(&self, host: &str, port: u16, key: &PublicKey) -> HostKeyStatus {
        let name = host_name(host, port);
        let entries = self.lock();
        let matching: Vec<&Entry> = entries
            .iter()
            .filter(|e| e.marker != Marker::CertAuthority && e.hosts.matches(&name))
            .collect();
        if matching
            .iter()
            .any(|e| e.marker == Marker::Revoked && e.key.key_data() == key.key_data())
        {
            return HostKeyStatus::Revoked;
        }
        let pinned = matching.iter().any(|e| e.pinned);
        let candidates: Vec<&&Entry> = matching
            .iter()
            .filter(|e| e.marker == Marker::None && (e.pinned || !pinned))
            .collect();
        if candidates.is_empty() {
            HostKeyStatus::Unknown
        } else if candidates
            .iter()
            .any(|e| e.key.key_data() == key.key_data())
        {
            HostKeyStatus::Trusted
        } else {
            HostKeyStatus::Mismatch(candidates.iter().map(|e| fingerprint(&e.key)).collect())
        }
    }

    /// Key types on record for `host:port`, for ordering the host-key negotiation.
    pub fn algorithms_for(&self, host: &str, port: u16) -> Vec<Algorithm> {
        let name = host_name(host, port);
        let mut out = Vec::new();
        for e in self.lock().iter() {
            if e.marker == Marker::None
                && e.hosts.matches(&name)
                && !out.contains(&e.key.algorithm())
            {
                out.push(e.key.algorithm());
            }
        }
        out
    }

    /// Records `key` for `host:port` (appending to the backing file, if any).
    ///
    /// # Errors
    ///
    /// Returns [`SshError::Io`] if the backing file cannot be written.
    pub fn add(&self, host: &str, port: u16, key: &PublicKey) -> Result<(), SshError> {
        self.insert(host, port, key, false)
    }

    /// Pins `public_key` (OpenSSH format) for `host:port`: from now on only pinned keys are
    /// accepted for it, whatever else is on record (e.g. a key attested by the paired
    ///
    /// # Errors
    ///
    /// Returns [`SshError::Key`] for an unparsable key and [`SshError::Io`] if the backing
    /// file cannot be written.
    pub fn pin(&self, host: &str, port: u16, public_key: &str) -> Result<(), SshError> {
        let key =
            PublicKey::from_openssh(public_key.trim()).map_err(|e| SshError::Key(e.to_string()))?;
        self.insert(host, port, &key, true)
    }

    /// Forgets the keys recorded for exactly `host:port`: plain entries naming only it, and
    /// hashed entries for it. Entries that also cover other hosts (`a,b`, wildcards) and
    /// `@revoked` lines stay. Returns how many entries were removed.
    ///
    /// # Errors
    ///
    /// Returns [`SshError::Io`] if the backing file cannot be rewritten.
    pub fn remove(&self, host: &str, port: u16) -> Result<usize, SshError> {
        let name = host_name(host, port).to_ascii_lowercase();
        let removed = {
            let mut entries = self.lock();
            let before = entries.len();
            entries.retain(|e| !(e.marker == Marker::None && e.hosts.is_exactly(&name)));
            before - entries.len()
        };
        if removed > 0 {
            if let Some(path) = &self.path {
                write_file(path, &self.to_text())?;
            }
            self.notify();
        }
        Ok(removed)
    }

    /// Records `key` as the only key for exactly `host:port` ([`remove`](Self::remove), then
    /// [`add`](Self::add)): what accepting a changed host key does.
    ///
    /// # Errors
    ///
    /// Returns [`SshError::Io`] if the backing file cannot be written.
    pub fn replace(&self, host: &str, port: u16, key: &PublicKey) -> Result<(), SshError> {
        self.remove(host, port)?;
        self.add(host, port, key)
    }

    fn insert(&self, host: &str, port: u16, key: &PublicKey, pinned: bool) -> Result<(), SshError> {
        let name = host_name(host, port);
        let line = format!("{name} {}", openssh_line(key));
        if let Some(path) = &self.path {
            append_line(path, &line)?;
        }
        self.lock().push(Entry {
            marker: Marker::None,
            hosts: Hosts::Patterns(vec![(false, name.to_ascii_lowercase())]),
            key: key.clone(),
            pinned,
            line,
        });
        self.notify();
        Ok(())
    }

    fn notify(&self) {
        if let Some(listener) = &self.listener {
            listener.changed(self.to_text());
        }
    }

    /// Decides whether `key`, presented by `spec`'s host, may be used.
    ///
    /// Returns `Ok(None)` when the key is trusted, `Ok(Some(_))` when it is new (or changed,
    /// and not pinned) and `policy` asks the user (the caller prompts after the key
    /// exchange), and an error for mismatched, revoked or refused keys.
    pub(crate) fn verify(
        &self,
        spec: &HostSpec,
        key: &PublicKey,
        policy: &HostKeyPolicy,
    ) -> Result<Option<Undecided>, SshError> {
        let host = spec.key_host();
        let info = || HostKeyInfo::new(host_name(host, spec.port), key);
        match self.check(host, spec.port, key) {
            HostKeyStatus::Trusted => Ok(None),
            HostKeyStatus::Revoked => Err(SshError::HostKeyRejected {
                host: host_name(host, spec.port),
                fingerprint: format!("{} (revoked)", fingerprint(key)),
            }),
            HostKeyStatus::Mismatch(expected)
                if matches!(policy, HostKeyPolicy::Ask(_)) && !self.is_pinned(host, spec.port) =>
            {
                Ok(Some(Undecided {
                    info: info(),
                    expected: Some(expected),
                }))
            }
            HostKeyStatus::Mismatch(expected) => Err(SshError::HostKeyMismatch {
                host: host_name(host, spec.port),
                expected,
                actual: fingerprint(key),
            }),
            HostKeyStatus::Unknown => match policy {
                HostKeyPolicy::Strict => Err(SshError::HostKeyRejected {
                    host: host_name(host, spec.port),
                    fingerprint: fingerprint(key),
                }),
                HostKeyPolicy::AcceptNew => {
                    self.add(host, spec.port, key)?;
                    Ok(None)
                }
                HostKeyPolicy::Ask(_) => Ok(Some(Undecided {
                    info: info(),
                    expected: None,
                })),
            },
        }
    }

    fn is_pinned(&self, host: &str, port: u16) -> bool {
        let name = host_name(host, port);
        self.lock()
            .iter()
            .any(|e| e.pinned && e.hosts.matches(&name))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Entry>> {
        self.entries.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Hosts {
    /// Whether the entry names `name` (lowercase) and nothing else.
    fn is_exactly(&self, name: &str) -> bool {
        match self {
            Self::Patterns(patterns) => {
                matches!(patterns.as_slice(), [(false, glob)] if glob.eq_ignore_ascii_case(name))
            }
            Self::Hashed { .. } => self.matches(name),
        }
    }

    fn matches(&self, name: &str) -> bool {
        let name = name.to_ascii_lowercase();
        match self {
            Self::Patterns(patterns) => {
                let mut hit = false;
                for (negated, glob) in patterns {
                    if wildcard::matches(glob, &name) {
                        if *negated {
                            return false;
                        }
                        hit = true;
                    }
                }
                hit
            }
            Self::Hashed { salt, hash } => {
                let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA1_FOR_LEGACY_USE_ONLY, salt);
                ring::hmac::verify(&key, name.as_bytes(), hash).is_ok()
            }
        }
    }
}

/// `host` for port 22, else `[host]:port` (the known_hosts convention).
pub fn host_name(host: &str, port: u16) -> String {
    if port == DEFAULT_PORT {
        host.to_owned()
    } else {
        format!("[{host}]:{port}")
    }
}

/// `SHA256:…` fingerprint of a key.
pub fn fingerprint(key: &PublicKey) -> String {
    key.fingerprint(HashAlg::Sha256).to_string()
}

fn openssh_line(key: &PublicKey) -> String {
    let mut key = key.clone();
    key.set_comment("");
    key.to_openssh().unwrap_or_default().trim().to_owned()
}

fn parse_line(line: &str) -> Option<Entry> {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return None;
    }
    let mut fields = trimmed.split_whitespace();
    let mut first = fields.next()?;
    let marker = match first {
        "@revoked" => Marker::Revoked,
        "@cert-authority" => Marker::CertAuthority,
        _ => Marker::None,
    };
    if marker != Marker::None {
        first = fields.next()?;
    }
    let hosts = if let Some(hashed) = first.strip_prefix("|1|") {
        let (salt, hash) = hashed.split_once('|')?;
        Hosts::Hashed {
            salt: BASE64.decode(salt.as_bytes()).ok()?,
            hash: BASE64.decode(hash.as_bytes()).ok()?,
        }
    } else {
        Hosts::Patterns(
            first
                .split(',')
                .map(|p| match p.strip_prefix('!') {
                    Some(rest) => (true, rest.to_ascii_lowercase()),
                    None => (false, p.to_ascii_lowercase()),
                })
                .collect(),
        )
    };
    let algorithm = fields.next()?;
    let data = fields.next()?;
    let key = PublicKey::from_openssh(&format!("{algorithm} {data}")).ok()?;
    Some(Entry {
        marker,
        hosts,
        key,
        pinned: false,
        line: trimmed.to_owned(),
    })
}

fn append_line(path: &Path, line: &str) -> Result<(), SshError> {
    let io = |e| SshError::io(format!("writing {}", path.display()), e);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(io)?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(io)?;
    // Make sure the new entry starts on its own line even if the file lacks a final newline.
    let needs_newline = std::fs::read(path)
        .map(|b| !b.is_empty() && !b.ends_with(b"\n"))
        .unwrap_or(false);
    let text = if needs_newline {
        format!("\n{line}\n")
    } else {
        format!("{line}\n")
    };
    file.write_all(text.as_bytes()).map_err(io)
}

fn write_file(path: &Path, text: &str) -> Result<(), SshError> {
    std::fs::write(path, text).map_err(|e| SshError::io(format!("writing {}", path.display()), e))
}

#[cfg(test)]
mod tests {
    use super::*;

    const ED: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE4B95dlDBizaGBx6p/SVce0fjr63zymF4ua6EuyZ3xN";
    const ED2: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF8HzTSXIUO0BZvZLYx1vfJjgLkq11APg9aeoAsjEkWP";

    fn key(s: &str) -> PublicKey {
        PublicKey::from_openssh(s).unwrap()
    }

    fn hashed(name: &str, salt: &[u8]) -> String {
        let k = ring::hmac::Key::new(ring::hmac::HMAC_SHA1_FOR_LEGACY_USE_ONLY, salt);
        let tag = ring::hmac::sign(&k, name.as_bytes());
        format!("|1|{}|{}", BASE64.encode(salt), BASE64.encode(tag.as_ref()))
    }

    #[test]
    fn plain_patterns_and_ports() {
        let kh = KnownHosts::from_text(&format!(
            "# comment\nbox,10.0.0.5 {ED}\n[box]:2222 {ED2}\n*.corp,!evil.corp {ED}\n"
        ));
        assert_eq!(kh.check("box", 22, &key(ED)), HostKeyStatus::Trusted);
        assert_eq!(kh.check("BOX", 22, &key(ED)), HostKeyStatus::Trusted);
        assert_eq!(kh.check("10.0.0.5", 22, &key(ED)), HostKeyStatus::Trusted);
        assert_eq!(kh.check("box", 2222, &key(ED2)), HostKeyStatus::Trusted);
        assert_eq!(kh.check("db.corp", 22, &key(ED)), HostKeyStatus::Trusted);
        assert_eq!(kh.check("evil.corp", 22, &key(ED)), HostKeyStatus::Unknown);
        assert_eq!(kh.check("other", 22, &key(ED)), HostKeyStatus::Unknown);
        assert_eq!(kh.algorithms_for("box", 22), [Algorithm::Ed25519]);
    }

    #[test]
    fn mismatch_reports_both_fingerprints() {
        let kh = KnownHosts::from_text(&format!("box {ED}\n"));
        let spec = HostSpec::new("box", "me");
        assert_eq!(
            kh.check("box", 22, &key(ED2)),
            HostKeyStatus::Mismatch(vec![fingerprint(&key(ED))])
        );
        match kh.verify(&spec, &key(ED2), &HostKeyPolicy::AcceptNew) {
            Err(SshError::HostKeyMismatch {
                host,
                expected,
                actual,
            }) => {
                assert_eq!(host, "box");
                assert_eq!(expected, [fingerprint(&key(ED))]);
                assert_eq!(actual, fingerprint(&key(ED2)));
                assert!(actual.starts_with("SHA256:"));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn hashed_entries() {
        let kh = KnownHosts::from_text(&format!(
            "{} {ED}\n{} {ED2}\n",
            hashed("box", b"0123456789abcdef0123"),
            hashed("[box]:2200", b"another salt 12345678"),
        ));
        assert_eq!(kh.check("box", 22, &key(ED)), HostKeyStatus::Trusted);
        assert_eq!(kh.check("box", 2200, &key(ED2)), HostKeyStatus::Trusted);
        assert_eq!(kh.check("box", 2201, &key(ED2)), HostKeyStatus::Unknown);
    }

    #[test]
    fn revoked_wins() {
        let kh = KnownHosts::from_text(&format!("box {ED}\n@revoked * {ED}\n"));
        assert_eq!(kh.check("box", 22, &key(ED)), HostKeyStatus::Revoked);
    }

    #[test]
    fn tofu_policies() {
        let spec = HostSpec::new("new", "me");
        let kh = KnownHosts::in_memory();
        assert!(matches!(
            kh.verify(&spec, &key(ED), &HostKeyPolicy::Strict),
            Err(SshError::HostKeyRejected { .. })
        ));
        struct Yes;
        impl HostKeyPrompt for Yes {
            fn trust_new_host(&self, _: HostKeyInfo) -> bool {
                true
            }
        }
        let undecided = kh
            .verify(&spec, &key(ED), &HostKeyPolicy::Ask(Arc::new(Yes)))
            .unwrap()
            .unwrap();
        assert_eq!(undecided.expected, None);
        let info = undecided.info;
        assert_eq!(info.host, "new");
        assert_eq!(info.algorithm, "ssh-ed25519");
        assert_eq!(info.public_key, ED);
        assert!(
            kh.verify(&spec, &key(ED), &HostKeyPolicy::AcceptNew)
                .unwrap()
                .is_none()
        );
        assert_eq!(kh.check("new", 22, &key(ED)), HostKeyStatus::Trusted);
    }

    #[test]
    fn pin_overrides_other_entries() {
        let kh = KnownHosts::from_text(&format!("box {ED}\n"));
        kh.pin("box", 22, ED2).unwrap();
        assert_eq!(kh.check("box", 22, &key(ED2)), HostKeyStatus::Trusted);
        assert_eq!(
            kh.check("box", 22, &key(ED)),
            HostKeyStatus::Mismatch(vec![fingerprint(&key(ED2))])
        );
    }

    #[test]
    fn changed_keys_are_asked_about_unless_pinned() {
        struct Yes;
        impl HostKeyPrompt for Yes {
            fn trust_new_host(&self, _: HostKeyInfo) -> bool {
                true
            }
        }
        let ask = HostKeyPolicy::Ask(Arc::new(Yes));
        let spec = HostSpec::new("box", "me");
        let kh = KnownHosts::from_text(&format!("box {ED}\n"));
        let undecided = kh.verify(&spec, &key(ED2), &ask).unwrap().unwrap();
        assert_eq!(undecided.expected, Some(vec![fingerprint(&key(ED))]));
        kh.pin("box", 22, ED).unwrap();
        assert!(matches!(
            kh.verify(&spec, &key(ED2), &ask),
            Err(SshError::HostKeyMismatch { .. })
        ));
    }

    #[test]
    fn replace_and_remove_touch_only_that_host() {
        struct Saved(Mutex<Vec<String>>);
        impl KnownHostsListener for Saved {
            fn changed(&self, text: String) {
                self.0.lock().unwrap().push(text);
            }
        }
        let saved = Arc::new(Saved(Mutex::new(Vec::new())));
        let kh = KnownHosts::from_text(&format!(
            "box {ED}\n{} {ED}\nbox,other {ED}\n[box]:2222 {ED}\n",
            hashed("box", b"0123456789abcdef0123")
        ))
        .with_listener(saved.clone());
        kh.replace("box", 22, &key(ED2)).unwrap();
        assert_eq!(kh.check("box", 22, &key(ED2)), HostKeyStatus::Trusted);
        assert_eq!(
            kh.to_text(),
            format!("box,other {ED}\n[box]:2222 {ED}\nbox {ED2}\n")
        );
        assert_eq!(saved.0.lock().unwrap().last(), Some(&kh.to_text()));
        assert_eq!(kh.remove("box", 2222).unwrap(), 1);
        assert_eq!(kh.check("box", 2222, &key(ED)), HostKeyStatus::Unknown);
        assert_eq!(saved.0.lock().unwrap().len(), 3);
    }

    #[test]
    fn file_backed_store_appends() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub/known_hosts");
        let kh = KnownHosts::open(&path).unwrap();
        kh.add("box", 2222, &key(ED)).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert_eq!(text, format!("[box]:2222 {ED}\n"));
        let again = KnownHosts::open(&path).unwrap();
        assert_eq!(again.check("box", 2222, &key(ED)), HostKeyStatus::Trusted);
        assert_eq!(again.to_text(), text);
    }
}
