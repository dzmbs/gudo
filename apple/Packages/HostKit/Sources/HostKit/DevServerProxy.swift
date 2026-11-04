import Foundation
import Network
import Security

// A dev server on a host keeps its origin in the in-app browser.
//
// The page loads at exactly the URL the server printed (`http://localhost:3000`,
// `http://app.localhost:5173`), so cookies, OAuth callbacks, CORS and HMR websockets see the
// origin they expect. Two pieces, because WebKit does not send loopback literals through a
// proxy whatever `proxyConfigurations`, `matchDomains` or `excludedDomains` say (macOS 26
// connects `localhost`, `127.0.0.1` and `[::1]` directly; the iOS 27 simulator proxies
// `localhost` but not `127.0.0.1` or `[::1]`); `*.localhost` is always proxied:
//
// - `DevServerSocksProxy`: one per host, set as its `WKWebsiteDataStore.proxyConfigurations`
//   (SOCKS5 with a username and password only that data store is given, so other programs and
//   users on this device cannot use it). `*.localhost:<port>` (and loopback literals, should
//   WebKit ever send them) go to that host's forward of `<port>`; anything else connects
//   directly.
// - `LoopbackRouter`: the app's listeners on this device's `127.0.0.1:<port>` and
//   `[::1]:<port>` for `localhost` URLs. Several hosts may serve the same port: each host's data
//   store carries a route cookie (`routeCookie`, HttpOnly) for the loopback names, and a
//   connection goes to the host whose cookie its first request carries, for a loopback `Host`.
//   Anything else (no cookie, TLS, another name) is refused, except on a sign-in's callback
//   port while the sign-in lasts: its callback comes from a browser without the cookie.
//
// Which ports of a host the forward opens is the caller's: `DevServerProxyError.portNotOpened`
// refuses one.

/// Gives the local port of a forward to the host's `localhost:<port>`, creating it if needed.
public typealias DevServerForward = @Sendable (_ hostPort: UInt16) async throws -> UInt16

public nonisolated enum DevServerNames {
    /// `localhost`, `127.x.x.x`, `::1`: names WebKit never proxies.
    public static func isLoopbackLiteral(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        return IPv4Address(host).map { $0.rawValue.first == 127 } ?? false
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
    /// The host's port was not opened for the browser.
    case portNotOpened(UInt16)
}

/// Equal whatever the contents, in time that depends only on the lengths.
nonisolated func constantTimeEqual(_ first: some Collection<UInt8>, _ second: some Collection<UInt8>) -> Bool {
    guard first.count == second.count else { return false }
    return zip(first, second).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

nonisolated func randomSecret() -> String {
    var bytes = [UInt8](repeating: 0, count: 24)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "no system randomness")
    return bytes.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Splicing

/// Copies bytes both ways; each direction's end is passed on as a half-close, and both
/// connections are cancelled once both directions ended or either failed.
nonisolated final class Splice: @unchecked Sendable {
    private let first: NWConnection
    private let second: NWConnection
    private let queue: DispatchQueue
    private var open = 2
    private var done = false

    init(_ first: NWConnection, _ second: NWConnection, queue: DispatchQueue) {
        self.first = first
        self.second = second
        self.queue = queue
    }

    func start() {
        copy(from: first, to: second)
        copy(from: second, to: first)
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
            first.cancel()
            second.cancel()
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

    /// The only username and password it takes (RFC 1929), random per proxy.
    public let credential = (username: randomSecret(), password: randomSecret())

    public init(forward: @escaping DevServerForward) {
        self.forward = forward
    }

    /// The proxy configuration for the host's data store, its credential applied.
    public var configuration: ProxyConfiguration {
        var configuration = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        configuration.applyCredential(username: credential.username, password: credential.password)
        return configuration
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
        // Greeting: VER, NMETHODS, METHODS…; only username and password (2).
        readPrefix(client, limit: 257, enough: { $0.count >= 2 && $0.count >= 2 + Int($0[$0.startIndex + 1]) }) { [self] greeting, _ in
            let bytes = [UInt8](greeting)
            guard bytes.count >= 2, bytes[0] == 5 else { return client.cancel() }
            guard bytes[2...].contains(2) else { return refuse(client, Data([5, 0xFF])) }
            client.send(content: Data([5, 2]), completion: .contentProcessed { [self] _ in authenticate(client) })
        }
    }

    /// `VER=1 ULEN UNAME PLEN PASSWD`, checked against `credential`.
    private func authenticate(_ client: NWConnection) {
        readPrefix(client, limit: 513, enough: { Self.parseLogin([UInt8]($0)) != nil }) { [self] data, _ in
            guard let (username, password) = Self.parseLogin([UInt8](data)) else { return client.cancel() }
            let userMatches = constantTimeEqual(username, Array(credential.username.utf8))
            let passwordMatches = constantTimeEqual(password, Array(credential.password.utf8))
            guard userMatches && passwordMatches else { return refuse(client, Data([1, 1])) }
            client.send(content: Data([1, 0]), completion: .contentProcessed { [self] _ in request(client) })
        }
    }

    private func refuse(_ client: NWConnection, _ reply: Data) {
        client.send(content: reply, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in client.cancel() })
    }

    /// `VER ULEN UNAME PLEN PASSWD` → (username, password), or nil while incomplete.
    static func parseLogin(_ bytes: [UInt8]) -> ([UInt8], [UInt8])? {
        guard bytes.count >= 2, bytes[0] == 1 else { return nil }
        let userEnd = 2 + Int(bytes[1])
        guard bytes.count > userEnd else { return nil }
        let passwordEnd = userEnd + 1 + Int(bytes[userEnd])
        guard bytes.count >= passwordEnd else { return nil }
        return (Array(bytes[2..<userEnd]), Array(bytes[(userEnd + 1)..<passwordEnd]))
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
                    } catch DevServerProxyError.portNotOpened {
                        reply(client, 2)
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
    static func parseRequest(_ bytes: [UInt8]) -> (UInt8, String, UInt16)? {
        guard bytes.count >= 5, bytes[0] == 5 else { return nil }
        let host: String
        let end: Int
        switch bytes[3] {
        case 1:
            end = 8
            guard bytes.count >= end + 2 else { return nil }
            host = bytes[4..<8].map(String.init).joined(separator: ".")
        case 3:
            let length = Int(bytes[4])
            end = 5 + length
            guard bytes.count >= end + 2 else { return nil }
            host = String(decoding: bytes[5..<end], as: UTF8.self)
        case 4:
            end = 20
            guard bytes.count >= end + 2 else { return nil }
            host = stride(from: 4, to: 20, by: 2).map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }
                .joined(separator: ":")
        default:
            return nil
        }
        return (bytes[1], host, UInt16(bytes[end]) << 8 | UInt16(bytes[end + 1]))
    }
}

// MARK: - Loopback ports

/// The app's own listeners on this device's loopback ports for `localhost` dev server URLs,
/// shared by every host and routed by the request's route cookie (see the top of this file).
public nonisolated final class LoopbackRouter: @unchecked Sendable {
    /// The HttpOnly cookie each host's data store carries for the loopback names.
    public static let routeCookie = "__gudo_route"

    private let queue = DispatchQueue(label: "loopback-router")
    private var listeners: [UInt16: [NWListener]] = [:]
    /// Per port: route token → that host's forward.
    private var routes: [UInt16: [String: DevServerForward]] = [:]
    /// Per port: the sign-in that takes requests without a route cookie.
    private var callbacks: [UInt16: String] = [:]
    private var routedBy: [String: Int] = [:]
    /// Per port: told each HTTP request's target (a sign-in waiting for its callback).
    private var observers: [UInt16: @Sendable (String) -> Void] = [:]

    public init() {}

    /// Ports this router listens on.
    public var ports: [UInt16] { queue.sync { listeners.keys.sorted() } }

    /// Connections routed to `token`'s host so far.
    public func count(for token: String) -> Int { queue.sync { routedBy[token, default: 0] } }

    /// Serves `port` on this device's loopback for the host with `token`. Throws
    /// `portInUse` when something else listens on it here (the caller falls back to a forward
    /// on another port).
    /// `onRequest` hears the target (`/callback?code=…`) of every HTTP request on the port.
    /// With `acceptsAnyRequest` (a sign-in's callback port, until released), requests without a
    /// route cookie go to this host too.
    public func claim(
        port: UInt16, token: String, forward: @escaping DevServerForward, acceptsAnyRequest: Bool = false,
        onRequest: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let listening = queue.sync { listeners[port] != nil }
        if !listening {
            let listener = try await listen(port)
            queue.sync { listeners[port] = [listener] }
        }
        queue.sync {
            routes[port, default: [:]][token] = forward
            if acceptsAnyRequest { callbacks[port] = token }
            if let onRequest { observers[port] = onRequest }
        }
    }

    /// Stops serving `port` for `token`'s host (a sign-in is over); closed once no host uses it.
    public func release(port: UInt16, token: String) {
        queue.sync {
            forget(token, on: port)
        }
    }

    /// On `queue`.
    private func forget(_ token: String, on port: UInt16) {
        routes[port]?[token] = nil
        if callbacks[port] == token { callbacks[port] = nil }
        if routes[port]?.isEmpty == true {
            routes[port] = nil
            observers[port] = nil
            listeners.removeValue(forKey: port)?.forEach { $0.cancel() }
        }
    }

    /// Forgets a host (disconnected, removed); ports no host uses any more are closed.
    public func release(token: String) {
        queue.sync {
            for port in routes.keys { forget(token, on: port) }
        }
    }

    public func stop() {
        queue.sync {
            listeners.values.joined().forEach { $0.cancel() }
            listeners = [:]
            routes = [:]
            callbacks = [:]
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
        // The request head names the host by its route cookie. Browsers speak first, so no
        // timeout.
        readPrefix(client, limit: 64 * 1024, enough: Self.headIsComplete) { [self] head, ended in
            // On `queue` already (the connection's queue).
            guard let token = route(head, port: port), let forward = routes[port]?[token] else { return client.cancel() }
            routedBy[token, default: 0] += 1
            if let observe = observers[port], let target = Self.requestTarget(in: head) { observe(target) }
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

    /// The route token of an HTTP request for a loopback name: its route cookie's host, else a
    /// sign-in waiting on the port. On `queue`.
    private func route(_ head: Data, port: UInt16) -> String? {
        guard Self.requestTarget(in: head) != nil, let host = Self.hostHeader(in: head),
              DevServerNames.isLoopbackLiteral(Self.hostName(host))
        else { return nil }
        if let cookie = Self.routeToken(in: head),
           let token = routes[port]?.keys.first(where: { constantTimeEqual(Array($0.utf8), Array(cookie.utf8)) }) {
            return token
        }
        return callbacks[port]
    }

    /// The `Host` header of an HTTP request head.
    static func hostHeader(in head: Data) -> String? {
        guard let end = head.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let text = String(decoding: head[..<end.lowerBound], as: UTF8.self)
        for line in text.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "host" else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `localhost:3000` → `localhost`, `[::1]:3000` → `[::1]`.
    static func hostName(_ host: String) -> String {
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") { return String(host[...close]) }
        return String(host.split(separator: ":", maxSplits: 1).first ?? "")
    }

    /// An HTTP request head is complete at its blank line; non-HTTP bytes are "complete" at once.
    static func headIsComplete(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        guard (65...90).contains(first) else { return true }  // not an HTTP method: TLS etc.
        return data.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    /// The target of an HTTP request head (`/callback?code=…`).
    static func requestTarget(in head: Data) -> String? {
        guard let end = head.range(of: Data("\r\n".utf8)) else { return nil }
        let words = String(decoding: head[..<end.lowerBound], as: UTF8.self).split(separator: " ")
        guard words.count == 3, words[2].hasPrefix("HTTP/") else { return nil }
        return String(words[1])
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
