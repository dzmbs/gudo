//! Codex's rate limits.
//!
//! - **Rollouts** (local, written by Codex): an `event_msg` line with payload type
//!   `token_count` is appended to `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl` after every
//!   model response; when the backend sent rate-limit headers it carries `rate_limits`
//!   (`primary` / `secondary` with `used_percent` 0–100, `window_minutes`, `resets_at` in Unix
//!   seconds — an RFC 3339 string in very old rollouts — and `plan_type`).
//! - **`codex app-server`** (documented JSON-RPC, labelled experimental):
//!   `account/rateLimits/read` → `rateLimits` with `usedPercent`, `windowDurationMins`,
//!   `resetsAt`.
//!
//! The daemon never reads Codex's sign-in (`auth.json`) or calls the undocumented `wham/usage`.
//!
//! Windows are named by their length, never by position: a Pro account's primary window can be
//! the weekly one.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use proto::{AgentKind, AgentUsage, UnixMillis, UsageSource, UsageWindow};
use serde_json::Value;

use super::{permille, rfc3339_millis, window_name};

/// Bytes read from the end of a rollout: token counts follow every response, so the last one
/// is near the end.
const TAIL: u64 = 512 << 10;
/// Day directories looked at, newest first.
const MAX_DAYS: usize = 60;
/// Rollout files looked at, newest first.
const MAX_FILES: usize = 12;

/// The newest rate-limit snapshot in the rollouts under `codex_home`, or `None`.
pub(crate) fn from_rollouts(codex_home: &Path) -> Option<AgentUsage> {
    let sessions = codex_home.join("sessions");
    let mut files: Vec<(SystemTime, PathBuf)> = Vec::new();
    for day in day_dirs(&sessions) {
        let Ok(entries) = std::fs::read_dir(&day) else {
            continue;
        };
        files.extend(
            entries
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .filter(|path| {
                    path.file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| {
                            name.starts_with("rollout-") && name.ends_with(".jsonl")
                        })
                })
                .filter_map(|path| Some((path.metadata().ok()?.modified().ok()?, path))),
        );
        if files.len() >= MAX_FILES {
            break;
        }
    }
    files.sort_by_key(|file| std::cmp::Reverse(file.0));
    files
        .iter()
        .take(MAX_FILES)
        .find_map(|(_, path)| last_snapshot(path))
}

/// `sessions/YYYY/MM/DD` directories, newest first.
fn day_dirs(sessions: &Path) -> Vec<PathBuf> {
    fn children(dir: &Path) -> Vec<PathBuf> {
        let mut names: Vec<PathBuf> = std::fs::read_dir(dir)
            .map(|entries| {
                entries
                    .filter_map(Result::ok)
                    .map(|entry| entry.path())
                    .collect()
            })
            .unwrap_or_default();
        names.retain(|path| path.is_dir());
        names.sort();
        names.reverse();
        names
    }
    children(sessions)
        .iter()
        .flat_map(|year| children(year))
        .flat_map(|month| children(&month))
        .take(MAX_DAYS)
        .collect()
}

/// The last `token_count` line with rate limits in one rollout.
fn last_snapshot(path: &Path) -> Option<AgentUsage> {
    let mut file = File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(len.saturating_sub(TAIL))).ok()?;
    let mut tail = Vec::new();
    file.take(TAIL).read_to_end(&mut tail).ok()?;
    let text = String::from_utf8_lossy(&tail);
    // From the end; the first line may be cut when reading started mid-file.
    text.lines().rev().find_map(|line| {
        if !line.contains("\"rate_limits\"") {
            return None;
        }
        let line: Value = serde_json::from_str(line).ok()?;
        let payload = line.get("payload")?;
        if line.get("type")?.as_str()? != "event_msg"
            || payload.get("type")?.as_str()? != "token_count"
        {
            return None;
        }
        let at = line
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(rfc3339_millis);
        snapshot(payload.get("rate_limits")?, at, UsageSource::LocalLog)
    })
}

/// A rate-limit snapshot in either of Codex's spellings (rollout snake_case, app-server
/// camelCase) as [`AgentUsage`]; `None` when it holds no window or belongs to
/// another limit than the plan's main `codex` one.
pub(crate) fn snapshot(limits: &Value, at: Option<u64>, source: UsageSource) -> Option<AgentUsage> {
    let str_of = |keys: &[&str]| keys.iter().find_map(|key| limits.get(*key)?.as_str());
    if str_of(&["limit_id", "limitId"]).is_some_and(|id| !id.is_empty() && id != "codex") {
        return None;
    }
    let mut windows: Vec<UsageWindow> = ["primary", "secondary"]
        .iter()
        .filter_map(|key| limits.get(*key).filter(|value| value.is_object()))
        .filter_map(|value| window(value, at))
        .collect();
    if windows.is_empty() {
        return None;
    }
    windows.sort_by_key(|window| {
        if window.minutes == 0 {
            u32::MAX
        } else {
            window.minutes
        }
    });
    let plan = str_of(&["plan_type", "planType"])
        .filter(|plan| !plan.is_empty() && *plan != "unknown")
        .map(str::to_owned);
    Some(AgentUsage {
        agent: AgentKind::Codex,
        plan,
        windows,
        source,
        as_of: at.map(UnixMillis),
        note: None,
    })
}

fn window(value: &Value, at: Option<u64>) -> Option<UsageWindow> {
    let number = |keys: &[&str]| keys.iter().find_map(|key| value.get(*key)?.as_f64());
    let used = number(&["used_percent", "usedPercent"])?;
    let minutes = number(&["window_minutes", "windowDurationMins"])
        .map_or(0, |minutes| minutes.clamp(0.0, f64::from(u32::MAX)) as u32);
    let absolute = ["resets_at", "resetsAt"]
        .iter()
        .find_map(|key| match value.get(*key)? {
            Value::Number(seconds) => seconds
                .as_f64()
                .map(|seconds| (seconds.max(0.0) * 1000.0) as u64),
            Value::String(timestamp) => rfc3339_millis(timestamp),
            _ => None,
        });
    let relative = number(&["resets_in_seconds"])
        .and_then(|seconds| Some(at? + (seconds.max(0.0) * 1000.0) as u64));
    Some(UsageWindow {
        name: window_name(minutes, None),
        minutes,
        used_permille: permille(used),
        resets_at: absolute.or(relative).map(UnixMillis),
        limited: used >= 100.0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const LINE: &str = r#"{"timestamp":"2026-10-19T09:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":62.0,"window_minutes":300,"resets_at":1792410000},"secondary":{"used_percent":18.5,"window_minutes":10080,"resets_at":1792900000},"credits":null,"plan_type":"plus"}}}"#;

    #[test]
    fn reads_the_newest_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let day = dir.path().join("sessions/2026/10/19");
        std::fs::create_dir_all(&day).unwrap();
        let older = LINE.replace("62.0", "40.0");
        std::fs::write(
            day.join("rollout-2026-10-19T09-00-00-x.jsonl"),
            format!("{{\"type\":\"session_meta\",\"payload\":{{}}}}\n{older}\n{LINE}\n{{\"type\":\"event_msg\",\"payload\":{{\"type\":\"token_count\",\"rate_limits\":null}}}}\n"),
        )
        .unwrap();
        let usage = from_rollouts(dir.path()).expect("snapshot");
        assert_eq!(usage.plan.as_deref(), Some("plus"));
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].name, "5h");
        assert_eq!(usage.windows[0].used_permille, 620);
        assert_eq!(
            usage.windows[0].resets_at,
            Some(UnixMillis(1_792_410_000_000))
        );
        assert_eq!(usage.windows[1].name, "weekly");
        assert_eq!(usage.windows[1].used_permille, 185);
        assert_eq!(usage.as_of, Some(UnixMillis(1_792_402_200_000)));
        assert_eq!(usage.source, UsageSource::LocalLog);
    }

    #[test]
    fn legacy_iso_resets_and_limit_reached() {
        let line = r#"{"timestamp":"2026-10-19T09:30:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100.0,"window_minutes":300,"resets_at":"2026-10-19T09:40:00Z"},"secondary":null}}}"#;
        let dir = tempfile::tempdir().unwrap();
        let day = dir.path().join("sessions/2026/10/19");
        std::fs::create_dir_all(&day).unwrap();
        std::fs::write(day.join("rollout-a.jsonl"), format!("{line}\n")).unwrap();
        let usage = from_rollouts(dir.path()).unwrap();
        assert_eq!(usage.windows.len(), 1);
        assert!(usage.windows[0].limited);
        assert_eq!(
            usage.windows[0].resets_at,
            Some(UnixMillis(1_792_402_800_000))
        );
        assert_eq!(usage.plan, None);
    }

    #[test]
    fn app_server_shape() {
        let app: Value = serde_json::from_str(r#"{"limitId":"codex","primary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1735689720},"secondary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":1735693200},"planType":"pro"}"#).unwrap();
        let usage = snapshot(&app, Some(1), UsageSource::Cli).unwrap();
        // Ordered by length, not position.
        assert_eq!(usage.windows[0].name, "5h");
        assert_eq!(usage.windows[1].name, "weekly");
        assert_eq!(usage.windows[1].used_permille, 420);
        assert_eq!(usage.plan.as_deref(), Some("pro"));
        assert_eq!(
            usage.windows[1].resets_at,
            Some(UnixMillis(1_735_689_720_000))
        );
        let other: Value =
            serde_json::from_str(r#"{"limitId":"codex_other","primary":{"usedPercent":88}}"#)
                .unwrap();
        assert!(snapshot(&other, None, UsageSource::Cli).is_none());
    }

    #[test]
    fn nothing_without_rollouts() {
        let dir = tempfile::tempdir().unwrap();
        assert!(from_rollouts(dir.path()).is_none());
    }
}
