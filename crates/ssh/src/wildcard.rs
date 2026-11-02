//! `*` / `?` glob matching as in OpenSSH's `match_pattern` (no character classes).

/// Whether `text` matches `pattern`, where `*` is any run of characters and `?` any one.
/// Comparison is exact; callers lower-case host names first.
pub(crate) fn matches(pattern: &str, text: &str) -> bool {
    let pattern: Vec<char> = pattern.chars().collect();
    let text: Vec<char> = text.chars().collect();
    let (mut pattern_pos, mut text_pos) = (0, 0);
    // Position of the last `*` and the text index it was tried at, for backtracking.
    let mut last_star: Option<(usize, usize)> = None;
    while text_pos < text.len() {
        if pattern_pos < pattern.len()
            && (pattern[pattern_pos] == '?' || pattern[pattern_pos] == text[text_pos])
        {
            pattern_pos += 1;
            text_pos += 1;
        } else if pattern_pos < pattern.len() && pattern[pattern_pos] == '*' {
            last_star = Some((pattern_pos, text_pos));
            pattern_pos += 1;
        } else if let Some((star_pos, star_text_pos)) = last_star {
            pattern_pos = star_pos + 1;
            text_pos = star_text_pos + 1;
            last_star = Some((star_pos, star_text_pos + 1));
        } else {
            return false;
        }
    }
    pattern[pattern_pos..].iter().all(|&c| c == '*')
}

#[cfg(test)]
mod tests {
    use super::matches;

    #[test]
    fn globs() {
        assert!(matches("*", ""));
        assert!(matches("*", "anything"));
        assert!(matches("*.corp", "db.corp"));
        assert!(!matches("*.corp", "corp"));
        assert!(matches("h?st", "host"));
        assert!(!matches("h?st", "hoost"));
        assert!(matches("a*b*c", "aXbYbZc"));
        assert!(!matches("a*b*c", "aXbYbZ"));
        assert!(matches("10.0.*.?", "10.0.12.7"));
        assert!(matches("exact", "exact"));
        assert!(!matches("exact", "exactly"));
        assert!(matches("**", "x"));
    }
}
