//! D9: the options of a blocked agent's dialog, read off the screen, with the keys that pick
//! each one.
//!
//! Claude Code and Codex draw their approval dialogs as numbered menus, optionally inside a
//! box (`│ ❯ 1. Yes │`), the selected row marked with `❯`, `›` or `>`:
//!
//! ```text
//!  Do you want to proceed?
//!  ❯ 1. Yes
//!    2. Yes, and don't ask again for git commands in /repo
//!    3. No, and tell Claude what to do differently (esc)
//! ```
//!
//! A label ending in a key hint, `(y)` or `(esc)`, is picked with that key; otherwise with its
//! number. Hook payloads give exact options; the screen gives the keys.

use proto::BlockedChoice;
use regex::Regex;
use std::sync::LazyLock;

static ITEM: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?P<sel>[❯›>▶➤→]\s*)?(?P<n>[1-9])[.)]\s+(?P<label>\S.*?)\s*$").expect("valid")
});
static HINT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\s*\((?P<key>esc|[a-zA-Z0-9])\)$").expect("valid"));

/// One option of a menu on screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MenuOption {
    /// Label without the key hint.
    pub label: String,
    pub keys: Vec<u8>,
    pub selected: bool,
    pub choice: BlockedChoice,
}

/// Strips a dialog box's borders and padding.
fn clean(line: &str) -> &str {
    line.trim()
        .trim_start_matches(['│', '┃', '|'])
        .trim_end_matches(['│', '┃', '|'])
        .trim()
}

/// The last numbered menu (`1.` … `n.`, at least two options) on `screen`.
pub(crate) fn parse_menu(screen: &str) -> Vec<MenuOption> {
    // (label, selected) per option.
    let mut best: Vec<(String, bool)> = Vec::new();
    let mut current: Vec<(String, bool)> = Vec::new();
    for raw in screen.lines() {
        let line = clean(raw);
        if let Some(c) = ITEM.captures(line) {
            let n: usize = c["n"].parse().unwrap_or(0);
            if n == 1 {
                if current.len() >= 2 {
                    best = std::mem::take(&mut current);
                }
                current.clear();
            }
            if n == current.len() + 1 {
                current.push((c["label"].to_owned(), c.name("sel").is_some()));
                continue;
            }
        }
        // A wrapped label continues on an indented line without a number.
        let inner = raw
            .trim_start()
            .trim_start_matches(['│', '┃', '|'])
            .trim_end()
            .trim_end_matches(['│', '┃', '|']);
        let continues = !current.is_empty()
            && !line.is_empty()
            && inner.starts_with("   ")
            && !line.starts_with(['─', '╰', '╭', '└', '┌']);
        if continues && let Some(last) = current.last_mut() {
            last.0.push(' ');
            last.0.push_str(line);
            continue;
        }
        if current.len() >= 2 {
            best = std::mem::take(&mut current);
        }
        current.clear();
    }
    if current.len() >= 2 {
        best = current;
    }
    best.into_iter()
        .enumerate()
        .map(|(i, (mut label, selected))| {
            let keys = match HINT.captures(&label) {
                Some(h) => {
                    let keys = match &h["key"] {
                        "esc" => vec![0x1b],
                        key => key.as_bytes().to_vec(),
                    };
                    let cut = h.get(0).map_or(label.len(), |m| m.start());
                    label.truncate(cut);
                    keys
                }
                None => (i + 1).to_string().into_bytes(),
            };
            MenuOption {
                choice: classify(&label),
                label,
                keys,
                selected,
            }
        })
        .collect()
}

/// What a label means.
pub(crate) fn classify(label: &str) -> BlockedChoice {
    let l = label.to_lowercase();
    if l.contains("don't ask again")
        || l.contains("do not ask again")
        || l.starts_with("always")
        || l.contains("for this session")
    {
        BlockedChoice::AllowSession
    } else if ["yes", "allow", "proceed", "approve", "accept", "run"]
        .iter()
        .any(|w| l.starts_with(w))
    {
        BlockedChoice::AllowOnce
    } else if ["no", "deny", "reject", "cancel", "decline", "don't"]
        .iter()
        .any(|w| l.starts_with(w))
    {
        BlockedChoice::Deny
    } else {
        BlockedChoice::Other
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_boxed_dialog() {
        let screen = "\
╭──────────────────────────────────────────╮
│ Bash command                             │
│   rm -rf node_modules                    │
│ Do you want to proceed?                  │
│ ❯ 1. Yes                                 │
│   2. Yes, and don't ask again for rm     │
│      commands in /repo                   │
│   3. No, and tell Claude what to do      │
│      differently (esc)                   │
╰──────────────────────────────────────────╯";
        let menu = parse_menu(screen);
        assert_eq!(menu.len(), 3, "{menu:?}");
        assert!(menu[0].selected);
        assert_eq!(menu[0].keys, b"1");
        assert_eq!(menu[0].choice, BlockedChoice::AllowOnce);
        assert_eq!(
            menu[1].label,
            "Yes, and don't ask again for rm commands in /repo"
        );
        assert_eq!(menu[1].choice, BlockedChoice::AllowSession);
        assert_eq!(menu[2].choice, BlockedChoice::Deny);
        assert_eq!(menu[2].keys, b"\x1b");
        assert_eq!(menu[2].label, "No, and tell Claude what to do differently");
    }

    #[test]
    fn codex_key_hints_and_last_menu_wins() {
        let screen = "\
1. old
2. menu
Allow command?
› 1. Yes, proceed (y)
  2. Yes, and don't ask again for this command (a)
  3. No, and tell Codex what to do differently (esc)
";
        let menu = parse_menu(screen);
        assert_eq!(menu.len(), 3);
        assert_eq!(menu[0].label, "Yes, proceed");
        assert_eq!(menu[0].keys, b"y");
        assert_eq!(menu[1].keys, b"a");
        assert_eq!(menu[2].keys, b"\x1b");
        assert_eq!(menu[2].label, "No, and tell Codex what to do differently");
    }

    #[test]
    fn prose_lists_need_two_items_from_one() {
        assert!(parse_menu("Steps:\n3. foo\n4. bar\n").is_empty());
        assert!(parse_menu("1. only one\n").is_empty());
    }
}
