#if os(iOS)
import XCTest

/// Walks through the layout changes that animate (split, sidebar, new tab, zoom, close) with
/// pauses between them, for a screen recording taken alongside (`xcrun simctl io recordVideo`).
/// Asserts only that each step lands; smoothness is judged from the recording's frames.
final class MotionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLayoutChangesForRecording() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "splits and the sidebar are the iPad and Mac layout")
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"]
        app.launch()
        let pane1 = element(app, "pane-1")
        XCTAssertTrue(pane1.waitForExistence(timeout: 10))
        pane1.tap()
        pause()

        // Split right, then down: the existing panes keep their views.
        let start = Date()
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(element(app, "pane-3").waitForExistence(timeout: 5))
        print("motion: split right visible after \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        pause()
        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(element(app, "pane-4").waitForExistence(timeout: 5))
        pause()

        // Sidebar out and back.
        element(app, "toggle-sidebar").tap()
        pause()
        element(app, "toggle-sidebar").tap()
        pause()

        // Zoom and back.
        toggleZoom(app)
        pause()
        toggleZoom(app)
        pause()

        // New tab, back to the first.
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(element(app, "pane-5").waitForExistence(timeout: 5))
        pause()
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(pane1.waitForExistence(timeout: 5))
        pause()

        // Close the focused pane.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element(app, "pane-4").waitForNonExistence(timeout: 5))
        pause()
    }

    /// The same from the pane menu with the software keyboard down: only the layout moves, so
    /// the recording shows whether a terminal reflows while its pane animates.
    @MainActor
    func testLayoutChangesWithoutKeyboardForRecording() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "splits and the sidebar are the iPad and Mac layout")
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES", "-noAutoFocus", "YES"]
        app.launch()
        XCTAssertTrue(element(app, "pane-1").waitForExistence(timeout: 10))
        pause()
        paneMenu(app, "Split Right")
        XCTAssertTrue(element(app, "pane-3").waitForExistence(timeout: 5))
        pause()
        paneMenu(app, "Split Down")
        XCTAssertTrue(element(app, "pane-4").waitForExistence(timeout: 5))
        pause()
        paneMenu(app, "Zoom Pane")
        pause()
        paneMenu(app, "Zoom Pane")
        pause()
        element(app, "toggle-sidebar").tap()
        pause()
        element(app, "toggle-sidebar").tap()
        pause()
        paneMenu(app, "Close Pane")
        XCTAssertTrue(element(app, "pane-4").waitForNonExistence(timeout: 5))
        pause()
        paneMenu(app, "Close Pane")
        XCTAssertTrue(element(app, "pane-3").waitForNonExistence(timeout: 5))
        pause()
    }

    /// A split, a close and a zoom each resize every pane they move exactly once, at the size
    /// it lands at: no resize per animation frame, so shells redraw their prompts once. Driven
    /// from the pane menu with the software keyboard kept down, so only the layout resizes.
    @MainActor
    func testEachLayoutChangeResizesEachPaneOnce() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "splits and the sidebar are the iPad and Mac layout")
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES", "-windowProbe", "YES", "-noAutoFocus", "YES"]
        app.launch()
        XCTAssertTrue(element(app, "pane-1").waitForExistence(timeout: 10))
        let first = try XCTUnwrap(settledResizes(app)[1])

        paneMenu(app, "Split Right")
        XCTAssertTrue(element(app, "pane-3").waitForExistence(timeout: 5))
        var counts = settledResizes(app)
        XCTAssertEqual(counts[1], first + 1, "the split pane: \(counts)")
        XCTAssertEqual(counts[3], 1, "the new pane: \(counts)")

        paneMenu(app, "Zoom Pane")
        counts = settledResizes(app)
        XCTAssertEqual(counts[3], 2, "zoomed: \(counts)")
        paneMenu(app, "Zoom Pane")
        counts = settledResizes(app)
        XCTAssertEqual(counts[3], 3, "unzoomed: \(counts)")
        XCTAssertEqual(counts[1], first + 1, "the pane hidden by the zoom: \(counts)")

        paneMenu(app, "Close Pane")
        XCTAssertTrue(element(app, "pane-3").waitForNonExistence(timeout: 5))
        counts = settledResizes(app)
        XCTAssertEqual(counts[1], first + 2, "after the close: \(counts)")
    }

    /// Hiding and showing the sidebar resizes each pane once, as the slide ends.
    @MainActor
    func testSidebarResizesEachPaneOnce() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "splits and the sidebar are the iPad and Mac layout")
        let app = probedApp()
        paneMenu(app, "Split Right")
        XCTAssertTrue(element(app, "pane-3").waitForExistence(timeout: 5))
        let start = settledResizes(app)
        for step in 1...2 {
            element(app, "toggle-sidebar").tap()
            let counts = settledResizes(app)
            XCTAssertEqual(counts[1], start[1].map { $0 + step }, "toggle \(step): \(counts)")
            XCTAssertEqual(counts[3], start[3].map { $0 + step }, "toggle \(step): \(counts)")
        }
    }

    /// The software keyboard coming up and going down resizes each pane once; focus moving
    /// between panes while it stays up resizes none.
    @MainActor
    func testKeyboardResizesEachPaneOnce() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "splits and the sidebar are the iPad and Mac layout")
        let app = probedApp()
        paneMenu(app, "Split Right")
        XCTAssertTrue(element(app, "pane-3").waitForExistence(timeout: 5))
        let start = settledResizes(app)

        element(app, "pane-1").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the software keyboard comes up")
        var counts = settledResizes(app)
        XCTAssertEqual(counts[1], start[1].map { $0 + 1 }, "keyboard up: \(counts)")
        XCTAssertEqual(counts[3], start[3].map { $0 + 1 }, "keyboard up: \(counts)")

        let keyboardUpCounts = counts
        for pane in ["pane-3", "pane-1", "pane-3"] {
            element(app, pane).tap()
            counts = settledResizes(app)
            XCTAssertEqual(counts, keyboardUpCounts, "focus to \(pane), keyboard still up: \(counts)")
        }

        element(app, "keybar-hide-keyboard").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard goes down")
        counts = settledResizes(app)
        XCTAssertEqual(counts[1], start[1].map { $0 + 2 }, "keyboard down: \(counts)")
        XCTAssertEqual(counts[3], start[3].map { $0 + 2 }, "keyboard down: \(counts)")
    }

    /// A new browser tab's start page: the host's dev servers, found after it opened, arrive
    /// below Frequently Visited, which stays where it was.
    @MainActor
    func testStartPageKeepsItsPlaceAsDevServersArrive() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "splits and the sidebar are the iPad and Mac layout")
        let app = XCUIApplication()
        app.launchArguments += ["-mock", "-screen", "start-page", "-restoreLastTarget", "NO"]
        app.launch()
        let frequent = app.buttons["start-frequent"].firstMatch
        XCTAssertTrue(frequent.waitForExistence(timeout: 15))
        let before = frequent.frame
        let server = app.buttons["start-dev-5173"].firstMatch
        XCTAssertFalse(server.exists, "the scan is still running")
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(frequent.frame, before, "Frequently Visited stays put")
        XCTAssertGreaterThan(server.frame.minY, frequent.frame.maxY, "dev servers come after")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "start-page-dev-servers"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Two-pane-ready app with the resize probe, the keyboard down.
    private func probedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES", "-windowProbe", "YES", "-noAutoFocus", "YES", "-sidebarShown", "YES"]
        app.launch()
        XCTAssertTrue(element(app, "pane-1").waitForExistence(timeout: 10))
        return app
    }

    private func paneMenu(_ app: XCUIApplication, _ title: String) {
        element(app, "pane-menu").tap()
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5))
    }

    /// Each pane's resize count once they have stopped changing (`WindowProbe` "resizes").
    private func settledResizes(_ app: XCUIApplication) -> [UInt64: Int] {
        var last = resizes(app)
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 1)
            let now = resizes(app)
            if now == last { return now }
            last = now
        }
        return last
    }

    private func resizes(_ app: XCUIApplication) -> [UInt64: Int] {
        let probe = app.descendants(matching: .any)["window-probe"]
        guard let text = probe.value as? String, let data = text.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var counts: [UInt64: Int] = [:]
        for pair in (fields["resizes"] ?? "").split(separator: " ") {
            let parts = pair.split(separator: ":")
            if parts.count == 2, let pane = UInt64(parts[0]), let count = Int(parts[1]) { counts[pane] = count }
        }
        return counts
    }

    private func pause() {
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func toggleZoom(_ app: XCUIApplication) {
        element(app, "pane-menu").tap()
        let item = app.buttons["Zoom Pane"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5))
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }
}
#endif
