#if os(iOS)
import XCTest

/// On a regular-width iPad a tool opens as a leaf beside the pane, as on the Mac, not as a
/// sheet over it.
@MainActor
final class ToolLeavesUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    func testChangesOpensBesideThePane() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "a phone keeps tools as sheets")
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES", "-keyBar.fullWithHardwareKeyboard", "YES"]
        app.launch()
        let pane = app.descendants(matching: .any)["pane-1"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()
        app.buttons["open-palette"].firstMatch.tap()
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("review changes")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        XCTAssertTrue(app.staticTexts["Changes"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(pane.isHittable, "the terminal is not covered")
        // The keyboard going down with the palette must not cost the terminal its screen.
        Thread.sleep(forTimeInterval: 1)
        let screen = app.descendants(matching: .any)["pane-1-screen"].firstMatch
        XCTAssertTrue((screen.value as? String ?? "").contains("local echo"), "screen: \(String(describing: screen.value))")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "tool-leaf-changes"
        shot.lifetime = .keepAlways
        add(shot)
        // For a screenshot taken alongside.
        Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["HOLD_SECONDS"] ?? "0") ?? 0)
    }
}
#endif
