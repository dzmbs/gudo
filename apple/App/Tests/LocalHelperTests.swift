#if os(macOS)
import HostKit
import XCTest
@testable import App

/// How the app starts This Mac's helper, above all after an update while the helper kept
/// running (it restarts into the new build and keeps its sessions), and how it moves on from the
/// login item earlier versions registered.
@MainActor
final class LocalHelperTests: XCTestCase {
    private typealias Running = LocalHelper.Running
    private static let app = HelperBuild(version: "0.1.7", build: "bbbbbbb", builtUnix: 200, protocolLevel: 1)

    func testNothingRunningStartsTheInstalledHelper() {
        XCTAssertEqual(LocalHelper.plan(running: nil, loginItem: .none), .launch(.leave))
        XCTAssertEqual(
            LocalHelper.plan(running: nil, loginItem: .enabled), .launch(.retire),
            "an earlier version's login item goes once nothing it runs would end")
        XCTAssertEqual(LocalHelper.plan(running: nil, loginItem: .disabled), .launch(.retire))
    }

    func testTheAppsBuildOrANewerOneIsKeptWhereverItRunsFrom() {
        for location in [LocalHelper.RunningHelper.installed, .bundled, .foreign] {
            for build in [BuildAge.same, .newer] {
                for atItsPath in [BuildAge.older, .same, .newer] {
                    let running = Running(location: location, build: build, buildAtItsPath: atItsPath)
                    guard case .keep = LocalHelper.plan(running: running, loginItem: .none) else {
                        return XCTFail("\(running) is kept, a newer dev build too")
                    }
                }
            }
        }
    }

    func testAnOlderBuildHandsOverWhereverItRunsFrom() {
        XCTAssertEqual(
            LocalHelper.plan(running: Running(location: .installed, build: .older, buildAtItsPath: .same), loginItem: .none),
            .restart(into: .itsOwnPath, .leave), "the app swapped a new build into Current")
        XCTAssertEqual(
            LocalHelper.plan(running: Running(location: .foreign, build: .older, buildAtItsPath: .older), loginItem: .none),
            .restart(into: .installed, .leave), "a login service that runs an older build from a build folder")
        XCTAssertEqual(
            LocalHelper.plan(running: Running(location: .bundled, build: .older, buildAtItsPath: .same), loginItem: .enabled),
            .restart(into: .itsOwnPath, .keepFromStartingAtLogin), "an earlier version's login item, its app replaced by this one")
        XCTAssertEqual(
            LocalHelper.plan(running: Running(location: .bundled, build: .older, buildAtItsPath: .older), loginItem: .none),
            .restart(into: .installed, .leave), "an older app's child")
        let unknown = BuildAge(nil, against: Self.app)
        XCTAssertEqual(
            LocalHelper.plan(running: Running(location: .foreign, build: unknown, buildAtItsPath: unknown), loginItem: .enabled),
            .restart(into: .installed, .retire), "a helper whose file was removed")
    }

    /// Released builds hand over hot only to the file at their own path.
    func testTheAppsBuildOrANewerOneAtItsOwnPathIsWhatItHandsOverTo() {
        XCTAssertEqual(
            LocalHelper.plan(running: Running(location: .foreign, build: .older, buildAtItsPath: .newer), loginItem: .none),
            .restart(into: .itsOwnPath, .leave), "a build folder rebuilt with a newer build")
    }

    /// launchd starts an earlier version's login item from its own app again, so restarting it
    /// cold would bring back the older build: it is retired before the installed build starts.
    func testAnOlderAppsLoginItemIsRetiredBeforeItsHelperIsReplaced() {
        for loginItem in [LocalHelper.LoginItem.enabled, .disabled] {
            XCTAssertEqual(
                LocalHelper.plan(running: Running(location: .bundled, build: .older, buildAtItsPath: .older), loginItem: loginItem),
                .replace)
        }
    }

    func testWhatARestartLeavesDecidesWhetherToAsk() {
        let endpoint = LocalHelper.Endpoint(daemonId: "d", pid: 10, startedAt: 100)
        XCTAssertEqual(LocalHelper.afterRestart(after: endpoint, build: .same), .updated, "handed over")
        XCTAssertEqual(LocalHelper.afterRestart(after: endpoint, build: .newer), .updated)
        XCTAssertEqual(
            LocalHelper.afterRestart(after: endpoint, build: .older), .ask,
            "refused, or could only restart cold: running commands are the user's to end")
        XCTAssertEqual(
            LocalHelper.afterRestart(after: .init(daemonId: "d", pid: 10, startedAt: 200), build: .older), .ask,
            "handed over in the same process to a build still older: its commands run on, so the user decides")
        XCTAssertEqual(LocalHelper.afterRestart(after: nil, build: nil), .replace, "stopped and not started again")
    }

    func testAnEarlierLoginItemGoesUnlessItsHelperIsTheOneRunning() {
        XCTAssertEqual(
            LocalHelper.plan(running: Running(location: .installed, build: .same, buildAtItsPath: .same), loginItem: .enabled),
            .keep(.retire), "a login item left over runs nothing while the installed build holds the folder")
        XCTAssertEqual(
            LocalHelper.plan(running: Running(location: .bundled, build: .same, buildAtItsPath: .same), loginItem: .enabled),
            .keep(.keepFromStartingAtLogin), "kept, and kept from starting at the next login")
        XCTAssertEqual(
            LocalHelper.plan(running: Running(location: .bundled, build: .same, buildAtItsPath: .same), loginItem: .disabled),
            .keep(.leave), "switched off already: its helper may be the one running")
    }

    func testBuildsAreOrderedByProtocolThenSourceTime() {
        let older = HelperBuild(version: "0.1.6", build: "aaaaaaa", builtUnix: 100, protocolLevel: 1)
        let newerDev = HelperBuild(version: "0.1.8", build: "ccccccc-dirty", builtUnix: 300, protocolLevel: 1)
        XCTAssertEqual(BuildAge(older, against: Self.app), .older)
        XCTAssertEqual(BuildAge(Self.app, against: Self.app), .same)
        XCTAssertEqual(BuildAge(newerDev, against: Self.app), .newer)
        XCTAssertEqual(BuildAge(HelperBuild(version: "0.2.0", build: "dev", builtUnix: 0, protocolLevel: 2), against: Self.app), .newer)
        XCTAssertEqual(BuildAge(nil, against: Self.app), .older, "a build that cannot be told")
    }

    func testBuildInfoFromEveryReleaseIsRead() throws {
        let json = #"{"version":"0.1.3","build":"0123456789abcdef","built_unix":1793721143,"protocol":1,"min_client_protocol":0,"os":"macos","arch":"aarch64"}"#
        let build = try XCTUnwrap(HelperBuild(json: Data(json.utf8)))
        XCTAssertEqual(build, HelperBuild(version: "0.1.3", build: "0123456789abcdef", builtUnix: 1793721143, protocolLevel: 1))
        XCTAssertEqual(build.summary, "0.1.3 (0123456)")
        XCTAssertEqual(HelperBuild.summary(version: "0.1.7", build: "dev"), "0.1.7 (dev)")
        XCTAssertNil(HelperBuild(json: Data(#"{"exe_sha256":"00"}"#.utf8)))
    }

    func testARunningHelperIsToldFromAFileThatReplacedItsOwn() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appending(path: "gudo-hostd")
        try FileManager.default.copyItem(at: try ThisMacHelperTests.daemonBinary(), to: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--state-dir", folder.appending(path: "state").path, "run"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }
        let realPath = try XCTUnwrap(realpath(executable.path, nil).map { String(cString: $0) })

        XCTAssertEqual(RunningExecutable.of(pid: process.processIdentifier), RunningExecutable(path: realPath, isOnDisk: true))
        let replacement = folder.appending(path: "next")
        try FileManager.default.copyItem(at: executable, to: replacement)
        _ = try FileManager.default.replaceItemAt(executable, withItemAt: replacement)
        XCTAssertEqual(
            RunningExecutable.of(pid: process.processIdentifier), RunningExecutable(path: realPath, isOnDisk: false),
            "another file at its path, which still tells where it runs from")
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
        XCTAssertEqual(try String(contentsOf: arguments, encoding: .utf8), "--state-dir \(state.path) restart --hot-only\n")

        let refused = await LocalHelper.restartInPlace(binary: try helper(exiting: 1), stateDirectory: state)
        XCTAssertFalse(refused, "a helper that cannot hand off (an older build) is not restarted, hot or cold")

        let installed = folder.appending(path: "Current/gudo-hostd")
        _ = await LocalHelper.restartInPlace(binary: try helper(exiting: 0), stateDirectory: state, into: installed)
        XCTAssertEqual(
            try String(contentsOf: arguments, encoding: .utf8), "--state-dir \(state.path) restart --hot-only --into \(installed.path)\n",
            "a helper at another path hands over to the installed build")
    }

    func testTheLoginServiceIsPointedAtTheInstalledBuildWithoutRestartingIt() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let arguments = folder.appending(path: "arguments")
        let state = folder.appending(path: "state", directoryHint: .isDirectory)
        let helper = try Self.script(in: folder, "echo \"$@\" > '\(arguments.path)'")

        let installed = await LocalHelper.installLoginService(helper, stateDirectory: state, startsNow: false)

        XCTAssertTrue(installed)
        XCTAssertEqual(try String(contentsOf: arguments, encoding: .utf8), "--state-dir \(state.path) service install --no-start\n")
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
