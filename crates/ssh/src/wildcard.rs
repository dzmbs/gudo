//! `*` / `?` glob matching as in OpenSSH's `match_pattern` (no character classes).

/// Whether `text` matches `pattern`, where `*` is any run of characters and `?` any one.
/// Comparison is exact; callers lower-case host names first.
pub(crate) fn matches(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    let (mut pi, mut ti) = (0, 0);
    // Position of the last `*` and the text index it was tried at, for backtracking.
    let mut star: Option<(usize, usize)> = None;
    while ti < t.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == t[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some((pi, ti));
            pi += 1;
        } else if let Some((sp, st)) = star {
            pi = sp + 1;
            ti = st + 1;
            star = Some((sp, st + 1));
        } else {
            return false;
        }
    }
    p[pi..].iter().all(|&c| c == '*')
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
