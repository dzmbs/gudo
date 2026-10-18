
use std::ffi::OsString;
use std::path::PathBuf;

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
    fn quotes_for_the_shell() {
        assert_eq!(shell_quote("/opt/un/bin/un-hook"), "/opt/un/bin/un-hook");
        assert_eq!(shell_quote("/Users/A B/un-hook"), "'/Users/A B/un-hook'");
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
        assert_eq!(shell_quote(""), "''");
    }
}
