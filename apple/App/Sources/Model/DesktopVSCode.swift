import Foundation
import HostKit
import os
import GudoCore
#if os(macOS)
import AppKit
import Network
#endif

/// §5): which local port a host's sshd gets, which login name, and whether a sshd answered.
/// Platform-free so it is unit-tested everywhere.
nonisolated enum RemoteSSHPlan {
    static let portsKey = "editor.remoteSSHPorts"
    /// Local ports for hosts' sshd: `[127.0.0.1]:<port>` lands in `known_hosts` once per host,
    /// so each host keeps its own port for good.
    static let portRange: ClosedRange<UInt16> = 22200...22999

    /// The host's stable local port: the one it was given before, else one derived from its id
    /// that no other host has. Remembered in `defaults`.
    static func port(for hostId: String, defaults: UserDefaults = .standard) -> UInt16 {
        var ports = defaults.dictionary(forKey: portsKey) as? [String: Int] ?? [:]
        if let port = ports[hostId], let value = UInt16(exactly: port), portRange.contains(value) { return value }
        let taken = Set(ports.values)
        let span = Int(portRange.upperBound - portRange.lowerBound) + 1
        let start = Int(fnv1a(hostId) % UInt64(span))
        var chosen = Int(portRange.lowerBound) + start
        for offset in 0..<span {
            let candidate = Int(portRange.lowerBound) + (start + offset) % span
            if !taken.contains(candidate) {
                chosen = candidate
                break
            }
        }
        ports[hostId] = chosen
        defaults.set(ports, forKey: portsKey)
        return UInt16(chosen)
    }

    /// Moves a host to another port (its usual one was taken on this Mac).
    static func reassign(_ hostId: String, to port: UInt16, defaults: UserDefaults = .standard) {
        var ports = defaults.dictionary(forKey: portsKey) as? [String: Int] ?? [:]
        ports[hostId] = Int(port)
        defaults.set(ports, forKey: portsKey)
    }

    /// The login name for the host's sshd: the SSH endpoint's when the host came from SSH, else
    /// the owner of the home directory the folder is in (`/home/<u>/…`, `/Users/<u>/…`), else
    /// nil (ssh's own default).
    static func user(sshUser: String?, folder: String?) -> String? {
        if let sshUser, !sshUser.isEmpty { return sshUser }
        guard let folder else { return nil }
        let parts = folder.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "home" || parts[0] == "Users" else {
            return folder == "/root" || folder.hasPrefix("/root/") ? "root" : nil
        }
        return String(parts[1])
    }

    /// The first bytes a sshd sends: `SSH-2.0-…` (RFC 4253 §4.2).
    static func isSSHBanner(_ data: Data) -> Bool {
        data.starts(with: Array("SSH-".utf8))
    }

    /// `vscode://…` for VS Code, `vscode-insiders://…` for Insiders.
    static func uri(_ uri: String, insiders: Bool) -> String {
        guard insiders, uri.hasPrefix("vscode://") else { return uri }
        return "vscode-insiders://" + uri.dropFirst("vscode://".count)
    }

    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

#if os(macOS)
/// "Open in VS Code" on the Mac: the user's own desktop VS Code with Microsoft's Remote - SSH,
/// reaching the host's sshd through a local port we forward over the daemon link. No licence
/// sheet here (desktop VS Code and Remote - SSH have their own) and no account. When VS Code is
/// not installed, or the host has no sshd, the in-app editor opens instead.
@MainActor
enum DesktopVSCode {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "editor")
    static let bundleIdentifiers = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]

    /// The installed VS Code and whether it is Insiders; nil when neither is installed, or for
    /// UI tests (`-desktopVSCode NO`).
    static var app: (url: URL, insiders: Bool)? {
        if UserDefaults.standard.object(forKey: "desktopVSCode") as? Bool == false { return nil }
        for id in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return (url, id.hasSuffix("Insiders"))
            }
        }
        return nil
    }

    static var isInstalled: Bool { app != nil }

    /// Opens the folder (or a file at a line) of `context` in desktop VS Code. Nil when it
    /// opened; else why not, in words, for the in-app fallback.
    static func open(context: HostContext, sshUser: String?, path: String?, line: Int?, column: Int?) async -> String? {
        guard let app else { return "Desktop VS Code is not installed." }
        do {
            let api = try context.api()
            let directory = context.directory ?? "~"
            var folder = directory
            if let status = try? await api.gitStatus(path: directory) { folder = status.root }
            let port = try forward(api, host: context.hostId)
            guard await sshdAnswers(port: port) else {
                return "\(context.name) has no SSH server that desktop VS Code could use."
            }
            let host = VsCodeSshHost(host: "127.0.0.1", user: RemoteSSHPlan.user(sshUser: sshUser, folder: folder), port: port)
            let target = path ?? folder
            let raw = vscodeRemoteSshUri(host: host, path: target, line: line.map { UInt32($0) }, column: column.map { UInt32($0) })
            guard let uri = URL(string: RemoteSSHPlan.uri(raw, insiders: app.insiders)) else { return "Could not build the VS Code link." }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([uri], withApplicationAt: app.url, configuration: configuration)
            log.info("desktop VS Code host=\(context.hostId, privacy: .public) port=\(port) path=\(target, privacy: .public)")
            return nil
        } catch {
            log.error("desktop VS Code: \(String(describing: error), privacy: .public)")
            return ScreenError.describe(error)
        }
    }

    /// A local port forwarded to the host's sshd: the existing forward, else the host's stable
    /// port (or the next free one, remembered).
    private static func forward(_ api: any DaemonWorkspaceAPI, host: String) throws -> UInt16 {
        if let existing = api.forwards().first(where: { $0.target == .tcp(port: 22) }) { return existing.localPort }
        let preferred = RemoteSSHPlan.port(for: host)
        var lastError: (any Error)?
        for offset in 0..<8 {
            let candidate = preferred &+ UInt16(offset)
            guard RemoteSSHPlan.portRange.contains(candidate) else { break }
            do {
                let bound = try api.forward(localPort: candidate, target: .tcp(port: 22))
                if bound != preferred { RemoteSSHPlan.reassign(host, to: bound) }
                return bound
            } catch {
                lastError = error
            }
        }
        throw lastError ?? HostError.notConnected
    }

    /// Whether something answering like a sshd is behind the forward (its banner within 5 s).
    nonisolated private static func sshdAnswers(port: UInt16) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let answered: Bool = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(minimumIncompleteLength: 4, maximumLength: 64) { data, _, _, _ in
                        once.resume(data.map(RemoteSSHPlan.isSSHBanner) ?? false)
                    }
                case .failed, .cancelled:
                    once.resume(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { once.resume(false) }
        }
        connection.cancel()
        return answered
    }

    nonisolated private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
#endif
