//! The proxy over real sockets, against a hyper upstream that plays the VS Code server.

use std::collections::VecDeque;
use std::io::Read as _;
use std::sync::atomic::{AtomicUsize, Ordering};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use super::*;

const COMMIT: &str = "807ba2d6075c29587f884698cd7370c81ab0724c";

fn script() -> Vec<u8> {
    (0..3000)
        .flat_map(|i| format!("export function f{i}(x) {{ return x * {i}; }}\n").into_bytes())
        .collect()
}

/// A body sent as the given chunks (chunked encoding unless `exact`), with an optional pause
/// before the last one.
struct Chunks {
    chunks: VecDeque<Bytes>,
    exact: Option<u64>,
    pause: Option<Pin<Box<tokio::time::Sleep>>>,
}

impl Chunks {
    fn new(body: &[u8], pieces: usize, exact: bool) -> Self {
        let size = body.len().div_ceil(pieces.max(1)).max(1);
        Self {
            chunks: body.chunks(size).map(Bytes::copy_from_slice).collect(),
            exact: exact.then_some(body.len() as u64),
            pause: None,
        }
    }
}

impl Body for Chunks {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Infallible>>> {
        let this = self.get_mut();
        if this.chunks.len() == 1
            && let Some(pause) = this.pause.as_mut()
        {
            if pause.as_mut().poll(cx).is_pending() {
                return Poll::Pending;
            }
            this.pause = None;
        }
        Poll::Ready(this.chunks.pop_front().map(|c| Ok(Frame::data(c))))
    }

    fn size_hint(&self) -> SizeHint {
        self.exact
            .map_or_else(SizeHint::default, SizeHint::with_exact)
    }
}

fn reply(status: StatusCode, headers: &[(&str, &str)], body: Chunks) -> Response<Chunks> {
    let mut resp = Response::new(body);
    *resp.status_mut() = status;
    for (k, v) in headers {
        resp.headers_mut().append(
            header::HeaderName::from_bytes(k.as_bytes()).unwrap(),
            HeaderValue::from_str(v).unwrap(),
        );
    }
    resp
}

/// The fake server: what VS Code's would send, by path.
fn serve(mut req: Request<Incoming>, hits: &AtomicUsize) -> Response<Chunks> {
    hits.fetch_add(1, Ordering::SeqCst);
    let js = script();
    let path = req.uri().path().to_owned();
    let immutable = [
        ("content-type", "text/javascript"),
        ("cache-control", "public, max-age=31536000"),
    ];
    match path.as_str() {
        p if p.ends_with("/static/app.js") => {
            reply(StatusCode::OK, &immutable, Chunks::new(&js, 7, false))
        }
        "/slow.js" => {
            let mut body = Chunks::new(&js, 2, false);
            body.pause = Some(Box::pin(tokio::time::sleep(Duration::from_millis(1500))));
            reply(StatusCode::OK, &[("content-type", "text/javascript")], body)
        }
        "/data.json" => {
            if req
                .headers()
                .get(header::IF_NONE_MATCH)
                .is_some_and(|v| v == "\"v1\"")
            {
                return reply(
                    StatusCode::NOT_MODIFIED,
                    &[("etag", "\"v1\"")],
                    Chunks::new(b"", 0, true),
                );
            }
            let json = format!("{{\"x\": \"{}\"}}", "y".repeat(4000));
            reply(
                StatusCode::OK,
                &[
                    ("content-type", "application/json"),
                    ("etag", "\"v1\""),
                    ("content-length", &json.len().to_string()),
                ],
                Chunks::new(json.as_bytes(), 1, true),
            )
        }
        "/range.js" => {
            let range = req.headers().contains_key(header::RANGE);
            let total = format!("bytes 0-9/{}", js.len());
            let mut headers = vec![("content-type", "text/javascript")];
            let body = if range {
                headers.push(("content-range", &total));
                &js[..10]
            } else {
                &js[..]
            };
            let status = if range {
                StatusCode::PARTIAL_CONTENT
            } else {
                StatusCode::OK
            };
            reply(status, &headers, Chunks::new(body, 1, true))
        }
        "/pre.js" => reply(
            StatusCode::OK,
            &[
                ("content-type", "text/javascript"),
                ("content-encoding", "gzip"),
            ],
            Chunks::new(b"\x1f\x8b already gzip", 1, true),
        ),
        "/tiny.css" => reply(
            StatusCode::OK,
            &[("content-type", "text/css"), ("content-length", "11")],
            Chunks::new(b"a{color:#f}", 1, true),
        ),
        "/logo.png" => reply(
            StatusCode::OK,
            &[("content-type", "image/png")],
            Chunks::new(&js, 1, true),
        ),
        "/ws" => {
            let upgraded = hyper::upgrade::on(&mut req);
            tokio::spawn(async move {
                let mut io = TokioIo::new(upgraded.await.unwrap());
                let mut buf = [0; 64];
                while let Ok(n) = io.read(&mut buf).await {
                    if n == 0 || io.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
            });
            reply(
                StatusCode::SWITCHING_PROTOCOLS,
                &[("connection", "Upgrade"), ("upgrade", "websocket")],
                Chunks::new(b"", 0, true),
            )
        }
        _ => reply(StatusCode::NOT_FOUND, &[], Chunks::new(b"", 0, true)),
    }
}

async fn upstream(hits: Arc<AtomicUsize>) -> u16 {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let (tcp, _) = listener.accept().await.unwrap();
            let hits = Arc::clone(&hits);
            tokio::spawn(async move {
                let svc = hyper::service::service_fn(move |req| {
                    let hits = Arc::clone(&hits);
                    async move { Ok::<_, Infallible>(serve(req, &hits)) }
                });
                let _ = hyper::server::conn::http1::Builder::new()
                    .serve_connection(TokioIo::new(tcp), svc)
                    .with_upgrades()
                    .await;
            });
        }
    });
    port
}

struct Fixture {
    proxy: EditorProxy,
    hits: Arc<AtomicUsize>,
    cache_dir: tempfile::TempDir,
}

async fn fixture() -> Fixture {
    let hits = Arc::new(AtomicUsize::new(0));
    let port = upstream(Arc::clone(&hits)).await;
    let cache_dir = tempfile::tempdir().unwrap();
    let cache = AssetCache::new(cache_dir.path().to_owned());
    let proxy = EditorProxy::start(port, Some(cache)).await.unwrap();
    Fixture {
        proxy,
        hits,
        cache_dir,
    }
}

struct Reply {
    head: String,
    body: Vec<u8>,
}

impl Reply {
    fn header(&self, name: &str) -> Option<&str> {
        self.head.lines().find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.eq_ignore_ascii_case(name).then(|| v.trim())
        })
    }

    fn decoded(&self) -> Vec<u8> {
        let mut out = Vec::new();
        match self.header("content-encoding") {
            Some("br") => {
                brotli::BrotliDecompress(&mut &self.body[..], &mut out).unwrap();
            }
            Some("gzip") => {
                flate2::read::GzDecoder::new(&self.body[..])
                    .read_to_end(&mut out)
                    .unwrap();
            }
            _ => out.clone_from(&self.body),
        }
        out
    }
}

/// One request on a fresh connection (`Connection: close`), the reply de-chunked.
async fn request(port: u16, method: &str, path: &str, headers: &[&str]) -> Reply {
    let mut tcp = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    let mut req =
        format!("{method} {path} HTTP/1.1\r\nHost: localhost:{port}\r\nConnection: close\r\n");
    for h in headers {
        req.push_str(h);
        req.push_str("\r\n");
    }
    req.push_str("\r\n");
    tcp.write_all(req.as_bytes()).await.unwrap();
    let mut raw = Vec::new();
    tokio::time::timeout(Duration::from_secs(10), tcp.read_to_end(&mut raw))
        .await
        .unwrap()
        .unwrap();
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    let mut reply = Reply {
        head: String::from_utf8(raw[..split].to_vec()).unwrap(),
        body: raw[split + 4..].to_vec(),
    };
    if reply.header("transfer-encoding") == Some("chunked") {
        reply.body = dechunk(&reply.body, true);
    }
    reply
}

/// The data of the chunks in `raw`; `complete` insists on the final empty chunk.
fn dechunk(mut raw: &[u8], complete: bool) -> Vec<u8> {
    let mut out = Vec::new();
    while let Some(line) = raw.windows(2).position(|w| w == b"\r\n") {
        let size = std::str::from_utf8(&raw[..line]).unwrap().trim();
        let size = usize::from_str_radix(size, 16).unwrap();
        if size == 0 {
            return out;
        }
        if raw.len() < line + 4 + size {
            break;
        }
        out.extend_from_slice(&raw[line + 2..line + 2 + size]);
        raw = &raw[line + 4 + size..];
    }
    assert!(!complete, "the body ended without its last chunk");
    out
}

fn app_js() -> String {
    format!("/stable-{COMMIT}/static/app.js")
}

#[tokio::test]
async fn compresses_chunked_bodies_with_the_accepted_coding() {
    let f = fixture().await;
    let port = f.proxy.port();
    for (accept, coding) in [
        ("Accept-Encoding: gzip, deflate, br", Some("br")),
        ("Accept-Encoding: gzip", Some("gzip")),
        ("Accept-Encoding: identity", None),
    ] {
        let r = request(port, "GET", &app_js(), &[accept]).await;
        assert!(r.head.starts_with("HTTP/1.1 200"), "{}", r.head);
        assert_eq!(r.header("content-encoding"), coding, "{accept}");
        assert_eq!(r.header("vary"), Some("accept-encoding"));
        assert_eq!(r.decoded(), script(), "{accept}");
        if coding.is_some() {
            assert!(r.header("content-length").is_none());
            assert!(r.body.len() * 3 < script().len(), "{}", r.body.len());
        }
    }
}

#[tokio::test]
async fn streams_instead_of_buffering() {
    let f = fixture().await;
    let mut tcp = TcpStream::connect(("127.0.0.1", f.proxy.port()))
        .await
        .unwrap();
    tcp.write_all(b"GET /slow.js HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br\r\n\r\n")
        .await
        .unwrap();
    // The upstream holds its second half back for 1.5 s; the first half's compressed bytes
    // must arrive well before that (flushed once the upstream goes quiet).
    let mut got = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_millis(700);
    let mut buf = [0; 65536];
    while let Ok(Ok(n)) = tokio::time::timeout_at(deadline, tcp.read(&mut buf)).await
        && n > 0
    {
        got.extend_from_slice(&buf[..n]);
    }
    let split = got.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
    let body = dechunk(&got[split + 4..], false);
    let mut plain = Vec::new();
    // The stream is not finished: decode what there is.
    let _ = brotli::Decompressor::new(&body[..], 4096).read_to_end(&mut plain);
    let half = script().len() / 2;
    assert!(
        plain.len() + 100 >= half,
        "only {} of {half} bytes arrived before the pause",
        plain.len()
    );
}

#[tokio::test]
async fn caches_versioned_static_assets_but_still_asks_the_server() {
    let f = fixture().await;
    let port = f.proxy.port();
    let first = request(port, "GET", &app_js(), &["Accept-Encoding: br"]).await;
    assert_eq!(first.header("content-encoding"), Some("br"));
    assert!(first.header("content-length").is_none(), "streamed");
    assert_eq!(first.decoded(), script());

    // Stored in the background, then rewritten at the best level.
    let dir = f.cache_dir.path().join(format!("stable-{COMMIT}"));
    let best = tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let found = std::fs::read_dir(&dir)
                .into_iter()
                .flatten()
                .flatten()
                .map(|e| e.path())
                .find(|p| p.extension().is_some_and(|x| x == "br"));
            if let Some(path) = found {
                return path;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("cached");
    let len = std::fs::metadata(&best).unwrap().len();

    let second = request(port, "GET", &app_js(), &["Accept-Encoding: gzip, br"]).await;
    assert_eq!(second.header("content-encoding"), Some("br"));
    assert_eq!(
        second.header("content-length"),
        Some(len.to_string().as_str())
    );
    assert_eq!(second.body.len() as u64, len);
    assert_eq!(second.decoded(), script());
    assert_eq!(
        f.hits.load(Ordering::SeqCst),
        2,
        "the server is asked every time"
    );

    // gzip has its own entry; identity is never cached.
    let gz = request(port, "GET", &app_js(), &["Accept-Encoding: gzip"]).await;
    assert_eq!(gz.header("content-encoding"), Some("gzip"));
    assert_eq!(gz.decoded(), script());
    let plain = request(port, "GET", &app_js(), &[]).await;
    assert!(plain.header("content-encoding").is_none());
    assert_eq!(plain.body, script());
}

#[tokio::test]
async fn ranges_encoded_tiny_and_binary_bodies_pass_untouched() {
    let f = fixture().await;
    let port = f.proxy.port();
    let br = "Accept-Encoding: br, gzip";
    let r = request(port, "GET", "/range.js", &[br, "Range: bytes=0-9"]).await;
    assert!(r.head.starts_with("HTTP/1.1 206"), "{}", r.head);
    assert!(r.header("content-encoding").is_none());
    assert!(r.header("content-range").is_some());
    assert_eq!(r.body, &script()[..10]);

    let r = request(port, "GET", "/pre.js", &[br]).await;
    assert_eq!(r.header("content-encoding"), Some("gzip"));
    assert_eq!(r.body, b"\x1f\x8b already gzip");

    let r = request(port, "GET", "/tiny.css", &[br]).await;
    assert!(r.header("content-encoding").is_none());
    assert_eq!(r.header("content-length"), Some("11"));

    let r = request(port, "GET", "/logo.png", &[br]).await;
    assert!(r.header("content-encoding").is_none());
    assert!(r.header("vary").is_none());
    assert_eq!(r.body, script());
}

#[tokio::test]
async fn head_reports_what_get_would_send() {
    let f = fixture().await;
    let port = f.proxy.port();
    let r = request(port, "HEAD", "/data.json", &["Accept-Encoding: br"]).await;
    assert!(r.head.starts_with("HTTP/1.1 200"), "{}", r.head);
    assert_eq!(r.header("content-encoding"), Some("br"));
    assert!(r.header("content-length").is_none(), "{}", r.head);
    assert!(r.header("transfer-encoding").is_none(), "{}", r.head);
    assert!(r.body.is_empty());
    let r = request(port, "HEAD", "/data.json", &[]).await;
    assert!(r.header("content-encoding").is_none());
    assert!(r.header("content-length").is_some(), "{}", r.head);
    assert!(r.body.is_empty());
}

#[tokio::test]
async fn etags_are_weakened_and_revalidate() {
    let f = fixture().await;
    let port = f.proxy.port();
    let r = request(port, "GET", "/data.json", &["Accept-Encoding: br"]).await;
    assert_eq!(r.header("etag"), Some("W/\"v1;unz\""));
    let r = request(port, "GET", "/data.json", &[]).await;
    assert_eq!(
        r.header("etag"),
        Some("\"v1\""),
        "identity keeps the strong tag"
    );

    let r = request(
        port,
        "GET",
        "/data.json",
        &["Accept-Encoding: br", "If-None-Match: W/\"v1;unz\""],
    )
    .await;
    assert!(r.head.starts_with("HTTP/1.1 304"), "{}", r.head);
    assert_eq!(r.header("etag"), Some("W/\"v1;unz\""));
}

#[tokio::test]
async fn websocket_upgrades_pass_through() {
    let f = fixture().await;
    let mut tcp = TcpStream::connect(("127.0.0.1", f.proxy.port()))
        .await
        .unwrap();
    tcp.write_all(
        b"GET /ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\
          Accept-Encoding: br\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
          Sec-WebSocket-Version: 13\r\n\r\n",
    )
    .await
    .unwrap();
    let mut head = Vec::new();
    while !head.ends_with(b"\r\n\r\n") {
        let mut b = [0; 1];
        tcp.read_exact(&mut b).await.unwrap();
        head.push(b[0]);
    }
    let head = String::from_utf8(head).unwrap();
    assert!(head.starts_with("HTTP/1.1 101"), "{head}");
    assert!(
        head.to_ascii_lowercase().contains("upgrade: websocket"),
        "{head}"
    );
    for msg in [&b"ping"[..], b"\x81\x05hello", &[0u8; 300][..]] {
        tcp.write_all(msg).await.unwrap();
        let mut back = vec![0; msg.len()];
        tokio::time::timeout(Duration::from_secs(5), tcp.read_exact(&mut back))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(back, msg);
    }
}

#[tokio::test]
async fn keeps_connections_alive_across_requests() {
    let f = fixture().await;
    let mut tcp = TcpStream::connect(("127.0.0.1", f.proxy.port()))
        .await
        .unwrap();
    // Two requests on one connection, the second after a compressed one.
    tcp.write_all(
        b"GET /slow.js HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br\r\n\r\n\
          GET /tiny.css HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    )
    .await
    .unwrap();
    let mut raw = Vec::new();
    tokio::time::timeout(Duration::from_secs(10), tcp.read_to_end(&mut raw))
        .await
        .unwrap()
        .unwrap();
    let text = String::from_utf8_lossy(&raw);
    assert_eq!(text.matches("HTTP/1.1 200").count(), 2, "{text}");
    assert!(text.ends_with("a{color:#f}"), "{text}");
}
