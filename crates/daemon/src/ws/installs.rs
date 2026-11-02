//! Whether the agents' commands are installed, found as a pane finds them: on the `PATH` of
//! the user's interactive login shell, which every agent pane is launched through.

use std::ffi::{OsStr, OsString};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;

use proto::{AgentInstall, AgentKind, AgentMcpCommand, InstallState};

use crate::config::Config;

/// Where the agents' own installers put their commands, relative to `$HOME`.
pub(crate) const INSTALLER_DIRS: [&str; 2] = [".local/bin", ".claude/local"];

/// A shell slower than this (a hung rc file) counts as not answering.
const PROBE_TIMEOUT: Duration = Duration::from_secs(8);

/// Bracket `$PATH` in the probe's output, apart from whatever the rc files print.
const MARK: &str = "\u{1f}path=";
const END: &str = "\u{1f}";

/// The agents the daemon launches.
const AGENTS: [AgentKind; 2] = [AgentKind::Claude, AgentKind::Codex];

/// `PATH` as the user's terminal panes see it, resolved once and again on request.
#[derive(Default)]
pub(crate) struct TerminalPath(Mutex<Option<OsString>>);

impl TerminalPath {
    /// Asks the shell again, keeping the answer for [`Self::cached`].
    pub(crate) async fn refresh(&self, cfg: &Config) -> Option<OsString> {
        let path = terminal_path(cfg, PROBE_TIMEOUT).await;
        self.0.lock().unwrap().clone_from(&path);
        path
    }

    /// The last answer, or a fresh one when there is none.
    pub(crate) async fn cached(&self, cfg: &Config) -> Option<OsString> {
        let known = self.0.lock().unwrap().clone();
        match known {
            Some(path) => Some(path),
            None => self.refresh(cfg).await,
        }
    }
}

/// Each agent's install state on this host, for `path` as [`TerminalPath`] resolves it.
pub(crate) fn check(cfg: &Config, path: Option<OsString>) -> Vec<AgentInstall> {
    let path = path.or_else(|| cfg.pane_var("PATH"));
    let home = cfg.home();
    AGENTS
        .into_iter()
        .map(|agent| {
            let program = crate::agent::program(agent);
            AgentInstall {
                agent,
                program: program.to_owned(),
                state: state(program, path.as_deref(), &home),
            }
        })
        .collect()
}

/// Each installed agent's own command that adds the daemon's MCP server to the user's
/// configuration (`register`), or removes it, naming each by path: the command may run
/// where rc files are not read. Every account has its own configuration, so each gets its
/// own command, run with `env <DIR_VAR>=<dir>`; the system account's runs as the user's own.
pub(crate) fn mcp_commands(
    cfg: &Config,
    path: Option<OsString>,
    register: bool,
    accounts: &[(AgentKind, PathBuf)],
) -> Vec<AgentMcpCommand> {
    let hook_bin = cfg.hook_bin();
    let home = cfg.home();
    let legacy = agents::legacy_mcp_server_name();
    check(cfg, path)
        .into_iter()
        .flat_map(|install| {
            let program = match install.state {
                InstallState::Installed { path } | InstallState::NotOnPath { path } => path,
                InstallState::Missing => return Vec::new(),
            };
            let (state_dir, agent) = (&cfg.state_dir, install.agent);
            let system_dir = cfg
                .pane_var(match agent {
                    AgentKind::Claude => agents::CLAUDE_DIR_VAR,
                    AgentKind::Codex => agents::CODEX_DIR_VAR,
                })
                .map(PathBuf::from);
            let dirs = std::iter::once(None).chain(
                accounts
                    .iter()
                    .filter(|(a, _)| *a == agent)
                    .map(|(_, dir)| Some(dir.clone())),
            );
            dirs.flat_map(|dir| {
                let (add, old) = match agent {
                    AgentKind::Claude => {
                        let config = agents::ClaudeCode::user_config_file(
                            &home,
                            dir.as_deref().or(system_dir.as_deref()),
                        );
                        (
                            agents::ClaudeCode::user_mcp_command(
                                &program, &hook_bin, state_dir, register,
                            ),
                            agents::ClaudeCode::user_mcp_registered(&config, &legacy)
                                .then(|| agents::ClaudeCode::user_mcp_remove(&program, &legacy)),
                        )
                    }
                    AgentKind::Codex => {
                        let config = agents::Codex::config_file(
                            &home,
                            dir.as_deref().or(system_dir.as_deref()),
                        );
                        (
                            agents::Codex::user_mcp_command(
                                &program, &hook_bin, state_dir, register,
                            ),
                            agents::Codex::user_mcp_registered(&config, &legacy)
                                .then(|| agents::Codex::user_mcp_remove(&program, &legacy)),
                        )
                    }
                };
                let prefix: Vec<String> = dir
                    .map(|dir| {
                        let var = match agent {
                            AgentKind::Claude => agents::CLAUDE_DIR_VAR,
                            AgentKind::Codex => agents::CODEX_DIR_VAR,
                        };
                        vec!["env".into(), format!("{var}={}", dir.display())]
                    })
                    .unwrap_or_default();
                // The server's old name goes too, so an agent does not run it twice.
                old.into_iter()
                    .chain([add])
                    .map(|argv| AgentMcpCommand {
                        agent,
                        argv: prefix.iter().cloned().chain(argv).collect(),
                    })
                    .collect::<Vec<_>>()
            })
            .collect()
        })
        .collect()
}

fn state(program: &str, path: Option<&OsStr>, home: &Path) -> InstallState {
    let on_path = path.map(|p| find(std::env::split_paths(p), program));
    if let Some(Some(found)) = on_path {
        return InstallState::Installed {
            path: found.to_string_lossy().into_owned(),
        };
    }
    match find(INSTALLER_DIRS.iter().map(|d| home.join(d)), program) {
        Some(found) => InstallState::NotOnPath {
            path: found.to_string_lossy().into_owned(),
        },
        None => InstallState::Missing,
    }
}

/// The first executable `program` in `dirs`.
pub(crate) fn find(dirs: impl IntoIterator<Item = PathBuf>, program: &str) -> Option<PathBuf> {
    dirs.into_iter()
        .filter(|d| d.is_absolute())
        .map(|d| d.join(program))
        .find(|p| {
            p.metadata()
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
}

/// `PATH` as the user's interactive login shell sets it (rc files included, as in a pane),
/// or as a plain login shell sets it when the interactive one fails.
async fn terminal_path(cfg: &Config, timeout: Duration) -> Option<OsString> {
    match probe(cfg, &["-i", "-l"], timeout).await {
        Some(path) => Some(path),
        None => probe(cfg, &["-l"], timeout).await,
    }
}

async fn probe(cfg: &Config, flags: &[&str], timeout: Duration) -> Option<OsString> {
    let mut cmd = tokio::process::Command::new(cfg.shell());
    // `"$PATH"` is colon-joined in fish too.
    cmd.args(flags)
        .args(["-c", &format!("printf '%s%s%s' '{MARK}' \"$PATH\" '{END}'")])
        .current_dir(cfg.home())
        .envs(cfg.pane_env.iter().map(|(k, v)| (k, v)))
        .env("TERM", "dumb")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    // A session of its own: no terminal for an interactive shell to take over, and one
    // process group to kill along with anything the rc files started.
    // SAFETY: `setsid` is async-signal-safe.
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let child = cmd.spawn().ok()?;
    let group = child.id().and_then(|id| libc::pid_t::try_from(id).ok());
    match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(out) => parse_path(&String::from_utf8_lossy(&out.ok()?.stdout)).map(OsString::from),
        Err(_) => {
            if let Some(group) = group {
                // SAFETY: signals only the probe's own process group.
                unsafe { libc::kill(-group, libc::SIGKILL) };
            }
            None
        }
    }
}

fn parse_path(stdout: &str) -> Option<&str> {
    let (_, rest) = stdout.rsplit_once(MARK)?;
    rest.split_once(END).map(|(path, _)| path)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::time::Instant;

    use super::*;

    fn executable(dir: &Path, name: &str) {
        fs::create_dir_all(dir).unwrap();
        let file = dir.join(name);
        fs::write(&file, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn finds_on_path_off_path_or_not_at_all() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let bin = tmp.path().join("bin");
        executable(&bin, "codex");
        executable(&home.join(".local/bin"), "claude");
        let path = std::env::join_paths([&bin]).unwrap();

        assert_eq!(
            state("codex", Some(&path), &home),
            InstallState::Installed {
                path: bin.join("codex").to_string_lossy().into_owned()
            }
        );
        assert_eq!(
            state("claude", Some(&path), &home),
            InstallState::NotOnPath {
                path: home
                    .join(".local/bin/claude")
                    .to_string_lossy()
                    .into_owned()
            }
        );
        assert_eq!(state("gemini", Some(&path), &home), InstallState::Missing);
    }

    #[test]
    fn skips_files_that_are_not_executable() {
        let tmp = tempfile::tempdir().unwrap();
        fs::write(tmp.path().join("claude"), "").unwrap();
        assert_eq!(find([tmp.path().to_owned()], "claude"), None);
    }

    #[test]
    fn reads_path_between_marks_amid_noise() {
        let out = format!("Welcome!\npath=/fake{MARK}/usr/bin:/bin{END}bye\n");
        assert_eq!(parse_path(&out), Some("/usr/bin:/bin"));
        assert_eq!(parse_path("no mark\n"), None);
    }

    /// A home whose shell is `shell`, with `claude` in `~/.local/bin` and the given rc files.
    fn home_with(shell: &str, files: &[(&str, &str)]) -> Option<(tempfile::TempDir, Config)> {
        if !Path::new(shell).exists() {
            return None;
        }
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().to_string_lossy().into_owned();
        executable(&tmp.path().join(".local/bin"), "claude");
        for (name, body) in files {
            fs::write(tmp.path().join(name), body).unwrap();
        }
        let mut cfg = Config::new(tmp.path().join("state"));
        cfg.shell = Some(shell.into());
        cfg.pane_env = vec![
            ("HOME".into(), home.clone()),
            ("ZDOTDIR".into(), home),
            ("PATH".into(), "/usr/bin:/bin".into()),
        ];
        Some((tmp, cfg))
    }

    async fn claude_state(cfg: &Config) -> InstallState {
        let path = TerminalPath::default().refresh(cfg).await;
        check(cfg, path).swap_remove(0).state
    }

    const ADD_LOCAL_BIN: &str = "export PATH=\"$HOME/.local/bin:$PATH\"\n";

    #[tokio::test]
    async fn finds_path_set_in_zshrc() {
        let Some((_tmp, cfg)) = home_with("/bin/zsh", &[(".zshrc", ADD_LOCAL_BIN)]) else {
            return;
        };
        assert!(matches!(
            claude_state(&cfg).await,
            InstallState::Installed { .. }
        ));
    }

    #[tokio::test]
    async fn finds_path_set_in_zprofile() {
        let Some((_tmp, cfg)) = home_with("/bin/zsh", &[(".zprofile", ADD_LOCAL_BIN)]) else {
            return;
        };
        assert!(matches!(
            claude_state(&cfg).await,
            InstallState::Installed { .. }
        ));
    }

    #[tokio::test]
    async fn finds_path_set_in_bashrc() {
        let files = [
            (".bash_profile", ". \"$HOME/.bashrc\"\n"),
            (".bashrc", ADD_LOCAL_BIN),
        ];
        let Some((_tmp, cfg)) = home_with("/bin/bash", &files) else {
            return;
        };
        assert!(matches!(
            claude_state(&cfg).await,
            InstallState::Installed { .. }
        ));
    }

    #[tokio::test]
    async fn off_path_when_no_rc_file_adds_it() {
        let Some((_tmp, cfg)) = home_with("/bin/zsh", &[(".zshrc", "alias ll='ls -l'\n")]) else {
            return;
        };
        assert!(matches!(
            claude_state(&cfg).await,
            InstallState::NotOnPath { .. }
        ));
    }

    #[tokio::test]
    async fn sees_through_noisy_rc_files() {
        let files = [
            (
                ".zshrc",
                "echo 'Welcome!'\nprintf 'no newline'\nexport PATH=\"$HOME/.local/bin:$PATH\"\n",
            ),
            (".zlogout", "echo 'bye'\n"),
        ];
        let Some((_tmp, cfg)) = home_with("/bin/zsh", &files) else {
            return;
        };
        assert!(matches!(
            claude_state(&cfg).await,
            InstallState::Installed { .. }
        ));
    }

    #[tokio::test]
    async fn a_hung_rc_file_falls_back_to_the_login_shell() {
        let files = [(".zprofile", ADD_LOCAL_BIN), (".zshrc", "sleep 30\n")];
        let Some((tmp, cfg)) = home_with("/bin/zsh", &files) else {
            return;
        };
        let started = Instant::now();
        let path = terminal_path(&cfg, Duration::from_millis(1500))
            .await
            .unwrap();
        assert!(started.elapsed() < Duration::from_secs(5));
        let local_bin = tmp.path().join(".local/bin");
        assert!(std::env::split_paths(&path).any(|d| d == local_bin));
    }

    #[tokio::test]
    async fn falls_back_to_the_pane_path_without_a_shell() {
        let tmp = tempfile::tempdir().unwrap();
        let bin = tmp.path().join("bin");
        executable(&bin, "claude");
        let mut cfg = Config::new(tmp.path().join("state"));
        cfg.shell = Some(tmp.path().join("no-such-shell"));
        cfg.pane_env = vec![
            ("HOME".into(), tmp.path().to_string_lossy().into_owned()),
            ("PATH".into(), bin.to_string_lossy().into_owned()),
        ];
        let installs = check(&cfg, TerminalPath::default().refresh(&cfg).await);
        assert_eq!(installs.len(), 2);
        assert_eq!(installs[0].agent, AgentKind::Claude);
        assert!(matches!(installs[0].state, InstallState::Installed { .. }));
        assert_eq!(installs[1].state, InstallState::Missing);
    }
}
