//! Each start also repairs what earlier daemons wrote with a direct shim path: the generated
//! agent settings under the state directory, and this daemon's MCP server registration in the
//! agents' user configuration when its shim no longer exists.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::core::shell_quote;
use crate::fsutil;

/// Where the launcher lives in `state_dir`.
pub(crate) fn path(state_dir: &Path) -> PathBuf {
    state_dir.join("bin").join(brand::HOOK_BIN)
}

/// Writes the launcher for the configured hook executable and returns its path.
///
/// # Errors
///
/// The script cannot be written.
pub(crate) fn install(config: &crate::Config) -> io::Result<PathBuf> {
    let shim = config.hook_bin();
    let launcher = path(&config.state_dir);
    if shim == launcher {
        return Ok(launcher);
    }
    crate::askpass::write_executable(&launcher, &script(&shim, config.cli_exe.as_deref()))?;
    Ok(launcher)
}

fn script(shim: &Path, daemon: Option<&Path>) -> String {
    format!(
        "#!/bin/sh\n\
         shim={}\n\
         if [ -x \"$shim\" ]; then exec \"$shim\" {}\"$@\"; fi\n\
         case \"$1\" in askpass|agent-input-arm|agent-exit-fence) exit 1 ;; esac\n\
         exit 0\n",
        shell_quote(&shim.to_string_lossy()),
        if daemon == Some(shim) { "hook " } else { "" },
    )
}

/// Points what earlier daemons wrote at `launcher`: the agent settings and MCP configs under
/// `state_dir` (always), and the registrations of this daemon's MCP server in the Claude Code
/// and Codex user configurations `claude_configs` and `codex_configs` whose shim is missing.
/// Failures are logged; nothing else in those files changes.
pub(crate) fn repair(
    state_dir: &Path,
    launcher: &Path,
    claude_configs: &[PathBuf],
    codex_configs: &[PathBuf],
) {
    for file in generated_files(state_dir) {
        if let Err(error) = repair_generated(&file, launcher) {
            tracing::warn!("repairing hook paths in {}: {error}", file.display());
        }
    }
    for legacy_helper in [
        state_dir
            .join("askpass")
            .join(format!("{}-askpass", brand::legacy::CLI_BIN)),
        state_dir
            .join("browser")
            .join(format!("{}-open", brand::legacy::CLI_BIN)),
    ] {
        let _ = fs::remove_file(legacy_helper);
    }
    for file in claude_configs {
        if let Err(error) = repair_claude_config(file, launcher, state_dir) {
            tracing::warn!("repairing the MCP server in {}: {error}", file.display());
        }
    }
    for file in codex_configs {
        if let Err(error) = repair_codex_config(file, launcher, state_dir) {
            tracing::warn!("repairing the MCP server in {}: {error}", file.display());
        }
    }
}

fn generated_files(state_dir: &Path) -> Vec<PathBuf> {
    let claude = state_dir.join("claude");
    let json_files = |dir: &Path| -> Vec<PathBuf> {
        fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
            .collect()
    };
    let mut files = json_files(&claude);
    files.extend(json_files(&claude.join("mcp")));
    files
}

fn repair_generated(file: &Path, launcher: &Path) -> io::Result<()> {
    let Some(bytes) = fsutil::read_optional(file)? else {
        return Ok(());
    };
    let Ok(mut value) = serde_json::from_slice::<Value>(&bytes) else {
        return Ok(());
    };
    if repoint_strings(&mut value, launcher) {
        let text = serde_json::to_string_pretty(&value).map_err(io::Error::other)?;
        fsutil::write_atomic(file, text.as_bytes())?;
    }
    Ok(())
}

fn repoint_strings(value: &mut Value, launcher: &Path) -> bool {
    match value {
        Value::String(text) => match repointed_command(text, launcher) {
            Some(repointed) => {
                *text = repointed;
                true
            }
            None => false,
        },
        Value::Array(items) => items.iter_mut().fold(false, |changed, item| {
            repoint_strings(item, launcher) | changed
        }),
        Value::Object(fields) => fields.values_mut().fold(false, |changed, item| {
            repoint_strings(item, launcher) | changed
        }),
        _ => false,
    }
}

/// `command` with its program replaced by `launcher` when the program is a hook shim other than
/// the launcher: a bare path (an MCP server's `command`) or a shell line's first word.
fn repointed_command(command: &str, launcher: &Path) -> Option<String> {
    if is_shim(Path::new(command)) {
        return (Path::new(command) != launcher).then(|| launcher.to_string_lossy().into_owned());
    }
    let (program, rest) = first_shell_word(command)?;
    (is_shim(Path::new(&program)) && Path::new(&program) != launcher)
        .then(|| format!("{}{rest}", shell_quote(&launcher.to_string_lossy())))
}

fn is_shim(path: &Path) -> bool {
    path.is_absolute()
        && path
            .file_name()
            .is_some_and(|name| name == brand::HOOK_BIN || name == brand::legacy::HOOK_BIN)
}

/// The first word of a shell line, unquoted, and the rest of the line from the space after it.
pub(crate) fn first_shell_word(line: &str) -> Option<(String, &str)> {
    let mut word = String::new();
    let mut chars = line.char_indices();
    while let Some((index, c)) = chars.next() {
        match c {
            ' ' => return Some((word, &line[index..])),
            '\'' => loop {
                match chars.next()? {
                    (_, '\'') => break,
                    (_, quoted) => word.push(quoted),
                }
            },
            '\\' => word.push(chars.next()?.1),
            '"' | '$' | '`' | ';' | '&' | '|' | '<' | '>' | '(' | ')' => return None,
            _ => word.push(c),
        }
    }
    Some((word, ""))
}

/// The shim path of this daemon's MCP server registration in `servers` (an agent's
/// `mcp_servers` table), when that shim no longer exists.
fn missing_registered_shim<'a>(
    servers: impl Iterator<Item = (&'a str, Option<&'a str>, Vec<&'a str>)>,
    state_dir: &Path,
) -> Vec<String> {
    let ours = std::iter::once(agents::mcp_server_name())
        .chain(agents::legacy_mcp_server_names().map(String::from))
        .collect::<Vec<_>>();
    let state = state_dir.to_string_lossy();
    servers
        .filter(|(name, _, args)| {
            ours.iter().any(|our| our == name)
                && args.windows(2).any(|pair| pair == ["--state", &*state])
        })
        .filter_map(|(_, command, _)| command)
        .filter(|command| is_shim(Path::new(command)) && !Path::new(command).exists())
        .map(String::from)
        .collect()
}

fn repair_claude_config(file: &Path, launcher: &Path, state_dir: &Path) -> io::Result<()> {
    let Some(text) = read_user_file(file)? else {
        return Ok(());
    };
    let Ok(config) = serde_json::from_str::<Value>(&text) else {
        return Ok(());
    };
    let empty = serde_json::Map::new();
    let servers = config["mcpServers"].as_object().unwrap_or(&empty);
    let stale = missing_registered_shim(
        servers.iter().map(|(name, server)| {
            let args = server["args"]
                .as_array()
                .map(|args| args.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            (name.as_str(), server["command"].as_str(), args)
        }),
        state_dir,
    );
    let quote = |text: &str| serde_json::to_string(text).expect("a string serializes");
    let replacements = stale
        .iter()
        .map(|shim| (quote(shim), quote(&launcher.to_string_lossy())))
        .collect::<Vec<_>>();
    let repaired = replace_all(&text, &replacements);
    if repaired != text && serde_json::from_str::<Value>(&repaired).is_ok() {
        fsutil::write_atomic(file, repaired.as_bytes())?;
    }
    Ok(())
}

fn repair_codex_config(file: &Path, launcher: &Path, state_dir: &Path) -> io::Result<()> {
    let Some(text) = read_user_file(file)? else {
        return Ok(());
    };
    let Ok(config) = text.parse::<toml::Table>() else {
        return Ok(());
    };
    let empty = toml::Table::new();
    let servers = config
        .get("mcp_servers")
        .and_then(toml::Value::as_table)
        .unwrap_or(&empty);
    let stale = missing_registered_shim(
        servers.iter().map(|(name, server)| {
            let args = server
                .get("args")
                .and_then(toml::Value::as_array)
                .map(|args| args.iter().filter_map(toml::Value::as_str).collect())
                .unwrap_or_default();
            (
                name.as_str(),
                server.get("command").and_then(toml::Value::as_str),
                args,
            )
        }),
        state_dir,
    );
    let launcher = toml_basic_string(&launcher.to_string_lossy());
    let replacements = stale
        .iter()
        .flat_map(|shim| {
            [
                (toml_basic_string(shim), launcher.clone()),
                (format!("'{shim}'"), launcher.clone()),
            ]
        })
        .collect::<Vec<_>>();
    let repaired = replace_all(&text, &replacements);
    if repaired != text && repaired.parse::<toml::Table>().is_ok() {
        fsutil::write_atomic(file, repaired.as_bytes())?;
    }
    Ok(())
}

fn toml_basic_string(text: &str) -> String {
    toml::Value::String(text.to_owned()).to_string()
}

fn replace_all(text: &str, replacements: &[(String, String)]) -> String {
    replacements
        .iter()
        .fold(text.to_owned(), |text, (from, to)| text.replace(from, to))
}

/// A user configuration file's text, unless it is missing or a symbolic link (replacing a link
/// with a file would cut it off from where the user keeps it).
fn read_user_file(file: &Path) -> io::Result<Option<String>> {
    match fs::symlink_metadata(file) {
        Ok(metadata) if metadata.file_type().is_symlink() => return Ok(None),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
        Ok(_) => {}
    }
    match fs::read_to_string(file) {
        Ok(text) => Ok(Some(text)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn install(state_dir: &Path, shim: &Path) -> io::Result<PathBuf> {
        let mut config = crate::Config::new(state_dir);
        config.hook_bin = Some(shim.to_owned());
        super::install(&config)
    }

    fn run(launcher: &Path, args: &[&str]) -> std::process::Output {
        Command::new(launcher).args(args).output().unwrap()
    }

    #[test]
    fn the_launcher_dispatches_to_the_daemons_hook_command() {
        let directory = tempfile::tempdir().unwrap();
        let daemon = directory.path().join("app's bundle").join("renamed-helper");
        crate::askpass::write_executable(&daemon, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n").unwrap();
        let mut config = crate::Config::new(directory.path().join("state"));
        config.hook_bin = Some(daemon.clone());
        config.cli_exe = Some(daemon);
        let launcher = super::install(&config).unwrap();
        let output = run(&launcher, &["askpass", "Password with spaces:"]);
        assert!(output.status.success());
        assert_eq!(output.stdout, b"hook\naskpass\nPassword with spaces:\n");
    }

    #[test]
    fn the_launcher_runs_the_shim_and_exits_quietly_without_it() {
        let dir = tempfile::tempdir().unwrap();
        let shim = dir.path().join("app").join(brand::HOOK_BIN);
        fs::create_dir_all(shim.parent().unwrap()).unwrap();
        crate::askpass::write_executable(&shim, "#!/bin/sh\necho \"ran $*\"\n").unwrap();
        let launcher = install(&dir.path().join("state"), &shim).unwrap();
        assert_eq!(launcher, path(&dir.path().join("state")));

        let output = run(&launcher, &["claude", "SessionStart"]);
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "ran claude SessionStart\n"
        );

        fs::remove_file(&shim).unwrap();
        let output = run(&launcher, &["claude", "SessionStart"]);
        assert!(output.status.success());
        assert!(output.stdout.is_empty() && output.stderr.is_empty());
        for arguments in [
            ["askpass", "Password:"],
            ["agent-input-arm", "launch"],
            ["agent-exit-fence", "launch"],
        ] {
            assert_eq!(run(&launcher, &arguments).status.code(), Some(1));
        }
    }

    #[test]
    fn a_shim_path_with_spaces_and_quotes_is_quoted() {
        let dir = tempfile::tempdir().unwrap();
        let shim = dir.path().join("Gudo's app").join(brand::HOOK_BIN);
        fs::create_dir_all(shim.parent().unwrap()).unwrap();
        crate::askpass::write_executable(&shim, "#!/bin/sh\necho ok\n").unwrap();
        let launcher = install(&dir.path().join("state dir"), &shim).unwrap();
        assert_eq!(run(&launcher, &[]).stdout, b"ok\n");
    }

    fn settings(program: &str) -> Value {
        serde_json::json!({
            "statusLine": { "type": "command", "command": format!("{program} claude StatusLine") },
            "hooks": {
                "SessionStart": [{
                    "matcher": "startup",
                    "hooks": [{ "type": "command", "command": format!("{program} claude SessionStart") }],
                }],
            },
        })
    }

    #[test]
    fn stale_generated_settings_point_at_the_launcher_and_stay_put_after() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state dir");
        let launcher =
            install(&state, Path::new("/gone/Gudo.app/Contents/MacOS/gudo-hook")).unwrap();
        let settings_file = state.join("claude").join("settings.v3.json");
        let mcp_file = state.join("claude").join("mcp").join("7.json");
        fsutil::write_atomic(
            &settings_file,
            settings(&format!("/gone/Debug/app/{}", brand::HOOK_BIN))
                .to_string()
                .as_bytes(),
        )
        .unwrap();
        fsutil::write_atomic(
            &mcp_file,
            br#"{"mcpServers":{"gudo":{"type":"stdio","command":"/old/unnamed.app/Contents/MacOS/un-hook","args":["mcp"]}}}"#,
        )
        .unwrap();

        repair(&state, &launcher, &[], &[]);
        let quoted = shell_quote(&launcher.to_string_lossy());
        let repaired: Value = serde_json::from_slice(&fs::read(&settings_file).unwrap()).unwrap();
        assert_eq!(repaired, settings(&quoted));
        let mcp: Value = serde_json::from_slice(&fs::read(&mcp_file).unwrap()).unwrap();
        assert_eq!(
            mcp["mcpServers"]["gudo"]["command"],
            launcher.to_string_lossy().as_ref()
        );

        let before = fs::read(&settings_file).unwrap();
        repair(&state, &launcher, &[], &[]);
        assert_eq!(fs::read(&settings_file).unwrap(), before);
    }

    #[test]
    fn foreign_commands_are_left_alone() {
        let launcher_path = format!("/s/bin/{}", brand::HOOK_BIN);
        let launcher = Path::new(&launcher_path);
        for command in [
            "/usr/local/bin/my-status-line",
            "gudo-hook claude Stop",
            "echo /old/gudo-hook",
            "\"/old/gudo-hook\" claude Stop",
            "/s/bin/gudo-hook claude Stop",
        ] {
            assert_eq!(repointed_command(command, launcher), None, "{command}");
        }
        let command = format!("'/a b/{}' claude Stop", brand::HOOK_BIN);
        let expected = format!("{} claude Stop", launcher.display());
        assert_eq!(
            repointed_command(&command, launcher).as_deref(),
            Some(expected.as_str())
        );
    }

    #[test]
    fn a_users_claude_config_gets_only_our_missing_shim_repaired() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let launcher = install(&state, Path::new("/gone/gudo-hook")).unwrap();
        let state_arg = state.to_string_lossy();
        let other_state = dir.path().join("other");
        let server = agents::mcp_server_name();
        let stale_hook = format!("/gone/app/{}", brand::HOOK_BIN);
        let original = serde_json::json!({
            "numStartups": 4,
            "mcpServers": {
                (server.clone()): { "type": "stdio", "command": stale_hook, "args": ["mcp", "--state", state_arg] },
                "mine": { "type": "stdio", "command": "/gone/tools/gudo-hook", "args": ["serve"] },
                "unnamed": { "type": "stdio", "command": "/gone/x/un-hook", "args": ["mcp", "--state", other_state.to_string_lossy()] },
            },
            "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "/elsewhere/notify" }] }] },
        });
        let text = serde_json::to_string_pretty(&original).unwrap();
        let config = dir.path().join(".claude.json");
        fs::write(&config, &text).unwrap();

        repair(&state, &launcher, std::slice::from_ref(&config), &[]);
        let mut expected = original.clone();
        expected["mcpServers"][&server]["command"] = launcher.to_string_lossy().as_ref().into();
        let repaired = fs::read_to_string(&config).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&repaired).unwrap(), expected);
        assert_eq!(
            repaired,
            text.replace(&stale_hook, &launcher.to_string_lossy())
        );

        repair(&state, &launcher, std::slice::from_ref(&config), &[]);
        assert_eq!(fs::read_to_string(&config).unwrap(), repaired);
    }

    #[test]
    fn a_users_claude_config_with_a_present_shim_is_not_rewritten() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let shim = dir.path().join(brand::HOOK_BIN);
        crate::askpass::write_executable(&shim, "#!/bin/sh\n").unwrap();
        let launcher = install(&state, &shim).unwrap();
        let text = serde_json::json!({
            "mcpServers": { "gudo": { "command": shim, "args": ["mcp", "--state", state] } },
        })
        .to_string();
        let config = dir.path().join(".claude.json");
        fs::write(&config, &text).unwrap();
        repair(&state, &launcher, std::slice::from_ref(&config), &[]);
        assert_eq!(fs::read_to_string(&config).unwrap(), text);
    }

    #[test]
    fn a_users_codex_config_gets_only_our_missing_shim_repaired() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let launcher = install(&state, Path::new("/gone/gudo-hook")).unwrap();
        let state_arg = toml_basic_string(&state.to_string_lossy());
        let server = agents::mcp_server_name();
        let stale_hook = format!("/gone/app/{}", brand::HOOK_BIN);
        let text = format!(
            "# mine\nmodel = \"o3\"\n\n[mcp_servers.{server}]\ncommand = \"{stale_hook}\"\nargs = [\"mcp\", \"--state\", {state_arg}]\n\n[mcp_servers.other]\ncommand = \"/gone/other/gudo-hook\"\nargs = []\n"
        );
        let config = dir.path().join("config.toml");
        fs::write(&config, &text).unwrap();

        repair(&state, &launcher, &[], std::slice::from_ref(&config));
        let repaired = fs::read_to_string(&config).unwrap();
        assert_eq!(
            repaired,
            text.replace(
                &toml_basic_string(&stale_hook),
                &toml_basic_string(&launcher.to_string_lossy())
            )
        );
        repair(&state, &launcher, &[], std::slice::from_ref(&config));
        assert_eq!(fs::read_to_string(&config).unwrap(), repaired);
    }

    #[test]
    fn earlier_named_helpers_are_removed() {
        let dir = tempfile::tempdir().unwrap();
        let helper = dir
            .path()
            .join("askpass")
            .join(format!("{}-askpass", brand::legacy::CLI_BIN));
        crate::askpass::write_executable(&helper, "#!/bin/sh\nexec /gone/un-hook askpass\n")
            .unwrap();
        repair(dir.path(), &path(dir.path()), &[], &[]);
        assert!(!helper.exists());
    }
}
