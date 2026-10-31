//! A compressing HTTP/1.1 reverse proxy in front of an editor server (`code serve-web`,
//! VSCodium, openvscode-server), the port the app's forward actually reaches.
//!
//! The VS Code server sends everything uncompressed whatever `Accept-Encoding` says: a cold
//! This proxy compresses responses the client accepts (brotli preferred, then gzip) as they
//! stream, and leaves alone what must not or need not change: websocket upgrades (the remote
//! extension host, the file system), range requests and partial responses, bodies that are
//! already encoded, tiny ones, types that do not shrink (images, woff2), `no-transform`.
//! A transformed body's `ETag` is weakened and marked, and the mark is taken off again in
//! `If-None-Match`, so revalidation still ends in `304`.
//!
//! Static assets live under `/<quality>-<commit>/static/` with a one-year `max-age`: they
//! never change for a server version. Those are compressed once and kept on disk per version
//! ([`AssetCache`]); the first load streams brotli at a fast level and stores it, a background
//! job then recompresses it at the best level once, and later loads are served from the file.
//! The server is still asked every time (it checks the connection token and says what the
//! asset is), only its body is not read.

use std::collections::HashSet;
use std::convert::Infallible;
use std::io::{self, Write as _};
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use bytes::{Bytes, BytesMut};
use hyper::body::{Body, Frame, Incoming, SizeHint};
use hyper::header::{self, HeaderMap, HeaderValue};
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::{TokioExecutor, TokioIo};
use tokio::io::AsyncRead;
use tokio::net::TcpListener;
use tokio::task::{JoinHandle, JoinSet};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// Bodies shorter than this are sent as they are: compressing them saves less than it costs.
const MIN_SIZE: u64 = 1024;
/// Brotli level while a response streams (≈50 MB/s on one core; workbench.js 19.9 → 4.6 MB).
const BR_FAST: u32 = 5;
/// Brotli level for cached assets, compressed once per server version in the background
/// (workbench.js → 3.9 MB in ~20 s of one core).
const BR_BEST: u32 = 11;
/// Brotli window (4 MiB): what browsers decode with modest memory.
const BR_LGWIN: u32 = 22;
const GZIP_LEVEL: u32 = 6;
/// With no new upstream data for this long, what was compressed so far is flushed to the
/// client (a streaming response must not wait for the compressor's next block). Flushing on
/// every read costs brotli ~20% of its gain, so only an actual pause flushes.
const IDLE_FLUSH: Duration = Duration::from_millis(20);
/// A compressed asset larger than this is streamed but not kept.
const MAX_CACHED: usize = 64 << 20;
/// Server versions kept in the cache; older ones are removed when a new one appears.
const KEEP_VERSIONS: usize = 3;
/// Marks a strong `ETag` this proxy weakened (`"x"` → `W/"x;unz"`), so `If-None-Match` can
/// be given back to the server as it issued it.
const ETAG_MARK: &str = ";unz";
/// Upstream keep-alive: below the 5 s Node's HTTP server closes idle connections after.
const UPSTREAM_IDLE: Duration = Duration::from_secs(4);
const FILE_CHUNK: usize = 64 << 10;

/// A content coding this proxy produces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Coding {
    Br,
    Gzip,
}

impl Coding {
    fn token(self) -> &'static str {
        match self {
            Self::Br => "br",
            Self::Gzip => "gzip",
        }
    }
}

/// The proxy for one editor server. Dropping it stops the listener and its connections.
pub(crate) struct EditorProxy {
    port: u16,
    shared: Arc<Shared>,
    task: JoinHandle<()>,
}

impl EditorProxy {
    /// Listens on `127.0.0.1` (a free port) and proxies to `127.0.0.1:upstream`, keeping
    /// static assets in `cache` when given.
    ///
    /// # Errors
    ///
    /// Binding the listener failed.
    pub(crate) async fn start(upstream: u16, cache: Option<Arc<AssetCache>>) -> io::Result<Self> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let port = listener.local_addr()?.port();
        let mut connector = HttpConnector::new();
        connector.set_nodelay(true);
        let client = Client::builder(TokioExecutor::new())
            .pool_idle_timeout(UPSTREAM_IDLE)
            .build(connector);
        let shared = Arc::new(Shared {
            client,
            upstream,
            cache,
            open: AtomicUsize::new(0),
            idle_since: Mutex::new(Instant::now()),
        });
        let task = tokio::spawn(accept(listener, Arc::clone(&shared)));
        Ok(Self { port, shared, task })
    }

    /// The port the app's forward should target.
    pub(crate) fn port(&self) -> u16 {
        self.port
    }

    /// How long no connection has been open (`None` while one is: a workbench, a load).
    pub(crate) fn idle_for(&self) -> Option<Duration> {
        if self.shared.open.load(Ordering::SeqCst) > 0 {
            return None;
        }
        Some(lock(&self.shared.idle_since).elapsed())
    }
}

impl Drop for EditorProxy {
    fn drop(&mut self) {
        self.task.abort();
    }
}

struct Shared {
    client: Client<HttpConnector, Incoming>,
    upstream: u16,
    cache: Option<Arc<AssetCache>>,
    /// Connections open now, websockets included.
    open: AtomicUsize,
    /// When the last connection closed.
    idle_since: Mutex<Instant>,
}

/// Counts as an open connection while it lives.
struct Busy(Arc<Shared>);

impl Busy {
    fn new(shared: &Arc<Shared>) -> Self {
        shared.open.fetch_add(1, Ordering::SeqCst);
        Self(Arc::clone(shared))
    }
}

impl Drop for Busy {
    fn drop(&mut self) {
        if self.0.open.fetch_sub(1, Ordering::SeqCst) == 1 {
            *lock(&self.0.idle_since) = Instant::now();
        }
    }
}

async fn accept(listener: TcpListener, shared: Arc<Shared>) {
    // Owned here, so aborting the accept loop also ends every open connection.
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let Ok((tcp, _)) = accepted else { continue };
                let _ = tcp.set_nodelay(true);
                let shared = Arc::clone(&shared);
                connections.spawn(async move {
                    let _busy = Busy::new(&shared);
                    let service = hyper::service::service_fn(move |req| {
                        let shared = Arc::clone(&shared);
                        async move { Ok::<_, Infallible>(handle(&shared, req).await) }
                    });
                    let served = hyper::server::conn::http1::Builder::new()
                        .serve_connection(TokioIo::new(tcp), service)
                        .with_upgrades()
                        .await;
                    if let Err(e) = served {
                        tracing::debug!("editor proxy connection: {e}");
                    }
                });
            }
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
}

/// Whether a `Host` header names this machine's loopback. Anything else is a page that
/// rebound its own name to 127.0.0.1 (DNS rebinding) and must not reach the editor.
fn loopback_host(host: Option<&HeaderValue>) -> bool {
    let Some(host) = host.and_then(|h| h.to_str().ok()) else {
        return false;
    };
    let name = match host.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or_default(),
        None => host.rsplit_once(':').map_or(host, |(name, _)| name),
    };
    let name = name.to_ascii_lowercase();
    name == "localhost"
        || name.ends_with(".localhost")
        || name == "::1"
        || name
            .parse::<std::net::Ipv4Addr>()
            .is_ok_and(|ip| ip.is_loopback())
}

async fn handle(shared: &Arc<Shared>, req: Request<Incoming>) -> Response<ProxyBody> {
    if !loopback_host(req.headers().get(header::HOST)) {
        let mut resp = Response::new(ProxyBody::Full(Some(Bytes::from_static(
            b"editor proxy: not a loopback host\n",
        ))));
        *resp.status_mut() = StatusCode::FORBIDDEN;
        return resp;
    }
    match proxy(shared, req).await {
        Ok(resp) => resp,
        Err(e) => {
            tracing::debug!("editor proxy: {e}");
            let mut resp = Response::new(ProxyBody::Full(Some(Bytes::from(format!(
                "editor proxy: {e}\n"
            )))));
            *resp.status_mut() = StatusCode::BAD_GATEWAY;
            resp
        }
    }
}

async fn proxy(
    shared: &Arc<Shared>,
    mut req: Request<Incoming>,
) -> Result<Response<ProxyBody>, BoxError> {
    let path = req
        .uri()
        .path_and_query()
        .map_or_else(|| "/".to_owned(), |p| p.as_str().to_owned());
    *req.uri_mut() = format!("http://127.0.0.1:{}{path}", shared.upstream).parse()?;

    if is_upgrade(req.headers()) {
        return upgrade(shared, req).await;
    }

    let method = req.method().clone();
    // Ranges address the identity body: never compressed (the response is passed as is).
    let coding = if req.headers().contains_key(header::RANGE) {
        None
    } else {
        negotiate(req.headers())
    };
    let cache_key = match (&shared.cache, method == Method::GET) {
        (Some(cache), true) => cache.key(&path),
        _ => None,
    };
    let revalidating_ours = unmark_if_none_match(req.headers_mut());
    strip_hop_by_hop(req.headers_mut());

    let resp = shared.client.request(req).await?;
    let (mut parts, body) = resp.into_parts();
    strip_hop_by_hop(&mut parts.headers);

    if parts.status == StatusCode::NOT_MODIFIED && revalidating_ours {
        // The 304 must carry the tag the client holds: the weakened one.
        weaken_etag(&mut parts.headers);
    }
    if !compressible(parts.status, &parts.headers) {
        return Ok(Response::from_parts(parts, ProxyBody::Pass(body)));
    }
    let varies = parts
        .headers
        .get_all(header::VARY)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
        .any(|v| {
            matches!(
                v.trim().to_ascii_lowercase().as_str(),
                "accept-encoding" | "*"
            )
        });
    if !varies {
        parts
            .headers
            .append(header::VARY, HeaderValue::from_static("accept-encoding"));
    }
    let Some(coding) = coding else {
        return Ok(Response::from_parts(parts, ProxyBody::Pass(body)));
    };
    let immutable = is_immutable(&parts.headers);
    parts.headers.remove(header::CONTENT_LENGTH);
    parts.headers.remove(header::ACCEPT_RANGES);
    parts.headers.insert(
        header::CONTENT_ENCODING,
        HeaderValue::from_static(coding.token()),
    );
    weaken_etag(&mut parts.headers);
    if method == Method::HEAD {
        return Ok(Response::from_parts(parts, ProxyBody::Full(None)));
    }

    let cache = shared.cache.as_ref().filter(|_| immutable);
    let tee = match (cache, cache_key) {
        (Some(cache), Some(key)) => {
            if let Some((file, len)) = cache.open(&key, coding).await {
                // The server said yes to this request; its copy of the body is not needed.
                drop(body);
                parts.headers.insert(header::CONTENT_LENGTH, len.into());
                return Ok(Response::from_parts(
                    parts,
                    ProxyBody::File(Box::new(CachedFile { file, left: len })),
                ));
            }
            Some(Tee {
                cache: Arc::clone(cache),
                key,
                coding,
                out: Vec::new(),
            })
        }
        _ => None,
    };
    Ok(Response::from_parts(
        parts,
        ProxyBody::Compress(Box::new(Compressing {
            inner: body,
            encoder: Some(Encoder::new(coding, BR_FAST)),
            tee,
            pending: false,
            idle: None,
        })),
    ))
}

/// Forwards an `Upgrade` request as it is and, on `101`, splices the two upgraded
/// connections (VS Code's websockets: extension host, file system, terminals).
async fn upgrade(
    shared: &Arc<Shared>,
    mut req: Request<Incoming>,
) -> Result<Response<ProxyBody>, BoxError> {
    let downstream = hyper::upgrade::on(&mut req);
    let mut resp = shared.client.request(req).await?;
    if resp.status() == StatusCode::SWITCHING_PROTOCOLS {
        let upstream = hyper::upgrade::on(&mut resp);
        let busy = Busy::new(shared);
        tokio::spawn(async move {
            let _busy = busy;
            let (Ok(down), Ok(up)) = tokio::join!(downstream, upstream) else {
                return;
            };
            let _ =
                tokio::io::copy_bidirectional(&mut TokioIo::new(down), &mut TokioIo::new(up)).await;
        });
    }
    Ok(resp.map(ProxyBody::Pass))
}

fn is_upgrade(headers: &HeaderMap) -> bool {
    headers.contains_key(header::UPGRADE)
        && headers
            .get_all(header::CONNECTION)
            .iter()
            .filter_map(|v| v.to_str().ok())
            .flat_map(|v| v.split(','))
            .any(|t| t.trim().eq_ignore_ascii_case("upgrade"))
}

/// Removes hop-by-hop headers (RFC 9110 §7.6.1), including those `Connection` names.
fn strip_hop_by_hop(headers: &mut HeaderMap) {
    let named: Vec<String> = headers
        .get_all(header::CONNECTION)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
        .map(|t| t.trim().to_ascii_lowercase())
        .filter(|t| !t.is_empty())
        .collect();
    for name in named {
        headers.remove(name.as_str());
    }
    for name in [
        header::CONNECTION,
        header::TRANSFER_ENCODING,
        header::TE,
        header::TRAILER,
        header::UPGRADE,
        header::PROXY_AUTHORIZATION,
        header::PROXY_AUTHENTICATE,
    ] {
        headers.remove(name);
    }
    headers.remove("keep-alive");
}

/// The coding to use for a request's `Accept-Encoding`: the highest `q`, brotli on a tie;
/// `None` when neither is acceptable.
pub(crate) fn negotiate(headers: &HeaderMap) -> Option<Coding> {
    let (mut br, mut gzip, mut star) = (None, None, None);
    for item in headers
        .get_all(header::ACCEPT_ENCODING)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
    {
        let mut params = item.split(';');
        let name = params
            .next()
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase();
        let q = params
            .filter_map(|p| p.trim().strip_prefix("q="))
            .find_map(|q| q.trim().parse::<f32>().ok())
            .unwrap_or(1.0);
        match name.as_str() {
            "br" => br = Some(q),
            "gzip" | "x-gzip" => gzip = Some(q),
            "*" => star = Some(q),
            _ => {}
        }
    }
    let br = br.or(star).unwrap_or(0.0);
    let gzip = gzip.or(star).unwrap_or(0.0);
    if br > 0.0 && br >= gzip {
        Some(Coding::Br)
    } else if gzip > 0.0 {
        Some(Coding::Gzip)
    } else {
        None
    }
}

/// Whether a response may and should be compressed (before looking at the request).
fn compressible(status: StatusCode, headers: &HeaderMap) -> bool {
    let text = |name| headers.get(name).and_then(|v| v.to_str().ok());
    let encoded =
        text(header::CONTENT_ENCODING).is_some_and(|e| !e.trim().eq_ignore_ascii_case("identity"));
    let tiny = text(header::CONTENT_LENGTH)
        .and_then(|l| l.trim().parse::<u64>().ok())
        .is_some_and(|l| l < MIN_SIZE);
    let no_transform = headers
        .get_all(header::CACHE_CONTROL)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .any(|v| v.to_ascii_lowercase().contains("no-transform"));
    status == StatusCode::OK
        && !encoded
        && !tiny
        && !no_transform
        && !headers.contains_key(header::CONTENT_RANGE)
        && text(header::CONTENT_TYPE).is_some_and(compressible_type)
}

/// Text, scripts, styles, JSON (source maps), SVG, WebAssembly and uncompressed fonts.
/// Images, media, archives and woff/woff2 are compressed already.
pub(crate) fn compressible_type(content_type: &str) -> bool {
    let mime = content_type
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    mime.starts_with("text/")
        || mime.ends_with("+json")
        || mime.ends_with("+xml")
        || matches!(
            mime.as_str(),
            "application/javascript"
                | "application/x-javascript"
                | "application/ecmascript"
                | "application/json"
                | "application/xml"
                | "application/wasm"
                | "application/x-font-ttf"
                | "application/x-font-otf"
                | "application/vnd.ms-fontobject"
                | "font/ttf"
                | "font/otf"
                | "image/x-icon"
                | "image/vnd.microsoft.icon"
                | "image/bmp"
        )
}

/// `Cache-Control` says the body never changes for this URL (VS Code's versioned static
/// assets: `public, max-age=31536000`).
fn is_immutable(headers: &HeaderMap) -> bool {
    if headers.contains_key(header::SET_COOKIE) {
        return false;
    }
    let directives: Vec<String> = headers
        .get_all(header::CACHE_CONTROL)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
        .map(|d| d.trim().to_ascii_lowercase())
        .collect();
    let forbidden = directives
        .iter()
        .any(|d| matches!(d.as_str(), "no-store" | "no-cache" | "private"));
    let long = directives.iter().any(|d| {
        d == "immutable"
            || d.strip_prefix("max-age=")
                .and_then(|s| s.parse::<u64>().ok())
                .is_some_and(|s| s >= 24 * 3600)
    });
    !forbidden && long
}

/// `"x"` → `W/"x;unz"`; weak tags stay as they are (a weak tag already allows a different
/// encoding of the same content).
fn weaken_etag(headers: &mut HeaderMap) {
    let Some(tag) = headers.get(header::ETAG).and_then(|v| v.to_str().ok()) else {
        return;
    };
    let tag = tag.trim();
    if let Some(opaque) = tag.strip_prefix('"').and_then(|t| t.strip_suffix('"'))
        && let Ok(weak) = HeaderValue::from_str(&format!("W/\"{opaque}{ETAG_MARK}\""))
    {
        headers.insert(header::ETAG, weak);
    }
}

/// Gives the server back the tags it issued: `W/"x;unz"` → `"x"` in `If-None-Match`.
/// Returns whether there was one.
fn unmark_if_none_match(headers: &mut HeaderMap) -> bool {
    let Some(value) = headers
        .get(header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
    else {
        return false;
    };
    let mut ours = false;
    let tags: Vec<String> = value
        .split(',')
        .map(|tag| {
            let tag = tag.trim();
            match tag
                .strip_prefix("W/\"")
                .and_then(|t| t.strip_suffix(&format!("{ETAG_MARK}\"")))
            {
                Some(opaque) => {
                    ours = true;
                    format!("\"{opaque}\"")
                }
                None => tag.to_owned(),
            }
        })
        .collect();
    if ours && let Ok(v) = HeaderValue::from_str(&tags.join(", ")) {
        headers.insert(header::IF_NONE_MATCH, v);
    }
    ours
}

/// A streaming compressor writing into memory, drained after every write.
pub(crate) enum Encoder {
    Br(Box<brotli::CompressorWriter<Vec<u8>>>),
    Gzip(flate2::write::GzEncoder<Vec<u8>>),
}

impl Encoder {
    pub(crate) fn new(coding: Coding, br_quality: u32) -> Self {
        match coding {
            Coding::Br => Self::Br(Box::new(brotli::CompressorWriter::new(
                Vec::new(),
                FILE_CHUNK,
                br_quality,
                BR_LGWIN,
            ))),
            Coding::Gzip => Self::Gzip(flate2::write::GzEncoder::new(
                Vec::new(),
                flate2::Compression::new(GZIP_LEVEL),
            )),
        }
    }

    fn out(&mut self) -> &mut Vec<u8> {
        match self {
            Self::Br(w) => w.get_mut(),
            Self::Gzip(w) => w.get_mut(),
        }
    }

    /// Compresses `data`; returns whatever output is ready.
    pub(crate) fn write(&mut self, data: &[u8]) -> io::Result<Vec<u8>> {
        match self {
            Self::Br(w) => w.write_all(data)?,
            Self::Gzip(w) => w.write_all(data)?,
        }
        Ok(std::mem::take(self.out()))
    }

    /// Emits everything written so far (a sync flush; the stream goes on).
    fn flush(&mut self) -> io::Result<Vec<u8>> {
        match self {
            Self::Br(w) => w.flush()?,
            Self::Gzip(w) => w.flush()?,
        }
        Ok(std::mem::take(self.out()))
    }

    /// Ends the stream; returns the rest.
    pub(crate) fn finish(self) -> io::Result<Vec<u8>> {
        match self {
            Self::Br(w) => Ok(w.into_inner()),
            Self::Gzip(w) => w.finish(),
        }
    }
}

/// The response body.
pub(crate) enum ProxyBody {
    /// The server's body, untouched.
    Pass(Incoming),
    /// The server's body, compressed as it arrives.
    Compress(Box<Compressing>),
    /// A compressed asset from the cache.
    File(Box<CachedFile>),
    /// A body the proxy wrote (errors), or none (`HEAD`).
    Full(Option<Bytes>),
}

pub(crate) struct Compressing {
    inner: Incoming,
    encoder: Option<Encoder>,
    tee: Option<Tee>,
    /// Input was written since the last output.
    pending: bool,
    idle: Option<Pin<Box<tokio::time::Sleep>>>,
}

pub(crate) struct CachedFile {
    file: tokio::fs::File,
    left: u64,
}

/// What a cacheable response compressed so far; stored when the body ended cleanly.
struct Tee {
    cache: Arc<AssetCache>,
    key: CacheKey,
    coding: Coding,
    out: Vec<u8>,
}

impl Tee {
    fn push(tee: &mut Option<Self>, chunk: &[u8]) {
        if let Some(t) = tee {
            if t.out.len() + chunk.len() > MAX_CACHED {
                *tee = None;
            } else {
                t.out.extend_from_slice(chunk);
            }
        }
    }
}

impl Compressing {
    fn emit(&mut self, out: Vec<u8>) -> Poll<Option<Result<Frame<Bytes>, BoxError>>> {
        Tee::push(&mut self.tee, &out);
        Poll::Ready(Some(Ok(Frame::data(Bytes::from(out)))))
    }

    fn poll_compressed(
        &mut self,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, BoxError>>> {
        loop {
            let Some(encoder) = self.encoder.as_mut() else {
                return Poll::Ready(None);
            };
            match Pin::new(&mut self.inner).poll_frame(cx) {
                Poll::Ready(Some(Ok(frame))) => {
                    // Trailers have nowhere to go once the body is re-encoded; drop them.
                    let Ok(data) = frame.into_data() else {
                        continue;
                    };
                    self.idle = None;
                    let out = encoder.write(&data)?;
                    self.pending = true;
                    if !out.is_empty() {
                        return self.emit(out);
                    }
                }
                Poll::Ready(Some(Err(e))) => {
                    self.tee = None;
                    self.encoder = None;
                    return Poll::Ready(Some(Err(e.into())));
                }
                Poll::Ready(None) => {
                    let out = self.encoder.take().map(Encoder::finish).transpose()?;
                    let out = out.unwrap_or_default();
                    Tee::push(&mut self.tee, &out);
                    if let Some(tee) = self.tee.take() {
                        tee.cache.store(tee.key, tee.coding, tee.out);
                    }
                    return if out.is_empty() {
                        Poll::Ready(None)
                    } else {
                        Poll::Ready(Some(Ok(Frame::data(Bytes::from(out)))))
                    };
                }
                Poll::Pending => {
                    if !self.pending {
                        return Poll::Pending;
                    }
                    let idle = self
                        .idle
                        .get_or_insert_with(|| Box::pin(tokio::time::sleep(IDLE_FLUSH)));
                    if idle.as_mut().poll(cx).is_pending() {
                        return Poll::Pending;
                    }
                    self.idle = None;
                    self.pending = false;
                    let out = encoder.flush()?;
                    if !out.is_empty() {
                        return self.emit(out);
                    }
                }
            }
        }
    }
}

impl Body for ProxyBody {
    type Data = Bytes;
    type Error = BoxError;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, BoxError>>> {
        match self.get_mut() {
            Self::Pass(body) => Pin::new(body).poll_frame(cx).map_err(Into::into),
            Self::Compress(c) => c.poll_compressed(cx),
            Self::File(f) => {
                if f.left == 0 {
                    return Poll::Ready(None);
                }
                let want = usize::try_from(f.left)
                    .unwrap_or(usize::MAX)
                    .min(FILE_CHUNK);
                let mut buf = BytesMut::zeroed(want);
                let mut read = tokio::io::ReadBuf::new(&mut buf);
                match Pin::new(&mut f.file).poll_read(cx, &mut read) {
                    Poll::Pending => Poll::Pending,
                    Poll::Ready(Err(e)) => Poll::Ready(Some(Err(e.into()))),
                    Poll::Ready(Ok(())) => {
                        let n = read.filled().len();
                        if n == 0 {
                            return Poll::Ready(Some(Err("cached asset shrank".into())));
                        }
                        buf.truncate(n);
                        f.left -= n as u64;
                        Poll::Ready(Some(Ok(Frame::data(buf.freeze()))))
                    }
                }
            }
            Self::Full(data) => Poll::Ready(data.take().map(|d| Ok(Frame::data(d)))),
        }
    }

    fn is_end_stream(&self) -> bool {
        match self {
            Self::Pass(body) => body.is_end_stream(),
            Self::Compress(c) => c.encoder.is_none(),
            Self::File(f) => f.left == 0,
            Self::Full(data) => data.is_none(),
        }
    }

    fn size_hint(&self) -> SizeHint {
        match self {
            Self::Pass(body) => body.size_hint(),
            Self::Compress(_) => SizeHint::default(),
            Self::File(f) => SizeHint::with_exact(f.left),
            // `HEAD` of a compressed response: the length is unknown, not zero.
            Self::Full(None) => SizeHint::default(),
            Self::Full(Some(d)) => SizeHint::with_exact(d.len() as u64),
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Compressed static assets, one directory per server version:
/// `<root>/<quality>-<commit>/<sha256 of the path>.{br,br5,gz}`. `.br5` is what the first
/// load streamed (fast brotli), `.br` the best-level rewrite that replaces it.
pub(crate) struct AssetCache {
    root: PathBuf,
    /// One best-level recompression at a time: it is a background nicety, not a CPU hog.
    rewrite: Mutex<()>,
    /// Assets with a rewrite queued or running.
    rewriting: Mutex<HashSet<String>>,
    /// Set on daemon shutdown: a running rewrite stops at its next piece instead of holding
    /// the runtime's shutdown for seconds (`.br5` stays and is rewritten on a later hit).
    closed: AtomicBool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CacheKey {
    version: String,
    name: String,
}

impl AssetCache {
    pub(crate) fn new(root: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            root,
            rewrite: Mutex::new(()),
            rewriting: Mutex::new(HashSet::new()),
            closed: AtomicBool::new(false),
        })
    }

    /// Stops background work (daemon shutdown).
    pub(crate) fn close(&self) {
        self.closed.store(true, Ordering::Relaxed);
    }

    /// The key for a versioned static asset (`/<quality>-<40 hex>/static/…`), else `None`.
    pub(crate) fn key(&self, path_and_query: &str) -> Option<CacheKey> {
        let mut segments = path_and_query.trim_start_matches('/').splitn(3, '/');
        let version = segments.next()?;
        let (quality, commit) = version.split_once('-')?;
        let versioned = !quality.is_empty()
            && quality.bytes().all(|b| b.is_ascii_lowercase())
            && commit.len() == 40
            && commit.bytes().all(|b| b.is_ascii_hexdigit());
        if !versioned || segments.next()? != "static" {
            return None;
        }
        let digest = ring::digest::digest(&ring::digest::SHA256, path_and_query.as_bytes());
        Some(CacheKey {
            version: version.to_owned(),
            name: crate::fsutil::hex(&digest.as_ref()[..20]),
        })
    }

    fn path(&self, key: &CacheKey, ext: &str) -> PathBuf {
        self.root
            .join(&key.version)
            .join(format!("{}.{ext}", key.name))
    }

    fn candidates(coding: Coding) -> &'static [&'static str] {
        match coding {
            Coding::Br => &["br", "br5"],
            Coding::Gzip => &["gz"],
        }
    }

    /// The stored body for `key` in `coding`, with its length. A fast-level one whose rewrite
    /// was interrupted gets rewritten again.
    async fn open(
        self: &Arc<Self>,
        key: &CacheKey,
        coding: Coding,
    ) -> Option<(tokio::fs::File, u64)> {
        for ext in Self::candidates(coding) {
            if let Ok(file) = tokio::fs::File::open(self.path(key, ext)).await
                && let Ok(meta) = file.metadata().await
            {
                if *ext == "br5" {
                    self.rewrite_soon(key.clone());
                }
                return Some((file, meta.len()));
            }
        }
        None
    }

    /// Stores a streamed body in the background, then (brotli) rewrites it at the best level.
    fn store(self: &Arc<Self>, key: CacheKey, coding: Coding, body: Vec<u8>) {
        let cache = Arc::clone(self);
        tokio::task::spawn_blocking(move || {
            let ext = match coding {
                Coding::Br => "br5",
                Coding::Gzip => "gz",
            };
            if let Err(e) = cache.write(&key, ext, &body) {
                tracing::debug!("caching an editor asset: {e}");
                return;
            }
            if coding == Coding::Br {
                cache.rewrite_soon(key);
            }
        });
    }

    /// Queues the best-level rewrite of a `.br5` (once per asset at a time).
    fn rewrite_soon(self: &Arc<Self>, key: CacheKey) {
        let queued = lock(&self.rewriting).insert(key.name.clone());
        if !queued || self.closed.load(Ordering::Relaxed) {
            return;
        }
        let cache = Arc::clone(self);
        tokio::task::spawn_blocking(move || {
            if let Err(e) = cache.rewrite_best(&key) {
                tracing::debug!("recompressing an editor asset: {e}");
            }
            lock(&cache.rewriting).remove(&key.name);
        });
    }

    /// Writes atomically (temp file + rename); a new version directory prunes old ones.
    fn write(&self, key: &CacheKey, ext: &str, body: &[u8]) -> io::Result<()> {
        let dir = self.root.join(&key.version);
        if !dir.is_dir() {
            std::fs::create_dir_all(&dir)?;
            self.prune(&key.version);
        }
        let tmp = dir.join(format!(
            ".{}.{ext}.{}",
            key.name,
            crate::fsutil::hex(&crate::fsutil::random::<4>())
        ));
        let result =
            std::fs::write(&tmp, body).and_then(|()| std::fs::rename(&tmp, self.path(key, ext)));
        if result.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        result
    }

    /// `.br5` → decompress → best-level brotli → `.br` (and the `.br5` goes).
    fn rewrite_best(&self, key: &CacheKey) -> io::Result<()> {
        let _one = lock(&self.rewrite);
        let fast = self.path(key, "br5");
        if self.path(key, "br").is_file() || !fast.is_file() {
            return Ok(());
        }
        let mut plain = Vec::new();
        brotli::BrotliDecompress(&mut std::fs::File::open(&fast)?, &mut plain)?;
        let mut encoder = Encoder::new(Coding::Br, BR_BEST);
        let mut best = Vec::new();
        for piece in plain.chunks(1 << 20) {
            if self.closed.load(Ordering::Relaxed) {
                return Ok(());
            }
            best.extend(encoder.write(piece)?);
        }
        best.extend(encoder.finish()?);
        let fast_len = std::fs::metadata(&fast)?.len();
        if (best.len() as u64) < fast_len {
            self.write(key, "br", &best)?;
        } else {
            std::fs::rename(&fast, self.path(key, "br"))?;
        }
        let _ = std::fs::remove_file(&fast);
        tracing::debug!(
            version = %key.version,
            plain = plain.len(),
            fast = fast_len,
            best = best.len(),
            "editor asset recompressed"
        );
        Ok(())
    }

    /// Keeps the newest [`KEEP_VERSIONS`] version directories (by modification time).
    fn prune(&self, current: &str) {
        let Ok(entries) = std::fs::read_dir(&self.root) else {
            return;
        };
        let mut versions: Vec<(std::time::SystemTime, PathBuf)> = entries
            .filter_map(Result::ok)
            .filter(|e| e.file_name() != current && e.path().is_dir())
            .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
            .collect();
        versions.sort_by_key(|v| std::cmp::Reverse(v.0));
        for (_, old) in versions.into_iter().skip(KEEP_VERSIONS - 1) {
            let _ = std::fs::remove_dir_all(old);
        }
    }

    /// The directory a version's assets live in (tests).
    #[cfg(test)]
    fn dir(&self, version: &str) -> PathBuf {
        self.root.join(version)
    }
}

#[cfg(test)]
mod http_tests;

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(pairs: &[(&'static str, &'static str)]) -> HeaderMap {
        let mut h = HeaderMap::new();
        for (k, v) in pairs {
            h.append(*k, HeaderValue::from_static(v));
        }
        h
    }

    #[test]
    fn negotiates_brotli_first_and_honours_q() {
        let ae = |v| negotiate(&headers(&[("accept-encoding", v)]));
        assert_eq!(ae("gzip, deflate, br"), Some(Coding::Br));
        assert_eq!(ae("gzip, deflate"), Some(Coding::Gzip));
        assert_eq!(ae("br;q=0, gzip"), Some(Coding::Gzip));
        assert_eq!(ae("gzip;q=1.0, br;q=0.5"), Some(Coding::Gzip));
        assert_eq!(ae("identity"), None);
        assert_eq!(ae("*"), Some(Coding::Br));
        assert_eq!(ae("*;q=0"), None);
        assert_eq!(negotiate(&HeaderMap::new()), None);
    }

    /// DNS rebinding names an attacker can point at 127.0.0.1, and spellings of loopback.
    #[test]
    fn only_loopback_names_pass_the_host_check() {
        let host = |h: &str| loopback_host(Some(&HeaderValue::from_str(h).unwrap()));
        for ok in [
            "localhost",
            "LOCALHOST:8080",
            "app.localhost:1",
            "127.0.0.1",
            "127.0.0.1:443",
            "127.8.9.10:1",
            "[::1]",
            "[::1]:8080",
        ] {
            assert!(host(ok), "{ok}");
        }
        for evil in [
            "localhost.evil.com",
            "localhost.evil.com:80",
            "127.0.0.1.nip.io",
            "127.0.0.1.nip.io:8080",
            "evil.com",
            "localhost.",
            "evil.com.",
            "[::ffff:127.0.0.1]",
            "[::ffff:7f00:1]:80",
            "[fe80::1]",
            "0.0.0.0:80",
            "2130706433",
            "0x7f000001",
            "127.1",
            "::1",
            "",
            "evil.com#@localhost",
            "localhost@evil.com",
        ] {
            assert!(!host(evil), "{evil}");
        }
        assert!(!loopback_host(None));
    }

    #[test]
    fn decides_what_to_compress() {
        let ok = |pairs| compressible(StatusCode::OK, &headers(pairs));
        assert!(ok(&[("content-type", "text/javascript")]));
        assert!(ok(&[("content-type", "application/json; charset=utf-8")]));
        assert!(ok(&[("content-type", "image/svg+xml")]));
        assert!(ok(&[("content-type", "application/wasm")]));
        assert!(ok(&[("content-type", "font/ttf")]));
        assert!(!ok(&[("content-type", "font/woff2")]));
        assert!(!ok(&[("content-type", "image/png")]));
        assert!(!ok(&[
            ("content-type", "text/css"),
            ("content-encoding", "gzip")
        ]));
        assert!(!ok(&[
            ("content-type", "text/css"),
            ("content-length", "200")
        ]));
        assert!(ok(&[
            ("content-type", "text/css"),
            ("content-length", "2000")
        ]));
        assert!(!ok(&[
            ("content-type", "text/css"),
            ("cache-control", "public, no-transform")
        ]));
        assert!(!ok(&[
            ("content-type", "text/css"),
            ("content-range", "bytes 0-9/100")
        ]));
        assert!(!compressible(
            StatusCode::PARTIAL_CONTENT,
            &headers(&[("content-type", "text/css")])
        ));
    }

    #[test]
    fn immutable_means_a_long_max_age_and_nothing_private() {
        let imm = |pairs| is_immutable(&headers(pairs));
        assert!(imm(&[("cache-control", "public, max-age=31536000")]));
        assert!(imm(&[("cache-control", "immutable")]));
        assert!(!imm(&[("cache-control", "max-age=60")]));
        assert!(!imm(&[("cache-control", "no-cache")]));
        assert!(!imm(&[]));
        assert!(!imm(&[
            ("cache-control", "max-age=31536000"),
            ("set-cookie", "a=b")
        ]));
    }

    #[test]
    fn weakened_etags_round_trip_through_if_none_match() {
        let mut h = headers(&[("etag", "\"abc\"")]);
        weaken_etag(&mut h);
        assert_eq!(h["etag"], "W/\"abc;unz\"");
        // The server's own weak tags are left alone, both ways.
        let mut weak = headers(&[("etag", "W/\"1-2-3\"")]);
        weaken_etag(&mut weak);
        assert_eq!(weak["etag"], "W/\"1-2-3\"");

        let mut req = headers(&[("if-none-match", "W/\"abc;unz\"")]);
        assert!(unmark_if_none_match(&mut req));
        assert_eq!(req["if-none-match"], "\"abc\"");
        let mut req = headers(&[("if-none-match", "W/\"1-2-3\"")]);
        assert!(!unmark_if_none_match(&mut req));
        assert_eq!(req["if-none-match"], "W/\"1-2-3\"");
    }

    #[test]
    fn cache_keys_only_for_versioned_static_paths() {
        let dir = tempfile::tempdir().unwrap();
        let cache = AssetCache::new(dir.path().to_owned());
        let commit = "807ba2d6075c29587f884698cd7370c81ab0724c";
        let key = cache
            .key(&format!("/stable-{commit}/static/out/vs/workbench.js"))
            .unwrap();
        assert_eq!(key.version, format!("stable-{commit}"));
        assert_ne!(
            cache.key(&format!("/stable-{commit}/static/out/nls.js")),
            Some(key)
        );
        assert!(cache.key("/static/out/x.js").is_none());
        assert!(
            cache
                .key(&format!("/stable-{commit}/vscode-remote-resource?x"))
                .is_none()
        );
        assert!(cache.key("/stable-123/static/x.js").is_none());
    }

    #[test]
    fn stores_rewrites_at_the_best_level_and_prunes_old_versions() {
        let dir = tempfile::tempdir().unwrap();
        let cache = AssetCache::new(dir.path().to_owned());
        let plain: Vec<u8> = (0..4_000)
            .flat_map(|i| format!("function f{i}(x) {{ return x * {i}; }}\n").into_bytes())
            .collect();
        let mut fast = Encoder::new(Coding::Br, BR_FAST);
        let mut body = fast.write(&plain).unwrap();
        body.extend(fast.finish().unwrap());

        let v = |n: u32| format!("stable-{n:040x}");
        let key = cache.key(&format!("/{}/static/a.js", v(1))).unwrap();
        cache.write(&key, "br5", &body).unwrap();
        cache.rewrite_best(&key).unwrap();
        assert!(!cache.path(&key, "br5").exists());
        let best = std::fs::read(cache.path(&key, "br")).unwrap();
        assert!(best.len() <= body.len(), "{} > {}", best.len(), body.len());
        let mut round = Vec::new();
        brotli::BrotliDecompress(&mut &best[..], &mut round).unwrap();
        assert_eq!(round, plain);

        for n in 2..=4 {
            std::thread::sleep(Duration::from_millis(20));
            let key = cache.key(&format!("/{}/static/a.js", v(n))).unwrap();
            cache.write(&key, "gz", b"x").unwrap();
        }
        assert!(!cache.dir(&v(1)).exists(), "the oldest version is pruned");
        for n in 2..=4 {
            assert!(cache.dir(&v(n)).exists());
        }

        // Shutting down leaves the fast copy for a later rewrite instead of finishing it.
        let key = cache.key(&format!("/{}/static/b.js", v(4))).unwrap();
        cache.write(&key, "br5", &body).unwrap();
        cache.close();
        cache.rewrite_best(&key).unwrap();
        assert!(cache.path(&key, "br5").exists());
        assert!(!cache.path(&key, "br").exists());
    }
}
