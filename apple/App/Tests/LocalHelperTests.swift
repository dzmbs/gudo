#if os(macOS)
import XCTest
@testable import App

/// How the app starts This Mac's helper, above all after an update replaced the app while the
/// helper kept running: it restarts into the new build and keeps its sessions.
@MainActor
final class LocalHelperTests: XCTestCase {
    private let running = LocalHelper.Endpoint(daemonId: "d", pid: 42)

    func testNothingRunningStartsTheHelper() {
        XCTAssertEqual(
            LocalHelper.plan(running: nil, isAppHelper: false, keepsRunning: true, loginItemEnabled: true, registeredIsCurrent: false),
            .launch)
    }

    func testADaemonTheUserRunsServesThisMac() {
        XCTAssertEqual(
            LocalHelper.plan(running: running, isAppHelper: false, keepsRunning: true, loginItemEnabled: true, registeredIsCurrent: false),
            .useForeign)
    }

    func testAnUpdatedAppRestartsItsHelperInPlace() {
        XCTAssertEqual(
            LocalHelper.plan(running: running, isAppHelper: true, keepsRunning: true, loginItemEnabled: true, registeredIsCurrent: false),
            .restartInPlace(replaceIfRefused: true),
            "a helper from before hand-offs is replaced; its agents resume")
    }

    func testTheHelperIsAskedEvenWhenTheLoginItemLooksCurrent() {
        // The login item can read as off or current after the app was replaced; the helper
        // itself knows whether the file it runs from changed.
        for (loginItemEnabled, registeredIsCurrent) in [(true, true), (false, false), (false, true)] {
            XCTAssertEqual(
                LocalHelper.plan(
                    running: running, isAppHelper: true, keepsRunning: true,
                    loginItemEnabled: loginItemEnabled, registeredIsCurrent: registeredIsCurrent),
                .restartInPlace(replaceIfRefused: false))
        }
        XCTAssertEqual(
            LocalHelper.plan(running: running, isAppHelper: true, keepsRunning: false, loginItemEnabled: true, registeredIsCurrent: false),
            .restartInPlace(replaceIfRefused: false),
            "a helper running as the app's child is never replaced from here")
    }

    func testRestartInPlaceRunsTheHelpersRestartCommand() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let arguments = folder.appending(path: "arguments")
        func helper(exiting status: Int) throws -> URL {
            let script = folder.appending(path: "helper-\(status)")
            try "#!/bin/sh\necho \"$@\" > '\(arguments.path)'\necho 'restarted into the installed build'\nexit \(status)\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return script
        }
        let state = folder.appending(path: "state", directoryHint: .isDirectory)

        let restarted = await LocalHelper.restartInPlace(binary: try helper(exiting: 0), stateDirectory: state)
        XCTAssertTrue(restarted)
        XCTAssertEqual(try String(contentsOf: arguments, encoding: .utf8), "--state-dir \(state.path) restart\n")

        let refused = await LocalHelper.restartInPlace(binary: try helper(exiting: 1), stateDirectory: state)
        XCTAssertFalse(refused, "a helper that cannot hand off (an older build) is not restarted")
    }
}
#endif
