#if os(macOS)
import AppKit
import DesignSystem
import HostKit
import SwiftUI
import XCTest
@testable import App

/// This Mac's helper as the app runs it, on a temporary state folder and shown in a real
/// window: starting, killed, upgraded under its sessions, and the app quitting with sessions
/// kept or not. The helper's shell is zsh with a bare prompt.
@MainActor
final class ThisMacHelperTests: XCTestCase {
    private var stateDirectory: URL?
    private var zshDirectory: URL?
    private var helpers: [LocalHelper] = []
    private var window: HostWindow?
    private var ready: [String] = []
    private var savedEnvironment: [String: String?] = [:]

    override func setUp() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        // Short: the helper's sockets live in it.
        let state = FileManager.default.temporaryDirectory.appending(path: "tm-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        stateDirectory = state
        let zsh = FileManager.default.temporaryDirectory.appending(path: "tm-zsh-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: zsh, withIntermediateDirectories: true)
        try "PROMPT='%# '\nRPROMPT=''\nunset HISTFILE\n".write(to: zsh.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        zshDirectory = zsh
        // The helper is the app's child and takes the app's environment: its shells too.
        for (key, value) in ["SHELL": "/bin/zsh", "ZDOTDIR": zsh.path] {
            savedEnvironment[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        for helper in helpers.reversed() { helper.stop() }
        AppModel.shared.serveThisMac(with: nil)
        let hosts = AppModel.shared.hosts
        if let id = hosts.thisDeviceId { hosts.remove(id) }
        hosts.thisDeviceEndpointFile = nil
        if let stateDirectory {
            let current = stateDirectory.appending(path: "Helper/Versions/Current/gudo-hostd")
            if FileManager.default.isExecutableFile(atPath: current.path) {
                await LocalHelper.stopJob(executable: current, stateDirectory: stateDirectory, uninstallsLoginService: false)
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while LocalHelper.runningEndpoint(in: stateDirectory) != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if let running = LocalHelper.runningEndpoint(in: stateDirectory) { kill(running.pid, SIGKILL) }
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        if let zshDirectory { try? FileManager.default.removeItem(at: zshDirectory) }
        for (key, value) in savedEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }

    // MARK: Helpers

    private func makeHelper(binary: URL? = nil, keepsRunning: Bool = false) throws -> LocalHelper {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "this-mac-helper-\(UUID().uuidString)"))
        defaults.set(true, forKey: LocalHelper.enabledKey)
        defaults.set(keepsRunning, forKey: LocalHelper.keepsRunningKey)
        let helper = LocalHelper(
            hosts: AppModel.shared.hosts, binary: try binary ?? Self.daemonBinary(), stateDirectory: try XCTUnwrap(stateDirectory),
            isIsolated: true, defaults: defaults)
        helpers.append(helper)
        return helper
    }

    /// The app hands This Mac to `helper`, and a window shows it once it is ready.
    /// `atPrompt`: waits for the test's bare zsh prompt too (a helper the app's child, with
    /// this process's environment; a launchd job's shell is the user's own).
    private func serve(_ helper: LocalHelper, atPrompt: Bool = true) async throws -> String {
        let window = window ?? HostWindow()
        self.window = window
        let before = ready.count
        AppModel.shared.serveThisMac(with: helper)
        let onReady = helper.onReady
        helper.onReady = { [weak self] id in
            self?.ready.append(id)
            onReady?(id)
        }
        try await window.until("the helper is ready", timeout: .seconds(40)) { self.ready.count > before }
        let id = ready[ready.count - 1]
        if window.model.currentGroupId != id { window.model.show(.host(id)) }
        if atPrompt {
            try await window.waitForShell(timeout: .seconds(30))
        } else {
            try await window.until("a live pane", timeout: .seconds(30)) { window.pane?.connection == .live }
        }
        return id
    }

    private var endpoint: LocalHelper.Endpoint? {
        stateDirectory.flatMap(LocalHelper.runningEndpoint(in:))
    }

    /// The window's connection state as it changes, until `done`.
    private func states(until what: String, timeout: Duration = .seconds(40), _ done: () -> Bool) async throws -> [ConnectionState] {
        let window = try XCTUnwrap(window)
        var seen: [ConnectionState] = []
        try await window.until(what, timeout: timeout) {
            let state = window.model.connection
            if seen.last.map({ !Self.sameKind($0, state) }) ?? true { seen.append(state) }
            return done()
        }
        return seen
    }

    private static func sameKind(_ first: ConnectionState, _ second: ConnectionState) -> Bool {
        switch (first, second) {
        case (.reconnecting, .reconnecting), (.connecting, .connecting), (.offline, .offline), (.slow, .slow): true
        default: first == second
        }
    }

    private static func isReconnecting(_ state: ConnectionState) -> Bool {
        if case .reconnecting = state { true } else { false }
    }

    // MARK: Starting

    func testStartingAgainAfterTheAppQuitReadsAsStartingNeverReconnecting() async throws {
        let first = try makeHelper()
        let id = try await serve(first)
        let window = try XCTUnwrap(window)
        first.appWillTerminate()
        try await window.until("the helper ends with the app", timeout: .seconds(10)) { self.endpoint == nil }
        window.close()
        AppModel.shared.hosts.disconnect(id)

        // The next launch: This Mac is paired, its helper not running yet.
        let window2 = HostWindow()
        self.window = window2
        let second = try makeHelper()
        AppModel.shared.serveThisMac(with: second)
        window2.model.show(.host(id))
        let seen = try await states(until: "This Mac is live again") {
            window2.model.connection.isLive && second.state == .running
        }
        XCTAssertFalse(seen.contains(where: Self.isReconnecting), "never a lost link while it starts: \(seen)")
        XCTAssertFalse(seen.contains { $0.isFailure }, "\(seen)")
        if seen.count > 1 { XCTAssertTrue(seen.contains(.starting), "\(seen)") }
    }

    // MARK: Killed

    func testAKilledHelperComesBackOnceWithItsPaneAndScreenAndSendsKeysTypedWhileAwayOnce() async throws {
        let helper = try makeHelper()
        let id = try await serve(helper)
        let window = try XCTUnwrap(window)
        try await window.run("echo before-$((6*7))", showing: "before-42")
        // The helper saves a screen a few seconds after its output.
        await HostWindow.sleep(7)
        let first = try XCTUnwrap(endpoint)
        let paneBefore = try XCTUnwrap(window.pane?.id)

        kill(first.pid, SIGKILL)
        try await window.until("the window sees the link go", timeout: .seconds(10)) { !window.model.connection.isLive }
        window.type("echo held-$((5*5))\r")

        let seen = try await states(until: "This Mac is live again") {
            guard let now = self.endpoint, now.pid != first.pid else { return false }
            return window.model.connection.isLive && window.pane?.connection == .live
        }
        XCTAssertEqual(ready, [id, id], "started again once, as the same host")
        XCTAssertEqual(endpoint?.daemonId, first.daemonId, "the same helper, its keys and pairing kept")
        XCTAssertFalse(seen.contains(where: Self.isReconnecting), "reads as starting, not lost: \(seen)")
        XCTAssertEqual(window.pane?.id, paneBefore, "the same pane")
        try await window.until("the pane shows its screen from before") { window.screenText.contains("before-42") }
        // The new run shows the screen the keys were typed at under its restore note and a
        // fresh prompt: they are sent there, once.
        try await window.until("the keys typed while it was away ran", timeout: .seconds(10)) { window.rows.contains("held-25") }
        await window.pump(1)
        XCTAssertNil(window.pane?.heldInput, "settled without a word")
        XCTAssertEqual(window.rows.filter { $0 == "held-25" }.count, 1, window.screenText)
        try await window.run("echo after-$((2+3))", showing: "after-5")
    }

    // MARK: Upgrade

    func testANewBuildTakesOverTheRunningHelperAndItsSessionsStay() async throws {
        let old = try makeHelper()
        _ = try await serve(old)
        let window = try XCTUnwrap(window)
        try await window.run("echo shell-$$", showing: try await shellRow(window))
        let shellBefore = try XCTUnwrap(window.rows.last { $0.hasPrefix("shell-") })
        let before = try XCTUnwrap(endpoint)

        // The app updated: its bundled helper is another build.
        let newBuild = try Self.otherBuild(in: try XCTUnwrap(stateDirectory))
        let updated = try makeHelper(binary: newBuild)
        AppModel.shared.serveThisMac(with: updated)
        try await window.until("the new build answers", timeout: .seconds(40)) {
            updated.state == .running && window.model.connection.isLive && window.pane?.connection == .live
        }
        let after = try XCTUnwrap(endpoint)
        XCTAssertEqual(after.pid, before.pid, "handed over in place")
        XCTAssertEqual(after.daemonId, before.daemonId)
        XCTAssertEqual(try HelperInstall.codeIdentity(of: try XCTUnwrap(updated.installed)), try HelperInstall.codeIdentity(of: newBuild))
        XCTAssertTrue(window.screenText.contains(shellBefore), "the screen stays: \(window.screenText)")
        try await window.run("echo again-$$", showing: shellBefore.replacingOccurrences(of: "shell-", with: "again-"))
    }

    // MARK: Quitting

    func testQuittingWithSessionsKeptOffEndsTheHelper() async throws {
        let helper = try makeHelper(keepsRunning: false)
        _ = try await serve(helper)
        XCTAssertNotNil(endpoint)

        helper.appWillTerminate()

        try await window?.until("the helper ends with the app", timeout: .seconds(10)) { self.endpoint == nil }
    }

    func testQuittingWithSessionsKeptOnLeavesTheHelperAndItsSessionsRunning() async throws {
        let helper = try makeHelper(keepsRunning: true)
        _ = try await serve(helper, atPrompt: false)
        let window = try XCTUnwrap(window)
        let tabs = try XCTUnwrap(window.model.workspace?.session.tabs.map(\.id))
        let running = try XCTUnwrap(endpoint)

        helper.appWillTerminate()
        window.close()
        self.window = nil
        await HostWindow.sleep(2)

        XCTAssertEqual(endpoint?.pid, running.pid, "the helper outlives the app")
        // The next launch finds it, with its sessions.
        let next = try makeHelper(keepsRunning: true)
        _ = try await serve(next, atPrompt: false)
        XCTAssertEqual(endpoint?.pid, running.pid)
        XCTAssertEqual(self.window?.model.workspace?.session.tabs.map(\.id), tabs)
    }

    // MARK: Away for long

    func testAHelperThatStopsAnsweringIsNamedAfterAWhileAndReconnectNowBringsItBack() async throws {
        let helper = try makeHelper()
        _ = try await serve(helper)
        let window = try XCTUnwrap(window)
        let running = try XCTUnwrap(endpoint)

        kill(running.pid, SIGSTOP)
        defer { kill(running.pid, SIGCONT) }
        try await window.until("the link is lost", timeout: .seconds(30)) { !window.model.connection.isLive }
        try await window.until("a card says the helper isn't answering", timeout: .seconds(60)) {
            window.element("connection-overlay") != nil
        }
        XCTAssertTrue(window.says("isn't answering") || window.says("hasn't answered"), window.texts().joined(separator: " | "))

        kill(running.pid, SIGCONT)
        let button = try XCTUnwrap(window.element("Reconnect Now") ?? window.element("Retry Now"), window.describeElements())
        try await window.click(button)
        try await window.until("live again", timeout: .seconds(20)) { window.model.connection.isLive }
        try await window.until("the card is gone") { window.element("connection-overlay") == nil }
    }

    func testAHelperThatHangsAsTheAppStartsIsNamedAfterAWhileAndRetryNowReachesIt() async throws {
        let first = try makeHelper()
        let id = try await serve(first)
        let running = try XCTUnwrap(endpoint)
        window?.close()
        window = nil
        AppModel.shared.hosts.disconnect(id)

        // The next launch finds the helper running, but it does not answer.
        kill(running.pid, SIGSTOP)
        defer { kill(running.pid, SIGCONT) }
        let window = HostWindow()
        self.window = window
        let second = try makeHelper()
        AppModel.shared.serveThisMac(with: second)
        window.model.show(.host(id))
        var seen: [ConnectionState] = []
        try await window.until("the window says it is starting", timeout: .seconds(10)) { window.says("Starting…", inSheet: false) }
        XCTAssertNil(window.element("Retry Now"), "nothing to do yet")
        try await window.until("after a while it says the helper hasn't answered", timeout: .seconds(70)) {
            if seen.last.map({ !Self.sameKind($0, window.model.connection) }) ?? true { seen.append(window.model.connection) }
            return window.says("The helper on This Mac hasn't answered", inSheet: false)
        }
        XCTAssertFalse(seen.contains(where: Self.isReconnecting), "it reads as starting: \(seen)")
        XCTAssertNotNil(window.element("Disconnect"))

        kill(running.pid, SIGCONT)
        try await window.click("Retry Now")
        try await window.until("live", timeout: .seconds(30)) { window.model.connection.isLive && window.pane?.connection == .live }
        XCTAssertFalse(window.says("hasn't answered", inSheet: false))
        XCTAssertEqual(endpoint?.pid, running.pid, "the same helper, its sessions kept")
    }

    // MARK: Builds

    /// A row `echo shell-$$` will print, once the shell's pid is known.
    private func shellRow(_ window: HostWindow) async throws -> String {
        window.type("echo $$\r")
        var pid = ""
        try await window.until("the shell says its pid") {
            guard let row = window.rows.last(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
            pid = row
            return true
        }
        return "shell-\(pid)"
    }

    /// The daemon build the tests run (`GUDO_HOSTD_BIN`, else the workspace's debug build).
    static func daemonBinary() throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["GUDO_HOSTD_BIN"].map(URL.init(fileURLWithPath:))
            ?? repoRoot.appending(path: "target/debug/gudo-hostd")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "no daemon at \(binary.path): run `cargo build -p hostd` first")
        return binary
    }

    /// The same daemon signed again under another identifier: another build as far as the
    /// install can tell (its code hash differs).
    static func otherBuild(in directory: URL) throws -> URL {
        let folder = directory.appending(path: "next-build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: try daemonBinary().lastPathComponent)
        try FileManager.default.copyItem(at: try daemonBinary(), to: copy)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", "next-build-\(UUID().uuidString.prefix(6))", copy.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try XCTSkipUnless(sign.terminationStatus == 0, "codesign could not sign a copy")
        return copy
    }
}

extension HostWindow {
    static func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
#endif
