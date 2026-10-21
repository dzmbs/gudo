#if os(iOS)
import XCTest

/// Agent toasts and the approval verbs against a real `unnamed-hostd` and the stand-in `claude`
/// (apple/scripts/w3-ui-test.sh with `UI_TEST_CLASS=AgentApprovalsUITests`): its
/// PermissionRequest hook asks to run `rm -rf build` when a prompt says "permission", and prints
/// what the hook answered. Skipped without a ticket.
@MainActor
final class AgentApprovalsUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

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
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func element(prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    /// An agent pane's screen showing `needle`.
    private func agentScreen(containing needle: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ENDSWITH '-screen' AND value CONTAINS %@", needle)).firstMatch
    }

    private func occurrences(of needle: String) -> Int {
        let value = (agentScreen(containing: needle).value as? String) ?? ""
        return value.components(separatedBy: needle).count - 1
    }

    private func palette(_ command: String) {
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        panes.firstMatch.tap()
        app.typeKey("k", modifierFlags: .command)
        if !field.waitForExistence(timeout: 3) { element("open-palette").tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the palette opens")
        field.typeText(command + "\n")
    }

    /// New Task with `prompt` beside the shell (no worktree); waits for the agent's pane.
    private func startAgent(_ prompt: String) {
        palette("New Task")
        let field = app.textViews.matching(identifier: "launch-prompt").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(prompt)
        let worktree = app.switches["task-worktree"].firstMatch
        XCTAssertTrue(worktree.waitForExistence(timeout: 5))
        if worktree.value as? String == "1" {
            worktree.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        let before = panes.count
        element("launch-start").tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 20))
        expectation(for: NSPredicate(format: "count == %d", before + 1), evaluatedWith: panes)
        waitForExpectations(timeout: 20)
    }

    /// Replies to the agent from the Inbox (its turn has finished).
    private func reply(_ text: String) {
        element("inbox-filter-all").tap()
        let button = element(prefix: "inbox-reply-")
        XCTAssertTrue(button.waitForExistence(timeout: 30), "the turn finished")
        button.tap()
        let composer = element("inbox-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        if (composer.value(forKey: "hasKeyboardFocus") as? Bool) != true { composer.tap() }
        composer.typeText(text)
        element("inbox-send").tap()
        XCTAssertTrue(composer.waitForNonExistence(timeout: 15))
    }

    /// Only the waiting agent listed, and the keyboard on it (↑ from nothing picks the last row).
    private func focusRequest() {
        element("inbox-filter-needsYou").tap()
        XCTAssertTrue(element(prefix: "inbox-approve-").waitForExistence(timeout: 30))
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func closeAgentPane() {
        let screen = agentScreen(containing: "prompt:")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.typeKey("1", modifierFlags: .command)
        if screen.waitForExistence(timeout: 5) { screen.tap() }
        app.typeKey("w", modifierFlags: .command)
    }

    // MARK: Tests

    /// The agent asks while another tab is in front: a toast with Approve.
    func testToastApprovesAnAgentOnAnotherTab() throws {
        try launch()
        startAgent("slowly ask permission")
        // A new tab in front before the agent asks (the stand-in waits 4 s).
        app.typeKey("t", modifierFlags: .command)
        let approve = element(prefix: "agent-toast-approve-")
        XCTAssertTrue(approve.waitForExistence(timeout: 30), "the toast says the agent needs you")
        shot("toast-needs-you")
        approve.tap()
        XCTAssertTrue(approve.waitForNonExistence(timeout: 5))
        // Its turn ends a moment later; the agent is still on another tab: a "finished" toast.
        let open = element(prefix: "agent-toast-open-")
        XCTAssertTrue(open.waitForExistence(timeout: 30), "the finished toast")
        open.tap()
        XCTAssertTrue(agentScreen(containing: "decision: allowed").waitForExistence(timeout: 15), "the approval reached the agent")
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("1", modifierFlags: .command)
        closeAgentPane()
    }

    /// The Inbox's keys: ↩ approves, ⌘. denies, E edits then approves, and "approve all like
    /// this" answers the next identical request by itself until it is revoked.
    func testInboxKeysEditAndApproveAllLikeThis() throws {
        try launch()
        startAgent("please ask permission")
        panes.firstMatch.tap()
        app.typeKey("i", modifierFlags: [.command, .shift])
        let approve = element(prefix: "inbox-approve-")
        XCTAssertTrue(approve.waitForExistence(timeout: 45), "the request shows in the Inbox")
        // The first key after launch is dropped; ↓ then focuses the row.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        focusRequest()
        app.typeKey("\n", modifierFlags: [])
        XCTAssertTrue(approve.waitForNonExistence(timeout: 10), "↩ approved")

        // ⌘. (Esc) denies.
        reply("deny this permission")
        focusRequest()
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(approve.waitForNonExistence(timeout: 10), "⌘. denied")

        // E: edit the command, then ↩ approves the edited one.
        reply("edit this permission")
        focusRequest()
        app.typeKey("e", modifierFlags: [])
        let field = element("inbox-edit-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Claude Code takes an edited command")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("echo edited\n")
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "approved as edited")

        // Approve all like this: the next identical request never reaches the Inbox.
        reply("one more permission")
        let menu = element(prefix: "inbox-approve-menu-")
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()
        let all = app.buttons["Approve All Like This for This Task"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        let rule = element("inbox-auto-approval")
        XCTAssertTrue(rule.waitForExistence(timeout: 15), "the rule shows on the agent's row")
        shot("inbox-auto-approval")
        reply("and again permission")
        XCTAssertFalse(approve.waitForExistence(timeout: 8), "approved by the rule, never asked")
        element(prefix: "inbox-revoke-").tap()
        XCTAssertTrue(rule.waitForNonExistence(timeout: 10), "revoked")

        // What the agent saw: allowed, denied, the edited command, allowed twice more.
        element(prefix: "inbox-open-").tap()
        XCTAssertTrue(agentScreen(containing: "decision: denied").waitForExistence(timeout: 15))
        XCTAssertTrue(agentScreen(containing: "decision: allowed (edited: echo edited)").exists)
        XCTAssertEqual(occurrences(of: "prompt: and again permission"), 1)
        shot("agent-decisions")
        closeAgentPane()
    }
}
#endif
