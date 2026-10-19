import XCTest

/// mark in the tab's leading slot, named by the program's display name; an unfocused tab whose
/// agent needs input shows the agent glyph instead (status UX §3.4); the Inbox names each agent
/// with its mark; the iPhone switcher lists tabs with theirs. Screenshots are attached
/// (`xcrun xcresulttool export attachments`).
@MainActor
final class ProgramLogoUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        #if os(macOS)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let shot = XCTAttachment(screenshot: app.screenshot())
        #endif
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launchPrograms() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-screen", "programs", "-mock", "-tabStyle", "sidebar", "-noAutoFocus", "YES",
            "-restoreLastTarget", "NO", "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launch()
        return app
    }

    func testTabsShowTheirProgramsMark() throws {
        #if os(iOS)
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "the sidebar is iPad and Mac")
        #endif
        let app = launchPrograms()

        // Tab 2 runs vim, tab 6 nvim (a shipped logo), tab 4 python3.12: each row shows the
        // program's mark element, labelled with its display name.
        let vim = element(app, "tab-row-2")
        XCTAssertTrue(vim.waitForExistence(timeout: 20), "the fixture opened its tabs")
        XCTAssertTrue(vim.label.contains("Vim"), "tab 2 names its program: \(vim.label)")
        let neovim = element(app, "program-mark-neovim")
        XCTAssertTrue(neovim.exists, "the Neovim tab shows its logo")
        XCTAssertEqual(neovim.label, "Neovim")
        XCTAssertEqual(element(app, "program-mark-python").label, "Python")
        // Tab 5's Codex needs input and is not focused: the glyph speaks instead of the mark.
        XCTAssertTrue(element(app, "tab-row-5").label.contains("Needs You"), element(app, "tab-row-5").label)
        XCTAssertFalse(element(app, "tab-row-5").descendants(matching: .any)["program-mark-codex"].exists,
                       "the agent glyph replaces Codex's mark in its row")
        // Tab 1 is Claude split beside a shell: the pane header carries Claude's mark.
        XCTAssertEqual(element(app, "program-mark-claude").label, "Claude Code")
        attach(app, "programs-sidebar")

        // The Inbox names each agent with its mark.
        let inbox = element(app, "sidebar-inbox")
        #if os(macOS)
        inbox.click()
        #else
        inbox.tap()
        #endif
        let mark = app.descendants(matching: .any).matching(identifier: "program-mark-claude").element(boundBy: 0)
        XCTAssertTrue(mark.waitForExistence(timeout: 5), "an Inbox row shows Claude's mark")
        sleep(1)
        attach(app, "programs-inbox")
    }

    func testPhoneSwitcherListsProgramMarks() throws {
        #if os(iOS)
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "the switcher is the iPhone's")
        let app = launchPrograms()
        let switcher = element(app, "tab-switcher")
        XCTAssertTrue(switcher.waitForExistence(timeout: 20))
        // The bar shows the active tab's mark (Claude's, tab 1).
        XCTAssertTrue(element(app, "program-mark-claude").waitForExistence(timeout: 10))
        attach(app, "programs-iphone-bar")
        switcher.tap()
        let vim = app.buttons.matching(NSPredicate(format: "label CONTAINS 'notes.txt'")).firstMatch
        XCTAssertTrue(vim.waitForExistence(timeout: 5), "the switcher lists the vim tab")
        sleep(1)
        attach(app, "programs-iphone-switcher")
        #else
        throw XCTSkip("iPhone only")
        #endif
    }
}
