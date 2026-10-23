import XCTest

/// Swipe and long-press on sidebar rows, and the full-screen editor's way out, on the iPad
/// a real daemon and the stand-in `code serve-web`. Skipped without a ticket.
@MainActor
final class RowActionsUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/w3-ui-test.sh)")
        app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-noAutoFocus", "YES"]
        app.launch()
        let pane = panes.firstMatch
        if !pane.waitForExistence(timeout: 30) {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
    }

    private var panes: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func text(containing needle: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", needle, needle)).firstMatch
    }

    private var tabRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab-row-'"))
    }

    private func palette(_ command: String) {
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        panes.firstMatch.tap()
        app.typeKey("k", modifierFlags: .command)
        if !field.waitForExistence(timeout: 3) {
            element("open-palette").firstMatch.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the palette opens")
        field.typeText(command + "\n")
    }

    /// Swipes the row left: a full swipe runs `action` itself; a shorter one leaves its button
    /// showing, which is then tapped.
    private func swipeToRun(_ row: XCUIElement, _ action: String) {
        row.swipeLeft(velocity: .fast)
        let button = element("row-action-\(action)")
        if button.waitForExistence(timeout: 1), button.isHittable { button.tap() }
    }

    private func openEditor() {
        palette("Open in VS Code")
        let accept = element("editor-licence-accept")
        if accept.waitForExistence(timeout: 10) { accept.tap() }
        XCTAssertTrue(text(containing: "Fake VS Code workbench").waitForExistence(timeout: 40), "the workbench loads")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Tests

    /// The fixtures' shell sits in a repository, so its tabs list under their worktree; a second
    /// tab there gives each tab a row of its own.
    func testSwipeClosesATerminalTabAndUndoReopensIt() throws {
        try launch()
        panes.firstMatch.tap()
        app.typeKey("t", modifierFlags: .command)
        let second = element("worktree-tab-2")
        XCTAssertTrue(second.waitForExistence(timeout: 15), "a second tab")
        // The daemon keeps tabs across the suite's launches: count them, never trust a number.
        let tabs = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'worktree-tab-'"))
        let before = tabs.count
        let closing = second.label

        // Partway: the actions show behind the row, and a tap on it puts it back.
        let middle = second.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: -90, dy: 0)))
        let close = element("row-action-closeTab")
        XCTAssertTrue(close.waitForExistence(timeout: 2), "the swipe shows Close")
        shot("tab-swipe-open")
        second.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3), "a tap puts the row back")
        XCTAssertEqual(tabs.count, before, "nothing closed")

        swipeToRun(second, "closeTab")
        let gone = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'worktree-tab-' AND label == %@", closing)).firstMatch
        XCTAssertTrue(gone.waitForNonExistence(timeout: 10), "the tab closed")
        let undo = element("toast-action")
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "Undo is offered")
        undo.tap()
        expectation(for: NSPredicate(format: "count == %d", before), evaluatedWith: tabs)
        waitForExpectations(timeout: 15)
    }

    func testSwipeClosesAVSCodeEditorTabAndUndoReopensIt() throws {
        try launch()
        openEditor()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-row-' AND label CONTAINS 'VS Code on'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the editor's row in the sidebar")
        let web = element("editor-web")
        XCTAssertTrue(web.exists)

        swipeToRun(row, "closeEditor")
        XCTAssertTrue(web.waitForNonExistence(timeout: 10), "the editor closed")
        let undo = element("toast-action")
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "Undo is offered")
        undo.tap()
        XCTAssertTrue(text(containing: "Fake VS Code workbench").waitForExistence(timeout: 40), "the same folder came back")
        shot("editor-undo")
    }

    func testLongPressOffersTheSameActionsAsTheSwipe() throws {
        try launch()
        panes.firstMatch.tap()
        app.typeKey("t", modifierFlags: .command)
        let row = element("worktree-tab-2")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.press(forDuration: 1.2)
        let close = element("menu-closeTab")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Close Tab in the menu")
        XCTAssertTrue(element("menu-rename").exists, "Rename… in the menu")
        shot("tab-menu")
        // Dismissed without choosing: the tab stays.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.exists)
    }

    func testFullScreenEditorShowsItsWayOut() throws {
        try launch()
        openEditor()
        app.webViews.firstMatch.tap()
        app.typeKey("f", modifierFlags: [.command, .control])
        let view = element("editor-full-screen-view")
        XCTAssertTrue(view.waitForExistence(timeout: 5), "full screen")
        let exit = element("editor-exit-full-screen")
        XCTAssertTrue(exit.exists, "the way out shows without hovering")
        XCTAssertTrue(text(containing: "to exit full screen").exists, "the hint")
        shot("editor-full-screen")
        exit.tap()
        XCTAssertTrue(view.waitForNonExistence(timeout: 5), "back to the window")
    }
}
