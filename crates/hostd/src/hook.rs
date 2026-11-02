//! `gudo-hook`: the agent hook shim. Agents launched by the daemon run
//! `gudo-hook <agent> <Event>` with the hook payload on stdin; the shim relays it to the
//! daemon's hook socket and prints the daemon's answer (for example a permission decision).
//!
//! `gudo-hook claude StatusLine` is Claude Code's status-line command in sessions the daemon
//! launches: the input (with the plan's `rate_limits`) goes to the daemon, then the shim runs
//! the user's own `statusLine` command from their Claude settings with the same input and lets
//! it print, so the status line looks as the user set it up.
//!
//! It never fails the agent: any error prints nothing and exits 0, so a missing daemon only
//! means the agent falls back to its own prompts.
//!
//! `gudo-hook askpass <prompt>` is the askpass helper instead (see `askpass.rs`), and
//! `gudo-hook mcp [--state <dir>] [--pane <id>]` the MCP server through which agents read the
//! session's drawings and use the app's browser (see `mcp.rs`), and `gudo-hook open-url <url>…`
//! the panes' `BROWSER` (see `browser.rs`), and `gudo-hook browser <verb> …` the browser tools
//! from a shell (see `browser_tools.rs`).

mod askpass;
mod browser;
mod browser_tools;
mod mcp;
mod term_tools;

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use daemon::{HookRequest, HookResponse, STATUS_LINE_EVENT};
use serde_json::Value;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("askpass") => std::process::exit(askpass::main(&args[1..])),
        Some("mcp") => std::process::exit(mcp::main(&args[1..])),
        Some("open-url") => std::process::exit(browser::open_url(&args[1..])),
        Some("browser") => std::process::exit(browser::cli(&args[1..])),
        _ => {}
    }
    let mut payload = Vec::new();
    let _ = std::io::stdin().take(4 << 20).read_to_end(&mut payload);
    let status_line = args.get(1).map(String::as_str) == Some(STATUS_LINE_EVENT);
    if let Err(error) = relay(&args, &payload, status_line)
        && brand::var_os("HOOK_DEBUG").is_some()
    {
        eprintln!("{}: {error}", brand::HOOK_BIN);
    }
    if status_line {
        user_status_line(&payload);
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
