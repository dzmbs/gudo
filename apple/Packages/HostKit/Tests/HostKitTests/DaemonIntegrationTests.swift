import Foundation
@testable import HostKit
import PaneLayout
import Synchronization
import TerminalCore
import Testing
import GudoCore

/// The repository root (this file is apple/Packages/HostKit/Tests/HostKitTests/…).
nonisolated let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A local `gudo-hostd` with relays off (as GudoCore's tests run it). Build it first:
/// `cargo build -p hostd`, or point `GUDO_HOSTD_BIN` at a build.
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

    /// The daemon build the tests run (`GUDO_HOSTD_BIN`, else the workspace's debug build).
    static var defaultBinary: URL {
        ProcessInfo.processInfo.environment["GUDO_HOSTD_BIN"].map(URL.init(fileURLWithPath:))
            ?? repoRoot.appending(path: "target/debug/gudo-hostd")
    }

    /// Run the way the Mac app runs its own helper: relays on, every interface, `pair --local`.
    let isThisMacHelper: Bool

    init(binary: URL? = nil, isThisMacHelper: Bool = false) throws {
        self.isThisMacHelper = isThisMacHelper
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
        process.arguments = isThisMacHelper
            ? ["--state-dir", stateDir.path, "run", "--shell", "/bin/sh"]
            : ["--state-dir", stateDir.path, "run", "--no-relay", "--bind", "127.0.0.1:\(port)", "--shell", "/bin/sh"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
    }

    /// Sends `signal` to the daemon (SIGSTOP/SIGCONT: a host that freezes and comes back).
    func send(_ signal: Int32) {
        if let pid = process?.processIdentifier { Darwin.kill(pid, signal) }
    }

    func kill() {
        send(SIGCONT)  // a stopped daemon would never see the SIGTERM
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
            pair.arguments = ["--state-dir", stateDir.path, "pair", "--json"] + (isThisMacHelper ? ["--local"] : [])
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

    /// Removes every paired device, as `gudo devices` does.
    func unpairEveryDevice() throws {
        let list = try run(["devices", "--json"])
        let devices = try JSONSerialization.jsonObject(with: list) as? [[String: Any]] ?? []
        for device in devices.compactMap({ $0["device"] as? String }) {
            _ = try run(["unpair", String(device.prefix(16))])
        }
    }

    private func run(_ arguments: [String]) throws -> Data {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--state-dir", stateDir.path] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestError("\(arguments.joined(separator: " ")) failed") }
        return data
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
        connection.networkChanged()  // what the path monitor or foreground would do
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
        let resumeDuration = ContinuousClock.now - resumed
        print("local daemon: resume from suspend \(resumeDuration)")
        #expect(resumeDuration < .seconds(1), "a loopback resume shows the live pane within a second")
        Array("echo resumed-$((3+4))\r".utf8).withUnsafeBytes { backend.write($0) }
        try await eventually("echo after resume", timeout: .seconds(10)) { connection.paneText(pane)?.contains("resumed-7") == true }

        // A second app instance with the same device key re-dials by the saved ticket (no new
        // pairing secret needed: the device is allowlisted).
        model.disconnect(hostId)
        let again = try #require(try model.open(hostId) as? DaemonConnection)
        try await eventually("reconnected by saved ticket", timeout: .seconds(15)) { again.isReady && again.status.isLive }
    }

    /// Instant start against a real daemon: a host opened again shows its saved workspace at
    /// once (before any packet), then the daemon's layout and screens replace it in place;
    /// what was typed before is sent once the screen is the daemon's and reads the same.
    /// Prints the times (docs/PERFORMANCE.md "Instant start").
    @Test func instantStartShowsTheSavedWorkspaceThenGoesLive() async throws {
        let daemon = try LocalDaemon()
        let model = makeModel()
        let store = WorkspaceCacheStore(directory: temporaryDirectory(), secrets: MemorySecretStore())
        model.workspaceCache = store
        let hostId = try await model.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        let first = try #require(model.connection(hostId) as? DaemonConnection)
        let pane = try #require(first.layout.session.activeTab?.focused)
        let terminal = Terminal(cols: 80, rows: 24) { _ in }
        let backend = try first.makeBackend(for: pane)
        backend.start { event in
            switch event {
            case .snapshot(let data): try? terminal.restore(snapshot: data)
            case .output(let data): terminal.write(Array(data))
            default: break
            }
        }
        backend.resize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        Array("clear; echo saved-$((6*7))\r".utf8).withUnsafeBytes { backend.write($0) }
        try await eventually("output", timeout: .seconds(10)) { terminal.visibleText().contains("saved-42") }
        try await Task.sleep(for: .milliseconds(300))
        let draft = try #require(first.workspaceToSave(daemonId: model.record(hostId)?.daemonId))
        let saved = draft.capturingScreens([pane.rawValue: terminal])
        try store.save(saved)
        let bytes = try Data(contentsOf: store.file(for: hostId)).count
        backend.terminate()

        var samples: [(cached: Duration, connected: Duration, layout: Duration, screen: Duration)] = []
        for round in 0..<5 {
            model.disconnect(hostId)
            let started = ContinuousClock.now
            let connection = try #require(try model.open(hostId) as? DaemonConnection)
            let cached = ContinuousClock.now - started
            #expect(connection.showsCachedLayout)
            #expect(connection.layout.session.panes.contains(pane))
            let screen = try #require(connection.cachedScreen(for: pane)?.screen)
            let view = Terminal(cols: 80, rows: 24) { _ in }
            try view.restore(snapshot: screen)
            #expect(view.visibleText().contains("saved-42"))

            let live = try #require(try connection.makeBackend(for: pane) as? DaemonPaneBackend)
            let states = HeldStates()
            live.holdInputUntilLive(screen: { view.visibleText() }) { states.append($0) }
            let shown = Mutex<ContinuousClock.Instant?>(nil)
            live.start { event in
                switch event {
                case .snapshot(let data):
                    try? view.restore(snapshot: data)
                    shown.withLock { $0 = $0 ?? .now }
                case .output(let data): view.write(Array(data))
                default: break
                }
            }
            live.resize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
            // Typed over the saved screen, before the daemon answered.
            if round == 0 { Array("echo early-$((1+1))\r".utf8).withUnsafeBytes { live.write($0) } }
            try await eventually("live", timeout: .seconds(15)) {
                connection.isReady && connection.status.isLive && shown.withLock { $0 } != nil
            }
            let timings = connection.timings
            samples.append((
                cached, timings.connected ?? .zero, timings.firstLayout ?? .zero,
                try #require(shown.withLock { $0 }) - started))
            #expect(!connection.showsCachedLayout)
            if round == 0 {
                try await eventually("held input sent", timeout: .seconds(10)) { view.visibleText().contains("early-2") }
                #expect(states.all.last == .sent)
            }
            live.terminate()
        }
        func median(_ values: [Duration]) -> Duration { values.sorted()[values.count / 2] }
        print("instant start (local daemon, \(bytes) B cache): saved workspace \(median(samples.map(\.cached))), connected \(median(samples.map(\.connected))), layout \(median(samples.map(\.layout))), live screen \(median(samples.map(\.screen)))")
    }

    /// The app quits (an update relaunches it) and the helper restarts cold: the tab and the
    /// pane that had focus are focused again, also over the saved workspace shown first.
    @Test func theFocusedTabAndPaneComeBackAfterARestartAndRelaunch() async throws {
        let daemon = try LocalDaemon()
        let model = makeModel()
        let store = WorkspaceCacheStore(directory: temporaryDirectory(), secrets: MemorySecretStore())
        model.workspaceCache = store
        let hostId = try await model.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        let first = try #require(model.connection(hostId) as? DaemonConnection)
        let wanted = try #require(first.layout.session.activeTab?.focused)
        let wantedTab = try #require(first.layout.session.activeTabId)
        first.layout.apply(.split(wanted, .horizontal))
        try await eventually("split", timeout: .seconds(10)) { first.layout.session.panes.count == 2 }
        first.layout.apply(.newTab)
        try await eventually("second tab", timeout: .seconds(10)) { first.layout.session.tabs.count == 2 }
        #expect(first.layout.session.activeTabId != wantedTab)
        first.layout.apply(.focus(wanted))
        try await eventually("focused", timeout: .seconds(10)) {
            first.layout.session.activeTabId == wantedTab && first.layout.session.activeTab?.focused == wanted
        }
        try await Task.sleep(for: .milliseconds(800))
        try store.save(try #require(first.workspaceToSave(daemonId: model.record(hostId)?.daemonId)))
        model.disconnect(hostId)

        daemon.kill()
        try daemon.start()
        let connection = try #require(try model.open(hostId) as? DaemonConnection)
        #expect(connection.showsCachedLayout)
        #expect(connection.layout.session.activeTabId == wantedTab)
        #expect(connection.layout.session.activeTab?.focused == wanted)
        try await eventually("live", timeout: .seconds(30)) {
            connection.status.isLive && !connection.showsCachedLayout && connection.layout.session.panes.count == 3
        }
        #expect(connection.layout.session.activeTabId == wantedTab)
        #expect(connection.layout.session.activeTab?.focused == wanted)
        model.disconnect(hostId)
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

    /// Closing a host's last tab leaves the host empty, never a tab whose panes are gone; Undo
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
        var announced: [String] = []
        first.onFirstPairing = { announced.append($0) }
        let used = try PairingTicket(try await daemon.ticket())
        let hostId = try await first.pair(used, name: "local")
        #expect(first.connection(hostId)?.status.isLive == true)
        #expect(announced == [hostId], "a new host is announced once (notification permission asks then)")
        _ = try await first.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        #expect(announced == [hostId], "re-pairing a known host is not a first pairing")

        let other = makeModel()
        other.onFirstPairing = { announced.append($0) }
        await #expect(throws: PairingError.self) { try await other.pair(used, name: "local") }
        #expect(announced.count == 1, "a refused pairing is not announced")
        #expect(other.records.isEmpty)
        #expect(other.connections.isEmpty)

        let id = try await other.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        #expect(other.records.map(\.id) == [id])
        #expect(other.connection(id)?.status.isLive == true)
    }
}
