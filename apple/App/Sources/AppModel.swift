import Foundation
import Observation
import os
import PaneLayout
import GudoCore

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
    /// When this process started: windows restored in its first seconds are the launch's.
    static let launchedAt = ContinuousClock.now
    static var isLaunching: Bool { ContinuousClock.now - launchedAt < .seconds(8) }

    let hosts: HostsModel
    /// Shown by the window when a pairing / connection started outside it fails (deep link).
    var lastError: String?
    /// This device's tabs (the Mac's shells; empty on iPhone and iPad unless a test or fixture
    /// asks for the echo stand-in), shared by every window like a host's layout. Empty at launch
    /// when This Mac's helper serves the Mac instead.
    let localLayout: LocalLayoutStore
    #if os(macOS)
    /// This Mac's own helper (nil for design fixtures and `-mock`).
    let localHelper: LocalHelper?
    #endif

    /// Saves daemon hosts' workspaces for instant start (nil for design fixtures and `-mock`).
    @ObservationIgnored private(set) var cacheWriter: WorkspaceCacheWriter?

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
        let defaults = LaunchArguments()
        // Tests and tooling keep hosts and secrets in a folder of their own (`AppData`): they
        // never touch the user's hosts or Keychain.
        let isolated = AppData.isolatedDirectory
        let repository = isolated.map { HostRepository(directory: $0) } ?? HostRepository.appDefault()
        let secrets: any SecretStore = isolated.map { FileSecretStore(directory: $0.appending(path: "secrets")) }
            ?? SecretStores.appDefault(
                service: (Bundle.main.bundleIdentifier ?? "app") + ".secrets",
                fallbackDirectory: repository.directory.appending(path: "secrets"))
        var configuration = HostsModel.Configuration()
        if defaults.string(forKey: "testRelay") == "disabled" { configuration.relay = .disabled }
        configuration.mirrorVt = defaults.bool(forKey: "testMirror")
        // `-testLinkDelayMs 600`: a slow link to a local daemon (echo prediction tests).
        let linkDelay = defaults.integer(forKey: "testLinkDelayMs")
        if linkDelay > 0 { configuration.linkDelay = .milliseconds(linkDelay) }
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
        // Instant start: each daemon host opens on what this device saved of it.
        if !LaunchOptions.mock, LaunchOptions.screen == nil {
            hosts.workspaceCache = WorkspaceCacheStore.appDefault(isolated: isolated)
        }
        #if os(macOS)
        let helper = LaunchOptions.mock || LaunchOptions.screen != nil ? nil : LocalHelper.app(hosts: hosts)
        localHelper = helper
        let helperServesMac = helper?.isEnabled == true
        #else
        let helperServesMac = false
        #endif
        // No local shell on iOS (only the echo stand-in for tests): an empty session. Nor on a
        // Mac whose helper serves it (a plain shell comes back if the helper can't).
        localLayout = LaunchOptions.hasLocalShell && !helperServesMac
            ? LocalLayoutStore() : LocalLayoutStore(session: Session(tabs: [], activeTabId: nil))
        hosts.onBrowserPush = { [weak self] id, push in self?.browserPush(id, push) }
        hosts.onClipboard = { [weak self] id, pane, text in self?.clipboardWrite(id, pane, text) }
        #if os(macOS)
        helper?.onReady = { [weak self] id in self?.thisDeviceReady(id) }
        helper?.onUnavailable = { [weak self] in self?.thisDeviceUnavailable() }
        helper?.start()
        if let helper { connectEarly(helper) }
        #endif
        if let store = hosts.workspaceCache {
            let writer = WorkspaceCacheWriter(store: store, hosts: hosts) { [weak self] in self?.openWorkspaces ?? [] }
            writer.start()
            cacheWriter = writer
        }
        #if os(iOS) && FILES_PROVIDER_YES
        if isolated == nil { FilesLocations.start(hosts) }
        #endif
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
    var openWindows: [WindowModel] { windows.allObjects.filter { !$0.isClosed }.sorted { $0.serial < $1.serial } }

    /// The gzipped static Linux daemons bundled as resources (project.yml), for "Install helper".
    nonisolated static func bundledDaemons() -> HostdBinaries {
        func file(_ arch: String) -> HostdBinary? {
            let name = "\(Brand.daemonBinary)-\(arch)-linux"
            return Bundle.main.url(forResource: name, withExtension: "gz").map { .file(path: $0.path) }
        }
        return HostdBinaries(linuxAarch64: file("aarch64"), linuxX8664: file("x86_64"), macosAarch64: nil, macosX8664: nil)
    }

    // MARK: This Mac's helper

    #if os(macOS)
    /// Dials This Mac's helper before any window exists when it already runs (a login item)
    /// and is the one paired: the first frame then shows its saved workspace and the link is
    /// on its way. The helper's own start (login item checks, pairing) follows as before.
    private func connectEarly(_ helper: LocalHelper) {
        guard helper.isEnabled, let id = hosts.thisDeviceId,
              let endpoint = LocalHelper.runningEndpoint(in: helper.stateDirectory),
              hosts.record(id)?.daemonId == endpoint.daemonId
        else { return }
        do {
            try hosts.open(id)
            Self.log.info("this Mac's helper: dialing at launch, \(LaunchTimeline.sinceStart(), privacy: .public) after process start")
        } catch {
            Self.log.error("this Mac's helper: \(String(describing: error), privacy: .public)")
        }
    }

    /// Every window shows This Mac's helper in place of an empty local workspace.
    private func thisDeviceReady(_ id: String) {
        // Dialled early, maybe before the helper was up: retry now rather than after a backoff.
        if let connection = hosts.connection(id), case .reconnecting = connection.status { connection.retry() }
        for window in openWindows { window.openThisDevice(id) }
    }

    /// The helper stopped or could not start: This Mac falls back to a plain shell.
    private func thisDeviceUnavailable() {
        if localLayout.session.tabs.isEmpty { localLayout.apply(.newTab) }
        for window in openWindows where window.currentGroupId == hosts.thisDeviceId { window.show(.local) }
    }
    #endif

    /// The host of this device's helper while it serves This Mac.
    var thisDeviceHostId: String? {
        #if os(macOS)
        localHelper?.isActive == true ? hosts.thisDeviceId : nil
        #else
        nil
        #endif
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
        let defaults = LaunchArguments()
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

    /// `runLaunchHooks` still has a host to pair or connect (UI tests): the first window
    /// waits for it instead of restoring.
    var hasLaunchHooks: Bool {
        guard !launchHooksRan else { return false }
        let defaults = LaunchArguments()
        return ["testTickets", "testTicket", "testSSH"].contains { !(defaults.string(forKey: $0) ?? "").isEmpty }
    }

    private func runSingleLaunchHook() async -> WorkspaceTarget? {
        let defaults = LaunchArguments()
        // `-testSSHConfig <path>`: read that ssh_config as Hosts → Import would (UI tests; the
        // simulator's pasteboard and file picker cannot be driven reliably).
        if let path = defaults.string(forKey: "testSSHConfig"),
           let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) {
            try? hosts.loadSSHConfig(text)
        }
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

/// When a launch reached its milestones, logged (category `launch`) so a slow start can be
/// told apart: process start → first frame of a window → its host live (docs/PERFORMANCE.md
/// "Instant start").
@MainActor
enum LaunchTimeline {
    private static var firstFrameLogged = false
    private static var liveLogged = false
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "launch")

    /// When the kernel started this process.
    nonisolated static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    /// Milliseconds since the process started, as words for the log.
    nonisolated static func sinceStart(_ now: Date = .now) -> String {
        processStart.map { "\(Int(now.timeIntervalSince($0) * 1000)) ms" } ?? "?"
    }

    static func firstFrame(savedWorkspace: Bool) {
        guard !firstFrameLogged else { return }
        firstFrameLogged = true
        log.info("first frame \(sinceStart(), privacy: .public) after process start (saved workspace: \(savedWorkspace))")
    }

    static func live(_ host: String) {
        guard !liveLogged else { return }
        liveLogged = true
        log.info("live on \(host, privacy: .public) \(sinceStart(), privacy: .public) after process start")
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
