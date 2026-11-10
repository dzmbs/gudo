use std::io;
use std::path::Path;

use serde_json::{Value, json};

use crate::{Config, fsutil, hook_launcher};

pub fn install_agent_integration(config: &Config) -> io::Result<()> {
    match config.agent_integration {
        crate::AgentIntegration::Automatic
            if brand::IS_DEV || config.state_dir != crate::default_state_dir() =>
        {
            Ok(())
        }
        _ => install_shared_agent_integration(config),
    }
}

fn install_shared_agent_integration(config: &Config) -> io::Result<()> {
    let home_directory = config.home();
    let launcher_path = hook_launcher::path(&config.state_dir);
    let claude_directory = config
        .pane_var(agents::CLAUDE_DIR_VAR)
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| home_directory.join(".claude"));
    let claude_config = agents::ClaudeCode::user_config_file(
        &home_directory,
        config
            .pane_var(agents::CLAUDE_DIR_VAR)
            .as_deref()
            .map(Path::new),
    );
    let codex_config = agents::Codex::config_file(
        &home_directory,
        config
            .pane_var(agents::CODEX_DIR_VAR)
            .as_deref()
            .map(Path::new),
    );
    let context = agents::LaunchContext {
        pane_id: agents::PaneId::new(String::new()),
        socket: config.state_dir.join("hook.sock"),
        token: String::new(),
        endpoint_file: config.state_dir.join("hook.endpoint"),
        hook_bin: launcher_path.clone(),
        state_dir: config.state_dir.clone(),
        cwd: home_directory,
        account: agents::AccountContext::system(),
    };
    let outcomes = [
        install_claude_settings(&claude_directory.join("settings.json"), &context),
        install_claude_server(&claude_config, &launcher_path),
        install_codex_config(&codex_config, &launcher_path),
    ];
    outcomes
        .into_iter()
        .find_map(Result::err)
        .map_or(Ok(()), Err)
}

fn read_config(path: &Path) -> io::Result<Option<String>> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "agent config is a symbolic link",
            ));
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    }
    std::fs::read_to_string(path).map(Some)
}

fn write_config(path: &Path, original: &str, contents: &str) -> io::Result<()> {
    if original != contents {
        fsutil::write_atomic(path, contents.as_bytes())?;
    }
    Ok(())
}

fn read_json_config(path: &Path) -> io::Result<Value> {
    let original = read_config(path)?.unwrap_or_else(|| "{}".into());
    let settings: Value = serde_json::from_str(&original).map_err(io::Error::other)?;
    if !settings.is_object() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "agent config must be an object",
        ));
    }
    Ok(settings)
}

/// Writes `settings` only when they differ from what was read: the agents rewrite these files
/// in their own layout while they run, and a rewrite of ours would race theirs for nothing.
fn write_json_config(path: &Path, original: &Value, settings: &Value) -> io::Result<()> {
    if original == settings {
        return Ok(());
    }
    let contents = serde_json::to_string_pretty(settings).map_err(io::Error::other)?;
    fsutil::write_atomic(path, contents.as_bytes())
}

fn is_hook_program(program: &str) -> bool {
    Path::new(program).file_name().is_some_and(|name| {
        name == brand::HOOK_BIN || (!brand::IS_DEV && name == brand::legacy::HOOK_BIN)
    })
}

fn is_owned_hook(command: &str) -> bool {
    hook_launcher::first_shell_word(command).is_some_and(|(program, arguments)| {
        is_hook_program(&program) && is_claude_hook_arguments(arguments)
    })
}

fn is_missing_hook_program(program: &str) -> bool {
    Path::new(program).is_absolute()
        && agents::is_hook_program(program)
        && std::fs::metadata(program).is_err_and(|error| error.kind() == io::ErrorKind::NotFound)
}

fn is_owned_server_name(name: &str) -> bool {
    brand::MCP_SERVER_NAMES.contains(&name) || agents::legacy_mcp_server_names().contains(&name)
}

fn is_claude_hook_arguments(arguments: &str) -> bool {
    let mut words = arguments.split_whitespace();
    words.next() == Some("claude")
        && words.next().is_some_and(|event| {
            event
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
        })
        && words.next().is_none()
}

fn is_stale_claude_hook(command: &str) -> bool {
    hook_launcher::first_shell_word(command).is_some_and(|(program, arguments)| {
        is_claude_hook_arguments(arguments) && is_missing_hook_program(&program)
    })
}

fn remove_hook_handlers(groups: &mut Vec<Value>, removes: fn(&str) -> bool) {
    groups.retain_mut(|group| {
        let Some(handlers) = group.get_mut("hooks").and_then(Value::as_array_mut) else {
            return true;
        };
        let original_count = handlers.len();
        handlers.retain(|handler| !handler["command"].as_str().is_some_and(removes));
        handlers.len() == original_count || !handlers.is_empty()
    });
}

fn install_claude_settings(path: &Path, context: &agents::LaunchContext) -> io::Result<()> {
    let original = read_json_config(path)?;
    let mut settings = original.clone();
    let generated = agents::ClaudeCode::hook_settings(context);
    if settings.get("hooks").is_none() {
        settings["hooks"] = json!({});
    }
    let hooks = settings["hooks"]
        .as_object_mut()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "hooks must be an object"))?;
    for groups in hooks.values_mut().filter_map(Value::as_array_mut) {
        remove_hook_handlers(groups, is_stale_claude_hook);
    }
    for (event, generated_groups) in generated["hooks"].as_object().into_iter().flatten() {
        let groups = hooks.entry(event.clone()).or_insert_with(|| json!([]));
        let groups = groups.as_array_mut().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "hook groups must be an array")
        })?;
        remove_hook_handlers(groups, is_owned_hook);
        groups.extend(generated_groups.as_array().into_iter().flatten().cloned());
    }
    write_json_config(path, &original, &settings)
}

fn install_claude_server(path: &Path, launcher_path: &Path) -> io::Result<()> {
    let original = read_json_config(path)?;
    let mut settings = original.clone();
    let name = agents::mcp_server_name();
    let mut removed_stale_server = false;
    if let Some(servers) = settings
        .get_mut("mcpServers")
        .and_then(Value::as_object_mut)
    {
        servers.retain(|name, server| {
            let removes = is_owned_server_name(name)
                && server["args"].get(0).and_then(Value::as_str) == Some("mcp")
                && server["command"]
                    .as_str()
                    .is_some_and(is_missing_hook_program);
            removed_stale_server |= removes;
            !removes
        });
    }
    if let Some(server) = settings
        .get("mcpServers")
        .and_then(|servers| servers.get(&name))
        && !server["command"].as_str().is_some_and(is_hook_program)
    {
        return if removed_stale_server {
            write_json_config(path, &original, &settings)
        } else {
            Ok(())
        };
    }
    if settings.get("mcpServers").is_none() {
        settings["mcpServers"] = json!({});
    }
    let servers = settings["mcpServers"].as_object_mut().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "mcpServers must be an object")
    })?;
    servers.insert(
        name,
        json!({"type":"stdio", "command":launcher_path, "args":["mcp"]}),
    );
    write_json_config(path, &original, &settings)
}

fn install_codex_config(path: &Path, launcher_path: &Path) -> io::Result<()> {
    let original = read_config(path)?.unwrap_or_default();
    let mut document = original
        .parse::<toml_edit::DocumentMut>()
        .map_err(io::Error::other)?;
    if document
        .get("mcp_servers")
        .is_some_and(|servers| !servers.is_table_like())
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "mcp_servers must be a table",
        ));
    }
    if document
        .get("notify")
        .is_some_and(|notification| !notification.is_array())
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "notify must be an array",
        ));
    }
    let name = agents::mcp_server_name();
    if let Some(servers) = document
        .get_mut("mcp_servers")
        .and_then(toml_edit::Item::as_table_like_mut)
    {
        let stale: Vec<String> = servers
            .iter()
            .filter(|(name, server)| {
                is_owned_server_name(name)
                    && server
                        .get("args")
                        .and_then(toml_edit::Item::as_array)
                        .and_then(|args| args.get(0))
                        .and_then(toml_edit::Value::as_str)
                        == Some("mcp")
                    && server
                        .get("command")
                        .and_then(toml_edit::Item::as_str)
                        .is_some_and(is_missing_hook_program)
            })
            .map(|(name, _)| name.to_owned())
            .collect();
        for name in stale {
            servers.remove(&name);
        }
    }
    let has_foreign_server = document
        .get("mcp_servers")
        .and_then(|servers| servers.get(&name))
        .is_some_and(|server| {
            !server
                .get("command")
                .and_then(toml_edit::Item::as_str)
                .is_some_and(is_hook_program)
        });
    if !has_foreign_server {
        document["mcp_servers"][&name]["command"] =
            toml_edit::value(launcher_path.to_string_lossy().as_ref());
        document["mcp_servers"][&name]["args"] =
            toml_edit::value(["mcp"].into_iter().collect::<toml_edit::Array>());
    }
    let existing_notify = document
        .get("notify")
        .and_then(toml_edit::Item::as_array)
        .map(|arguments| {
            arguments
                .iter()
                .map(|argument| argument.as_str().map(str::to_owned))
                .collect::<Option<Vec<_>>>()
        })
        .unwrap_or_else(|| Some(Vec::new()))
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "notify must contain strings"))?;
    let original_notify = serde_json::to_string(&normalize_notification(existing_notify)?)
        .map_err(io::Error::other)?;
    let notification: toml_edit::Array = [
        launcher_path.to_string_lossy().into_owned(),
        agents::CODEX_NOTIFY_SUBCOMMAND.into(),
        original_notify,
    ]
    .into_iter()
    .collect();
    document["notify"] = toml_edit::value(notification);
    write_config(path, &original, &document.to_string())
}

fn normalize_notification(arguments: Vec<String>) -> io::Result<Vec<String>> {
    agents::NotifyChain::parse(arguments)
        .and_then(|chain| {
            chain.remove_hooks(|program| {
                is_hook_program(program) || is_missing_hook_program(program)
            })
        })
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn install_agent_integration(config: &Config) -> io::Result<()> {
        super::install_shared_agent_integration(config)
    }

    fn private_config(directory: &Path) -> Config {
        let home = directory.join("home");
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        let mut config = Config::new(directory.join("state"));
        config.pane_env = vec![
            ("HOME".into(), home.to_string_lossy().into_owned()),
            (
                agents::CLAUDE_DIR_VAR.into(),
                home.join(".claude").to_string_lossy().into_owned(),
            ),
            (
                agents::CODEX_DIR_VAR.into(),
                home.join(".codex").to_string_lossy().into_owned(),
            ),
        ];
        config.agent_integration = crate::AgentIntegration::Install;
        config
    }

    fn other_flavour() -> (&'static str, &'static str) {
        if brand::IS_DEV {
            (brand::RELEASE_HOOK_BIN, brand::MCP_SERVER_NAMES[0])
        } else {
            (brand::DEV_HOOK_BIN, brand::MCP_SERVER_NAMES[1])
        }
    }

    fn notify_wrapper(program: &Path, original: &[String]) -> Vec<String> {
        vec![
            program.to_string_lossy().into_owned(),
            "codex-notify".into(),
            serde_json::to_string(original).unwrap(),
        ]
    }

    #[test]
    fn stale_cleanup_preserves_relative_commands_and_custom_shell_suffixes() {
        let directory = tempfile::tempdir().unwrap();
        let program = directory.path().join(brand::HOOK_BIN);
        let program = agents::shell_quote(&program.to_string_lossy());
        assert!(is_stale_claude_hook(&format!("{program} claude Stop")));
        assert!(!is_stale_claude_hook(&format!(
            "{} claude Stop",
            brand::HOOK_BIN
        )));
        assert!(!is_stale_claude_hook(&format!(
            "{program} claude Stop; custom-notify"
        )));
        assert!(!is_owned_hook(&format!(
            "{program} claude Stop && custom-notify"
        )));
    }

    #[test]
    fn startup_removes_missing_owned_entries_without_touching_live_or_foreign_entries() {
        let directory = tempfile::tempdir().unwrap();
        let config = private_config(directory.path());
        let (other_hook, other_server) = other_flavour();
        let missing = directory.path().join("gone/bin").join(other_hook);
        let live = directory.path().join("live").join(other_hook);
        std::fs::create_dir_all(live.parent().unwrap()).unwrap();
        std::fs::write(&live, "live hook fixture").unwrap();
        let settings_path = config.home().join(".claude/settings.json");
        let handlers = json!({"hooks":{"RetiredEvent":[{"hooks":[
            {"type":"command","command":format!("{} claude Stop", agents::shell_quote(&missing.to_string_lossy()))},
            {"type":"command","command":format!("{} claude Stop", agents::shell_quote(&live.to_string_lossy()))},
            {"type":"command","command":"my-missing-hook claude Stop"}
        ]}]}});
        std::fs::write(&settings_path, handlers.to_string()).unwrap();
        let server_path = config.home().join(".claude/.claude.json");
        std::fs::write(
            &server_path,
            json!({"mcpServers":{
                other_server:{"command":missing,"args":["mcp"]},
                "mine":{"command":missing,"args":["mcp"]}
            }})
            .to_string(),
        )
        .unwrap();
        let notify = notify_wrapper(&missing, &["my-notify".into()]);
        let codex_path = config.home().join(".codex/config.toml");
        std::fs::write(&codex_path, format!("# preserve\nnotify = {}\n\n[mcp_servers.{other_server}]\ncommand = {}\nargs = ['mcp']\n\n[mcp_servers.mine]\ncommand = 'my-server'\n", serde_json::to_string(&notify).unwrap(), serde_json::to_string(&missing).unwrap())).unwrap();
        super::install_agent_integration(&config).unwrap();
        let settings: Value =
            serde_json::from_str(&std::fs::read_to_string(settings_path).unwrap()).unwrap();
        let retained = settings["hooks"]["RetiredEvent"][0]["hooks"]
            .as_array()
            .unwrap();
        assert_eq!(retained.len(), 2);
        assert_eq!(
            retained[0],
            handlers["hooks"]["RetiredEvent"][0]["hooks"][1]
        );
        assert_eq!(
            retained[1],
            handlers["hooks"]["RetiredEvent"][0]["hooks"][2]
        );
        let servers: Value =
            serde_json::from_str(&std::fs::read_to_string(server_path).unwrap()).unwrap();
        assert!(servers["mcpServers"].get(other_server).is_none());
        assert_eq!(servers["mcpServers"]["mine"]["command"], json!(missing));
        let codex_text = std::fs::read_to_string(codex_path).unwrap();
        assert!(codex_text.starts_with("# preserve\n"));
        let codex: toml::Table = codex_text.parse().unwrap();
        assert!(codex["mcp_servers"].get(other_server).is_none());
        assert_eq!(
            codex["mcp_servers"]["mine"]["command"].as_str(),
            Some("my-server")
        );
        let original: Vec<String> =
            serde_json::from_str(codex["notify"][2].as_str().unwrap()).unwrap();
        assert_eq!(original, ["my-notify"]);
    }

    #[test]
    fn alternating_flavours_keep_one_notification_wrapper_each_and_preserve_live_servers() {
        let directory = tempfile::tempdir().unwrap();
        let config = private_config(directory.path());
        let (other_hook, other_server) = other_flavour();
        let live = directory.path().join("live").join(other_hook);
        std::fs::create_dir_all(live.parent().unwrap()).unwrap();
        std::fs::write(&live, "live hook fixture").unwrap();
        let current = hook_launcher::path(&config.state_dir);
        let user_notify = vec!["my-notify".into(), "argument with spaces".into()];
        let previous = notify_wrapper(&live, &notify_wrapper(&current, &user_notify));
        let codex_path = config.home().join(".codex/config.toml");
        std::fs::write(
            &codex_path,
            format!(
                "notify = {}\n\n[mcp_servers.{other_server}]\ncommand = {}\nargs = ['mcp']\n",
                serde_json::to_string(&previous).unwrap(),
                serde_json::to_string(&live).unwrap()
            ),
        )
        .unwrap();
        let claude_path = config.home().join(".claude/.claude.json");
        let other_registration = json!({"command":live,"args":["mcp"],"env":{"CUSTOM":"keep"}});
        std::fs::write(
            &claude_path,
            json!({"mcpServers":{other_server:other_registration}}).to_string(),
        )
        .unwrap();
        super::install_agent_integration(&config).unwrap();
        let first = std::fs::read_to_string(&codex_path).unwrap();
        let codex: toml::Table = first.parse().unwrap();
        let original: Vec<String> =
            serde_json::from_str(codex["notify"][2].as_str().unwrap()).unwrap();
        assert_eq!(original, notify_wrapper(&live, &user_notify));
        assert_eq!(
            codex["mcp_servers"][other_server]["command"].as_str(),
            live.to_str()
        );
        let claude: Value =
            serde_json::from_str(&std::fs::read_to_string(&claude_path).unwrap()).unwrap();
        assert_eq!(claude["mcpServers"][other_server], other_registration);
        super::install_agent_integration(&config).unwrap();
        assert_eq!(std::fs::read_to_string(codex_path).unwrap(), first);
    }

    #[test]
    fn temporary_state_startup_leaves_shared_agent_configuration_untouched() {
        let directory = tempfile::tempdir().unwrap();
        let home = directory.path().join("home");
        let claude = home.join(".claude");
        let codex = home.join(".codex");
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::create_dir_all(&codex).unwrap();
        let files = [
            (
                claude.join("settings.json"),
                r#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-stop"}]}]}}"#,
            ),
            (
                home.join(".claude.json"),
                r#"{"mcpServers":{"mine":{"command":"my-server"}}}"#,
            ),
            (
                claude.join(".claude.json"),
                r#"{"mcpServers":{"mine":{"command":"my-server"}}}"#,
            ),
            (codex.join("config.toml"), "notify = ['my-notify']\n"),
        ];
        for (path, contents) in &files {
            std::fs::write(path, contents).unwrap();
        }
        let mut config = Config::new(directory.path().join("temporary-state"));
        config.pane_env = vec![
            ("HOME".into(), home.to_string_lossy().into_owned()),
            (
                agents::CLAUDE_DIR_VAR.into(),
                claude.to_string_lossy().into_owned(),
            ),
            (
                agents::CODEX_DIR_VAR.into(),
                codex.to_string_lossy().into_owned(),
            ),
        ];
        super::install_agent_integration(&config).unwrap();
        for (path, contents) in &files {
            assert_eq!(
                std::fs::read_to_string(path).unwrap(),
                *contents,
                "{} was changed",
                path.display()
            );
        }
    }

    #[test]
    fn development_startup_never_writes_shared_agent_configuration() {
        if !brand::IS_DEV {
            return;
        }
        let directory = tempfile::tempdir().unwrap();
        let mut config = Config::new(directory.path().join("state"));
        config.pane_env.push((
            "HOME".into(),
            directory.path().to_string_lossy().into_owned(),
        ));
        super::install_agent_integration(&config).unwrap();
        assert!(!directory.path().join(".claude").exists());
        assert!(!directory.path().join(".claude.json").exists());
        assert!(!directory.path().join(".codex").exists());
    }

    #[test]
    fn manual_agents_get_tools_and_hooks_without_losing_their_settings() {
        let directory = tempfile::tempdir().unwrap();
        let home_directory = directory.path().join("home");
        let claude_directory = home_directory.join(".claude");
        let codex_directory = home_directory.join(".codex");
        std::fs::create_dir_all(&claude_directory).unwrap();
        std::fs::create_dir_all(&codex_directory).unwrap();
        let claude_settings = claude_directory.join("settings.json");
        let original_settings = json!({
            "statusLine": { "type": "command", "command": "my-status" },
            "hooks": { "Stop": [{"hooks":[{"type":"command", "command":"my-stop"}]}] },
            "permissions": { "deny": ["Bash(secret)"] }
        });
        std::fs::write(&claude_settings, original_settings.to_string()).unwrap();
        let claude_config = claude_directory.join(".claude.json");
        std::fs::write(
            &claude_config,
            r#"{"numStartups":7,"mcpServers":{"mine":{"command":"my-server"}}}"#,
        )
        .unwrap();
        let codex_config = codex_directory.join("config.toml");
        std::fs::write(&codex_config, "# keep this\nmodel = 'chosen-model'\nnotify = ['my-notify', 'argument with spaces']\n\n[mcp_servers.mine]\ncommand = 'my-server'\n").unwrap();
        let mut config = Config::new(directory.path().join("state"));
        config.pane_env = vec![
            ("HOME".into(), home_directory.to_string_lossy().into_owned()),
            (
                agents::CLAUDE_DIR_VAR.into(),
                home_directory
                    .join(".claude")
                    .to_string_lossy()
                    .into_owned(),
            ),
            (
                agents::CODEX_DIR_VAR.into(),
                home_directory.join(".codex").to_string_lossy().into_owned(),
            ),
        ];
        config.agent_integration = crate::AgentIntegration::Install;
        super::install_agent_integration(&config).unwrap();
        let settings: Value =
            serde_json::from_slice(&std::fs::read(&claude_settings).unwrap()).unwrap();
        assert_eq!(settings["statusLine"], original_settings["statusLine"]);
        assert_eq!(
            settings["permissions"]["deny"],
            original_settings["permissions"]["deny"]
        );
        let stop_hooks = settings["hooks"]["Stop"].as_array().unwrap();
        assert_eq!(stop_hooks.len(), 2);
        assert_eq!(stop_hooks[0], original_settings["hooks"]["Stop"][0]);
        let registered: Value =
            serde_json::from_slice(&std::fs::read(&claude_config).unwrap()).unwrap();
        assert_eq!(registered["numStartups"], 7);
        assert_eq!(registered["mcpServers"]["mine"]["command"], "my-server");
        assert_eq!(
            registered["mcpServers"][agents::mcp_server_name()]["args"],
            json!(["mcp"])
        );
        let codex_text = std::fs::read_to_string(&codex_config).unwrap();
        assert!(codex_text.starts_with("# keep this\nmodel = 'chosen-model'\n"));
        let codex: toml::Table = codex_text.parse().unwrap();
        assert_eq!(
            codex["mcp_servers"]["mine"]["command"].as_str(),
            Some("my-server")
        );
        let notification = codex["notify"].as_array().unwrap();
        assert_eq!(notification[1].as_str(), Some("codex-notify"));
        let original_notify: Vec<String> =
            serde_json::from_str(notification[2].as_str().unwrap()).unwrap();
        assert_eq!(original_notify, ["my-notify", "argument with spaces"]);
        super::install_agent_integration(&config).unwrap();
        assert_eq!(std::fs::read_to_string(&codex_config).unwrap(), codex_text);
        assert_eq!(
            serde_json::from_slice::<Value>(&std::fs::read(&claude_settings).unwrap()).unwrap(),
            settings
        );
    }

    #[test]
    fn a_foreign_server_with_our_name_is_left_alone() {
        let directory = tempfile::tempdir().unwrap();
        let home_directory = directory.path().join("home");
        std::fs::create_dir_all(&home_directory).unwrap();
        let config_path = home_directory.join(".claude/.claude.json");
        std::fs::create_dir_all(config_path.parent().unwrap()).unwrap();
        let original =
            json!({"mcpServers": {agents::mcp_server_name(): {"command":"another-server"}}})
                .to_string();
        std::fs::write(&config_path, &original).unwrap();
        let mut config = Config::new(directory.path().join("state"));
        config.pane_env = vec![
            ("HOME".into(), home_directory.to_string_lossy().into_owned()),
            (
                agents::CLAUDE_DIR_VAR.into(),
                home_directory
                    .join(".claude")
                    .to_string_lossy()
                    .into_owned(),
            ),
            (
                agents::CODEX_DIR_VAR.into(),
                home_directory.join(".codex").to_string_lossy().into_owned(),
            ),
        ];
        let _ = install_agent_integration(&config);
        assert_eq!(std::fs::read_to_string(config_path).unwrap(), original);
    }
    #[test]
    fn malformed_and_linked_configs_are_preserved_while_other_agents_are_configured() {
        let directory = tempfile::tempdir().unwrap();
        let claude_directory = directory.path().join("claude");
        let codex_directory = directory.path().join("codex");
        std::fs::create_dir(&claude_directory).unwrap();
        let linked_settings = directory.path().join("linked-settings.json");
        std::fs::write(&linked_settings, "malformed settings").unwrap();
        std::os::unix::fs::symlink(&linked_settings, claude_directory.join("settings.json"))
            .unwrap();
        let mut config = Config::new(directory.path().join("state"));
        config.pane_env = vec![
            (
                "HOME".into(),
                directory.path().to_string_lossy().into_owned(),
            ),
            (
                agents::CLAUDE_DIR_VAR.into(),
                claude_directory.to_string_lossy().into_owned(),
            ),
            (
                agents::CODEX_DIR_VAR.into(),
                codex_directory.to_string_lossy().into_owned(),
            ),
        ];
        assert!(install_agent_integration(&config).is_err());
        assert_eq!(
            std::fs::read_to_string(&linked_settings).unwrap(),
            "malformed settings"
        );
        assert!(
            std::fs::symlink_metadata(claude_directory.join("settings.json"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        let codex_config = codex_directory.join("config.toml");
        assert!(codex_config.exists());
        std::fs::write(&codex_config, "notify = false\n").unwrap();
        assert!(install_agent_integration(&config).is_err());
        assert_eq!(
            std::fs::read_to_string(codex_config).unwrap(),
            "notify = false\n"
        );
    }

    /// Claude Code rewrites its own files in its own layout and key order while it runs: a start
    /// that finds our entries in place writes nothing.
    #[test]
    fn a_start_with_nothing_to_change_leaves_the_files_as_they_are() {
        let directory = tempfile::tempdir().unwrap();
        let config = private_config(directory.path());
        let settings_path = config.home().join(".claude/settings.json");
        let server_path = config.home().join(".claude/.claude.json");
        let codex_path = config.home().join(".codex/config.toml");
        std::fs::write(
            &settings_path,
            "{\"theme\": \"dark\", \"alwaysThinking\": true}",
        )
        .unwrap();
        std::fs::write(&server_path, "{\"numStartups\": 3, \"autoUpdates\": false}").unwrap();
        install_agent_integration(&config).unwrap();
        let settings = std::fs::read_to_string(&settings_path).unwrap();
        let servers = std::fs::read_to_string(&server_path).unwrap();

        let installed: Value = serde_json::from_str(&settings).unwrap();
        let rewritten_settings = format!(
            "{{\"zz\":1,\"hooks\":{},\"theme\":\"dark\",\"alwaysThinking\":true}}",
            installed["hooks"]
        );
        let installed: Value = serde_json::from_str(&servers).unwrap();
        let rewritten_servers = format!(
            "{{\n\t\"userID\": \"x\",\n\t\"mcpServers\": {},\n\t\"numStartups\": 4\n}}",
            installed["mcpServers"]
        );
        std::fs::write(&settings_path, &rewritten_settings).unwrap();
        std::fs::write(&server_path, &rewritten_servers).unwrap();
        let codex = std::fs::read_to_string(&codex_path).unwrap();
        install_agent_integration(&config).unwrap();
        assert_eq!(
            std::fs::read_to_string(&settings_path).unwrap(),
            rewritten_settings
        );
        assert_eq!(
            std::fs::read_to_string(&server_path).unwrap(),
            rewritten_servers
        );
        assert_eq!(std::fs::read_to_string(&codex_path).unwrap(), codex);
    }
}
