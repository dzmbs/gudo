use std::ffi::OsString;
use std::path::Path;

use super::{Codex, NOTIFICATION_OVERRIDES, mcp_overrides};
use crate::launch::{CODEX_DIR_VAR, LaunchContext, LaunchMode, LaunchSpec, account_env, pane_env};
use crate::launch::{mcp_server_name, toml_quote};

/// Pane-owned server and its official remote TUI; neither recipe changes user configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexLiveLaunch {
    pub server: LaunchSpec,
    pub tui: LaunchSpec,
}

/// The server and correlation relay require distinct absolute UTF-8 Unix socket paths.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidCodexSocket;

impl std::fmt::Display for InvalidCodexSocket {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Codex requires distinct absolute UTF-8 Unix socket paths")
    }
}

impl std::error::Error for InvalidCodexSocket {}

impl Codex {
    /// Builds a separate app-server for this pane, keeping notify owned by the user's config.
    ///
    /// The daemon must supply the resolved pane environment to both processes, then apply removals,
    /// additions and account pins. Server lifetime belongs to the launch, not a Chat subscription.
    /// The distinct TUI socket belongs to the daemon's physical-connection correlation relay.
    ///
    /// # Errors
    /// Returns an error for identical, relative, non-UTF-8 or control-bearing socket paths.
    pub fn live_launch(
        context: &LaunchContext,
        mode: &LaunchMode,
        server_socket: &Path,
        tui_socket: &Path,
    ) -> Result<CodexLiveLaunch, InvalidCodexSocket> {
        if server_socket == tui_socket {
            return Err(InvalidCodexSocket);
        }
        let server_endpoint = endpoint(server_socket)?;
        let tui_endpoint = endpoint(tui_socket)?;
        let mut server = spec(context);
        server.args = mcp_overrides(context)
            .into_iter()
            .chain(std::iter::once(mcp_environment(context)))
            .flat_map(|setting| [OsString::from("-c"), setting.into()])
            .chain([
                "app-server".into(),
                "--listen".into(),
                server_endpoint.into(),
            ])
            .collect();
        let mut tui = spec(context);
        tui.args = vec!["--remote".into(), tui_endpoint.into()];
        for setting in NOTIFICATION_OVERRIDES {
            tui.args.extend(["-c".into(), setting.into()]);
        }
        if let LaunchMode::Resume { session_id } = mode {
            tui.args
                .extend(["resume".into(), session_id.as_str().into()]);
        }
        Ok(CodexLiveLaunch { server, tui })
    }
}

fn endpoint(socket: &Path) -> Result<String, InvalidCodexSocket> {
    match socket.to_str() {
        Some(path) if socket.is_absolute() && !path.chars().any(char::is_control) => {
            Ok(format!("unix://{path}"))
        }
        _ => Err(InvalidCodexSocket),
    }
}

fn mcp_environment(context: &LaunchContext) -> String {
    let (_, account) = account_env(&context.account, CODEX_DIR_VAR);
    let mut names: Vec<String> = pane_env(context)
        .into_iter()
        .map(|(name, _)| name)
        .collect();
    names.extend(account.into_iter().map(|(name, _)| name));
    names.extend([brand::DAEMON_PID_ENV.into(), CODEX_DIR_VAR.into()]);
    names.sort();
    names.dedup();
    let names = names
        .iter()
        .map(|name| toml_quote(name))
        .collect::<Vec<_>>();
    format!(
        "mcp_servers.{}.env_vars=[{}]",
        mcp_server_name(),
        names.join(",")
    )
}

fn spec(context: &LaunchContext) -> LaunchSpec {
    let (env_remove, env_pinned) = account_env(&context.account, CODEX_DIR_VAR);
    LaunchSpec {
        program: "codex".into(),
        args: Vec::new(),
        env: pane_env(context),
        cwd: context.cwd.clone(),
        files: Vec::new(),
        env_remove,
        env_pinned,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NativeSessionId;

    #[test]
    fn mcp_is_configured_on_the_server_and_notify_is_not_overridden() {
        let context = crate::launch::work_context();
        let launch = Codex::live_launch(
            &context,
            &LaunchMode::Fresh { session_id: None },
            Path::new("/s/server.sock"),
            Path::new("/s/pane.sock"),
        )
        .unwrap();
        let server = launch.server.display_argv();
        let tui = launch.tui.display_argv();
        assert!(
            server
                .iter()
                .any(|argument| argument.starts_with("mcp_servers."))
        );
        assert!(server.iter().any(|argument| argument == "app-server"));
        assert_eq!(&tui[1..3], ["--remote", "unix:///s/pane.sock"]);
        for recipe in [&launch.server, &launch.tui] {
            assert!(
                !recipe
                    .display_argv()
                    .iter()
                    .any(|argument| argument.starts_with("notify="))
            );
            assert!(!recipe.shell_line().contains(&context.token));
            assert!(recipe.files.is_empty());
            assert!(
                recipe
                    .env
                    .iter()
                    .any(|(name, value)| name == &brand::env_var("TOKEN")
                        && value == context.token.as_str())
            );
            assert!(
                recipe
                    .env_pinned
                    .iter()
                    .any(|(name, _)| name == "CODEX_HOME")
            );
            assert!(
                recipe
                    .env_remove
                    .iter()
                    .any(|name| name == "OPENAI_API_KEY")
            );
        }
        assert_eq!(launch.server.env, launch.tui.env);
        assert_eq!(launch.server.env_pinned, launch.tui.env_pinned);
    }

    #[test]
    fn mcp_inherits_pane_identity_by_name_without_token_values_in_arguments() {
        let context = crate::launch::work_context();
        let setting = mcp_environment(&context);
        let document: toml::Table = toml::from_str(&setting).unwrap();
        let names = document["mcp_servers"][mcp_server_name()]["env_vars"]
            .as_array()
            .unwrap();
        for name in [
            brand::env_var("PANE_ID"),
            brand::env_var("TOKEN"),
            brand::env_var("ACCOUNT_DIR"),
            "CODEX_HOME".into(),
            brand::DAEMON_PID_ENV.into(),
        ] {
            assert!(
                names.iter().any(|value| value.as_str() == Some(&name)),
                "missing {name}"
            );
        }
        assert!(!setting.contains(&context.token));
        assert!(
            !names
                .iter()
                .any(|value| value.as_str() == Some("OPENAI_API_KEY"))
        );
        if brand::IS_DEV {
            assert!(
                !names
                    .iter()
                    .any(|value| value.as_str() == Some("GUDO_TOKEN"))
            );
        }
    }

    #[test]
    fn resume_is_a_tui_choice_not_a_second_server_turn() {
        let launch = Codex::live_launch(
            &crate::launch::test_context(),
            &LaunchMode::Resume {
                session_id: NativeSessionId::new("existing"),
            },
            Path::new("/s/server.sock"),
            Path::new("/s/pane.sock"),
        )
        .unwrap();
        assert!(
            launch
                .tui
                .display_argv()
                .ends_with(&["resume".into(), "existing".into()])
        );
        assert!(
            !launch
                .server
                .display_argv()
                .iter()
                .any(|argument| argument == "resume")
        );
        assert!(
            !launch
                .server
                .env_pinned
                .iter()
                .any(|(name, _)| name == "CODEX_HOME")
        );
    }

    #[test]
    fn panes_sharing_an_account_do_not_share_launch_identity() {
        let first = crate::launch::work_context();
        let mut second = first.clone();
        second.pane_id = crate::PaneId::new("another-pane");
        second.token = "another-pane-token".into();
        let mode = LaunchMode::Fresh { session_id: None };
        let first = Codex::live_launch(
            &first,
            &mode,
            Path::new("/s/a-server"),
            Path::new("/s/a-tui"),
        )
        .unwrap();
        let second = Codex::live_launch(
            &second,
            &mode,
            Path::new("/s/b-server"),
            Path::new("/s/b-tui"),
        )
        .unwrap();
        assert_eq!(first.server.env_pinned, second.server.env_pinned);
        assert_ne!(first.server.env, second.server.env);
        assert_ne!(first.server.args, second.server.args);
        assert_ne!(first.tui.args, second.tui.args);
    }

    #[test]
    fn socket_paths_are_validated_before_building_a_command() {
        let context = crate::launch::test_context();
        for path in [
            "relative.sock",
            "/s/line\n.sock",
            "/s/null\0.sock",
            "/s/pane.sock",
        ] {
            assert_eq!(
                Codex::live_launch(
                    &context,
                    &LaunchMode::Fresh { session_id: None },
                    Path::new(path),
                    Path::new("/s/pane.sock")
                ),
                Err(InvalidCodexSocket)
            );
        }
    }
}
