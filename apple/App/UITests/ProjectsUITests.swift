#if os(iOS)
import XCTest

/// Projects in the iPad sidebar against a real daemon (apple/scripts/projects-ui-test.sh passes
/// its ticket): New Project from Tab, Move to Project, rename, collapse, ungroup, and a tab
/// dragged onto another groups the two. Skipped without a ticket and on iPhone.
@MainActor
final class ProjectsUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func projects(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'project-' AND NOT identifier BEGINSWITH 'project-new-tab-' AND NOT identifier BEGINSWITH 'project-suggestion-'"))
    }

    private func waitFor(_ predicate: NSPredicate, _ object: Any, timeout: TimeInterval, _ message: String = "") {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func menu(_ app: XCUIApplication, on target: XCUIElement, _ item: String) {
        target.press(forDuration: 1.2)
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "menu item \(item)")
        button.tap()
    }

    private func launch() throws -> XCUIApplication {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "the sidebar is iPad")
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/projects-ui-test.sh)")
        let app = XCUIApplication()
        app.launchArguments += [
            "-testTicket", ticket, "-testRelay", "disabled", "-restoreLastTarget", "NO", "-sidebarShown", "YES",
            "-hostsDirectory", NSTemporaryDirectory() + "projects-\(ticket.suffix(12))",
        ]
        app.launch()
        return app
    }

    /// Three tabs; the first becomes a project, the second moves into it, it is renamed,
    /// collapsed (its rows leave, the count shows) and ungrouped (the tabs stay open).
    func testProjectMenusRenameCollapseUngroup() throws {
        let app = try launch()
        let row1 = element(app, "tab-row-1")
        XCTAssertTrue(row1.waitForExistence(timeout: 40), "the daemon's tab")
        for number in 2...3 {
            app.typeKey("t", modifierFlags: .command)
            XCTAssertTrue(element(app, "tab-row-\(number)").waitForExistence(timeout: 20), "tab \(number)")
        }

        menu(app, on: row1, "New Project from Tab")
        let project = projects(app).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10), "a project header")
        let name = String(project.identifier.dropFirst("project-".count))
        shot(app, "projects-created")

        menu(app, on: element(app, "tab-row-2"), "Move to Project")
        let target = app.buttons[name].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), "the project is offered")
        target.tap()
        waitFor(NSPredicate(format: "label CONTAINS '2 tabs'"), project, timeout: 10, "two tabs in the project")
        shot(app, "projects-moved")

        menu(app, on: project, "Rename…")
        let field = app.textFields["Name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "rename in place")
        field.doubleTap()
        app.typeKey("a", modifierFlags: .command)
        field.typeText("Work\n")
        let renamed = element(app, "project-Work")
        XCTAssertTrue(renamed.waitForExistence(timeout: 10), "renamed")
        shot(app, "projects-renamed")

        // Collapse: the project's rows leave the list; the third (loose) tab stays.
        renamed.tap()
        waitFor(NSPredicate(format: "count == 1"), app.descendants(matching: .any).matching(identifier: "tab-row-3"), timeout: 5)
        waitFor(NSPredicate(format: "exists == false"), element(app, "tab-row-1"), timeout: 5, "collapsed rows hidden")
        shot(app, "projects-collapsed")
        renamed.tap()
        XCTAssertTrue(element(app, "tab-row-1").waitForExistence(timeout: 5), "expanded again")

        menu(app, on: renamed, "Ungroup")
        XCTAssertTrue(renamed.waitForNonExistence(timeout: 10), "project gone")
        for number in 1...3 { XCTAssertTrue(element(app, "tab-row-\(number)").exists, "tab \(number) still open") }
        shot(app, "projects-ungrouped")
    }

    /// This iPad's own tabs (local echo): no daemon needed.
    private func launchLocal() throws -> XCUIApplication {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "the sidebar is iPad")
        let app = XCUIApplication()
        app.launchArguments += [
            "-localEcho", "YES", "-restoreLastTarget", "NO", "-sidebarShown", "YES",
            "-hostsDirectory", NSTemporaryDirectory() + "projects-local-\(UUID().uuidString)",
        ]
        app.launch()
        XCTAssertTrue(element(app, "tab-row-1").waitForExistence(timeout: 20), "this iPad's tab")
        return app
    }

    /// A cell of the pane's grid (8×17 pt cells, 2 pt padding).
    private func cellPoint(_ pane: XCUIElement, x: Int, y: Int) -> XCUICoordinate {
        pane.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2 + (CGFloat(x) + 0.5) * 8, dy: 2 + (CGFloat(y) + 0.5) * 17))
    }

    /// A project header let go over a terminal is not pasted into it as text.
    func testProjectHeaderDroppedOnTerminalIsNotPasted() throws {
        let app = try launchLocal()
        menu(app, on: element(app, "tab-row-1"), "New Project from Tab")
        let project = projects(app).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        let pane = element(app, "pane-1")
        XCTAssertTrue(pane.exists)
        project.press(forDuration: 1.0, thenDragTo: pane, withVelocity: .slow, thenHoldForDuration: 0.5)
        sleep(2)
        shot(app, "projects-header-on-terminal")
        let screen = element(app, "pane-1-screen")
        XCTAssertFalse((screen.value as? String ?? "").contains("project:"), "the header's drag text was pasted")
    }

    /// A tab drag that ends nowhere leaves nothing behind: text dragged onto the sidebar later
    /// (a terminal selection here, another app's text alike) does not move that tab.
    func testCancelledTabDragIsForgotten() throws {
        let app = try launchLocal()
        app.typeKey("t", modifierFlags: .command)
        let row2 = element(app, "tab-row-2")
        XCTAssertTrue(row2.waitForExistence(timeout: 10))
        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        // Tab 2 let go on its own pane: refused, the drag ends.
        row2.press(forDuration: 1.0, thenDragTo: pane, withVelocity: .slow, thenHoldForDuration: 0.5)
        sleep(1)
        // Select the banner's first word and drag the selection onto tab 1's row.
        cellPoint(pane, x: 3, y: 0).press(forDuration: 0.8)
        XCTAssertTrue(element(app, "selection-start-handle").waitForExistence(timeout: 5), "a selection")
        cellPoint(pane, x: 3, y: 0).press(forDuration: 1.0, thenDragTo: element(app, "tab-row-1").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.6)
        sleep(2)
        shot(app, "projects-text-on-sidebar")
        XCTAssertEqual(projects(app).count, 0, "the old tab drag made a project")
    }

    /// A tab dropped on the middle of another groups them in a new project; the dragged row is
    /// never left drawn twice.
    func testDropTabOnTabMakesProject() throws {
        let app = try launch()
        XCTAssertTrue(element(app, "tab-row-1").waitForExistence(timeout: 40))
        app.typeKey("t", modifierFlags: .command)
        let row2 = element(app, "tab-row-2")
        XCTAssertTrue(row2.waitForExistence(timeout: 20))
        let row1 = element(app, "tab-row-1")
        row2.press(forDuration: 1.0, thenDragTo: row1, withVelocity: .slow, thenHoldForDuration: 0.6)
        let project = projects(app).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10), "dropping on a tab makes a project")
        waitFor(NSPredicate(format: "label CONTAINS '2 tabs'"), project, timeout: 10)
        shot(app, "projects-dropped")
    }
}
#endif
