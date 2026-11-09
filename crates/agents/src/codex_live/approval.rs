use serde::Deserialize;
use serde_json::Value;

#[cfg(test)]
mod tests;
use std::collections::BTreeMap;

/// Exact request metadata; decisions still require the daemon's signed policy admission.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexApprovalDetails {
    pub command: Option<String>,
    pub cwd: Option<String>,
    pub reason: Option<String>,
    pub available_decisions: Option<Vec<Value>>,
    #[serde(flatten)]
    pub context: BTreeMap<String, Value>,
}

impl CodexApprovalDetails {
    pub fn offers(&self, decision: &str) -> bool {
        self.available_decisions.as_ref().map_or(
            matches!(decision, "accept" | "decline" | "cancel"),
            |decisions| {
                decisions
                    .iter()
                    .any(|value| value.as_str() == Some(decision))
            },
        )
    }

    pub fn is_supported_command(&self) -> bool {
        self.command.is_some()
            && self
                .context
                .get("kind")
                .is_none_or(|kind| kind.as_str() == Some("command"))
            && self.context.keys().all(|key| {
                matches!(
                    key.as_str(),
                    "kind"
                        | "startedAtMs"
                        | "approvalId"
                        | "commandActions"
                        | "environmentId"
                        | "proposedExecpolicyAmendment"
                        | "proposedNetworkPolicyAmendments"
                        | "additionalPermissions"
                        | "networkApprovalContext"
                        | "pluginId"
                        | "scriptPath"
                )
            })
    }

    pub fn is_plain_command(&self) -> bool {
        self.context.get("environmentId").is_none_or(|environment| {
            environment.is_null() || environment.as_str() == Some("local")
        }) && self.context.iter().all(|(key, value)| {
            value.is_null()
                || matches!(
                    key.as_str(),
                    "kind"
                        | "startedAtMs"
                        | "approvalId"
                        | "commandActions"
                        | "environmentId"
                        | "proposedExecpolicyAmendment"
                        | "proposedNetworkPolicyAmendments"
                )
        })
    }

    pub fn is_file_change(&self) -> bool {
        self.command.is_none()
            && self.cwd.is_none()
            && self
                .context
                .keys()
                .all(|key| matches!(key.as_str(), "grantRoot" | "startedAtMs"))
    }

    pub fn denial(&self) -> Option<&'static str> {
        if self.offers("decline") {
            Some("decline")
        } else if self.offers("cancel") {
            Some("cancel")
        } else {
            None
        }
    }

    pub fn summary(&self) -> String {
        let mut context = self.context.clone();
        // These are identities or derived display hints, not additional permissions.
        for field in ["startedAtMs", "approvalId", "commandActions"] {
            context.remove(field);
        }
        serde_json::json!({"command":self.command,"cwd":self.cwd,"reason":self.reason,"context":context}).to_string()
    }
}
