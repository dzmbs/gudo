import Foundation
@testable import HostKit
import Testing

/// A connection's end against a real daemon (fast; runs with the other integration tests).
@MainActor
@Suite(.serialized) struct ConnectionLifecycleTests {
    let stress = ClientStressTests()

    /// Disconnecting a host while a window still holds one of its panes ends the connection:
    /// nothing keeps streaming into the pane or redialling behind the user's back.
    @Test func disconnectingAHostEndsItsConnectionEvenWithPanesOpen() async throws {
        let daemon = try LocalDaemon()
        let model = stress.makeModel()
        let (connection, panes) = try await stress.host(try await daemon.ticket(), model: model)
        let pane = MirrorPane(try connection.makeBackend(for: panes[0]))
        try await eventually("prompt", timeout: .seconds(10)) { pane.snapshots > 0 }
        pane.type("i=0; while :; do i=$((i+1)); echo tick $i; sleep 0.02; done\r")
        try await eventually("ticking", timeout: .seconds(10)) { pane.tail.contains("tick 5") }
        let hostId = try #require(model.records.first?.id)
        model.disconnect(hostId)
        try await Task.sleep(for: .seconds(1))
        let settled = pane.bytes
        try await Task.sleep(for: .seconds(2))
        #expect(pane.bytes == settled, "output still arrives after the host was disconnected")
        if case .stale = pane.connection {} else { Issue.record("the pane is not marked stale: \(String(describing: pane.connection))") }
        pane.backend.terminate()
    }
}
