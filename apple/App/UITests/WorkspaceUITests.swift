#if os(iOS)
import XCTest

/// Drives the app through hardware-keyboard shortcuts, the way an iPad or Mac user would.
/// Ids: the first tab holds pane-1 (tab-2); each split or new tab takes the next number.
final class WorkspaceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    #if os(iOS)
    @MainActor
    func testShortcutsSplitZoomAndSwitchTabs() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "splits and dividers are the iPad and Mac layout")
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"]
        app.launch()
        let pane1 = element(app, "pane-1")
        XCTAssertTrue(pane1.waitForExistence(timeout: 10))
        pane1.tap()

        app.typeKey("d", modifierFlags: .command)  // split right → pane-3
        XCTAssertTrue(element(app, "pane-3").waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: [.command, .shift])  // split pane-3 down → pane-4
        XCTAssertTrue(element(app, "pane-4").waitForExistence(timeout: 5))

        // Zoom hides the other panes; zooming again brings them back. Through the pane menu:
        // XCUITest's synthesized ⇧⌘↩ never reaches the app in the simulator.
        toggleZoom(app)
        XCTAssertTrue(element(app, "pane-1").waitForNonExistence(timeout: 5))
        toggleZoom(app)
        XCTAssertTrue(element(app, "pane-1").waitForExistence(timeout: 5))

        // Focus moves left from pane-4 to pane-1: zooming now shows pane-1 alone.
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        let splitWidth = pane1.frame.width
        toggleZoom(app)
        XCTAssertGreaterThan(pane1.frame.width, splitWidth * 1.5)
        toggleZoom(app)

        // Dividers move with ⌃⌘ arrows (not observable here beyond not crashing); then split
        // pane-1 down → pane-5.
        app.typeKey(.rightArrow, modifierFlags: [.command, .control])
        app.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(element(app, "pane-5").waitForExistence(timeout: 5))

        // Close pane-5 (focused) with ⌘W.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(element(app, "pane-5").waitForNonExistence(timeout: 5))

        // New tab, then back to the first one with ⌘1 and forward with ⇧⌘].
        app.typeKey("t", modifierFlags: .command)  // tab-7 with pane-6
        XCTAssertTrue(element(app, "pane-6").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "pane-1").waitForNonExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(element(app, "pane-1").waitForExistence(timeout: 5))
        app.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertTrue(element(app, "pane-6").waitForExistence(timeout: 5))
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertTrue(element(app, "pane-3").waitForExistence(timeout: 5))

        app.typeText("echo split\n")
        add(XCTAttachment(screenshot: app.screenshot()))
        hold()
    }

    /// Resizes a split with ⌃⌘→ and by dragging its divider, then rotates the iPad both ways while
    /// split: the ratio must survive the rotation and splitting must keep working (guards against
    /// a SwiftUI layout cycle).
    @MainActor
    func testRotationAndDividerResize() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "splits and dividers are the iPad and Mac layout")
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"]
        app.launch()
        let pane1 = element(app, "pane-1")
        let pane3 = element(app, "pane-3")
        XCTAssertTrue(pane1.waitForExistence(timeout: 10))
        pane1.tap()
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(pane3.waitForExistence(timeout: 5))

        let initial = pane1.frame.width
        app.typeKey(.rightArrow, modifierFlags: [.command, .control])
        XCTAssertGreaterThan(pane1.frame.width, initial + 20, "⌃⌘→ moves the divider right")

        let divider = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH[c] 'split divider'")).firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        let beforeDrag = pane1.frame.width
        let grip = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.3, thenDragTo: grip.withOffset(CGVector(dx: -250, dy: 0)))
        XCTAssertLessThan(pane1.frame.width, beforeDrag - 150, "dragging the divider left shrinks pane-1")

        let ratio = share(of: pane1, next: pane3)
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 2)  // rotation animation
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertEqual(share(of: pane1, next: pane3), ratio, accuracy: 0.02, "ratio survives \(orientation.rawValue)")
        }

        app.typeKey("d", modifierFlags: [.command, .shift])  // split pane-3 (focused) down in landscape → pane-4
        XCTAssertTrue(element(app, "pane-4").waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(element(app, "pane-4").exists)
        add(XCTAttachment(screenshot: app.screenshot()))
        hold()
    }

    /// Opens the software keyboard on a split layout so the key bar shows, uses sticky Ctrl.
    @MainActor
    func testKeyBarAboveSoftwareKeyboard() throws {
        let app = XCUIApplication()
        // The simulator reports the Mac's keyboard, which collapses the bar to its slim strip.
        app.launchArguments += ["-keyBar.fullWithHardwareKeyboard", "YES"]
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"]
        app.launch()
        let pane1 = element(app, "pane-1")
        XCTAssertTrue(pane1.waitForExistence(timeout: 10))
        pane1.tap()
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(element(app, "pane-3").waitForExistence(timeout: 5))

        let ctrl = app.buttons["keybar-ctrl"]
        XCTAssertTrue(ctrl.waitForExistence(timeout: 5))
        app.typeText("ls")
        ctrl.tap()
        XCTAssertEqual(ctrl.value as? String, "Latched")
        app.typeText("c")  // one-shot Ctrl+C
        XCTAssertEqual(ctrl.value as? String, "off")
        app.buttons["keybar-pipe"].tap()
        app.buttons["keybar-tilde"].tap()
        app.typeText("\n")
        add(XCTAttachment(screenshot: app.screenshot()))
        hold()
    }

    #endif

    #if os(macOS)
    /// Switching from the tab strip to vertical tabs shows the sidebar on macOS.
    @MainActor
    func testSidebarAppearsAfterSwitchingFromTabStrip() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-localEcho", "YES", "-sidebarShown", "NO", "-tabBarWithoutSidebar", "YES"]
        app.launch()
        XCTAssertTrue(element(app, "tab-bar").waitForExistence(timeout: 20))
        element(app, "toggle-sidebar").click()
        let inbox = element(app, "sidebar-inbox")
        XCTAssertTrue(inbox.waitForExistence(timeout: 5), "the sidebar shows after switching")
        XCTAssertTrue(inbox.isHittable, "the sidebar is on screen, not collapsed")
        XCTAssertTrue(element(app, "tab-bar").waitForNonExistence(timeout: 5))
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }
    #endif

    /// `pane`'s share of the width it splits with `next` (side by side).
    @MainActor
    private func share(of pane: XCUIElement, next: XCUIElement) -> CGFloat {
        pane.frame.width / (pane.frame.width + next.frame.width)
    }

    #if os(iOS)
    @MainActor
    private func toggleZoom(_ app: XCUIApplication) {
        element(app, "pane-menu").tap()
        let item = app.buttons["Zoom Pane"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5))
    }
    #endif

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Keeps the final state on screen for an external capture (`xcrun simctl io … screenshot`)
    /// when TEST_RUNNER_HOLD_SECONDS is set.
    private func hold() {
        guard let seconds = ProcessInfo.processInfo.environment["HOLD_SECONDS"].flatMap(Double.init) else { return }
        Thread.sleep(forTimeInterval: seconds)
    }
}
#endif
