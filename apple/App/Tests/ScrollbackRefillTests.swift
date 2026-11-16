import Foundation
import HostKit
import PaneLayout
import Synchronization
import TerminalCore
import XCTest
@testable import App

/// A remote pane whose grid grows (⌘−, a pinch, a taller window) shows the host's older rows at
/// its top, as the host's own terminal does, even when they are older than the snapshot it holds.
@MainActor
final class ScrollbackRefillTests: XCTestCase {
    private final class RemoteStream: PaneBackend, @unchecked Sendable {
        let events = Mutex<(@Sendable (PaneEvent) -> Void)?>(nil)
        let historyRequests = Atomic(0)
        let hasHistory = Atomic(true)

        func start(events: @escaping @Sendable (PaneEvent) -> Void) { self.events.withLock { $0 = events } }
        func write(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}
        func terminate() {}
        func requestHistory() -> Bool {
            guard hasHistory.load(ordering: .relaxed) else { return false }
            historyRequests.add(1, ordering: .relaxed)
            return true
        }
        var sizeFollowsStream: Bool { true }
        var hostAnswersQueries: Bool { true }

        func send(_ event: PaneEvent) {
            let deliver = events.withLock { $0 }
            deliver?(event)
        }
    }

    private struct Host {
        let terminal = Terminal(cols: 80, rows: 24) { _ in }
        let ready: Data
        let history: Data

        init() throws {
            for line in 0..<3000 { terminal.write(Array("line \(line)\r\n".utf8)) }
            terminal.write(Array("$ ".utf8))
            let snapshot = try XCTUnwrap(terminal.encodeSnapshot())
            (ready, history) = try XCTUnwrap(Terminal.splitSnapshot(snapshot))
        }

        func topRow() -> Substring? { terminal.visibleText().split(separator: "\n").first }
    }

    private func topRow(of pane: Pane) -> Substring? {
        pane.view.surface.terminal.visibleText().split(separator: "\n", omittingEmptySubsequences: false).first
    }

    func testAGrowingGridShowsTheHostsOlderRowsAtItsTop() throws {
        let host = try Host()
        let stream = RemoteStream()
        let pane = try Pane(id: PaneId(1), backend: stream) {}
        stream.send(.snapshot(host.ready))
        let held = pane.view.surface.terminal.scrollbar
        XCTAssertLessThan(held.total - held.visible, 36, "the snapshot holds fewer rows above its screen than the grid gains")

        host.terminal.resize(cols: 96, rows: 60, cellWidth: 8, cellHeight: 16)
        stream.send(.resized(cols: 96, rows: 60, cellWidth: 8, cellHeight: 16))
        XCTAssertEqual(stream.historyRequests.load(ordering: .relaxed), 1, "the rows the grid gains are asked of the host")
        stream.send(.history(host.history, done: true))
        stream.send(.output(Data("\r\n$ ".utf8)))
        host.terminal.write(Array("\r\n$ ".utf8))

        XCTAssertEqual(pane.view.surface.terminal.size.rows, 60)
        XCTAssertEqual(topRow(of: pane), host.topRow())
        XCTAssertEqual(pane.view.surface.terminal.visibleText(), host.terminal.visibleText())
    }

    func testAGridThatGrowsWithinTheRowsHeldAsksForNothing() throws {
        let host = try Host()
        let stream = RemoteStream()
        let pane = try Pane(id: PaneId(1), backend: stream) {}
        stream.send(.snapshot(host.ready))
        host.terminal.resize(cols: 80, rows: 26, cellWidth: 8, cellHeight: 16)
        stream.send(.resized(cols: 80, rows: 26, cellWidth: 8, cellHeight: 16))
        XCTAssertEqual(stream.historyRequests.load(ordering: .relaxed), 0)
        XCTAssertEqual(topRow(of: pane), host.topRow())
    }

    func testAHostWithNoOlderRowsResizesAtOnce() throws {
        let host = try Host()
        let stream = RemoteStream()
        stream.hasHistory.store(false, ordering: .relaxed)
        let pane = try Pane(id: PaneId(1), backend: stream) {}
        stream.send(.snapshot(host.ready))
        stream.send(.resized(cols: 96, rows: 60, cellWidth: 8, cellHeight: 16))
        XCTAssertEqual(pane.view.surface.terminal.size.rows, 60)
    }

    func testAnUnansweredRequestStillResizes() async throws {
        let host = try Host()
        let stream = RemoteStream()
        let pane = try Pane(id: PaneId(1), backend: stream) {}
        stream.send(.snapshot(host.ready))
        stream.send(.resized(cols: 96, rows: 60, cellWidth: 8, cellHeight: 16))
        stream.send(.output(Data("after".utf8)))
        let deadline = ContinuousClock.now + .seconds(5)
        while pane.view.surface.terminal.size.rows != 60, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(pane.view.surface.terminal.size.rows, 60)
        XCTAssertTrue(pane.view.surface.terminal.visibleText().contains("$ after"), "output after the resize lands after it, in order")
    }
}
