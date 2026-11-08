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
                for byte in &self.0[..4] {
                    write!(f, "{byte:02x}")?;
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
    /// A person, independent of how many devices they use. Random, minted by the daemon.
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
    /// Adapter features, independent of permission to perform an action.
    AgentCapabilities: u16 {
        READ = 0;
        SEND = 1;
        ACKNOWLEDGED_SEND = 2;
        STOP = 3;
        APPROVALS = 4;
        DIFFS = 5;
        STREAMING_DELTAS = 6;
        THINKING = 7;
        PLANS = 8;
    }
}

bitset! {
    /// The roles a grant confers. Roles combine: `DRIVER | APPROVER` is normal for a
    /// pair-programming partner.
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
            .filter(|(role, _)| self.contains(*role))
            .map(|(_, name)| *name)
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
    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let mut roles = Self::EMPTY;
        for name in text
            .split(['+', ','])
            .map(str::trim)
            .filter(|name| !name.is_empty())
        {
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
        /// Shows native password prompts: wants `ServerCtl::Askpass` pushes and answers them
        /// with `ClientCtl::Askpass` (see `proto::askpass`). Without it the daemon's askpass
        /// helper asks on the terminal.
        ASKPASS = 7;
        /// Wants `ServerCtl::Repos` (repository, worktree, branch and pull request state of
        /// every pane); the daemon only watches repositories while such a client is connected.
        REPO_STATUS = 8;
        /// Can wait for an owner after presenting a knock invite (`ServerCtl::KnockAnswer`);
        /// on an owner device, wants `ServerCtl::Knock`. Without it a knock invite is refused
        /// as an invalid grant.
        KNOCK = 9;
        /// Understands approval policies: wants `ServerCtl::ApprovalPolicy` and
        /// `ServerCtl::ApprovalStatus`.
        APPROVAL_POLICY = 10;
        /// Wants `ServerCtl::Approval` pushes (what may be done with an open approval
        /// request, auto-approve rules in force) and may send `ClientCtl::Approval`.
        APPROVALS = 11;
        /// Wants `ServerCtl::WorkflowsChanged` when a workflow file it has listed changes
        /// (see `proto::workflow`).
        WORKFLOWS = 12;
        /// Opens URLs programs in a pane ask for and runs agents' browser tools: wants
        /// `ServerCtl::Browser` pushes and answers calls with `ClientCtl::BrowserResult`
        /// (see `proto::browser`).
        BROWSER = 13;
        /// Wants live presence (`ServerCtl::Peers`) and may send `ClientCtl::Peer`: drafts,
        /// viewports, following, heartbeats (see `proto::peer`). Silent such clients are
        /// marked away, then disconnected.
        PRESENCE = 14;
        /// Wants `ServerCtl::ProgramStatus`: what any program in a visible pane reports
        /// about itself (see `proto::program`).
        PROGRAM_STATUS = 15;
        /// On an owner device, wants `ServerCtl::DevicePaired` whenever another owner
        /// device pairs.
        DEVICE_ALERTS = 16;
        /// On an owner device, wants `ServerCtl::HostAlert`.
        HOST_ALERTS = 17;
        /// Wants `ServerCtl::Projects` after each `ServerCtl::LayoutChanged` (sent only
        /// with the owner role; see `proto::project`).
        PROJECTS = 18;
        /// Copies what programs write to the clipboard (OSC 52) in panes this connection
        /// typed into last: wants `ServerCtl::Clipboard`.
        CLIPBOARD = 19;
        /// Understands `AskpassPush::PromptWhileGuestDrives` (a password prompt asked while
        /// a guest holds the pane's lease).
        ASKPASS_DRIVER = 20;
        /// Shows floating panes: wants `ServerCtl::Floats` after each
        /// `ServerCtl::LayoutChanged` (see `proto::float`).
        FLOATS = 21;
        /// With `APPROVALS`, wants `ApprovalPush::Drive`: the exact action of an agent's request
        /// to drive one of the user's panes, to show it and offer all three answers (see
        /// `proto::drive`).
        DRIVE_ASKS = 22;
        /// On an owner device, wants `ServerCtl::Accounts` and, while watching usage,
        /// `ServerCtl::AccountUsage` (see `proto::account`).
        ACCOUNTS = 23;
        /// Mirrors panes with the daemon's terminal limits: wants
        /// `ServerCtl::TerminalLimits` after `DaemonInfo` and before `Welcome`.
        TERMINAL_LIMITS = 24;
        /// Numbers its input across reconnects (`Input::input_seq` keeps counting) and, after
        /// reconnecting with the `Welcome`'s resume token, sends again what was not yet
        /// acknowledged; the daemon applies each number once (`DaemonFeatures::INPUT_RESUME`).
        INPUT_RESUME = 25;
        /// On an owner device, wants `ServerCtl::GuestAnswered` whenever someone else answers
        /// an agent's request.
        ANSWER_ALERTS = 26;
        AGENT_TIMELINE = 27;
        /// Understands `SizePolicy::LastActive` and reports `ClientCtl::PaneActivity`.
        ACTIVE_SIZING = 28;
        PANE_SIZING = 29;
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
        /// Keeps drawings' finished versions and answers `ArtifactRequest::History` /
        /// `Restore`.
        ARTIFACT_HISTORY = 2;
        /// Multiplayer: invite terms (knock, history since joining) and approval
        /// policies (`MpRequest::RegisterInvite` … `Claim`).
        MP2 = 3;
        /// Sends the agents Live Activity (start, update, end) through the push relay and
        /// answers `WorkspaceRequest::PushActivity`.
        LIVE_ACTIVITY = 4;
        /// Answers `WorkspaceRequest::WorkflowList` / `WorkflowSave` and pushes
        /// `ServerCtl::WorkflowsChanged`.
        WORKFLOWS = 5;
        /// Answers `WorkspaceRequest::AgentInstalls`.
        AGENT_INSTALLS = 6;
        /// Applies `LayoutOp::BreakPane`, `MovePane` and `MergeTab`.
        PANE_MOVES = 7;
        /// Gives panes `BROWSER` (URLs reach clients with `Caps::BROWSER`) and serves agents'
        /// browser tools through them.
        BROWSER = 8;
        /// Answers `WorkspaceRequest::AgentMcpCommands`.
        AGENT_MCP = 9;
        /// Live presence: answers `ClientCtl::Peer` and pushes `ServerCtl::Peers` to clients
        /// with `Caps::PRESENCE` (see `proto::peer`).
        PRESENCE = 10;
        /// Answers `MpRequest::InviteLink`: a registered invite's chain and terms, so an
        /// owner can copy its link again.
        INVITE_LINKS = 11;
        /// Pushes `ServerCtl::ProgramStatus` to clients with `Caps::PROGRAM_STATUS`.
        PROGRAM_STATUS = 12;
        /// Applies `LayoutOp::SetTabProject`, `PutProject` and `RemoveProject`, and pushes
        /// `ServerCtl::Projects` to clients with `Caps::PROJECTS`.
        PROJECTS = 13;
        /// Runs a repository's setup and teardown commands only once the owner trusts them,
        /// and answers `WorkspaceRequest::RepoHooks` / `RepoTrust`.
        REPO_TRUST = 14;
        /// Remembers closed panes (directory, agent session) and starts
        /// `PaneLaunch::Reopen`.
        REOPEN = 15;
        /// Applies `LayoutOp::NewFloat`, `FloatPane`, `SetFloat` and `DockPane`, and pushes
        /// `ServerCtl::Floats` to clients with `Caps::FLOATS`.
        FLOATS = 16;
        /// Asks the owner before an agent drives one of the user's panes (`proto::drive`),
        /// instead of refusing.
        DRIVE_ASKS = 17;
        /// Keeps agent accounts: answers the `Account*` workspace requests, launches
        /// `PaneLaunch::AccountAgent` and `AccountSignIn` (see `proto::account`).
        ACCOUNTS = 18;
        /// Applies each input of a client once across its reconnects (`Caps::INPUT_RESUME`).
        INPUT_RESUME = 19;
        /// Answers `MpRequest::PairingTicket` and `MpRequest::RenameDevice` from paired owner
        /// devices.
        DEVICE_MANAGEMENT = 20;
        /// Answers `WorkspaceRequest::PushAgents` (which agents a device wants pushed).
        PUSH_AGENTS = 21;
        /// Answers programs' color queries with the theme clients send in
        /// `ClientCtl::TerminalColors`.
        TERMINAL_COLORS = 22;
        POWER_SETTINGS = 23;
        AGENT_TIMELINE = 24;
        /// Accepts `InputPayload::GeneratedBytes` without treating reports as typing.
        GENERATED_INPUT = 25;
        /// Accepts pane activity and applies shared-terminal size policies.
        ACTIVE_SIZING = 26;
        /// Accepts TimelineWatchVersioned with the peer's highest readable schema.
        VERSIONED_TIMELINE = 27;
        /// Reads bounded complete recorded tool changes through a scoped result handle.
        TIMELINE_TOOL_DIFF = 28;
        CHAT_SEND = 29;
        /// Native interrupt controls with live-turn tickets and draft-risk confirmation.
        CHAT_INTERRUPT = 30;
        /// Returns session-bound adapter features with a timeline watch snapshot.
        AGENT_CAPABILITIES = 31;
    }
}
