
use std::ffi::OsString;
use std::path::{Path, PathBuf};

use crate::event::{NativeSessionId, PaneId};

/// Daemon facts every launch recipe needs.
#[derive(Debug, Clone)]
pub struct LaunchContext {
    /// The pane the agent runs in.
    pub pane_id: PaneId,
    /// The daemon's hook socket.
    pub socket: PathBuf,
    /// The token hooks present on the socket.
    pub token: String,
    /// The file holding the current socket endpoint, re-read on every hook call so a pane outlives
    /// a daemon restart.
    pub endpoint_file: PathBuf,
    /// The absolute path of the hook shim binary ([`brand::HOOK_BIN`]).
    pub hook_bin: PathBuf,
    /// The daemon's state directory, where support files such as hook settings live.
    pub state_dir: PathBuf,
    /// The working directory to launch in. Resume must use the session's original cwd for agents
    /// that scope sessions by directory.
    pub cwd: PathBuf,
    /// The account the agent runs under.
    pub account: AccountContext,
}

/// Which of the host's accounts an agent runs under (docs/DAEMON.md "Agent accounts").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountContext {
    /// The account's id, exported as `UN_ACCOUNT`.
    pub id: String,
    /// The account's configuration directory, passed as the agent's own variable
    /// (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). `None` is the system account: the pane inherits
    /// whatever the user's environment says, exactly as without accounts.
    pub dir: Option<PathBuf>,
}

impl AccountContext {
    /// The user's own configuration directory.
    pub fn system() -> Self {
        Self {
            id: SYSTEM_ACCOUNT.into(),
            dir: None,
        }
    }
}

/// The id of the account that is the user's own configuration directory.
pub const SYSTEM_ACCOUNT: &str = "system";

/// Variables that outrank an account's own sign-in (an API key or token in the environment wins
/// over `/login` and `codex login`), so they would silently bill another account. They are
/// removed from every agent pane the daemon launches.
pub const CREDENTIAL_VARS: &[&str] = &[
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
    "ANTHROPIC_PROFILE",
    "CODEX_API_KEY",
    "OPENAI_API_KEY",
    "CODEX_ACCESS_TOKEN",
];

/// The variable naming Claude Code's configuration directory.
pub const CLAUDE_DIR_VAR: &str = "CLAUDE_CONFIG_DIR";
/// The variable naming Codex's home.
pub const CODEX_DIR_VAR: &str = "CODEX_HOME";

/// Whether to start a new session or resume one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LaunchMode {
    /// Start a new session, pinning its id when the agent supports that.
    Fresh {
        /// An id minted by the daemon. Agents that cannot pin an id ignore it and report theirs
        /// later.
        session_id: Option<NativeSessionId>,
    },
    /// Resume an existing session.
    Resume {
        /// The agent's id for the session.
        session_id: NativeSessionId,
    },
}

/// A file the daemon must write before spawning, e.g. Claude's hook settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupportFile {
    /// Where to write it.
    pub path: PathBuf,
    /// What to write.
    pub contents: String,
}

/// Everything needed to spawn an agent in a PTY.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchSpec {
    /// The program, looked up on `PATH`.
    pub program: OsString,
    /// Arguments after the program.
    pub args: Vec<OsString>,
    /// Variables to add to the pane's environment.
    pub env: Vec<(String, OsString)>,
    /// The working directory.
    pub cwd: PathBuf,
    /// Files to write first. Writing is idempotent; the contents depend only on the context.
    pub files: Vec<SupportFile>,
    /// Variables removed from the pane's environment, again after the login shell's startup
    /// files ran ([`Self::shell_line`]).
    pub env_remove: Vec<String>,
    /// Variables set after the login shell's startup files ran, so a startup file cannot point
    /// the agent at another account. They appear in the process list: never a secret.
    pub env_pinned: Vec<(String, OsString)>,
}

impl LaunchSpec {
    /// Returns the program and arguments as strings, for display and for
    /// [`SessionInfo::resume_argv`](crate::SessionInfo::resume_argv).
    ///
    /// Non-UTF-8 bytes are replaced, so never spawn from this; use `program` and `args`.
    pub fn display_argv(&self) -> Vec<String> {
        std::iter::once(&self.program)
            .chain(&self.args)
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect()
    }

    /// The POSIX shell line that runs the program: `unset` of [`Self::env_remove`], `export`
    /// of [`Self::env_pinned`], then the command.
    ///
    /// # Examples
    ///
    /// ```
    /// let spec = agents::LaunchSpec {
    ///     program: "claude".into(),
    ///     args: vec!["--resume".into(), "s1".into()],
    ///     env: Vec::new(),
    ///     cwd: "/src".into(),
    ///     files: Vec::new(),
    ///     env_remove: vec!["ANTHROPIC_API_KEY".into()],
    ///     env_pinned: vec![("CLAUDE_CONFIG_DIR".into(), "/s/a b".into())],
    /// };
    /// assert_eq!(
    ///     spec.shell_line(),
    ///     "unset ANTHROPIC_API_KEY; export CLAUDE_CONFIG_DIR='/s/a b'; claude --resume s1"
    /// );
    /// ```
    pub fn shell_line(&self) -> String {
        let mut line = String::new();
        if !self.env_remove.is_empty() {
            line.push_str("unset ");
            line.push_str(&self.env_remove.join(" "));
            line.push_str("; ");
        }
        for (k, v) in &self.env_pinned {
            line.push_str(&format!(
                "export {k}={}; ",
                shell_quote(&v.to_string_lossy())
            ));
        }
        let command: Vec<String> = std::iter::once(&self.program)
            .chain(&self.args)
            .map(|a| shell_quote(&a.to_string_lossy()))
            .collect();
        line.push_str(&command.join(" "));
        line
    }
}

/// The environment rules for an agent whose directory variable is `own` (`CLAUDE_CONFIG_DIR`,
/// `CODEX_HOME`) under `account`: the variables to remove and the ones to set
/// (docs/DAEMON.md "Agent accounts").
///
/// Credential variables and the other agent's directory variable always go. An account's
/// directory is set; the system account keeps the inherited one.
///
/// # Examples
///
/// ```
/// use agents::{AccountContext, account_env};
///
/// let (remove, set) = account_env(&AccountContext::system(), "CODEX_HOME");
/// assert!(remove.iter().any(|v| v == "OPENAI_API_KEY"));
/// assert!(remove.iter().any(|v| v == "CLAUDE_CONFIG_DIR"));
/// assert!(!set.iter().any(|(k, _)| k == "CODEX_HOME"));
/// ```
pub fn account_env(account: &AccountContext, own: &str) -> (Vec<String>, Vec<(String, OsString)>) {
    let other = if own == CLAUDE_DIR_VAR {
        CODEX_DIR_VAR
    } else {
        CLAUDE_DIR_VAR
    };
    let remove = CREDENTIAL_VARS
        .iter()
        .chain([&other])
        .map(|v| (*v).to_owned())
        .collect();
    let mut pinned = vec![(brand::env_var("ACCOUNT"), account.id.clone().into())];
    if let Some(dir) = &account.dir {
        pinned.push((own.to_owned(), dir.clone().into()));
        // The hook shim reads it: Claude may scrub its own variable from hook environments.
        pinned.push((brand::env_var("ACCOUNT_DIR"), dir.clone().into()));
    }
    (remove, pinned)
}

/// Returns the variables every agent pane gets: pane id, socket, token, endpoint file and the hook
/// shim path, named through [`brand::env_var`].
pub fn pane_env(ctx: &LaunchContext) -> Vec<(String, OsString)> {
    vec![
        (brand::env_var("PANE_ID"), ctx.pane_id.as_str().into()),
        (brand::env_var("SOCK"), ctx.socket.clone().into()),
        (brand::env_var("TOKEN"), ctx.token.clone().into()),
        (
            brand::env_var("ENDPOINT_FILE"),
            ctx.endpoint_file.clone().into(),
        ),
        (brand::env_var("HOOK"), ctx.hook_bin.clone().into()),
    ]
}

/// Returns the name agents know the daemon's MCP server by (docs/DAEMON.md §7.12):
/// [`brand::PRODUCT_NAME`] made a bare identifier.
///
/// It is valid both as a Claude Code server name (its tools appear as `mcp__<name>__<tool>`)
/// and as a bare TOML key in Codex's `mcp_servers.<name>`.
///
/// # Examples
///
/// ```
/// assert_eq!(agents::mcp_server_name(), "unnamed");
/// ```
pub fn mcp_server_name() -> String {
    brand::PRODUCT_NAME
        .chars()
        .map(|c| match c {
            'a'..='z' | '0'..='9' => c,
            'A'..='Z' => c.to_ascii_lowercase(),
            _ => '_',
        })
        .collect()
}

/// The name earlier builds registered the server under, when it only served drawings; a user
/// registration under it is removed when registering again.
pub fn legacy_mcp_server_name() -> String {
    format!("{}_drawings", mcp_server_name())
}

/// The MCP server's terminal tools that act (run, type, open, close, start and prompt agents):
/// an agent's own permission prompt asks before each, as it does for its shell tool. The rest
/// only read.
pub const ACTING_TOOLS: &[&str] = &[
    "cmd_run",
    "pane_send",
    "pane_split",
    "tab_new",
    "pane_close",
    "agent_spawn",
    "agent_prompt",
];

/// Returns the hook shim's arguments that run the MCP server for this pane:
/// `mcp --state <state_dir> --pane <pane>`. The shim reads the socket and token from the state
/// directory, so no secret goes on a command line.
pub fn mcp_args(ctx: &LaunchContext) -> Vec<String> {
    vec![
        "mcp".into(),
        "--state".into(),
        ctx.state_dir.to_string_lossy().into_owned(),
        "--pane".into(),
        ctx.pane_id.as_str().into(),
    ]
}

/// Returns the server command an agent's user-wide configuration names, for agents the user
/// starts by hand in a pane: `<hook_bin> mcp --state <state_dir>`. The pane comes from the
/// pane's `UN_PANE_ID`, which every pane has.
pub(crate) fn user_mcp_server(hook_bin: &Path, state_dir: &Path) -> Vec<String> {
    vec![
        hook_bin.to_string_lossy().into_owned(),
        "mcp".into(),
        "--state".into(),
        state_dir.to_string_lossy().into_owned(),
    ]
}

/// Quotes `s` as a TOML basic string.
pub(crate) fn toml_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if c.is_control() => out.push_str(&format!("\\u{:04X}", u32::from(c))),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Quotes `s` for a POSIX shell as one word.
pub fn shell_quote(s: &str) -> String {
    if !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"/._-+=:,@".contains(&b))
    {
        return s.to_owned();
    }
    format!("'{}'", s.replace('\'', r"'\''"))
}

#[cfg(test)]
pub(crate) fn test_context() -> LaunchContext {
    LaunchContext {
        pane_id: PaneId::new("p_9f2"),
        socket: "/run/un/hostd.sock".into(),
        token: "tok".into(),
        endpoint_file: "/state/endpoint".into(),
        hook_bin: "/opt/un/bin/un-hook".into(),
        state_dir: "/state".into(),
        cwd: "/src/app".into(),
        account: AccountContext::system(),
    }
}

#[cfg(test)]
pub(crate) fn work_context() -> LaunchContext {
    LaunchContext {
        account: AccountContext {
            id: "a1b2".into(),
            dir: Some("/state/accounts/claude/a1b2".into()),
        },
        ..test_context()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pane_env_uses_the_brand_prefix() {
        let env = pane_env(&test_context());
        let names: Vec<&str> = env.iter().map(|(k, _)| k.as_str()).collect();
        assert_eq!(
            names,
            [
                "UN_PANE_ID",
                "UN_SOCK",
                "UN_TOKEN",
                "UN_ENDPOINT_FILE",
                "UN_HOOK"
            ]
        );
        assert_eq!(env[0].1, "p_9f2");
    }

    #[test]
    fn mcp_server_runs_the_shim_for_this_pane() {
        assert_eq!(mcp_server_name(), "unnamed");
        assert_eq!(legacy_mcp_server_name(), "unnamed_drawings");
        assert_eq!(
            mcp_args(&test_context()),
            ["mcp", "--state", "/state", "--pane", "p_9f2"]
        );
    }

    #[test]
    fn quotes_for_toml() {
        assert_eq!(
            toml_quote("/opt/un/bin/un-hook"),
            r#""/opt/un/bin/un-hook""#
        );
        assert_eq!(
            toml_quote(r#"/Users/A "B"\C/un-hook"#),
            r#""/Users/A \"B\"\\C/un-hook""#
        );
        assert_eq!(toml_quote("a\nb\u{7f}"), r#""a\nb\u007F""#);
        let weird = "it's \"x\" \\ y\tz é\u{1}";
        let doc: toml::Table = toml::from_str(&format!("k = {}", toml_quote(weird))).unwrap();
        assert_eq!(doc["k"].as_str(), Some(weird));
    }

    #[test]
    fn quotes_for_the_shell() {
        assert_eq!(shell_quote("/opt/un/bin/un-hook"), "/opt/un/bin/un-hook");
        assert_eq!(shell_quote("/Users/A B/un-hook"), "'/Users/A B/un-hook'");
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
        assert_eq!(shell_quote(""), "''");
    }

    fn names(vars: &[(String, OsString)]) -> Vec<&str> {
        vars.iter().map(|(k, _)| k.as_str()).collect()
    }

    /// Every credential that outranks a sign-in goes, for both agents and every account; the
    /// system account sets no directory, so it behaves as before accounts.
    #[test]
    fn credentials_and_the_other_agents_dir_are_always_removed() {
        for own in [CLAUDE_DIR_VAR, CODEX_DIR_VAR] {
            for ctx in [test_context(), work_context()] {
                let (remove, _) = account_env(&ctx.account, own);
                for var in CREDENTIAL_VARS {
                    assert!(remove.iter().any(|r| r == var), "{own}: {var} kept");
                }
                let other = if own == CLAUDE_DIR_VAR {
                    CODEX_DIR_VAR
                } else {
                    CLAUDE_DIR_VAR
                };
                assert!(remove.iter().any(|r| r == other));
                assert!(!remove.iter().any(|r| r == own), "{own} removed");
            }
        }
        let (_, set) = account_env(&test_context().account, CLAUDE_DIR_VAR);
        assert_eq!(names(&set), ["UN_ACCOUNT"]);
        assert_eq!(set[0].1, "system");
        let (_, set) = account_env(&work_context().account, CLAUDE_DIR_VAR);
        assert_eq!(
            names(&set),
            ["UN_ACCOUNT", "CLAUDE_CONFIG_DIR", "UN_ACCOUNT_DIR"]
        );
        assert_eq!(set[1].1, "/state/accounts/claude/a1b2");
    }

    /// The shell line unsets before it exports and quotes every value, so a startup file's
    /// `export ANTHROPIC_API_KEY=…` cannot reach the agent.
    #[test]
    fn shell_line_scrubs_after_startup_files() {
        let (env_remove, env_pinned) = account_env(&work_context().account, CODEX_DIR_VAR);
        let spec = LaunchSpec {
            program: "codex".into(),
            args: vec!["resume".into(), "it's".into()],
            env: Vec::new(),
            cwd: "/".into(),
            files: Vec::new(),
            env_remove,
            env_pinned,
        };
        let line = spec.shell_line();
        assert!(line.starts_with("unset ANTHROPIC_API_KEY "), "{line}");
        assert!(line.contains(" CLAUDE_CONFIG_DIR; "), "{line}");
        assert!(
            line.contains("export CODEX_HOME=/state/accounts/claude/a1b2; "),
            "{line}"
        );
        assert!(line.ends_with(r"; codex resume 'it'\''s'"), "{line}");
    }
}
