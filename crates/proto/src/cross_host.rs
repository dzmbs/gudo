//! Agents reaching other hosts through the owner's device.
//!
//! An agent on host A calls a terminal tool with `host`. A's daemon never talks to host B: it
//! pushes a [`CrossHostRequest`] to its connected owner devices that announced
//! [`Caps::CROSS_HOST`](crate::Caps::CROSS_HOST). A device checks that B is a host it is
//! paired with as owner and that the owner let agents on A reach B, asks the owner (or finds
//! an earlier yes that covers it), claims the request with a signed
//! [`Decide`](crate::Decide), and performs it on B over its own connection as a
//! [`RemoteCall`] on behalf of the agent. B's [`TermReply`](CrossHostPush::CallResult) goes
//! back to A as [`CrossHostMsg::Result`]. The first device to claim a request performs it;
//! the others are told [`CrossHostPush::Closed`].
//!
//! Daemons that take part say
//! [`MoreDaemonFeatures::CROSS_HOST`](crate::MoreDaemonFeatures::CROSS_HOST). Guests never
//! announce the capability, never get a request and are never a target.

use serde::{Deserialize, Serialize};

use crate::ids::{DaemonId, OptionId, PaneId, RequestId, SessionId, UnixMillis};
use crate::{Decide, drive};

/// What kind of thing a relayed tool does, for wording and for what an earlier yes covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CrossHostVerb {
    /// Lists, reads or waits; changes nothing.
    Read,
    /// Opens a tab, pane or agent.
    Open,
    /// Types, runs a command or prompts an agent.
    Input,
    /// Closes a pane.
    Close,
}

/// The tools an agent may call on another host, and what each does. `events_wait` and the
/// tools about the agent's own pane stay on its host.
pub const CROSS_HOST_TOOLS: [(&str, CrossHostVerb); 12] = [
    ("pane_list", CrossHostVerb::Read),
    ("pane_read", CrossHostVerb::Read),
    ("pane_wait", CrossHostVerb::Read),
    ("agent_wait", CrossHostVerb::Read),
    ("agent_result", CrossHostVerb::Read),
    ("tab_new", CrossHostVerb::Open),
    ("pane_split", CrossHostVerb::Open),
    ("agent_spawn", CrossHostVerb::Open),
    ("pane_send", CrossHostVerb::Input),
    ("cmd_run", CrossHostVerb::Input),
    ("agent_prompt", CrossHostVerb::Input),
    ("pane_close", CrossHostVerb::Close),
];

impl CrossHostVerb {
    /// The verb of a tool that may reach another host; `None` for any other tool.
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::CrossHostVerb;
    ///
    /// assert_eq!(CrossHostVerb::of("cmd_run"), Some(CrossHostVerb::Input));
    /// assert_eq!(CrossHostVerb::of("events_wait"), None);
    /// ```
    pub fn of(tool: &str) -> Option<Self> {
        CROSS_HOST_TOOLS
            .iter()
            .find(|(name, _)| *name == tool)
            .map(|(_, verb)| *verb)
    }
}

/// An agent's call to be performed on another host, as its host pushes it to owner devices.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CrossHostRequest {
    /// Claim it with a [`Decide`] for this id, signed for the asking host.
    pub id: RequestId,
    /// The asking agent's pane on its host.
    pub pane_id: PaneId,
    /// Names this agent for as long as its pane is open; an earlier yes for it matches only
    /// this key, and [`CrossHostPush::AgentGone`] ends it.
    pub agent_key: u64,
    /// Who asks, for display (`Claude`, `Codex`, or the program's name).
    pub agent: String,
    /// The other host, as the agent named it: a name shown in the app, or a daemon id.
    pub host: String,
    /// One of [`CROSS_HOST_TOOLS`].
    pub tool: String,
    /// The tool's arguments, a JSON object (without `host`).
    pub args: String,
    /// A guest drives the asking pane: their name, so the card says it was asked meanwhile.
    pub guest_driving: Option<String>,
    /// When the request lapses unclaimed.
    pub expires_at: UnixMillis,
}

impl CrossHostRequest {
    /// Allows this one call (and, from then on, reads by this agent on that host).
    pub const ALLOW_ONCE: OptionId = OptionId(0);
    /// Allows everything this agent asks on that host until its pane closes.
    pub const ALLOW_AGENT: OptionId = OptionId(1);
    /// Refuses.
    pub const DENY: OptionId = OptionId(2);

    /// The options in order, with the labels every surface shows.
    pub const OPTIONS: [(OptionId, &'static str); 3] = [
        (Self::ALLOW_ONCE, "Allow once"),
        (Self::ALLOW_AGENT, "Allow all for this agent"),
        (Self::DENY, "Deny"),
    ];

    /// What the tool does, from the tool and its arguments.
    pub fn verb(&self) -> Option<CrossHostVerb> {
        CrossHostVerb::of(&self.tool)
    }
}

/// Why a device will not relay a request. The asking host words it for the agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum CrossHostRefusal {
    /// No host of that name or id is paired with the device.
    UnknownHost { host: String },
    /// The owner has not let agents on the asking host reach it.
    NotEnabled { host: String },
    /// The device joined it as a guest: someone else's host is never a target.
    Guest { host: String },
    /// It is reached over plain SSH, with no helper to run tools.
    NoHelper { host: String },
    /// Its helper is too old to run relayed tools.
    OldHelper { host: String },
    /// The device cannot reach it right now.
    Offline { host: String },
    /// The asking host is the target.
    SameHost,
}

impl CrossHostRefusal {
    /// The refusal in words for the agent on `here` (`this Mac`).
    ///
    /// # Examples
    ///
    /// ```
    /// use proto::CrossHostRefusal;
    ///
    /// let refusal = CrossHostRefusal::NotEnabled { host: "ops".into() };
    /// assert_eq!(
    ///     refusal.message("this Mac"),
    ///     format!(
    ///         "ops isn't enabled for agents on this Mac. Turn it on in {} › Hosts › ops.",
    ///         brand::PRODUCT_NAME
    ///     )
    /// );
    /// ```
    pub fn message(&self, here: &str) -> String {
        let product = brand::PRODUCT_NAME;
        match self {
            Self::UnknownHost { host } => {
                format!("No host named {host} is paired with the {product} device that answered.")
            }
            Self::NotEnabled { host } => format!(
                "{host} isn't enabled for agents on {here}. Turn it on in {product} › Hosts › {host}."
            ),
            Self::Guest { host } => {
                format!("{host} was joined as a guest; agents never reach someone else's host.")
            }
            Self::NoHelper { host } => format!("Install the helper on {host} to reach it."),
            Self::OldHelper { host } => format!("Update the helper on {host} to reach it."),
            Self::Offline { host } => format!("{host} isn't connected to the {product} device."),
            Self::SameHost => "That is this host: call the tool without `host`.".into(),
        }
    }
}

/// Where a device stands with one of its hosts, as `host_list` shows it on another.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PairState {
    /// Agents on the receiving host may ask to reach it.
    Enabled,
    /// The owner has not turned it on.
    Off,
    /// Turned on, but the device is not connected to it.
    Offline,
    /// Joined as a guest: never a target.
    Guest,
    /// Plain SSH, no helper.
    NoHelper,
    /// Its helper is too old.
    OldHelper,
}

/// One of the device's other hosts, sent to a host so its agents can list them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostEntry {
    /// The daemon id in hex, or the app's own id for a host without a helper.
    pub id: String,
    /// The name shown in the app.
    pub name: String,
    pub state: PairState,
}

/// The agent a relayed call is made for.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RemoteAgent {
    /// The agent's host.
    pub host: DaemonId,
    /// Its host's name in the app, for display and the audit log.
    pub host_name: String,
    /// The agent's pane there.
    pub pane_id: PaneId,
    /// [`CrossHostRequest::agent_key`].
    pub agent_key: u64,
    /// `Claude`.
    pub agent: String,
}

/// The owner's yes a relayed call runs under.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Consent {
    /// The owner allowed exactly this call.
    Once,
    /// The owner allowed everything this agent asks on this host until its pane closes.
    Agent,
    /// A read, covered by an earlier yes for this agent on this host.
    Reads,
}

/// A call a device performs on a host for an agent elsewhere.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteCall {
    pub on_behalf_of: RemoteAgent,
    pub consent: Consent,
    /// The session to work in (the one the device shows); else the host's most recent.
    pub session: Option<SessionId>,
    /// One of [`CROSS_HOST_TOOLS`].
    pub tool: String,
    /// A JSON object.
    pub args: String,
}

/// From a daemon to an owner device with [`Caps::CROSS_HOST`](crate::Caps::CROSS_HOST)
/// ([`ServerCtl::CrossHost`](crate::ServerCtl::CrossHost)).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum CrossHostPush {
    /// An agent here asks for a call on another host (and, on connecting, every open one).
    Request(CrossHostRequest),
    /// The request is over: claimed by another device, answered, expired or withdrawn.
    Closed { id: RequestId },
    /// The answer to [`CrossHostMsg::Claim`]: `won` if this device performs it.
    Claimed { id: RequestId, won: bool },
    /// The agent's pane closed: every yes for this agent ends.
    AgentGone { pane_id: PaneId, agent_key: u64 },
    /// The answer to [`CrossHostMsg::Call`]: the terminal tools' reply, one JSON object.
    CallResult { req_id: u64, reply: String },
}

/// From an owner device to a daemon ([`ClientCtl::CrossHost`](crate::ClientCtl::CrossHost)).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum CrossHostMsg {
    /// The device's other hosts, for `host_list`: on connecting and whenever they change.
    Directory(Vec<HostEntry>),
    /// Takes a request with the owner's answer, signed. Answered by
    /// [`CrossHostPush::Claimed`]; the winner of an allow then performs it.
    Claim(Decide),
    /// This device will not relay the request.
    Refuse {
        id: RequestId,
        refusal: CrossHostRefusal,
    },
    /// The claimed request's outcome: the target's reply, or why it could not be performed.
    Result {
        id: RequestId,
        outcome: Result<String, String>,
    },
    /// Performs a call for an agent on another host. Owner devices only; answered by
    /// [`CrossHostPush::CallResult`].
    Call { req_id: u64, call: RemoteCall },
    /// The agent is gone (its pane closed, or the owner revoked it): the panes it opened here
    /// go back to the user.
    AgentGone {
        host: DaemonId,
        pane_id: PaneId,
        agent_key: u64,
    },
}

/// A relayed call in words, from the tool and its arguments as the target will get them:
/// `run $ npm test`, `type “ls”, then Return into p3`. Text the agent chose is made visible
/// as in [`DriveAction::describe`](crate::DriveAction::describe).
///
/// # Examples
///
/// ```
/// use proto::describe_cross_host;
///
/// assert_eq!(describe_cross_host("cmd_run", r#"{"command":"npm test"}"#), "run $ npm test");
/// assert_eq!(
///     describe_cross_host("pane_send", r#"{"pane":"p3","text":"ls","submit":true}"#),
///     "type “ls”, then Return into p3"
/// );
/// ```
pub fn describe_cross_host(tool: &str, args: &str) -> String {
    let args: serde_json::Value = serde_json::from_str(args).unwrap_or_default();
    let text = |key: &str| args[key].as_str().map(drive::visible);
    let pane = || {
        text("pane")
            .or_else(|| text("of"))
            .unwrap_or_else(|| "a pane of its own".into())
    };
    let launch = || match (text("agent"), text("command")) {
        (Some(agent), _) => format!(" running {agent}"),
        (None, Some(command)) => format!(" running $ {command}"),
        (None, None) => String::new(),
    };
    match tool {
        "pane_list" => "list the tabs and panes".into(),
        "pane_read" => format!("read {}", pane()),
        "pane_wait" => format!("wait on {}", pane()),
        "agent_wait" | "agent_result" => "read how the agents it started are doing".into(),
        "tab_new" => format!("open a tab{}", launch()),
        "pane_split" => format!("open a pane beside {}{}", pane(), launch()),
        "agent_spawn" => {
            let kind = text("kind").unwrap_or_else(|| "an agent".into());
            match text("prompt") {
                Some(prompt) => format!("start {kind} and prompt it “{prompt}”"),
                None => format!("start {kind}"),
            }
        }
        "pane_send" => {
            let action = drive::DriveAction::Type {
                text: args["text"].as_str().map(str::to_owned),
                keys: args["keys"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|key| key.as_str().map(str::to_owned))
                    .collect(),
                submit: args["submit"].as_bool().unwrap_or(false),
            };
            let typed = action.describe();
            let typed = typed.strip_prefix("Type").unwrap_or(&typed);
            format!("type{typed} into {}", pane())
        }
        "cmd_run" => {
            let command = text("command").unwrap_or_default();
            let place = match (text("pane"), text("cwd")) {
                (Some(pane), Some(cwd)) => format!(" in {pane}, in {cwd}"),
                (Some(pane), None) => format!(" in {pane}"),
                (None, Some(cwd)) => format!(" in {cwd}"),
                (None, None) => String::new(),
            };
            format!("run $ {command}{place}")
        }
        "agent_prompt" => format!(
            "prompt the agent in {} “{}”",
            pane(),
            text("text").unwrap_or_default()
        ),
        "pane_close" => format!("close {}", pane()),
        other => format!("call {}", drive::visible(other)),
    }
}
