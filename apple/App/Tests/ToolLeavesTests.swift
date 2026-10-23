import PaneLayout
import XCTest
@testable import App

/// Files, Changes, Ports and Replays open as leaves beside the focused pane on the Mac: asked
/// again, the open leaf comes forward instead of a second one.
@MainActor
final class ToolLeavesTests: XCTestCase {
    func testAToolOpensBesideThePaneAndIsReused() throws {
        let model = WindowModel(app: .shared)
        model.startMixedTabs()
        var session = Session()
        session.apply(.split(PaneId(1), .horizontal))
        let id = model.composites.make(fromHost: "h1", tab: session.tabs[0])
        model.activeMixedTab = id

        model.sheet = .diff
        XCTAssertNil(model.sheet, "no sheet: a leaf")
        let tab = try XCTUnwrap(model.activeMixed)
        XCTAssertEqual(tab.leaves.count, 3, "two terminals and Changes")
        XCTAssertEqual(tab.focusedTool?.tool, .changes)
        let changes = try XCTUnwrap(tab.focusedTool)

        // Focus a terminal, ask again: the same leaf takes the focus.
        model.focusLeaf(tab.leaves[0], inMixedTab: id)
        model.sheet = .diff
        XCTAssertEqual(model.activeMixed?.leaves.count, 3)
        XCTAssertEqual(model.activeMixed?.focusedTool, changes)

        // Another tool is a leaf of its own.
        model.sheet = .files
        XCTAssertEqual(model.activeMixed?.leaves.count, 4)
        XCTAssertEqual(model.activeMixed?.focusedTool?.tool, .files)
        XCTAssertNotEqual(model.title(ofMixedTab: try XCTUnwrap(model.activeMixed)), "Files", "the tab keeps its terminal's name")

        model.closeTool(changes.id)
        XCTAssertNil(model.composites.tab(containingTool: changes.id))
        XCTAssertEqual(model.activeMixed?.leaves.count, 3)
    }

    func testOtherSheetsStaySheets() {
        let model = WindowModel(app: .shared)
        model.sheet = .settings
        XCTAssertEqual(model.sheet, .settings)
        model.sheet = nil
    }
}
