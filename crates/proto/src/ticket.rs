//! Pairing tickets: everything a new device needs to dial a daemon and prove it was invited.
//!
//! A ticket is shown by `hostd pair` as text and as a QR code. Its text form is
//! `<scheme>://pair/<base32>` ([`brand::URL_SCHEME`]), where the base32 (RFC 4648, no padding)
//! decodes to the postcard encoding of [`Ticket`]. Dialing by the daemon's key pins it in the
//! TLS handshake, so the ticket needs no other server authentication.
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
    /// The principal the paired device will act as.
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
            Self::Decode(error) => write!(f, "malformed pairing ticket: {error}"),
            Self::Version(version) => write!(f, "unsupported pairing ticket version {version}"),
        }
    }
}

impl std::error::Error for TicketError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Decode(error) => Some(error),
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
    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let bytes = ticket_bytes(text)?;
        let (version, _) = postcard::take_from_bytes::<u16>(&bytes).map_err(TicketError::Decode)?;
        if version != Self::VERSION {
            return Err(TicketError::Version(version));
        }
        postcard::from_bytes(&bytes).map_err(TicketError::Decode)
    }
}

/// What follows `<verb>/` or `<verb>#` in a link into the app: `<scheme>://<verb>`, the same
/// under the legacy scheme, or the universal link `https://<web domain>/<verb>`.
/// `None` when `link` is not such a link. Case is ignored.
pub(crate) fn link_payload<'a>(link: &'a str, verb: &str) -> Option<&'a str> {
    [
        format!("{}://{verb}", brand::RELEASE_URL_SCHEME),
        format!("{}://{verb}", brand::DEV_URL_SCHEME),
        format!("{}://{verb}", brand::legacy::URL_SCHEME),
        format!("https://{}/{verb}", brand::WEB_DOMAIN),
    ]
    .iter()
    .find_map(|head| {
        let start = link.get(..head.len())?;
        start
            .eq_ignore_ascii_case(head)
            .then(|| link[head.len()..].strip_prefix(['/', '#']))?
    })
}

/// The base32 payload of a ticket's text, decoded.
fn ticket_bytes(text: &str) -> Result<Vec<u8>, TicketError> {
    let text = text.trim();
    let payload = link_payload(text, "pair").unwrap_or(text);
    let cleaned: String = payload
        .chars()
        .filter(|ch| !ch.is_whitespace())
        .map(|ch| ch.to_ascii_uppercase())
        .collect();
    BASE32_NOPAD
        .decode(cleaned.as_bytes())
        .map_err(|_| TicketError::Encoding)
}

/// Which relays a daemon uses, so the paired device dials it the same way (self-hosted relays,
/// local-only mode). Travels in [`TicketExtras`].
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum TicketRelays {
    /// The product's default relays (and address lookup); [`Ticket::relay_url`] is the
    /// daemon's home relay among them.
    #[default]
    Default,
    /// Only these `iroh-relay` servers, no third-party address lookup.
    Custom {
        /// Relay URLs (`https://relay.example.com`).
        urls: Vec<String>,
        /// Shared access token the relays require, if any.
        auth_token: Option<String>,
    },
    /// No relays at all: direct addresses only (LAN, Tailscale, a VPN).
    Disabled,
}

/// Optional additions to a [`Ticket`], encoded after it in the same base32 payload as
/// `EXTRAS_MAGIC || postcard(TicketExtras)`. `postcard::from_bytes` ignores trailing bytes, so
/// a [`Ticket::from_str`] that predates them still reads the ticket (and dials through
/// `relay_url`, which a daemon with custom relays sets to its home relay).
///
/// # Examples
///
/// ```
/// use proto::{DaemonId, PairingSecret, PrincipalId, Ticket, TicketExtras, TicketRelays, UnixMillis};
///
/// let ticket = Ticket {
///     v: Ticket::VERSION,
///     daemon_id: DaemonId([7; 32]),
///     addrs: vec![],
///     relay_url: Some("https://relay.example.com./".into()),
///     principal: PrincipalId([1; 16]),
///     secret: PairingSecret([2; 16]),
///     expires: UnixMillis(1_800_000_000_000),
/// };
/// let extras = TicketExtras {
///     v: TicketExtras::VERSION,
///     relays: TicketRelays::Custom {
///         urls: vec!["https://relay.example.com".into()],
///         auth_token: None,
///     },
/// };
/// let text = ticket.to_string_with(&extras);
/// assert_eq!(Ticket::parse_with_extras(&text)?, (ticket.clone(), extras));
/// // Older readers still get the ticket.
/// assert_eq!(text.parse::<Ticket>()?, ticket);
/// # Ok::<(), proto::TicketError>(())
/// ```
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct TicketExtras {
    /// [`TicketExtras::VERSION`].
    pub v: u16,
    pub relays: TicketRelays,
}

impl TicketExtras {
    /// The extension version this crate writes.
    pub const VERSION: u16 = 1;
}

/// Marks the start of [`TicketExtras`] after the ticket.
const EXTRAS_MAGIC: u8 = 0xE7;

impl Ticket {
    /// The text form with `extras` appended (plain [`Display`](fmt::Display) when the relays
    /// are the default, so ordinary tickets stay short).
    pub fn to_string_with(&self, extras: &TicketExtras) -> String {
        if extras.relays == TicketRelays::Default {
            return self.to_string();
        }
        let mut bytes = postcard::to_stdvec(self).expect("tickets always encode");
        bytes.push(EXTRAS_MAGIC);
        bytes.extend(postcard::to_stdvec(extras).expect("extras always encode"));
        format!(
            "{}://pair/{}",
            brand::URL_SCHEME,
            BASE32_NOPAD.encode(&bytes)
        )
    }

    /// Parses a ticket and its extras (the defaults when there are none, or when they come
    /// from a newer writer this build cannot read).
    ///
    /// # Errors
    ///
    /// As [`Ticket::from_str`].
    pub fn parse_with_extras(text: &str) -> Result<(Self, TicketExtras), TicketError> {
        let ticket: Self = text.parse()?;
        let bytes = ticket_bytes(text)?;
        let (_, rest) = postcard::take_from_bytes::<Self>(&bytes).map_err(TicketError::Decode)?;
        let extras = match rest.split_first() {
            Some((&EXTRAS_MAGIC, extras_bytes)) => {
                postcard::from_bytes::<TicketExtras>(extras_bytes)
                    .ok()
                    .filter(|extras| extras.v == TicketExtras::VERSION)
                    .unwrap_or_default()
            }
            _ => TicketExtras::default(),
        };
        Ok((ticket, extras))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{GrantChain, Invite};

    #[test]
    fn tickets_parse_from_every_link_form() {
        let ticket = Ticket {
            v: Ticket::VERSION,
            daemon_id: DaemonId([7; 32]),
            addrs: vec!["127.0.0.1:4433".parse().unwrap()],
            relay_url: None,
            principal: PrincipalId([1; 16]),
            secret: PairingSecret([2; 16]),
            expires: UnixMillis(1_800_000_000_000),
        };
        let text = ticket.to_string();
        let payload = text.rsplit('/').next().unwrap();
        for link in [
            format!("{}://pair/{payload}", brand::legacy::URL_SCHEME),
            format!("https://{}/pair#{payload}", brand::WEB_DOMAIN),
            format!(
                "HTTPS://{}/PAIR/{payload}",
                brand::WEB_DOMAIN.to_uppercase()
            ),
        ] {
            assert_eq!(link.parse::<Ticket>().unwrap(), ticket, "{link}");
        }
        let elsewhere = format!("https://elsewhere.example/pair#{payload}");
        assert!(elsewhere.parse::<Ticket>().is_err());
    }

    #[test]
    fn invites_parse_from_every_link_form() {
        let invite = Invite {
            v: Invite::VERSION,
            daemon_id: DaemonId([7; 32]),
            addrs: vec![],
            relay_url: None,
            inviter: "Ana".into(),
            chain: GrantChain { links: vec![] },
        };
        let text = invite.to_string();
        let payload = text.rsplit('/').next().unwrap();
        for link in [
            format!("{}://join#{payload}", brand::legacy::URL_SCHEME),
            format!("https://{}/join#{payload}", brand::WEB_DOMAIN),
        ] {
            assert!(link.parse::<Invite>().unwrap() == invite, "{link}");
        }
    }
}
