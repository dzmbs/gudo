use super::*;

pub(super) async fn terminal(
    daemon: &crate::Daemon,
    entry: &crate::core::PaneEntry,
    root: &Path,
    model_url: &str,
) -> Result<(), String> {
    let result = tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            if lock(&entry.codex).is_none()
                && entry.pane.line_snapshot().bracketed
                && entry.pane.screen_text().contains('›')
            {
                return Ok::<(), String>(());
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .map_err(|_| "unsupported version did not fall back to Terminal".to_string());
    std::fs::write(
        root.join("fallback-startup-screen.txt"),
        entry.pane.screen_text(),
    )
    .map_err(|error| error.to_string())?;
    result??;
    if lock(&entry.agent)
        .as_ref()
        .ok_or("missing legacy runtime")?
        .session()
        .lane
        != agents::Lane::Pty
    {
        return Err("fallback retained structured authority".into());
    }
    let capabilities = crate::agent_driver::driver(AgentKind::Codex)
        .current_capabilities(&daemon.core, entry.pane.id);
    if [
        proto::AgentCapabilities::READ,
        proto::AgentCapabilities::STREAMING_DELTAS,
        proto::AgentCapabilities::STOP,
        proto::AgentCapabilities::APPROVALS,
    ]
    .into_iter()
    .any(|flag| capabilities.contains(flag))
    {
        return Err("unsupported version advertised native controls".into());
    }
    let invocations = std::fs::read_to_string(root.join("cli-invocations.txt"))
        .map_err(|error| error.to_string())?;
    if invocations.contains("app-server") || invocations.contains("--remote") {
        return Err("fallback launched a native server or remote TUI".into());
    }
    entry
        .pane
        .write(b"\x1b[200~Reply with a short fixture sentence.\x1b[201~\r".to_vec())
        .await
        .map_err(|error| error.to_string())?;
    crate::agent_input::chat_tests::wait_until(|| {
        entry.pane.screen_text().contains("A same-process")
    })
    .await;
    super::advance_model(model_url).await?;
    crate::agent_input::chat_tests::wait_until(|| {
        entry.pane.screen_text().contains("live mirror.")
    })
    .await;
    std::fs::write(
        root.join("fallback-final-screen.txt"),
        entry.pane.screen_text(),
    )
    .map_err(|error| error.to_string())?;
    Ok(())
}
