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
