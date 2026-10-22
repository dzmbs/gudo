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
