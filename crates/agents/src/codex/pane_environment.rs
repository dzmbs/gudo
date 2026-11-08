use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::path::PathBuf;

/// Private launch bootstrap, never an agent event. Contains secrets: do not log or persist.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CodexPaneEnvironment {
    pub version: u8,
    pub variables: Vec<(OsString, OsString)>,
    pub cwd: PathBuf,
}

pub const CODEX_ENVIRONMENT_LIMIT: usize = 1024 * 1024;
