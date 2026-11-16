#if os(macOS)
import HostKit
import XCTest
@testable import App

/// This Mac's helper as the app starts it when sessions outlive the app: installed out of the
/// bundle and run as a launchd job, found again after a crash, and gone after Stop Helper.
/// The job's label comes from the test's own state folder; it is removed however the test ends.
@MainActor
final class LocalHelperJobTests: XCTestCase {
    private var stateDirectory: URL?
    private var helper: LocalHelper?

    override func tearDown() async throws {
        helper?.stop()
        if let stateDirectory {
            let current = stateDirectory.appending(path: "Helper/Versions/Current/gudo-hostd")
            if FileManager.default.isExecutableFile(atPath: current.path) {
                await LocalHelper.stopJob(executable: current, stateDirectory: stateDirectory, uninstallsLoginService: false)
            }
            try? FileManager.default.removeItem(at: stateDirectory)
        }
    }

    func testTheHelperRunsAsAJobFromItsInstalledCopyAndOutlivesACrash() async throws {
        let binary = try Self.daemonBinary()
        let state = FileManager.default.temporaryDirectory
            .appending(path: "lj-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        stateDirectory = state
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "helper-job-\(UUID().uuidString)"))
        defaults.set(true, forKey: LocalHelper.enabledKey)
        defaults.set(true, forKey: LocalHelper.keepsRunningKey)
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
        XCTAssertEqual(LocalHelper.runningHelper(pid: first.pid, versions: helper.versionsDirectory), .installed)
        XCTAssertEqual(helper.installed?.lastPathComponent, binary.lastPathComponent)
        XCTAssertEqual(getppid(first.pid), 1, "launchd's, not the app's child")

        kill(first.pid, SIGKILL)

        try await until("a helper runs again and This Mac is live again") {
            guard let now = LocalHelper.runningEndpoint(in: state), now.pid != first.pid else { return false }
            return helper.state == .running && hosts.connection(ready[0])?.status.isLive == true
        }
        let second = try XCTUnwrap(LocalHelper.runningEndpoint(in: state))
        XCTAssertEqual(second.daemonId, first.daemonId, "the same helper, its keys and pairing kept")

        helper.stop()
        try await until("Stop Helper ends it") { LocalHelper.runningEndpoint(in: state) == nil }
    }

    private func until(_ what: String, timeout: Duration = .seconds(40), _ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The parent of `pid`, from the kernel's process table.
    private func getppid(_ pid: Int32) -> Int32 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return -1 }
        return Int32(info.pbi_ppid)
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
}
#endif
