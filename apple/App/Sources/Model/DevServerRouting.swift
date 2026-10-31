import CryptoKit
import Foundation
import HostKit
import Network
import UnnamedCore
import WebKit

/// S-BR1: a host's dev server opens in the in-app browser at exactly the URL it printed
/// (`http://localhost:3000`, `http://app.localhost:5173`), so its origin, cookies, OAuth
/// callbacks, CORS and HMR websockets work as on the host. How (HostKit `DevServerProxy.swift`):
///
/// - Each host has its own `WKWebsiteDataStore` (cookies and storage never mix between two
///   hosts that both serve `:3000`) whose `proxyConfigurations` point at that host's SOCKS proxy:
///   `*.localhost:<port>` goes to the host's forward of `<port>`.
/// - WebKit does not proxy loopback literals (`127.0.0.1` and `[::1]` anywhere, `localhost` on
///   macOS), so for those the app also listens on this device's loopback port itself
///   (`LoopbackRouter`) and sends each connection to the host whose route cookie it carries.
///
/// The fallback (`page` returns nil): a forward on the same port number if free here, else on
/// any port (the origin's port changes). Taken when the port is in use here by something else
/// (on the Mac, the user's own server) or the proxy cannot start; `-browserProxy NO` forces it.
@MainActor
final class DevServerRouting {
    static let shared = DevServerRouting()

    var isEnabled = LaunchArguments().string(forKey: "browserProxy") != "NO"

    private let router = LoopbackRouter()
    private var hosts: [String: HostRoute] = [:]
    /// One instance per host's store: two instances on one identifier would not share a proxy.
    private var stores: [String: WKWebsiteDataStore] = [:]

    private final class HostRoute {
        let store: WKWebsiteDataStore
        let token: String
        var proxy: DevServerSocksProxy?
        var cookiesSet = false
        var client: () throws -> any DaemonWorkspaceAPI

        init(store: WKWebsiteDataStore, token: String, client: @escaping () throws -> any DaemonWorkspaceAPI) {
            self.store = store
            self.token = token
            self.client = client
        }
    }

    /// The host's web data store, once one of its dev servers was opened (nil: the default).
    func store(forHost id: String?) -> WKWebsiteDataStore? {
        id.flatMap { hosts[$0]?.store }
    }

    /// The store for a page on `hostId` (a host opened it, or it shows the host's servers), else
    /// the user's own. A host's pages never share cookies or storage with another host's or
    /// with the user's own browsing, whether or not its proxy runs.
    func dataStore(forHost hostId: String?) -> WKWebsiteDataStore {
        guard let hostId else { return .default() }
        if let store = stores[hostId] { return store }
        let store = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier(hostId))
        stores[hostId] = store
        return store
    }

    /// A host was removed: its pages' cookies and storage go with it.
    func forgetHost(_ hostId: String) async {
        let store = stores.removeValue(forKey: hostId)
        if let route = hosts.removeValue(forKey: hostId) {
            route.proxy?.stop()
            router.release(token: route.token)
        }
        // Emptied first: the store cannot be deleted while a page still uses it.
        await (store ?? WKWebsiteDataStore(forIdentifier: Self.storeIdentifier(hostId)))
            .removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: Self.storeIdentifier(hostId))
        } catch {
            AppModel.log.info("a removed host's web data store stays until its pages close: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Connections the in-app browser sent to the host through the proxy or the router.
    func routedConnections(forHost id: String) -> Int {
        guard let route = hosts[id] else { return 0 }
        return (route.proxy?.counts.routed ?? 0) + router.count(for: route.token)
    }

    /// The URL to load for a host's dev server, with its data store routed to the host; nil
    /// when it cannot keep the origin (the caller forwards to another port instead).
    func page(for port: DetectedPort, hostId: String, client: @escaping () throws -> any DaemonWorkspaceAPI) async -> URL? {
        guard isEnabled, let route = await route(hostId, client: client) else { return nil }
        let url = Self.pageURL(for: port)
        if let host = url.host(), DevServerNames.isLoopbackLiteral(host) {
            do {
                try await router.claim(port: port.port, token: route.token) { [weak self] hostPort in
                    guard let self else { throw HostError.notConnected }
                    return try await self.forward(hostId, hostPort)
                }
            } catch {
                // Held here by something else: the origin can only be kept where WebKit sends
                // the name through the proxy.
                if !Self.webKitProxies(host) { return nil }
            }
        }
        return url
    }

    /// The host's data store, its proxy running (a browser leaf on the host's dev servers).
    func store(forHost id: String, client: @escaping () throws -> any DaemonWorkspaceAPI) async -> WKWebsiteDataStore? {
        guard isEnabled else { return nil }
        return await route(id, client: client)?.store
    }

    /// Before a page on the host's `localhost:<port>` (or `127.0.0.1`) loads: this device's
    /// port serves the host's, as for a dev server opened from the ports list.
    func prepareLoopback(_ url: URL, hostId: String, client: @escaping () throws -> any DaemonWorkspaceAPI) async {
        guard let host = url.host(), DevServerNames.isLoopbackLiteral(host), let port = url.port.flatMap(UInt16.init(exactly:)),
              !router.ports.contains(port)
        else { return }
        _ = await page(
            for: DetectedPort(port: port, process: "", url: url.absoluteString, isHTTP: true, loopbackOnly: true, pane: nil),
            hostId: hostId, client: client)
    }

    /// Serves this device's `localhost:<port>` for the host while a sign-in waits for its
    /// callback there (`HostSignIn`); `onRequest` hears each request's target. Returns the
    /// claim's token for `releaseSignIn`. Throws when the port is taken here.
    func claimSignIn(
        port: UInt16, hostId: String, client: @escaping () throws -> any DaemonWorkspaceAPI,
        onRequest: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard await route(hostId, client: client) != nil else { throw HostError.notConnected }
        let token = "signin-" + UUID().uuidString.lowercased()
        try await router.claim(port: port, token: token, forward: { [weak self] hostPort in
            guard let self else { throw HostError.notConnected }
            return try await self.forward(hostId, hostPort)
        }, onRequest: onRequest)
        return token
    }

    func releaseSignIn(port: UInt16, token: String) {
        router.release(port: port, token: token)
    }

    /// Loopback names WebKit sends through `proxyConfigurations` (checked 2026-10-21): on iOS 27
    /// `localhost` (not `127.0.0.1` or `[::1]`); on macOS 26 none. `*.localhost` always is.
    nonisolated static func webKitProxies(_ host: String) -> Bool {
        #if os(iOS)
        host.lowercased() == "localhost"
        #else
        false
        #endif
    }

    /// What the server printed when it names this host's loopback (`localhost`, `127.0.0.1`,
    /// `*.localhost`), else `http://localhost:<port>` with the printed path.
    nonisolated static func pageURL(for port: DetectedPort) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(port.port)
        if let printed = port.url.flatMap(URLComponents.init(string:)) {
            components.scheme = printed.scheme == "https" ? "https" : "http"
            if let host = printed.host, DevServerNames.isRouted(host), printed.port == Int(port.port) {
                components.host = host == "0.0.0.0" ? "localhost" : host
            }
            components.path = printed.path
            components.query = printed.query
        }
        if components.path.isEmpty { components.path = "/" }
        return components.url ?? URL(string: "http://localhost:\(port.port)/")!
    }

    private func route(_ hostId: String, client: @escaping () throws -> any DaemonWorkspaceAPI) async -> HostRoute? {
        let route: HostRoute
        if let existing = hosts[hostId] {
            route = existing
            route.client = client
        } else {
            route = HostRoute(
                store: dataStore(forHost: hostId),
                token: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                client: client)
            hosts[hostId] = route
        }
        if route.proxy == nil {
            let proxy = DevServerSocksProxy { [weak self] hostPort in
                guard let self else { throw HostError.notConnected }
                return try await self.forward(hostId, hostPort)
            }
            do {
                try await proxy.start()
            } catch {
                return nil
            }
            route.proxy = proxy
            route.store.proxyConfigurations = [ProxyConfiguration(
                socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!))]
        }
        if !route.cookiesSet {
            for domain in ["localhost", "127.0.0.1"] {
                if let cookie = HTTPCookie(properties: [
                    .domain: domain, .path: "/", .name: LoopbackRouter.routeCookie, .value: route.token,
                    HTTPCookiePropertyKey("HttpOnly"): "TRUE",
                ]) {
                    await route.store.httpCookieStore.setCookie(cookie)
                }
            }
            route.cookiesSet = true
        }
        return route
    }

    /// A forward to the host's `localhost:<hostPort>` on any local port (reused while it lasts).
    private func forward(_ hostId: String, _ hostPort: UInt16) throws -> UInt16 {
        guard let route = hosts[hostId] else { throw HostError.notConnected }
        let api = try route.client()
        if let existing = api.forwards().first(where: { if case .tcp(let p) = $0.target { p == hostPort } else { false } }) {
            return existing.localPort
        }
        return try api.forward(localPort: 0, target: .tcp(port: hostPort))
    }

    /// The same store for a host across launches (its dev servers' cookies and storage).
    nonisolated static func storeIdentifier(_ hostId: String) -> UUID {
        WKWebsiteDataStore.stableIdentifier("unnamed-browser:\(hostId)")
    }
}

extension WKWebsiteDataStore {
    /// A data store identifier that is the same for `key` on every launch (a name-based UUID).
    nonisolated static func stableIdentifier(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension DetectedPort {
    /// A coding agent's own listener, never a dev server: Claude Code's and Codex's sign-in
    /// callbacks and editor bridges answer only at the URL the agent built, and opening their
    /// `/` breaks a sign-in in progress. By process (`claude`, `codex`, or the version-named
    /// binary Claude's native install runs as, `2.1.307`), or, in a pane running an agent, any
    /// port in the ephemeral range: servers an agent starts take a chosen port.
    nonisolated static func isAgentListener(process: String, port: UInt16, inAgentPane: Bool) -> Bool {
        let name = process.lowercased()
        if ["claude", "codex", "claude-code", "codex-cli"].contains(name) { return true }
        if name.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil { return true }
        return inAgentPane && port >= 32768
    }
}
