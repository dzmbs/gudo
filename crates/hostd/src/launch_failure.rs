use std::io;

/// Why an agent did not start, in words for the person reading the pane.
pub(super) fn describe(product: &str, program: &str, error: &io::Error) -> String {
    match error.kind() {
        io::ErrorKind::NotFound => format!(
            "{product} is not installed on this host: no `{program}` on the PATH of a login shell."
        ),
        io::ErrorKind::PermissionDenied => {
            format!("{product} cannot be run on this host: `{program}` is not executable.")
        }
        _ => format!("{product} could not start: {error}."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_agent_says_it_is_not_installed() {
        assert_eq!(
            describe("Codex", "codex", &io::Error::from(io::ErrorKind::NotFound)),
            "Codex is not installed on this host: no `codex` on the PATH of a login shell."
        );
        assert_eq!(
            describe(
                "Claude Code",
                "claude",
                &io::Error::from(io::ErrorKind::PermissionDenied)
            ),
            "Claude Code cannot be run on this host: `claude` is not executable."
        );
        assert_eq!(
            describe("Codex", "codex", &io::Error::other("launch refused")),
            "Codex could not start: launch refused."
        );
    }
}
