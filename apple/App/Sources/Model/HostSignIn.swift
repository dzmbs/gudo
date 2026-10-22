import AuthenticationServices
import DesignSystem
import Foundation
import HostKit
import Network
import Synchronization
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A sign-in URL a program on a host opened or printed (`claude /login`, `codex login`).
nonisolated enum SignInLink: Equatable, Sendable {
    /// The provider sends the browser back to `http://localhost:<port><path>` on the host, where
    /// the program waits (the URL Claude Code hands to `BROWSER`, the one `codex login` prints).
    case loopback(port: UInt16, path: String)
    /// Claude Code's printed URL: the provider's page shows a code the terminal waits for.
    case pastedCode

    init?(_ url: URL) {
        guard url.scheme == "https" || url.scheme == "http",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
              let target = URLComponents(string: redirect), let host = target.host?.lowercased()
        else { return nil }
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host), let port = target.port, let port = UInt16(exactly: port) {
            self = .loopback(port: port, path: target.path.isEmpty ? "/" : target.path)
        } else if Self.isCodePage(host: host, path: target.path) {
            self = .pastedCode
        } else {
            return nil
        }
    }

    /// `code#state`, as Claude Code's "Paste code here" takes it, from the page its printed
    /// sign-in ends on (`https://platform.claude.com/oauth/code/callback?code=…&state=…`).
    static func pastedCode(from url: URL) -> String? {
        guard let host = url.host()?.lowercased(), isCodePage(host: host, path: url.path()),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty
        else { return nil }
        return "\(code)#\(state)"
    }

    private static func isCodePage(host: String, path: String) -> Bool {
        let anthropic = ["claude.com", "claude.ai", "anthropic.com"].contains { host == $0 || host.hasSuffix(".\($0)") }
        return anthropic && path == "/oauth/code/callback"
    }

    /// Whether `target` (a request's path and query) is the provider's answer on the callback.
    static func isCallback(_ target: String, path: String) -> Bool {
        guard let components = URLComponents(string: target), components.path == path else { return false }
        return components.queryItems?.contains { $0.name == "code" || $0.name == "error" } ?? false
    }
}

/// A sign-in for a program on a host, in the system's sign-in sheet (Google refuses embedded
/// web views). Its callback comes back to this device's `localhost:<port>`, which is forwarded
/// to the host's for as long as the sign-in lasts, so the program there gets it as if the
/// browser ran on the host. The sheet closes once the callback went through, or once the
/// program stops listening (signed in some other way, or gave up).
@MainActor
final class HostSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var active: [UInt16: HostSignIn] = [:]

    let url: URL
    let port: UInt16
    let path: String
    let hostId: String
    let hostName: String
    private weak var window: WindowModel?
    private var session: ASWebAuthenticationSession?
    private var claim: String?
    private var watch: Task<Void, Never>?
    private var called = false
    private var done = false

    /// Starts a sign-in (replacing one waiting on the same port).
    static func start(_ url: URL, port: UInt16, path: String, hostId: String, in window: WindowModel) {
        active[port]?.finish(message: nil)
        let signIn = HostSignIn(url: url, port: port, path: path, hostId: hostId, window: window)
        active[port] = signIn
        window.signInPorts.insert(port)
        Task { await signIn.begin() }
    }

    private init(url: URL, port: UInt16, path: String, hostId: String, window: WindowModel) {
        self.url = url
        self.port = port
        self.path = path
        self.hostId = hostId
        self.window = window
        hostName = window.app.hosts.record(hostId)?.name ?? hostId
    }

    private func begin() async {
        guard let window, let context = HostContext.host(hostId, app: window.app) else {
            return finish(message: "Couldn't sign in: \(hostName) isn't connected")
        }
        let hub = context.hub
        let path = path
        do {
            claim = try await DevServerRouting.shared.claimSignIn(
                port: port, hostId: hostId, client: { try hub.client() },
                onRequest: { [weak self] target in
                    guard SignInLink.isCallback(target, path: path) else { return }
                    Task { @MainActor [weak self] in self?.callbackArrived() }
                })
        } catch {
            // Taken here (a simulator shares the host's loopback): the browser reaches that
            // port directly; the watch below still sees the sign-in end.
            AppModel.log.info("sign-in port \(self.port) not claimed: \(String(describing: error), privacy: .public)")
        }
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("unnamed-signin")) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.finish(message: self?.called == true ? nil : "Sign-in closed") }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        self.session = session
        guard session.start() else {
            return finish(message: "Couldn't open the sign-in page")
        }
        watch = Task { [weak self] in await self?.watchHost(api: { try hub.client() }) }
    }

    /// Closes the sheet once the program on the host stops listening (it got its callback, or
    /// it was signed in or cancelled in the terminal).
    private func watchHost(api: @escaping () throws -> any DaemonWorkspaceAPI) async {
        var seen = false
        let deadline = ContinuousClock.now + .seconds(15 * 60)
        while !Task.isCancelled, !done, ContinuousClock.now < deadline {
            let local = try? Self.forward(api(), to: port)
            let alive = if let local { await HostPortProbe.answers(localPort: local) } else { false }
            if alive { seen = true } else if seen || local == nil {
                return finish(message: called ? signedIn : nil)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if !done { finish(message: nil) }
    }

    private static func forward(_ api: any DaemonWorkspaceAPI, to hostPort: UInt16) throws -> UInt16 {
        if let existing = api.forwards().first(where: { if case .tcp(let p) = $0.target { p == hostPort } else { false } }) {
            return existing.localPort
        }
        return try api.forward(localPort: 0, target: .tcp(port: hostPort))
    }

    private var signedIn: String { "Signed in on \(hostName)" }

    private func callbackArrived() {
        guard !called else { return }
        called = true
        // The program answers with its "signed in" page; then the sheet goes.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.finish(message: self?.signedIn)
        }
    }

    private func finish(message: String?) {
        guard !done else { return }
        done = true
        watch?.cancel()
        session?.cancel()
        session = nil
        if Self.active[port] === self {
            Self.active[port] = nil
            window?.signInPorts.remove(port)
        }
        if let message, let window {
            let success = message == signedIn
            window.toasts.show(Toast(message, systemImage: success ? "checkmark.circle.fill" : "xmark.circle", style: success ? .success : .neutral))
        }
        if let claim {
            let port = port
            // The program's "signed in" page may still be loading through the port.
            Task {
                try? await Task.sleep(for: .seconds(5))
                DevServerRouting.shared.releaseSignIn(port: port, token: claim)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            // Presenting at all means a scene is up.
            let scene = window?.scene ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
            return scene.keyWindow ?? scene.windows.first ?? ASPresentationAnchor(windowScene: scene)
            #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

/// Whether a program on the host still listens on a port: an HTTP request through a forward to
/// it gets any answer. A refused connection ends the forwarded stream without a byte.
nonisolated enum HostPortProbe {
    static func answers(localPort: UInt16) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: localPort) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            let resumed = Flag()
            let finish: @Sendable (Bool) -> Void = { alive in
                guard !resumed.value.exchange(true, ordering: .relaxed) else { return }
                connection.cancel()
                continuation.resume(returning: alive)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data("HEAD / HTTP/1.0\r\nHost: localhost\r\n\r\n".utf8), completion: .contentProcessed { _ in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                            finish(!(data ?? Data()).isEmpty)
                        }
                    })
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            // Slow to answer is still there.
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { finish(true) }
        }
    }
}

