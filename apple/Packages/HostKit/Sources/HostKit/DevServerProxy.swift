import Foundation
import Network

// S-BR1: a dev server on a host keeps its origin in the in-app browser.
//
// The page loads at exactly the URL the server printed (`http://localhost:3000`,
// `http://app.localhost:5173`), so cookies, OAuth callbacks, CORS and HMR websockets see the
// origin they expect. Two pieces, because WebKit does not send loopback literals through a
// proxy whatever `proxyConfigurations`, `matchDomains` or `excludedDomains` say (checked
// 2026-10-21: macOS 26 connects `localhost`, `127.0.0.1` and `[::1]` directly; the iOS 27
// simulator proxies `localhost` but not `127.0.0.1` or `[::1]`); `*.localhost` is always proxied:
//
// - `DevServerSocksProxy`: one per host, set as its `WKWebsiteDataStore.proxyConfigurations`
//   (SOCKS5). `*.localhost:<port>` (and loopback literals, should WebKit ever send them) go to
//   that host's forward of `<port>`; anything else connects directly.
// - `LoopbackRouter`: the app's listeners on this device's `127.0.0.1:<port>` and
//   `[::1]:<port>` for `localhost` URLs. Several hosts may serve the same port: each host's data
//   store carries a route cookie (`routeCookie`, HttpOnly) for the loopback names, and a
//   connection goes to the host whose cookie its first request carries, else to the host that
//   opened the port last (TLS, or a request without cookies).

/// Gives the local port of a forward to the host's `localhost:<port>`, creating it if needed.
public typealias DevServerForward = @Sendable (_ hostPort: UInt16) async throws -> UInt16

public nonisolated enum DevServerNames {
    /// `localhost`, `127.x.x.x`, `::1`: names WebKit never proxies.
    public static func isLoopbackLiteral(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// Names the host's forwards serve: loopback literals and `*.localhost`.
    public static func isRouted(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        return isLoopbackLiteral(host) || host.hasSuffix(".localhost")
    }
}

public nonisolated enum DevServerProxyError: Error, Equatable {
    /// Something other than this app listens on that loopback port here.
    case portInUse(UInt16)
    case listenerFailed(String)
}

// MARK: - Splicing

/// Copies bytes both ways; each direction's end is passed on as a half-close, and both
/// connections are cancelled once both directions ended or either failed.
nonisolated final class Splice: @unchecked Sendable {
    private let a: NWConnection
    private let b: NWConnection
    private let queue: DispatchQueue
    private var open = 2
    private var done = false

    init(_ a: NWConnection, _ b: NWConnection, queue: DispatchQueue) {
        self.a = a
        self.b = b
        self.queue = queue
    }

    func start() {
        copy(from: a, to: b)
        copy(from: b, to: a)
    }

    private func copy(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                // Read again only once written: a slow reader holds the writer back.
                sink.send(content: data, completion: .contentProcessed { [self] error in
                    if error != nil { finish() } else if isComplete { halfClose(sink) } else { copy(from: source, to: sink) }
                })
            } else if isComplete {
                halfClose(sink)
            } else if error != nil {
                finish()
            } else {
                copy(from: source, to: sink)
            }
        }
    }

    private func halfClose(_ sink: NWConnection) {
        sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
            queue.async { [self] in
                open -= 1
                if open == 0 { finish() }
            }
        })
    }

    private func finish() {
        queue.async { [self] in
            guard !done else { return }
            done = true
            a.cancel()
            b.cancel()
        }
    }
}

/// Connects to `127.0.0.1:<port>` (a forward) and calls back once ready or failed.
nonisolated func connectLocal(
    _ port: UInt16, queue: DispatchQueue, _ done: @escaping @Sendable (NWConnection?) -> Void
) {
    connect(.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), queue: queue, done)
}

nonisolated func connect(
    _ endpoint: NWEndpoint, queue: DispatchQueue, _ done: @escaping @Sendable (NWConnection?) -> Void
) {
    let connection = NWConnection(to: endpoint, using: .tcp)
    let called = Once()
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready: if called.take() { done(connection) }
        case .failed, .cancelled, .waiting:
            if called.take() {
                connection.cancel()
                done(nil)
            }
        default: break
        }
    }
    connection.start(queue: queue)
}

nonisolated final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}

/// Reads until `enough` says the buffer is complete, the peer ends, or `limit` bytes.
nonisolated func readPrefix(
    _ connection: NWConnection, buffer: Data = Data(), limit: Int, enough: @escaping @Sendable (Data) -> Bool,
    _ done: @escaping @Sendable (Data, Bool) -> Void
) {
    if enough(buffer) || buffer.count >= limit { return done(buffer, false) }
    connection.receive(minimumIncompleteLength: 1, maximumLength: limit - buffer.count) { data, _, isComplete, error in
        var buffer = buffer
        if let data { buffer.append(data) }
        if error != nil || isComplete { return done(buffer, true) }
        readPrefix(connection, buffer: buffer, limit: limit, enough: enough, done)
    }
}

// MARK: - SOCKS5

/// A SOCKS5 server on `127.0.0.1:<ephemeral>` for one host's web data store.
public nonisolated final class DevServerSocksProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev-server-socks")
    private let forward: DevServerForward
    private var listener: NWListener?
    private var routedCount = 0
    private var directCount = 0

    /// The port it listens on (after `start`).
    public private(set) var port: UInt16 = 0

    public init(forward: @escaping DevServerForward) {
        self.forward = forward
    }

    /// Connections sent to the host (`*.localhost`, loopback) and directly (anything else).
    public var counts: (routed: Int, direct: Int) { queue.sync { (routedCount, directCount) } }

    public func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        port = try await Self.ready(listener, queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    static func ready(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error), .waiting(let error):
                    if once.take() {
                        listener.cancel()
                        if case .posix(let code) = error, code == .EADDRINUSE {
                            continuation.resume(throwing: DevServerProxyError.portInUse(0))
                        } else {
                            continuation.resume(throwing: DevServerProxyError.listenerFailed("\(error)"))
                        }
                    }
                case .cancelled:
                    if once.take() { continuation.resume(throwing: DevServerProxyError.listenerFailed("cancelled")) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        // Greeting: VER, NMETHODS, METHODS…
        readPrefix(client, limit: 257, enough: { $0.count >= 2 && $0.count >= 2 + Int($0[$0.startIndex + 1]) }) { [self] greeting, _ in
            let bytes = [UInt8](greeting)
            guard bytes.count >= 2, bytes[0] == 5, bytes[2...].contains(0) else { return client.cancel() }
            client.send(content: Data([5, 0]), completion: .contentProcessed { [self] _ in request(client) })
        }
    }

    private func request(_ client: NWConnection) {
        readPrefix(client, limit: 262, enough: { Self.parseRequest([UInt8]($0)) != nil }) { [self] data, _ in
            guard let (command, host, port) = Self.parseRequest([UInt8](data)) else { return client.cancel() }
            guard command == 1 else { return reply(client, 7) }  // CONNECT only
            if DevServerNames.isRouted(host) {
                queue.async { self.routedCount += 1 }
                Task { [self] in
                    do {
                        let local = try await forward(port)
                        connectLocal(local, queue: queue) { [self] upstream in established(client, upstream) }
                    } catch {
                        reply(client, 5)
                    }
                }
            } else {
                queue.async { self.directCount += 1 }
                connect(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), queue: queue) { [self] upstream in
                    established(client, upstream)
                }
            }
        }
    }

    private func established(_ client: NWConnection, _ upstream: NWConnection?) {
        guard let upstream else { return reply(client, 5) }
        client.send(content: Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { [self] error in
            if error != nil {
                client.cancel()
                upstream.cancel()
            } else {
                Splice(client, upstream, queue: queue).start()
            }
        })
    }

    private func reply(_ client: NWConnection, _ code: UInt8) {
        client.send(content: Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]), contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in client.cancel() })
    }

    /// `VER CMD RSV ATYP DST.ADDR DST.PORT` → (command, host, port), or nil while incomplete.
    static func parseRequest(_ b: [UInt8]) -> (UInt8, String, UInt16)? {
        guard b.count >= 5, b[0] == 5 else { return nil }
        let host: String
        let end: Int
        switch b[3] {
        case 1:
            end = 8
            guard b.count >= end + 2 else { return nil }
            host = b[4..<8].map(String.init).joined(separator: ".")
        case 3:
            let length = Int(b[4])
            end = 5 + length
            guard b.count >= end + 2 else { return nil }
            host = String(decoding: b[5..<end], as: UTF8.self)
        case 4:
            end = 20
            guard b.count >= end + 2 else { return nil }
            host = stride(from: 4, to: 20, by: 2).map { String(UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]), radix: 16) }
                .joined(separator: ":")
        default:
            return nil
        }
        return (b[1], host, UInt16(b[end]) << 8 | UInt16(b[end + 1]))
    }
}

// MARK: - Loopback ports

/// The app's own listeners on this device's loopback ports for `localhost` dev server URLs,
/// shared by every host and routed by the request's route cookie (see the top of this file).
public nonisolated final class LoopbackRouter: @unchecked Sendable {
    /// The HttpOnly cookie each host's data store carries for the loopback names.
    public static let routeCookie = "__unnamed_route"

    private let queue = DispatchQueue(label: "loopback-router")
    private var listeners: [UInt16: [NWListener]] = [:]
    /// Per port: route token → that host's forward, and the host that opened it last.
    private var routes: [UInt16: [String: DevServerForward]] = [:]
    private var latest: [UInt16: String] = [:]
    private var routedBy: [String: Int] = [:]

    public init() {}

    /// Ports this router listens on.
    public var ports: [UInt16] { queue.sync { listeners.keys.sorted() } }

    /// Connections routed to `token`'s host so far.
    public func count(for token: String) -> Int { queue.sync { routedBy[token, default: 0] } }

    /// Serves `port` on this device's loopback for the host with `token`. Throws
    /// `portInUse` when something else listens on it here (the caller falls back to a forward
    /// on another port).
    public func claim(port: UInt16, token: String, forward: @escaping DevServerForward) async throws {
        let listening = queue.sync { listeners[port] != nil }
        if !listening {
            let listener = try await listen(port)
            queue.sync { listeners[port] = [listener] }
        }
        queue.sync {
            routes[port, default: [:]][token] = forward
            latest[port] = token
        }
    }

    /// Forgets a host (disconnected, removed); ports no host uses any more are closed.
    public func release(token: String) {
        queue.sync {
            for port in routes.keys {
                routes[port]?[token] = nil
                if latest[port] == token { latest[port] = routes[port]?.keys.sorted().first }
                if routes[port]?.isEmpty == true {
                    routes[port] = nil
                    latest[port] = nil
                    listeners.removeValue(forKey: port)?.forEach { $0.cancel() }
                }
            }
        }
    }

    public func stop() {
        queue.sync {
            listeners.values.joined().forEach { $0.cancel() }
            listeners = [:]
            routes = [:]
            latest = [:]
        }
    }

    /// One listener on the loopback interface takes both `127.0.0.1` and `[::1]` (WebKit tries
    /// `localhost` as ::1 first) and nothing from the network. Without address reuse, a port
    /// something else listens on here fails with `portInUse` instead of being taken over.
    private func listen(_ port: UInt16) async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, port: port) }
        do {
            _ = try await DevServerSocksProxy.ready(listener, queue: queue)
        } catch DevServerProxyError.portInUse {
            throw DevServerProxyError.portInUse(port)
        }
        return listener
    }

    private func accept(_ client: NWConnection, port: UInt16) {
        client.start(queue: queue)
        // The request head names the host by its route cookie; anything that is not HTTP
        // (TLS) goes to the latest host at once. Browsers speak first, so no timeout.
        readPrefix(client, limit: 64 * 1024, enough: Self.headIsComplete) { [self] head, ended in
            let token = Self.routeToken(in: head)
            // On `queue` already (the connection's queue).
            let forward: DevServerForward? = {
                let routes = routes[port] ?? [:]
                if let token, let forward = routes[token] {
                    routedBy[token, default: 0] += 1
                    return forward
                }
                guard let latest = latest[port] else { return nil }
                routedBy[latest, default: 0] += 1
                return routes[latest]
            }()
            guard let forward else { return client.cancel() }
            Task { [self] in
                guard let local = try? await forward(port) else { return client.cancel() }
                connectLocal(local, queue: queue) { [self] upstream in
                    guard let upstream else { return client.cancel() }
                    upstream.send(content: head, completion: .contentProcessed { [self] _ in
                        if ended {
                            upstream.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                        }
                        Splice(client, upstream, queue: queue).start()
                    })
                }
            }
        }
    }

    /// An HTTP request head is complete at its blank line; non-HTTP bytes are "complete" at once.
    static func headIsComplete(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        guard (65...90).contains(first) else { return true }  // not an HTTP method: TLS etc.
        return data.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    /// The route cookie's value in an HTTP request head.
    static func routeToken(in head: Data) -> String? {
        guard let end = head.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let text = String(decoding: head[..<end.lowerBound], as: UTF8.self)
        for line in text.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "cookie" else { continue }
            for pair in line[line.index(after: colon)...].split(separator: ";") {
                let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0] == routeCookie { return String(parts[1]) }
            }
        }
        return nil
    }
}
