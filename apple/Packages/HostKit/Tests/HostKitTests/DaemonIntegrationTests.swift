import Foundation
@testable import HostKit
import PaneLayout
import Testing
import UnnamedCore

/// The repository root (this file is apple/Packages/HostKit/Tests/HostKitTests/…).
nonisolated let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A local `unnamed-hostd` with relays off (as UnnamedCore's tests run it). Build it first:
/// `cargo build -p hostd`, or point `UN_HOSTD_BIN` at a build.
nonisolated final class LocalDaemon {
    let binary: URL
    let stateDir: URL
    private var process: Process?
    /// Fixed across restarts so the ticket's direct address stays valid (relays are off).
    let port: UInt16

    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw TestError("no free port") }
        return UInt16(bigEndian: address.sin_port)
    }

    /// The daemon build the tests run (`UN_HOSTD_BIN`, else the workspace's debug build).
    static var defaultBinary: URL {
        ProcessInfo.processInfo.environment["UN_HOSTD_BIN"].map(URL.init(fileURLWithPath:))
            ?? repoRoot.appending(path: "target/debug/unnamed-hostd")
    }

    init(binary: URL? = nil) throws {
        self.binary = binary ?? Self.defaultBinary
        guard FileManager.default.isExecutableFile(atPath: self.binary.path) else {
            throw TestError("no daemon at \(self.binary.path): run `cargo build -p hostd` first")
        }
        stateDir = temporaryDirectory()
        port = try Self.freePort()
        try start()
    }

    /// Starts (or restarts, keeping its state: same id, layout, paired devices) the daemon.
    func start() throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--state-dir", stateDir.path, "run", "--no-relay", "--bind", "127.0.0.1:\(port)", "--shell", "/bin/sh"]
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

        // Ctrl-C reaches the remote foreground job.
        Array("sleep 100\r".utf8).withUnsafeBytes { second.write($0) }
        try await Task.sleep(for: .milliseconds(500))
        Array("\u{03}echo int-$?\r".utf8).withUnsafeBytes { second.write($0) }
        try await eventually("ctrl-c", timeout: .seconds(10)) { secondSink.output.contains("int-130") }

        // ⌘W on the new pane: the daemon closes it and ends its process.
        let marker = Int.random(in: 40000...49999)
        Array("sleep \(marker)\r".utf8).withUnsafeBytes { second.write($0) }
        try await eventually("job runs", timeout: .seconds(10)) { pgrep("sleep \(marker)") }
        connection.layout.apply(.close(newPane))
        try await eventually("closed", timeout: .seconds(10)) { connection.layout.session.panes.count == 1 }
        try await eventually("job ended with the pane", timeout: .seconds(10)) { !pgrep("sleep \(marker)") }
        second.terminate()
        connection.layout.apply(.split(pane, .horizontal))
        try await eventually("split again", timeout: .seconds(10)) { connection.layout.session.panes.count == 2 }

        // Restart the daemon: panes go stale (content kept), then live again, and the layout
        // (restored by the daemon with the same ids) is still there.
        daemon.kill()
        try await eventually("stale", timeout: .seconds(20)) {
            if case .stale = sink.lastConnection { true } else { false }
        }
        try await eventually("status shows the drop", timeout: .seconds(10)) { !connection.status.isLive }
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

    /// Projects live on the daemon: what one connection groups, a fresh connection is told, and
    /// a reorder never shows the old order in between.
    @Test func projectsComeBackFromTheDaemon() async throws {
        let daemon = try LocalDaemon()
        let model = makeModel()
        let hostId = try await model.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        let connection = try #require(model.connection(hostId) as? DaemonConnection)
        try await eventually("features", timeout: .seconds(10)) { connection.layout.supportsProjects }
        let store = connection.layout
        store.apply(.newTab)
        store.apply(.newTab)
        try await eventually("three tabs", timeout: .seconds(10)) { store.session.tabs.count == 3 }
        let tabs = store.session.tabs.map(\.id)

        let info = ProjectInfo(id: "p1", name: "app", color: 2, order: 0, updated: 1)
        store.apply(.put(info))
        store.apply(.setTab(tabs[0], Membership(project: "p1", rank: 0)))
        store.apply(.setTab(tabs[2], Membership(project: "p1", rank: 1024)))
        #expect(store.projects.members.count == 2, "shown before the daemon answers")
        var orders: [[TabId]] = []
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                orders.append(store.session.tabs.map(\.id))
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        // A click (focus) right before the drop: its echo carries the order from before the move.
        store.apply(.focus(try #require(store.session.tabs.last?.focused)))
        store.apply(.moveTab(tabs[2], to: 0))
        try await Task.sleep(for: .seconds(1))
        observer.cancel()
        let moved = [tabs[2], tabs[0], tabs[1]]
        #expect(store.session.tabs.map(\.id) == moved)
        #expect(orders.allSatisfy { $0 == moved }, "an echo never showed the old order: \(orders.count) samples")

        model.disconnect(hostId)
        let again = try #require(try model.open(hostId) as? DaemonConnection)
        try await eventually("projects again", timeout: .seconds(15)) { again.layout.projects.members.count == 2 }
        #expect(again.layout.projects.projects["p1"]?.name == "app")
        #expect(again.layout.projects.members[tabs[2]]?.rank == 1024)
    }

    /// Closing a host's last tab leaves the host empty, never a tab whose panes are gone (the
    /// owner once typed into one and was told it was "outside what you were invited to"); Undo
    /// brings the tab back in the same session, in its directory.
    @Test func closingTheLastTabLeavesTheHostEmptyAndUndoBringsItBack() async throws {
        let daemon = try LocalDaemon()
        let model = makeModel()
        let hostId = try await model.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        let connection = try #require(model.connection(hostId) as? DaemonConnection)
        try await eventually("layout", timeout: .seconds(15)) { connection.isReady && connection.layout.session.tabs.count == 1 }
        let store = connection.layout
        let session = try #require(store.sessionId)
        let tab = try #require(store.session.tabs.first)

        store.apply(.closeTab(tab.id))
        try await eventually("empty host", timeout: .seconds(10)) { store.session.tabs.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.session.tabs.isEmpty, "nothing comes back on its own")
        #expect(store.sessionId == session, "the session stays, empty")
        #expect(connection.status.isLive)

        let back = try await connection.reopenTab(closedPane: tab.focused.rawValue, directory: NSTemporaryDirectory(), name: "again")
        try await eventually("reopened", timeout: .seconds(10)) { store.session.tabs.map(\.id) == [back.tab] }
        #expect(store.session.tabs.first?.title == "again")
        #expect(store.sessionId == session)
    }

    /// Tickets minted the moment a daemon starts (as the UI tests' daemons are) all pair; a
    /// used ticket is refused on another device and leaves no host there, which then pairs
    /// with a new ticket.
    @Test func freshTicketsPairAndAUsedOneLeavesNothingBehind() async throws {
        let daemon = try LocalDaemon()
        let first = makeModel()
        let used = try PairingTicket(try await daemon.ticket())
        let hostId = try await first.pair(used, name: "local")
        #expect(first.connection(hostId)?.status.isLive == true)

        let other = makeModel()
        await #expect(throws: PairingError.self) { try await other.pair(used, name: "local") }
        #expect(other.records.isEmpty)
        #expect(other.connections.isEmpty)

        let id = try await other.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        #expect(other.records.map(\.id) == [id])
        #expect(other.connection(id)?.status.isLive == true)
    }
}
