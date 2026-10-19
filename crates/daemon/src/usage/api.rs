//! Claude / Codex sign-in. **Undocumented**: these are the endpoints Claude Code's `/usage`
//! and Codex's `/status` call internally. Only used when a watching client opted in
//! (Settings › Agents), and at most once per [`super::UsageConfig::api_refresh`]. The token is
//! read on the host, sent only to the provider it belongs to, and never leaves the host
//! otherwise.

use std::path::Path;
use std::sync::OnceLock;

use proto::{AgentUsage, UsageSource};
use serde_json::Value;

/// Claude's usage endpoint (`/usage` in Claude Code calls it).
pub(crate) const CLAUDE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
/// Codex's usage endpoint (`backend-client` in Codex calls it).
pub(crate) const CODEX_URL: &str = "https://chatgpt.com/backend-api/wham/usage";

fn http() -> &'static reqwest::Client {
    static HTTP: OnceLock<reqwest::Client> = OnceLock::new();
    HTTP.get_or_init(crate::notifier::http_client)
}

/// Claude's limits from `url` with the sign-in in `<claude_dir>/.credentials.json`.
pub(crate) async fn claude(url: &str, claude_dir: &Path) -> Result<AgentUsage, String> {
    let creds = std::fs::read_to_string(claude_dir.join(".credentials.json")).map_err(|_| {
        "no Claude sign-in file on this host (on a Mac, Claude keeps it in the Keychain, which the helper does not read)".to_owned()
    })?;
    let creds: Value =
        serde_json::from_str(&creds).map_err(|_| "the Claude sign-in file is unreadable")?;
    let oauth = &creds["claudeAiOauth"];
    let token = oauth["accessToken"]
        .as_str()
        .ok_or("Claude is signed in with an API key, which has no plan limits")?;
    let body = get(http()
        .get(url)
        .bearer_auth(token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .header("accept", "application/json"))
    .await?;
    let mut usage =
        super::claude::from_limits(&body, crate::identity::now_millis(), UsageSource::Api)
            .ok_or("the usage endpoint returned no limits")?;
    usage.plan = oauth["subscriptionType"].as_str().map(str::to_owned);
    Ok(usage)
}

/// Codex's limits from `url` with the sign-in in `<codex_home>/auth.json`.
pub(crate) async fn codex(url: &str, codex_home: &Path) -> Result<AgentUsage, String> {
    let auth = std::fs::read_to_string(codex_home.join("auth.json"))
        .map_err(|_| "no Codex sign-in file on this host".to_owned())?;
    let auth: Value =
        serde_json::from_str(&auth).map_err(|_| "the Codex sign-in file is unreadable")?;
    let tokens = &auth["tokens"];
    let token = tokens["access_token"]
        .as_str()
        .ok_or("Codex is signed in with an API key, which has no plan limits")?;
    let mut req = http()
        .get(url)
        .bearer_auth(token)
        .header("accept", "application/json")
        .header("user-agent", "codex-cli");
    if let Some(account) = tokens["account_id"].as_str() {
        req = req.header("ChatGPT-Account-Id", account);
    }
    let body = get(req).await?;
    let limits = body
        .get("rate_limit")
        .or_else(|| body.get("rate_limits"))
        .ok_or("the usage endpoint returned no limits")?;
    let mut usage = super::codex::snapshot(
        limits,
        Some(crate::identity::now_millis()),
        UsageSource::Api,
    )
    .ok_or("the usage endpoint returned no limits")?;
    if usage.plan.is_none() {
        usage.plan = body["plan_type"].as_str().map(str::to_owned);
    }
    if limits["limit_reached"].as_bool() == Some(true) {
        for w in usage.windows.iter_mut().filter(|w| w.used_permille >= 1000) {
            w.limited = true;
        }
    }
    Ok(usage)
}

async fn get(req: reqwest::RequestBuilder) -> Result<Value, String> {
    let resp = req.send().await.map_err(|e| {
        if e.is_timeout() {
            "the usage endpoint did not answer".to_owned()
        } else {
            "could not reach the usage endpoint".to_owned()
        }
    })?;
    let status = resp.status();
    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        return Err(format!(
            "the sign-in was refused ({}); sign in again on the host",
            status.as_u16()
        ));
    }
    if !status.is_success() {
        return Err(format!("the usage endpoint answered {}", status.as_u16()));
    }
    let body = resp
        .bytes()
        .await
        .map_err(|_| "the usage endpoint's answer was cut off".to_owned())?;
    serde_json::from_slice(&body)
        .map_err(|_| "the usage endpoint's answer was unreadable".to_owned())
}
