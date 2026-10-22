//! Whether the agents' commands are installed, found as a pane finds them: on the `PATH` of
//! the user's login shell, which every agent pane is launched through.

use std::ffi::{OsStr, OsString};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use proto::{AgentInstall, AgentKind, InstallState};

use crate::config::Config;

/// Where the agents' own installers put their commands, relative to `$HOME`.
pub(crate) const INSTALLER_DIRS: [&str; 2] = [".local/bin", ".claude/local"];

/// A login shell slower than this (a hung profile) counts as not answering.
const PROBE_TIMEOUT: Duration = Duration::from_secs(10);

/// Precedes `$PATH` in the probe's output, apart from whatever the profile prints.
const MARK: &str = "\u{1f}path=";

/// The agents the daemon launches.
const AGENTS: [AgentKind; 2] = [AgentKind::Claude, AgentKind::Codex];

/// Each agent's install state on this host.
pub(crate) async fn check(cfg: &Config) -> Vec<AgentInstall> {
    let path = login_path(cfg).await.or_else(|| cfg.pane_var("PATH"));
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

/// `PATH` as the user's login shell sets it, with the panes' environment.
async fn login_path(cfg: &Config) -> Option<OsString> {
    let mut cmd = tokio::process::Command::new(cfg.shell());
    // `"$PATH"` is colon-joined in fish too.
    cmd.args([
        "-l",
        "-c",
        &format!("printf '\\n%s%s\\n' '{MARK}' \"$PATH\""),
    ])
    .current_dir(cfg.home())
    .envs(cfg.pane_env.iter().map(|(k, v)| (k, v)))
    .stdin(Stdio::null())
    .stderr(Stdio::null())
    .kill_on_drop(true);
    let out = tokio::time::timeout(PROBE_TIMEOUT, cmd.output())
        .await
        .ok()?
        .ok()?;
    parse_path(&String::from_utf8_lossy(&out.stdout)).map(OsString::from)
}

fn parse_path(stdout: &str) -> Option<&str> {
    stdout.lines().rev().find_map(|l| l.strip_prefix(MARK))
}

#[cfg(test)]
mod tests {
    use std::fs;

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
    fn reads_path_after_profile_noise() {
        let out = format!("Welcome!\npath=/fake\n\n{MARK}/usr/bin:/bin\n");
        assert_eq!(parse_path(&out), Some("/usr/bin:/bin"));
        assert_eq!(parse_path("no mark\n"), None);
    }

    #[tokio::test]
    async fn asks_the_login_shell() {
        let tmp = tempfile::tempdir().unwrap();
        let bin = tmp.path().join("bin");
        executable(&bin, "claude");
        let mut cfg = Config::new(tmp.path().join("state"));
        cfg.shell = Some("/bin/sh".into());
        cfg.pane_env = vec![
            ("HOME".into(), tmp.path().to_string_lossy().into_owned()),
            ("PATH".into(), bin.to_string_lossy().into_owned()),
        ];
        let installs = check(&cfg).await;
        assert_eq!(installs.len(), 2);
        assert_eq!(installs[0].agent, AgentKind::Claude);
        assert!(matches!(installs[0].state, InstallState::Installed { .. }));
        assert_eq!(installs[1].state, InstallState::Missing);
    }
}
