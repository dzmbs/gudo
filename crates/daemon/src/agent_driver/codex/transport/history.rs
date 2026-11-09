use super::{Live, rpc};
use crate::core::lock;
use agents::CodexThreadBinding;
use futures_util::SinkExt;
use serde_json::json;
use std::io;
use std::sync::Arc;
use std::time::Duration;
use tokio_websockets::Message;

const HISTORY_WAIT: Duration = Duration::from_secs(5);

impl Live {
    pub(in crate::agent_driver::codex) fn load_history(
        self: &Arc<Self>,
        binding: CodexThreadBinding,
    ) {
        if let Some(task) = lock(&self.history_task).take() {
            task.abort();
        }
        let server = self.directory.join("server.sock");
        let Some(pid) = lock(&self.process)
            .as_ref()
            .and_then(tokio::process::Child::id)
        else {
            return;
        };
        let weak = Arc::downgrade(self);
        let task = tokio::spawn(async move {
            {
                let Some(source) = weak.upgrade() else {
                    return;
                };
                if source.target().is_none() || !lock(&source.state).binding.is_current(&binding) {
                    return;
                }
            }
            let result = tokio::time::timeout(
                HISTORY_WAIT,
                read(server, pid, weak.clone(), binding.clone()),
            )
            .await
            .map_err(io::Error::other)
            .and_then(|result| result);
            let Some(source) = weak.upgrade() else {
                return;
            };
            {
                let state = lock(&source.state);
                if !state.binding.is_current(&binding) || state.closed {
                    return;
                }
                *lock(&source.history_result) = Some((binding, result));
            }
            if let Some(sender) = lock(&source.observations).as_ref() {
                let _ = sender.try_send(super::Observation::HistoryReady);
            }
        });
        *lock(&self.history_task) = Some(task.abort_handle());
    }
}

async fn read(
    path: std::path::PathBuf,
    server: u32,
    source: std::sync::Weak<Live>,
    binding: CodexThreadBinding,
) -> io::Result<String> {
    let mut connection = rpc::connect(&path, server).await?;
    // Initialize may await: recheck ownership and binding at actual request serialization.
    let request = {
        let source = source
            .upgrade()
            .ok_or_else(|| io::Error::other("Codex source ended"))?;
        if source.target().is_none() {
            return Err(io::Error::other("Codex pane changed"));
        }
        let state = lock(&source.state);
        history_request(&state, &binding)?
    };
    connection
        .send(Message::text(request))
        .await
        .map_err(io::Error::other)?;
    rpc::reply(&mut connection, rpc::REQUEST_ID).await
}

fn history_request(
    state: &super::super::State,
    binding: &CodexThreadBinding,
) -> io::Result<String> {
    if state.closed || !state.binding.is_current(binding) {
        return Err(io::Error::other("Codex history binding changed"));
    }
    // Only read the already proven thread; never start or resume a conversation.
    Ok(json!({"id":rpc::REQUEST_ID,"method":"thread/read","params":{"threadId":binding.thread_id(),"includeTurns":true}}).to_string())
}

#[cfg(test)]
mod tests {
    use super::super::Direction;
    use super::*;

    #[test]
    fn serialization_rejects_a_binding_retired_during_connection_initialization() {
        let mut state = super::super::super::State::new();
        state.observe(r#"{"id":1,"method":"thread/start"}"#, Direction::FromTui);
        state.observe(
            r#"{"id":1,"result":{"thread":{"id":"primary"}}}"#,
            Direction::FromServer,
        );
        let binding = state.current.clone().unwrap();
        assert!(history_request(&state, &binding).is_ok());
        state.observe(
            r#"{"id":2,"method":"thread/resume","params":{"threadId":"other"}}"#,
            Direction::FromTui,
        );
        assert!(history_request(&state, &binding).is_err());
    }
}
