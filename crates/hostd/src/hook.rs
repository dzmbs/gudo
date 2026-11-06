//! `gudo-hook`: the agent hook shim. Agents launched by the daemon run
//! `gudo-hook <agent> <Event>` with the hook payload on stdin; the shim relays it to the
//! daemon's hook socket and prints the daemon's answer (for example a permission decision).
//!
//! `gudo-hook claude StatusLine` is Claude Code's status-line command in sessions the daemon
//! launches: the input (with the plan's `rate_limits`) goes to the daemon, then the shim runs
//! the user's own `statusLine` command from their Claude settings with the same input and lets
//! it print, so the status line looks as the user set it up.
//!
//! `gudo-hook codex notify <json>` is Codex's `notify` program in sessions the daemon launches:
//! the payload is the last argument (Codex gives no stdin), goes to the daemon, then the shim
//! runs the user's own `notify` from their Codex `config.toml` with the same argument.
//!
//! Ordinary hooks never fail the agent: an error prints nothing and exits 0, so a missing
//! daemon means the agent falls back to its own prompts. The agent input arm/exit fence is
//! different: failure exits nonzero and the launch script must not start its fallback shell.
//!
//! `gudo-hook askpass <prompt>` is the askpass helper instead (see `askpass.rs`), and
//! `gudo-hook mcp [--state <dir>] [--pane <id>]` the MCP server through which agents read the
//! session's drawings and use the app's browser (see `mcp.rs`), and `gudo-hook open-url <url>…`
//! the panes' `BROWSER` (see `browser.rs`), and `gudo-hook browser <verb> …` the browser tools
//! from a shell (see `browser_tools.rs`).

mod agent_exit_fence;
mod askpass;
mod browser;
mod browser_tools;
mod browser_upload;
mod mcp;
mod term_tools;

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use daemon::{CODEX_NOTIFY_EVENT, HookRequest, HookResponse, STATUS_LINE_EVENT};
use serde_json::Value;

pub fn run_hook(arguments: &[String]) {
    match arguments.first().map(String::as_str) {
        Some("agent-input-arm") => std::process::exit(agent_exit_fence::main(
            &arguments[1..],
            agent_exit_fence::FenceAction::Arm,
        )),
        Some("agent-exit-fence") => std::process::exit(agent_exit_fence::main(
            &arguments[1..],
            agent_exit_fence::FenceAction::Close,
        )),
        Some("codex-notify") => {
            relay_codex_notify(&arguments[1..]);
            return;
        }
        Some("askpass") => std::process::exit(askpass::main(&arguments[1..])),
        Some("mcp") => std::process::exit(mcp::main(&arguments[1..])),
        Some("open-url") => std::process::exit(browser::open_url(&arguments[1..])),
        Some("browser") => std::process::exit(browser::cli(&arguments[1..])),
        _ => {}
    }
    let codex_notify = arguments.first().map(String::as_str) == Some("codex")
        && arguments.get(1).map(String::as_str) == Some(CODEX_NOTIFY_EVENT);
    let mut payload = Vec::new();
    if codex_notify {
        payload = arguments
            .get(2)
            .map(|json| json.as_bytes().to_vec())
            .unwrap_or_default();
    } else {
        let _ = std::io::stdin().take(4 << 20).read_to_end(&mut payload);
    }
    let status_line = arguments.get(1).map(String::as_str) == Some(STATUS_LINE_EVENT);
    if let Err(error) = relay(arguments, &payload, status_line)
        && brand::var_os("HOOK_DEBUG").is_some()
    {
        eprintln!("{}: {error}", brand::HOOK_BIN);
    }
    if status_line {
        user_status_line(&payload);
    }
    if codex_notify && let Some(json) = arguments.get(2) {
        user_codex_notify(json);
    }
}

fn relay_codex_notify(arguments: &[String]) {
    let (Some(original_command), Some(payload)) = (arguments.first(), arguments.get(1)) else {
        return;
    };
    let forwarded = ["codex".into(), CODEX_NOTIFY_EVENT.into()];
    let _ = relay(&forwarded, payload.as_bytes(), false);
    let Ok(command) = serde_json::from_str::<Vec<String>>(original_command) else {
        return;
    };
    if let Some(program) = command.first() {
        let _ = Command::new(program)
            .args(&command[1..])
            .arg(payload)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

fn relay(args: &[String], raw: &[u8], status_line: bool) -> Result<(), Box<dyn std::error::Error>> {
    let (Some(agent), Some(event)) = (args.first(), args.get(1)) else {
        return Err("usage: gudo-hook <agent> <event>".into());
    };
    let env = |name: &str| brand::var(name).ok_or(std::env::VarError::NotPresent);
    let payload = serde_json::from_slice(raw).unwrap_or(Value::Null);

    // The endpoint file wins over GUDO_SOCK so a pane outlives a daemon restart that moved it.
    let socket = env("ENDPOINT_FILE")
        .ok()
        .and_then(|file| std::fs::read_to_string(file).ok())
        .map(|contents| PathBuf::from(contents.trim()))
        .or_else(|| env("SOCK").ok().map(PathBuf::from))
        .ok_or("no hook socket")?;
    let request = HookRequest {
        v: 1,
        token: env("TOKEN")?,
        pane: env("PANE_ID")?,
        agent: agent.clone(),
        seq: daemon::hook_seq(),
        payload,
        event: event.clone(),
    };
    let mut stream = UnixStream::connect(socket)?;
    let wait = if event == "PermissionRequest" {
        daemon::PERMISSION_WAIT + Duration::from_secs(2)
    } else if status_line {
        // The status line redraws often; never hold it up.
        Duration::from_secs(1)
    } else {
        Duration::from_secs(5)
    };
    stream.set_read_timeout(Some(wait))?;
    stream.set_write_timeout(Some(wait))?;
    let mut line = serde_json::to_vec(&request)?;
    line.push(b'\n');
    stream.write_all(&line)?;
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer)?;
    let response: HookResponse = serde_json::from_str(&answer)?;
    if let Some(stdout) = response.stdout
        && !status_line
    {
        println!("{stdout}");
    }
    Ok(())
}

/// Runs the status line the user configured (`statusLine.command` in the project's
/// `.claude/settings.local.json`, `.claude/settings.json`, then the account's
/// `settings.json`, by default `~/.claude/settings.json`,
/// Claude's own precedence) with the same input, its output going straight to Claude.
fn user_status_line(raw: &[u8]) {
    let input: Value = serde_json::from_slice(raw).unwrap_or(Value::Null);
    let Some(command) = user_status_command(&input) else {
        return;
    };
    let Ok(mut child) = Command::new("/bin/sh")
        .arg("-c")
        .arg(&command)
        .stdin(Stdio::piped())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
    else {
        return;
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(raw);
    }
    let _ = child.wait();
}

/// Starts the user's own Codex `notify` program (`notify = [...]` in the account's or the
/// user's `config.toml`) with the payload as its last argument, as Codex would have, and leaves
/// it running.
fn user_codex_notify(json: &str) {
    let codex_home = config_dir_from(brand::var_os("ACCOUNT_DIR"), std::env::var_os("CODEX_HOME"))
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".codex")));
    let Some(argv) = codex_home.and_then(|home| user_notify_command(&home.join("config.toml")))
    else {
        return;
    };
    let _ = Command::new(&argv[0])
        .args(&argv[1..])
        .arg(json)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

fn user_notify_command(config: &std::path::Path) -> Option<Vec<String>> {
    let text = std::fs::read_to_string(config).ok()?;
    let table: toml::Table = text.parse().ok()?;
    let mut arguments: Vec<String> = table
        .get("notify")?
        .as_array()?
        .iter()
        .map(|argument| argument.as_str().map(str::to_owned))
        .collect::<Option<_>>()?;
    for _ in 0..64 {
        let is_owned_command = arguments.first().is_some_and(|program| {
            std::path::Path::new(program)
                .file_name()
                .is_some_and(|name| {
                    name == brand::RELEASE_HOOK_BIN
                        || name == brand::DEV_HOOK_BIN
                        || name == brand::legacy::HOOK_BIN
                })
        });
        if !is_owned_command {
            return (!arguments.is_empty()).then_some(arguments);
        }
        if arguments.len() != 3 || arguments[1] != "codex-notify" {
            return None;
        }
        arguments = serde_json::from_str(&arguments[2]).ok()?;
    }
    None
}

/// The pane's Claude configuration directory: its account's (`GUDO_ACCOUNT_DIR`, which Claude's
/// subprocess scrub leaves alone), else `CLAUDE_CONFIG_DIR`; `None` means `~/.claude`.
fn user_config_dir() -> Option<PathBuf> {
    config_dir_from(
        brand::var_os("ACCOUNT_DIR"),
        std::env::var_os("CLAUDE_CONFIG_DIR"),
    )
}

fn config_dir_from(
    account: Option<std::ffi::OsString>,
    claude: Option<std::ffi::OsString>,
) -> Option<PathBuf> {
    account
        .filter(|dir| !dir.is_empty())
        .or(claude)
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
}

fn user_status_command(input: &Value) -> Option<String> {
    let mut files = Vec::new();
    for key in ["/workspace/project_dir", "/workspace/current_dir", "/cwd"] {
        if let Some(dir) = input.pointer(key).and_then(Value::as_str) {
            let dir = PathBuf::from(dir).join(".claude");
            files.push(dir.join("settings.local.json"));
            files.push(dir.join("settings.json"));
        }
    }
    let config = user_config_dir()
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".claude")));
    if let Some(config) = config {
        files.push(config.join("settings.json"));
    }
    files.iter().find_map(|file| {
        let text = std::fs::read_to_string(file).ok()?;
        let settings: Value = serde_json::from_str(&text).ok()?;
        let command = settings.pointer("/statusLine/command")?.as_str()?.trim();
        // Never ourselves (a settings file copied from a launched session).
        let ours = [brand::HOOK_BIN, brand::legacy::HOOK_BIN]
            .iter()
            .any(|bin| command.contains(bin))
            && command.contains(STATUS_LINE_EVENT);
        (!command.is_empty() && !ours).then(|| command.to_owned())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The account's directory wins over `CLAUDE_CONFIG_DIR`, which Claude may scrub from
    /// hook environments or a startup file may point elsewhere.
    #[test]
    fn the_accounts_dir_names_the_status_line_settings() {
        let dir = |path: &str| Some(std::ffi::OsString::from(path));
        assert_eq!(
            config_dir_from(dir("/s/accounts/claude/a1"), dir("/h/.claude")),
            Some(PathBuf::from("/s/accounts/claude/a1"))
        );
        assert_eq!(
            config_dir_from(None, dir("/h/.claude")),
            Some(PathBuf::from("/h/.claude"))
        );
        assert_eq!(config_dir_from(dir(""), None), None);
    }

    #[test]
    fn dedicated_notifications_unwrap_both_flavours_without_relaying_twice() {
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("config.toml");
        let user = vec!["my-notify".to_owned(), "argument with spaces".into()];
        let mut notification = user.clone();
        for program in [brand::RELEASE_HOOK_BIN, brand::DEV_HOOK_BIN] {
            notification = vec![
                format!("/state/bin/{program}"),
                "codex-notify".into(),
                serde_json::to_string(&notification).unwrap(),
            ];
        }
        std::fs::write(
            &config,
            format!(
                "notify = {}\n",
                serde_json::to_string(&notification).unwrap()
            ),
        )
        .unwrap();
        assert_eq!(user_notify_command(&config), Some(user));
    }

    #[test]
    fn finds_the_users_codex_notify_but_never_ours() {
        let dir = tempfile::tempdir().unwrap();
        let config = dir.path().join("config.toml");
        assert_eq!(user_notify_command(&config), None);
        std::fs::write(
            &config,
            "model = \"o3\"\nnotify = [\"python3\", \"/h/notify.py\"]\n",
        )
        .unwrap();
        assert_eq!(
            user_notify_command(&config),
            Some(vec!["python3".to_owned(), "/h/notify.py".to_owned()])
        );
        std::fs::write(
            &config,
            format!(
                "notify = [\"/s/bin/{}\", \"codex\", \"notify\"]\n",
                brand::HOOK_BIN
            ),
        )
        .unwrap();
        assert_eq!(user_notify_command(&config), None);
        std::fs::write(&config, "notify = []\n").unwrap();
        assert_eq!(user_notify_command(&config), None);
    }

    #[test]
    fn finds_the_users_status_line_in_claudes_order() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join("p");
        std::fs::create_dir_all(project.join(".claude")).unwrap();
        let input = serde_json::json!({ "workspace": { "project_dir": project } });
        std::fs::write(
            project.join(".claude/settings.json"),
            r#"{"statusLine":{"type":"command","command":"echo project"}}"#,
        )
        .unwrap();
        assert_eq!(user_status_command(&input).as_deref(), Some("echo project"));
        std::fs::write(
            project.join(".claude/settings.local.json"),
            r#"{"statusLine":{"type":"command","command":"echo local"}}"#,
        )
        .unwrap();
        assert_eq!(user_status_command(&input).as_deref(), Some("echo local"));
        // Never our own command.
        std::fs::write(
            project.join(".claude/settings.local.json"),
            format!(
                r#"{{"statusLine":{{"type":"command","command":"/x/{} claude StatusLine"}}}}"#,
                brand::HOOK_BIN
            ),
        )
        .unwrap();
        assert_eq!(user_status_command(&input).as_deref(), Some("echo project"));
    }
}
