//! Chat's agent controls (`proto::agent_control`) for the apps, as JSON strings like the
//! timeline: the model, mode and effort pickers and the question and plan cards.

use client_core::proto;

use crate::approvals::ApprovalError;
use crate::client::DaemonClient;
use crate::on_runtime;
use crate::ws_types::WorkspaceError;

fn encoded<T: serde::Serialize>(value: &T) -> Result<String, proto::WsError> {
    serde_json::to_string(value).map_err(|error| proto::WsError::Failed(error.to_string()))
}

pub(crate) fn encode_controls(controls: &proto::AgentControls) -> String {
    encoded(controls).unwrap_or_default()
}

#[uniffi::export]
impl DaemonClient {
    /// Whether the helper offers agent controls; without it Chat keeps its read-only chips.
    pub fn offers_agent_controls(&self) -> bool {
        self.inner
            .daemon_offers(proto::MoreDaemonFeatures::AGENT_CONTROLS)
    }

    /// The pane's agent controls as JSON; changes follow as `WorkspaceEvent::AgentControls`.
    pub async fn agent_controls_watch(&self, pane_id: u64) -> Result<String, WorkspaceError> {
        self.ws_call(|client| async move {
            encoded(&client.agent_controls_watch(proto::PaneId(pane_id)).await?)
        })
        .await
    }

    pub async fn agent_controls_unwatch(&self, pane_id: u64) -> Result<(), WorkspaceError> {
        self.ws_call(
            |client| async move { client.agent_controls_unwatch(proto::PaneId(pane_id)).await },
        )
        .await
    }

    /// Changes the agent's model, mode or effort (the ones given); returns the controls as JSON.
    pub async fn set_agent_config(
        &self,
        pane_id: u64,
        model: Option<String>,
        mode: Option<String>,
        effort: Option<String>,
    ) -> Result<String, WorkspaceError> {
        let change = proto::AgentConfigValues {
            model,
            mode,
            effort,
        };
        self.ws_call(|client| async move {
            encoded(
                &client
                    .set_agent_config(proto::PaneId(pane_id), change)
                    .await?,
            )
        })
        .await
    }

    /// Answers the agent's questions: `answers_json` is a list of `{question, answer}`.
    ///
    /// # Errors
    ///
    /// [`ApprovalError::Invalid`] for answers that are not that list.
    pub async fn answer_question(
        &self,
        request_id: u64,
        option_id: u32,
        answers_json: String,
    ) -> Result<(), ApprovalError> {
        let answers: Vec<proto::QuestionAnswer> =
            serde_json::from_str(&answers_json).map_err(|error| ApprovalError::Invalid {
                message: error.to_string(),
            })?;
        let core = self.core();
        on_runtime(async move {
            core.answer_question(
                proto::RequestId(request_id),
                proto::OptionId(option_id),
                answers,
            )
            .await
        })
        .await
        .map_err(Into::into)
    }

    /// Refuses a request with a message for the agent, such as what to change in a plan.
    pub async fn refuse_request(
        &self,
        request_id: u64,
        option_id: u32,
        message: String,
    ) -> Result<(), ApprovalError> {
        let core = self.core();
        on_runtime(async move {
            core.refuse(
                proto::RequestId(request_id),
                proto::OptionId(option_id),
                message,
            )
            .await
        })
        .await
        .map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn controls_reach_the_app_with_snake_case_fields_and_tagged_enums() {
        let controls = proto::AgentControls {
            pane_id: proto::PaneId(4),
            config: proto::AgentConfig {
                support: proto::AgentConfigSupport::Unsupported("no".into()),
                current: proto::AgentConfigValues {
                    model: Some("sonnet".into()),
                    mode: None,
                    effort: None,
                },
                pending: None,
                models: vec![],
                modes: vec![proto::AgentModeChoice {
                    choice: proto::AgentChoice {
                        id: "plan".into(),
                        label: "Plan".into(),
                        detail: String::new(),
                    },
                    risk: proto::AgentModeRisk::Plans,
                }],
                efforts: vec![],
                timing: proto::AgentConfigTiming::Restart,
                context: Some(proto::AgentContextUsage {
                    used: 10,
                    window: 100,
                }),
            },
            prompt: Some(proto::AgentPrompt::Plan(proto::AgentPlan {
                request_id: proto::RequestId(9),
                plan: "# P".into(),
                approve: proto::OptionId(0),
                keep_planning: proto::OptionId(1),
            })),
        };
        let value: serde_json::Value = serde_json::from_str(&encode_controls(&controls)).unwrap();
        assert_eq!(value["pane_id"], 4);
        assert_eq!(value["config"]["support"]["Unsupported"], "no");
        assert_eq!(value["config"]["current"]["model"], "sonnet");
        assert_eq!(value["config"]["modes"][0]["risk"], "Plans");
        assert_eq!(value["config"]["timing"], "Restart");
        assert_eq!(value["config"]["context"]["window"], 100);
        assert_eq!(value["prompt"]["Plan"]["keep_planning"], 1);
    }
}
