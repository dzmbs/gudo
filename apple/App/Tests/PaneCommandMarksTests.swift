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

    private func fixture(host: String) throws -> Fixture {
        let client = FakeWorkspaceClient()
        let connection = DaemonConnection(hostId: host, ticket: "fixture") { _, listener in
            client.state.withLock { $0.events = listener }
            return client
        }
        try connection.connect()
        let workspace = Workspace(hostId: host, connection: connection)
        let backend = try connection.makeBackend(for: PaneId(7))
        let pane = try Pane(id: PaneId(7), backend: backend, appearance: .fromPreferences(), onExit: {})
        let daemonBackend = try XCTUnwrap(backend as? DaemonPaneBackend)
        let marks = PaneCommandMarks.attach(to: pane, backend: daemonBackend,
                                           daemon: connection, workspace: workspace)
        return Fixture(pane: pane, workspace: workspace, connection: connection, marks: marks)
    }
}
