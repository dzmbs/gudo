#if os(macOS)
import HostKit
import XCTest
@testable import App

/// This Mac's helper killed while the app runs: the app starts it again by itself, once, and
/// This Mac's connection goes live again.
@MainActor
final class LocalHelperRespawnTests: XCTestCase {
    private var stateDirectory: URL?
    private var helper: LocalHelper?

    override func tearDown() async throws {
        helper?.stop()
        if let stateDirectory {
            let deadline = ContinuousClock.now + .seconds(5)
            while LocalHelper.runningEndpoint(in: stateDirectory) != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try? FileManager.default.removeItem(at: stateDirectory)
        }
    }

    func testAKilledHelperIsStartedAgainAndThisMacReconnects() async throws {
        let binary = try Self.daemonBinary()
        // Short: the helper's sockets live in it.
        let state = FileManager.default.temporaryDirectory
            .appending(path: "lh-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        stateDirectory = state
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "helper-respawn-\(UUID().uuidString)"))
        defaults.set(true, forKey: LocalHelper.enabledKey)
        var configuration = HostsModel.Configuration()
        configuration.relay = .disabled
        let hosts = HostsModel(
            secrets: MemorySecretStore(),
            repository: HostRepository(directory: state.appending(path: "app", directoryHint: .isDirectory)),
            configuration: configuration)
        let helper = LocalHelper(hosts: hosts, binary: binary, stateDirectory: state, isIsolated: true, defaults: defaults)
        self.helper = helper
        var ready: [String] = []
        helper.onReady = { id in
            ready.append(id)
            _ = try? hosts.open(id)
        }

        helper.start()
        try await until("the helper runs and This Mac is live") {
            ready.count == 1 && hosts.connection(ready[0])?.status.isLive == true
        }
        let first = try XCTUnwrap(LocalHelper.runningEndpoint(in: state))

        kill(first.pid, SIGKILL)

        try await until("a new helper runs and This Mac is live again") {
            guard let now = LocalHelper.runningEndpoint(in: state), now.pid != first.pid else { return false }
            return helper.state == .running && hosts.connection(ready[0])?.status.isLive == true
        }
        let second = try XCTUnwrap(LocalHelper.runningEndpoint(in: state))
        XCTAssertEqual(second.daemonId, first.daemonId, "the same helper, its keys and pairing kept")
        XCTAssertEqual(ready, [ready[0], ready[0]], "started again once, as the same host")
        XCTAssertEqual(Self.helpers(on: state), [second.pid], "one helper on the folder")
    }

    private func until(_ what: String, timeout: Duration = .seconds(30), _ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The daemon build the tests run (`GUDO_HOSTD_BIN`, else the workspace's debug build).
    private static func daemonBinary() throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["GUDO_HOSTD_BIN"].map(URL.init(fileURLWithPath:))
            ?? repoRoot.appending(path: "target/debug/gudo-hostd")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "no daemon at \(binary.path): run `cargo build -p hostd` first")
        return binary
    }

    /// Processes running a daemon on `state`.
    private static func helpers(on state: URL) -> [Int32] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "--", "--state-dir \(state.path) run"]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
    }
}
#endif
