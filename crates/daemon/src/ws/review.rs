//! Review notes → an agent prompt: `path:L-L`, the quoted lines, then the note, numbered, in one
//! message the agent can act on.

use std::time::Duration;

use proto::{InputPayload, PaneId, ReviewNote, WsError};

use crate::core::Core;

const DEFAULT_PREAMBLE: &str = "I reviewed your changes. Please address these notes:";

/// # Examples
///
/// The output for one note on lines 3–4 of `src/main.rs` with a quote:
///
/// ```text
/// I reviewed your changes. Please address these notes:
///
/// 1. src/main.rs:3-4
///    > let x = 1;
///    > let y = 2;
///    Use a const.
/// ```
pub(crate) fn format_prompt(preamble: Option<&str>, notes: &[ReviewNote]) -> String {
    let mut prompt = preamble.unwrap_or(DEFAULT_PREAMBLE).trim_end().to_owned();
    for (index, note) in notes.iter().enumerate() {
        prompt.push_str("\n\n");
        let lines = if note.end_line > note.start_line {
            format!("{}-{}", note.start_line, note.end_line)
        } else {
            note.start_line.to_string()
        };
        let side = if note.old_side { " (old version)" } else { "" };
        prompt.push_str(&format!("{}. {}:{lines}{side}", index + 1, note.path));
        if let Some(quote) = note.quote.as_deref().filter(|text| !text.trim().is_empty()) {
            for line in quote.trim_end_matches('\n').lines() {
                prompt.push_str("\n   > ");
                prompt.extend(line.chars().map(visible));
            }
        }
        for line in note.note.trim().lines() {
            prompt.push_str("\n   ");
            prompt.push_str(line);
        }
    }
    prompt
}

/// Formats `notes` into one prompt, checks it like any prompt and types it into `pane_id`,
/// with Enter when `submit`. With `agent_only` (a sender who may not drive the pane) the pane's
/// agent must hold the terminal at the moment of each write, or nothing is written.
///
/// # Errors
///
/// [`WsError::Invalid`] for no notes or a prompt the check refuses, [`WsError::Denied`] when
/// `agent_only` and no agent holds the terminal, [`WsError::NotFound`] for a pane that is gone.
pub(crate) async fn send(
    core: &Core,
    pane_id: PaneId,
    preamble: Option<&str>,
    notes: &[ReviewNote],
    submit: bool,
    agent_only: bool,
) -> Result<String, WsError> {
    let entry = core
        .pane(pane_id)
        .ok_or_else(|| WsError::NotFound(format!("pane {pane_id}")))?;
    if notes.is_empty() {
        return Err(WsError::Invalid("no notes".into()));
    }
    let prompt = format_prompt(preamble, notes);
    crate::mp::prompt::check_review(&prompt)
        .map_err(|error| WsError::Invalid(error.to_string()))?;
    let agent_holds = || !agent_only || core.agent_has_terminal(pane_id);
    if !agent_holds() {
        return Err(WsError::Denied(
            "review notes from a prompter go to agent panes only".into(),
        ));
    }
    let bytes = entry.pane.encode_input(InputPayload::Paste(prompt.clone()));
    entry
        .pane
        .write(bytes)
        .await
        .map_err(|_| WsError::NotFound(format!("pane {pane_id} exited")))?;
    if submit {
        // Let the agent's input box take the paste before Enter arrives.
        tokio::time::sleep(Duration::from_millis(80)).await;
        if agent_holds() {
            let _ = entry.pane.write(b"\r".to_vec()).await;
        }
    }
    Ok(prompt)
}

/// Quoted code is the file's, not the reviewer's: a stray control character in it is shown,
/// never sent to the agent's terminal.
fn visible(character: char) -> char {
    if character.is_control() && character != '\t' {
        char::REPLACEMENT_CHARACTER
    } else {
        character
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_numbered_notes() {
        let notes = vec![
            ReviewNote {
                path: "src/main.rs".into(),
                start_line: 3,
                end_line: 4,
                old_side: false,
                quote: Some("let x = 1;\nlet y = 2;\n".into()),
                note: "Use a const.".into(),
            },
            ReviewNote {
                path: "README.md".into(),
                start_line: 9,
                end_line: 9,
                old_side: true,
                quote: None,
                note: "Keep this line.\nIt matters.".into(),
            },
        ];
        assert_eq!(
            format_prompt(None, &notes),
            "I reviewed your changes. Please address these notes:\n\n\
             1. src/main.rs:3-4\n   > let x = 1;\n   > let y = 2;\n   Use a const.\n\n\
             2. README.md:9 (old version)\n   Keep this line.\n   It matters."
        );
    }
}
