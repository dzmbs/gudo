import GudoCore
import HostKit
import PaneLayout
import XCTest
@testable import App

@MainActor
final class PaneCommandMarksTests: XCTestCase {
    private struct Fixture {
        let pane: Pane
        let workspace: Workspace
        let connection: DaemonConnection
        let marks: PaneCommandMarks

        @MainActor func close() {
            pane.detach()
            workspace.close()
            connection.close()
        }
    }

    func testRepeatedPaneNumbersOnDifferentHostsCannotReplaceEachOthersMarks() throws {
        let first = try fixture(host: "first")
        defer { first.close() }
        let second = try fixture(host: "second")
        defer { second.close() }
        XCTAssertEqual(first.pane.id, second.pane.id)
        XCTAssertTrue(PaneCommandMarks.of(first.pane) === first.marks)
        XCTAssertTrue(PaneCommandMarks.of(second.pane) === second.marks)
    }

    func testAnUnattachedViewCannotBorrowAnotherViewsRepeatedPaneNumber() throws {
        let first = try fixture(host: "first")
        defer { first.close() }
        let backend = try first.connection.makeBackend(for: first.pane.id)
        let second = try Pane(id: first.pane.id, backend: backend, appearance: .fromPreferences(), onExit: {})
        defer { second.detach() }
        XCTAssertNil(PaneCommandMarks.of(second))
        let daemonBackend = try XCTUnwrap(backend as? DaemonPaneBackend)
        let marks = PaneCommandMarks.attach(to: second, backend: daemonBackend,
                                           daemon: first.connection, workspace: first.workspace)
        XCTAssertTrue(PaneCommandMarks.of(second) === marks)
        XCTAssertTrue(PaneCommandMarks.of(first.pane) === first.marks)
    }

    func testExactCommandNavigationUsesRetainedPinsRatherThanTheNearestPrompt() throws {
        let fixture = try fixture(host: "navigation")
        defer { fixture.close() }
        let list = seed(fixture)
        let terminal = fixture.pane.view.surface.terminal
        XCTAssertGreaterThan(terminal.viewportTopRow, 10)
        XCTAssertTrue(fixture.marks.reveal(command: 42))
        XCTAssertEqual(terminal.viewportTopRow, 10)
        terminal.write(Array(String(repeating: "later output\r\n", count: 40).utf8))
        fixture.marks.tracker.observe(seq: 200)
        terminal.scrollToBottom()
        XCTAssertTrue(fixture.marks.reveal(command: list.commands[0].mark.commandId))
        XCTAssertEqual(terminal.viewportTopRow, 10)
    }

    func testUnavailableFutureForeignAndAlternateScreenMarksNeverGuessARow() throws {
        let fixture = try fixture(host: "missing-navigation")
        defer { fixture.close() }
        var list = seed(fixture)
        let terminal = fixture.pane.view.surface.terminal
        let top = terminal.viewportTopRow
        XCTAssertFalse(fixture.marks.reveal(command: 99))
        list.atSeq = 200
        fixture.marks.reconcile(list)
        XCTAssertFalse(fixture.marks.reveal(command: 42))
        XCTAssertEqual(terminal.viewportTopRow, top)
        list.atSeq = 100
        list.commands[0].mark.paneId = 99
        fixture.marks.reconcile(list)
        XCTAssertFalse(fixture.marks.reveal(command: 42))
        XCTAssertEqual(terminal.viewportTopRow, top)
        list.commands[0].mark.paneId = fixture.pane.id.rawValue
        fixture.marks.reconcile(list)
        terminal.write(Array("\u{1b}[?1049h".utf8))
        XCTAssertTrue(terminal.isAlternateScreen)
        XCTAssertFalse(fixture.marks.reveal(command: 42))
    }

    func testErasedHistoryCannotBeReplacedByASimilarLookingScreenRow() throws {
        let fixture = try fixture(host: "expired-navigation")
        defer { fixture.close() }
        _ = seed(fixture)
        let terminal = fixture.pane.view.surface.terminal
        terminal.write(Array("\u{1b}[3J".utf8))
        let top = terminal.viewportTopRow
        XCTAssertFalse(fixture.marks.reveal(command: 42))
        XCTAssertEqual(terminal.viewportTopRow, top)
    }

    private func seed(_ fixture: Fixture) -> CommandList {
        let terminal = fixture.pane.view.surface.terminal
        terminal.write(Array((0..<120).map { "row \($0)\r\n" }.joined().utf8))
        fixture.marks.tracker.observe(seq: 100, snapshot: true)
        let mark = CommandMark(paneId: fixture.pane.id.rawValue, commandId: 42, command: "fixture",
            cwd: "/fixture", startedAtMs: 1_000, atSeq: 100, finished: CommandEnd(exit: 0, durationMs: 50))
        let info = CommandInfo(mark: mark, promptRow: 10, outputRow: 11, endRow: 20)
        let list = CommandList(atSeq: 100, totalRows: UInt64(terminal.totalRows), commands: [info])
        fixture.marks.reconcile(list)
        terminal.scrollToBottom()
        return list
    }

    private func fixture(host: String) throws -> Fixture {
        let client = FakeWorkspaceClient()
        let connection = DaemonConnection(hostId: host, ticket: "fixture") { _, listener in
            client.state.withLock { $0.events = listener }
            return client
        }
        try connection.connect()
        let workspace = Workspace(hostId: host, connection: connection)
        let backend = try connection.makeBackend(for: PaneId(7))
        let pane = try Pane(id: PaneId(7), backend: backend, appearance: .init(), onExit: {})
        let daemonBackend = try XCTUnwrap(backend as? DaemonPaneBackend)
        let marks = PaneCommandMarks.attach(to: pane, backend: daemonBackend,
                                           daemon: connection, workspace: workspace)
        return Fixture(pane: pane, workspace: workspace, connection: connection, marks: marks)
    }
}
