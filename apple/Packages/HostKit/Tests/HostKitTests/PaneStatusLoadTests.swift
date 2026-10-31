import Foundation
@testable import HostKit
import Observation
import PaneLayout
import Synchronization
import Testing
import UnnamedCore

/// A fleet of agents reporting hundreds of times a second: views that show one pane see that
/// pane's changes only, and updates reach views at a bounded rate, newest per pane.
@MainActor
@Suite struct PaneStatusLoadTests {
    private func makeConnection() throws -> (DaemonConnection, FakeClient) {
        let client = Mutex<FakeClient?>(nil)
        let connection = DaemonConnection(hostId: "h", ticket: "t") { _, listener in
            let fake = FakeClient(listener: listener)
            client.withLock { $0 = fake }
            return fake
        }
        try connection.connect()
        return (connection, client.withLock { $0! })
    }

    private func meta(_ pane: UInt64, _ title: String) -> PaneMeta {
        PaneMeta(
            paneId: pane, title: title, cwd: "/", exit: nil, agent: AgentStatus(kind: "claude", state: .running),
            size: PaneSize(cols: 80, rows: 24), sizePolicy: .smallest, sizedBy: nil)
    }

    /// Counts how often reading `read` would have re-rendered a view.
    private final class Invalidations {
        var count = 0
        func watch(_ read: @escaping @MainActor () -> Void) {
            withObservationTracking { read() } onChange: { [self] in
                Task { @MainActor in
                    self.count += 1
                    self.watch(read)
                }
            }
        }
    }

    @Test func aRowOfOnePaneIgnoresTheOthers() async throws {
        let (connection, client) = try makeConnection()
        for pane in 1...3 as ClosedRange<UInt64> { client.send(.paneMeta(meta: meta(pane, "start"))) }
        try await eventually("panes") { connection.meta.all.count == 3 }

        let row = Invalidations()
        row.watch { _ = connection.meta[PaneId(1)] }
        for n in 0..<50 { client.send(.paneMeta(meta: meta(2 + UInt64(n % 2), "step \(n)"))) }
        try await eventually("the others' updates") { connection.meta[PaneId(3)]?.title == "step 49" }
        try await Task.sleep(for: .milliseconds(100))
        #expect(row.count == 0, "pane 1's row re-rendered for other panes")

        client.send(.paneMeta(meta: meta(1, "mine")))
        try await eventually("its own update") { row.count == 1 }
        #expect(connection.meta[PaneId(1)]?.title == "mine")
    }

    @Test func aFloodReachesViewsAtABoundedRateNewestPerPane() async throws {
        let (connection, client) = try makeConnection()
        let all = Invalidations()
        all.watch { _ = connection.meta.all }
        // One quiet update applies at once.
        client.send(.paneMeta(meta: meta(1, "first")))
        try await eventually("the first update") { connection.meta[PaneId(1)]?.title == "first" }
        #expect(all.count == 1)

        // 2 000 updates over 200 panes in about half a second.
        let start = ContinuousClock.now
        for n in 0..<2_000 {
            client.send(.paneMeta(meta: meta(UInt64(n % 200) + 1, "step \(n)")))
            if n % 40 == 39 { try await Task.sleep(for: .milliseconds(10)) }
        }
        try await eventually("the last update") { connection.meta[PaneId(200)]?.title == "step 1999" }
        let elapsed = ContinuousClock.now - start
        let windows = Int(elapsed / DaemonConnection.paneStatusInterval) + 3
        #expect(all.count <= windows, "\(all.count) renders in \(elapsed)")
        #expect(connection.meta[PaneId(1)]?.title == "step 1800")

        // A closed pane's held update never brings it back.
        client.send(.paneMeta(meta: meta(7, "late")))
        client.send(.paneClosed(paneId: 7))
        try await eventually("closed") { connection.meta[PaneId(7)] == nil }
        try await Task.sleep(for: .milliseconds(150))
        #expect(connection.meta[PaneId(7)] == nil)
    }
}
