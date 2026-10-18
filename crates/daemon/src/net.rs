//! Framed reads and writes over iroh streams.

use iroh::endpoint::{ReadExactError, RecvStream, SendStream};
use serde::Serialize;
use serde::de::DeserializeOwned;

/// Errors on a framed stream.
#[derive(Debug, thiserror::Error)]
pub(crate) enum NetError {
    #[error("frame: {0}")]
    Frame(#[from] proto::FrameError),
    #[error("read: {0}")]
    Read(#[from] ReadExactError),
    #[error("write: {0}")]
    Write(#[from] iroh::endpoint::WriteError),
}

/// Writes one framed message.
pub(crate) async fn send<T: Serialize>(stream: &mut SendStream, msg: &T) -> Result<(), NetError> {
    let buf = proto::frame::to_vec(msg)?;
    stream.write_all(&buf).await?;
    Ok(())
}

/// Reads one framed message; `None` at a clean end of stream.
pub(crate) async fn recv<T: DeserializeOwned>(
    stream: &mut RecvStream,
) -> Result<Option<T>, NetError> {
    let mut prefix = [0; proto::frame::LEN_PREFIX];
    match stream.read_exact(&mut prefix).await {
        Ok(()) => {}
        Err(ReadExactError::FinishedEarly(0)) => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    let mut body = vec![0; proto::frame::body_len(prefix, proto::MAX_FRAME_LEN)?];
    stream.read_exact(&mut body).await?;
    Ok(Some(proto::frame::decode_body(&body)?))
}
