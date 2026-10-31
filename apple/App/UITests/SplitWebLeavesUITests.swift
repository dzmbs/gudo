#if os(iOS)
import XCTest

/// A browser leaf opened right after a split, then splits, a zoom and a close around it while
/// they still animate: the page stays, and the app with it (a page's view made twice is a
/// WebKit trap). The Mac's in-process cases are `SplitWebLeavesTests`.
@MainActor
final class SplitWebLeavesUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    func testBrowserBesideRightAfterSplitsZoomAndClose() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "splits are the iPad and Mac layout")
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES", "-keyBar.fullWithHardwareKeyboard", "YES"]
        app.launch()
        let pane = app.descendants(matching: .any)["pane-1"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()
        app.typeKey("d", modifierFlags: .command)
        app.buttons["open-palette"].firstMatch.tap()
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Open Browser Beside\n")
        let leaf = app.descendants(matching: .any)["browser-leaf"].firstMatch
        XCTAssertTrue(leaf.waitForExistence(timeout: 10), "the page opens beside the panes")

        // The terminal's turn: split it, zoom and unzoom, close the new pane, all at once.
        app.descendants(matching: .any)["pane-1"].firstMatch.tap()
        app.typeKey("d", modifierFlags: [.command, .shift])
        app.typeKey(.return, modifierFlags: [.command, .shift])
        app.typeKey(.return, modifierFlags: [.command, .shift])
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground, "the app lives on")
        XCTAssertTrue(leaf.exists, "and so does the page")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "split-web-leaves"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
