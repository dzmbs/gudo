use client_core::proto;

use crate::client::DaemonClient;
use crate::ws_types::WorkspaceError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PowerPolicy {
    Always,
    WhenPluggedIn,
    Never,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PowerStatus {
    pub policy: PowerPolicy,
    pub keeping_awake: bool,
}

impl From<PowerPolicy> for proto::PowerPolicy {
    fn from(policy: PowerPolicy) -> Self {
        match policy {
            PowerPolicy::Always => Self::Always,
            PowerPolicy::WhenPluggedIn => Self::WhenPluggedIn,
            PowerPolicy::Never => Self::Never,
        }
    }
}

impl From<proto::PowerStatus> for PowerStatus {
    fn from(status: proto::PowerStatus) -> Self {
        Self {
            policy: match status.policy {
                proto::PowerPolicy::Always => PowerPolicy::Always,
                proto::PowerPolicy::WhenPluggedIn => PowerPolicy::WhenPluggedIn,
                proto::PowerPolicy::Never => PowerPolicy::Never,
            },
            keeping_awake: status.keeping_awake,
        }
    }
}

#[uniffi::export]
impl DaemonClient {
    pub async fn power_settings(
        &self,
        policy: Option<PowerPolicy>,
    ) -> Result<PowerStatus, WorkspaceError> {
        self.ws_call(|client| async move { client.power_settings(policy.map(Into::into)).await })
            .await
    }
}
