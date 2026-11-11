#if os(iOS)
import XCTest

/// The iPhone bar's Chat switch on an agent pane, against a real `gudo-hostd` and the stand-in
/// `claude` with a recorded-format session (apple/scripts/w3-ui-test.sh with
/// `UI_TEST_CLASS=ChatSwitchUITests` on an iPhone simulator). Skipped without a ticket.
@MainActor
final class ChatSwitchUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    func testTheBarSwitchesAnAgentPaneBetweenChatAndTerminal() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "the bar switch is the iPhone layout's")
        try launch()
        startAgent("hello")
        let toggle = element("pane-presentation")
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "an agent pane offers Chat")
        if !toggle.isSelected { toggle.tap() }
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'All 12 sign-up tests pass'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "Chat shows the conversation")
        XCTAssertTrue(toggle.isSelected)
        shot("chat, latest")
        app.swipeDown()
        app.swipeDown()
        shot("chat, earlier")
        toggle.tap()
        expectation(for: NSPredicate(format: "isSelected == false"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        shot("terminal")
        toggle.tap()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
    }

    /// Claude Code typed into a shell, not started as an agent: Chat still shows its session.
    func testClaudeTypedIntoAShellShowsItsConversation() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "the bar switch is the iPhone layout's")
        try launch()
        let pane = panes.firstMatch
        pane.tap()
        pane.typeText("claude\n")
        let toggle = element("pane-presentation")
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "a shell running Claude Code offers Chat")
        if !toggle.isSelected { toggle.tap() }
        shot("typed claude, chat")
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'All 12 sign-up tests pass'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "Chat shows the conversation")
    }

    private func launch() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/w3-ui-test.sh)")
        app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-noAutoFocus", "YES"]
        app.launch()
        XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 30), "a daemon pane appears")
    }

    private var panes: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func startAgent(_ prompt: String) {
        let palette = app.textFields.matching(identifier: "command-palette").firstMatch
        element("open-palette").tap()
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "the palette opens")
        palette.typeText("New Agent\n")
        let field = app.descendants(matching: .any).matching(identifier: "launch-prompt").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(prompt)
        let worktree = app.switches["task-worktree"].firstMatch
        if worktree.waitForExistence(timeout: 5), worktree.value as? String == "1" {
            worktree.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        element("launch-start").tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 20))
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
