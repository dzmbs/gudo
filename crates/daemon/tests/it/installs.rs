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
        .find(|install| install.agent == kind)
        .map(|install| install.state.clone())
        .unwrap()
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
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
        ("HOME".to_owned(), path_text(&home)),
        (
            "PATH".to_owned(),
            format!("{}:/usr/bin:/bin", bin.display()),
        ),
    ];
    let daemon = start_with(state_dir.path(), move |config| config.pane_env.extend(env)).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let features = owner.client.daemon_info().unwrap().features;
    assert!(features.contains(DaemonFeatures::AGENT_INSTALLS));

    let installs = owner.client.agent_installs().await.unwrap();
    assert_eq!(
        state(&installs, AgentKind::Codex),
        InstallState::Installed {
            path: path_text(&bin.join("codex"))
        }
    );
    assert_eq!(
        state(&installs, AgentKind::Claude),
        InstallState::NotOnPath {
            path: path_text(&home.join(".local/bin/claude"))
        }
    );

    // Asked again, the answer is fresh.
    std::fs::remove_file(bin.join("codex")).unwrap();
    let installs = owner.client.agent_installs().await.unwrap();
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
        ("HOME".to_owned(), path_text(&home)),
        (
            "PATH".to_owned(),
            format!("{}:/usr/bin:/bin", bin.display()),
        ),
    ];
    let daemon = start_with(state_dir.path(), move |config| config.pane_env.extend(env)).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    owner.attach_and_follow().await;
    let features = owner.client.daemon_info().unwrap().features;
    assert!(features.contains(DaemonFeatures::AGENT_MCP));

    let add = owner.client.agent_mcp_commands(true).await.unwrap();
    let claude = add
        .iter()
        .find(|command| command.agent == AgentKind::Claude)
        .unwrap();
    // Every agent is named by path, on the terminal `PATH` or off it.
    assert_eq!(claude.argv[0], path_text(&home.join(".local/bin/claude")));
    assert_eq!(claude.argv[1..6], ["mcp", "add", "--scope", "user", "gudo"]);
    let codex = add
        .iter()
        .find(|command| command.agent == AgentKind::Codex)
        .unwrap();
    assert_eq!(
        codex.argv[..5],
        [
            path_text(&bin.join("codex")).as_str(),
            "mcp",
            "add",
            "gudo",
            "--"
        ]
    );
    assert!(codex.argv[5].ends_with("gudo-hook"));
    assert_eq!(codex.argv[6..8], ["mcp", "--state"]);

    // Registrations under the server's old names are removed first, and only where they exist.
    std::fs::write(
        home.join(".claude.json"),
        r#"{"mcpServers":{"unnamed":{"command":"un-hook"},"unnamed_drawings":{"command":"un-hook"}}}"#,
    )
    .unwrap();
    let add = owner.client.agent_mcp_commands(true).await.unwrap();
    let claude: Vec<_> = add
        .iter()
        .filter(|command| command.agent == AgentKind::Claude)
        .collect();
    assert_eq!(
        claude[0].argv[1..],
        ["mcp", "remove", "--scope", "user", "unnamed"]
    );
    assert_eq!(
        claude[1].argv[1..],
        ["mcp", "remove", "--scope", "user", "unnamed_drawings"]
    );
    assert_eq!(claude[2].argv[2], "add");
    assert_eq!(
        add.iter()
            .filter(|command| command.agent == AgentKind::Codex)
            .count(),
        1
    );

    std::fs::remove_file(bin.join("codex")).unwrap();
    std::fs::remove_file(home.join(".claude.json")).unwrap();
    let remove = owner.client.agent_mcp_commands(false).await.unwrap();
    assert_eq!(remove.len(), 1, "a missing agent has no command");
    assert_eq!(
        remove[0].argv[1..],
        ["mcp", "remove", "--scope", "user", "gudo"]
    );
}
