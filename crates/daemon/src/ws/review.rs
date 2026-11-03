//! Review notes → an agent prompt: `path:L-L`, the quoted lines, then the note, numbered, in one
//! message the agent can act on.

use proto::ReviewNote;

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
