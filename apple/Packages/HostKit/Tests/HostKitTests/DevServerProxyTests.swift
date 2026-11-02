import CryptoKit
import Foundation
import Network
import WebKit
import XCTest
@testable import HostKit

/// S-BR1: the SOCKS proxy and the loopback router route dev server connections to the right
/// host's forward, and WebKit keeps the page's origin, cookies and websockets through them.
nonisolated final class DevServerProxyTests: XCTestCase {
    // MARK: SOCKS

    func testSocksSendsLocalhostNamesToTheHostsForward() async throws {
        let server = try await TestDevServer.start(name: "A")
        defer { server.stop() }
        let asked = Locked<[UInt16]>([])
        let proxy = DevServerSocksProxy { port in
            asked.mutate { $0.append(port) }
            return server.port
        }
        try await proxy.start()
        defer { proxy.stop() }

        let reply = try await RawClient.socksGet(proxy: proxy.port, host: "app.localhost", port: 48_321, path: "/whoami")
        XCTAssertTrue(reply.contains("server=A"), reply)
        XCTAssertTrue(reply.contains("host=app.localhost:48321"), "the Host header is the page's own: \(reply)")
        XCTAssertEqual(asked.value, [48_321], "the host's port, not the forward's")
        XCTAssertEqual(proxy.counts.routed, 1)
        XCTAssertEqual(proxy.counts.direct, 0)
    }

    func testSocksRequestParsing() {
        XCTAssertNil(DevServerSocksProxy.parseRequest([5, 1, 0, 3, 9, 0x61]), "incomplete")
        let domain: [UInt8] = [5, 1, 0, 3, 9] + Array("localhost".utf8) + [0x0B, 0xB8]
        XCTAssertEqual(DevServerSocksProxy.parseRequest(domain)?.1, "localhost")
        XCTAssertEqual(DevServerSocksProxy.parseRequest(domain)?.2, 3000)
        let v4: [UInt8] = [5, 1, 0, 1, 127, 0, 0, 1, 0x1F, 0x90]
        XCTAssertEqual(DevServerSocksProxy.parseRequest(v4)?.1, "127.0.0.1")
        XCTAssertEqual(DevServerSocksProxy.parseRequest(v4)?.2, 8080)
        let v6: [UInt8] = [5, 1, 0, 4] + Array(repeating: 0, count: 15) + [1, 0, 80]
        XCTAssertEqual(DevServerSocksProxy.parseRequest(v6)?.1, "0:0:0:0:0:0:0:1")
    }

    func testRoutedNames() {
        for name in ["localhost", "LOCALHOST", "127.0.0.1", "127.1.2.3", "[::1]", "app.localhost", "a.b.localhost", "app.localhost."] {
            XCTAssertTrue(DevServerNames.isRouted(name), name)
        }
        for name in ["example.com", "localhost.example.com", "10.0.0.1", "mylocalhost"] {
            XCTAssertFalse(DevServerNames.isRouted(name), name)
        }
        XCTAssertTrue(DevServerNames.isLoopbackLiteral("localhost"))
        XCTAssertFalse(DevServerNames.isLoopbackLiteral("app.localhost"), "proxied, not a loopback listener")
    }

    // MARK: Loopback router

    func testRouterPicksTheHostByItsCookie() async throws {
        let a = try await TestDevServer.start(name: "A")
        let b = try await TestDevServer.start(name: "B")
        defer { a.stop(); b.stop() }
        let router = LoopbackRouter()
        defer { router.stop() }
        let port: UInt16 = 48_322
        try await router.claim(port: port, token: "ta") { _ in a.port }
        try await router.claim(port: port, token: "tb") { _ in b.port }
        XCTAssertEqual(router.ports, [port])

        let viaA = try await RawClient.get(port: port, path: "/whoami", cookie: "x=1; \(LoopbackRouter.routeCookie)=ta")
        XCTAssertTrue(viaA.contains("server=A"), viaA)
        let viaB = try await RawClient.get(port: port, path: "/whoami", cookie: "\(LoopbackRouter.routeCookie)=tb")
        XCTAssertTrue(viaB.contains("server=B"), viaB)
        let none = try await RawClient.get(port: port, path: "/whoami", cookie: nil)
        XCTAssertTrue(none.contains("server=B"), "no cookie: the host that opened the port last")
        XCTAssertEqual(router.count(for: "ta"), 1)
        XCTAssertEqual(router.count(for: "tb"), 2)

        router.release(token: "tb")
        let afterRelease = try await RawClient.get(port: port, path: "/whoami", cookie: nil)
        XCTAssertTrue(afterRelease.contains("server=A"), afterRelease)
        router.release(token: "ta")
        XCTAssertEqual(router.ports, [], "a port no host uses is closed")
    }

    func testRouterRefusesAPortTakenHere() async throws {
        let other = try await TestDevServer.start(name: "mine", port: 48_323)
        defer { other.stop() }
        let router = LoopbackRouter()
        defer { router.stop() }
        do {
            try await router.claim(port: 48_323, token: "t") { _ in 1 }
            XCTFail("claimed a port something else listens on")
        } catch let error as DevServerProxyError {
            XCTAssertEqual(error, .portInUse(48_323))
        }
        let still = try await RawClient.get(port: 48_323, path: "/whoami", cookie: nil)
        XCTAssertTrue(still.contains("server=mine"), "the other listener keeps its port")
    }

    /// A sign-in's callback port: served for the host while the sign-in lasts, its requests
    /// heard (the callback arriving), then closed.
    func testSignInPortIsObservedAndReleased() async throws {
        let host = try await TestDevServer.start(name: "H")
        defer { host.stop() }
        let router = LoopbackRouter()
        defer { router.stop() }
        let port: UInt16 = 48_324
        let heard = Locked<[String]>([])
        try await router.claim(port: port, token: "signin", forward: { _ in host.port }) { target in
            heard.mutate { $0.append(target) }
        }
        let reply = try await RawClient.get(port: port, path: "/whoami?code=abc&state=s", cookie: nil)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"), "the host answered: \(reply)")
        XCTAssertEqual(heard.value, ["/whoami?code=abc&state=s"])
        router.release(port: port, token: "signin")
        XCTAssertEqual(router.ports, [])
        XCTAssertEqual(LoopbackRouter.requestTarget(in: Data("GET /a?b=c HTTP/1.1\r\nHost: x\r\n\r\n".utf8)), "/a?b=c")
        XCTAssertNil(LoopbackRouter.requestTarget(in: Data([0x16, 3, 1, 0, 1])))
    }

    func testRouterHeadParsing() {
        XCTAssertFalse(LoopbackRouter.headIsComplete(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)))
        XCTAssertTrue(LoopbackRouter.headIsComplete(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        XCTAssertTrue(LoopbackRouter.headIsComplete(Data([0x16, 3, 1])), "TLS goes on at once")
        let head = Data("GET / HTTP/1.1\r\nHost: localhost:3000\r\nCOOKIE: a=b; __gudo_route=tok; c=d\r\n\r\n".utf8)
        XCTAssertEqual(LoopbackRouter.routeToken(in: head), "tok")
        XCTAssertNil(LoopbackRouter.routeToken(in: Data("GET / HTTP/1.1\r\nCookie: a=b\r\n\r\n".utf8)))
    }

    // MARK: WebKit end to end

    /// Two hosts both serving the same port: each host's data store reaches its own server, at
    /// the URL the server printed, with its cookies and a websocket, for `*.localhost` (SOCKS)
    /// and `localhost` (the loopback router).
    @MainActor func testWebKitKeepsTheOriginPerHost() async throws {
        let a = try await TestDevServer.start(name: "A")
        let b = try await TestDevServer.start(name: "B")
        defer { a.stop(); b.stop() }
        let router = LoopbackRouter()
        defer { router.stop() }
        let port: UInt16 = 48_324

        var views: [(String, WKWebView, DevServerSocksProxy)] = []
        for (name, server) in [("A", a), ("B", b)] {
            let token = "token-\(name)"
            let proxy = DevServerSocksProxy { _ in server.port }
            try await proxy.start()
            let store = WKWebsiteDataStore(forIdentifier: UUID())
            store.proxyConfigurations = [ProxyConfiguration(
                socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!))]
            for domain in ["localhost", "127.0.0.1"] {
                let cookie = HTTPCookie(properties: [
                    .domain: domain, .path: "/", .name: LoopbackRouter.routeCookie, .value: token,
                    HTTPCookiePropertyKey("HttpOnly"): "TRUE",
                ])!
                await store.httpCookieStore.setCookie(cookie)
            }
            try await router.claim(port: port, token: token) { _ in server.port }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = store
            views.append((name, WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration), proxy))
        }
        defer { views.forEach { $0.2.stop() } }

        for origin in ["http://app.localhost:\(port)", "http://localhost:\(port)"] {
            for (_, view, _) in views { view.load(URLRequest(url: URL(string: origin + "/")!)) }
            for (name, view, _) in views {
                let result = try await Self.result(of: view, origin: origin)
                XCTAssertTrue(result.contains("origin=\(origin) "), "\(name): \(result)")
                XCTAssertTrue(result.contains("server=\(name) "), "\(name) reaches its own host: \(result)")
                XCTAssertTrue(result.contains("cookie=dev=dev-\(name) "), "\(name)'s page cookie reaches its server: \(result)")
                XCTAssertTrue(result.contains("ws=echo:hello"), "\(name): websocket through the route: \(result)")
                XCTAssertFalse(result.contains("visible-route"), "the route cookie is HttpOnly: \(result)")
            }
        }
        XCTAssertGreaterThan(views[0].2.counts.routed, 0, "*.localhost went through the proxy")
        XCTAssertGreaterThan(router.count(for: "token-A"), 0)
        XCTAssertGreaterThan(router.count(for: "token-B"), 0)
    }

    /// Polls the test page's `window.result` until its checks finished.
    @MainActor private static func result(of view: WKWebView, origin: String) async throws -> String {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let value = try? await view.evaluateJavaScript("window.result || ''") as? String, value.contains("origin=\(origin) "), value.contains("done") {
                return value
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return (try? await view.evaluateJavaScript("location.href + ' ' + (window.result || 'no result')") as? String) ?? "timeout"
    }
}

// MARK: - Helpers

nonisolated final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// A dev server stand-in on `127.0.0.1`: `/` is a page that sets a cookie, asks `/whoami`
/// what the server saw, and echoes over a websocket on `/ws`; results land in `window.result`.
nonisolated final class TestDevServer: @unchecked Sendable {
    let name: String
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-dev-server")

    private init(name: String, listener: NWListener) {
        self.name = name
        self.listener = listener
    }

    static func start(name: String, port: UInt16 = 0) async throws -> TestDevServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let server = TestDevServer(name: name, listener: try NWListener(using: parameters))
        server.listener.newConnectionHandler = { [server] connection in server.serve(connection) }
        server.port = try await DevServerSocksProxy.ready(server.listener, queue: server.queue)
        return server
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readPrefix(connection, limit: 64 * 1024, enough: { $0.range(of: Data("\r\n\r\n".utf8)) != nil }) { [self] head, _ in
            let text = String(decoding: head, as: UTF8.self)
            let lines = text.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            func header(_ name: String) -> String {
                lines.dropFirst().first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                    .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) } ?? ""
            }
            if path == "/ws" {
                let accept = Data(Insecure.SHA1.hash(data: Data((header("Sec-WebSocket-Key") + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                    .base64EncodedString()
                let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { [self] _ in echoFrame(connection) })
                return
            }
            let body: String
            let type: String
            if path == "/whoami" {
                // The page's own cookies only (the route cookie is the app's business).
                let cookies = header("Cookie").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.hasPrefix(LoopbackRouter.routeCookie) }.joined(separator: ";")
                body = "server=\(name) host=\(header("Host")) cookie=\(cookies) "
                type = "text/plain"
            } else {
                body = Self.page(name: name)
                type = "text/html"
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Reads one small masked client frame and sends its text back as "echo:<text>".
    private func echoFrame(_ connection: NWConnection) {
        readPrefix(connection, limit: 4096, enough: { $0.count >= 6 && $0.count >= 6 + Int($0[$0.startIndex + 1] & 0x7F) }) { data, _ in
            let bytes = [UInt8](data)
            guard bytes.count >= 6 else { return connection.cancel() }
            let length = Int(bytes[1] & 0x7F)
            let mask = Array(bytes[2..<6])
            let payload = (0..<length).map { bytes[6 + $0] ^ mask[$0 % 4] }
            let reply = Array("echo:".utf8) + payload
            connection.send(content: Data([0x81, UInt8(reply.count)] + reply), completion: .contentProcessed { _ in })
        }
    }

    static func page(name: String) -> String {
        """
        <!doctype html><title>\(name)</title><script>
        document.cookie = "dev=dev-\(name); path=/";
        const out = { origin: location.origin };
        fetch("/whoami").then(r => r.text()).then(t => {
          out.who = t;
          const ws = new WebSocket("ws://" + location.host + "/ws");
          ws.onopen = () => ws.send("hello");
          ws.onmessage = e => { out.ws = e.data; finish(); };
          ws.onerror = () => { out.ws = "error"; finish(); };
        }).catch(e => { out.who = "fetch failed " + e; finish(); });
        function finish() {
          const visible = document.cookie.includes("\(LoopbackRouter.routeCookie)") ? " visible-route" : "";
          window.result = "origin=" + out.origin + " " + out.who + " ws=" + out.ws + visible + " done";
        }
        </script>
        """
    }
}

/// Plain TCP clients for the proxy and the router.
nonisolated enum RawClient {
    static func get(port: UInt16, path: String, cookie: String?) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        try await ready(connection)
        var request = "GET \(path) HTTP/1.1\r\nHost: localhost:\(port)\r\n"
        if let cookie { request += "Cookie: \(cookie)\r\n" }
        try await send(connection, Data((request + "\r\n").utf8))
        return try await readAll(connection)
    }

    static func socksGet(proxy: UInt16, host: String, port: UInt16, path: String) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy)!, using: .tcp)
        defer { connection.cancel() }
        try await ready(connection)
        try await send(connection, Data([5, 1, 0]))
        let method = [UInt8](try await read(connection, 2))
        XCTAssertEqual(method, [5, 0])
        try await send(connection, Data([5, 1, 0, 3, UInt8(host.utf8.count)] + Array(host.utf8) + [UInt8(port >> 8), UInt8(port & 0xFF)]))
        let reply = [UInt8](try await read(connection, 10))
        XCTAssertEqual(reply.prefix(2), [5, 0], "CONNECT succeeds")
        try await send(connection, Data("GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\n\r\n".utf8))
        return try await readAll(connection)
    }

    private static func ready(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume() }
                case .failed(let error), .waiting(let error): if once.take() { continuation.resume(throwing: error) }
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }

    private static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func read(_ connection: NWConnection, _ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private static func readAll(_ connection: NWConnection) async throws -> String {
        var all = Data()
        while true {
            let (data, done): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, isComplete)) }
                }
            }
            if let data { all.append(data) }
            if done { return String(decoding: all, as: UTF8.self) }
        }
    }
}
