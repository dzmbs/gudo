//! Claude Code's plan limits.
//!
//! - **Status line** (documented, stable; code.claude.com/docs/en/statusline): the JSON on a
//!   status-line command's stdin has `rate_limits.five_hour` / `seven_day` (and a gateway's
//!   `spend_limit`), each `{used_percentage: 0–100, resets_at: Unix seconds}`, for Pro and Max
//!   subscribers after the session's first response. Sessions the daemon launches run
//!   `gudo-hook claude StatusLine` as their status line (which then runs the user's own), so the
//!   daemon sees it.
//! - **`claude -p /usage --output-format stream-json --verbose`** (documented, experimental):
//!   the assistant message's `usage_report.rate_limits.limits[]` rows (`kind` `session` /
//!   `weekly_all` / `weekly_scoped` with `scope.model.display_name`, `percent` 0–100,
//!   `resets_at` RFC 3339). `claude auth status --json` names the plan (`subscriptionType`).
//!
//! The daemon never reads Claude Code's sign-in or calls the undocumented `/api/oauth/usage`.

use std::path::Path;

use proto::{AgentKind, AgentUsage, UnixMillis, UsageSource, UsageWindow};
use serde_json::Value;

use super::{permille, rfc3339_millis, window_name};

const STATE_FILE: &str = "claude-status-line.json";

/// The status line's windows, by key, with their length in minutes.
const STATUS_WINDOWS: [(&str, u32); 2] = [("five_hour", 300), ("seven_day", 10_080)];

/// The limits in a status-line input, received at `now` (Unix ms); `None` when it has none
/// (API-key sessions, before the first response).
pub(crate) fn from_status_line(payload: &Value, now: u64) -> Option<AgentUsage> {
    let limits = payload.get("rate_limits")?;
    let mut windows: Vec<UsageWindow> = STATUS_WINDOWS
        .iter()
        .filter_map(|(key, minutes)| {
            let limit = limits.get(*key)?;
            let used = limit.get("used_percentage")?.as_f64()?;
            Some(UsageWindow {
                name: window_name(*minutes, None),
                minutes: *minutes,
                used_permille: permille(used),
                resets_at: reset(limit.get("resets_at")),
                limited: used >= 100.0,
            })
        })
        .collect();
    if let Some(limit) = limits.get("spend_limit")
        && let Some(used) = limit.get("used_percentage").and_then(Value::as_f64)
    {
        let period = limit.get("period").and_then(Value::as_str).unwrap_or("");
        windows.push(UsageWindow {
            name: format!("{period} spend").trim().to_owned(),
            minutes: 0,
            used_permille: permille(used),
            resets_at: reset(limit.get("resets_at")),
            limited: used >= 100.0,
        });
    }
    if windows.is_empty() {
        return None;
    }
    Some(AgentUsage {
        agent: AgentKind::Claude,
        plan: None,
        windows,
        source: UsageSource::StatusLine,
        as_of: Some(UnixMillis(now)),
        note: None,
    })
}

/// The limits in `/usage`'s stream-json output (one JSON object per line), or why not.
pub(crate) fn from_usage_report(stream: &str, now: u64) -> Result<AgentUsage, String> {
    let mut text = None;
    for line in stream.lines() {
        let Ok(event) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if let Some(report) = event
            .get("message")
            .and_then(|message| message.get("usage_report"))
            .or_else(|| event.get("usage_report"))
            && let Some(limits) = report.get("rate_limits")
            && let Some(usage) = from_limits(limits, now, UsageSource::Cli)
        {
            return Ok(usage);
        }
        if event.get("type").and_then(Value::as_str) == Some("result") {
            text = event
                .get("result")
                .and_then(Value::as_str)
                .map(str::to_owned);
        }
    }
    Err(text
        .map(|text| text.lines().next().unwrap_or("").trim().to_owned())
        .filter(|text| !text.is_empty())
        .unwrap_or_else(|| "Claude Code reported no plan limits".to_owned()))
}

/// A `usage_report.rate_limits`: the `limits[]` rows, else named windows (`five_hour`,
/// `seven_day`, … with `utilization`), which some versions report instead.
pub(crate) fn from_limits(
    rate_limits: &Value,
    now: u64,
    source: UsageSource,
) -> Option<AgentUsage> {
    let mut windows: Vec<UsageWindow> = Vec::new();
    for row in rate_limits
        .get("limits")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(used) = row.get("percent").and_then(Value::as_f64) else {
            continue;
        };
        let scope = row
            .pointer("/scope/model/display_name")
            .and_then(Value::as_str);
        let minutes = match row.get("kind").and_then(Value::as_str) {
            Some("session") => 300,
            Some("weekly_all" | "weekly_scoped") => 10_080,
            _ => match row.get("group").and_then(Value::as_str) {
                Some("session") => 300,
                Some("weekly") => 10_080,
                _ => 0,
            },
        };
        windows.push(UsageWindow {
            name: window_name(minutes, scope),
            minutes,
            used_permille: permille(used),
            resets_at: reset(row.get("resets_at")),
            limited: used >= 100.0
                || row.get("severity").and_then(Value::as_str) == Some("exceeded"),
        });
    }
    if windows.is_empty() {
        for (key, minutes, scope) in [
            ("five_hour", 300, None),
            ("seven_day", 10_080, None),
            ("seven_day_opus", 10_080, Some("Opus")),
            ("seven_day_sonnet", 10_080, Some("Sonnet")),
        ] {
            let Some(limit) = rate_limits.get(key).filter(|limit| limit.is_object()) else {
                continue;
            };
            let Some(used) = limit.get("utilization").and_then(Value::as_f64) else {
                continue;
            };
            windows.push(UsageWindow {
                name: window_name(minutes, scope),
                minutes,
                used_permille: permille(used),
                resets_at: reset(limit.get("resets_at")),
                limited: used >= 100.0,
            });
        }
    }
    if windows.is_empty() {
        return None;
    }
    // Shortest first, the plan-wide weekly before per-model ones.
    windows.sort_by_key(|window| (window.minutes == 0, window.minutes, window.name.len()));
    Some(AgentUsage {
        agent: AgentKind::Claude,
        plan: None,
        windows,
        source,
        as_of: Some(UnixMillis(now)),
        note: None,
    })
}

/// `subscriptionType` from `claude auth status --json`.
pub(crate) fn plan_from_auth_status(json: &str) -> Option<String> {
    let status: Value = serde_json::from_str(json.trim()).ok()?;
    status
        .get("subscriptionType")
        .and_then(Value::as_str)
        .filter(|plan| !plan.is_empty())
        .map(str::to_owned)
}

fn reset(value: Option<&Value>) -> Option<UnixMillis> {
    match value? {
        Value::Number(seconds) => seconds
            .as_f64()
            .map(|seconds| UnixMillis((seconds.max(0.0) * 1000.0) as u64)),
        Value::String(timestamp) => rfc3339_millis(timestamp).map(UnixMillis),
        _ => None,
    }
}

/// The snapshot file of `account` in the usage directory.
fn state_file(dir: &Path, account: &str) -> std::path::PathBuf {
    if account == proto::SYSTEM_ACCOUNT {
        dir.join(STATE_FILE)
    } else {
        dir.join(format!("claude-status-line-{account}.json"))
    }
}

/// The last status-line snapshot of `account` saved in `dir`.
pub(crate) fn load(dir: &Path, account: &str) -> Option<AgentUsage> {
    let text = std::fs::read_to_string(state_file(dir, account)).ok()?;
    let saved: Value = serde_json::from_str(&text).ok()?;
    let mut usage = from_status_line(&saved["payload"], saved["at"].as_u64()?)?;
    usage.plan = saved["plan"].as_str().map(str::to_owned);
    Some(usage)
}

/// Saves a status-line snapshot in `dir` (as the status line's own shape, so [`load`] reads it
/// back the same way).
pub(crate) fn save(dir: &Path, account: &str, usage: &AgentUsage) {
    let mut limits = serde_json::Map::new();
    for window in &usage.windows {
        let key = match window.minutes {
            300 => "five_hour",
            10_080 => "seven_day",
            _ => continue,
        };
        limits.insert(
            key.into(),
            serde_json::json!({
                "used_percentage": f64::from(window.used_permille) / 10.0,
                "resets_at": window.resets_at.map(|resets_at| resets_at.0 / 1000),
            }),
        );
    }
    let doc = serde_json::json!({
        "at": usage.as_of.map_or(0, |as_of| as_of.0),
        "plan": usage.plan,
        "payload": { "rate_limits": limits },
    });
    if let Err(error) =
        crate::fsutil::write_atomic(&state_file(dir, account), doc.to_string().as_bytes())
    {
        tracing::debug!("saving the Claude usage snapshot: {error}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_line_rate_limits() {
        let json: Value = serde_json::from_str(r#"{"session_id":"s","model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}"#).unwrap();
        let usage = from_status_line(&json, 5).unwrap();
        assert_eq!(usage.source, UsageSource::StatusLine);
        assert_eq!(usage.windows[0].name, "5h");
        assert_eq!(usage.windows[0].used_permille, 235);
        assert_eq!(
            usage.windows[0].resets_at,
            Some(UnixMillis(1_738_425_600_000))
        );
        assert_eq!(usage.windows[1].name, "weekly");
        assert_eq!(usage.as_of, Some(UnixMillis(5)));
        assert!(from_status_line(&serde_json::json!({"model": {}}), 5).is_none());
    }

    #[test]
    fn usage_report_rows() {
        let stream = r#"{"type":"system","subtype":"init"}
{"type":"assistant","message":{"model":"<synthetic>","usage_report":{"session":{},"rate_limits":{"limits":[{"kind":"session","group":"session","percent":17,"resets_at":"2026-10-19T19:40:00.280888+00:00","scope":null,"severity":"normal"},{"kind":"weekly_all","group":"weekly","percent":58,"resets_at":"2026-10-23T13:00:00+00:00","scope":null,"severity":"normal"},{"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":"2026-10-23T13:00:00+00:00","scope":{"model":{"display_name":"Fable"}},"severity":"normal"}]}}}}
{"type":"result","result":"Current session: 17% used"}"#;
        let usage = from_usage_report(stream, 9).unwrap();
        let names: Vec<_> = usage
            .windows
            .iter()
            .map(|window| window.name.as_str())
            .collect();
        assert_eq!(names, ["5h", "weekly", "weekly Fable"]);
        assert_eq!(usage.windows[0].used_permille, 170);
        assert_eq!(usage.source, UsageSource::Cli);
        let message = from_usage_report(
            r#"{"type":"result","result":"/usage is only available for subscription plans."}"#,
            9,
        )
        .unwrap_err();
        assert!(message.contains("subscription"));
    }

    #[test]
    fn named_windows() {
        let json: Value = serde_json::from_str(r#"{"five_hour":{"utilization":81.0,"resets_at":"2026-10-19T19:40:00Z"},"seven_day":{"utilization":20},"seven_day_opus":null}"#).unwrap();
        let usage = from_limits(&json, 1, UsageSource::Cli).unwrap();
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].used_permille, 810);
    }

    #[test]
    fn snapshot_survives_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let json: Value = serde_json::from_str(
            r#"{"rate_limits":{"five_hour":{"used_percentage":62,"resets_at":1792410000}}}"#,
        )
        .unwrap();
        let usage = from_status_line(&json, 77).unwrap();
        save(dir.path(), "system", &usage);
        assert_eq!(load(dir.path(), "system"), Some(usage.clone()));
        // Each account keeps its own snapshot.
        assert_eq!(load(dir.path(), "a1b2c3d4"), None);
        save(dir.path(), "a1b2c3d4", &usage);
        assert_eq!(load(dir.path(), "a1b2c3d4"), Some(usage));
        assert_eq!(
            plan_from_auth_status(r#"{"loggedIn":true,"subscriptionType":"max"}"#).as_deref(),
            Some("max")
        );
    }
}
