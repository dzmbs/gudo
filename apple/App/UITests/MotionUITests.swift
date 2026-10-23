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
