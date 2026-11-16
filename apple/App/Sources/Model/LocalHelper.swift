#if os(macOS)
import Foundation
import HostKit
import Observation
import os
import Security
import ServiceManagement

/// This Mac's own helper: the daemon bundled in the app (`Contents/MacOS/<name>-hostd`), run for
/// this user and paired with the app as its owner, so This Mac has everything a remote host has:
/// files, changes, ports, the editor, agents, sharing. It runs as a login item (a LaunchAgent in
/// the bundle, `SMAppService`) so sessions outlive the app, or as the app's child when that is
/// turned off or not allowed. iPhone and iPad have no helper of their own.
@MainActor
@Observable
final class LocalHelper {
    enum State: Equatable {
        /// Turned off, or not part of this build.
        case off
        case starting
        case running
        case failed(String)
    }

    private(set) var state = State.off
    /// The login item waits for approval in System Settings ▸ General ▸ Login Items.
    private(set) var needsApproval = false
    @ObservationIgnored let hosts: HostsModel
    @ObservationIgnored let binary: URL?
    /// The helper's state folder (keys, paired devices, layout).
    @ObservationIgnored let stateDirectory: URL
    /// Test launches: a child in their own folder, never a login item, never on unless asked.
    @ObservationIgnored let isIsolated: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var child: Process?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// When this app last started the helper (a dial from before then found nothing to reach).
    @ObservationIgnored private(set) var startedAt: ContinuousClock.Instant?
    @ObservationIgnored private var pairsAgainAfterTask = false
    @ObservationIgnored private var isPairingAgain = false
    @ObservationIgnored private var pairingAgainFailed: ContinuousClock.Instant?
    @ObservationIgnored private var exitWatch: DispatchSourceProcess?
    @ObservationIgnored private var watchedSince: ContinuousClock.Instant?
    @ObservationIgnored private var respawn = HelperRespawn()
    @ObservationIgnored private var respawnTask: Task<Void, Never>?
    /// A daemon the user runs on the folder serves This Mac: they (or launchd) start it again.
    @ObservationIgnored private var servesForeign = false
    /// The host became ready (each window opens it).
    @ObservationIgnored var onReady: ((String) -> Void)?
    /// The helper stopped or failed to start.
    @ObservationIgnored var onUnavailable: (() -> Void)?

    static let enabledKey = "localHelper"
    static let keepsRunningKey = "localHelperKeepsRunning"
    private static let registeredKey = "localHelperRegistered"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "helper")

    init(hosts: HostsModel, binary: URL?, stateDirectory: URL, isIsolated: Bool, defaults: UserDefaults = .standard) {
        self.hosts = hosts
        self.binary = binary
        self.stateDirectory = stateDirectory
        self.isIsolated = isIsolated
        self.defaults = defaults
        hosts.thisDeviceEndpointFile = stateDirectory.appending(path: "endpoint.json")
    }

    /// The app's helper: the bundled build in the daemon's default folder (where the `gudo` CLI
    /// and agent hooks look), or a test folder.
    static func app(hosts: HostsModel) -> LocalHelper {
        let binary = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(Brand.daemonBinary)")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let state = AppData.isolatedDirectory.map { $0.appending(path: "helper", directoryHint: .isDirectory) }
            ?? home.appending(path: "Library/Application Support/\(Brand.name)", directoryHint: .isDirectory)
        return LocalHelper(
            hosts: hosts, binary: FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil,
            stateDirectory: state, isIsolated: AppData.isIsolated)
    }

    /// On unless turned off (Settings ▸ This Mac); test launches only with `-localHelper YES`.
    var isEnabled: Bool {
        guard binary != nil else { return false }
        return flag(Self.enabledKey) ?? !isIsolated
    }

    /// Sessions keep running after the app quits (a login item). On by default.
    var keepsRunning: Bool {
        !isIsolated && (flag(Self.keepsRunningKey) ?? true)
    }

    /// A saved switch, or a launch argument (`-localHelper YES`); nil when unset.
    private func flag(_ key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    /// Whether This Mac is served by the helper: its plain local shells give way to it.
    var isActive: Bool { isEnabled && state != .off && !isFailed }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    // MARK: Starting and stopping

    /// Starts the helper if needed and pairs with it once.
    func start() {
        guard isEnabled, task == nil else { return }
        guard state != .running || hosts.thisDeviceId == nil else { return }
        state = .starting
        task = Task {
            defer { finishTask() }
            do {
                let id = try await run()
                state = .running
                watchExit()
                onReady?(id)
            } catch {
                if Task.isCancelled { return }
                Self.log.error("helper: \(String(describing: error), privacy: .public)")
                state = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
                onUnavailable?()
            }
        }
    }

    /// The helper no longer knows this app's device (removed from its devices, or the pairing
    /// was lost): pairs again with a fresh ticket from the helper, without asking. Anyone who
    /// can run the helper on its folder can mint one, as this user on this Mac can. False when
    /// it won't (turned off, or it just failed): the host then asks the user.
    @discardableResult
    func pairAgain() -> Bool {
        // A refusal of the pairing itself must not start another.
        guard isEnabled, !isPairingAgain, let binary else { return false }
        if let failed = pairingAgainFailed, ContinuousClock.now - failed < .seconds(10) { return false }
        guard task == nil else {
            pairsAgainAfterTask = true
            return true
        }
        Self.log.info("helper: this Mac's device was removed; pairing again")
        isPairingAgain = true
        task = Task {
            defer {
                isPairingAgain = false
                finishTask()
            }
            do {
                let ticket = try await Self.mintTicket(binary: binary, stateDirectory: stateDirectory)
                let id = try await hosts.pairThisDevice(try PairingTicket(ticket), name: WindowModel.deviceName)
                pairingAgainFailed = nil
                state = .running
                watchExit()
                onReady?(id)
            } catch {
                Self.log.error("helper: pairing again failed: \(String(describing: error), privacy: .public)")
                pairingAgainFailed = .now
                showRefusal()
            }
        }
        return true
    }

    private func finishTask() {
        task = nil
        guard pairsAgainAfterTask else { return }
        pairsAgainAfterTask = false
        guard let id = hosts.thisDeviceId, let connection = hosts.connection(id) as? DaemonConnection,
              connection.refusal.map(DaemonConnection.meansDeviceRemoved) == true
        else { return }
        if !pairAgain() { showRefusal() }
    }

    /// A connection left waiting for a pairing that did not happen dials again, and this time
    /// shows the refusal.
    private func showRefusal() {
        guard let id = hosts.thisDeviceId, let connection = hosts.connection(id), connection.status.isConnecting else { return }
        connection.retry()
    }

    /// Stops the helper (its sessions end) and leaves it off until started again.
    func stop() {
        defaults.set(false, forKey: Self.enabledKey)
        task?.cancel()
        stopWatchingExit()
        if let id = hosts.thisDeviceId { hosts.disconnect(id) }
        if !isIsolated { try? agent.unregister() }
        child?.terminate()
        child = nil
        state = .off
        onUnavailable?()
    }

    func enable() {
        defaults.set(true, forKey: Self.enabledKey)
        start()
    }

    /// Switches between a login item and a child of the app. The running sessions end.
    func setKeepsRunning(_ keep: Bool) {
        defaults.set(keep, forKey: Self.keepsRunningKey)
        guard isEnabled else { return }
        task?.cancel()
        task = nil
        stopWatchingExit()
        if !keep { try? agent.unregister() }
        child?.terminate()
        child = nil
        state = .starting
        Task {
            // The old process lets go of the state folder before the new one takes it.
            let deadline = ContinuousClock.now + .seconds(5)
            while Self.runningEndpoint(in: stateDirectory) != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            start()
        }
    }

    /// The app is quitting: a child helper goes with it (a login item stays).
    func appWillTerminate() {
        stopWatchingExit()
        child?.terminate()
    }

    // MARK: When the helper ends on its own

    /// Notices the helper ending while it serves This Mac (killed, crashed, or stopped from a
    /// terminal), whoever started it: the app, launchd or the user.
    private func watchExit() {
        stopWatchingExit()
        guard let endpoint = Self.runningEndpoint(in: stateDirectory) else { return }
        let pid = endpoint.pid
        let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.helperExited(pid: pid) }
        }
        source.resume()
        exitWatch = source
        watchedSince = .now
        // A process that ended before the watch began never reports it.
        if kill(pid, 0) != 0 { helperExited(pid: pid) }
    }

    private func stopWatchingExit() {
        exitWatch?.cancel()
        exitWatch = nil
        respawnTask?.cancel()
        respawnTask = nil
    }

    /// Starts the helper once more after a pause, so This Mac reconnects to it by itself. Its
    /// layout and saved screens bring the sessions back.
    private func helperExited(pid: Int32) {
        exitWatch?.cancel()
        exitWatch = nil
        guard isEnabled, state == .running, task == nil, respawnTask == nil else { return }
        // Its link looks up until the idle timeout; dialling now shows "Connecting" at once
        // and reaches the helper as soon as one listens again.
        if let id = hosts.thisDeviceId { hosts.connection(id)?.retry() }
        guard !servesForeign else { return }
        if child?.processIdentifier == pid { child = nil }
        let ranFor = watchedSince.map { ContinuousClock.now - $0 } ?? .zero
        guard let delay = respawn.delay(afterRunning: ranFor, jitter: .random(in: 0..<1)) else {
            Self.log.error("helper: pid \(pid) ended right after starting again; leaving it stopped")
            state = .failed(HelperError.keepsStopping.errorDescription ?? "")
            onUnavailable?()
            return
        }
        Self.log.info("helper: pid \(pid) ended; starting it again in \(delay, privacy: .public)")
        state = .starting
        respawnTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            respawnTask = nil
            start()
        }
    }

    private func run() async throws -> String {
        guard let binary else { throw HelperError.notBundled }
        if !isIsolated && !Brand.isDev { await retireLegacyHelper() }
        var launched = true
        servesForeign = false
        let running = Self.runningEndpoint(in: stateDirectory)
        let loginItemEnabled = !isIsolated && agent.status == .enabled
        let plan = Self.plan(
            running: running, isAppHelper: running.map { Self.isAppHelper(pid: $0.pid) } ?? false,
            keepsRunning: keepsRunning, loginItemEnabled: loginItemEnabled, registeredIsCurrent: isRegistered(binary))
        switch plan {
        case .useForeign:
            launched = false
            servesForeign = true
            // A daemon the user runs on this folder (`service install`, `run`) serves This Mac.
            // The app's login item could only fail to take the folder, again and again.
            if loginItemEnabled {
                try? await agent.unregister()
                defaults.removeObject(forKey: Self.registeredKey)
            }
            Self.log.info("helper: using the daemon already running on the folder (pid \(running?.pid ?? 0))")
        case .launch:
            try await launch(binary)
        case .restartInPlace(let replaceIfRefused):
            if await Self.restartInPlace(binary: binary, stateDirectory: stateDirectory) {
                // The running helper now runs the build in the app (same process, so launchd
                // keeps it), its sessions still running; or it already did. The login item is
                // registered again the next time the helper is not running (`startLoginItem`).
                launched = false
            } else if replaceIfRefused {
                // A helper that cannot restart in place is replaced, never restarted, because
                // launchd only spawns the exact build that was registered. Its agents resume
                // their sessions in the new helper.
                try await stopLoginItem()
                try await launch(binary)
            } else {
                launched = false
            }
        }
        let endpoint = try await waitForEndpoint()
        if launched { startedAt = .now }
        if let id = hosts.thisDeviceId, hosts.record(id)?.daemonId == endpoint.daemonId { return id }
        let ticket = try await Self.mintTicket(binary: binary, stateDirectory: stateDirectory)
        return try await hosts.pairThisDevice(try PairingTicket(ticket), name: WindowModel.deviceName)
    }

    /// How starting goes, given what runs on the state folder.
    nonisolated enum StartPlan: Equatable {
        /// Nothing runs there: start the helper.
        case launch
        /// A daemon the user runs on the folder serves This Mac.
        case useForeign
        /// The app's helper runs: it restarts into the build in the app, keeping its sessions,
        /// when that build changed (an update replaced the app). One that cannot is replaced
        /// when `replaceIfRefused`, else left running.
        case restartInPlace(replaceIfRefused: Bool)
    }

    nonisolated static func plan(
        running: Endpoint?, isAppHelper: Bool, keepsRunning: Bool, loginItemEnabled: Bool, registeredIsCurrent: Bool
    ) -> StartPlan {
        guard running != nil else { return .launch }
        guard isAppHelper else { return .useForeign }
        return .restartInPlace(replaceIfRefused: keepsRunning && loginItemEnabled && !registeredIsCurrent)
    }

    /// Stops the helper of a build from before the product's rename and keeps its login items
    /// from starting again, so this build's helper can take over its state folder (keys, paired
    /// devices, grants, layout), which the helper moves into its own when it starts.
    private func retireLegacyHelper() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy = home.appending(path: "Library/Application Support/\(Brand.Legacy.name)", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: legacy.appending(path: "daemon.key").path) else { return }
        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        // The old app's login item, and a helper installed with `service install`.
        for label in ["\(Brand.Legacy.bundleIdPrefix).app.hostd", "\(Brand.Legacy.bundleIdPrefix).hostd"] {
            let target = "gui/\(getuid())/\(label)"
            _ = try? await Self.output(launchctl, ["bootout", target])
            _ = try? await Self.output(launchctl, ["disable", target])
        }
        if let old = Self.runningEndpoint(in: legacy) { kill(old.pid, SIGTERM) }
        let deadline = ContinuousClock.now + .seconds(5)
        while Self.runningEndpoint(in: legacy) != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        Self.log.info("helper: retired the helper from before the rename")
    }

    private func launch(_ binary: URL) async throws {
        if keepsRunning, await startLoginItem(binary) { return }
        try startChild(binary)
    }

    /// Registers the login item (again when the build changed) and waits for it to come up.
    /// False when it isn't allowed or doesn't start: the caller runs the helper as a child.
    private func startLoginItem(_ binary: URL) async -> Bool {
        do {
            if agent.status == .enabled, !isRegistered(binary) { try await stopLoginItem() }
            if agent.status != .enabled { try agent.register() }
        } catch {
            Self.log.error("login item: \(String(describing: error), privacy: .public)")
        }
        needsApproval = agent.status == .requiresApproval
        guard agent.status == .enabled else {
            Self.log.info("login item status \(String(describing: self.agent.status), privacy: .public): running as a child")
            // Not left behind to start later and find the folder taken.
            try? await agent.unregister()
            return false
        }
        noteRegistered(binary)
        // launchd starts it again after a crash, never after it stopped cleanly (`SIGTERM`). A
        // login item can also read as enabled while launchd has no job for it (a moved or
        // re-signed build), and then nothing would ever start it.
        if Self.runningEndpoint(in: stateDirectory) == nil {
            let target = "gui/\(getuid())/\(Self.label)"
            let loaded = await Self.kickstartWhenLoaded(within: .milliseconds(1500)) {
                (try? await Self.output(URL(fileURLWithPath: "/bin/launchctl"), ["kickstart", target])) != nil
            }
            if !loaded, Self.runningEndpoint(in: stateDirectory) == nil {
                Self.log.error("login item enabled but launchd has no job for it: running as a child")
                try? await stopLoginItem()
                return false
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if Self.runningEndpoint(in: stateDirectory) != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Self.log.error("login item registered but not running: running as a child")
        try? await stopLoginItem()
        return false
    }

    /// Asks launchd to start the job until it knows it (a just-registered job loads a moment
    /// later), or `within` passes.
    static func kickstartWhenLoaded(within limit: Duration, kickstart: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while true {
            if await kickstart() { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Unregisters the login item and waits for its helper to let go of the state folder.
    private func stopLoginItem() async throws {
        try await agent.unregister()
        defaults.removeObject(forKey: Self.registeredKey)
        let deadline = ContinuousClock.now + .seconds(5)
        while Self.runningEndpoint(in: stateDirectory) != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func startChild(_ binary: URL) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--state-dir", stateDirectory.path, "run"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        child = process
    }

    /// Whether the registered login item is this exact build: launchd pins the registered
    /// app's code and won't spawn a rebuilt helper under the old registration.
    private func isRegistered(_ binary: URL) -> Bool {
        defaults.string(forKey: Self.registeredKey) == Self.identity(binary)
    }

    private func noteRegistered(_ binary: URL) {
        defaults.set(Self.identity(binary), forKey: Self.registeredKey)
    }

    /// The helper's location and code hash.
    nonisolated static func identity(_ binary: URL) -> String {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return binary.path }
        return binary.path + "#" + hash.map { String(format: "%02x", $0) }.joined()
    }

    private static var label: String { (Bundle.main.bundleIdentifier ?? "app") + ".hostd" }
    private var agent: SMAppService { .agent(plistName: Self.label + ".plist") }

    // MARK: The helper's state folder

    /// What a running helper recorded about itself.
    nonisolated struct Endpoint: Equatable, Decodable {
        var daemonId: String
        var pid: Int32

        enum CodingKeys: String, CodingKey {
            case daemonId = "daemon_id"
            case pid
        }
    }

    /// The helper running on `directory`, if its process is alive.
    nonisolated static func runningEndpoint(in directory: URL) -> Endpoint? {
        guard let data = try? Data(contentsOf: directory.appending(path: "endpoint.json")),
              let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data),
              endpoint.pid > 0, kill(endpoint.pid, 0) == 0
        else { return nil }
        return endpoint
    }

    /// Whether `pid` runs a helper bundled in an app (this one or another build), not a daemon
    /// the user installed or started from a terminal.
    nonisolated static func isAppHelper(pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return true }
        return String(cString: buffer).contains(".app/Contents/")
    }

    private func waitForEndpoint(timeout: Duration = .seconds(30)) async throws -> Endpoint {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let endpoint = Self.runningEndpoint(in: stateDirectory) { return endpoint }
            if let child, !child.isRunning { throw HelperError.exited(child.terminationStatus) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HelperError.didNotStart
    }

    /// Asks the running helper to hand its sessions to the build now in the app and become it
    /// (`restart`): false when it cannot (a build from before this, or the new build cannot
    /// take the sessions over), which leaves it running as it was.
    static func restartInPlace(binary: URL, stateDirectory: URL) async -> Bool {
        do {
            let output = try await Self.output(binary, ["--state-dir", stateDirectory.path, "restart"])
            let said = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            Self.log.info("helper: \(said, privacy: .public)")
            return true
        } catch {
            Self.log.info("helper: no restart in place (\(String(describing: error), privacy: .public))")
            return false
        }
    }

    /// A one-time ticket from the helper itself, with loopback addresses (works offline).
    nonisolated static func mintTicket(binary: URL, stateDirectory: URL) async throws -> String {
        let output = try await Self.output(binary, ["--state-dir", stateDirectory.path, "pair", "--json", "--local", "--minutes", "5"])
        guard let object = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              let ticket = object["ticket"] as? String
        else { throw HelperError.noTicket }
        return ticket
    }

    private nonisolated static func output(_ binary: URL, _ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = binary
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: HelperError.exited(process.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// When a helper that ended on its own starts again: soon after a long run, then further
/// apart (with jitter) while it keeps ending right after it starts, and not again after
/// `maxQuickEnds` of those in a row.
nonisolated struct HelperRespawn: Equatable {
    /// launchd starts a crashed login item at once; waiting a little first lets the app find
    /// that one rather than race it for the state folder.
    static let firstDelay = Duration.milliseconds(500)
    static let maxDelay = Duration.seconds(30)
    static let stableAfter = Duration.seconds(30)
    static let maxQuickEnds = 5
    private(set) var endsInARow = 0

    /// The pause before starting again, or nil to leave it stopped. `jitter` in 0..<1 adds up
    /// to half the pause again.
    mutating func delay(afterRunning ranFor: Duration, jitter: Double) -> Duration? {
        if ranFor >= Self.stableAfter { endsInARow = 0 }
        endsInARow += 1
        guard endsInARow <= Self.maxQuickEnds else { return nil }
        let base = min(Self.firstDelay * (1 << (endsInARow - 1)), Self.maxDelay)
        return base + base * (min(max(jitter, 0), 1) / 2)
    }
}

nonisolated enum HelperError: Error, Equatable, LocalizedError {
    case notBundled
    case didNotStart
    case exited(Int32)
    case noTicket
    case keepsStopping

    var errorDescription: String? {
        switch self {
        case .notBundled: "This build doesn't include the helper."
        case .didNotStart: "The helper didn't start."
        case .exited(let status): "The helper stopped (status \(status))."
        case .noTicket: "The helper didn't hand out a pairing ticket."
        case .keepsStopping: "The helper keeps stopping right after it starts."
        }
    }
}
#endif
