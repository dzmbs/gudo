import Foundation
import Observation
import os
import UnnamedCore

/// What a window shows: the local workspace (macOS shell / iOS scratch echo) or a host.
enum WorkspaceTarget: Hashable, Codable {
    case local
    case host(String)
}

/// App-wide state: the hosts (HostKit's `HostsModel`) and one `Workspace` per open target, so
/// a host's panes (and their terminals) survive switching away and back. The UI binds to these;
/// docs/APP-ARCHITECTURE.md lists the seams.
@MainActor
@Observable
final class AppModel {
    let hosts: HostsModel
    /// Shown by the window when a pairing / connection started outside it fails (deep link).
    var lastError: String?

    @ObservationIgnored private var workspaces: [WorkspaceTarget: (workspace: Workspace, connection: ObjectIdentifier?)] = [:]
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "app")

    static let shared = AppModel()

    private init() {
        CoreLog.install()
        let defaults = UserDefaults.standard
        let repository = HostRepository.appDefault()
        let secrets = SecretStores.appDefault(
            service: (Bundle.main.bundleIdentifier ?? "app") + ".secrets",
            fallbackDirectory: repository.directory.appending(path: "secrets"))
        var configuration = HostsModel.Configuration()
        if defaults.string(forKey: "testRelay") == "disabled" { configuration.relay = .disabled }
        configuration.mirrorVt = defaults.bool(forKey: "testMirror")
        configuration.hostdBinaries = { Self.bundledDaemons() }
        hosts = HostsModel(secrets: secrets, repository: repository, configuration: configuration)
        hosts.hostKeyPrompts.trustNewHostsAutomatically = defaults.bool(forKey: "testTrustHostKeys")
    }

    /// The workspace for a target, created on first use. A host whose connection object changed
    /// (plain SSH upgraded to the daemon) gets a fresh workspace on the new connection.
    func workspace(for target: WorkspaceTarget) -> Workspace? {
        switch target {
        case .local:
            if let existing = workspaces[.local] { return existing.workspace }
            let workspace = Workspace()
            workspaces[.local] = (workspace, nil)
            return workspace
        case .host(let id):
            let connection: any HostConnection
            do {
                connection = try hosts.open(id)
            } catch {
                Self.log.error("open host \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
            let identity = ObjectIdentifier(connection)
            if let existing = workspaces[target], existing.connection == identity { return existing.workspace }
            let workspace = Workspace(hostId: id, connection: connection)
            workspaces[target] = (workspace, identity)
            return workspace
        }
    }

    /// The gzipped static Linux daemons bundled as resources (project.yml), for "Install helper".
    nonisolated static func bundledDaemons() -> HostdBinaries {
        func file(_ arch: String) -> HostdBinary? {
            let name = "\(Brand.name)-hostd-\(arch)-linux"
            return Bundle.main.url(forResource: name, withExtension: "gz").map { .file(path: $0.path) }
        }
        return HostdBinaries(linuxAarch64: file("aarch64"), linuxX8664: file("x86_64"), macosAarch64: nil, macosX8664: nil)
    }

    // MARK: Pairing entry points

    /// A pairing deep link (`<scheme>://pair/<ticket>`): pair and return the host to show.
    func handle(url: URL) async -> WorkspaceTarget? {
        guard let ticket = PairingTicket(url: url) else { return nil }
        do {
            return .host(try await hosts.pair(ticket))
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: Test hooks (launch arguments; used by UI tests and the real-host runs)

    /// `-testTicket <ticket>`: pair and show that host. `-testSSH user@host[:port]` with
    /// `-testSSHKey <path>` (a private key file to import) or `-testSSHPassword <pw>`: "just ssh"
    /// to it; `-testInstallHelper YES` then installs the helper and switches to the daemon.
    func runLaunchHooks() async -> WorkspaceTarget? {
        let defaults = UserDefaults.standard
        if let ticket = defaults.string(forKey: "testTicket"), !ticket.isEmpty {
            do {
                return .host(try await hosts.pair(try PairingTicket(ticket), name: "test daemon"))
            } catch {
                lastError = "pairing failed: \(error.localizedDescription)"
                Self.log.error("test pairing failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        if let destination = defaults.string(forKey: "testSSH"), !destination.isEmpty {
            let flow = JustSSHFlow(hosts: hosts)
            flow.destination = destination
            do {
                if let path = defaults.string(forKey: "testSSHKey") {
                    let pem = try Data(contentsOf: URL(fileURLWithPath: path))
                    try flow.importKey(pem: pem, passphrase: nil, label: URL(fileURLWithPath: path).lastPathComponent)
                } else if let password = defaults.string(forKey: "testSSHPassword") {
                    flow.auth = .password
                    flow.password = password
                }
            } catch {
                lastError = "key import failed: \(error.localizedDescription)"
                return nil
            }
            await flow.connect()
            guard case .connected(let id) = flow.step else {
                if case .failed(let reason) = flow.step { lastError = reason }
                return nil
            }
            if defaults.bool(forKey: "testInstallHelper") {
                Task {
                    // Let the plain-SSH pane show first (the screenshot of that step).
                    try? await Task.sleep(for: .seconds(defaults.double(forKey: "testInstallDelay").nonZero ?? 4))
                    do {
                        try await self.hosts.installHelper(id)
                    } catch {
                        self.lastError = "install failed: \(SshErrorText.describe(error))"
                    }
                }
            }
            return .host(id)
        }
        return nil
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
