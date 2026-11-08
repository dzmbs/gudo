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
                read(server, pid, binding.thread_id()),
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

async fn read(path: std::path::PathBuf, server: u32, thread: &str) -> io::Result<String> {
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
    // Read only the already proven thread. This connection never starts or resumes a conversation.
    connection
        .send(Message::text(
            json!({"id":2,"method":"thread/read","params":{"threadId":thread,"includeTurns":true}})
                .to_string(),
        ))
        .await
        .map_err(io::Error::other)?;
    reply(&mut connection, 2).await
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
