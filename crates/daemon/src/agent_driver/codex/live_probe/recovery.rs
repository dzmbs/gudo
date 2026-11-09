use super::*;

pub(super) async fn recover(
    daemon: &crate::Daemon,
    root: &Path,
    conversation: &Conversation,
) -> Result<(), String> {
    let (entry, source) = tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            if let Some(entry) = daemon.core.pane(conversation.pane) {
                let source = lock(&entry.codex).clone();
                if let Some(source) = source {
                    if source.fault.load(std::sync::atomic::Ordering::Acquire) {
                        let _ = std::fs::write(
                            root.join("recovered-screen.txt"),
                            entry.pane.screen_text(),
                        );
                        return Err("recovered native source failed".to_owned());
                    }
                    if lock(&source.state).is_ready() {
                        return Ok((entry, source));
                    }
                }
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .map_err(|_| "native recovery timeout".to_owned())??;
    std::fs::write(root.join("recovered-screen.txt"), entry.pane.screen_text())
        .map_err(|error| error.to_string())?;
    crate::agent_input::chat_tests::wait_until(|| {
        lock(&entry.agent)
            .as_ref()
            .unwrap()
            .session()
            .native_id
            .as_ref()
            .is_some_and(|id| id.as_str() == conversation.thread)
    })
    .await;
    if !lock(&source.state).requires_history {
        return Err("recovery did not observe an official resume".into());
    }
    if daemon
        .core
        .pane_account(conversation.pane)
        .as_ref()
        .map(|(_, account)| account.as_str())
        != Some(conversation.account.as_str())
    {
        return Err("recovery lost the named account".into());
    }
    let (client, _events) = crate::agent_input::chat_tests::owner_client(daemon).await;
    let snapshot = client
        .timeline_watch_capabilities(conversation.pane)
        .await
        .map_err(|error| format!("recovered watch: {error:?}"))?;
    if !snapshot.snapshot.items.iter().any(|item| matches!(&item.body, proto::TimelineBody::Assistant { text, streaming: false } if text == "A same-process live mirror.\n")) { return Err(format!("official resume did not hydrate history: {:?}", snapshot.snapshot.items)); }
    if lock(&entry.meta).turns != 0 {
        return Err("recovery recounted historical completion".into());
    }
    Ok(())
}
