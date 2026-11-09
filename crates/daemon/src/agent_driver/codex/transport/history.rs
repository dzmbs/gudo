use super::{Live, peer};
use crate::core::lock;
use agents::CodexThreadBinding;
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use std::io;
use std::sync::Arc;
use tokio_websockets::{ClientBuilder, Limits, Message, WebSocketStream};

type Connection = WebSocketStream<tokio::net::UnixStream>;

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
                std::time::Duration::from_secs(5),
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
                let _ = sender.try_send((false, Vec::new()));
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
    let stream = tokio::net::UnixStream::connect(path).await?;
    if !peer::in_tree(peer::pid(&stream)?, server).await {
        return Err(io::Error::other("wrong Codex history peer"));
    }
    let (mut connection, _) = ClientBuilder::new()
        .uri("ws://localhost/")
        .map_err(io::Error::other)?
        .limits(Limits::default().max_payload_len(Some(64 * 1024)))
        .connect_on(stream)
        .await
        .map_err(io::Error::other)?;
    connection.send(Message::text(json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":brand::CLI_BIN,"version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}}).to_string())).await.map_err(io::Error::other)?;
    reply(&mut connection, 1).await?;
    connection
        .send(Message::text(r#"{"method":"initialized"}"#))
        .await
        .map_err(io::Error::other)?;
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
    reply(&mut connection, 2).await
}

fn history_request(
    state: &super::super::State,
    binding: &CodexThreadBinding,
) -> io::Result<String> {
    if state.closed || !state.binding.is_current(binding) {
        return Err(io::Error::other("Codex history binding changed"));
    }
    // Only read the already proven thread; never start or resume a conversation.
    Ok(json!({"id":2,"method":"thread/read","params":{"threadId":binding.thread_id(),"includeTurns":true}}).to_string())
}

async fn reply(connection: &mut Connection, expected: i64) -> io::Result<String> {
    #[derive(serde::Deserialize)]
    struct Header {
        id: Option<agents::CodexRpcId>,
        error: Option<serde::de::IgnoredAny>,
    }
    for _ in 0..256 {
        let message = connection
            .next()
            .await
            .ok_or_else(|| io::Error::other("Codex history connection closed"))?
            .map_err(io::Error::other)?;
        let Some(text) = message.as_text() else {
            continue;
        };
        let header: Header = serde_json::from_str(text).map_err(io::Error::other)?;
        if header.id == Some(agents::CodexRpcId::Integer(expected)) {
            if header.error.is_some() {
                return Err(io::Error::other("Codex history request failed"));
            }
            return Ok(text.to_owned());
        }
    }
    Err(io::Error::other("Codex history reply allowance exceeded"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialization_rejects_a_binding_retired_during_connection_initialization() {
        let mut state = super::super::super::State::new();
        state.observe(r#"{"id":1,"method":"thread/start"}"#, true);
        state.observe(r#"{"id":1,"result":{"thread":{"id":"primary"}}}"#, false);
        let binding = state.current.clone().unwrap();
        assert!(history_request(&state, &binding).is_ok());
        state.observe(
            r#"{"id":2,"method":"thread/resume","params":{"threadId":"other"}}"#,
            true,
        );
        assert!(history_request(&state, &binding).is_err());
    }
}
