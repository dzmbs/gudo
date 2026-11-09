use super::peer;
use futures_util::{SinkExt, StreamExt};
use std::io;
use std::path::Path;
use tokio_websockets::{ClientBuilder, Limits, Message, WebSocketStream};

pub(super) type Connection = WebSocketStream<tokio::net::UnixStream>;

pub(super) async fn connect(path: &Path, server: u32) -> io::Result<Connection> {
    let stream = tokio::net::UnixStream::connect(path).await?;
    if !peer::in_tree(peer::pid(&stream)?, server).await {
        return Err(io::Error::other("wrong Codex RPC peer"));
    }
    let (mut connection, _) = ClientBuilder::new()
        .uri("ws://localhost/")
        .map_err(io::Error::other)?
        .limits(Limits::default().max_payload_len(Some(64 * 1024)))
        .connect_on(stream)
        .await
        .map_err(io::Error::other)?;
    connection.send(Message::text(serde_json::json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":brand::CLI_BIN,"version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}}).to_string())).await.map_err(io::Error::other)?;
    reply(&mut connection, 1).await?;
    connection
        .send(Message::text(r#"{"method":"initialized"}"#))
        .await
        .map_err(io::Error::other)?;
    Ok(connection)
}

pub(super) async fn reply(connection: &mut Connection, expected: i64) -> io::Result<String> {
    for _ in 0..256 {
        let message = connection
            .next()
            .await
            .ok_or_else(|| io::Error::other("Codex RPC connection closed"))?
            .map_err(io::Error::other)?;
        let Some(text) = message.as_text() else {
            continue;
        };
        if is_reply(text, expected)? {
            return Ok(text.to_owned());
        }
    }
    Err(io::Error::other(
        "Codex RPC notification allowance exceeded",
    ))
}

fn is_reply(text: &str, expected: i64) -> io::Result<bool> {
    #[derive(serde::Deserialize)]
    struct Header {
        id: Option<agents::CodexRpcId>,
        method: Option<serde::de::IgnoredAny>,
        result: Option<serde::de::IgnoredAny>,
        error: Option<serde::de::IgnoredAny>,
    }
    let header: Header = serde_json::from_str(text).map_err(io::Error::other)?;
    if header.method.is_some() || header.id != Some(agents::CodexRpcId::Integer(expected)) {
        return Ok(false);
    }
    if header.error.is_some() || header.result.is_none() {
        return Err(io::Error::other("Codex RPC rejected or malformed"));
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_server_request_with_the_same_numeric_id_is_not_a_control_receipt() {
        assert!(
            !is_reply(
                r#"{"id":2,"method":"item/commandExecution/requestApproval","params":{}}"#,
                2
            )
            .unwrap()
        );
        assert!(!is_reply(r#"{"id":"2","result":{}}"#, 2).unwrap());
        assert!(is_reply(r#"{"id":2,"result":{}}"#, 2).unwrap());
        assert!(is_reply(r#"{"id":2,"error":{"code":-1}}"#, 2).is_err());
        assert!(is_reply(r#"{"id":2}"#, 2).is_err());
    }
}
