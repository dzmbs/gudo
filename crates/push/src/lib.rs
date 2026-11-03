//! Push notifications without trusting the push relay (ARCHITECTURE D16, `docs/PUSH.md`).
//!
//! Three formats live here, shared by the daemon (which produces them), client-core (which
//! answers actions) and, through the test vectors in `tests/vectors/`, the Swift
//! `PushCrypto` package in the Notification Service Extension:
//!
//! - **Sealed payloads** ([`seal`], [`open`]): a [`Notification`] (or [`ActivityState`]) as
//!   JSON, signed with the daemon's Ed25519 key, then HPKE-sealed ([`hpke`]) to the device's
//!   X25519 key. The relay and Apple see only ciphertext.
//! - **Relay requests** ([`RelayRequest`], [`sign_request`], [`verify_request`]): what the
//!   daemon POSTs to the relay, signed with the daemon's key. The relay learns the opaque push
//!   capability, a coarse [`Category`] and a collapse id it cannot link to a pane.
//! - **Action tokens** ([`ActionToken`], [`issue_token`], [`verify_token`],
//!   [`sign_decision`]): Approve/Deny from the lock screen. The daemon signs a token naming
//!   the request and the device; the device returns it with its decision, signed with its own
//!   key, over its iroh connection.
//!
//! # Examples
//!
//! ```
//! let daemon_seed = [1; 32];
//! let (device_secret, device_public) = push::x25519_keypair();
//! let note = push::Notification {
//!     v: push::Notification::VERSION,
//!     daemon: push::hex(&push::ed25519_public(&daemon_seed)),
//!     host: "studio".into(),
//!     kind: push::Kind::Done,
//!     item: 1,
//!     pane: 4,
//!     session: None,
//!     title: "Claude Code finished".into(),
//!     place: Some("api".into()),
//!     body: "All tests pass.".into(),
//!     at: 1_700_000_000_000,
//!     action: None,
//! };
//! let sealed = push::seal(&device_public, &daemon_seed, &serde_json::to_vec(&note)?)?;
//! let opened = push::open(&device_secret, &sealed)?;
//! assert_eq!(opened.notification()?, note);
//! # Ok::<(), Box<dyn std::error::Error>>(())
//! ```

pub mod hpke;

use data_encoding::{BASE64URL_NOPAD, HEXLOWER};
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use proto::{DaemonId, DeviceId, OptionId, PaneId, RequestId, UnixMillis};
use serde::{Deserialize, Serialize};

/// HPKE `info` for sealed payloads.
pub const SEAL_INFO: &[u8] = b"push-seal/v1";
/// Domain prefix of the daemon's signature inside a sealed payload.
pub const PAYLOAD_DOMAIN: &[u8] = b"push-payload/v1\0";
/// Domain prefix of the daemon's signature on a relay request.
pub const REQUEST_DOMAIN: &[u8] = b"push-relay/v1\0";
/// Domain prefix of the daemon's signature on an action token.
pub const TOKEN_DOMAIN: &[u8] = b"push-action-token/v1\0";
/// Domain prefix of the device's signature on a decision.
pub const DECISION_DOMAIN: &[u8] = b"push-action/v1\0";
/// HTTP header carrying [`sign_request`]'s signature.
pub const SIGNATURE_HEADER: &str = "x-push-signature";
/// First byte of a sealed plaintext: the envelope format.
const ENVELOPE_V1: u8 = 1;
const SIG_LEN: usize = 64;

/// APNs allows 4 KiB per payload; the relay adds its own few hundred bytes around `sealed`.
pub const MAX_SEALED_LEN: usize = 3000;

/// Why a push format could not be produced or read.
#[derive(Debug, thiserror::Error)]
pub enum PushError {
    /// Not base64url, too short, or an unknown envelope version.
    #[error("malformed push data")]
    Malformed,
    /// HPKE failed: wrong key, or the data was changed.
    #[error(transparent)]
    Open(#[from] hpke::OpenError),
    /// A signature did not verify, or a key is not a valid public key.
    #[error("bad signature")]
    Signature,
    /// The payload is not the expected JSON.
    #[error("payload: {0}")]
    Json(#[from] serde_json::Error),
    /// The sealed payload would exceed [`MAX_SEALED_LEN`].
    #[error("payload too large ({0} bytes sealed)")]
    TooLarge(usize),
    /// The token has expired.
    #[error("expired")]
    Expired,
}

/// Lowercase hex.
pub fn hex(bytes: &[u8]) -> String {
    HEXLOWER.encode(bytes)
}

/// Unpadded base64url (RFC 4648 §5), the text form of every binary field.
pub fn b64(bytes: &[u8]) -> String {
    BASE64URL_NOPAD.encode(bytes)
}

/// Decodes [`b64`].
///
/// # Errors
///
/// [`PushError::Malformed`] if `text` is not unpadded base64url.
pub fn unb64(text: &str) -> Result<Vec<u8>, PushError> {
    BASE64URL_NOPAD
        .decode(text.as_bytes())
        .map_err(|_| PushError::Malformed)
}

/// A fresh X25519 key pair `(secret, public)` for a device's sealing key.
pub fn x25519_keypair() -> ([u8; 32], [u8; 32]) {
    let mut secret = [0; 32];
    getrandom::fill(&mut secret).expect("the OS random source is available");
    (secret, hpke::public_key(&secret))
}

/// The Ed25519 public key of a 32-byte seed (an iroh secret key's bytes).
pub fn ed25519_public(seed: &[u8; 32]) -> [u8; 32] {
    SigningKey::from_bytes(seed).verifying_key().to_bytes()
}

/// Signs `domain || msg` with an Ed25519 seed.
pub fn ed25519_sign(seed: &[u8; 32], domain: &[u8], msg: &[u8]) -> [u8; SIG_LEN] {
    SigningKey::from_bytes(seed)
        .sign(&[domain, msg].concat())
        .to_bytes()
}

/// Verifies an Ed25519 signature over `domain || msg`.
///
/// # Errors
///
/// [`PushError::Signature`] if the key is invalid or the signature does not verify.
pub fn ed25519_verify(
    public: &[u8; 32],
    domain: &[u8],
    msg: &[u8],
    sig: &[u8],
) -> Result<(), PushError> {
    let key = VerifyingKey::from_bytes(public).map_err(|_| PushError::Signature)?;
    let sig: [u8; SIG_LEN] = sig.try_into().map_err(|_| PushError::Signature)?;
    key.verify_strict(
        &[domain, msg].concat(),
        &ed25519_dalek::Signature::from_bytes(&sig),
    )
    .map_err(|_| PushError::Signature)
}

/// What a notification is about. The NSE picks the notification category from this (not from
/// the relay's [`Category`], which it cannot trust).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// An agent asks to approve a tool call: Approve / Deny / Open.
    Approval,
    /// An agent waits for an answer that needs the terminal: Open.
    Blocked,
    /// An agent finished its turn.
    Done,
    /// An agent's turn failed.
    Failed,
    /// A long command finished while nobody watched.
    Command,
}

impl Kind {
    /// The coarse category the relay is told.
    pub fn category(self) -> Category {
        match self {
            Self::Approval => Category::Approval,
            Self::Blocked => Category::Blocked,
            Self::Done | Self::Failed => Category::Done,
            Self::Command => Category::Command,
        }
    }
}

/// The only thing about a notification's content the relay learns, so it can set the APNs
/// category (action buttons) and interruption level before the NSE runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Category {
    /// [`Kind::Approval`]: time-sensitive, `AGENT_APPROVAL` (Approve, Deny, Open).
    Approval,
    /// [`Kind::Blocked`]: time-sensitive, `AGENT_BLOCKED` (Open).
    Blocked,
    /// [`Kind::Done`] and [`Kind::Failed`]: `AGENT_DONE` (Open).
    Done,
    /// [`Kind::Command`]: `COMMAND_DONE` (Open).
    Command,
}

impl Category {
    /// The `UNNotificationCategory` identifier the app registers.
    pub fn apns_category(self) -> &'static str {
        match self {
            Self::Approval => "AGENT_APPROVAL",
            Self::Blocked => "AGENT_BLOCKED",
            Self::Done => "AGENT_DONE",
            Self::Command => "COMMAND_DONE",
        }
    }
}

/// Notification action identifiers the app registers on its categories.
pub mod actions {
    /// Approve the agent's request (`.authenticationRequired`).
    pub const APPROVE: &str = "APPROVE";
    /// Deny the agent's request (`.authenticationRequired`, `.destructive`).
    pub const DENY: &str = "DENY";
    /// Open the pane (`.foreground`).
    pub const OPEN: &str = "OPEN";
}

/// A notification, as the device sees it after decrypting.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Notification {
    /// [`Notification::VERSION`].
    pub v: u8,
    /// The daemon's Ed25519 key (its iroh endpoint id), hex. The device checks it is a host it
    /// paired with and verifies the envelope signature against it.
    pub daemon: String,
    /// The host's name, for display.
    pub host: String,
    pub kind: Kind,
    /// The attention item's id (mark it seen with `AttentionSeen`).
    pub item: u64,
    pub pane: u64,
    /// The pane's session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<u64>,
    /// Title ("Claude Code needs you").
    pub title: String,
    /// Where it happened on the host, for display: the pane's tab or project.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub place: Option<String>,
    /// Body (the blocker summary or the agent's last message).
    pub body: String,
    /// When it happened, Unix ms.
    pub at: u64,
    /// Approve / Deny, for [`Kind::Approval`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action: Option<ActionOffer>,
}

impl Notification {
    /// The format version this crate writes.
    pub const VERSION: u8 = 1;
}

/// The decision a notification offers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActionOffer {
    /// An [`ActionToken`] issued by the daemon, base64url. Returned verbatim with the decision.
    pub token: String,
    /// Label of the approving option ("Yes").
    pub approve: String,
    /// Label of the denying option ("No").
    pub deny: String,
    /// The token's expiry, Unix ms.
    pub expires: u64,
}

/// The aggregated agent status a Live Activity shows (one activity for all agents of all
/// hosts; each host updates its own row). Sealed like a [`Notification`] and carried in the
/// activity's `content-state` as `{"s": <sealed>}`; the widget decrypts it while rendering.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActivityState {
    /// [`Notification::VERSION`].
    pub v: u8,
    /// The daemon's key, hex.
    pub daemon: String,
    /// The host's name.
    pub host: String,
    /// Agents working.
    pub running: u32,
    /// Agents waiting for the user.
    pub blocked: u32,
    /// Agents finished since the user last looked.
    pub done: u32,
    /// One line for the most urgent agent ("claude: approve git push?").
    pub headline: String,
    /// When this state was computed, Unix ms (APNs `timestamp` is seconds of this).
    pub at: u64,
}

/// Seals `json` for the device key `recipient`, signed with the daemon seed.
///
/// The result is `base64url(enc || HPKE ciphertext)`, where the plaintext is
/// `0x01 || Ed25519(daemon, PAYLOAD_DOMAIN || json) || json`.
///
/// # Errors
///
/// [`PushError::Open`] for an unusable recipient key, [`PushError::TooLarge`] when the result
/// would not fit an APNs payload.
pub fn seal(
    recipient: &[u8; 32],
    daemon_seed: &[u8; 32],
    json: &[u8],
) -> Result<String, PushError> {
    let mut ephemeral = [0; 32];
    getrandom::fill(&mut ephemeral).expect("the OS random source is available");
    seal_with_ephemeral(recipient, daemon_seed, json, &ephemeral)
}

/// [`seal`] with a chosen ephemeral key: deterministic, for the shared test vectors only.
///
/// # Errors
///
/// As [`seal`].
#[doc(hidden)]
pub fn seal_with_ephemeral(
    recipient: &[u8; 32],
    daemon_seed: &[u8; 32],
    json: &[u8],
    ephemeral: &[u8; 32],
) -> Result<String, PushError> {
    let sig = ed25519_sign(daemon_seed, PAYLOAD_DOMAIN, json);
    let plaintext = [&[ENVELOPE_V1][..], &sig, json].concat();
    let (enc, ciphertext) =
        hpke::seal_with_ephemeral(recipient, ephemeral, SEAL_INFO, b"", &plaintext)?;
    let sealed = b64(&[enc.as_slice(), &ciphertext].concat());
    if sealed.len() > MAX_SEALED_LEN {
        return Err(PushError::TooLarge(sealed.len()));
    }
    Ok(sealed)
}

/// A decrypted payload whose signature is not checked yet.
#[derive(Debug, Clone)]
pub struct Opened {
    pub json: Vec<u8>,
    sig: Vec<u8>,
}

impl Opened {
    /// Checks the signature against `daemon` (an Ed25519 public key).
    ///
    /// # Errors
    ///
    /// [`PushError::Signature`] if it does not verify.
    pub fn verify(&self, daemon: &[u8; 32]) -> Result<(), PushError> {
        ed25519_verify(daemon, PAYLOAD_DOMAIN, &self.json, &self.sig)
    }

    /// Parses a [`Notification`] and checks the signature against the daemon key it names.
    /// The caller must still check that key belongs to a paired host.
    ///
    /// # Errors
    ///
    /// [`PushError::Json`] or [`PushError::Signature`].
    pub fn notification(&self) -> Result<Notification, PushError> {
        let note: Notification = serde_json::from_slice(&self.json)?;
        self.verify(&parse_key(&note.daemon)?)?;
        Ok(note)
    }

    /// Like [`notification`](Self::notification), for an [`ActivityState`].
    ///
    /// # Errors
    ///
    /// [`PushError::Json`] or [`PushError::Signature`].
    pub fn activity(&self) -> Result<ActivityState, PushError> {
        let state: ActivityState = serde_json::from_slice(&self.json)?;
        self.verify(&parse_key(&state.daemon)?)?;
        Ok(state)
    }
}

fn parse_key(text: &str) -> Result<[u8; 32], PushError> {
    HEXLOWER
        .decode(text.as_bytes())
        .ok()
        .and_then(|key| key.try_into().ok())
        .ok_or(PushError::Signature)
}

/// Decrypts a [`seal`]ed payload with the device's X25519 secret.
///
/// # Errors
///
/// [`PushError::Malformed`] or [`PushError::Open`].
pub fn open(device_secret: &[u8; 32], sealed: &str) -> Result<Opened, PushError> {
    let raw = unb64(sealed)?;
    if raw.len() < hpke::KEY_LEN + hpke::TAG_LEN {
        return Err(PushError::Malformed);
    }
    let (enc, ciphertext) = raw.split_at(hpke::KEY_LEN);
    let enc: [u8; 32] = enc.try_into().expect("split at 32");
    let plaintext = hpke::open(device_secret, &enc, SEAL_INFO, b"", ciphertext)?;
    match plaintext.split_first() {
        Some((&ENVELOPE_V1, rest)) if rest.len() >= SIG_LEN => Ok(Opened {
            sig: rest[..SIG_LEN].to_vec(),
            json: rest[SIG_LEN..].to_vec(),
        }),
        _ => Err(PushError::Malformed),
    }
}

/// An opaque APNs collapse id for `(daemon, pane, category)`: a later notification about the
/// same pane replaces the earlier one on the lock screen. Keyed with the daemon's secret so
/// the relay cannot tell which pane it is.
pub fn collapse_id(daemon_seed: &[u8; 32], pane: PaneId, category: Category) -> String {
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, daemon_seed);
    let mut msg = b"push-collapse/v1\0".to_vec();
    msg.extend_from_slice(&pane.0.to_le_bytes());
    msg.extend_from_slice(category.apns_category().as_bytes());
    // 32 hex chars: well under APNs' 64-byte limit.
    hex(&ring::hmac::sign(&key, &msg).as_ref()[..16])
}

/// APNs push type of a relay request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PushType {
    /// A visible alert, `mutable-content: 1`, decrypted by the NSE.
    Alert,
    /// A Live Activity start (push-to-start), update or end.
    LiveActivity,
}

/// Live Activity push events.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivityEvent {
    /// Push-to-start (iOS 17.2+); needs the push-to-start capability and an alert.
    Start,
    /// Update the running activity.
    Update,
    /// End it (`dismissal-date` decides when it leaves the lock screen).
    End,
}

/// What a daemon POSTs to `<relay>/v1/push` (JSON body; the signature is the
/// [`SIGNATURE_HEADER`] header).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelayRequest {
    /// [`RelayRequest::VERSION`].
    pub v: u8,
    /// The daemon's Ed25519 key, hex. Must match the key in `cap`.
    pub daemon: String,
    /// The push capability the device obtained from the relay (opaque to the daemon).
    pub cap: String,
    /// Alert or Live Activity.
    pub push_type: PushType,
    /// For alerts: the APNs category and interruption level.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<Category>,
    /// `apns-collapse-id` ([`collapse_id`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collapse: Option<String>,
    /// The [`seal`]ed payload.
    pub sealed: String,
    /// Unix ms when signed; the relay refuses requests more than five minutes off.
    pub ts: u64,
    /// Random, hex; the relay refuses a nonce it has seen from this daemon.
    pub nonce: String,
    /// For Live Activities: start, update or end.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub event: Option<ActivityEvent>,
    /// For Live Activities: `stale-date`, Unix seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stale: Option<u64>,
    /// For Live Activities: `dismissal-date`, Unix seconds (with [`ActivityEvent::End`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dismiss: Option<u64>,
    /// Live Activities: send with priority 10 (counts against the budget) instead of 5.
    #[serde(default)]
    pub urgent: bool,
}

impl RelayRequest {
    /// The format version this crate writes.
    pub const VERSION: u8 = 1;
}

/// A fresh request nonce.
pub fn nonce() -> String {
    let mut bytes = [0; 16];
    getrandom::fill(&mut bytes).expect("the OS random source is available");
    hex(&bytes)
}

/// The [`SIGNATURE_HEADER`] value for a request body: base64url Ed25519 over
/// `REQUEST_DOMAIN || body`.
pub fn sign_request(daemon_seed: &[u8; 32], body: &[u8]) -> String {
    b64(&ed25519_sign(daemon_seed, REQUEST_DOMAIN, body))
}

/// Checks a request body's signature against the daemon key it names (what the relay does).
///
/// # Errors
///
/// [`PushError::Json`], [`PushError::Malformed`] or [`PushError::Signature`].
pub fn verify_request(body: &[u8], signature: &str) -> Result<RelayRequest, PushError> {
    let request: RelayRequest = serde_json::from_slice(body)?;
    ed25519_verify(
        &parse_key(&request.daemon)?,
        REQUEST_DOMAIN,
        body,
        &unb64(signature)?,
    )?;
    Ok(request)
}

/// What the daemon authorises a notification action to do. Encoded with postcard and signed
/// by the daemon ([`issue_token`]); the device treats it as opaque bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActionToken {
    /// [`ActionToken::VERSION`].
    pub v: u16,
    /// The issuing daemon.
    pub daemon: DaemonId,
    /// The only device that may use it (the one the notification was sealed to).
    pub device: DeviceId,
    /// The pane whose agent asked.
    pub pane: PaneId,
    /// The approval request.
    pub request: RequestId,
    /// The option "Approve" picks.
    pub approve: Option<OptionId>,
    /// The option "Deny" picks.
    pub deny: Option<OptionId>,
    /// The attention item, marked seen once the action runs.
    pub item: u64,
    /// After this the daemon refuses the token.
    pub expires: UnixMillis,
    /// [`request_subject`] of the request as the notification showed it. The daemon recomputes
    /// it before applying a decision, so the answer only ever lands on that exact request.
    pub subject: [u8; 32],
}

impl ActionToken {
    /// The format version this crate writes.
    pub const VERSION: u16 = 2;
}

/// A digest of what an approval asks: the agent's own request id, the tool and the summary
/// shown to the user. Length-prefixed, so no two different requests share an encoding.
pub fn request_subject(agent_request: &str, tool: Option<&str>, summary: &str) -> [u8; 32] {
    let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
    digest.update(b"push-request-subject/v1\0");
    digest.update(&[u8::from(tool.is_some())]);
    for part in [agent_request, tool.unwrap_or(""), summary] {
        digest.update(&(part.len() as u64).to_le_bytes());
        digest.update(part.as_bytes());
    }
    digest
        .finish()
        .as_ref()
        .try_into()
        .expect("SHA-256 is 32 bytes")
}

/// The device's answer to an action.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Decision {
    /// The notification's Approve button.
    Approve,
    /// The notification's Deny button.
    Deny,
}

impl Decision {
    fn byte(self) -> u8 {
        match self {
            Self::Approve => 1,
            Self::Deny => 0,
        }
    }
}

/// Encodes and signs a token: `postcard(token) || Ed25519(daemon, TOKEN_DOMAIN || postcard)`.
pub fn issue_token(daemon_seed: &[u8; 32], token: &ActionToken) -> Vec<u8> {
    let body = postcard::to_stdvec(token).expect("tokens always encode");
    let sig = ed25519_sign(daemon_seed, TOKEN_DOMAIN, &body);
    [body, sig.to_vec()].concat()
}

/// Checks a token's signature with the daemon's own key and its expiry against `now`.
///
/// # Errors
///
/// [`PushError::Malformed`], [`PushError::Signature`] or [`PushError::Expired`].
pub fn verify_token(
    daemon_public: &[u8; 32],
    bytes: &[u8],
    now: UnixMillis,
) -> Result<ActionToken, PushError> {
    if bytes.len() <= SIG_LEN {
        return Err(PushError::Malformed);
    }
    let (body, sig) = bytes.split_at(bytes.len() - SIG_LEN);
    ed25519_verify(daemon_public, TOKEN_DOMAIN, body, sig)?;
    let token: ActionToken = postcard::from_bytes(body).map_err(|_| PushError::Malformed)?;
    if token.v != ActionToken::VERSION || token.daemon.0 != *daemon_public {
        return Err(PushError::Malformed);
    }
    if now >= token.expires {
        return Err(PushError::Expired);
    }
    Ok(token)
}

/// The message a device signs for a decision: `DECISION_DOMAIN || token || decision byte`
/// (1 approve, 0 deny), without the domain.
#[doc(hidden)]
pub fn decision_message(token: &[u8], decision: Decision) -> Vec<u8> {
    [token, &[decision.byte()]].concat()
}

/// The device's signature on its decision, with its Ed25519 (iroh) secret key. Lets the daemon
/// log a decision the device provably made (D17 signed approvals), not just one that arrived
/// on its connection.
pub fn sign_decision(device_seed: &[u8; 32], token: &[u8], decision: Decision) -> [u8; 64] {
    ed25519_sign(
        device_seed,
        DECISION_DOMAIN,
        &decision_message(token, decision),
    )
}

/// Checks [`sign_decision`]'s signature against the device key.
///
/// # Errors
///
/// [`PushError::Signature`].
pub fn verify_decision(
    device_public: &[u8; 32],
    token: &[u8],
    decision: Decision,
    sig: &[u8],
) -> Result<(), PushError> {
    ed25519_verify(
        device_public,
        DECISION_DOMAIN,
        &decision_message(token, decision),
        sig,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(daemon: [u8; 32]) -> ActionToken {
        ActionToken {
            v: ActionToken::VERSION,
            daemon: DaemonId(daemon),
            device: DeviceId([2; 32]),
            pane: PaneId(4),
            request: RequestId(9),
            approve: Some(OptionId(0)),
            deny: Some(OptionId(2)),
            item: 3,
            expires: UnixMillis(2_000),
            subject: request_subject("toolu_1", Some("Bash"), "make deploy"),
        }
    }

    #[test]
    fn tokens_verify_and_expire() {
        let seed = [5; 32];
        let public = ed25519_public(&seed);
        let bytes = issue_token(&seed, &token(public));
        assert_eq!(
            verify_token(&public, &bytes, UnixMillis(1_000)).unwrap(),
            token(public)
        );
        assert!(matches!(
            verify_token(&public, &bytes, UnixMillis(2_000)),
            Err(PushError::Expired)
        ));
        let mut forged = bytes.clone();
        forged[3] ^= 1;
        assert!(verify_token(&public, &forged, UnixMillis(1_000)).is_err());
        let other = ed25519_public(&[6; 32]);
        assert!(verify_token(&other, &bytes, UnixMillis(1_000)).is_err());
    }

    #[test]
    fn request_subjects_tell_requests_apart() {
        let subject = request_subject("toolu_1", Some("Bash"), "rm -rf build");
        assert_eq!(
            subject,
            request_subject("toolu_1", Some("Bash"), "rm -rf build")
        );
        assert_ne!(
            subject,
            request_subject("toolu_2", Some("Bash"), "rm -rf build")
        );
        assert_ne!(
            subject,
            request_subject("toolu_1", Some("Bash"), "rm -rf /")
        );
        assert_ne!(subject, request_subject("toolu_1", None, "rm -rf build"));
        // Moving text between fields changes the digest.
        assert_ne!(
            request_subject("ab", Some("c"), ""),
            request_subject("a", Some("bc"), "")
        );
        assert_ne!(
            request_subject("x", Some(""), "s"),
            request_subject("x", None, "s")
        );
    }

    #[test]
    fn decisions_bind_token_and_choice() {
        let device = [8; 32];
        let public = ed25519_public(&device);
        let sig = sign_decision(&device, b"tok", Decision::Approve);
        verify_decision(&public, b"tok", Decision::Approve, &sig).unwrap();
        assert!(verify_decision(&public, b"tok", Decision::Deny, &sig).is_err());
        assert!(verify_decision(&public, b"tok2", Decision::Approve, &sig).is_err());
    }

    #[test]
    fn requests_verify_and_reject_tampering() {
        let seed = [3; 32];
        let request = RelayRequest {
            v: RelayRequest::VERSION,
            daemon: hex(&ed25519_public(&seed)),
            cap: "cap".into(),
            push_type: PushType::Alert,
            category: Some(Category::Approval),
            collapse: Some(collapse_id(&seed, PaneId(1), Category::Approval)),
            sealed: "AAAA".into(),
            ts: 1,
            nonce: nonce(),
            event: None,
            stale: None,
            dismiss: None,
            urgent: false,
        };
        let body = serde_json::to_vec(&request).unwrap();
        let sig = sign_request(&seed, &body);
        assert_eq!(verify_request(&body, &sig).unwrap(), request);
        let mut tampered = body.clone();
        let position = tampered.iter().position(|&byte| byte == b'c').unwrap();
        tampered[position] = b'd';
        assert!(verify_request(&tampered, &sig).is_err());
    }

    #[test]
    fn collapse_ids_differ_per_pane_and_daemon() {
        let id = collapse_id(&[1; 32], PaneId(1), Category::Done);
        assert_eq!(id.len(), 32);
        assert_ne!(id, collapse_id(&[1; 32], PaneId(2), Category::Done));
        assert_ne!(id, collapse_id(&[2; 32], PaneId(1), Category::Done));
        assert_ne!(id, collapse_id(&[1; 32], PaneId(1), Category::Approval));
    }

    #[test]
    fn oversized_payloads_are_refused() {
        let (_, public) = x25519_keypair();
        let big = vec![b'x'; 4000];
        assert!(matches!(
            seal(&public, &[1; 32], &big),
            Err(PushError::TooLarge(_))
        ));
    }

    #[test]
    fn sealed_payloads_resist_truncation_versions_and_domain_swaps() {
        let (secret, public) = x25519_keypair();
        let seed = [1; 32];
        let sealed = seal(&public, &seed, b"{}").unwrap();
        // Fresh ephemeral key per payload: the same message never repeats a key or ciphertext.
        let again = seal(&public, &seed, b"{}").unwrap();
        assert_ne!(sealed[..43], again[..43]);
        assert_ne!(sealed, again);

        let raw = unb64(&sealed).unwrap();
        for cut in [1, hpke::TAG_LEN, raw.len() - hpke::KEY_LEN] {
            assert!(
                open(&secret, &b64(&raw[..raw.len() - cut])).is_err(),
                "cut {cut}"
            );
        }
        assert!(open(&secret, &b64(&raw[..hpke::KEY_LEN])).is_err());

        let envelope = |version: u8, domain: &[u8], json: &[u8], sig_len: usize| {
            let sig = ed25519_sign(&seed, domain, json);
            let plaintext = [&[version][..], &sig[..sig_len], json].concat();
            let (enc, ciphertext) = hpke::seal(&public, SEAL_INFO, b"", &plaintext).unwrap();
            b64(&[enc.as_slice(), &ciphertext].concat())
        };
        let json = br#"{"v":1}"#;
        assert!(matches!(
            open(&secret, &envelope(2, PAYLOAD_DOMAIN, json, 64)),
            Err(PushError::Malformed)
        ));
        assert!(matches!(
            open(&secret, &envelope(1, PAYLOAD_DOMAIN, b"", 63)),
            Err(PushError::Malformed)
        ));
        // A signature the daemon made for another purpose does not verify as a payload.
        for domain in [REQUEST_DOMAIN, TOKEN_DOMAIN, DECISION_DOMAIN] {
            let opened = open(&secret, &envelope(1, domain, json, 64)).unwrap();
            assert!(opened.verify(&ed25519_public(&seed)).is_err());
        }
        open(&secret, &envelope(1, PAYLOAD_DOMAIN, json, 64))
            .unwrap()
            .verify(&ed25519_public(&seed))
            .unwrap();
    }

    #[test]
    fn wrong_device_or_daemon_fails() {
        let (secret, public) = x25519_keypair();
        let (other, _) = x25519_keypair();
        let sealed = seal(&public, &[1; 32], b"{}").unwrap();
        assert!(open(&other, &sealed).is_err());
        let opened = open(&secret, &sealed).unwrap();
        opened.verify(&ed25519_public(&[1; 32])).unwrap();
        assert!(opened.verify(&ed25519_public(&[2; 32])).is_err());
    }
}
