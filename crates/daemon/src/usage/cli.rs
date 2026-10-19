//! The tools' own documented commands, run on the host when their local data is missing or
//!
//! - `claude -p /usage --output-format stream-json --verbose` prints a `usage_report` (no model
//!   call, no tokens; documented as experimental), and `claude auth status --json` names the
//!   plan.
//! - `codex app-server` speaks JSON-RPC on stdio: `initialize`, `initialized`, then
//!   `account/rateLimits/read` (documented; the app-server is labelled experimental).

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use proto::{AgentUsage, UsageSource};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

/// How long one probe may take.
const TIMEOUT: Duration = Duration::from_secs(30);

/// What a probe needs from the host.
#[derive(Debug, Clone)]
pub(crate) struct Env {
    /// The program, found on the panes' `PATH`.
    pub program: PathBuf,
    /// Working directory (`$HOME`).
    pub cwd: PathBuf,
    /// The panes' configured environment, over the daemon's own.
    pub vars: Vec<(String, String)>,
}

impl Env {
    fn command(&self, args: &[&str]) -> Command {
        let mut cmd = Command::new(&self.program);
        cmd.args(args)
            .current_dir(&self.cwd)
            .envs(self.vars.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        cmd
    }

    async fn output(&self, args: &[&str]) -> Result<String, String> {
        let out = tokio::time::timeout(TIMEOUT, self.command(args).output())
            .await
            .map_err(|_| format!("{} did not answer", name(&self.program)))?
            .map_err(|e| format!("could not run {}: {e}", name(&self.program)))?;
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
}

fn name(program: &Path) -> String {
    program
        .file_name()
        .map_or_else(|| "the tool".into(), |n| n.to_string_lossy().into_owned())
}

/// Claude Code's limits from `/usage`, with the plan from `auth status`.
pub(crate) async fn claude(env: &Env) -> Result<AgentUsage, String> {
    let stream = env
        .output(&[
            "-p",
            "/usage",
            "--output-format",
            "stream-json",
            "--verbose",
        ])
        .await?;
    let mut usage = super::claude::from_usage_report(&stream, crate::identity::now_millis())?;
    if let Ok(status) = env.output(&["auth", "status", "--json"]).await {
        usage.plan = super::claude::plan_from_auth_status(&status);
    }
    Ok(usage)
}

/// Codex's limits from its app server.
pub(crate) async fn codex(env: &Env) -> Result<AgentUsage, String> {
    let mut cmd = env.command(&["app-server"]);
    cmd.stdin(Stdio::piped());
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("could not run codex app-server: {e}"))?;
    let mut stdin = child.stdin.take().ok_or("no stdin")?;
    let stdout = child.stdout.take().ok_or("no stdout")?;
    let exchange = async move {
        let messages = [
            json!({"method": "initialize", "id": 1, "params": {
                "clientInfo": {"name": brand::DAEMON_BIN, "title": brand::DAEMON_BIN, "version": env!("CARGO_PKG_VERSION")},
            }}),
            json!({"method": "initialized"}),
            json!({"method": "account/rateLimits/read", "id": 2, "params": {"excludeResetCreditDetails": true}}),
        ];
        for m in messages {
            let mut line = m.to_string();
            line.push('\n');
            stdin
                .write_all(line.as_bytes())
                .await
                .map_err(|_| "codex app-server closed its input")?;
        }
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let Ok(v) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if v.get("id").and_then(Value::as_u64) != Some(2) {
                continue;
            }
            if let Some(err) = v.get("error") {
                let msg = err
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("error");
                return Err(format!("Codex: {msg}"));
            }
            let result = v.get("result").ok_or("Codex answered without a result")?;
            let limits = result
                .get("rateLimits")
                .or_else(|| result.pointer("/rateLimitsByLimitId/codex"))
                .ok_or("Codex reported no plan limits")?;
            return super::codex::snapshot(
                limits,
                Some(crate::identity::now_millis()),
                UsageSource::Cli,
            )
            .ok_or_else(|| "Codex reported no plan limits".to_owned());
        }
        Err("codex app-server ended without answering".to_owned())
    };
    let result = tokio::time::timeout(TIMEOUT, exchange)
        .await
        .unwrap_or_else(|_| Err("codex app-server did not answer".into()));
    let _ = child.kill().await;
    result
}
