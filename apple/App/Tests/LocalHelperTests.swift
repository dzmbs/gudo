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

    func testALoginItemLaunchdHasNoJobForGivesUpAtOnce() async {
        let started = ContinuousClock.now
        let loaded = await LocalHelper.kickstartWhenLoaded(within: .seconds(1)) { false }
        XCTAssertFalse(loaded, "nothing would start it: the app runs the helper as a child")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
    }

    func testALoginItemThatLoadsAMomentLaterIsStarted() async {
        var attempts = 0
        let loaded = await LocalHelper.kickstartWhenLoaded(within: .seconds(2)) {
            attempts += 1
            return attempts >= 3
        }
        XCTAssertTrue(loaded)
        XCTAssertEqual(attempts, 3)
    }

    func testAHelperThatEndsStartsAgainOnceAfterAPause() {
        var respawn = HelperRespawn()
        XCTAssertEqual(respawn.delay(afterRunning: .seconds(3600), jitter: 0), .milliseconds(500))
        XCTAssertEqual(respawn.delay(afterRunning: .seconds(3600), jitter: 0), .milliseconds(500),
                       "a helper that ran a while is started again soon, every time")
    }

    func testAHelperThatKeepsEndingIsStartedFurtherApartThenLeftStopped() {
        var respawn = HelperRespawn()
        var delays: [Duration] = []
        while let delay = respawn.delay(afterRunning: .seconds(1), jitter: 0) { delays.append(delay) }
        XCTAssertEqual(delays, [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)])
        XCTAssertNil(respawn.delay(afterRunning: .seconds(1), jitter: 0))
        XCTAssertEqual(respawn.delay(afterRunning: .seconds(60), jitter: 0), .milliseconds(500),
                       "a run that lasted counts as recovered")
    }

    func testJitterSpreadsTheRestartUpToHalfAgain() throws {
        var low = HelperRespawn()
        var high = HelperRespawn()
        XCTAssertEqual(low.delay(afterRunning: .seconds(60), jitter: 0), .milliseconds(500))
        let spread = try XCTUnwrap(high.delay(afterRunning: .seconds(60), jitter: 0.999))
        XCTAssertGreaterThan(spread, .milliseconds(745))
        XCTAssertLessThan(spread, .milliseconds(750))
    }

    /// A key left in the folder from before the rename stays once this build's folder has its
    /// own: each launch must not stop login items and wait for a helper that is long gone.
    func testTheHelperFromBeforeTheRenameIsRetiredOnlyWhileItMatters() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let legacy = folder.appending(path: "legacy", directoryHint: .isDirectory)
        let current = folder.appending(path: "current", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertFalse(LocalHelper.legacyHelperNeedsRetiring(legacy: legacy, current: current), "nothing from before")
        try Data("key".utf8).write(to: legacy.appending(path: "daemon.key"))
        XCTAssertTrue(LocalHelper.legacyHelperNeedsRetiring(legacy: legacy, current: current), "not moved over yet")
        try Data("key".utf8).write(to: current.appending(path: "daemon.key"))
        XCTAssertFalse(LocalHelper.legacyHelperNeedsRetiring(legacy: legacy, current: current), "moved over, nothing runs")
        let endpoint = #"{"daemon_id":"old","pid":\#(getpid())}"#
        try Data(endpoint.utf8).write(to: legacy.appending(path: "endpoint.json"))
        XCTAssertTrue(LocalHelper.legacyHelperNeedsRetiring(legacy: legacy, current: current), "the old helper still runs")
    }

    func testEachStepOfAStartIsTimed() {
        var timeline = LocalHelper.StartTimeline()
        timeline.mark("plan launch")
        timeline.mark("helper listening")
        XCTAssertEqual(timeline.steps.map(\.name), ["plan launch", "helper listening"])
        XCTAssertTrue(timeline.steps.allSatisfy { $0.took >= .zero })
    }
}
#endif
