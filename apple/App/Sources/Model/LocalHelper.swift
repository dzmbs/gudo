#if os(macOS)
import Foundation
import HostKit
import Observation
import os
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
    @ObservationIgnored let hosts: HostsModel
    @ObservationIgnored let binary: URL?
    /// The helper's state folder (keys, paired devices, layout).
    @ObservationIgnored let stateDirectory: URL
    /// Test launches: a child in their own folder, never a login item, never on unless asked.
    @ObservationIgnored let isIsolated: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var child: Process?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The host became ready (each window opens it).
    @ObservationIgnored var onReady: ((String) -> Void)?
    /// The helper stopped or failed to start.
    @ObservationIgnored var onUnavailable: (() -> Void)?

    static let enabledKey = "localHelper"
    static let keepsRunningKey = "localHelperKeepsRunning"
    private static let binaryStampKey = "localHelperBinaryStamp"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "helper")

    init(hosts: HostsModel, binary: URL?, stateDirectory: URL, isIsolated: Bool, defaults: UserDefaults = .standard) {
        self.hosts = hosts
        self.binary = binary
        self.stateDirectory = stateDirectory
        self.isIsolated = isIsolated
        self.defaults = defaults
    }

    /// The app's helper: the bundled build in the daemon's default folder (where the `un` CLI
    /// and agent hooks look), or a test folder.
    static func app(hosts: HostsModel) -> LocalHelper {
        let binary = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(Brand.name)-hostd")
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
            defer { task = nil }
            do {
                let id = try await run()
                state = .running
                onReady?(id)
            } catch {
                if Task.isCancelled { return }
                Self.log.error("helper: \(String(describing: error), privacy: .public)")
                state = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
                onUnavailable?()
            }
        }
    }

    /// Stops the helper (its sessions end) and leaves it off until started again.
    func stop() {
        defaults.set(false, forKey: Self.enabledKey)
        task?.cancel()
        if let id = hosts.thisDeviceId { hosts.disconnect(id) }
        if !isIsolated { try? agent.unregister() }
        child?.terminate()
        child = nil
        state = .off
        onUnavailable?()
    }

    /// Turns the helper back on.
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
        child?.terminate()
    }

    private func run() async throws -> String {
        guard let binary else { throw HelperError.notBundled }
        if Self.runningEndpoint(in: stateDirectory) == nil {
            try launch(binary)
        } else {
            restartIfUpdated(binary)
        }
        let endpoint = try await waitForEndpoint()
        if let id = hosts.thisDeviceId, hosts.record(id)?.daemonId == endpoint.daemonId { return id }
        let ticket = try await Self.mintTicket(binary: binary, stateDirectory: stateDirectory)
        return try await hosts.pairThisDevice(try PairingTicket(ticket), name: WindowModel.deviceName)
    }

    private func launch(_ binary: URL) throws {
        if keepsRunning {
            do {
                if agent.status != .enabled { try agent.register() }
                if agent.status == .enabled {
                    noteBinary(binary)
                    return
                }
                Self.log.info("login item status \(String(describing: self.agent.status), privacy: .public): running as a child")
                // Not left behind to start later and find the folder taken.
                try? agent.unregister()
            } catch {
                Self.log.error("login item: \(String(describing: error), privacy: .public): running as a child")
            }
        }
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--state-dir", stateDirectory.path, "run"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        child = process
    }

    /// A login item started by an older app build still runs the old helper: restart it.
    private func restartIfUpdated(_ binary: URL) {
        guard keepsRunning, agent.status == .enabled else { return }
        let stamp = Self.stamp(binary)
        guard defaults.string(forKey: Self.binaryStampKey) != stamp else { return }
        Self.log.info("helper build changed: restarting the login item")
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kick.arguments = ["kickstart", "-k", "gui/\(getuid())/\(Self.label)"]
        try? kick.run()
        kick.waitUntilExit()
        noteBinary(binary)
    }

    private func noteBinary(_ binary: URL) {
        defaults.set(Self.stamp(binary), forKey: Self.binaryStampKey)
    }

    private static func stamp(_ binary: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: binary.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int(modified))"
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

    private func waitForEndpoint(timeout: Duration = .seconds(30)) async throws -> Endpoint {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let endpoint = Self.runningEndpoint(in: stateDirectory) { return endpoint }
            if let child, !child.isRunning { throw HelperError.exited(child.terminationStatus) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HelperError.didNotStart
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

nonisolated enum HelperError: Error, Equatable, LocalizedError {
    case notBundled
    case didNotStart
    case exited(Int32)
    case noTicket

    var errorDescription: String? {
        switch self {
        case .notBundled: "This build doesn't include the helper."
        case .didNotStart: "The helper didn't start."
        case .exited(let status): "The helper stopped (status \(status))."
        case .noTicket: "The helper didn't hand out a pairing ticket."
        }
    }
}
#endif
