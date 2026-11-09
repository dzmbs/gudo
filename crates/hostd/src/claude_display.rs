use std::ffi::OsStr;
use std::io;
use std::os::unix::process::CommandExt;
use std::process::Command;

pub(super) fn main(arguments: &[String]) -> i32 {
    let result: io::Result<()> =
        command(OsStr::new("claude"), arguments).and_then(|mut command| Err(command.exec()));
    if result.is_err() {
        eprintln!("Claude Code could not start with this pane environment.");
    }
    1
}

fn command(program: &OsStr, arguments: &[String]) -> io::Result<Command> {
    let (display_settings, arguments) = arguments
        .split_first()
        .ok_or_else(|| io::Error::other("missing display settings"))?;
    let (legacy_settings, prefix) = arguments
        .split_last()
        .ok_or_else(|| io::Error::other("missing Claude arguments"))?;
    if prefix.last().map(String::as_str) != Some("--settings") {
        return Err(io::Error::other("missing final settings option"));
    }
    let supported = super::cli_version::read(program)
        .ok()
        .flatten()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .is_some_and(|version| agents::claude_supports_message_display(&version));
    let settings = if supported {
        display_settings
    } else {
        legacy_settings
    };
    if !supported {
        eprintln!("Claude live Chat is unavailable for this version. Continuing in Terminal.");
    }
    let mut command = Command::new(program);
    command.args(prefix).arg(settings);
    if !supported {
        command.env_remove(brand::env_var("CLAUDE_DISPLAY_TOKEN"));
    }
    Ok(command)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::time::{Duration, Instant};

    fn executable(directory: &std::path::Path, body: &str) -> std::path::PathBuf {
        let path = directory.join("claude");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    fn arguments() -> Vec<String> {
        [
            "/display.json",
            "--resume",
            "exact-session",
            "--mcp-config",
            "/mcp.json",
            "--settings",
            "/legacy.json",
        ]
        .map(String::from)
        .into()
    }

    #[test]
    fn version_gate_changes_only_the_settings_file_before_any_conversation() {
        let root = tempfile::tempdir().unwrap();
        for (body, expected) in [
            ("printf '2.1.319 (Claude Code)\\n'", "/display.json"),
            ("printf '2.1.69 (Claude Code)\\n'", "/display.json"),
            ("printf '2.1.68 (Claude Code)\\n'", "/legacy.json"),
            ("printf '2.1.319 (Claude Code)\\n'; exit 1", "/legacy.json"),
            ("printf '2.1.319 (Claude Code)\\nextra'", "/legacy.json"),
            ("printf '%0128d' 0", "/legacy.json"),
        ] {
            let path = executable(root.path(), body);
            let command = command(path.as_os_str(), &arguments()).unwrap();
            if expected == "/legacy.json" {
                assert!(command.get_envs().any(|(name, value)| name
                    == OsStr::new(&brand::env_var("CLAUDE_DISPLAY_TOKEN"))
                    && value.is_none()));
            }
            assert_eq!(
                command.get_args().collect::<Vec<_>>(),
                [
                    "--resume",
                    "exact-session",
                    "--mcp-config",
                    "/mcp.json",
                    "--settings",
                    expected
                ]
            );
        }
    }

    #[test]
    fn hung_version_query_is_bounded_and_falls_back() {
        let root = tempfile::tempdir().unwrap();
        let path = executable(root.path(), "exec 1>&-; exec /bin/sleep 10");
        let started = Instant::now();
        let command = command(path.as_os_str(), &arguments()).unwrap();
        assert_eq!(command.get_args().last(), Some(OsStr::new("/legacy.json")));
        assert!(started.elapsed() < Duration::from_secs(5));
    }
}
