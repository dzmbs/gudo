#if os(iOS)
import XCTest

/// The software keyboard stays with the terminal being typed into: through a dropped link and
/// through rotation.
@MainActor
final class TerminalKeyboardUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-keyBar.fullWithHardwareKeyboard", "YES", "-restoreLastTarget", "NO", "-localEcho", "YES",
                                "-resetWindows", "YES"] + extra
        app.launch()
        let pane = element(app, "pane-1")
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the software keyboard is up")
        return app
    }

    /// The link drops and comes back: the keyboard stays up, the terminal stays where it was and
    /// typing reaches it again.
    func testADroppedLinkKeepsTheKeyboardAndTheTerminalInPlace() throws {
        let app = launch(["-screen", "connection-drop"])
        let pane = element(app, "pane-1")
        let paneFrame = pane.frame
        let notice = element(app, "connection-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "the link drops")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stays up while reconnecting")
        XCTAssertEqual(pane.frame, paneFrame, "the terminal stays where it was")
        pane.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "a tap while reconnecting keeps the keyboard")
        XCTAssertTrue(notice.waitForNonExistence(timeout: 15), "the link comes back")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.typeText("echo back\n")
        expectScreen(app, containing: "back")
    }

    /// Turning to landscape and back keeps the keyboard on the terminal: the first key typed
    /// after each turn arrives.
    func testRotationKeepsTheKeyboardOnTheTerminal() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "iPhone: rotation crosses the compact width")
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard is up in landscape")
        app.typeText("echo wide\n")
        expectScreen(app, containing: "wide")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard is up in portrait")
        app.typeText("echo tall\n")
        expectScreen(app, containing: "tall")
    }

    /// iPhone landscape with the keyboard up: the prompt line shows above the key bar, the
    /// toolbar's controls are on screen and the sidebar leaves the terminal the width.
    func testLandscapeKeepsThePromptAboveTheKeyBar() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "iPhone landscape")
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        let esc = app.buttons["keybar-esc"]
        XCTAssertTrue(esc.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        let screen = element(app, "pane-1-screen")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(screen.frame.maxY, esc.frame.minY + 1, "the grid ends above the key bar: \(screen.frame) \(esc.frame)")
        XCTAssertGreaterThan(screen.frame.width, window.width * 0.8, "the terminal has the width: \(screen.frame) in \(window)")
        for id in ["open-palette", "new-tab"] {
            let button = app.buttons[id].firstMatch
            if button.exists { XCTAssertTrue(window.contains(button.frame), "\(id) on screen: \(button.frame)") }
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "landscape-keyboard"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func expectScreen(_ app: XCUIApplication, containing text: String) {
        let pane = element(app, "pane-1-screen")
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: pane)], timeout: 5), .completed,
                       "pane shows \(text): \(String(describing: pane.value))")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}
#endif
