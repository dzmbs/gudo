#if os(macOS)
import HostKit
import XCTest
@testable import App

/// How the app starts This Mac's helper, above all after an update while the helper kept
/// running (it restarts into the new build and keeps its sessions), and how it moves on from the
/// login item earlier versions registered.
@MainActor
final class LocalHelperTests: XCTestCase {
    func testNothingRunningStartsTheInstalledHelper() {
        XCTAssertEqual(LocalHelper.plan(running: nil, loginItem: .none, registeredIsCurrent: false), .launch(retiresLoginItem: false))
        XCTAssertEqual(
            LocalHelper.plan(running: nil, loginItem: .enabled, registeredIsCurrent: true), .launch(retiresLoginItem: true),
            "an earlier version's login item goes once nothing it runs would end")
        XCTAssertEqual(LocalHelper.plan(running: nil, loginItem: .disabled, registeredIsCurrent: false), .launch(retiresLoginItem: true))
    }

    func testADaemonTheUserRunsServesThisMac() {
        XCTAssertEqual(LocalHelper.plan(running: .foreign, loginItem: .none, registeredIsCurrent: false), .useForeign(retiresLoginItem: false))
        XCTAssertEqual(LocalHelper.plan(running: .foreign, loginItem: .enabled, registeredIsCurrent: false), .useForeign(retiresLoginItem: true))
    }

    func testTheInstalledHelperRestartsIntoTheNewBuildInPlace() {
        XCTAssertEqual(
            LocalHelper.plan(running: .installed, loginItem: .none, registeredIsCurrent: false), .restartInPlace(retiresLoginItem: false))
        XCTAssertEqual(
            LocalHelper.plan(running: .installed, loginItem: .enabled, registeredIsCurrent: false), .restartInPlace(retiresLoginItem: true),
            "a login item left over runs nothing while the installed build holds the folder")
    }

    func testAnEarlierLoginItemsHelperKeepsItsSessions() {
        XCTAssertEqual(
            LocalHelper.plan(running: .bundled, loginItem: .enabled, registeredIsCurrent: true),
            .keepBundled(stopsLoginStart: true, replaceIfRefused: false),
            "kept, and kept from starting at the next login")
        XCTAssertEqual(
            LocalHelper.plan(running: .bundled, loginItem: .enabled, registeredIsCurrent: false),
            .keepBundled(stopsLoginStart: true, replaceIfRefused: true),
            "a helper from before hand-offs is replaced; its agents resume")
        for loginItem in [LocalHelper.LoginItem.disabled, .none] {
            XCTAssertEqual(
                LocalHelper.plan(running: .bundled, loginItem: loginItem, registeredIsCurrent: false),
                .keepBundled(stopsLoginStart: false, replaceIfRefused: false),
                "switched off already, or an earlier version's child: never replaced from here")
        }
    }

    func testWhatRunsIsToldByWhereItRunsFrom() {
        let versions = URL(fileURLWithPath: "/Users/u/Library/Application Support/Gudo/Helper/Versions", isDirectory: true)
        XCTAssertEqual(LocalHelper.runningHelper(executable: versions.path + "/Current/gudo-hostd", versions: versions), .installed)
        XCTAssertEqual(LocalHelper.runningHelper(executable: "/Applications/Gudo.app/Contents/MacOS/gudo-hostd", versions: versions), .bundled)
        XCTAssertEqual(LocalHelper.runningHelper(executable: "/Users/u/.local/bin/gudo-hostd", versions: versions), .foreign)
        XCTAssertEqual(
            LocalHelper.runningHelper(executable: versions.path + "-old/Current/gudo-hostd", versions: versions), .foreign,
            "a folder next to it is not it")
    }

    func testStartingTheJobReadsWhetherItStartedOneAndTellsARefusal() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = folder.appending(path: "state", directoryHint: .isDirectory)
        let started = try await LocalHelper.startJob(
            executable: try Self.script(in: folder, #"echo '{"label":"x","started":true,"pid":7}'"#), stateDirectory: state)
        XCTAssertTrue(started)
        let found = try await LocalHelper.startJob(
            executable: try Self.script(in: folder, #"echo '{"label":"x","started":false,"pid":7}'"#), stateDirectory: state)
        XCTAssertFalse(found)
        do {
            _ = try await LocalHelper.startJob(executable: try Self.script(in: folder, "exit 3"), stateDirectory: state)
            XCTFail("a refusal throws")
        } catch {
            XCTAssertEqual(error as? HelperError, .launchdRefused, "the app then runs the helper as its child")
        }
        do {
            _ = try await LocalHelper.startJob(executable: try Self.script(in: folder, "exit 1"), stateDirectory: state)
            XCTFail("a failure throws")
        } catch {
            XCTAssertEqual(error as? HelperError, .exited(1))
        }
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func script(in folder: URL, _ body: String) throws -> URL {
        let script = folder.appending(path: "helper-\(UUID().uuidString.prefix(8))")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
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

    func testTheHelperStartsAtLoginUnlessTurnedOffOrInATestLaunch() throws {
        func helper(isIsolated: Bool, startsAtLogin: Bool?) throws -> LocalHelper {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "starts-at-login-\(UUID().uuidString)"))
            if let startsAtLogin { defaults.set(startsAtLogin, forKey: LocalHelper.startsAtLoginKey) }
            let state = FileManager.default.temporaryDirectory.appending(path: "sal-\(UUID().uuidString.prefix(8))")
            let hosts = HostsModel(
                secrets: MemorySecretStore(), repository: HostRepository(directory: state), configuration: .init())
            return LocalHelper(hosts: hosts, binary: nil, stateDirectory: state, isIsolated: isIsolated, defaults: defaults)
        }
        XCTAssertTrue(try helper(isIsolated: false, startsAtLogin: nil).startsAtLogin, "phones reach This Mac after a restart")
        XCTAssertFalse(try helper(isIsolated: false, startsAtLogin: false).startsAtLogin)
        XCTAssertFalse(try helper(isIsolated: true, startsAtLogin: nil).startsAtLogin)
    }
}
#endif
