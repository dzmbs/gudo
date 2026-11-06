//! Learning the session id of a Claude Code the user started by hand in a pane, so the pane can
//! `claude --resume` it after a daemon restart. One the daemon launched has its id pinned and
//! reports it through hooks; a hand-started one does neither, so the id comes from:
//!
//! 1. **Arguments** (exact): `--resume <id>`, `-r <id>` or `--session-id <id>`.
//! 2. **Transcript scan** (fallback): the newest transcript written since the agent started in
//!    `<config>/projects/<directory>/<id>.jsonl` that no other pane claimed.

use std::path::Path;
use std::time::SystemTime;

/// Whether `text` is a session id (a UUID).
pub(crate) fn is_session_id(text: &str) -> bool {
    text.len() == 36
        && text.char_indices().all(|(i, character)| match i {
            8 | 13 | 18 | 23 => character == '-',
            _ => character.is_ascii_hexdigit(),
        })
}

/// The session id Claude Code's arguments name, if any.
pub(crate) fn from_argv(argv: &[String]) -> Option<String> {
    let mut arguments = argv.iter().skip(1);
    while let Some(argument) = arguments.next() {
        let value = match argument.split_once('=') {
            Some(("--resume" | "--session-id", value)) => Some(value.to_owned()),
            _ if matches!(argument.as_str(), "--resume" | "-r" | "--session-id") => {
                arguments.next().cloned()
            }
            _ => None,
        };
        if let Some(id) = value.filter(|value| is_session_id(value)) {
            return Some(id.to_ascii_lowercase());
        }
    }
    None
}

/// Claude Code's folder for the transcripts of sessions started in `cwd`.
pub(crate) fn project_dir(config_dir: &Path, cwd: &Path) -> std::path::PathBuf {
    let cwd = cwd.canonicalize().unwrap_or_else(|_| cwd.to_owned());
    let name: String = cwd
        .to_string_lossy()
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character
            } else {
                '-'
            }
        })
        .collect();
    config_dir.join("projects").join(name)
}

/// The newest unclaimed transcript of a session in `cwd` written since `since`.
pub(crate) fn from_transcripts(
    config_dir: &Path,
    cwd: &Path,
    since: SystemTime,
    claimed: &[String],
) -> Option<String> {
    let entries = std::fs::read_dir(project_dir(config_dir, cwd)).ok()?;
    let mut best: Option<(SystemTime, String)> = None;
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        let Some(id) = path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_suffix(".jsonl"))
            .filter(|stem| is_session_id(stem))
            .map(str::to_ascii_lowercase)
        else {
            continue;
        };
        let Ok(modified) = entry.metadata().and_then(|metadata| metadata.modified()) else {
            continue;
        };
        if modified + std::time::Duration::from_secs(2) < since || claimed.contains(&id) {
            continue;
        }
        if best.as_ref().is_none_or(|(newest, _)| modified > *newest) {
            best = Some((modified, id));
        }
    }
    best.map(|(_, id)| id)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "8f0c2a4e-5b1d-4c3e-9a7f-0123456789ab";

    fn argv(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| (*word).to_owned()).collect()
    }

    #[test]
    fn ids_come_from_resume_arguments() {
        assert_eq!(
            from_argv(&argv(&["claude", "--resume", ID])).as_deref(),
            Some(ID)
        );
        assert_eq!(from_argv(&argv(&["claude", "-r", ID])).as_deref(), Some(ID));
        let joined = format!("--session-id={ID}");
        assert_eq!(from_argv(&argv(&["claude", &joined])).as_deref(), Some(ID));
        assert_eq!(from_argv(&argv(&["claude", "--resume"])), None);
        assert_eq!(from_argv(&argv(&["claude", "-r", "notes"])), None);
        assert_eq!(from_argv(&argv(&["claude", ID])), None);
    }

    #[test]
    fn scan_finds_the_newest_unclaimed_transcript_of_the_directory() {
        let config = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        let dir = project_dir(config.path(), work.path());
        std::fs::create_dir_all(&dir).unwrap();
        let since = SystemTime::now() - std::time::Duration::from_secs(5);
        std::fs::write(dir.join(format!("{ID}.jsonl")), "{}\n").unwrap();
        std::fs::write(dir.join("notes.jsonl"), "{}\n").unwrap();
        assert_eq!(
            from_transcripts(config.path(), work.path(), since, &[]).as_deref(),
            Some(ID)
        );
        assert_eq!(
            from_transcripts(config.path(), work.path(), since, &[ID.to_owned()]),
            None
        );
        let later = SystemTime::now() + std::time::Duration::from_secs(60);
        assert_eq!(
            from_transcripts(config.path(), work.path(), later, &[]),
            None
        );
        let elsewhere = tempfile::tempdir().unwrap();
        assert_eq!(
            from_transcripts(config.path(), elsewhere.path(), since, &[]),
            None
        );
    }
}
