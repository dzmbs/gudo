use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::path::PathBuf;

/// Private launch bootstrap, never an agent event. Contains secrets: do not log or persist.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CodexPaneEnvironment {
    pub version: u8,
    #[serde(default, skip_serializing_if = "CodexPaneMode::is_native")]
    pub mode: CodexPaneMode,
    pub variables: Vec<(OsString, OsString)>,
    pub cwd: PathBuf,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CodexPaneMode {
    #[default]
    Native,
    Terminal,
}

impl CodexPaneMode {
    fn is_native(&self) -> bool {
        *self == Self::Native
    }
}

/// Legacy launch selected before any native server or conversation exists.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CodexTerminalLaunch {
    pub arguments: Vec<OsString>,
    pub env_remove: Vec<String>,
    pub env_pinned: Vec<(String, OsString)>,
}

pub const CODEX_ENVIRONMENT_LIMIT: usize = 1024 * 1024;
