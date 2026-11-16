//! A finished turn's final message when the agent's end-of-turn signal left it out, read back
//! from the agent's transcript: Claude Code's session JSONL, or Codex's rollout
//! (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<timestamp>-<thread id>.jsonl`).

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use proto::AgentKind;
use serde_json::Value;

/// How much of a transcript's end is read for the last message.
const TAIL_BYTES: u64 = 4 << 20;

/// Longest final message kept, in characters, as the hooks cut theirs.
const MESSAGE_CHARS: usize = 16 * 1024;

/// Why a finished turn has no final message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MessageUnavailable {
    /// The agent did not send it; its transcript is being read.
    ReadingTranscript,
    /// The agent did not send it and its transcript is unknown.
    NoTranscript,
    /// Its transcript has no final message for the turn.
    NotInTranscript,
    /// The turn was stopped before it answered.
    Cancelled,
    /// The pane closed while the agent was working.
    PaneClosed,
}

impl MessageUnavailable {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ReadingTranscript => "reading_transcript",
            Self::NoTranscript => "no_transcript",
            Self::NotInTranscript => "not_in_transcript",
            Self::Cancelled => "cancelled",
            Self::PaneClosed => "pane_closed",
        }
    }
}

/// A final message found in a transcript, with the offset just past the line holding it.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Found {
    pub message: String,
    pub end: u64,
}

/// The rollout file of Codex thread `thread` under `codex_home`, newest day first.
pub(crate) fn codex_rollout(codex_home: &Path, thread: &str) -> Option<PathBuf> {
    let suffix = format!("-{}.jsonl", thread.to_ascii_lowercase());
    let newest_first = |dir: &Path| -> Vec<PathBuf> {
        let mut entries: Vec<PathBuf> = std::fs::read_dir(dir)
            .map(|entries| {
                entries
                    .filter_map(Result::ok)
                    .map(|entry| entry.path())
                    .collect()
            })
            .unwrap_or_default();
        entries.sort();
        entries.reverse();
        entries
    };
    for year in newest_first(&codex_home.join("sessions")) {
        for month in newest_first(&year) {
            for day in newest_first(&month) {
                let found = newest_first(&day).into_iter().find(|path| {
                    path.file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| name.starts_with("rollout-") && name.ends_with(&suffix))
                });
                if found.is_some() {
                    return found;
                }
            }
        }
    }
    None
}

/// The last turn's final message in `transcript`, if it ends after `after` (where the
/// previous turn's message was found), so a turn not written yet never gets the one before.
pub(crate) fn last_message(kind: AgentKind, transcript: &Path, after: u64) -> Option<Found> {
    let mut file = std::fs::File::open(transcript).ok()?;
    let length = file.metadata().ok()?.len();
    let start = length.saturating_sub(TAIL_BYTES);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut tail = Vec::new();
    file.take(TAIL_BYTES).read_to_end(&mut tail).ok()?;
    let mut end = length;
    for line in tail.rsplit(|&byte| byte == b'\n') {
        // Past the line's newline, where there is one.
        let line_end = (end + 1).min(length);
        end = end.saturating_sub(line.len() as u64 + 1);
        if line_end <= after {
            return None;
        }
        let Ok(entry) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        let step = match kind {
            AgentKind::Codex => codex_step(&entry),
            AgentKind::Claude => claude_step(&entry),
            AgentKind::Pi => return None,
        };
        match step {
            Step::Message(message) => {
                return Some(Found {
                    message: message.chars().take(MESSAGE_CHARS).collect(),
                    end: line_end,
                });
            }
            Step::TurnStart => return None,
            Step::Skip => {}
        }
    }
    None
}

enum Step {
    Message(String),
    TurnStart,
    Skip,
}

fn codex_step(entry: &Value) -> Step {
    let payload = &entry["payload"];
    let text = |value: &Value| {
        value
            .as_str()
            .filter(|text| !text.trim().is_empty())
            .map(str::to_owned)
    };
    match (entry["type"].as_str(), payload["type"].as_str()) {
        (Some("event_msg"), Some("task_complete" | "turn_complete")) => {
            text(&payload["last_agent_message"]).map_or(Step::Skip, Step::Message)
        }
        (Some("event_msg"), Some("task_started" | "turn_started")) => Step::TurnStart,
        (Some("event_msg"), Some("agent_message")) => {
            text(&payload["message"]).map_or(Step::Skip, Step::Message)
        }
        (Some("response_item"), Some("message")) if payload["role"] == "assistant" => {
            joined_text(&payload["content"], "output_text").map_or(Step::Skip, Step::Message)
        }
        (Some("response_item"), Some("message")) if payload["role"] == "user" => Step::TurnStart,
        _ => Step::Skip,
    }
}

fn claude_step(entry: &Value) -> Step {
    let content = &entry["message"]["content"];
    match entry["type"].as_str() {
        Some("assistant") => joined_text(content, "text").map_or(Step::Skip, Step::Message),
        // A prompt, not a tool result coming back.
        Some("user") if content.is_string() => Step::TurnStart,
        _ => Step::Skip,
    }
}

/// The text parts of a message's content, joined.
fn joined_text(content: &Value, part: &str) -> Option<String> {
    let text = content
        .as_array()?
        .iter()
        .filter(|item| item["type"] == part)
        .filter_map(|item| item["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    (!text.trim().is_empty()).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    const THREAD: &str = "0199a213-81c0-7800-8aa1-bbab2a035a53";

    fn write(lines: &[&str]) -> tempfile::NamedTempFile {
        let file = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(file.path(), lines.join("\n") + "\n").unwrap();
        file
    }

    #[test]
    fn codex_answers_come_from_the_turns_completion() {
        let file = write(&[
            r#"{"type":"session_meta","payload":{"id":"x"}}"#,
            r#"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            r#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Looking."}]}}"#,
            r#"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Done: 3 files."}}"#,
        ]);
        let found = last_message(AgentKind::Codex, file.path(), 0).unwrap();
        assert_eq!(found.message, "Done: 3 files.");
        assert_eq!(found.end, std::fs::metadata(file.path()).unwrap().len());
        assert_eq!(last_message(AgentKind::Codex, file.path(), found.end), None);
    }

    #[test]
    fn a_codex_turn_without_a_completion_message_falls_back_to_its_last_reply() {
        let file = write(&[
            r#"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Old."}}"#,
            r#"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            r#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"New."}]}}"#,
            r#"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":null}}"#,
        ]);
        assert_eq!(
            last_message(AgentKind::Codex, file.path(), 0)
                .unwrap()
                .message,
            "New."
        );
    }

    #[test]
    fn a_turn_with_no_reply_does_not_take_the_previous_one() {
        let file = write(&[
            r#"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Old."}}"#,
            r#"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        ]);
        assert_eq!(last_message(AgentKind::Codex, file.path(), 0), None);
    }

    #[test]
    fn claude_answers_are_the_last_assistant_text() {
        let file = write(&[
            r#"{"type":"user","message":{"role":"user","content":"fix it"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed."}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
        ]);
        assert_eq!(
            last_message(AgentKind::Claude, file.path(), 0)
                .unwrap()
                .message,
            "Fixed."
        );
    }

    #[test]
    fn rollouts_are_found_by_thread_id() {
        let home = tempfile::tempdir().unwrap();
        let day = home.path().join("sessions/2026/11/15");
        std::fs::create_dir_all(&day).unwrap();
        let rollout = day.join(format!("rollout-2026-11-15T12-00-00-{THREAD}.jsonl"));
        std::fs::write(&rollout, "").unwrap();
        assert_eq!(codex_rollout(home.path(), THREAD), Some(rollout));
        assert_eq!(codex_rollout(home.path(), "other"), None);
    }
}
