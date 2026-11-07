pub(super) fn plain_text(text: &str) -> String {
    strip_terminal_controls(text)
}

pub(super) fn output_preview(text: &str) -> String {
    let mut start = text.len().saturating_sub(4096);
    while !text.is_char_boundary(start) {
        start += 1;
    }
    text[start..].to_owned()
}

#[derive(Clone, Copy)]
enum Escape {
    None,
    Start,
    Csi,
    String,
    StringEnd,
}

fn strip_terminal_controls(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut escape = Escape::None;
    for character in text.chars() {
        match escape {
            Escape::None => match character {
                '\u{1b}' => escape = Escape::Start,
                '\u{9b}' => escape = Escape::Csi,
                '\u{9d}' | '\u{90}' => escape = Escape::String,
                '\n' | '\t' => output.push(character),
                '\r' => {
                    if !output.ends_with('\n') {
                        output.push('\n');
                    }
                }
                character if !character.is_control() => output.push(character),
                _ => {}
            },
            Escape::Start => {
                escape = match character {
                    '[' => Escape::Csi,
                    ']' | 'P' | '^' | '_' => Escape::String,
                    _ => Escape::None,
                }
            }
            Escape::Csi => {
                if ('@'..='~').contains(&character) {
                    escape = Escape::None;
                }
            }
            Escape::String => match character {
                '\u{7}' | '\u{9c}' => escape = Escape::None,
                '\u{1b}' => escape = Escape::StringEnd,
                _ => {}
            },
            Escape::StringEnd => {
                escape = if character == '\\' {
                    Escape::None
                } else {
                    Escape::String
                }
            }
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn output_does_not_expose_terminal_control_payloads() {
        assert_eq!(
            plain_text(
                "\u{1b}[31mred\u{1b}[0m \u{1b}]8;;https://example.invalid\u{7}link\u{1b}]8;;\u{1b}\\\u{1b}Psecret\u{1b}\\\n"
            ),
            "red link\n"
        );
        let content: super::super::claude_record::Content = serde_json::from_value(
            json!([{ "type":"text", "text":"first" }, { "type":"image", "data":"hidden" }, { "text":"last" }]),
        ).unwrap();
        assert_eq!(plain_text(&content.joined_text()), "first\nlast");
    }

    #[test]
    fn output_tail_is_bounded_at_a_utf8_boundary() {
        let text = "🦀".repeat(2000);
        let preview = output_preview(&text);
        assert_eq!(preview.len(), 4096);
        assert!(text.ends_with(&preview));
        assert_eq!(output_preview("short"), "short");
    }
}
