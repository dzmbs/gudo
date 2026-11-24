//! Codex's model, reasoning effort and approval mode from Chat. Codex takes them per turn, so
//! a change waits for the next turn Chat starts (`turn/start`), and the models are the
//! app-server's own (`model/list`).

use std::sync::Arc;
use std::time::Duration;

use futures_util::SinkExt;
use proto::{
    AgentChoice, AgentConfig, AgentConfigSupport, AgentConfigTiming, AgentConfigValues,
    AgentModeChoice, AgentModeRisk, PaneId,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use tokio_websockets::Message;

use super::{Live, transport::rpc};
use crate::core::{Core, lock};

const MODEL_LIST_WAIT: Duration = Duration::from_secs(5);
const MAX_MODELS: usize = 64;

/// Approval and sandbox presets, as Codex's own `/approvals` names them.
const MODES: [(&str, &str, &str, AgentModeRisk); 3] = [
    (
        "read-only",
        "Read only",
        "Reads files; asks before it edits or runs anything",
        AgentModeRisk::Asks,
    ),
    (
        "auto",
        "Auto",
        "Edits and runs in this folder; asks before going outside it",
        AgentModeRisk::Edits,
    ),
    (
        "full-access",
        "Full access",
        "Edits and runs anything, with network, without asking",
        AgentModeRisk::Bypass,
    ),
];

#[derive(Debug, Clone, PartialEq, Eq)]
struct CodexModel {
    choice: AgentChoice,
    efforts: Vec<AgentChoice>,
    default_effort: Option<String>,
    is_default: bool,
}

/// What Chat knows and wants of a Codex pane's settings.
#[derive(Default)]
pub(crate) struct CodexConfig {
    models: Option<Vec<CodexModel>>,
    loading: bool,
    /// What the last turn Chat started ran with.
    applied: AgentConfigValues,
    pending: Option<AgentConfigValues>,
}

impl CodexConfig {
    fn current_model(&self) -> Option<&CodexModel> {
        let models = self.models.as_ref()?;
        match &self.applied.model {
            Some(id) => models.iter().find(|model| &model.choice.id == id),
            None => models.iter().find(|model| model.is_default),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListedModel {
    model: String,
    #[serde(default)]
    display_name: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    hidden: bool,
    #[serde(default)]
    supported_reasoning_efforts: Vec<ListedEffort>,
    default_reasoning_effort: Option<String>,
    #[serde(default)]
    is_default: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListedEffort {
    reasoning_effort: String,
    #[serde(default)]
    description: String,
}

fn is_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= proto::MAX_AGENT_CONFIG_ID
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "-_.:/".contains(character))
}

fn effort_label(effort: &str) -> String {
    match effort {
        "xhigh" => "Extra high".into(),
        other => {
            let mut characters = other.chars();
            characters.next().map_or_else(String::new, |first| {
                first.to_uppercase().chain(characters).collect()
            })
        }
    }
}

/// The models of a `model/list` reply, without hidden ones.
fn parse_models(reply: &str) -> Option<Vec<CodexModel>> {
    #[derive(Deserialize)]
    struct Reply {
        result: ListResult,
    }
    #[derive(Deserialize)]
    struct ListResult {
        data: Vec<ListedModel>,
    }
    let reply: Reply = serde_json::from_str(reply).ok()?;
    Some(
        reply
            .result
            .data
            .into_iter()
            .filter(|model| !model.hidden && is_id(&model.model))
            .take(MAX_MODELS)
            .map(|model| CodexModel {
                choice: AgentChoice {
                    label: if model.display_name.is_empty() {
                        model.model.clone()
                    } else {
                        model.display_name
                    },
                    id: model.model,
                    detail: model.description,
                },
                efforts: model
                    .supported_reasoning_efforts
                    .into_iter()
                    .filter(|effort| is_id(&effort.reasoning_effort))
                    .map(|effort| AgentChoice {
                        label: effort_label(&effort.reasoning_effort),
                        id: effort.reasoning_effort,
                        detail: effort.description,
                    })
                    .collect(),
                default_effort: model.default_reasoning_effort,
                is_default: model.is_default,
            })
            .collect(),
    )
}

/// What `turn/start` carries for `values`: `model`, `effort`, and the mode's
/// `approvalPolicy` and `sandboxPolicy`.
pub(super) fn turn_overrides(values: &AgentConfigValues) -> Map<String, Value> {
    let mut params = Map::new();
    if let Some(model) = &values.model {
        params.insert("model".into(), model.clone().into());
    }
    if let Some(effort) = &values.effort {
        params.insert("effort".into(), effort.clone().into());
    }
    let policies = match values.mode.as_deref() {
        Some("read-only") => Some(("on-request", json!({"type":"readOnly"}))),
        Some("auto") => Some(("on-request", json!({"type":"workspaceWrite"}))),
        Some("full-access") => Some(("never", json!({"type":"dangerFullAccess"}))),
        _ => None,
    };
    if let Some((approval, sandbox)) = policies {
        params.insert("approvalPolicy".into(), approval.into());
        params.insert("sandboxPolicy".into(), sandbox);
    }
    params
}

impl Live {
    pub(crate) fn config(&self) -> AgentConfig {
        let config = lock(&self.config);
        let current_model = config.current_model();
        AgentConfig {
            support: AgentConfigSupport::Supported,
            current: AgentConfigValues {
                model: config
                    .applied
                    .model
                    .clone()
                    .or_else(|| current_model.map(|model| model.choice.id.clone())),
                mode: config.applied.mode.clone(),
                effort: config
                    .applied
                    .effort
                    .clone()
                    .or_else(|| current_model.and_then(|model| model.default_effort.clone())),
            },
            pending: config.pending.clone(),
            models: config
                .models
                .iter()
                .flatten()
                .map(|model| model.choice.clone())
                .collect(),
            modes: MODES
                .iter()
                .map(|(id, label, detail, risk)| AgentModeChoice {
                    choice: AgentChoice {
                        id: (*id).into(),
                        label: (*label).into(),
                        detail: (*detail).into(),
                    },
                    risk: *risk,
                })
                .collect(),
            efforts: config
                .pending
                .as_ref()
                .and_then(|pending| pending.model.as_ref())
                .and_then(|id| {
                    config
                        .models
                        .iter()
                        .flatten()
                        .find(|model| &model.choice.id == id)
                })
                .or(current_model)
                .map(|model| model.efforts.clone())
                .unwrap_or_default(),
            timing: AgentConfigTiming::NextTurn,
            context: lock(&self.state)
                .projection
                .context()
                .map(|usage| proto::AgentContextUsage {
                    used: usage.used,
                    window: usage.window,
                }),
        }
    }

    pub(crate) fn set_config(&self, change: &AgentConfigValues) {
        let mut config = lock(&self.config);
        crate::agent_config::merge_values(
            config.pending.get_or_insert_with(Default::default),
            change,
        );
    }

    /// The settings the next `turn/start` carries.
    pub(super) fn pending_config(&self) -> Option<AgentConfigValues> {
        lock(&self.config).pending.clone()
    }

    /// A turn started with `values`: they are what Codex runs with now.
    pub(super) fn config_applied(&self, values: &AgentConfigValues) {
        let offered = self.config();
        let notices = {
            let mut config = lock(&self.config);
            let before = config.applied.clone();
            crate::agent_config::merge_values(&mut config.applied, values);
            if config.pending.as_ref() == Some(values) {
                config.pending = None;
            }
            crate::agent_config::change_notices(&offered, &before, &config.applied)
        };
        lock(&self.state).setting_notices(&notices);
    }

    /// Asks the app-server for its models once, on a connection of its own.
    pub(crate) fn load_models(self: &Arc<Self>, core: &Core, pane: PaneId) {
        {
            let mut config = lock(&self.config);
            if config.models.is_some() || config.loading {
                return;
            }
            config.loading = true;
        }
        let Some(server) = lock(&self.process)
            .as_ref()
            .and_then(tokio::process::Child::id)
        else {
            lock(&self.config).loading = false;
            return;
        };
        let path = self.directory.join("server.sock");
        let (source, core) = (Arc::downgrade(self), core.weak());
        tokio::spawn(async move {
            let models = tokio::time::timeout(MODEL_LIST_WAIT, list_models(&path, server))
                .await
                .ok()
                .and_then(Result::ok)
                .and_then(|reply| parse_models(&reply));
            let Some(source) = source.upgrade() else {
                return;
            };
            {
                let mut config = lock(&source.config);
                config.loading = false;
                if models.is_some() {
                    config.models = models;
                }
            }
            if let Some(core) = core.upgrade() {
                crate::agent_config::changed(&core, pane);
            }
        });
    }
}

async fn list_models(path: &std::path::Path, server: u32) -> std::io::Result<String> {
    let mut connection = rpc::connect(path, server).await?;
    connection
        .send(Message::text(
            json!({"id":rpc::REQUEST_ID,"method":"model/list","params":{"limit":MAX_MODELS}})
                .to_string(),
        ))
        .await
        .map_err(std::io::Error::other)?;
    rpc::reply(&mut connection, rpc::REQUEST_ID).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn models_come_from_the_app_server_without_hidden_ones() {
        let reply = json!({"id":2,"result":{"data":[
            {"id":"gpt-5.4","model":"gpt-5.4","displayName":"GPT-5.4","description":"Latest",
             "hidden":false,"isDefault":true,"defaultReasoningEffort":"medium",
             "supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},
                                          {"reasoningEffort":"xhigh","description":"Deep"}]},
            {"id":"old","model":"old","displayName":"Old","description":"","hidden":true,
             "isDefault":false,"defaultReasoningEffort":"low","supportedReasoningEfforts":[]}
        ],"nextCursor":null}})
        .to_string();
        let models = parse_models(&reply).unwrap();
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].choice.id, "gpt-5.4");
        assert_eq!(models[0].choice.label, "GPT-5.4");
        assert_eq!(models[0].efforts[1].label, "Extra high");
        assert!(models[0].is_default);
    }

    #[test]
    fn a_turn_carries_the_model_effort_and_mode() {
        let params = turn_overrides(&AgentConfigValues {
            model: Some("gpt-5.4".into()),
            mode: Some("full-access".into()),
            effort: Some("high".into()),
        });
        assert_eq!(params["model"], "gpt-5.4");
        assert_eq!(params["effort"], "high");
        assert_eq!(params["approvalPolicy"], "never");
        assert_eq!(params["sandboxPolicy"]["type"], "dangerFullAccess");
        assert!(turn_overrides(&AgentConfigValues::default()).is_empty());
    }
}
