//! Learning the session id of a Codex the daemon launched, so the pane can `codex resume` it
//! never reports one, but it writes its transcript to
//! `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`:
//!
//! 1. **Open file** (exact): a process in the pane's tree holds its rollout file open.
//! 2. **Rollout scan** (fallback): the newest rollout created since the launch whose
//!    `session_meta.cwd` is the pane's directory and that no other pane claimed.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::procinfo;

/// The session id named by a rollout file, `rollout-<timestamp>-<uuid>.jsonl`.
fn rollout_id(path: &Path) -> Option<String> {
    let name = path.file_name()?.to_str()?;
    let stem = name.strip_prefix("rollout-")?.strip_suffix(".jsonl")?;
    let id = stem.get(stem.len().checked_sub(36)?..)?;
    let shape = id.len() == 36
        && id.char_indices().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit(),
        });
    shape.then(|| id.to_ascii_lowercase())
}

/// The id of the rollout a process under `root_pid` holds open, if any.
pub(crate) fn from_open_files(root_pid: u32) -> Option<String> {
    procinfo::process_tree(root_pid)
        .into_iter()
        .flat_map(procinfo::open_files)
        .filter(|p| p.components().any(|c| c.as_os_str() == "sessions"))
        .find_map(|p| rollout_id(&p))
}

/// The newest unclaimed rollout under `codex_home` started in `cwd` since `since`.
pub(crate) fn from_rollouts(
    codex_home: &Path,
    cwd: &Path,
    since: SystemTime,
    claimed: &[String],
) -> Option<String> {
    let cwd = cwd.canonicalize().unwrap_or_else(|_| cwd.to_owned());
    let mut best: Option<(SystemTime, String)> = None;
    for dir in day_dirs(&codex_home.join("sessions")) {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.filter_map(Result::ok) {
            let path = entry.path();
            let Some(id) = rollout_id(&path) else {
                continue;
            };
            let Ok(modified) = entry.metadata().and_then(|m| m.modified()) else {
                continue;
            };
            // A little slack for coarse filesystem timestamps.
            if modified + std::time::Duration::from_secs(2) < since || claimed.contains(&id) {
                continue;
            }
            if session_cwd(&path).is_some_and(|c| c.canonicalize().unwrap_or(c) == cwd)
                && best.as_ref().is_none_or(|(t, _)| modified > *t)
            {
                best = Some((modified, id));
            }
        }
    }
    best.map(|(_, id)| id)
}

/// The three most recent `YYYY/MM/DD` directories (sessions crossing midnight, time zones).
fn day_dirs(sessions: &Path) -> Vec<PathBuf> {
    fn newest(dir: &Path, n: usize) -> Vec<PathBuf> {
        let mut names: Vec<PathBuf> = std::fs::read_dir(dir)
            .map(|d| d.filter_map(Result::ok).map(|e| e.path()).collect())
            .unwrap_or_default();
        names.retain(|p| p.is_dir());
        names.sort();
        names.into_iter().rev().take(n).collect()
    }
    newest(sessions, 2)
        .iter()
        .flat_map(|y| newest(y, 2))
        .flat_map(|m| newest(&m, 3))
        .collect()
}

/// `payload.cwd` of the rollout's first line (`{"type":"session_meta","payload":{…}}`).
fn session_cwd(path: &Path) -> Option<PathBuf> {
    use std::io::{BufRead, Read};
    let file = std::fs::File::open(path).ok()?;
    let mut line = String::new();
    std::io::BufReader::new(file)
        .take(1 << 20)
        .read_line(&mut line)
        .ok()?;
    let meta: serde_json::Value = serde_json::from_str(&line).ok()?;
    let payload = meta.get("payload").unwrap_or(&meta);
    payload.get("cwd")?.as_str().map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0199a213-81c0-7800-8aa1-bbab2a035a53";

    #[test]
    fn ids_come_from_rollout_names() {
        let p = Path::new("/h/.codex/sessions/2026/10/18/rollout-2026-10-18T12-00-00-");
        assert_eq!(
            rollout_id(&p.with_file_name(format!("rollout-2026-10-18T12-00-00-{ID}.jsonl")))
                .as_deref(),
            Some(ID)
        );
        assert_eq!(rollout_id(Path::new("/x/rollout-short.jsonl")), None);
        assert_eq!(rollout_id(Path::new("/x/notes.jsonl")), None);
    }

    #[test]
    fn scan_matches_cwd_and_skips_claimed() {
        let home = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let day = home.path().join("sessions/2026/10/18");
        std::fs::create_dir_all(&day).unwrap();
        let write = |id: &str, cwd: &Path| {
            let meta = serde_json::json!({
                "type": "session_meta",
                "payload": { "id": id, "cwd": cwd },
            });
            std::fs::write(
                day.join(format!("rollout-2026-10-18T12-00-00-{id}.jsonl")),
                format!("{meta}\n"),
            )
            .unwrap();
        };
        let since = SystemTime::now() - std::time::Duration::from_secs(5);
        write(ID, work.path());
        write(
            "0199a213-0000-7800-8aa1-bbab2a035a53",
            Path::new("/elsewhere"),
        );
        assert_eq!(
            from_rollouts(home.path(), work.path(), since, &[]).as_deref(),
            Some(ID)
        );
        assert_eq!(
            from_rollouts(home.path(), work.path(), since, &[ID.to_owned()]),
            None
        );
    }
}
