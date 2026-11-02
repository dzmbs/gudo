import XCTest

/// Agent plan usage meters with a fake usage source
/// (`-fakeUsage YES`: Claude at 62 % of 5h, Codex at 92 % of its week): one quiet line per agent
/// under the host's name, the detail popover with every window, and the Inbox strip.
@MainActor
final class UsageUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, matching predicate: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: predicate)).firstMatch
    }

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        #if os(macOS)
        let shot = app.windows.firstMatch.screenshot()
        #else
        let shot = app.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dismissPopover(_ app: XCUIApplication) {
        #if os(macOS)
        app.typeKey(.escape, modifierFlags: [])
        #else
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()
        #endif
    }

    func testMetersPopoverAndInbox() throws {
        #if os(iOS)
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "the sidebar is the iPad and Mac layout")
        #endif
        let app = XCUIApplication()
        app.launchArguments += [
            "-restoreLastTarget", "NO", "-localEcho", "YES", "-fakeUsage", "YES", "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()

        // Sidebar: one line per agent, under the host's name.
        let claude = element(app, matching: "identifier BEGINSWITH 'usage-meter-' AND identifier ENDSWITH '-claude'")
        if !claude.waitForExistence(timeout: 20) {
            // iPad portrait hides the sidebar.
            let toggle = app.buttons["ToggleSidebar"].firstMatch
            if toggle.exists { press(toggle) }
        }
        XCTAssertTrue(claude.waitForExistence(timeout: 10), "Claude meter in the sidebar")
        XCTAssertTrue(claude.label.contains("Claude · 62% of 5h · resets"), claude.label)
        let codex = element(app, matching: "identifier BEGINSWITH 'usage-meter-' AND identifier ENDSWITH '-codex'")
        XCTAssertTrue(codex.exists)
        XCTAssertTrue(codex.label.contains("Codex · 92% of weekly"), codex.label)
        attach(app, "usage-sidebar")

        // The detail: every window, with its source.
        press(claude)
        let detail = element(app, matching: "identifier == 'usage-detail'")
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "detail popover")
        XCTAssertTrue(app.staticTexts["Claude Code · Max"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Codex · Plus"].firstMatch.exists)
        XCTAssertTrue(element(app, matching: "identifier == 'usage-row-codex-weekly'").exists)
        XCTAssertTrue(element(app, matching: "identifier == 'usage-row-claude-5h'").exists)
        attach(app, "usage-detail")
        dismissPopover(app)
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))

        // The Inbox: the same meters, with the host's name.
        let inbox = app.descendants(matching: .any)["sidebar-inbox"].firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        press(inbox)
        let inboxClaude = element(app, matching: "identifier BEGINSWITH 'inbox-usage-' AND identifier ENDSWITH '-claude'")
        XCTAssertTrue(inboxClaude.waitForExistence(timeout: 5), "Claude meter in the Inbox")
        XCTAssertTrue(inboxClaude.label.contains("62% of 5h"), inboxClaude.label)
        press(inboxClaude)
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "detail from the Inbox")
        attach(app, "usage-inbox")
    }
}
