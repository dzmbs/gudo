//! Auto-approve rules ("approve all like this for this task", [`proto::approve`]): signing,
//! verification, the bounds the daemon accepts, and what a rule matches.
//!
//! A rule is a narrow, short-lived grant to answer "allow once" on a person's behalf:
//!
//! - **Scope:** one pane (the agent's task); the daemon also ends it with the agent session.
//! - **Match:** one tool, and for shell commands one command ([`like_this`]). A shell command
//!   that chains, pipes, redirects, substitutes or expands anything never matches, so
//!   `cargo test && rm -rf ~` is not "like" `cargo test`.
//! - **Limits:** an expiry at most [`MAX_RULE_LIFETIME_MS`] away and at most
//!   [`MAX_RULE_TURNS`] agent turns ([`check_rule`]).
//! - **Proof:** signed by the device that made it ([`sign_auto_approve`]), bound to the daemon.
//!
//! # Examples
//!
//! ```
//! use grants::{DeviceKey, like_this, permits, sign_auto_approve, verify_auto_approve};
//! use proto::{Actor, AutoApproveRule, DaemonId, PaneId, PrincipalId, RuleId, UnixMillis};
//!
//! let daemon = DaemonId([9; 32]);
//! let key = DeviceKey::generate();
//! let matcher = like_this("Bash", "cargo test --workspace").unwrap();
//! assert_eq!(matcher.prefix, "cargo test");
//!
//! let mut rule = AutoApproveRule {
//!     rule_id: RuleId([1; 16]),
//!     pane_id: PaneId(4),
//!     request_id: None,
//!     matcher,
//!     expires_at: UnixMillis(60_000),
//!     max_turns: 3,
//!     actor: Actor { principal: PrincipalId([2; 16]), device: key.device_id() },
//!     sig: Vec::new(),
//! };
//! sign_auto_approve(&key, daemon, &mut rule);
//! assert!(verify_auto_approve(daemon, &rule));
//!
//! let now = UnixMillis(1_000);
//! assert!(permits(&rule, PaneId(4), "Bash", "cargo test -p proto", now, 1));
//! assert!(!permits(&rule, PaneId(4), "Bash", "cargo test; rm -rf ~", now, 1));
//! ```

use proto::{
    AutoApproveRule, DaemonId, MAX_RULE_LIFETIME_MS, MAX_RULE_TURNS, PaneId, RuleMatch, UnixMillis,
};

use crate::{DeviceKey, verify_signature};

/// How far a client's clock may run ahead of the daemon's when it sets an expiry.
pub const CLOCK_SKEW_MS: u64 = 60_000;

/// Tools whose input is a shell command.
const SHELL_TOOLS: &[&str] = &["Bash", "shell", "exec_command", "local_shell"];

/// Programs whose second word is a subcommand: "like `cargo test`" is not "like `cargo
/// publish`".
const SUBCOMMAND_TOOLS: &[&str] = &[
    "bun",
    "cargo",
    "docker",
    "gh",
    "git",
    "go",
    "kubectl",
    "make",
    "npm",
    "npx",
    "pip",
    "pnpm",
    "swift",
    "uv",
    "xcodebuild",
    "yarn",
];

/// Programs a rule never covers: they change who runs the command or run another one.
const NEVER: &[&str] = &[
    "sudo", "su", "doas", "env", "eval", "exec", "xargs", "sh", "bash", "zsh", "fish", "nohup",
    "time", "command", "builtin",
];

/// Whether `tool` runs shell commands.
pub fn is_shell_tool(tool: &str) -> bool {
    SHELL_TOOLS.contains(&tool)
}

/// Whether a shell command is one simple command: nothing that chains, pipes, redirects,
/// runs in the background, substitutes or expands.
fn is_simple_command(input: &str) -> bool {
    !input.chars().any(|c| {
        matches!(
            c,
            ';' | '&' | '|' | '>' | '<' | '`' | '$' | '\n' | '\r' | '(' | ')' | '{' | '}' | '\\'
        )
    })
}

/// A plain word: no option, assignment, glob or quote.
fn is_plain_word(word: &str) -> bool {
    !word.is_empty()
        && !word.starts_with('-')
        && !word.contains(['=', '*', '?', '[', '\'', '"', '~'])
}

/// The rule "approve all like this" would add for a request, or `None` when the request is
/// not one a rule should cover (a compound shell command, `sudo …`, an option where a
/// subcommand belongs).
///
/// Shell commands match on their program, plus the subcommand for programs that have them
/// ([`SUBCOMMAND_TOOLS`]); other tools match on the tool alone.
pub fn like_this(tool: &str, input: &str) -> Option<RuleMatch> {
    if tool.is_empty() {
        return None;
    }
    if !is_shell_tool(tool) {
        return Some(RuleMatch {
            tool: tool.to_owned(),
            prefix: String::new(),
        });
    }
    // Only spaces and tabs are trimmed: a newline anywhere, even a trailing one, is a second
    // command line as far as a rule is concerned.
    let input = trim_blanks(input);
    if !is_simple_command(input) {
        return None;
    }
    let mut words = input.split_whitespace();
    let first = words.next()?;
    if !is_plain_word(first) || NEVER.contains(&first.rsplit('/').next().unwrap_or(first)) {
        return None;
    }
    let mut prefix = first.to_owned();
    if SUBCOMMAND_TOOLS.contains(&first) {
        let sub = words.next()?;
        if !is_plain_word(sub) || sub.contains('/') {
            return None;
        }
        prefix.push(' ');
        prefix.push_str(sub);
    }
    Some(RuleMatch {
        tool: tool.to_owned(),
        prefix,
    })
}

/// Whether a request's `tool` and `input` are covered by `matcher`.
///
/// The input must equal the prefix or continue it after a space (`cargo test` covers `cargo
/// test -p x`, not `cargo testx`), and a shell command must be a simple one.
pub fn rule_matches(matcher: &RuleMatch, tool: &str, input: &str) -> bool {
    if matcher.tool != tool {
        return false;
    }
    if !is_shell_tool(tool) {
        return matcher.prefix.is_empty() || continues(input.trim(), &matcher.prefix);
    }
    let input = trim_blanks(input);
    if matcher.prefix.is_empty() || !is_simple_command(input) {
        return false;
    }
    // Compare word by word, so extra spaces between them do not matter.
    let normalized = input.split_whitespace().collect::<Vec<_>>().join(" ");
    continues(&normalized, &matcher.prefix)
}

/// Spaces and tabs off both ends (never newlines).
fn trim_blanks(input: &str) -> &str {
    input.trim_matches([' ', '\t'])
}

fn continues(input: &str, prefix: &str) -> bool {
    input == prefix
        || input
            .strip_prefix(prefix)
            .is_some_and(|rest| rest.starts_with(' '))
}

/// Why the daemon refuses a rule.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RuleError {
    /// It has already expired.
    #[error("the rule has already expired")]
    Expired,
    /// It lives longer than [`MAX_RULE_LIFETIME_MS`].
    #[error("a rule lives at most 8 hours")]
    TooLong,
    /// It spans no turns or more than [`MAX_RULE_TURNS`].
    #[error("a rule spans 1 to {MAX_RULE_TURNS} turns")]
    Turns,
    /// Its match is wider than a rule may be (no tool, a shell rule for any command, a
    /// compound command).
    #[error("the rule matches too much")]
    TooWide,
    /// The signature is missing or wrong.
    #[error("the rule is not signed by its device")]
    Signature,
}

/// Checks a rule the daemon is asked to add at `now`: bounds, match width, signature.
///
/// # Errors
///
/// The first [`RuleError`] that applies.
pub fn check_rule(
    daemon: DaemonId,
    rule: &AutoApproveRule,
    now: UnixMillis,
) -> Result<(), RuleError> {
    if rule.expires_at <= now {
        return Err(RuleError::Expired);
    }
    if rule.expires_at.0 - now.0 > MAX_RULE_LIFETIME_MS + CLOCK_SKEW_MS {
        return Err(RuleError::TooLong);
    }
    if rule.max_turns == 0 || rule.max_turns > MAX_RULE_TURNS {
        return Err(RuleError::Turns);
    }
    let m = &rule.matcher;
    if m.tool.is_empty()
        || (is_shell_tool(&m.tool)
            && like_this(&m.tool, &m.prefix).is_none_or(|own| !continues(&m.prefix, &own.prefix)))
    {
        return Err(RuleError::TooWide);
    }
    if !verify_auto_approve(daemon, rule) {
        return Err(RuleError::Signature);
    }
    Ok(())
}

/// Whether `rule` answers a request on `pane` for `tool` with `input`, at `now`, after
/// `turns_used` turns (the current one included).
pub fn permits(
    rule: &AutoApproveRule,
    pane: PaneId,
    tool: &str,
    input: &str,
    now: UnixMillis,
    turns_used: u32,
) -> bool {
    rule.pane_id == pane
        && now < rule.expires_at
        && turns_used <= rule.max_turns
        && rule_matches(&rule.matcher, tool, input)
}

/// Signs `rule` with `key` for `daemon`, filling `rule.sig`. `rule.actor.device` must be
/// `key`'s device for the daemon to accept it.
pub fn sign_auto_approve(key: &DeviceKey, daemon: DaemonId, rule: &mut AutoApproveRule) {
    rule.sig = key.sign(&proto::auto_approve_signing_bytes(daemon, rule));
}

/// Whether `rule.sig` is a valid signature by `rule.actor.device` for `daemon`.
pub fn verify_auto_approve(daemon: DaemonId, rule: &AutoApproveRule) -> bool {
    verify_signature(
        rule.actor.device,
        &proto::auto_approve_signing_bytes(daemon, rule),
        &rule.sig,
    )
}

#[cfg(test)]
mod tests {
    use proto::{Actor, PrincipalId, RuleId};

    use super::*;

    const DAEMON: DaemonId = DaemonId([9; 32]);
    const NOW: UnixMillis = UnixMillis(10_000_000);
    const PANE: PaneId = PaneId(4);

    fn rule(key: &DeviceKey, tool: &str, prefix: &str) -> AutoApproveRule {
        let mut rule = AutoApproveRule {
            rule_id: RuleId([1; 16]),
            pane_id: PANE,
            request_id: None,
            matcher: RuleMatch {
                tool: tool.into(),
                prefix: prefix.into(),
            },
            expires_at: UnixMillis(NOW.0 + 3_600_000),
            max_turns: 5,
            actor: Actor {
                principal: PrincipalId([2; 16]),
                device: key.device_id(),
            },
            sig: Vec::new(),
        };
        sign_auto_approve(key, DAEMON, &mut rule);
        rule
    }

    #[test]
    fn like_this_takes_the_program_and_its_subcommand() {
        let m = |tool, input| like_this(tool, input).map(|m| m.prefix);
        assert_eq!(
            m("Bash", "cargo test --workspace").as_deref(),
            Some("cargo test")
        );
        assert_eq!(m("Bash", "  rm -rf build ").as_deref(), Some("rm"));
        assert_eq!(
            m("Bash", "./scripts/ci.sh fast").as_deref(),
            Some("./scripts/ci.sh")
        );
        assert_eq!(m("Edit", "src/main.rs").as_deref(), Some(""));
        // Nothing a rule should cover.
        assert_eq!(m("Bash", "cargo test && rm -rf ~"), None);
        assert_eq!(m("Bash", "sudo rm -rf /"), None);
        assert_eq!(m("Bash", "/usr/bin/env rm x"), None);
        assert_eq!(m("Bash", "git -C repo push"), None);
        assert_eq!(m("Bash", "FOO=1 make"), None);
        assert_eq!(m("Bash", "cargo"), None);
        assert_eq!(m("Bash", ""), None);
        assert_eq!(m("", "x"), None);
    }

    #[test]
    fn matches_on_a_word_boundary() {
        let r = RuleMatch {
            tool: "Bash".into(),
            prefix: "cargo test".into(),
        };
        assert!(rule_matches(&r, "Bash", "cargo test"));
        assert!(rule_matches(&r, "Bash", "cargo   test -p proto"));
        assert!(!rule_matches(&r, "Bash", "cargo testx"));
        assert!(!rule_matches(&r, "Bash", "cargo build"));
        assert!(!rule_matches(&r, "Edit", "cargo test"));
    }

    #[test]
    fn compound_commands_never_match() {
        let r = RuleMatch {
            tool: "Bash".into(),
            prefix: "cargo test".into(),
        };
        for input in [
            "cargo test; rm -rf ~",
            "cargo test && rm -rf ~",
            "cargo test || true",
            "cargo test | sh",
            "cargo test &",
            "cargo test > /etc/passwd",
            "cargo test < x",
            "cargo test `rm x`",
            "cargo test $(rm x)",
            "cargo test $HOME",
            "cargo test\nrm x",
        ] {
            assert!(!rule_matches(&r, "Bash", input), "{input:?} matched");
        }
    }

    #[test]
    fn a_shell_rule_for_any_command_never_matches() {
        let r = RuleMatch {
            tool: "Bash".into(),
            prefix: String::new(),
        };
        assert!(!rule_matches(&r, "Bash", "ls"));
    }

    #[test]
    fn other_tools_match_on_the_tool() {
        let r = RuleMatch {
            tool: "Edit".into(),
            prefix: String::new(),
        };
        assert!(rule_matches(&r, "Edit", "src/lib.rs"));
        assert!(!rule_matches(&r, "Write", "src/lib.rs"));
    }

    #[test]
    fn signatures_bind_the_rule_the_daemon_and_the_device() {
        let key = DeviceKey::generate();
        let good = rule(&key, "Bash", "cargo test");
        assert!(verify_auto_approve(DAEMON, &good));
        assert!(!verify_auto_approve(DaemonId([8; 32]), &good));

        let mut wider = good.clone();
        wider.matcher.prefix = "cargo".into();
        assert!(!verify_auto_approve(DAEMON, &wider));
        let mut longer = good.clone();
        longer.expires_at = UnixMillis(good.expires_at.0 + 1);
        assert!(!verify_auto_approve(DAEMON, &longer));
        let mut moved = good.clone();
        moved.pane_id = PaneId(5);
        assert!(!verify_auto_approve(DAEMON, &moved));
        let mut more = good.clone();
        more.max_turns += 1;
        assert!(!verify_auto_approve(DAEMON, &more));

        // Another device cannot sign for this actor.
        let other = DeviceKey::generate();
        let mut forged = good.clone();
        sign_auto_approve(&other, DAEMON, &mut forged);
        assert!(!verify_auto_approve(DAEMON, &forged));
    }

    #[test]
    fn rules_are_scoped_to_their_pane_time_and_turns() {
        let key = DeviceKey::generate();
        let r = rule(&key, "Bash", "cargo test");
        assert!(permits(&r, PANE, "Bash", "cargo test", NOW, 1));
        assert!(permits(&r, PANE, "Bash", "cargo test", NOW, 5));
        assert!(!permits(&r, PANE, "Bash", "cargo test", NOW, 6));
        assert!(!permits(&r, PaneId(5), "Bash", "cargo test", NOW, 1));
        assert!(!permits(&r, PANE, "Bash", "cargo test", r.expires_at, 1));
        assert!(!permits(&r, PANE, "Edit", "cargo test", NOW, 1));
    }

    #[test]
    fn the_daemon_refuses_rules_beyond_the_caps() {
        let key = DeviceKey::generate();
        assert_eq!(
            check_rule(DAEMON, &rule(&key, "Bash", "cargo test"), NOW),
            Ok(())
        );

        let resign = |mut r: AutoApproveRule| {
            sign_auto_approve(&key, DAEMON, &mut r);
            r
        };
        let mut r = rule(&key, "Bash", "cargo test");
        r.expires_at = NOW;
        assert_eq!(check_rule(DAEMON, &resign(r), NOW), Err(RuleError::Expired));
        let mut r = rule(&key, "Bash", "cargo test");
        r.expires_at = UnixMillis(NOW.0 + MAX_RULE_LIFETIME_MS + CLOCK_SKEW_MS + 1);
        assert_eq!(check_rule(DAEMON, &resign(r), NOW), Err(RuleError::TooLong));
        for turns in [0, MAX_RULE_TURNS + 1] {
            let mut r = rule(&key, "Bash", "cargo test");
            r.max_turns = turns;
            assert_eq!(check_rule(DAEMON, &resign(r), NOW), Err(RuleError::Turns));
        }
        for (tool, prefix) in [("Bash", ""), ("Bash", "a && b"), ("Bash", "sudo"), ("", "")] {
            let r = rule(&key, tool, prefix);
            assert_eq!(
                check_rule(DAEMON, &r, NOW),
                Err(RuleError::TooWide),
                "{tool} {prefix}"
            );
        }
        let mut r = rule(&key, "Bash", "cargo test");
        r.sig[0] ^= 1;
        assert_eq!(check_rule(DAEMON, &r, NOW), Err(RuleError::Signature));
    }
}
