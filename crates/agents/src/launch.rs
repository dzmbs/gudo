
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
}

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
/// [`brand::PRODUCT_NAME`] made a bare identifier, plus `_drawings`.
///
/// It is valid both as a Claude Code server name (its tools appear as `mcp__<name>__<tool>`)
/// and as a bare TOML key in Codex's `mcp_servers.<name>`.
///
/// # Examples
///
/// ```
/// assert_eq!(agents::mcp_server_name(), "unnamed_drawings");
/// ```
pub fn mcp_server_name() -> String {
    let product: String = brand::PRODUCT_NAME
        .chars()
        .map(|c| match c {
            'a'..='z' | '0'..='9' => c,
            'A'..='Z' => c.to_ascii_lowercase(),
            _ => '_',
        })
        .collect();
    format!("{product}_drawings")
}

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
pub(crate) fn shell_quote(s: &str) -> String {
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
        assert_eq!(mcp_server_name(), "unnamed_drawings");
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
}
