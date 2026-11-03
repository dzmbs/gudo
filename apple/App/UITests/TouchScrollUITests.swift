#if os(iOS)
import XCTest

/// Touch on the terminal against the local echo stand-in: a drag scrolls (scrollback, or wheel
/// events to a program that tracks the mouse, never a mouse drag that selects and copies), a
/// long-press selects with the edit menu and copies nothing by itself, a pinch sets the font size.
final class TouchScrollUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES", "-resetFontSize"]
        app.launch()
        let pane = app.descendants(matching: .any)["pane-1"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()
        sleep(1)
        return (app, pane)
    }

    @MainActor
    private func screenText(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["pane-1-screen"].firstMatch.value as? String ?? ""
    }

    @MainActor
    private func waitForScreen(_ app: XCUIApplication, _ format: String, _ argument: String, _ message: String) {
        let predicate = NSPredicate(format: format, argument)
        let screen = app.descendants(matching: .any)["pane-1-screen"].firstMatch
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: screen)], timeout: 8)
        if result != .completed { shot(app, "failed") }
        XCTAssertEqual(result, .completed, message)
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testOneFingerDragScrollsTheScrollback() {
        let (app, pane) = launch()
        app.typeText("seq 300\n")
        waitForScreen(app, "value CONTAINS %@", "row 300", "the output is on screen")
        pane.swipeDown()
        waitForScreen(app, "NOT (value CONTAINS %@)", "row 300", "dragging down shows older rows")
        XCTAssertFalse(app.menuItems["Copy"].exists, "a drag never selects")
        shot(app, "scrolled-back")
        pane.swipeUp()
        pane.swipeUp()
        waitForScreen(app, "value CONTAINS %@", "row 300", "dragging up returns to the newest rows")
    }

    @MainActor
    func testDragInAMouseTrackingProgramSendsWheelNotDrag() {
        let (app, pane) = launch()
        app.typeText("mouse\n")
        sleep(1)
        pane.swipeDown()
        waitForScreen(app, "value CONTAINS %@", "[<64;", "dragging down sends wheel up")
        pane.swipeUp()
        waitForScreen(app, "value CONTAINS %@", "[<65;", "dragging up sends wheel down")
        let screen = screenText(app)
        XCTAssertFalse(screen.contains("[<0;"), "no left button press reached the program")
        XCTAssertFalse(screen.contains("[<32;"), "no drag motion reached the program")
        XCTAssertFalse(app.descendants(matching: .any)["terminal-toast"].exists, "nothing was copied")
        shot(app, "mouse-wheel")
    }

    @MainActor
    func testLongPressSelectsAndOffersTheEditMenuWithoutCopying() {
        let (app, pane) = launch()
        app.typeText("mouse\n")
        sleep(1)
        pane.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 10)).press(forDuration: 0.8)
        XCTAssertTrue(app.descendants(matching: .any)["selection-end-handle"].waitForExistence(timeout: 5), "a long-press selects")
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5), "the edit menu offers Copy")
        XCTAssertTrue(app.menuItems["Select All"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["terminal-toast"].exists, "selecting copies nothing")
        XCTAssertFalse(screenText(app).contains("[<0;"), "the long-press did not click the program")
        shot(app, "long-press-menu")
    }

    @MainActor
    func testPinchSetsTheFontSize() {
        let (app, pane) = launch()
        let toast = app.descendants(matching: .any)["terminal-toast"]
        pane.pinch(withScale: 1.6, velocity: 1)
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "the size shows while pinching")
        XCTAssertNotEqual(toast.label, "13 pt")
        XCTAssertTrue(toast.label.hasSuffix(" pt"), toast.label)
        shot(app, "pinched")
        // The size is kept across launches: back to the default for the tests after this one.
        app.terminate()
        app.launch()
    }
}
#endif
