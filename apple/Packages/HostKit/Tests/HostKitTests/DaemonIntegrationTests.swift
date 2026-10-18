import Foundation
@testable import HostKit
import PaneLayout
import Testing
import UnnamedCore

/// The repository root (this file is apple/Packages/HostKit/Tests/HostKitTests/…).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A local `unnamed-hostd` with relays off (as UnnamedCore's tests run it). Build it first:
/// `cargo build -p hostd`, or point `UN_HOSTD_BIN` at a build.
nonisolated final class LocalDaemon {
    let binary: URL
    let stateDir: URL
    private var process: Process?

    init() throws {
        binary = ProcessInfo.processInfo.environment["UN_HOSTD_BIN"].map(URL.init(fileURLWithPath:))
            ?? repoRoot.appending(path: "target/debug/unnamed-hostd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw TestError("no daemon at \(binary.path): run `cargo build -p hostd` first")
        }
        stateDir = temporaryDirectory()
        try start()
    }

    /// Starts (or restarts, keeping its state: same id, layout, paired devices) the daemon.
    func start() throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--state-dir", stateDir.path, "run", "--no-relay", "--bind", "127.0.0.1:0", "--shell", "/bin/sh"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
    }

    func kill() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
    }

    func ticket() async throws -> String {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let pipe = Pipe()
            let pair = Process()
            pair.executableURL = binary
            pair.arguments = ["--state-dir", stateDir.path, "pair", "--json"]
            pair.standardOutput = pipe
            pair.standardError = FileHandle.nullDevice
            try pair.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            pair.waitUntilExit()
            if pair.terminationStatus == 0,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["running"] as? Bool == true, (object["addrs"] as? [Any])?.isEmpty == false,
               let ticket = object["ticket"] as? String
            {
                return ticket
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TestError("the daemon did not come up")
    }

    deinit {
        kill()
        try? FileManager.default.removeItem(at: stateDir)
    }
}

/// End to end through HostsModel → DaemonConnection → DaemonClient → a real daemon: pair by
/// ticket, type and see the echo, split on the daemon, and survive a daemon restart with the
/// pane dimmed (never blank) until it is live again.
@MainActor
@Suite(.serialized) struct DaemonIntegrationTests {
    func makeModel() -> HostsModel {
        var configuration = HostsModel.Configuration()
        configuration.relay = .disabled
        configuration.mirrorVt = true
        return HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()), configuration: configuration)
    }

    @Test func pairTypeSplitAndReconnect() async throws {
        let daemon = try LocalDaemon()
        let model = makeModel()
        let ticket = try PairingTicket(try await daemon.ticket())
        #expect(!ticket.isExpired)

        let started = ContinuousClock.now
        let hostId = try await model.pair(ticket, name: "local")
        let pairTime = ContinuousClock.now - started
        let connection = try #require(model.connection(hostId) as? DaemonConnection)
        #expect(connection.status.isLive)
        #expect(model.record(hostId)?.daemonId == ticket.info.daemonId)
        #expect(try model.secrets.string(for: model.record(hostId)!.ticketKey) == ticket.text)

        // The focused pane: start it the way a Pane does, size it, type, see the echo.
        let pane = try #require(connection.layout.session.activeTab?.focused)
        let backend = try connection.makeBackend(for: pane)
        let sink = EventSink()
        backend.start(events: sink.handler)
        backend.resize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        try await eventually("first output") {
            sink.all.contains { if case .snapshot = $0 { true } else if case .output = $0 { true } else { false } }
        }
        let firstPaint = ContinuousClock.now - started
        let typed = ContinuousClock.now
        Array("echo hi-$((40+2))\r".utf8).withUnsafeBytes { backend.write($0) }
        try await eventually("echo", timeout: .seconds(10)) { sink.output.contains("hi-42") }
        let echo = ContinuousClock.now - typed
        try await eventually("mirror shows it") { connection.paneText(pane)?.contains("hi-42") == true }
        print("local daemon: pair+layout \(pairTime), first paint \(firstPaint), command round trip \(echo), echo rtt \(String(describing: connection.echoRoundTrip))")

        // ⌘D: the split happens on the daemon; the new pane appears in the layout it sends back.
        connection.layout.apply(.split(pane, .horizontal))
        try await eventually("split", timeout: .seconds(10)) { connection.layout.session.panes.count == 2 }
        let newPane = try #require(connection.layout.session.activeTab?.focused)
        #expect(newPane != pane)
        let second = try connection.makeBackend(for: newPane)
        let secondSink = EventSink()
        second.start(events: secondSink.handler)
        Array("echo second-$((1+1))\r".utf8).withUnsafeBytes { second.write($0) }
        try await eventually("second pane echo", timeout: .seconds(10)) { secondSink.output.contains("second-2") }

        // Restart the daemon: panes go stale (content kept), then live again, and the layout
        // (restored by the daemon with the same ids) is still there.
        daemon.kill()
        try await eventually("stale", timeout: .seconds(20)) {
            if case .stale = sink.lastConnection { true } else { false }
        }
        if case .reconnecting = connection.status {} else if case .connecting = connection.status {} else {
            Issue.record("status while down: \(connection.status)")
        }
        let outputBefore = sink.output
        try daemon.start()
        connection.networkChanged()  // what the path monitor or foreground would do (R10)
        let resumeStarted = ContinuousClock.now
        try await eventually("live again", timeout: .seconds(30)) { sink.lastConnection == .live && connection.status.isLive }
        try await eventually("layout restored", timeout: .seconds(10)) { connection.layout.session.panes.count == 2 }
        print("local daemon: resume after restart \(ContinuousClock.now - resumeStarted)")
        #expect(sink.output.hasPrefix(outputBefore), "stale content is never cleared by the reconnect")

        // The shell restarted (a daemon restart ends PTYs), and typing works again.
        try await eventually("snapshot or bytes after restart", timeout: .seconds(10)) { sink.all.count > 0 }
        Array("echo back-$((2+3))\r".utf8).withUnsafeBytes { backend.write($0) }
        try await eventually("echo after restart", timeout: .seconds(15)) { connection.paneText(pane)?.contains("back-5") == true }

        // Suspend (iOS background) and resume (foreground).
        connection.background()
        #expect(connection.status == .suspended)
        #expect(sink.lastConnection == .stale(reason: "Paused"))
        let resumed = ContinuousClock.now
        connection.foreground()
        try await eventually("resumed", timeout: .seconds(15)) { connection.status.isLive && sink.lastConnection == .live }
        print("local daemon: resume from suspend \(ContinuousClock.now - resumed)")
        Array("echo resumed-$((3+4))\r".utf8).withUnsafeBytes { backend.write($0) }
        try await eventually("echo after resume", timeout: .seconds(10)) { connection.paneText(pane)?.contains("resumed-7") == true }

        // A second app instance with the same device key re-dials by the saved ticket (no new
        // pairing secret needed: the device is allowlisted).
        model.disconnect(hostId)
        let again = try #require(try model.open(hostId) as? DaemonConnection)
        try await eventually("reconnected by saved ticket", timeout: .seconds(15)) { again.isReady && again.status.isLive }
    }
}
