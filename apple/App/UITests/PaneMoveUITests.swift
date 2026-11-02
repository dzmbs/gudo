#if os(iOS)
import XCTest

/// New Agent opens its own tab, and panes move between tabs (Move to New Tab, Merge Into Tab, a
/// tab dropped on a pane's edge) against a real `gudo-hostd` (apple/scripts/w3-ui-test.sh
/// with `UI_TEST_CLASS=PaneMoveUITests`). Skipped without a ticket.
@MainActor
final class PaneMoveUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/w3-ui-test.sh)")
        app = XCUIApplication()
        // The strip instead of the sidebar, for this launch only (arguments are not saved).
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-noAutoFocus", "YES", "-sidebarShown", "<false/>"]
        app.launch()
        if !panes.firstMatch.waitForExistence(timeout: 30) {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 30), "a daemon pane appears")
        panes.firstMatch.tap()
        // The first key after launch is dropped.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        XCTAssertTrue(element("tab-bar").waitForExistence(timeout: 5))
    }

    private var panes: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    /// The tab strip's tabs (the sidebar groups tabs by worktree; the strip lists each once).
    private var tabRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tabbar-'"))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func expectCount(_ query: XCUIElementQuery, _ count: Int, _ message: String) {
        let done = expectation(for: NSPredicate(format: "count == %d", count), evaluatedWith: query)
        done.expectationDescription = message
        wait(for: [done], timeout: 20)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Closes every tab past the first `count`.
    private func closeExtraTabs(keeping count: Int) {
        while tabRows.count > count {
            app.typeKey("9", modifierFlags: .command)
            app.typeKey("w", modifierFlags: .command)
            _ = tabRows.element(boundBy: count).waitForNonExistence(timeout: 2)
        }
    }

    /// New Agent starts in a tab of its own, in front, not in a split of the focused pane; the
    /// sheet's first frame is already its final layout.
    func testNewAgentOpensInItsOwnTab() throws {
        try launch()
        let tabs = tabRows.count
        app.typeKey("n", modifierFlags: [.command, .shift])
        let runner = element("task-runner")
        XCTAssertTrue(runner.waitForExistence(timeout: 5))
        let frame = runner.frame
        shot("new-agent-first")
        let worktree = app.switches["task-worktree"].firstMatch
        XCTAssertTrue(worktree.waitForExistence(timeout: 5))
        // Nothing moves once the host has said which agents it has.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(runner.frame, frame, "the agent picker stays put")
        shot("new-agent-settled")
        if worktree.value as? String == "1" {
            worktree.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        let prompt = app.descendants(matching: .any).matching(identifier: "launch-prompt").firstMatch
        prompt.tap()
        prompt.typeText("hello")
        element("launch-start").tap()
        expectCount(tabRows, tabs + 1, "the agent has its own tab")
        let screen = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ENDSWITH '-screen' AND value CONTAINS 'prompt: hello'")).firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "the agent's tab is in front and got its prompt")
        XCTAssertEqual(panes.count, 1, "no split")
        shot("agent-tab")
        closeExtraTabs(keeping: tabs)
    }

    /// ⇧⌘T moves the focused pane to a new tab; Merge Into Tab brings it back as a split; the
    /// pane menu moves it out again.
    func testMovePaneToNewTabAndMergeBack() throws {
        try launch()
        let tabs = tabRows.count
        app.typeKey("d", modifierFlags: .command)
        expectCount(panes, 2, "split")
        app.typeKey("t", modifierFlags: [.command, .shift])
        expectCount(tabRows, tabs + 1, "the pane has its own tab")
        expectCount(panes, 1, "and is alone in it")
        shot("moved-to-new-tab")

        tabRows.element(boundBy: tabs).press(forDuration: 1)
        let merge = app.buttons["Merge Into Tab"].firstMatch
        XCTAssertTrue(merge.waitForExistence(timeout: 5), "the tab's menu offers Merge Into Tab")
        merge.tap()
        let target = app.collectionViews.buttons.firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        expectCount(tabRows, tabs, "merged: the tab is gone")
        expectCount(panes, 2, "its pane is a split again")

        app.buttons.matching(NSPredicate(format: "label == 'Pane Menu'")).element(boundBy: 1).tap()
        let move = element("pane-move-new-tab")
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        move.tap()
        expectCount(tabRows, tabs + 1, "moved out from the pane menu")
        closeExtraTabs(keeping: tabs)
    }

    /// A tab dragged onto a pane's right edge merges there, with that half lit while it hovers.
    func testTabDroppedOnAPaneEdgeMergesThere() throws {
        try launch()
        let tabs = tabRows.count
        app.typeKey("t", modifierFlags: .command)
        expectCount(tabRows, tabs + 1, "a second tab")
        app.typeKey("1", modifierFlags: .command)
        let pane = panes.firstMatch
        let dragged = String(tabRows.element(boundBy: tabs).identifier.dropFirst("tabbar-".count))
        // A hold can open the tab's menu instead of lifting it: dismiss and drag again.
        for _ in 0..<3 where tabRows.count > tabs {
            tabRows.element(boundBy: tabs).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: 0.6, thenDragTo: pane.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)),
                withVelocity: .default, thenHoldForDuration: 0.8)
            if tabRows.element(boundBy: tabs).waitForNonExistence(timeout: 3) { break }
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
        expectCount(tabRows, tabs, "the dropped tab merged")
        expectCount(panes, 2, "beside the pane")
        let frames = panes.allElementsBoundByIndex.map(\.frame).sorted { $0.minX < $1.minX }
        XCTAssertLessThan(frames[0].maxX, frames[1].minX + 1, "side by side")
        for screen in panes.allElementsBoundByIndex.map({ element($0.identifier + "-screen") }) {
            XCTAssertFalse((screen.value as? String ?? "").contains(dragged), "the terminal under the drop did not paste the tab")
        }
        shot("merged-by-drop")
        app.typeKey("w", modifierFlags: .command)
        expectCount(panes, 1, "closed")
    }
}
#endif
