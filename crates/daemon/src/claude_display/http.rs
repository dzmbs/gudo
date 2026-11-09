use std::io::{self, Read};
use std::net::{Ipv4Addr, SocketAddr};
use std::os::unix::fs::OpenOptionsExt;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::PaneId;
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpSocket, TcpStream};
use tokio::sync::Semaphore;
use tokio::task::{JoinHandle, JoinSet};

use crate::core::{Core, lock};

const RESPONSE: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n{}";
const REQUEST_TIMEOUT: Duration = Duration::from_millis(250);
const HEADER_LIMIT: usize = 4096;
const DRAIN_LIMIT: usize = 512 * 1024;

pub(crate) struct HttpListener {
    address: SocketAddr,
    listener: Mutex<Option<TcpListener>>,
}

struct Request {
    pane: PaneId,
    token: String,
    length: usize,
    body: Vec<u8>,
}

impl HttpListener {
    pub fn bind(state_dir: &std::path::Path) -> io::Result<Self> {
        let port_file = state_dir.join("claude-display.port");
        let port = match std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&port_file)
        {
            Ok(file) => {
                let mut bytes = Vec::new();
                file.take(9).read_to_end(&mut bytes)?;
                if bytes.len() > 8 {
                    return Err(io::Error::other("invalid display port"));
                }
                std::str::from_utf8(&bytes)
                    .ok()
                    .and_then(|port| port.trim().parse::<u16>().ok())
                    .filter(|port| *port != 0)
                    .ok_or_else(|| io::Error::other("invalid display port"))?
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => 0,
            Err(error) => return Err(error),
        };
        let socket = TcpSocket::new_v4()?;
        socket.set_reuseaddr(true)?;
        socket.bind((Ipv4Addr::LOCALHOST, port).into())?;
        let listener = socket.listen(32)?;
        let address = listener.local_addr()?;
        crate::fsutil::write_atomic(&port_file, address.port().to_string().as_bytes())?;
        Ok(Self {
            address,
            listener: Mutex::new(Some(listener)),
        })
    }

    pub fn port(&self) -> u16 {
        self.address.port()
    }

    pub fn url(&self) -> String {
        format!("http://{}/claude/message-display", self.address)
    }

    pub fn listen(&self, core: &Arc<Core>) -> io::Result<JoinHandle<()>> {
        let listener = lock(&self.listener)
            .take()
            .ok_or_else(|| io::Error::other("display listener already started"))?;
        let host = self.address.to_string();
        let core = Arc::clone(core);
        Ok(tokio::spawn(async move {
            let slots = Arc::new(Semaphore::new(8));
            let mut tasks = JoinSet::new();
            loop {
                let Ok(slot) = Arc::clone(&slots).acquire_owned().await else {
                    return;
                };
                let stream = tokio::select! {
                    accepted = listener.accept() => accepted,
                    Some(_) = tasks.join_next(), if !tasks.is_empty() => { continue; }
                };
                let Ok((stream, _)) = stream else {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                };
                let core = Arc::clone(&core);
                let host = host.clone();
                tasks.spawn(async move {
                    serve(&core.hooks.display, stream, &host, |request| {
                        core.hooks.display.receive(
                            &core,
                            request.pane,
                            &request.token,
                            &request.body,
                        );
                    })
                    .await;
                    drop(slot);
                });
            }
        }))
    }
}

async fn serve(
    capture: &super::Capture,
    mut stream: TcpStream,
    host: &str,
    receive: impl FnOnce(Request) + Send,
) {
    let request = tokio::time::timeout(REQUEST_TIMEOUT, read_request(capture, &mut stream, host))
        .await
        .ok()
        .and_then(Result::ok)
        .flatten();
    let acknowledged = tokio::time::timeout(REQUEST_TIMEOUT, async {
        stream.write_all(RESPONSE).await?;
        stream.shutdown().await
    })
    .await
    .is_ok_and(|result| result.is_ok());
    // No capture, render or transcript work may delay the CLI's display acknowledgement.
    if acknowledged && let Some(request) = request {
        receive(request);
    }
}

async fn read_request(
    capture: &super::Capture,
    stream: &mut TcpStream,
    host: &str,
) -> io::Result<Option<Request>> {
    let mut reader = BufReader::new(stream);
    let mut header = Vec::new();
    while header.len() < HEADER_LIMIT && !header.ends_with(b"\r\n\r\n") {
        header.push(reader.read_u8().await?);
    }
    let Some(mut request) = parse_headers(&header, host) else {
        return Ok(None);
    };
    if !capture.verify(request.pane, &request.token) {
        return Ok(None);
    }
    let length = request.length;
    if length > DRAIN_LIMIT {
        return Ok(Some(Request {
            body: Vec::new(),
            ..request
        }));
    }
    if length <= agents::CLAUDE_DISPLAY_BATCH_LIMIT {
        request.body.resize(length, 0);
        reader.read_exact(&mut request.body).await?;
    } else {
        let mut remaining = length;
        let mut scratch = [0u8; 4096];
        while remaining > 0 {
            let count = remaining.min(scratch.len());
            reader.read_exact(&mut scratch[..count]).await?;
            remaining -= count;
        }
        request.body = Vec::new();
    }
    Ok(Some(request))
}

fn parse_headers(bytes: &[u8], host: &str) -> Option<Request> {
    let header = std::str::from_utf8(bytes).ok()?;
    if !header.ends_with("\r\n\r\n") {
        return None;
    }
    let mut lines = header.split("\r\n");
    if lines.next()? != "POST /claude/message-display HTTP/1.1" {
        return None;
    }
    let (mut actual_host, mut token, mut pane, mut length) = (None, None, None, None);
    for line in lines.take_while(|line| !line.is_empty()) {
        let (name, value) = line.split_once(':')?;
        let value = value.trim();
        if name.eq_ignore_ascii_case("host") && actual_host.replace(value).is_some() {
            return None;
        }
        if name.eq_ignore_ascii_case("authorization")
            && token.replace(value.strip_prefix("Bearer ")?).is_some()
        {
            return None;
        }
        if name.eq_ignore_ascii_case("x-gudo-pane")
            && pane.replace(PaneId(value.parse().ok()?)).is_some()
        {
            return None;
        }
        if name.eq_ignore_ascii_case("content-length")
            && length.replace(value.parse::<usize>().ok()?).is_some()
        {
            return None;
        }
        if ["origin", "referer", "transfer-encoding", "content-encoding"]
            .iter()
            .any(|forbidden| name.eq_ignore_ascii_case(forbidden))
        {
            return None;
        }
    }
    if actual_host? != host {
        return None;
    }
    Some(Request {
        pane: pane?,
        token: token?.to_owned(),
        length: length?,
        body: Vec::new(),
    })
}

#[cfg(test)]
mod tests;
