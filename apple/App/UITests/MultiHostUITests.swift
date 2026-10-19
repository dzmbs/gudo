import XCTest

/// One window, two live hosts (apple/scripts/multihost-ui-test.sh starts two local daemons,
/// "alpha" and "beta", passes their tickets, and kills alpha mid-test): both groups show in the
/// sidebar at once; clicking a tab on either host and ⌘1/⌘2 switch instantly with no reconnect
/// (the same connection objects, no new dials, no stale or connecting overlay); ⌘T opens on the
/// current host; killing alpha shows its group reconnecting while beta stays live and typeable.
/// Skipped without the tickets.
@MainActor
final class MultiHostUITests: XCTestCase {
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
        guard let dir = ProcessInfo.processInfo.environment["MARKER_DIR"] else { return }
        FileManager.default.createFile(atPath: dir + "/" + name, contents: Data())
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
        waitFor(NSPredicate(format: "value CONTAINS %@", expected), screens(app).firstMatch, timeout: 20, "echo \(expected)")
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
        app.launchArguments += extra + [
            "-testTickets", "\(alpha),\(beta)", "-testTicketNames", names, "-testRelay", "disabled",
            "-hostsDirectory", NSTemporaryDirectory() + "multihost-\(UUID().uuidString)", "-connectionProbe", "YES",
            "-restoreLastTarget", "NO", "-tabStyle", "sidebar", "-sidebarShown", "YES",
        ]
        app.launch()
        return app
    }

    /// iPhone: the title menu lists every host as a section with its tabs; picking a tab on the
    /// other host switches at once.
    func testPhoneSwitcherGroupsTabsByHost() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "iPhone only")
        let app = try launch(names: "studio,hetzner", extra: ["-noAutoFocus", "YES"])
        let switcher = element(app, "tab-switcher")
        XCTAssertTrue(switcher.waitForExistence(timeout: 40))
        XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 40), "studio's pane")
        // Both hosts' tabs are listed (one each, the friendly names), under their host's section.
        switcher.tap()
        let buttons = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New Tab on '"))
        waitFor(NSPredicate(format: "count == 2"), buttons, timeout: 10, "a section per host")
        XCTAssertTrue(app.staticTexts["studio"].exists || app.otherElements["studio"].exists || app.buttons["New Tab on studio"].exists)
        shot(app, "multihost-iphone-switcher")
        app.buttons["New Tab on hetzner"].tap()
        waitFor(NSPredicate(format: "label CONTAINS 'hetzner'"), switcher, timeout: 20, "now on hetzner")
        XCTAssertEqual(stale(app).count, 0)
        shot(app, "multihost-iphone-hetzner")
    }

    func testTwoHostsLiveSwitchAndOneGoesDown() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "the sidebar is iPad and Mac")
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
        waitFor(NSPredicate(format: "value CONTAINS 'on-alpha-21'"), screens(app).firstMatch, timeout: 5, "⌘1 shows alpha")
        app.typeKey("2", modifierFlags: .command)
        assertLiveAtOnce(app, "⌘2")
        waitFor(NSPredicate(format: "value CONTAINS 'on-beta-32'"), screens(app).firstMatch, timeout: 5, "⌘2 shows beta")
        // (⇧⌘[ / ⇧⌘] across hosts: HostGroupsTests; XCUITest's synthesized ⇧⌘[ reaches the
        // iPad app only sometimes, like ⇧⌘↩.)
        app.typeKey("1", modifierFlags: .command)
        waitFor(NSPredicate(format: "value CONTAINS 'on-alpha-21'"), screens(app).firstMatch, timeout: 5, "⌘1 again")
        app.typeKey("2", modifierFlags: .command)
        waitFor(NSPredicate(format: "value CONTAINS 'on-beta-32'"), screens(app).firstMatch, timeout: 5, "⌘2 again")
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
        waitFor(NSPredicate(format: "value == 'Reconnecting' OR value == 'Unreachable'"), groupA, timeout: 90, "alpha goes down")
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
