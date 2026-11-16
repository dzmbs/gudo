//! pi: launched as itself, with no hooks. The daemon reads its session file for Chat and its
//! own OSC 7501 reports (`app=pi`) for its state.

use std::ffi::OsString;

use crate::adapter::{AgentAdapter, HookCoverage, HookError};
use crate::event::{AgentKind, Seq};
use crate::launch::{LaunchContext, LaunchMode, LaunchSpec, pane_env};
use crate::manifest::Manifest;
use crate::signal::Signal;

pub struct Pi {
    manifest: Manifest,
}

impl Pi {
    pub fn new() -> Self {
        Self {
            manifest: Manifest::from_toml("id = \"pi\"\nversion = \"2026.11.16.1\"\n")
                .expect("the bundled pi manifest is valid"),
        }
    }
}

impl Default for Pi {
    fn default() -> Self {
        Self::new()
    }
}

impl AgentAdapter for Pi {
    fn kind(&self) -> AgentKind {
        AgentKind::Pi
    }

    fn program_status_app(&self) -> &str {
        "pi"
    }

    fn hook_coverage(&self) -> HookCoverage {
        HookCoverage::Partial
    }

    fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    /// `pi`, or `pi --session <id>`: pi names a fresh session itself.
    fn launch(&self, ctx: &LaunchContext, mode: &LaunchMode) -> LaunchSpec {
        let args: Vec<OsString> = match mode {
            LaunchMode::Resume { session_id } => {
                vec!["--session".into(), session_id.as_str().into()]
            }
            LaunchMode::Fresh { .. } => Vec::new(),
        };
        LaunchSpec {
            program: "pi".into(),
            args,
            env: pane_env(ctx),
            cwd: ctx.cwd.clone(),
            files: Vec::new(),
            env_remove: Vec::new(),
            env_pinned: Vec::new(),
        }
    }

    fn parse_hook(&self, _payload: &[u8], _seq: Seq) -> Result<Option<Signal>, HookError> {
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NativeSessionId;

    #[test]
    fn pi_resumes_with_its_own_flag_and_reports_as_pi() {
        let pi = Pi::new();
        let context = LaunchContext {
            pane_id: crate::PaneId::new("p1"),
            socket: "/run/sock".into(),
            token: "t".into(),
            endpoint_file: "/state/endpoint".into(),
            hook_bin: "/bin/hook".into(),
            state_dir: "/state".into(),
            cwd: "/src".into(),
            account: crate::AccountContext::system(),
        };
        let resume = LaunchMode::Resume {
            session_id: NativeSessionId::new("abc"),
        };
        assert_eq!(
            pi.launch(&context, &resume).display_argv(),
            ["pi", "--session", "abc"]
        );
        let fresh = LaunchMode::Fresh { session_id: None };
        assert_eq!(pi.launch(&context, &fresh).display_argv(), ["pi"]);
        assert!(pi.parse_program_status("state=working:app=pi").is_some());
        assert!(pi.parse_hook(b"{}", Seq(1)).unwrap().is_none());
    }
}
