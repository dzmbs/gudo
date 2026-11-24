//! Model and thinking-level controls of a connected pi, behind the small interface the
//! agent-configuration requests call for every agent that can change them while it runs.

use std::future::Future;
use std::pin::Pin;

use proto::{PaneId, WsError};

use super::bridge::{self, Request};
use crate::core::Core;

pub(crate) type ConfigFuture = Pin<Box<dyn Future<Output = Result<(), WsError>> + Send>>;

/// One model an agent offers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AgentModel {
    /// What the agent is told to select.
    pub id: String,
    pub label: String,
    /// Whether the model reasons, and so takes an effort level.
    pub reasons: bool,
}

/// What an agent runs with now and what it offers instead.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct AgentConfig {
    pub model: Option<String>,
    pub models: Vec<AgentModel>,
    pub effort: Option<String>,
    pub efforts: Vec<String>,
    /// Context tokens in use and the model's window, when known.
    pub context: Option<(u64, u64)>,
}

/// Changes the model or effort of the agent in a pane while it runs.
pub(crate) trait AgentConfigDriver: Send + Sync {
    fn config(&self, core: &Core, pane: PaneId) -> Result<AgentConfig, WsError>;
    fn set_model(&self, core: &Core, pane: PaneId, model: &str) -> Result<ConfigFuture, WsError>;
    fn set_effort(&self, core: &Core, pane: PaneId, effort: &str) -> Result<ConfigFuture, WsError>;
}

pub(crate) struct PiConfig;

impl PiConfig {
    fn bridge(core: &Core, pane: PaneId) -> Result<std::sync::Arc<bridge::Bridge>, WsError> {
        super::connected(core, pane)
            .map(|(_, bridge)| bridge)
            .ok_or_else(|| {
                WsError::Unavailable(
                    "This pi is not connected to the helper. Change it in Terminal.".into(),
                )
            })
    }
}

/// A pi model id is `provider/id`, as pi names it on its own command line.
fn model_id(model: &bridge::PiModel) -> String {
    format!("{}/{}", model.provider, model.id)
}

impl AgentConfigDriver for PiConfig {
    fn config(&self, core: &Core, pane: PaneId) -> Result<AgentConfig, WsError> {
        let state = Self::bridge(core, pane)?.state();
        let session = state.session.as_ref();
        Ok(AgentConfig {
            model: session
                .and_then(|session| session.model.as_ref())
                .map(model_id),
            models: state
                .models
                .iter()
                .map(|model| AgentModel {
                    id: model_id(model),
                    label: model.label(),
                    reasons: model.reasoning,
                })
                .collect(),
            effort: session.and_then(|session| session.thinking.clone()),
            efforts: session.map_or_else(Vec::new, |session| session.thinking_levels.clone()),
            context: state
                .context
                .and_then(|context| Some((context.tokens?, context.window))),
        })
    }

    fn set_model(&self, core: &Core, pane: PaneId, model: &str) -> Result<ConfigFuture, WsError> {
        let (provider, model) = model
            .split_once('/')
            .ok_or_else(|| WsError::Invalid("a pi model is provider/id".into()))?;
        let reply = Self::bridge(core, pane)?.request(&Request::SetModel { provider, model })?;
        Ok(Box::pin(async move { reply.await.map(drop) }))
    }

    fn set_effort(&self, core: &Core, pane: PaneId, effort: &str) -> Result<ConfigFuture, WsError> {
        let bridge = Self::bridge(core, pane)?;
        let offered = bridge
            .state()
            .session
            .is_some_and(|session| session.thinking_levels.iter().any(|level| level == effort));
        if !offered {
            return Err(WsError::Invalid(
                "this pi model does not offer that thinking level".into(),
            ));
        }
        let reply = bridge.request(&Request::SetThinking { level: effort })?;
        Ok(Box::pin(async move { reply.await.map(drop) }))
    }
}
