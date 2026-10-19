#if os(iOS)
import XCTest

/// The context-aware key bar (04-mobile-ux C5) over the software keyboard: profile switching from
/// the pane title, the agent composer, and snippets. Titles are set through the iOS echo backend's
/// `title <text>` command, which emits OSC 2 like a program would.
final class KeyBarUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testProfileFollowsTitleAndComposerSends() throws {
        let app = launch()
        let profile = app.buttons["keybar-profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertEqual(profile.value as? String, "Shell")
        XCTAssertTrue(app.buttons["keybar-pipe"].exists)

        app.typeText("title vim main.swift\n")
        XCTAssertTrue(waitFor(profile, value: "Vim"))
        XCTAssertTrue(app.buttons["keybar-colon"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["keybar-ctrl"].exists)
        XCTAssertFalse(app.buttons["keybar-pipe"].exists)
        XCTAssertFalse(element(app, "keybar-composer").exists, "no composer for vim")

        app.buttons["keybar-esc"].tap()
        app.typeText("title claude\n")
        XCTAssertTrue(waitFor(profile, value: "Claude Code"))
        XCTAssertTrue(app.buttons["keybar-shift-tab"].exists)
        let composer = element(app, "keybar-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "agents default to the composer")
        XCTAssertEqual(app.buttons["keybar-composer-toggle"].value as? String, "on")

        composer.tap()
        composer.typeText("explain this repo\nin two lines")
        XCTAssertTrue(app.buttons["keybar-profile"].exists, "the bar stays while the composer types")
        app.buttons["keybar-composer-send"].tap()
        XCTAssertEqual(composer.value as? String ?? "", "", "Send clears the composer")
        add(XCTAttachment(screenshot: app.screenshot()))

        // Back to a shell: the composer goes away again.
        app.buttons["keybar-composer-toggle"].tap()
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5))
        element(app, "pane-1").tap()
        app.typeText("title zsh ~/src\n")
        XCTAssertTrue(waitFor(profile, value: "Shell"))
        hold()
    }

    @MainActor
    func testManualProfileFromChip() throws {
        let app = launch()
        let profile = app.buttons["keybar-profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        let pager = app.buttons["Pager"].firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        pager.tap()
        XCTAssertTrue(waitFor(profile, value: "Pager"))
        XCTAssertTrue(app.buttons["keybar-pgdn"].exists)
    }

    @MainActor
    func testSnippetsRow() throws {
        let app = launch()
        let toggle = app.buttons["keybar-snippets"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["keybar-snippet-0"].exists)
        toggle.tap()
        let first = app.buttons["keybar-snippet-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()  // runs "git status" in the echo pane
        add(XCTAttachment(screenshot: app.screenshot()))
        toggle.tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        hold()
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // The simulator may report a hardware keyboard; these tests are about the full bar.
        app.launchArguments += ["-keyBar.fullWithHardwareKeyboard", "YES"]
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"]
        app.launch()
        let pane1 = element(app, "pane-1")
        XCTAssertTrue(pane1.waitForExistence(timeout: 10))
        pane1.tap()
        return app
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, value: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func hold() {
        guard let seconds = ProcessInfo.processInfo.environment["HOLD_SECONDS"].flatMap(Double.init) else { return }
        Thread.sleep(forTimeInterval: seconds)
    }
}
#endif
