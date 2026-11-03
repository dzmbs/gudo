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
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"]
        app.launch()
        let pane = element(app, "pane-1")
        XCTAssertTrue(pane.waitForExistence(timeout: 10))

        // "gudo" is the first word of the banner.
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
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"]
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
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"]
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

    /// Text copied in another app (the test runner) pastes with ⌘V, no permission prompt.
    @MainActor
    func testCommandVPastesTextCopiedElsewhere() throws {
        let app = launchFocused()
        UIPasteboard.general.string = "curl -fsSL example.com/install.sh"
        app.typeKey("v", modifierFlags: .command)
        expectScreen(app, containing: "example.com/install.sh")
    }

    /// The key bar's paste key: another app's text through the system's Paste at the cursor (no
    /// prompt); text copied in this app at once.
    @MainActor
    func testKeyBarPasteKey() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "a phone's shell key set has no room for the paste key (the edit menu pastes)")
        let app = launchFocused(fullKeyBar: true)
        UIPasteboard.general.string = "pasted-from-key-bar"
        let key = element(app, "keybar-paste")
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        expectScreen(app, containing: "pasted-from-key-bar")

        // Copy "pane-1" from the banner here, then the key pastes it straight away.
        cellPoint(element(app, "pane-1"), x: 12, y: 0).doubleTap()
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        // Copying clears the selection; the paste below shows what was copied. (The 1.2 s
        // "Copied" capsule can fade before XCUITest's next snapshot, and the runner cannot read
        // another app's pasteboard without a prompt.)
        XCTAssertTrue(element(app, "selection-start-handle").waitForNonExistence(timeout: 5), "copied")
        key.tap()
        XCTAssertFalse(app.menuItems["Paste"].firstMatch.waitForExistence(timeout: 1))
        expectScreen(app, containing: "pasted-from-key-barpane-1")
    }

    /// A long-press on blank cells still offers Paste (the iPhone's way in).
    @MainActor
    func testLongPressOnBlankOffersPaste() throws {
        let app = launchFocused()
        UIPasteboard.general.string = "pasted-from-menu"
        let pane = element(app, "pane-1")
        cellPoint(pane, x: 40, y: 20).press(forDuration: 0.8)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        expectScreen(app, containing: "pasted-from-menu")
    }

    /// Closing a sheet gives the terminal the keyboard back, so ⌘V lands there.
    @MainActor
    func testCommandVAfterSheetCloses() throws {
        let app = launchFocused()
        app.typeKey("n", modifierFlags: [.command, .shift])
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        UIPasteboard.general.string = "pasted-after-sheet"
        app.typeKey("v", modifierFlags: .command)
        expectScreen(app, containing: "pasted-after-sheet")
    }

    /// Extend a long-press selection with its handle, copy, paste it back with ⌘V: plain text,
    /// trailing blanks trimmed.
    @MainActor
    func testSelectionDragCopyAndPasteBack() throws {
        let app = launchFocused()
        let pane = element(app, "pane-1")
        cellPoint(pane, x: 3, y: 0).press(forDuration: 0.8)
        let end = element(app, "selection-end-handle")
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        // "Gudo · pane-1" ends at column 15.
        end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: cellPoint(pane, x: 15, y: 0))
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        // A key sent while the edit menu is still going away does not reach the terminal.
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        app.typeKey("v", modifierFlags: .command)
        expectScreen(app, containing: "❯ Gudo · pane-1")
    }

    @MainActor
    private func launchFocused(fullKeyBar: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"]
        if fullKeyBar { app.launchArguments += ["-keyBar.fullWithHardwareKeyboard", "YES"] }
        app.launch()
        let pane = element(app, "pane-1")
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()
        // The simulator drops the first hardware key after launch.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        return app
    }

    /// Fails on a paste permission prompt: every paste path here is one iOS trusts.
    @MainActor
    private func expectScreen(_ app: XCUIApplication, containing text: String) {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let found = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element(app, "pane-1-screen"))], timeout: 6)
        add(XCTAttachment(screenshot: app.screenshot()).named("paste-\(text)"))
        XCTAssertFalse(app.alerts.buttons["Allow Paste"].exists, "iOS asked for paste permission")
        XCTAssertEqual(found, .completed, "\(text) not on screen")
    }

    /// With 400 ms each way, typed characters show at once as underlined predictions, then the
    /// echo confirms them (the screen text then contains them for real).
    @MainActor
    func testEchoPredictionOnSlowLink() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-echoLatencyMs", "400"]
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"]
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
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"]
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
