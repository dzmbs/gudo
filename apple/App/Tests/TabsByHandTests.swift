#if os(macOS)
import AppKit
import HostKit
import XCTest
@testable import App

/// Tabs opened, closed, renamed, reordered and walked the way a person does it: keys, and
/// clicks on the sidebar's rows and their menus.
@MainActor
final class TabsByHandTests: XCTestCase {
    private var driver: WorkspaceDriver!

    override func setUp() async throws {
        driver = try await WorkspaceDriver.start()
    }

    override func tearDown() async throws {
        driver?.close()
        driver = nil
    }

    private var model: WindowModel { driver.model }

    /// The tabs as the sidebar lists them.
    private var rows: [TabRef] {
        model.sidebarItems(drop: nil, projectMove: nil).items.compactMap { item in
            model.groups.tabs.first { "tab/\($0)" == item.id }
        }
    }

    private func title(of ref: TabRef) throws -> String {
        let workspace = try driver.workspace
        let tab = try XCTUnwrap(workspace.session.tabs.first { $0.id == ref.tab })
        return workspace.title(of: tab)
    }

    /// The terminal on screen has the keyboard and belongs to `ref`.
    private func assertShowing(_ ref: TabRef, _ context: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(model.shownTab, ref, "shown tab, \(context)", file: file, line: line)
        let workspace = try driver.workspace
        let tab = try XCTUnwrap(workspace.session.tabs.first { $0.id == ref.tab }, file: file, line: line)
        let terminal = try XCTUnwrap(workspace.pane(tab.focused)?.view, file: file, line: line)
        XCTAssertNotNil(terminal.window, "its terminal is in the window, \(context)", file: file, line: line)
        XCTAssertTrue(driver.window.firstResponder === terminal, "its terminal has the keyboard, \(context): \(String(describing: driver.window.firstResponder))", file: file, line: line)
    }

    private func newTabs(_ count: Int) async {
        for _ in 0..<count {
            driver.command("t")
            await driver.settle()
        }
    }

    // MARK: New

    func testCommandTOpensATabThatTakesTheKeyboard() async throws {
        let before = rows
        driver.command("t")
        await driver.expect("a row for the new tab") { self.rows.count == before.count + 1 }
        await driver.settle()
        let added = try XCTUnwrap(rows.first { !before.contains($0) })
        XCTAssertEqual(rows.last, added, "the new tab is listed last")
        try assertShowing(added, "after ⌘T")
    }

    func testTheHostsPlusInTheSidebarOpensATerminalThere() async throws {
        let before = rows
        let header = try XCTUnwrap(driver.sidebarRowFrame("host/local"), "the host's header row")
        await driver.click(CGPoint(x: header.maxX - 20, y: header.midY - 4))
        await driver.expect("a row for the new tab") { self.rows.count == before.count + 1 }
        await driver.settle()
        let added = try XCTUnwrap(rows.first { !before.contains($0) })
        try assertShowing(added, "after the sidebar's +")
    }

    // MARK: Close

    func testCommandWClosesThePaneThenItsTab() async throws {
        await newTabs(1)
        let tabs = rows
        let closing = try XCTUnwrap(model.shownTab)
        driver.command("d")
        await driver.settle()
        XCTAssertEqual(try driver.workspace.session.activeTab?.root.panes.count, 2)

        driver.command("w")
        await driver.settle()
        XCTAssertEqual(try driver.workspace.session.activeTab?.root.panes.count, 1, "⌘W closes the focused pane first")
        XCTAssertEqual(rows, tabs, "and keeps its tab")

        driver.command("w")
        await driver.expect("the tab's row goes") { !self.rows.contains(closing) }
        await driver.settle()
        let shown = try XCTUnwrap(model.shownTab)
        XCTAssertTrue(rows.contains(shown))
        try assertShowing(shown, "after closing the tab")
    }

    func testCloseTabFromARowsMenu() async throws {
        await newTabs(1)
        let closing = rows[0]
        let titles = await driver.contextMenu(on: driver.sidebarRowFrame(of: closing), choose: ["Close Tab"])
        XCTAssertNotNil(titles, "a menu opens on the row")
        await driver.expect("the row goes") { !self.rows.contains(closing) }
    }

    func testClosingTheLastTabLeavesAnEmptyWindowThatCommandTFills() async throws {
        let only = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        driver.command("w")
        await driver.expect("the last row goes") { !self.rows.contains(only) }
        await driver.settle()
        XCTAssertNil(model.shownTab, "nothing is shown")
        XCTAssertNil(driver.terminal(), "no terminal is left on screen")

        driver.command("t")
        await driver.expect("a new tab") { self.rows.count == 1 }
        await driver.settle()
        try assertShowing(try XCTUnwrap(rows.first), "after ⌘T in the empty window")
    }

    func testCommandShiftTBringsTheClosedTabBackWhereItWas() async throws {
        await newTabs(2)
        let order = rows
        await driver.click(driver.sidebarRowFrame(of: order[1]))
        await driver.settle()
        driver.command("w")
        await driver.expect("the row goes") { self.rows.count == 2 }
        driver.command("t", .shift)
        await driver.expect("the row is back") { self.rows.count == 3 }
        await driver.settle()
        XCTAssertEqual(rows.count, 3)
        let reopened = rows[1]
        XCTAssertFalse([order[0], order[2]].contains(reopened), "the reopened tab is in its old place: \(rows)")
        try assertShowing(reopened, "after ⇧⌘T")
    }

    // MARK: Rename

    func testDoubleClickingARowRenamesItsTab() async throws {
        let ref = try XCTUnwrap(rows.first)
        await driver.click(driver.sidebarRowFrame(of: ref), count: 2)
        await driver.expect("the rename prompt opens") { self.driver.sheet != nil }
        await driver.answerSheet(typing: "build")
        await driver.expect("the prompt closes") { self.driver.sheet == nil }
        XCTAssertEqual(try title(of: ref), "build")
    }

    func testRenameFromARowsMenuAndAnEmptyNameLetsTheShellNameIt() async throws {
        let ref = try XCTUnwrap(rows.first)
        await driver.contextMenu(on: driver.sidebarRowFrame(of: ref), choose: ["Rename…"])
        await driver.expect("the rename prompt opens") { self.driver.sheet != nil }
        await driver.answerSheet(typing: "logs")
        await driver.expect("the prompt closes") { self.driver.sheet == nil }
        XCTAssertEqual(try title(of: ref), "logs")

        await driver.contextMenu(on: driver.sidebarRowFrame(of: ref), choose: ["Rename…"])
        await driver.expect("the rename prompt opens again") { self.driver.sheet != nil }
        await driver.answerSheet(typing: "")
        await driver.expect("the prompt closes") { self.driver.sheet == nil }
        let workspace = try driver.workspace
        let tab = try XCTUnwrap(workspace.session.tabs.first { $0.id == ref.tab })
        XCTAssertNil(tab.title, "an empty name leaves it no name of its own")
        XCTAssertNotEqual(try title(of: ref), "logs", "what its shell says names it")
    }

    func testAMixedTabsRenamePromptShowsItsNameEachTimeItOpens() async throws {
        let before = Set(model.sidebarItems(drop: nil, projectMove: nil).items.map(\.id))
        model.openBrowserTab()
        await driver.expect("a browser tab") { self.model.activeMixed != nil }
        await driver.settle()
        let row = try XCTUnwrap(model.sidebarItems(drop: nil, projectMove: nil).items.map(\.id).first { !before.contains($0) && $0.hasPrefix("tab/") }, "its row")
        let mixed = try XCTUnwrap(model.activeMixed?.id)

        await driver.contextMenu(on: driver.sidebarRowFrame(row), choose: ["Rename…"])
        await driver.expect("the rename prompt opens") { self.driver.sheet != nil }
        await driver.answerSheet(typing: "docs")
        await driver.expect("the prompt closes") { self.driver.sheet == nil }
        XCTAssertEqual(model.groups.composites.tab(mixed)?.title, "docs")

        await driver.contextMenu(on: driver.sidebarRowFrame(row), choose: ["Rename…"])
        await driver.expect("the rename prompt opens again") { self.driver.sheet != nil }
        await driver.pump(0.2)
        let field = (driver.sheet?.firstResponder as? NSTextView)?.string
        XCTAssertEqual(field, "docs", "the field holds the name Rename would keep")
        driver.press("\u{1B}", keyCode: 53)
    }

    // MARK: Order and selection

    func testMoveTabKeysReorderTheSidebarAndTheStrip() async throws {
        await newTabs(2)
        let order = rows
        await driver.click(driver.sidebarRowFrame(of: order[2]))
        await driver.settle()
        driver.press(String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), keyCode: 126, modifiers: [.command, .control, .shift])
        await driver.expect("the tab moves up one") { self.rows == [order[0], order[2], order[1]] }
        XCTAssertEqual(model.groups.tabs, rows, "⌘1…⌘9 and the strip follow the sidebar's order")
        try assertShowing(order[2], "after moving it")
    }

    func testCommandNumbersAndNextPreviousWalkTheTabs() async throws {
        await newTabs(3)
        let order = rows
        XCTAssertEqual(order.count, 4)
        driver.command("1")
        await driver.settle()
        try assertShowing(order[0], "⌘1")
        driver.command("3")
        await driver.settle()
        try assertShowing(order[2], "⌘3")
        driver.command("9")
        await driver.settle()
        try assertShowing(order[3], "⌘9 is the last tab")
        driver.command("]", .shift)
        await driver.settle()
        try assertShowing(order[0], "⇧⌘] wraps to the first")
        driver.command("[", .shift)
        await driver.settle()
        try assertShowing(order[3], "⇧⌘[ wraps to the last")
        driver.command("[", .shift)
        await driver.settle()
        try assertShowing(order[2], "⇧⌘[ again")
    }

    func testClickingRowsShowsTheirTabs() async throws {
        await newTabs(2)
        let order = rows
        for ref in [order[0], order[2], order[1]] {
            await driver.click(driver.sidebarRowFrame(of: ref))
            await driver.settle()
            try assertShowing(ref, "after clicking its row")
        }
    }
}
#endif
