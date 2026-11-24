//! Chat's controls for the agent in a pane: its model, permission mode and reasoning effort,
//! and the questions and plans it asks the user to answer.
//!
//! A client opts in per pane with [`WorkspaceRequest::AgentControlsWatch`]: the reply is the
//! pane's [`AgentControls`], and every change after it is pushed as
//! [`ServerCtl::AgentControls`] until [`WorkspaceRequest::AgentControlsUnwatch`] or the
//! connection ends. [`WorkspaceRequest::SetAgentConfig`] changes the running agent; only the
//! owner may. A question is answered with [`ApprovalRequest::AnswerQuestion`], a plan with an
//! ordinary [`ClientCtl::Decide`] or, to keep planning with feedback,
//! [`ApprovalRequest::Refuse`]. Only daemons offering
//! [`MoreDaemonFeatures::AGENT_CONTROLS`] understand any of these.
//!
//! [`WorkspaceRequest::AgentControlsWatch`]: crate::WorkspaceRequest::AgentControlsWatch
//! [`WorkspaceRequest::AgentControlsUnwatch`]: crate::WorkspaceRequest::AgentControlsUnwatch
//! [`WorkspaceRequest::SetAgentConfig`]: crate::WorkspaceRequest::SetAgentConfig
//! [`ServerCtl::AgentControls`]: crate::ServerCtl::AgentControls
//! [`ApprovalRequest::AnswerQuestion`]: crate::ApprovalRequest::AnswerQuestion
//! [`ApprovalRequest::Refuse`]: crate::ApprovalRequest::Refuse
//! [`ClientCtl::Decide`]: crate::ClientCtl::Decide
//! [`MoreDaemonFeatures::AGENT_CONTROLS`]: crate::MoreDaemonFeatures::AGENT_CONTROLS

use serde::{Deserialize, Serialize};

use crate::ids::{OptionId, PaneId, RequestId};

/// The longest model, mode or effort id a client may ask for.
pub const MAX_AGENT_CONFIG_ID: usize = 128;

/// The longest answer to one question, and the longest feedback on a plan.
pub const MAX_AGENT_ANSWER: usize = 16 * 1024;

/// One entry of a picker.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentChoice {
    /// What the agent is told (`sonnet`, `gpt-5.4`, `plan`, `high`).
    pub id: String,
    /// What the user reads (`Sonnet`, `Plan`).
    pub label: String,
    /// One line about it; may be empty.
    pub detail: String,
}

/// How much a permission mode lets the agent do without asking, for how it is shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgentModeRisk {
    /// Asks before it edits or runs anything.
    Asks,
    /// Plans only; changes nothing.
    Plans,
    /// Edits files without asking; still asks to run commands.
    Edits,
    /// Decides on its own what needs asking.
    Automatic,
    /// Never asks.
    Bypass,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentModeChoice {
    pub choice: AgentChoice,
    pub risk: AgentModeRisk,
}

/// When a configuration change reaches the agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgentConfigTiming {
    /// The agent restarts on the same conversation with the new settings once it is idle.
    Restart,
    /// The agent takes it with the next turn started from Chat.
    NextTurn,
    /// The agent takes it at once (pi through its bridge).
    Now,
}

/// A model, mode and effort; `None` leaves (or reports) that one unknown or unchanged.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentConfigValues {
    pub model: Option<String>,
    pub mode: Option<String>,
    pub effort: Option<String>,
}

/// Whether Chat can change this agent's configuration.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgentConfigSupport {
    Supported,
    /// Why not, for the user ("Start Claude Code from Gudo to change its model.").
    Unsupported(String),
}

/// How full the model's context window is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentContextUsage {
    /// Tokens in use.
    pub used: u64,
    /// The model's window, in tokens.
    pub window: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentConfig {
    pub support: AgentConfigSupport,
    /// What the agent runs with now, as far as the daemon knows.
    pub current: AgentConfigValues,
    /// A change waiting for the agent: the fields that will change.
    pub pending: Option<AgentConfigValues>,
    pub models: Vec<AgentChoice>,
    pub modes: Vec<AgentModeChoice>,
    pub efforts: Vec<AgentChoice>,
    pub timing: AgentConfigTiming,
    /// The context in use, when the agent reports it.
    pub context: Option<AgentContextUsage>,
}

/// One option of a question.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentQuestionOption {
    pub label: String,
    pub description: String,
}

/// One question the agent asks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentQuestion {
    /// A short tag for it (`Auth method`); may be empty.
    pub header: String,
    pub question: String,
    pub options: Vec<AgentQuestionOption>,
    /// Several options may be chosen.
    pub multi_select: bool,
}

/// Questions the agent waits on. Every question may also be answered in the user's own words.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentQuestions {
    /// The request the agent is blocked on.
    pub request_id: RequestId,
    pub questions: Vec<AgentQuestion>,
    /// The option a [`ApprovalRequest::AnswerQuestion`](crate::ApprovalRequest::AnswerQuestion)
    /// decides with.
    pub answer: OptionId,
    /// The option that declines to answer.
    pub skip: OptionId,
}

/// A plan the agent asks to carry out.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentPlan {
    pub request_id: RequestId,
    /// Markdown.
    pub plan: String,
    /// The option that approves it.
    pub approve: OptionId,
    /// The option that keeps planning.
    pub keep_planning: OptionId,
}

/// What the agent asks the user, beyond a permission.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgentPrompt {
    Questions(AgentQuestions),
    Plan(AgentPlan),
}

/// Everything Chat controls for a pane's agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentControls {
    pub pane_id: PaneId,
    pub config: AgentConfig,
    pub prompt: Option<AgentPrompt>,
}

/// The answer to one question: the chosen labels joined by `", "`, or the user's own words.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionAnswer {
    /// The question's full text, as asked.
    pub question: String,
    pub answer: String,
}
