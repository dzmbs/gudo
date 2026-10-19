import XCTest

/// with tabs on top and in the sidebar, and iPhone/iPad never start in a fake local shell.
/// Screenshots of both tab placements are attached (`xcrun xcresulttool export attachments`).
@MainActor
final class ChromeUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        #if os(macOS)
        let shot = app.windows.firstMatch.screenshot()
        #else
        let shot = app.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The toolbar's buttons have the same size, order and (by construction) style in both tab
    /// placements: one toolbar serves both.
    func testToolbarIsTheSameInBothTabPlacements() throws {
        #if os(iOS)
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "iPhone has no tab placements")
        #endif
        let app = XCUIApplication()
        // Not `-tabStyle`: a launch argument outranks the toggle's write to user defaults.
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let ids = ["hosts-button", "pane-menu", "open-palette"]
        XCTAssertTrue(element(app, "hosts-button").waitForExistence(timeout: 20))
        func placement(_ title: String) -> XCUIElement {
            press(element(app, "pane-menu"))
            return app.buttons[title].firstMatch
        }
        // Start from vertical tabs: the strip shows only with tabs on top.
        if element(app, "tab-bar").exists { press(placement("Tabs in Sidebar")) }
        XCTAssertTrue(element(app, "tab-bar").waitForNonExistence(timeout: 5))
        sleep(1)
        let sidebarFrames = ids.map { element(app, $0).frame }
        attach(app, "toolbar-sidebar")

        let toggle = placement("Tabs on Top")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        press(toggle)
        XCTAssertTrue(element(app, "tab-bar").waitForExistence(timeout: 5))
        sleep(1)
        let barFrames = ids.map { element(app, $0).frame }
        attach(app, "toolbar-bar")

        for (id, (a, b)) in zip(ids, zip(sidebarFrames, barFrames)) {
            XCTAssertEqual(a.width, b.width, accuracy: 0.5, "\(id) width differs between tab placements")
            XCTAssertEqual(a.height, b.height, accuracy: 0.5, "\(id) height differs between tab placements")
            XCTAssertEqual(a.minY, b.minY, accuracy: 0.5, "\(id) moved vertically between tab placements")
        }
        // Same order, left to right.
        XCTAssertEqual(barFrames.map(\.minX), barFrames.map(\.minX).sorted())
        XCTAssertEqual(sidebarFrames.map(\.minX), sidebarFrames.map(\.minX).sorted())
        // Leave the default placement for the next test (the choice is saved).
        press(placement("Tabs in Sidebar"))
    }

    #if os(iOS)
    /// A fresh install on iPhone or iPad opens on the welcome screen with ways to add a host, and
    /// never in a local echo "shell".
    func testFirstLaunchShowsWelcomeNotAShell() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO"]
        app.launch()
        let welcome = element(app, "welcome")
        XCTAssertTrue(welcome.waitForExistence(timeout: 20), "the welcome screen shows")
        XCTAssertTrue(element(app, "welcome-ssh").exists, "Connect with SSH is offered")
        XCTAssertTrue(element(app, "welcome-ticket").exists, "Pairing by ticket is offered")
        let panes = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
        XCTAssertEqual(panes.count, 0, "no local echo pane")
        attach(app, "first-launch")
    }
    #endif
}
