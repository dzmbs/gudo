#if os(iOS)
import XCTest

/// Selection, paste and IME on the iPad terminal view. Cell geometry: 13 pt JetBrains Mono at 2x
/// gives 8 x 17 pt cells after 2 pt padding; the echo backend prints its banner on row 0.
final class TerminalInputUITests: XCTestCase {
    private static let cell = CGSize(width: 8, height: 17)
    private static let padding: CGFloat = 2

    override func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func cellPoint(_ pane: XCUIElement, x: Int, y: Int) -> XCUICoordinate {
        pane.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: Self.padding + (CGFloat(x) + 0.5) * Self.cell.width,
            dy: Self.padding + (CGFloat(y) + 0.5) * Self.cell.height))
    }

    @MainActor
    func testLongPressSelectsWordShowsHandlesAndCopies() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO"]
        app.launch()
        let pane = element(app, "pane-1")
        XCTAssertTrue(pane.waitForExistence(timeout: 10))

        // "unnamed" is the first word of the banner.
        cellPoint(pane, x: 3, y: 0).press(forDuration: 0.8)
        XCTAssertTrue(element(app, "selection-start-handle").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "selection-end-handle").exists)

        // Drag the end handle a few cells right: the selection grows past the word.
        let end = element(app, "selection-end-handle")
        let before = end.frame.midX
        end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: cellPoint(pane, x: 20, y: 0))
        XCTAssertGreaterThan(end.frame.midX, before + 40)

        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        add(XCTAttachment(screenshot: app.screenshot()).named("selection"))
        copy.tap()
        // Copying clears the selection.
        XCTAssertTrue(element(app, "selection-start-handle").waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testDoubleTapSelectsWordAndTapClears() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO"]
        app.launch()
        let pane = element(app, "pane-1")
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        cellPoint(pane, x: 3, y: 0).doubleTap()
        XCTAssertTrue(element(app, "selection-start-handle").waitForExistence(timeout: 5))
        cellPoint(pane, x: 40, y: 10).tap()
        XCTAssertTrue(element(app, "selection-start-handle").waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testMultilinePasteAsksForConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO"]
        app.launch()
        let pane = element(app, "pane-1")
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        UIPasteboard.general.string = "echo one\necho two"
        // Through the edit menu: long-press shows it with Paste.
        cellPoint(pane, x: 3, y: 0).press(forDuration: 0.8)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()

        // iOS may first ask whether the app may read the pasteboard.
        let allow = app.alerts.buttons["Allow Paste"].firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        let confirm = app.alerts["Paste 2 Lines?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        add(XCTAttachment(screenshot: app.screenshot()).named("paste-confirm"))
        confirm.buttons["Paste"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
    }

    /// With 400 ms each way, typed characters show at once as underlined predictions, then the
    /// echo confirms them (the screen text then contains them for real).
    @MainActor
    func testEchoPredictionOnSlowLink() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-echoLatencyMs", "400"]
        app.launchArguments += ["-restoreLastTarget", "NO"]
        app.launch()
        let pane = element(app, "pane-1")
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()
        app.typeKey("p", modifierFlags: [])
        app.typeKey("r", modifierFlags: [])
        app.typeKey("e", modifierFlags: [])
        app.typeKey("d", modifierFlags: [])
        add(XCTAttachment(screenshot: app.screenshot()).named("echo-prediction"))
        let confirmed = NSPredicate(format: "value CONTAINS %@", "pred")
        expectation(for: confirmed, evaluatedWith: element(app, "pane-1-screen"))
        waitForExpectations(timeout: 10)
    }

    @MainActor
    func testMarkedTextIsDrawnInline() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-demoPreedit", "にほんご"]
        app.launchArguments += ["-restoreLastTarget", "NO"]
        app.launch()
        let pane = element(app, "pane-1")
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        let composing = NSPredicate(format: "value BEGINSWITH %@", "composing ")
        expectation(for: composing, evaluatedWith: element(app, "pane-1-screen"))
        waitForExpectations(timeout: 5)
        add(XCTAttachment(screenshot: app.screenshot()).named("ime-preedit"))
    }
}

private extension XCTAttachment {
    func named(_ name: String) -> XCTAttachment {
        self.name = name
        lifetime = .keepAlways
        return self
    }
}
#endif
