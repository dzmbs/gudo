import XCTest

/// One window, two live hosts (apple/scripts/multihost-ui-test.sh starts two local daemons,
/// "alpha" and "beta", passes their tickets, and kills alpha mid-test): both groups show in the
/// sidebar at once; clicking a tab on either host and ⌘1/⌘2 switch instantly with no reconnect
/// (the same connection objects, no new dials, no stale or connecting overlay); ⌘T opens on the
/// current host; killing alpha shows its group reconnecting while beta stays live and typeable.
/// Skipped without the tickets.
@MainActor
final class MultiHostUITests: XCTestCase {
    /// The device is an iPhone (UIDevice does not exist on the Mac).
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func screens(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'pane-' AND identifier ENDSWITH '-screen'"))
    }

    private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func stale(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'stale-'"))
    }

    private func waitFor(_ predicate: NSPredicate, _ element: Any, timeout: TimeInterval, _ message: String = "") {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message)
    }

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }

    /// Tells the driver script (which owns the daemons) to act: a marker file in its directory.
    private func signal(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["MARKER_DIR"] else { return }
        FileManager.default.createFile(atPath: directory + "/" + name, contents: Data())
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Types into the pane on screen and waits for the echo.
    private func typeAndSee(_ app: XCUIApplication, _ command: String, _ expected: String) {
        let pane = panes(app).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a pane is on screen")
        pane.tap()
        app.typeText(command + "\n")
        seeOnScreen(app, expected, timeout: 20)
    }

    /// Some pane's screen shows `text` (any of them: the accessibility tree can hold a pane
    /// screen that is leaving alongside the one on screen).
    private func seeOnScreen(_ app: XCUIApplication, _ text: String, timeout: TimeInterval) {
        let matching = screens(app).matching(NSPredicate(format: "value CONTAINS %@", text))
        waitFor(NSPredicate(format: "count > 0"), matching, timeout: timeout, "a screen shows \(text)")
    }

    /// A place whose tabs all closed must still offer a terminal,
    /// in the sidebar (New Terminal under it) and in the terminal area (the welcome view with
    /// New Terminal ⌘T), never a dead end; on the Inbox, + is New Terminal first. A daemon host
    /// cannot be held at zero tabs (the daemon drops an empty session and the client attaches a
    /// fresh one with a shell), so this runs on this iPad's own group (`-localEcho YES`), which
    /// draws the same group, row and welcome view. Needs no daemon.
    func testNewTerminalWhereNoTabsAreOpen() throws {
        try XCTSkipIf(Self.isPhone, "the sidebar is iPad and Mac")
        let app = XCUIApplication()
        app.launchArguments += [
            "-localEcho", "YES", "-restoreLastTarget", "NO", "-sidebarShown", "YES",
            "-hostsDirectory", NSTemporaryDirectory() + "multihost-empty-\(UUID().uuidString)",
        ]
        app.launch()
        let row1 = element(app, "tab-row-1")
        XCTAssertTrue(row1.waitForExistence(timeout: 20), "this iPad's tab")
        // Close the only tab from its context menu.
        row1.press(forDuration: 1.2)
        let close = app.buttons["Close Tab"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(row1.waitForNonExistence(timeout: 10), "no tabs left")
        // The group stays, with New Terminal; the terminal area is the welcome view.
        let newTerminal = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'new-terminal-'")).firstMatch
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 10), "New Terminal in the sidebar")
        XCTAssertTrue(element(app, "welcome").waitForExistence(timeout: 10), "the welcome view, not a void")
        XCTAssertTrue(element(app, "welcome-new-terminal").exists, "New Terminal ⌘T in the welcome view")
        shot(app, "multihost-no-tabs")
        newTerminal.tap()
        XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 20), "a shell pane")
        XCTAssertTrue(element(app, "tab-row-1").waitForExistence(timeout: 10))
        // From Agents, + ▸ New Terminal opens one and goes back to it.
        element(app, "sidebar-inbox").tap()
        let plus = element(app, "inbox-new")
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "+ on Agents")
        plus.tap()
        let terminalItem = element(app, "inbox-new-terminal")
        XCTAssertTrue(terminalItem.waitForExistence(timeout: 5), "+ lists New Terminal")
        terminalItem.tap()
        XCTAssertTrue(element(app, "tab-row-2").waitForExistence(timeout: 10), "+ on Agents opened a terminal")
        XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 10), "back on the terminal")
    }

    /// Right after a switch: the pane is live (no stale dimming, no connecting card).
    private func assertLiveAtOnce(_ app: XCUIApplication, _ what: String) {
        XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 2), "\(what): the pane shows at once")
        XCTAssertEqual(stale(app).count, 0, "\(what): no stale overlay")
        XCTAssertFalse(element(app, "connecting").exists, "\(what): no connecting screen")
    }

    private func launch(names: String = "alpha,beta", extra: [String] = []) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        let alpha = env["PAIR_TICKET_A"] ?? "", beta = env["PAIR_TICKET_B"] ?? ""
        try XCTSkipIf(alpha.isEmpty || beta.isEmpty, "no daemon tickets (run apple/scripts/multihost-ui-test.sh)")
        let app = XCUIApplication()
        // The prompt line editor is off (a plist `<false/>`: the editor reads `as? Bool`, and a
        // plain "NO" argument is a string). With it on, its text field holds the keyboard at a
        // daemon prompt, inside the keyboard's accessory window, so ⌘ shortcuts never reach the
        // scene's commands, and typed text goes to the field.
        app.launchArguments += extra + [
            "-testTickets", "\(alpha),\(beta)", "-testTicketNames", names, "-testRelay", "disabled",
            "-hostsDirectory", NSTemporaryDirectory() + "multihost-\(alpha.suffix(10))\(beta.suffix(10))", "-connectionProbe", "YES",
            "-restoreLastTarget", "NO", "-sidebarShown", "YES", "-keyBar.lineEditor", "<false/>",
        ]
        app.launch()
        return app
    }

    /// iPhone: the title menu lists every host as a section with its tabs; picking a tab on the
    /// other host switches at once.
    func testPhoneSwitcherGroupsTabsByHost() throws {
        try XCTSkipIf(!Self.isPhone, "iPhone only")
        let app = try launch(names: "studio,cloud", extra: ["-noAutoFocus", "YES"])
        let switcher = element(app, "tab-switcher")
        XCTAssertTrue(switcher.waitForExistence(timeout: 40))
        XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 40), "studio's pane")
        // Both hosts' tabs are listed (one each, the friendly names), under their host's section.
        switcher.tap()
        let buttons = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Terminal on '"))
        waitFor(NSPredicate(format: "count == 2"), buttons, timeout: 10, "a section per host")
        XCTAssertTrue(app.staticTexts["studio"].exists || app.otherElements["studio"].exists || app.buttons["New Terminal on studio"].exists)
        shot(app, "multihost-iphone-switcher")
        app.buttons["New Terminal on cloud"].tap()
        waitFor(NSPredicate(format: "label CONTAINS 'cloud'"), switcher, timeout: 20, "now on cloud")
        XCTAssertEqual(stale(app).count, 0)
        shot(app, "multihost-iphone-cloud")
    }

    func testTwoHostsLiveSwitchAndOneGoesDown() throws {
        try XCTSkipIf(Self.isPhone, "the sidebar is iPad and Mac")
        let app = try launch()

        // Both hosts at once, each group live, one tab each: ⌘1 is alpha's, ⌘2 beta's.
        let groupA = element(app, "host-group-alpha"), groupB = element(app, "host-group-beta")
        XCTAssertTrue(groupA.waitForExistence(timeout: 40), "alpha's group")
        XCTAssertTrue(groupB.waitForExistence(timeout: 40), "beta's group")
        waitFor(NSPredicate(format: "value == 'Connected'"), groupA, timeout: 40, "alpha connected")
        waitFor(NSPredicate(format: "value == 'Connected'"), groupB, timeout: 40, "beta connected")
        let row1 = element(app, "tab-row-1"), row2 = element(app, "tab-row-2")
        XCTAssertTrue(row1.waitForExistence(timeout: 30) && row2.waitForExistence(timeout: 30), "a tab on each host")
        XCTAssertTrue(row1.label.hasSuffix("alpha"), "tab 1 is alpha's: \(row1.label)")
        XCTAssertTrue(row2.label.hasSuffix("beta"), "tab 2 is beta's: \(row2.label)")

        let probe = element(app, "connection-probe")
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        waitFor(NSPredicate(format: "value CONTAINS 'alpha=' AND value CONTAINS 'beta='"), probe, timeout: 10)
        let connections = value(probe)

        // Alpha is on screen (the first hooked host): type there.
        typeAndSee(app, "echo on-alpha-$((20+1))", "on-alpha-21")
        shot(app, "multihost-alpha")

        // Click beta's tab: beta's pane, live at once; type there.
        row2.tap()
        assertLiveAtOnce(app, "click beta")
        typeAndSee(app, "echo on-beta-$((30+2))", "on-beta-32")
        shot(app, "multihost-beta")

        // ⌘1 → alpha (its screen still has its output), ⌘2 → beta, ⌘1 again: no reconnect.
        app.typeKey("1", modifierFlags: .command)
        assertLiveAtOnce(app, "⌘1")
        waitFor(NSPredicate(format: "selected == true"), row1, timeout: 5, "⌘1 shows alpha")
        seeOnScreen(app, "on-alpha-21", timeout: 5)
        app.typeKey("2", modifierFlags: .command)
        assertLiveAtOnce(app, "⌘2")
        waitFor(NSPredicate(format: "selected == true"), row2, timeout: 5, "⌘2 shows beta")
        seeOnScreen(app, "on-beta-32", timeout: 5)
        // (⇧⌘[ / ⇧⌘] across hosts: HostGroupsTests; XCUITest's synthesized ⇧⌘[ reaches the
        // iPad app only sometimes, like ⇧⌘↩.)
        app.typeKey("1", modifierFlags: .command)
        waitFor(NSPredicate(format: "selected == true"), row1, timeout: 5, "⌘1 again")
        seeOnScreen(app, "on-alpha-21", timeout: 5)
        app.typeKey("2", modifierFlags: .command)
        waitFor(NSPredicate(format: "selected == true"), row2, timeout: 5, "⌘2 again")
        seeOnScreen(app, "on-beta-32", timeout: 5)
        XCTAssertEqual(value(probe), connections, "the same connection objects, no new dials, after switching")

        // ⌘T opens on the current host (beta): beta now has two tabs (rows 2 and 3).
        app.typeKey("t", modifierFlags: .command)
        let row3 = element(app, "tab-row-3")
        XCTAssertTrue(row3.waitForExistence(timeout: 20), "a third tab")
        XCTAssertTrue(row3.label.hasSuffix("beta"), "⌘T opened on beta: \(row3.label)")
        typeAndSee(app, "echo beta-two-$((4+4))", "beta-two-8")
        shot(app, "multihost-new-tab")

        // Ask the driver script to kill alpha: alpha's group reconnects…
        signal("kill-alpha")
        waitFor(NSPredicate(format: "value BEGINSWITH 'Reconnecting' OR value BEGINSWITH 'Can'"), groupA, timeout: 90, "alpha goes down")
        // …while beta stays live and takes input.
        XCTAssertEqual(value(groupB), "Connected", "beta stays connected")
        XCTAssertEqual(stale(app).count, 0, "beta's panes are not stale")
        typeAndSee(app, "echo still-beta-$((5+5))", "still-beta-10")
        shot(app, "multihost-alpha-down")

        // Alpha comes back (the script restarts it): its group is live again, its tab shows.
        signal("restart-alpha")
        waitFor(NSPredicate(format: "value == 'Connected'"), groupA, timeout: 90, "alpha back")
        row1.tap()
        waitFor(NSPredicate(format: "count == 0"), stale(app), timeout: 30, "alpha's pane live again")
        typeAndSee(app, "echo alpha-back-$((6+6))", "alpha-back-12")
        shot(app, "multihost-alpha-back")
    }
}
