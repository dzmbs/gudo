//! Agent install checks end to end: the daemon offers them, and finds each agent's command
//! on its login shell's `PATH`, in an installer's directory off that `PATH`, or nowhere.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use client_core::ClientConfig;
use client_core::proto::{AgentInstall, AgentKind, DaemonFeatures, InstallState};

use crate::support::{TestClient, start_with, ticket};

fn executable(path: &Path) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn state(installs: &[AgentInstall], kind: AgentKind) -> InstallState {
    installs
        .iter()
        .find(|i| i.agent == kind)
        .map(|i| i.state.clone())
        .unwrap()
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

#[tokio::test(flavor = "multi_thread")]
async fn reports_installed_off_path_and_missing_agents() {
    let state_dir = tempfile::tempdir().unwrap();
    let home_dir = tempfile::tempdir().unwrap();
    let home = home_dir.path().canonicalize().unwrap();
    let bin = home.join("bin");
    executable(&bin.join("codex"));
    executable(&home.join(".local/bin/claude"));
    let env = [
        ("HOME".to_owned(), s(&home)),
        (
            "PATH".to_owned(),
            format!("{}:/usr/bin:/bin", bin.display()),
        ),
    ];
    let daemon = start_with(state_dir.path(), move |c| c.pane_env.extend(env)).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;
    let features = c.client.daemon_info().unwrap().features;
    assert!(features.contains(DaemonFeatures::AGENT_INSTALLS));

    let installs = c.client.agent_installs().await.unwrap();
    assert_eq!(
        state(&installs, AgentKind::Codex),
        InstallState::Installed {
            path: s(&bin.join("codex"))
        }
    );
    assert_eq!(
        state(&installs, AgentKind::Claude),
        InstallState::NotOnPath {
            path: s(&home.join(".local/bin/claude"))
        }
    );

    // Asked again, the answer is fresh.
    std::fs::remove_file(bin.join("codex")).unwrap();
    let installs = c.client.agent_installs().await.unwrap();
    assert_eq!(state(&installs, AgentKind::Codex), InstallState::Missing);
}

#[tokio::test(flavor = "multi_thread")]
async fn names_each_installed_agents_mcp_command() {
    let state_dir = tempfile::tempdir().unwrap();
    let home_dir = tempfile::tempdir().unwrap();
    let home = home_dir.path().canonicalize().unwrap();
    let bin = home.join("bin");
    executable(&bin.join("codex"));
    executable(&home.join(".local/bin/claude"));
    let env = [
        ("HOME".to_owned(), s(&home)),
        (
            "PATH".to_owned(),
            format!("{}:/usr/bin:/bin", bin.display()),
        ),
    ];
    let daemon = start_with(state_dir.path(), move |c| c.pane_env.extend(env)).await;
    let mut c = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    c.attach_and_follow().await;
    let features = c.client.daemon_info().unwrap().features;
    assert!(features.contains(DaemonFeatures::AGENT_MCP));

    let add = c.client.agent_mcp_commands(true).await.unwrap();
    let claude = add.iter().find(|c| c.agent == AgentKind::Claude).unwrap();
    // Every agent is named by path, on the terminal `PATH` or off it.
    assert_eq!(claude.argv[0], s(&home.join(".local/bin/claude")));
    assert_eq!(
        claude.argv[1..6],
        ["mcp", "add", "--scope", "user", "unnamed"]
    );
    let codex = add.iter().find(|c| c.agent == AgentKind::Codex).unwrap();
    assert_eq!(
        codex.argv[..5],
        [
            s(&bin.join("codex")).as_str(),
            "mcp",
            "add",
            "unnamed",
            "--"
        ]
    );
    assert!(codex.argv[5].ends_with("un-hook"));
    assert_eq!(codex.argv[6..8], ["mcp", "--state"]);

    // A registration under the server's old name is removed first, and only where it exists.
    std::fs::write(
        home.join(".claude.json"),
        r#"{"mcpServers":{"unnamed_drawings":{"command":"un-hook"}}}"#,
    )
    .unwrap();
    let add = c.client.agent_mcp_commands(true).await.unwrap();
    let claude: Vec<_> = add
        .iter()
        .filter(|c| c.agent == AgentKind::Claude)
        .collect();
    assert_eq!(
        claude[0].argv[1..],
        ["mcp", "remove", "--scope", "user", "unnamed_drawings"]
    );
    assert_eq!(claude[1].argv[2], "add");
    assert_eq!(
        add.iter().filter(|c| c.agent == AgentKind::Codex).count(),
        1
    );

    std::fs::remove_file(bin.join("codex")).unwrap();
    std::fs::remove_file(home.join(".claude.json")).unwrap();
    let remove = c.client.agent_mcp_commands(false).await.unwrap();
    assert_eq!(remove.len(), 1, "a missing agent has no command");
    assert_eq!(
        remove[0].argv[1..],
        ["mcp", "remove", "--scope", "user", "unnamed"]
    );
}
