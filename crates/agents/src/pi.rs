//! pi: launched as itself, with no hooks. The daemon reads its session file for Chat and its
//! own OSC 7501 reports (`app=pi`) for its state. A pi the daemon launches also loads the
//! bridge extension, which streams to the daemon and takes its prompts beside the terminal UI.

use std::ffi::OsString;

use crate::adapter::{AgentAdapter, HookCoverage, HookError};
use crate::event::{AgentKind, Seq};
use crate::launch::{LaunchContext, LaunchMode, LaunchSpec, pane_env};
use crate::manifest::Manifest;
use crate::signal::Signal;

/// The bridge extension's file name in the daemon's state directory.
pub const PI_BRIDGE_FILE: &str = "pi-bridge.js";

/// The bridge extension's source, reading this product's pane variables.
pub fn pi_bridge_extension() -> String {
    include_str!("pi/bridge.js")
        .replace("@PANE_ID@", &brand::env_var("PANE_ID"))
        .replace("@TOKEN@", &brand::env_var("TOKEN"))
        .replace("@SOCK@", &brand::env_var("SOCK"))
        .replace("@ENDPOINT_FILE@", &brand::env_var("ENDPOINT_FILE"))
}

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
    fn the_bridge_reads_this_products_pane_variables() {
        let source = pi_bridge_extension();
        assert!(
            ["@PANE_ID@", "@TOKEN@", "@SOCK@", "@ENDPOINT_FILE@"]
                .iter()
                .all(|placeholder| !source.contains(placeholder))
        );
        assert!(source.contains(&format!("\"{}\"", brand::env_var("TOKEN"))));
        assert!(source.contains("pi_bridge"));
    }

    #[test]
    fn the_bridge_streams_takes_requests_and_reconnects() {
        let node = std::process::Command::new("node").arg("--version").output();
        if !node.is_ok_and(|output| output.status.success()) {
            eprintln!("skipped: node is not installed");
            return;
        }
        let directory = tempfile::tempdir().unwrap();
        let bridge = directory.path().join("bridge.js");
        std::fs::write(&bridge, pi_bridge_extension()).unwrap();
        let socket = directory.path().join("hook.sock");
        let harness = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/pi/bridge-harness.js"
        );
        let output = std::process::Command::new("node")
            .arg(harness)
            .arg(&bridge)
            .arg(&socket)
            .env(brand::env_var("PANE_ID"), "7")
            .env(brand::env_var("TOKEN"), "pane-token")
            .env(brand::env_var("SOCK"), &socket)
            .env_remove(brand::env_var("ENDPOINT_FILE"))
            .output()
            .unwrap();
        assert!(
            output.status.success() && output.stdout == b"ok\n",
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

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
