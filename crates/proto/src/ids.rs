//! Identifiers, counters and small bitsets shared by all messages.

use std::fmt;
use std::ops::{BitOr, BitOrAssign};

use serde::{Deserialize, Serialize};

macro_rules! counter {
    ($(#[$doc:meta])* $name:ident) => {
        $(#[$doc])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
        #[derive(Serialize, Deserialize)]
        pub struct $name(pub u64);

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                fmt::Display::fmt(&self.0, f)
            }
        }
    };
}

counter! {
    /// A pane on one daemon. Unique for the daemon's lifetime, never reused.
    PaneId
}
counter! {
    /// A session on one daemon. Never reused, stable across daemon restarts.
    SessionId
}
counter! {
    /// A tab on one daemon. Never reused, stable across daemon restarts.
    TabId
}
counter! {
    /// Byte offset into a pane's PTY output stream. Monotonic per pane per [`SnapGen`].
    Seq
}
counter! {
    /// Per-connection, per-pane sequence number of an [`Input`](crate::Input) event.
    InputSeq
}
counter! {
    /// Generation of a pane's terminal state. Bumped whenever `Seq` stops being continuous
    /// (daemon restart, history reset), so a client's resume point from another generation is
    /// known to be invalid.
    SnapGen
}
counter! {
    /// Identifies one daemon run. A client seeing a new epoch must drop all resume state.
    SessionEpoch
}
counter! {
    /// An agent approval request, unique per daemon. Decisions are single-flight per id.
    RequestId
}
counter! {
    /// Milliseconds since the Unix epoch, UTC.
    UnixMillis
}

/// One answer within an approval request (for example "allow once", "deny").
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct OptionId(pub u32);

macro_rules! key_bytes {
    ($(#[$doc:meta])* $name:ident, $len:literal) => {
        $(#[$doc])*
        #[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
        pub struct $name(pub [u8; $len]);

        impl fmt::Debug for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(f, "{}(", stringify!($name))?;
                // A short prefix is enough to tell ids apart in logs.
                for b in &self.0[..4] {
                    write!(f, "{b:02x}")?;
                }
                f.write_str("…)")
            }
        }
    };
}

key_bytes! {
    /// A device: its iroh endpoint id, an Ed25519 public key. The QUIC handshake proves it.
    DeviceId, 32
}
key_bytes! {
    /// The daemon's iroh endpoint id (Ed25519 public key).
    DaemonId, 32
}
key_bytes! {
    /// A person, independent of how many devices they use. Random, minted by the daemon (or
    /// later by a team service).
    PrincipalId, 16
}
key_bytes! {
    /// A capability grant. Every inbound client message is authorised against the grant the
    /// connection presented, looked up by this id.
    GrantId, 16
}

/// Who did something: the person and the device key they did it from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Actor {
    /// The person.
    pub principal: PrincipalId,
    /// The device the action came from.
    pub device: DeviceId,
}

/// Opaque resume token minted by the daemon and echoed back in a later `Hello`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ResumeToken(#[serde(with = "crate::serde_bytes")] pub Vec<u8>);

macro_rules! bitset {
    ($(#[$doc:meta])* $name:ident: $repr:ty { $($(#[$fdoc:meta])* $flag:ident = $bit:expr;)* }) => {
        $(#[$doc])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
        pub struct $name(pub $repr);

        impl $name {
            /// The empty set.
            pub const EMPTY: Self = Self(0);
            $($(#[$fdoc])* pub const $flag: Self = Self(1 << $bit);)*

            /// Returns `true` if every flag in `other` is also set in `self`.
            pub const fn contains(self, other: Self) -> bool {
                self.0 & other.0 == other.0
            }
        }

        impl BitOr for $name {
            type Output = Self;

            fn bitor(self, rhs: Self) -> Self {
                Self(self.0 | rhs.0)
            }
        }

        impl BitOrAssign for $name {
            fn bitor_assign(&mut self, rhs: Self) {
                self.0 |= rhs.0;
            }
        }
    };
}

bitset! {
    /// pair-programming partner. The MVP only issues [`Roles::OWNER`].
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::Roles;
    ///
    /// let pair = Roles::DRIVER | Roles::APPROVER;
    /// assert!(pair.contains(Roles::DRIVER));
    /// assert!(!pair.contains(Roles::OWNER));
    /// ```
    Roles: u8 {
        /// Sees output, scrollback and agent state.
        VIEWER = 0;
        /// May send structured prompts to an agent.
        PROMPTER = 1;
        /// May send raw input while holding the lease, resize, take control.
        DRIVER = 2;
        /// May answer agent approval requests.
        APPROVER = 3;
        /// Everything, plus grant management and killing panes.
        OWNER = 4;
    }
}

impl Roles {
    /// Every role.
    pub const ALL: Self = Self(0b1_1111);

    /// The roles in force: [`Roles::OWNER`] implies every other role.
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::Roles;
    ///
    /// assert!(Roles::OWNER.effective().contains(Roles::DRIVER));
    /// assert_eq!(Roles::VIEWER.effective(), Roles::VIEWER);
    /// ```
    pub const fn effective(self) -> Self {
        if self.0 & Self::OWNER.0 != 0 {
            Self::ALL
        } else {
            Self(self.0 & Self::ALL.0)
        }
    }

    /// Whether these roles confer any of `any` (after [`effective`](Self::effective)).
    pub const fn allows_any(self, any: Self) -> bool {
        self.effective().0 & any.0 != 0
    }

    /// Whether every role in `other` is conferred by `self` (after
    /// [`effective`](Self::effective) on both sides): `other` is no wider than `self`.
    pub const fn covers(self, other: Self) -> bool {
        self.effective().contains(other.effective())
    }

    /// Lower-case role names joined by `+` (`"driver+approver"`).
    pub fn names(self) -> String {
        const NAMES: [(Roles, &str); 5] = [
            (Roles::OWNER, "owner"),
            (Roles::APPROVER, "approver"),
            (Roles::DRIVER, "driver"),
            (Roles::PROMPTER, "prompter"),
            (Roles::VIEWER, "viewer"),
        ];
        let names: Vec<&str> = NAMES
            .iter()
            .filter(|(r, _)| self.contains(*r))
            .map(|(_, n)| *n)
            .collect();
        if names.is_empty() {
            "none".into()
        } else {
            names.join("+")
        }
    }
}

impl std::str::FromStr for Roles {
    type Err = String;

    /// Parses role names joined by `+` or `,` (`"driver+approver"`).
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let mut roles = Self::EMPTY;
        for name in s.split(['+', ',']).map(str::trim).filter(|n| !n.is_empty()) {
            roles |= match name.to_ascii_lowercase().as_str() {
                "viewer" => Self::VIEWER,
                "prompter" => Self::PROMPTER,
                "driver" => Self::DRIVER,
                "approver" => Self::APPROVER,
                "owner" => Self::OWNER,
                other => return Err(format!("unknown role {other:?}")),
            };
        }
        if roles == Self::EMPTY {
            return Err("no role given".into());
        }
        Ok(roles)
    }
}

bitset! {
    /// Optional client capabilities announced in `Hello`.
    Caps: u32 {
        /// Accepts QUIC datagrams for echo hints and presence cursors.
        DATAGRAMS = 0;
        /// Renders kitty graphics blobs delivered on `bulk`.
        KITTY_GRAPHICS = 1;
        /// Runs local echo prediction and wants `EchoHint`.
        ECHO_PREDICTION = 2;
        /// Understands drawings and images (`ServerCtl::Artifact`, canvas panes).
        ARTIFACTS = 3;
        /// Understands `ServerCtl::AttachResult` (how the session was chosen, or why not).
        ATTACH_RESULT = 4;
        /// Wants `ServerCtl::DaemonInfo` (version, build, protocol level, host name) before
        /// the `Welcome` or `Refused`, and can be let in to upgrade a daemon whose snapshot
        /// format it does not decode (see `ServerCtl::DaemonInfo`).
        DAEMON_INFO = 5;
        /// Wants `ServerCtl::AgentUsage` pushes while it watches agent usage
        /// (`WorkspaceRequest::UsageWatch`).
        AGENT_USAGE = 6;
    }
}

bitset! {
    /// What a daemon can do beyond the base protocol, in [`DaemonInfo`](crate::DaemonInfo).
    DaemonFeatures: u32 {
        /// Accepts a new build of itself over the connection from its owner
        /// ([`StreamHeader::Upgrade`](crate::StreamHeader::Upgrade)) and restarts into it.
        SELF_UPGRADE = 0;
        /// Answers `WorkspaceRequest::UsageWatch` / `UsageUnwatch` (agent plan usage).
        AGENT_USAGE = 1;
    }
}
