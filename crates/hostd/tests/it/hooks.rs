use std::path::Path;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

use client_core::proto::{AgentState, PaneId, Secret};
use client_core::{AskpassEvent, ClientConfig};
use serde_json::{Value, json};

use crate::support::TestClient;

fn hook_command(executable: &Path, state_directory: &Path, pane_id: PaneId) -> Command {
    let mut command = Command::new(executable);
    command
        .env("GUDO_ENDPOINT_FILE", state_directory.join("hook.endpoint"))
        .env(
            "GUDO_TOKEN",
            std::fs::read_to_string(state_directory.join("hook.token")).unwrap(),
        )
        .env("GUDO_PANE_ID", pane_id.0.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true);
    command
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_shipped_daemon_provides_hooks_askpass_and_mcp_without_a_separate_shim() {
    let directory = tempfile::tempdir().unwrap();
    let executable = directory.path().join(brand::DAEMON_BIN);
    std::fs::copy(env!("CARGO_BIN_EXE_gudo-hostd"), &executable).unwrap();
    let state_directory = directory.path().join("state");
    let home = directory.path().join("home");
    std::fs::create_dir(&home).unwrap();
    std::fs::create_dir(home.join(".codex")).unwrap();
    let notification_path = directory.path().join("user-notification.json");
    let user_notification = vec![
        "/bin/sh".to_owned(),
        "-c".to_owned(),
        format!(
            "printf '%s' \"$1\" > {}",
            agents::shell_quote(&notification_path.to_string_lossy())
        ),
        "notify".to_owned(),
    ];
    std::fs::write(
        home.join(".codex/config.toml"),
        format!(
            "notify = {}\n",
            serde_json::to_string(&user_notification).unwrap()
        ),
    )
    .unwrap();
    let _daemon = Command::new(&executable)
        .arg("--state-dir")
        .arg(&state_directory)
        .args([
            "run",
            "--no-relay",
            "--bind",
            "127.0.0.1:0",
            "--shell",
            "/bin/sh",
        ])
        .env("HOME", &home)
        .env("CODEX_HOME", home.join(".codex"))
        .env("CLAUDE_CONFIG_DIR", home.join(".claude"))
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let pairing_output = Command::new(&executable)
        .arg("--state-dir")
        .arg(&state_directory)
        .args(["pair", "--json", "--local", "--wait", "20"])
        .output()
        .await
        .unwrap();
    assert!(
        pairing_output.status.success(),
        "{}",
        String::from_utf8_lossy(&pairing_output.stderr)
    );
    let pairing: Value = serde_json::from_slice(&pairing_output.stdout).unwrap();
    let mut client = TestClient::connect_askpass(
        pairing["ticket"].as_str().unwrap(),
        ClientConfig::generate_key(),
    );
    let pane = client.attach_and_follow().await;
    assert!(!executable.with_file_name(brand::HOOK_BIN).exists());
    let launcher = state_directory.join("bin").join(brand::HOOK_BIN);

    let mut event = hook_command(&launcher, &state_directory, pane)
        .args(["claude", "UserPromptSubmit"])
        .spawn()
        .unwrap();
    event
        .stdin
        .take()
        .unwrap()
        .write_all(br#"{"hook_event_name":"UserPromptSubmit","session_id":"test-session"}"#)
        .await
        .unwrap();
    assert!(event.wait().await.unwrap().success());
    client
        .until("hook updates agent state", |client| {
            client
                .metas
                .get(&pane)
                .and_then(|meta| meta.agent.as_ref())
                .is_some_and(|agent| matches!(agent.state, AgentState::Running))
        })
        .await;

    let mut askpass = hook_command(&launcher, &state_directory, pane)
        .args(["askpass", "Password:"])
        .spawn()
        .unwrap();
    client
        .until("askpass reaches client", |client| {
            !client.askpass.is_empty()
        })
        .await;
    let prompt = client
        .askpass
        .iter()
        .find_map(|event| match event {
            AskpassEvent::Prompt(prompt) => Some(prompt),
            _ => None,
        })
        .unwrap();
    client
        .client
        .answer_askpass(prompt.id, Secret::new(b"test-answer".to_vec()))
        .await
        .unwrap();
    let mut answer = String::new();
    BufReader::new(askpass.stdout.take().unwrap())
        .read_line(&mut answer)
        .await
        .unwrap();
    assert_eq!(answer, "test-answer\n");
    assert!(askpass.wait().await.unwrap().success());

    for (program, needs_hook_subcommand) in [(&launcher, false), (&executable, true)] {
        let mut command = hook_command(program, &state_directory, pane);
        if needs_hook_subcommand {
            command.arg("hook");
        }
        let mut server = command.arg("mcp").spawn().unwrap();
        let mut server_input = server.stdin.take().unwrap();
        let mut server_output = BufReader::new(server.stdout.take().unwrap());
        for (request_id, method, parameters) in [
            (
                1,
                "initialize",
                json!({"protocolVersion":"2024-11-05", "capabilities":{}, "clientInfo":{"name":"test", "version":"1"}}),
            ),
            (2, "tools/call", json!({"name":"pane_list", "arguments":{}})),
        ] {
            let request =
                json!({"jsonrpc":"2.0", "id":request_id, "method":method, "params":parameters});
            server_input
                .write_all(format!("{request}\n").as_bytes())
                .await
                .unwrap();
            let mut line = String::new();
            server_output.read_line(&mut line).await.unwrap();
            let response: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(response["id"], request_id);
            assert!(response.get("error").is_none(), "{response}");
            assert_ne!(response["result"]["isError"], true, "{response}");
            if request_id == 2 {
                let panes = response["result"]["structuredContent"]["panes"]
                    .as_array()
                    .unwrap();
                assert!(
                    panes
                        .iter()
                        .any(|entry| entry["id"] == format!("p{}", pane.0)),
                    "{response}"
                );
            }
        }
        drop(server_input);
        assert!(server.wait().await.unwrap().success());
    }

    let tools_directory = directory.path().join("tools");
    std::fs::create_dir(&tools_directory).unwrap();
    for agent_name in ["claude", "codex"] {
        use std::os::unix::fs::PermissionsExt;
        let agent_path = tools_directory.join(agent_name);
        std::fs::write(&agent_path, format!(
            "#!/bin/sh\nexport GUDO_TEST_MANUAL_AGENT={}\nexec {} --exact hooks::manual_agent_process --nocapture\n",
            agent_name,
            agents::shell_quote(&std::env::current_exe().unwrap().to_string_lossy()),
        )).unwrap();
        std::fs::set_permissions(&agent_path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    client.type_line(
        pane,
        &format!(
            "export HOME={} CLAUDE_CONFIG_DIR={} CODEX_HOME={} PATH={}:$PATH; claude; codex",
            agents::shell_quote(&home.to_string_lossy()),
            agents::shell_quote(&home.join(".claude").to_string_lossy()),
            agents::shell_quote(&home.join(".codex").to_string_lossy()),
            agents::shell_quote(&tools_directory.to_string_lossy()),
        ),
    );
    client.wait_text(pane, "manual-claude-tools-ok").await;
    client.wait_text(pane, "manual-codex-tools-ok").await;
    assert!(
        client
            .agent_events
            .iter()
            .any(|event| event.contains("manual-claude"))
    );
    assert!(
        client
            .agent_events
            .iter()
            .any(|event| event.contains("manual-codex"))
    );
    let notification: Value =
        serde_json::from_slice(&std::fs::read(notification_path).unwrap()).unwrap();
    assert_eq!(
        notification["last-assistant-message"],
        "Manual agent completed"
    );

    let alias = directory.path().join("alias");
    std::fs::create_dir(&alias).unwrap();
    let alias = alias.join(brand::HOOK_BIN);
    std::os::unix::fs::symlink(&executable, &alias).unwrap();
    assert!(
        hook_command(&alias, &state_directory, pane)
            .args(["askpass", "--available"])
            .status()
            .await
            .unwrap()
            .success()
    );
}

#[test]
fn manual_agent_process() {
    use std::io::{BufRead, BufReader, Write};
    use std::process::Command;

    let Ok(agent_name) = std::env::var("GUDO_TEST_MANUAL_AGENT") else {
        return;
    };
    let server = if agent_name == "claude" {
        let config_directory =
            std::path::PathBuf::from(std::env::var_os("CLAUDE_CONFIG_DIR").unwrap());
        let settings: Value =
            serde_json::from_slice(&std::fs::read(config_directory.join("settings.json")).unwrap())
                .unwrap();
        for group in settings["hooks"]["UserPromptSubmit"].as_array().unwrap() {
            for handler in group["hooks"].as_array().unwrap() {
                let mut hook_process = Command::new("/bin/sh")
                    .args(["-c", handler["command"].as_str().unwrap()])
                    .stdin(Stdio::piped())
                    .spawn()
                    .unwrap();
                hook_process
                    .stdin
                    .take()
                    .unwrap()
                    .write_all(
                        br#"{"hook_event_name":"UserPromptSubmit", "session_id":"manual-claude"}"#,
                    )
                    .unwrap();
                assert!(hook_process.wait().unwrap().success());
            }
        }
        let settings: Value =
            serde_json::from_slice(&std::fs::read(config_directory.join(".claude.json")).unwrap())
                .unwrap();
        settings["mcpServers"][agents::mcp_server_name()].clone()
    } else {
        let config_directory = std::path::PathBuf::from(std::env::var_os("CODEX_HOME").unwrap());
        let settings: toml::Table = std::fs::read_to_string(config_directory.join("config.toml"))
            .unwrap()
            .parse()
            .unwrap();
        let notification = settings["notify"].as_array().unwrap();
        assert!(Command::new(notification[0].as_str().unwrap())
            .args(notification[1..].iter().map(|argument| argument.as_str().unwrap()))
            .arg(json!({"type":"agent-turn-complete", "thread-id":"manual-codex", "last-assistant-message":"Manual agent completed"}).to_string())
            .status().unwrap().success());
        serde_json::to_value(&settings["mcp_servers"][agents::mcp_server_name()]).unwrap()
    };
    let mut process = Command::new(server["command"].as_str().unwrap())
        .args(
            server["args"]
                .as_array()
                .unwrap()
                .iter()
                .map(|argument| argument.as_str().unwrap()),
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut server_input = process.stdin.take().unwrap();
    let mut server_output = BufReader::new(process.stdout.take().unwrap());
    for (request_id, method, parameters) in [
        (
            1,
            "initialize",
            json!({"protocolVersion":"2025-06-18", "capabilities":{}, "clientInfo":{"name":"manual-agent", "version":"1"}}),
        ),
        (2, "tools/call", json!({"name":"pane_list", "arguments":{}})),
    ] {
        writeln!(
            server_input,
            "{}",
            json!({"jsonrpc":"2.0", "id":request_id, "method":method, "params":parameters})
        )
        .unwrap();
        let mut line = String::new();
        server_output.read_line(&mut line).unwrap();
        let response: Value = serde_json::from_str(&line).unwrap();
        assert!(response.get("error").is_none(), "{response}");
        if request_id == 2 {
            assert!(
                !response["result"]["structuredContent"]["panes"]
                    .as_array()
                    .unwrap()
                    .is_empty(),
                "{response}"
            );
        }
    }
    drop(server_input);
    assert!(process.wait().unwrap().success());
    println!("manual-{agent_name}-tools-ok");
}
