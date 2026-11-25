//! Whether an agent coming back after a restart has a conversation to resume. Claude Code and
//! Codex name a session as they start but save it only once it has a message, so an agent that
//! was started and never used leaves an id with nothing behind it, and resuming that id fails
//! and drops the pane to its shell. Such an agent starts afresh instead: it had nothing to lose.
//! Where the agent keeps its sessions cannot be told for sure (a shell's rc file may move it),
//! so only a session that is certainly missing starts afresh; any other resume is tried.

use std::path::{Path, PathBuf};

/// What an agent saved of the session a pane would resume.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SavedConversation {
    /// Saved where its resume finds it, or where it would be is unknown.
    Resumable,
    /// Saved by an agent started in this other directory, which resumes it only from there.
    StartedIn(PathBuf),
    /// Never saved.
    Missing,
}

/// Claude Code's session `session`, resumed from `cwd`. `transcript` is the path its hooks
/// named for it, when they did.
pub(crate) fn claude(
    config_dir: &Path,
    transcript: Option<&Path>,
    cwd: &Path,
    session: &str,
) -> SavedConversation {
    let found = transcript
        .filter(|path| path.is_file())
        .map(Path::to_path_buf)
        .or_else(|| crate::claude_session::find_transcript(config_dir, session));
    let Some(found) = found else {
        let knows_where = transcript.is_some() || config_dir.join("projects").is_dir();
        return if knows_where {
            SavedConversation::Missing
        } else {
            SavedConversation::Resumable
        };
    };
    if crate::claude_session::is_filed_under(config_dir, &found, cwd) {
        return SavedConversation::Resumable;
    }
    crate::claude_session::transcript_cwd(&found)
        .filter(|started_in| started_in.as_path() != cwd && started_in.is_dir())
        .map_or(SavedConversation::Resumable, SavedConversation::StartedIn)
}

/// Codex's session `session`. `rollout` is the path its hooks named for it, when they did.
pub(crate) fn codex(codex_home: &Path, rollout: Option<&Path>, session: &str) -> SavedConversation {
    if rollout.is_some_and(Path::is_file) || crate::codex_session::has_rollout(codex_home, session)
    {
        return SavedConversation::Resumable;
    }
    if rollout.is_some() || codex_home.join("sessions").is_dir() {
        SavedConversation::Missing
    } else {
        SavedConversation::Resumable
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "e4ea3b84-6daf-4905-9510-2efcd840fd83";
    const ROLLOUT_ID: &str = "0199a213-81c0-7800-8aa1-bbab2a035a53";

    #[test]
    fn a_claude_session_that_never_wrote_a_transcript_is_missing() {
        let config = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(config.path().join("projects")).unwrap();
        assert_eq!(
            claude(config.path(), None, work.path(), ID),
            SavedConversation::Missing
        );
        let named = crate::claude_session::project_dir(config.path(), work.path())
            .join(format!("{ID}.jsonl"));
        assert_eq!(
            claude(config.path(), Some(&named), work.path(), ID),
            SavedConversation::Missing
        );
    }

    #[test]
    fn a_claude_session_is_resumable_when_its_transcript_is_there_or_its_folder_unknown() {
        let config = tempfile::tempdir().unwrap();
        let work = tempfile::tempdir().unwrap();
        assert_eq!(
            claude(config.path(), None, work.path(), ID),
            SavedConversation::Resumable,
            "no projects folder: Claude Code may keep its sessions elsewhere"
        );
        let folder = crate::claude_session::project_dir(config.path(), work.path());
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join(format!("{ID}.jsonl")), "{}\n").unwrap();
        assert_eq!(
            claude(config.path(), None, work.path(), ID),
            SavedConversation::Resumable
        );
    }

    #[test]
    fn a_claude_session_started_elsewhere_resumes_where_it_started() {
        let config = tempfile::tempdir().unwrap();
        let pane = tempfile::tempdir().unwrap();
        let started = tempfile::tempdir().unwrap();
        let started_in = started.path().canonicalize().unwrap();
        let folder = crate::claude_session::project_dir(config.path(), &started_in);
        std::fs::create_dir_all(&folder).unwrap();
        let transcript = folder.join(format!("{ID}.jsonl"));
        std::fs::write(
            &transcript,
            format!(
                "{{\"type\":\"summary\"}}\n{{\"type\":\"user\",\"cwd\":{}}}\n",
                serde_json::Value::from(started_in.display().to_string())
            ),
        )
        .unwrap();
        assert_eq!(
            claude(config.path(), Some(&transcript), pane.path(), ID),
            SavedConversation::StartedIn(started_in.clone())
        );
        assert_eq!(
            claude(config.path(), None, pane.path(), ID),
            SavedConversation::StartedIn(started_in.clone())
        );
        assert_eq!(
            claude(config.path(), None, &started_in, ID),
            SavedConversation::Resumable
        );
    }

    #[test]
    fn a_codex_session_without_a_rollout_is_missing() {
        let home = tempfile::tempdir().unwrap();
        assert_eq!(
            codex(home.path(), None, ROLLOUT_ID),
            SavedConversation::Resumable,
            "no sessions folder: Codex may keep its sessions elsewhere"
        );
        let day = home.path().join("sessions/2026/11/25");
        std::fs::create_dir_all(&day).unwrap();
        assert_eq!(
            codex(home.path(), None, ROLLOUT_ID),
            SavedConversation::Missing
        );
        std::fs::write(
            day.join(format!(
                "rollout-2026-11-25T10-50-00-{ROLLOUT_ID}.jsonl.zst"
            )),
            "",
        )
        .unwrap();
        assert_eq!(
            codex(home.path(), None, ROLLOUT_ID),
            SavedConversation::Resumable,
            "a compressed rollout still resumes"
        );
    }
}
