#if os(macOS)
import AppKit
import PaneLayout
import XCTest
@testable import App

/// Panes split, focused, zoomed, resized, floated, docked, minimized, restored, rearranged and
/// closed the way a person does it: keys, clicks on a pane and its header, the header's menu,
/// drags of a divider and of a header.
@MainActor
final class PanesByHandTests: XCTestCase {
    private var driver: WorkspaceDriver!

    override func setUp() async throws {
        driver = try await WorkspaceDriver.start()
    }

    override func tearDown() async throws {
        driver?.close()
        driver = nil
    }

    private var model: WindowModel { driver.model }

    private func tab() throws -> Tab { try XCTUnwrap(try driver.workspace.session.activeTab) }

    private func panes() throws -> [PaneId] { try tab().root.panes }

    private func focused() throws -> PaneId { try XCTUnwrap(try driver.workspace.focusedPane) }

    private func frame(of pane: PaneId, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let view = try XCTUnwrap(driver.terminal(of: pane), "pane \(pane) has a terminal", file: file, line: line)
        XCTAssertNotNil(view.window, "pane \(pane) is in the window", file: file, line: line)
        return driver.frame(of: view)
    }

    /// Where a pane's header is: the band over its terminal.
    private func header(of pane: PaneId) throws -> CGRect {
        let terminal = try frame(of: pane)
        return CGRect(x: terminal.minX, y: terminal.maxY, width: terminal.width, height: PaneHeader.height)
    }

    private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// The pane has the focus, the keyboard, and what is typed shows in it.
    private func assertTypingGoes(to pane: PaneId, _ context: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(try focused(), pane, "focused, \(context)", file: file, line: line)
        let terminal = try XCTUnwrap(driver.terminal(of: pane), file: file, line: line)
        XCTAssertTrue(driver.window.firstResponder === terminal, "has the keyboard, \(context): \(String(describing: driver.window.firstResponder))", file: file, line: line)
        let marker = "q\(Int.random(in: 100...999))"
        driver.type(marker)
        let workspace = try driver.workspace
        await driver.expect("\(marker) shows in the pane, \(context)", file: file, line: line) {
            workspace.pane(pane)?.view.surface.terminal.visibleText().contains(marker) ?? false
        }
    }

    /// A canvas rectangle (top-left origin, the panes' own space) in window coordinates, found
    /// from where a tiled pane's terminal is.
    private func windowRect(fromCanvas rect: CGRect) throws -> CGRect {
        let layout = try XCTUnwrap(model.arrangement.layout)
        let (pane, leafFrame) = try XCTUnwrap(layout.tiled.first)
        let terminal = try frame(of: pane)
        let header = leafFrame.height - terminal.height
        let originX = terminal.minX - leafFrame.minX
        let top = terminal.maxY + header + leafFrame.minY
        return CGRect(x: originX + rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Split

    func testSplitRightThenDownAndTheNewPaneTakesTheKeyboard() async throws {
        let first = try focused()
        driver.command("d")
        await driver.expect("two panes") { (try? self.panes().count) == 2 }
        await driver.settle()
        let right = try focused()
        XCTAssertNotEqual(right, first)
        XCTAssertGreaterThanOrEqual(try frame(of: right).minX, try frame(of: first).maxX, "the new pane is on the right")
        XCTAssertEqual(try frame(of: right).minY, try frame(of: first).minY, accuracy: 1)
        try await assertTypingGoes(to: right, "after ⌘D")

        driver.command("d", .shift)
        await driver.expect("three panes") { (try? self.panes().count) == 3 }
        await driver.settle()
        let below = try focused()
        XCTAssertLessThanOrEqual(try frame(of: below).maxY, try frame(of: right).minY + 1, "the new pane is below")
        XCTAssertEqual(try frame(of: below).minX, try frame(of: right).minX, accuracy: 1)
        try await assertTypingGoes(to: below, "after ⇧⌘D")
    }

    func testBestFitSplitsAlongTheLongerSide() async throws {
        driver.press("\r", keyCode: 36, modifiers: .command)
        await driver.expect("two panes") { (try? self.panes().count) == 2 }
        await driver.settle()
        let panes = try panes()
        XCTAssertGreaterThanOrEqual(try frame(of: panes[1]).minX, try frame(of: panes[0]).maxX, "a wide pane splits right")

        driver.press("\r", keyCode: 36, modifiers: .command)
        await driver.expect("three panes") { (try? self.panes().count) == 3 }
        await driver.settle()
        let newest = try focused()
        let tall = try frame(of: newest)
        XCTAssertLessThan(tall.height, try frame(of: panes[0]).height, "a tall, narrow pane splits down: \(tall)")
    }

    func testTheHeadersMenuSplitsThatPane() async throws {
        driver.command("d")
        await driver.settle()
        let left = try XCTUnwrap(try panes().first)
        await driver.contextMenu(on: try header(of: left), choose: ["Split Down"])
        await driver.expect("three panes") { (try? self.panes().count) == 3 }
        await driver.settle()
        let newest = try focused()
        XCTAssertEqual(try frame(of: newest).minX, try frame(of: left).minX, accuracy: 1, "split under the pane whose menu it was")
        XCTAssertLessThan(try frame(of: newest).maxY, try frame(of: left).minY + 1)
    }

    // MARK: Focus

    func testClickingAPaneOrItsHeaderFocusesItAndTypingGoesThere() async throws {
        let first = try focused()
        driver.command("d")
        await driver.settle()
        let second = try focused()
        await driver.click(center(try frame(of: first)))
        await driver.settle()
        try await assertTypingGoes(to: first, "after clicking its terminal")
        await driver.click(center(try header(of: second)))
        await driver.settle()
        try await assertTypingGoes(to: second, "after clicking its header")
    }

    func testFocusKeysWalkThePanes() async throws {
        let first = try focused()
        driver.command("d")
        await driver.settle()
        let second = try focused()
        driver.command("[")
        await driver.settle()
        try await assertTypingGoes(to: first, "⌘[")
        driver.command("]")
        await driver.settle()
        try await assertTypingGoes(to: second, "⌘]")
        driver.press(String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), keyCode: 123, modifiers: [.command, .option])
        await driver.settle()
        try await assertTypingGoes(to: first, "⌥⌘←")
        driver.press(String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), keyCode: 124, modifiers: [.command, .option])
        await driver.settle()
        try await assertTypingGoes(to: second, "⌥⌘→")
    }

    // MARK: Zoom

    func testZoomByKeysAndByDoubleClickingTheHeader() async throws {
        let first = try focused()
        let alone = try frame(of: first)
        driver.command("d")
        await driver.settle()
        let second = try focused()
        let split = try frame(of: second)

        driver.press("\r", keyCode: 36, modifiers: [.command, .shift])
        await driver.expect("zoomed") { (try? self.tab().zoomed) == second }
        await driver.settle()
        let zoomed = try frame(of: second)
        XCTAssertEqual(zoomed.width, alone.width, accuracy: 2, "the zoomed pane fills the tab")
        let underneath = try XCTUnwrap(driver.terminal(of: first))
        XCTAssertFalse(driver.hit(at: CGPoint(x: alone.minX + 40, y: alone.midY))?.isDescendant(of: underneath) ?? false,
                       "the pane under it takes no clicks")
        try await assertTypingGoes(to: second, "zoomed")

        driver.press("\r", keyCode: 36, modifiers: [.command, .shift])
        await driver.expect("unzoomed") { (try? self.tab().zoomed) == nil }
        await driver.settle()
        XCTAssertEqual(try frame(of: second).width, split.width, accuracy: 2)

        await driver.click(try header(of: first), count: 2)
        await driver.expect("the header's double-click zooms its pane") { (try? self.tab().zoomed) == first }
        await driver.settle()
        try await assertTypingGoes(to: first, "zoomed from its header")
        await driver.click(try header(of: first), count: 2)
        await driver.expect("and back") { (try? self.tab().zoomed) == nil }
    }

    // MARK: Dividers

    func testDraggingTheDividerResizesBothPanesAndADoubleClickEvensThem() async throws {
        driver.command("d")
        await driver.settle()
        let panes = try panes()
        let left = try frame(of: panes[0])
        let right = try frame(of: panes[1])
        let line = CGPoint(x: (left.maxX + right.minX) / 2, y: left.midY)
        await driver.drag(from: line, to: CGPoint(x: line.x - 150, y: line.y))
        await driver.settle()
        XCTAssertEqual(try frame(of: panes[0]).width, left.width - 150, accuracy: 3, "the left pane gives the room")
        XCTAssertEqual(try frame(of: panes[1]).width, right.width + 150, accuracy: 3, "the right pane takes it")
        let columns = try XCTUnwrap(try driver.workspace.pane(panes[0])?.view.surface.grid?.cols)

        let moved = CGPoint(x: line.x - 150, y: line.y)
        await driver.click(moved, count: 2)
        await driver.expect("a double-click evens the split") { abs(((try? self.frame(of: panes[0]).width) ?? 0) - left.width) < 3 }
        await driver.settle()
        XCTAssertEqual(try frame(of: panes[0]).width, left.width, accuracy: 3)
        XCTAssertGreaterThan(try XCTUnwrap(try driver.workspace.pane(panes[0])?.view.surface.grid?.cols), columns, "its terminal has the columns back")
    }

    // MARK: Close

    func testClosePaneFromItsHeadersMenuGivesItsRoomToTheOther() async throws {
        let first = try focused()
        let alone = try frame(of: first)
        driver.command("d")
        await driver.settle()
        let second = try focused()
        await driver.contextMenu(on: try header(of: second), choose: ["Close Pane"])
        await driver.expect("one pane") { (try? self.panes()) == [first] }
        await driver.settle()
        XCTAssertEqual(try frame(of: first).width, alone.width, accuracy: 2, "the pane left fills the tab again")
        try await assertTypingGoes(to: first, "after the other pane closed")
    }

    // MARK: Floating

    func testFloatMinimizeRestoreAndDock() async throws {
        let first = try focused()
        driver.command("d")
        await driver.settle()
        let second = try focused()

        driver.press("\r", keyCode: 36, modifiers: [.command, .option])
        await driver.expect("the pane floats") { (try? self.driver.workspace.window(of: second)) != nil }
        await driver.settle()
        let floating = try frame(of: second)
        let tiled = try frame(of: first)
        XCTAssertTrue(tiled.contains(center(floating)), "the window floats over the tab's pane")
        XCTAssertTrue(driver.hit(at: center(floating))?.isDescendant(of: try XCTUnwrap(driver.terminal(of: second))) ?? false,
                      "the window takes clicks over the pane under it")
        try await assertTypingGoes(to: second, "floating")

        driver.press("m", keyCode: 46, modifiers: [.command, .shift])
        await driver.expect("the window goes to the tray") { (try? self.driver.workspace.window(of: second)?.minimized) == true }
        await driver.settle()
        XCTAssertFalse(driver.hit(at: center(floating))?.isDescendant(of: try XCTUnwrap(driver.terminal(of: second))) ?? false,
                       "a minimized window is out of sight")
        let chip = try XCTUnwrap(model.arrangement.layout?.chips.first, "a tray chip stands in for it")
        await driver.click(try windowRect(fromCanvas: chip.frame))
        await driver.expect("the chip brings it back") { (try? self.driver.workspace.window(of: second)?.minimized) == false }
        await driver.settle()
        XCTAssertNotNil(driver.terminal(of: second)?.window)

        await driver.contextMenu(on: try header(of: second), choose: ["Dock Pane"])
        await driver.expect("the pane docks") { (try? self.driver.workspace.window(of: second)) == nil && (try? self.panes().count) == 2 }
        await driver.settle()
        XCTAssertFalse(try frame(of: first).intersects(try frame(of: second).insetBy(dx: 2, dy: 2)), "docked, the panes sit side by side")
    }

    // MARK: Rearranging

    func testDraggingAHeaderOntoAnotherPanesBottomStacksThem() async throws {
        let first = try focused()
        driver.command("d")
        await driver.settle()
        let second = try focused()
        let target = try frame(of: second)
        let start = center(try header(of: first))
        let end = CGPoint(x: target.midX, y: target.minY + target.height * 0.1)
        await driver.drag(from: start, to: end, steps: 20, holdAtEnd: 0.3)
        await driver.expect("the pane moves under the other") {
            guard let top = try? self.frame(of: second), let bottom = try? self.frame(of: first) else { return false }
            return bottom.maxY <= top.minY + 1 && abs(bottom.minX - top.minX) < 2
        }
        await driver.settle()
        XCTAssertEqual(try panes().count, 2)
        XCTAssertNil(try driver.workspace.window(of: first), "it docks, it does not float")
    }

    // MARK: Pages beside terminals

    func testABrowserPageBesideATerminalAndTheTerminalTakesItsClickBack() async throws {
        let terminal = try focused()
        driver.press("b", keyCode: 11, modifiers: [.command, .option, .shift])
        await driver.expect("a page opens beside the pane") { (self.model.activeMixed?.leaves.count ?? 0) == 2 }
        await driver.settle()
        await driver.click(center(try frame(of: terminal)))
        await driver.settle()
        XCTAssertTrue(driver.window.firstResponder === driver.terminal(of: terminal), "the terminal has the keyboard back")
        let marker = "q\(Int.random(in: 100...999))"
        driver.type(marker)
        let workspace = try driver.workspace
        await driver.expect("typing shows in the terminal") { workspace.pane(terminal)?.view.surface.terminal.visibleText().contains(marker) ?? false }
    }
}
#endif
