#if os(iOS)
import XCTest

/// The agent-fleet polish on the design fixtures (`-mock`): agent toasts, the Inbox's filters and
/// keys, approve-all and its revoke, and Settings search. The same flows against a real daemon
/// and the stand-in Claude are `AgentApprovalsUITests` (apple/scripts/w3-ui-test.sh).
@MainActor
final class AgentFleetUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch(screen: String) {
        app = XCUIApplication()
        app.launchArguments += ["-mock", "-screen", screen, "-restoreLastTarget", "NO"]
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The simulator drops the first hardware key event after launch.
    private func wakeKeyboard() {
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
    }

    // MARK: Toasts

    func testAgentToastsApproveAndOpen() {
        launch(screen: "agent-toast")
        let approve = element("agent-toast-approve-a3")
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "a toast for the agent that needs you")
        let open = element("agent-toast-open-a4")
        XCTAssertTrue(open.waitForExistence(timeout: 5), "and one for the agent that finished")
        shot("agent-toasts")
        approve.tap()
        XCTAssertTrue(approve.waitForNonExistence(timeout: 5), "approved from the toast: its card goes")
        // The finished agent's card leaves by itself after 8 s.
        XCTAssertTrue(open.waitForNonExistence(timeout: 12), "the toast times out")
    }

    // MARK: Inbox

    func testInboxFiltersCountAndNarrowTheList() {
        launch(screen: "inbox")
        XCTAssertTrue(element("inbox-a1").waitForExistence(timeout: 10))
        let errors = element("inbox-filter-errors")
        XCTAssertTrue(errors.exists)
        XCTAssertEqual(errors.label, "Errors, 1")
        errors.tap()
        XCTAssertTrue(element("inbox-a6").waitForExistence(timeout: 3))
        XCTAssertFalse(element("inbox-a1").exists, "only failures")
        element("inbox-filter-running").tap()
        XCTAssertTrue(element("inbox-a3").waitForExistence(timeout: 3))
        XCTAssertTrue(element("inbox-a4").exists)
        XCTAssertFalse(element("inbox-a6").exists)
        element("inbox-filter-needsYou").tap()
        XCTAssertTrue(element("inbox-a1").waitForExistence(timeout: 3))
        XCTAssertTrue(element("inbox-a2").exists)
        XCTAssertFalse(element("inbox-a3").exists)
        shot("inbox-needs-you")
        element("inbox-filter-all").tap()
        XCTAssertTrue(element("inbox-a6").waitForExistence(timeout: 3))
    }

    /// The keyboard on the first row (the permission request).
    private func focusFirstRow() -> XCUIElement {
        let row = element("inbox-a1")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        wakeKeyboard()
        // ↑ until the first row has the keyboard (from nothing, ↑ picks the last row).
        for _ in 0..<10 where (row.value as? String) != "focused" {
            app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        }
        XCTAssertEqual(row.value as? String, "focused")
        return row
    }

    func testInboxKeysMoveAndApprove() {
        launch(screen: "inbox")
        let row = focusFirstRow()
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        XCTAssertEqual(element("inbox-a2").value as? String, "focused", "↓ moves to the next row")
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        XCTAssertEqual(row.value as? String, "focused", "↑ moves back")
        let approve = element("inbox-approve-a1")
        XCTAssertTrue(approve.exists)
        app.typeKey("\n", modifierFlags: [])
        XCTAssertTrue(approve.waitForNonExistence(timeout: 5), "↩ approves")
        XCTAssertTrue(element("inbox-a2").exists, "only once: still in the Inbox")
    }

    func testInboxEditKeyOpensAndCancels() {
        launch(screen: "inbox")
        _ = focusFirstRow()
        // E: edit the command, ⌘. puts it back.
        app.typeKey("e", modifierFlags: [])
        let field = element("inbox-edit-field")
        XCTAssertTrue(field.waitForExistence(timeout: 3), "E opens the command for editing")
        shot("inbox-edit")
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(field.waitForNonExistence(timeout: 3), "⌘. cancels the edit")
        XCTAssertTrue(element("inbox-approve-a1").exists, "nothing was approved")
        // ↩ still answers the row afterwards.
        app.typeKey("\n", modifierFlags: [])
        XCTAssertTrue(element("inbox-approve-a1").waitForNonExistence(timeout: 5), "↩ approves after an edit was cancelled")
    }

    func testApproveAllLikeThisShowsTheRuleAndRevokes() {
        launch(screen: "inbox")
        let menu = element("inbox-approve-menu-a1")
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let all = app.buttons["Approve All Like This for This Task"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 3))
        all.tap()
        XCTAssertTrue(element("inbox-approve-a1").waitForNonExistence(timeout: 5), "this request is approved too")
        let rules = app.descendants(matching: .any).matching(identifier: "inbox-auto-approval")
        // The renderer agent's standing rule, and now this one.
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rules)
        waitForExpectations(timeout: 5)
        shot("inbox-auto-approval")
        let revoke = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'inbox-revoke-' AND identifier != 'inbox-revoke-r1'")).firstMatch
        XCTAssertTrue(revoke.exists)
        revoke.tap()
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: rules)
        waitForExpectations(timeout: 5)
    }

    // MARK: Settings search

    func testSettingsSearchFindsAGhosttyKeyAndJumpsToItsRow() {
        launch(screen: "settings")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("bell-features")
        let result = element("settings-result-bell-features")
        XCTAssertTrue(result.waitForExistence(timeout: 3), "found by its Ghostty key")
        shot("settings-search")
        result.tap()
        XCTAssertTrue(result.waitForNonExistence(timeout: 3), "the results close")
        let row = app.staticTexts["Flash Border on Bell"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: row)
        waitForExpectations(timeout: 3)

        search.tap()
        search.typeText("no such setting")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No Results'")).firstMatch.waitForExistence(timeout: 3))
    }
}
#endif
