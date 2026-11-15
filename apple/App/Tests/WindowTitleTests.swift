import PaneLayout
import XCTest
@testable import App

/// The window's title and the line under it: the tab on screen, its context when that adds
/// something, then the split.
@MainActor
final class WindowTitleTests: XCTestCase {
    private final class Quiet: PaneBackend, @unchecked Sendable {
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {}
        func write(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}
        func terminate() {}
    }

    private var workspace: Workspace!

    override func tearDown() {
        workspace?.close()
        super.tearDown()
    }

    private func make(splits: Int) throws -> Tab {
        var session = Session()
        for _ in 0..<splits {
            let focused = try XCTUnwrap(session.activeTab?.focused)
            session.apply(.split(focused, .horizontal))
        }
        workspace = Workspace(layout: LocalLayoutStore(session: session)) { _ in Quiet() }
        return try XCTUnwrap(workspace.session.activeTab)
    }

    func testASplitWithNothingElseToSayNamesThePanesOnce() throws {
        let tab = try make(splits: 1)
        XCTAssertEqual(workspace.windowSubtitle(of: tab), "2 panes")
    }

    func testASinglePaneWithNothingToSayHasNoSubtitle() throws {
        let tab = try make(splits: 0)
        XCTAssertEqual(workspace.windowSubtitle(of: tab), "")
    }

    func testTheSidebarRowStillNamesThePanesWhenNothingElseIsKnown() throws {
        let tab = try make(splits: 2)
        XCTAssertEqual(workspace.context(of: tab), "3 panes")
    }

    func testTheTitleWaitsForTheSelectedTabToDraw() throws {
        let first = try make(splits: 0)
        workspace.apply(.newTab)
        let second = try XCTUnwrap(workspace.session.activeTab)
        XCTAssertNotEqual(first.id, second.id)
        workspace.tabHandoff.select(first.id) { true }
        workspace.tabHandoff.select(second.id) { false }
        XCTAssertEqual(workspace.shownTab?.id, first.id, "the title stays with the content on screen")
    }
}
