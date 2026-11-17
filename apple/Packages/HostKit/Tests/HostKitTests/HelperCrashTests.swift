import Foundation
import Synchronization
@testable import HostKit
import PaneLayout
import Testing
import GudoCore

/// A helper killed outright and started again on its state folder: its panes come back on the
/// same connection, streaming the new run's screens, and what was typed meanwhile is settled
/// (sent or dropped) once the pane is back, never held on.
@MainActor
@Suite(.serialized) struct HelperCrashTests {
    func makeModel() -> HostsModel {
        var configuration = HostsModel.Configuration()
        configuration.relay = .disabled
        configuration.mirrorVt = true
        return HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()), configuration: configuration)
    }

    @Test func aPaneComesBackStreamingAfterItsHelperIsKilledAndStartedAgain() async throws {
        let daemon = try LocalDaemon()
        defer { daemon.kill() }
        let model = makeModel()
        let id = try await model.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        let connection = try #require(model.connection(id) as? DaemonConnection)
        let pane = try #require(connection.layout.session.activeTab?.focused)
        let backend = try #require(try connection.makeBackend(for: pane) as? DaemonPaneBackend)
        let sink = EventSink()
        backend.start(events: sink.handler)
        backend.resize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        Array("echo before-$((6*7))\r".utf8).withUnsafeBytes { backend.write($0) }
        try await eventually("the shell runs it", timeout: .seconds(10)) { connection.paneText(pane)?.contains("before-42") == true }
        // Saved to disk, as a running helper saves its sessions.
        try await Task.sleep(for: .seconds(2))

        daemon.send(SIGKILL)
        try await eventually("the link drops", timeout: .seconds(40)) { !connection.status.isLive }
        let eventsAfter = sink.all.count
        try daemon.start()
        try await eventually("live again", timeout: .seconds(30)) { connection.status.isLive }

        try await eventually("the pane streams the new run", timeout: .seconds(10)) {
            sink.all.dropFirst(eventsAfter).contains { if case .snapshot = $0 { true } else if case .output = $0 { true } else { false } }
        }
        Array("echo after-$((2+3))\r".utf8).withUnsafeBytes { backend.write($0) }
        try await eventually("keys reach the new shell", timeout: .seconds(10)) { connection.paneText(pane)?.contains("after-5") == true }
    }

    @Test func keysTypedWhileTheHelperWasDownAreSettledOnceThePaneIsBack() async throws {
        let daemon = try LocalDaemon()
        defer { daemon.kill() }
        let model = makeModel()
        let id = try await model.pair(try PairingTicket(try await daemon.ticket()), name: "local")
        let connection = try #require(model.connection(id) as? DaemonConnection)
        let pane = try #require(connection.layout.session.activeTab?.focused)
        let backend = try #require(try connection.makeBackend(for: pane) as? DaemonPaneBackend)
        let sink = EventSink()
        let states = Mutex<[DaemonPaneBackend.HeldInputState]>([])
        backend.followHeldInput(screen: { "" }) { state in states.withLock { $0.append(state) } }
        backend.start(events: sink.handler)
        backend.resize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        Array("echo before-$((6*7))\r".utf8).withUnsafeBytes { backend.write($0) }
        try await eventually("the shell runs it", timeout: .seconds(10)) { connection.paneText(pane)?.contains("before-42") == true }

        daemon.send(SIGKILL)
        try await eventually("the link drops", timeout: .seconds(40)) { !connection.status.isLive }
        Array("echo held-$((5*5))\r".utf8).withUnsafeBytes { backend.write($0) }
        #expect(states.withLock { $0.last } == .holding(1))
        try daemon.start()
        try await eventually("live again", timeout: .seconds(30)) { connection.status.isLive }

        try await eventually("what was held is sent or dropped", timeout: .seconds(10)) {
            states.withLock { $0.last.map { if case .holding = $0 { false } else { true } } ?? false }
        }
        Array("echo after-$((2+3))\r".utf8).withUnsafeBytes { backend.write($0) }
        try await eventually("keys typed now reach the new shell", timeout: .seconds(10)) { connection.paneText(pane)?.contains("after-5") == true }
    }
}
