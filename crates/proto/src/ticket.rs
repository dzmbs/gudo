//! Pairing tickets: everything a new device needs to dial a daemon and prove it was invited.
//!
//! A ticket is shown by `hostd pair` as text and as a QR code. Its text form is
//! `<scheme>://pair/<base32>` ([`brand::URL_SCHEME`]), where the base32 (RFC 4648, no padding)
//! decodes to the postcard encoding of [`Ticket`]. Dialing by the daemon's key pins it in the
//!
//! # Examples
//!
//! ```
//! use proto::{DaemonId, PairingSecret, PrincipalId, Ticket, UnixMillis};
//!
//! let ticket = Ticket {
//!     v: Ticket::VERSION,
//!     daemon_id: DaemonId([7; 32]),
//!     addrs: vec!["127.0.0.1:4433".parse().unwrap()],
//!     relay_url: None,
//!     principal: PrincipalId([1; 16]),
//!     secret: PairingSecret([2; 16]),
//!     expires: UnixMillis(1_800_000_000_000),
//! };
//! let text = ticket.to_string();
//! assert!(text.starts_with(&format!("{}://pair/", brand::URL_SCHEME)));
//! assert_eq!(text.parse::<Ticket>()?, ticket);
//! # Ok::<(), proto::TicketError>(())
//! ```

use std::fmt;
use std::net::SocketAddr;
use std::str::FromStr;

use data_encoding::BASE32_NOPAD;
use serde::{Deserialize, Serialize};

use crate::ids::{DaemonId, PrincipalId, UnixMillis};

/// A one-time pairing secret (128 bits). Consumed by the first device that presents it.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PairingSecret(pub [u8; 16]);

impl fmt::Debug for PairingSecret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Never log the secret itself.
        f.write_str("PairingSecret(…)")
    }
}

/// An invitation to pair with a daemon.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ticket {
    /// Ticket format version; [`Ticket::VERSION`].
    pub v: u16,
    /// The daemon's iroh endpoint id.
    pub daemon_id: DaemonId,
    /// Direct addresses to try.
    pub addrs: Vec<SocketAddr>,
    /// The daemon's home relay, if it uses one.
    pub relay_url: Option<String>,
    /// The principal the paired device will act as. The MVP has a single owner principal.
    pub principal: PrincipalId,
    /// One-time secret proving the invitation.
    pub secret: PairingSecret,
    /// After this instant the daemon refuses the secret.
    pub expires: UnixMillis,
}

impl Ticket {
    /// The format version this crate writes and reads.
    pub const VERSION: u16 = 1;
}

/// Why a ticket could not be parsed.
#[derive(Debug)]
pub enum TicketError {
    /// Not base32, or not a `<scheme>://pair/` URL.
    Encoding,
    /// The payload is not a valid ticket.
    Decode(postcard::Error),
    /// A ticket version this build does not read.
    Version(u16),
}

impl fmt::Display for TicketError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Encoding => f.write_str("not a pairing ticket"),
            Self::Decode(e) => write!(f, "malformed pairing ticket: {e}"),
            Self::Version(v) => write!(f, "unsupported pairing ticket version {v}"),
        }
    }
}

impl std::error::Error for TicketError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Decode(e) => Some(e),
            _ => None,
        }
    }
}

impl fmt::Display for Ticket {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let bytes = postcard::to_stdvec(self).map_err(|_| fmt::Error)?;
        write!(
            f,
            "{}://pair/{}",
            brand::URL_SCHEME,
            BASE32_NOPAD.encode(&bytes)
        )
    }
}

impl FromStr for Ticket {
    type Err = TicketError;

    /// Parses the URL form, or the bare base32 payload. Whitespace and case are ignored, so a
    /// ticket survives being retyped or wrapped by a terminal.
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let s = s.trim();
        let prefix = format!("{}://pair/", brand::URL_SCHEME);
        let payload = match s.get(..prefix.len()) {
            Some(head) if head.eq_ignore_ascii_case(&prefix) => &s[prefix.len()..],
            _ => s,
        };
        let cleaned: String = payload
            .chars()
            .filter(|c| !c.is_whitespace())
            .map(|c| c.to_ascii_uppercase())
            .collect();
        let bytes = BASE32_NOPAD
            .decode(cleaned.as_bytes())
            .map_err(|_| TicketError::Encoding)?;
        let (v, _) = postcard::take_from_bytes::<u16>(&bytes).map_err(TicketError::Decode)?;
        if v != Self::VERSION {
            return Err(TicketError::Version(v));
        }
        postcard::from_bytes(&bytes).map_err(TicketError::Decode)
    }
}
