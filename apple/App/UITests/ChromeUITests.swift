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

    /// Safari's model: the sidebar button is always in the toolbar, ⌘B does the same, and the
    /// tabs move to a strip on top while the sidebar is hidden. The toolbar's buttons keep their
    /// size, order and place either way.
    func testSidebarToggleAndCommandBMoveTheTabs() throws {
        #if os(iOS)
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "iPhone has no sidebar")
        #endif
        let app = XCUIApplication()
        app.launchArguments += [
            "-restoreLastTarget", "NO", "-localEcho", "YES", "-ApplePersistenceIgnoreState", "YES",
            "-sidebarShown", "YES", "-tabBarWithoutSidebar", "YES",
        ]
        app.launch()
        let ids = ["toggle-sidebar", "hosts-button", "pane-menu", "open-palette"]
        let toggle = element(app, "toggle-sidebar")
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "the sidebar button is in the toolbar")
        let sidebar = element(app, "sidebar-inbox")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "the sidebar shows")
        XCTAssertFalse(element(app, "tab-bar").exists, "no strip while the sidebar holds the tabs")
        sleep(1)
        let shownFrames = ids.map { element(app, $0).frame }
        attach(app, "sidebar-shown")

        press(toggle)
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 5), "the button hides the sidebar")
        XCTAssertTrue(element(app, "tab-bar").waitForExistence(timeout: 5), "the tabs move to the strip")
        sleep(1)
        let hiddenFrames = ids.map { element(app, $0).frame }
        attach(app, "sidebar-hidden")
        for (id, (a, b)) in zip(ids, zip(shownFrames, hiddenFrames)) {
            XCTAssertEqual(a.width, b.width, accuracy: 0.5, "\(id) width differs")
            XCTAssertEqual(a.height, b.height, accuracy: 0.5, "\(id) height differs")
            XCTAssertEqual(a.minY, b.minY, accuracy: 0.5, "\(id) moved vertically")
        }
        XCTAssertEqual(hiddenFrames.map(\.minX), hiddenFrames.map(\.minX).sorted())

        // ⌘B from the terminal, both ways.
        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: pane)
        waitForExpectations(timeout: 5)
        // The Simulator attaches its hardware keyboard on the first key event of a launch and
        // drops that event (a real keyboard is attached long before): a harmless key first.
        app.typeKey(XCUIKeyboardKey.shift, modifierFlags: [])
        app.typeKey("b", modifierFlags: .command)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "⌘B shows the sidebar")
        XCTAssertTrue(element(app, "tab-bar").waitForNonExistence(timeout: 5))
        app.typeKey("b", modifierFlags: .command)
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 5), "⌘B hides it again")
        app.typeKey("b", modifierFlags: .command)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        // ⌘/ lists every shortcut, ⌘B among them.
        pane.tap()
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(element(app, "shortcuts-sheet").waitForExistence(timeout: 5), "⌘/ opens the shortcuts")
        XCTAssertTrue(app.staticTexts["Toggle Sidebar"].exists)
        attach(app, "shortcuts")
    }

    #if os(iOS)
    /// A theme picked in Settings restyles the whole window at once: the open terminal, the
    /// sidebar and the band along the bottom edge, both ways (light, then back to dark).
    func testThemeChangeRestylesTheWholeWindow() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "iPhone has no sidebar")
        let app = XCUIApplication()
        app.launchArguments += [
            "-restoreLastTarget", "NO", "-localEcho", "YES", "-ApplePersistenceIgnoreState", "YES",
            "-sidebarShown", "YES",
        ]
        app.launch()
        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 20))
        pickTheme(app, "Ghostty Default")
        try assertWindow(app, pane, light: false, "dark")
        pickTheme(app, "Builtin Light")
        try assertWindow(app, pane, light: true, "light")
        pickTheme(app, "Ghostty Default")
        try assertWindow(app, pane, light: false, "dark-again")
    }

    private func pickTheme(_ app: XCUIApplication, _ name: String) {
        press(element(app, "open-settings"))
        let row = element(app, "settings-theme")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        press(row)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(name)
        let card = element(app, "theme-\(name)")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "\(name) is listed")
        press(card)
        attach(app, "settings-\(name)")
        app.swipeDown(velocity: .fast)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Settings closed")
    }

    /// Samples the terminal (below its text), the sidebar, both bars and the bottom edge.
    private func assertWindow(_ app: XCUIApplication, _ pane: XCUIElement, light: Bool, _ name: String) throws {
        // Focused, so the key bar is up.
        pane.tap()
        Thread.sleep(forTimeInterval: 1)
        let shot = app.screenshot()
        attach(app, "theme-\(name)")
        let image = try XCTUnwrap(shot.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let sidebar = element(app, "sidebar-inbox").frame
        let barY = pane.frame.minY - 5
        var regions = [
            ("terminal", CGPoint(x: pane.frame.midX, y: pane.frame.maxY - 60)),
            ("sidebar", CGPoint(x: sidebar.midX, y: app.frame.maxY - 120)),
            ("sidebar bar", CGPoint(x: sidebar.midX, y: barY)),
            ("toolbar", CGPoint(x: pane.frame.midX, y: barY)),
            ("bottom edge", CGPoint(x: pane.frame.minX + 40, y: app.frame.maxY - 4)),
        ]
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            // Beside the key bar's capsules, over the sidebar.
            regions.append(("sidebar by the key bar", CGPoint(x: 8, y: keyboard.frame.minY - 6)))
        }
        for (region, point) in regions {
            let luma = Self.luma(image, at: CGPoint(x: point.x * scale, y: point.y * scale))
            XCTAssertEqual(luma > 128, light, "\(name): the \(region) is \(light ? "light" : "dark") (luma \(luma))")
        }
    }

    private static func luma(_ image: CGImage, at point: CGPoint) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: -point.x, y: point.y - CGFloat(image.height) + 1, width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(pixel[0]) * 3 + Int(pixel[1]) * 6 + Int(pixel[2])) / 10
    }

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
