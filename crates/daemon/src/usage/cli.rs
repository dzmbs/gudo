//! The tools' own documented commands, run on the host when their local data is missing or
//! stale, and to read and end an account's sign-in:
//!
//! - `claude -p /usage --output-format stream-json --verbose` prints a `usage_report` (no model
//!   call, no tokens; documented as experimental), and `claude auth status --json` names the
//!   plan and the signed-in account.
//! - `codex app-server` speaks JSON-RPC on stdio: `initialize`, `initialized`, then
//!   `account/rateLimits/read` or `account/read` (documented; the app-server is labelled
//!   experimental).

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
    /// The panes' configured environment, over the daemon's own, then the account's.
    pub vars: Vec<(String, String)>,
    /// Variables removed after `vars`: credentials that would outrank the account's sign-in.
    pub remove: Vec<String>,
}

impl Env {
    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(&self.program);
        command
            .args(args)
            .current_dir(&self.cwd)
            .envs(self.vars.iter().map(|(name, value)| (name, value)))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        for var in &self.remove {
            command.env_remove(var);
        }
        command
    }

    /// Runs the program to its end: whether it succeeded, and its output.
    pub(crate) async fn run(&self, args: &[&str]) -> Result<(bool, String), String> {
        let output = tokio::time::timeout(TIMEOUT, self.command(args).output())
            .await
            .map_err(|_| format!("{} did not answer", name(&self.program)))?
            .map_err(|error| format!("could not run {}: {error}", name(&self.program)))?;
        Ok((
            output.status.success(),
            String::from_utf8_lossy(&output.stdout).into_owned(),
        ))
    }

    async fn output(&self, args: &[&str]) -> Result<String, String> {
        self.run(args).await.map(|(_, stdout)| stdout)
    }
}

fn name(program: &Path) -> String {
    program.file_name().map_or_else(
        || "the tool".into(),
        |file_name| file_name.to_string_lossy().into_owned(),
    )
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
    if let Ok(status) = env.output(agents::ClaudeCode::STATUS).await {
        usage.plan = super::claude::plan_from_auth_status(&status);
    }
    Ok(usage)
}

/// Codex's limits from its app server.
pub(crate) async fn codex(env: &Env) -> Result<AgentUsage, String> {
    let result = app_server(
        env,
        "account/rateLimits/read",
        json!({"excludeResetCreditDetails": true}),
    )
    .await?;
    let limits = result
        .get("rateLimits")
        .or_else(|| result.pointer("/rateLimitsByLimitId/codex"))
        .ok_or("Codex reported no plan limits")?;
    super::codex::snapshot(
        limits,
        Some(crate::identity::now_millis()),
        UsageSource::Cli,
    )
    .ok_or_else(|| "Codex reported no plan limits".to_owned())
}

/// Asks `codex app-server` one JSON-RPC `method` and returns its result.
pub(crate) async fn app_server(env: &Env, method: &str, params: Value) -> Result<Value, String> {
    let mut command = env.command(&["app-server"]);
    command.stdin(Stdio::piped());
    let mut child = command
        .spawn()
        .map_err(|error| format!("could not run codex app-server: {error}"))?;
    let mut stdin = child.stdin.take().ok_or("no stdin")?;
    let stdout = child.stdout.take().ok_or("no stdout")?;
    let exchange = async move {
        let messages = [
            json!({"method": "initialize", "id": 1, "params": {
                "clientInfo": {"name": brand::DAEMON_BIN, "title": brand::DAEMON_BIN, "version": env!("CARGO_PKG_VERSION")},
            }}),
            json!({"method": "initialized"}),
            json!({"method": method, "id": 2, "params": params}),
        ];
        for message in messages {
            let mut line = message.to_string();
            line.push('\n');
            stdin
                .write_all(line.as_bytes())
                .await
                .map_err(|_| "codex app-server closed its input")?;
        }
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let Ok(reply) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if reply.get("id").and_then(Value::as_u64) != Some(2) {
                continue;
            }
            if let Some(error) = reply.get("error") {
                let message = error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("error");
                return Err(format!("Codex: {message}"));
            }
            return reply
                .get("result")
                .cloned()
                .ok_or_else(|| "Codex answered without a result".to_owned());
        }
        Err("codex app-server ended without answering".to_owned())
    };
    let result = tokio::time::timeout(TIMEOUT, exchange)
        .await
        .unwrap_or_else(|_| Err("codex app-server did not answer".into()));
    let _ = child.kill().await;
    result
}
