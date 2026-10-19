import Foundation
import Observation
import os
import PaneLayout
import UnnamedCore

/// What a window shows: the local workspace (macOS shell / iOS scratch echo) or a host.
enum WorkspaceTarget: Hashable, Codable {
    case local
    case host(String)
}

/// App-wide state: the hosts (HostKit's `HostsModel`), this device's layout, and the pane
/// streams every window shares. Each window makes its own `Workspace` per host
/// (`makeWorkspace`): its own selection, terminals and views over the host's one layout store and
/// one stream per pane (docs/APP-ARCHITECTURE.md "Windows").
@MainActor
@Observable
final class AppModel {
    let hosts: HostsModel
    /// Shown by the window when a pairing / connection started outside it fails (deep link).
    var lastError: String?
    /// This device's tabs (the Mac's shells; empty on iPhone and iPad unless a test or fixture
    /// asks for the echo stand-in), shared by every window like a host's layout.
    let localLayout: LocalLayoutStore

    /// Pane streams shared by windows, for backends that are one process or channel per pane
    /// (local PTYs, plain SSH, the echo stand-in). Daemon panes share their connection's router.
    @ObservationIgnored private var sharedPanes: [SharedPaneKey: SharedPaneBackend] = [:]
    /// Every open window (Hosts closing in one window stay connected while another shows them).
    @ObservationIgnored private let windows = NSHashTable<WindowModel>.weakObjects()

    private struct SharedPaneKey: Hashable {
        /// The connection (nil: this device).
        var connection: ObjectIdentifier?
        var pane: PaneId
    }
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "app")

    static let shared = AppModel()

    private init() {
        CoreLog.install()
        let defaults = UserDefaults.standard
        // `-hostsDirectory <path>`: saved hosts and secrets in that folder only (UI tests and
        // screenshots against throwaway daemons never touch the user's own hosts or Keychain).
        let isolated = defaults.string(forKey: "hostsDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let repository = isolated.map { HostRepository(directory: $0) } ?? HostRepository.appDefault()
        let secrets: any SecretStore = isolated.map { FileSecretStore(directory: $0.appending(path: "secrets")) }
            ?? SecretStores.appDefault(
                service: (Bundle.main.bundleIdentifier ?? "app") + ".secrets",
                fallbackDirectory: repository.directory.appending(path: "secrets"))
        var configuration = HostsModel.Configuration()
        if defaults.string(forKey: "testRelay") == "disabled" { configuration.relay = .disabled }
        configuration.mirrorVt = defaults.bool(forKey: "testMirror")
        configuration.hostdBinaries = { Self.bundledDaemons() }
        // `-testBundledDaemons <dir>`: a hostd-manifest.json and builds elsewhere (tests that
        // update a local daemon).
        let manifest = defaults.string(forKey: "testBundledDaemons").map {
            URL(fileURLWithPath: $0).appending(path: "hostd-manifest.json")
        } ?? Bundle.main.url(forResource: "hostd-manifest", withExtension: "json")
        let bundled = manifest.flatMap(BundledDaemons.load(manifest:))
        configuration.bundledDaemons = { bundled }
        hosts = HostsModel(secrets: secrets, repository: repository, configuration: configuration)
        hosts.hostKeyPrompts.trustNewHostsAutomatically = defaults.bool(forKey: "testTrustHostKeys")
        // No local shell on iOS (only the echo stand-in for tests): an empty session.
        localLayout = LaunchOptions.hasLocalShell ? LocalLayoutStore() : LocalLayoutStore(session: Session(tabs: [], activeTabId: nil))
    }

    /// A window's workspace for a target: this window's view of the host (its own selection,
    /// starting on `tab` if given, and its own terminals) over the host's shared layout and pane
    /// streams. Opening the host connects it if needed; nil if it cannot be opened.
    func makeWorkspace(for target: WorkspaceTarget, selecting tab: TabId? = nil) -> Workspace? {
        switch target {
        case .local:
            return Workspace(layout: localLayout, selecting: tab) { [weak self] pane in
                guard let self else { throw HostError.notConnected }
                return try self.sharedPane(nil, pane) { try makeLocalBackend(for: pane) }
            }
        case .host(let id):
            let connection: any HostConnection
            do {
                connection = try hosts.open(id)
            } catch {
                Self.log.error("open host \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
            // A daemon's router already shares each pane's stream between windows.
            if connection is DaemonConnection { return Workspace(hostId: id, connection: connection, selecting: tab) }
            return Workspace(hostId: id, connection: connection, selecting: tab) { [weak self, weak connection] pane in
                guard let self, let connection else { throw HostError.notConnected }
                return try self.sharedPane(ObjectIdentifier(connection), pane) { try connection.makeBackend(for: pane) }
            }
        }
    }

    /// A tap of a pane's shared stream, starting the backend with the first window that shows
    /// the pane.
    private func sharedPane(
        _ connection: ObjectIdentifier?, _ pane: PaneId, make: () throws -> any PaneBackend
    ) rethrows -> any PaneBackend {
        sharedPanes = sharedPanes.filter { !$0.value.isTerminated }
        let key = SharedPaneKey(connection: connection, pane: pane)
        if let shared = sharedPanes[key] { return shared.makeTap() }
        let shared = SharedPaneBackend(try make())
        sharedPanes[key] = shared
        return shared.makeTap()
    }

    /// Every open window's workspaces, the key window's first (dictation looks for the pane
    /// that has the keyboard, else the key window's focused pane).
    var openWorkspaces: [Workspace] {
        let key = openWindows.first { $0 === ActiveWindow.model }
        let windows = (key.map { [$0] } ?? []) + openWindows.filter { $0 !== key }
        return windows.flatMap { window in
            [window.workspace].compactMap { $0 } + window.workspaces.values.filter { $0 !== window.workspace }
        }
    }

    /// Ends the shared streams of a connection that closed (its panes cannot come back).
    func endSharedPanes(of connection: any HostConnection) {
        let id = ObjectIdentifier(connection)
        for (key, shared) in sharedPanes where key.connection == id { shared.terminate() }
        sharedPanes = sharedPanes.filter { $0.key.connection != id }
    }

    // MARK: Windows

    func register(_ window: WindowModel) {
        windows.add(window)
        windowsChanged += 1
    }

    /// Bumped when a window opens or closes (observers of `openWindows`).
    var windowsChanged = 0

    /// Whether a window other than `window` has a host open.
    func isHostOpen(_ id: String, elsewhereThan window: WindowModel) -> Bool {
        windows.allObjects.contains { $0 !== window && !$0.isClosed && $0.groups.openHosts.contains(id) }
    }

    /// Every open window, most recently active first when known.
    var openWindows: [WindowModel] { windows.allObjects.filter { !$0.isClosed } }

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
    /// `-testTickets <t1>,<t2>,…` pairs with each daemon (named by `-testTicketNames
    /// alpha,beta,…`) for the multi-host tests; the window opens them all and shows the first.
    func runLaunchHooks() async -> [WorkspaceTarget] {
        // Once per app: every window's launch asks, only the first pairs and shows the hosts
        // (two windows restored at launch must not pair the same ticket twice).
        guard !launchHooksRan else { return [] }
        launchHooksRan = true
        let defaults = UserDefaults.standard
        if let list = defaults.string(forKey: "testTickets"), !list.isEmpty {
            let tickets = list.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            let names = (defaults.string(forKey: "testTicketNames") ?? "").split(separator: ",").map(String.init)
            var targets: [WorkspaceTarget] = []
            for (index, ticket) in tickets.enumerated() {
                do {
                    let name = names.indices.contains(index) ? names[index] : nil
                    targets.append(.host(try await hosts.pair(try PairingTicket(ticket), name: name)))
                } catch {
                    lastError = "pairing failed: \(error.localizedDescription)"
                    Self.log.error("test pairing failed: \(String(describing: error), privacy: .public)")
                }
            }
            return targets
        }
        return await runSingleLaunchHook().map { [$0] } ?? []
    }

    @ObservationIgnored private var launchHooksRan = false

    private func runSingleLaunchHook() async -> WorkspaceTarget? {
        let defaults = UserDefaults.standard
        if let ticket = defaults.string(forKey: "testTicket"), !ticket.isEmpty {
            do {
                return .host(try await hosts.pair(try PairingTicket(ticket)))
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
