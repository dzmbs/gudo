#if os(iOS)
import XCTest

/// Mixed tabs and Two Columns.
///
/// The mixed case needs two daemons (apple/scripts/mixed-ui-test.sh starts "alpha" and "beta",
/// passes their tickets and kills alpha when asked): Split with Host puts a beta pane beside
/// alpha's in one tab; both take typing; ⌘D splits on the focused pane's host and ⌘W closes on
/// it; a relaunch restores the mixed tab with both panes live; with alpha killed, alpha's pane
/// shows its host down while beta's keeps working. Skipped without the tickets.
@MainActor
final class MixedTabsUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func screens(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'pane-' AND identifier ENDSWITH '-screen'"))
    }

    private func waitFor(_ predicate: NSPredicate, _ object: Any, timeout: TimeInterval, _ message: String = "") {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func signal(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["MARKER_DIR"] else { return }
        FileManager.default.createFile(atPath: directory + "/" + name, contents: Data())
    }

    /// The panes on screen, left to right (then top to bottom).
    private func panesByPosition(_ app: XCUIApplication) -> [XCUIElement] {
        panes(app).allElementsBoundByIndex.filter(\.exists).sorted {
            abs($0.frame.minX - $1.frame.minX) > 2 ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
    }

    /// Taps a pane, types a command and waits for its output in a screen inside that pane.
    private func type(in pane: XCUIElement, _ app: XCUIApplication, _ command: String, expect: String) {
        pane.tap()
        app.typeText(command + "\n")
        let frame = pane.frame
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            let shown = screens(app).allElementsBoundByIndex.contains { screen in
                screen.exists && frame.insetBy(dx: -2, dy: -2).contains(screen.frame) && (screen.value as? String ?? "").contains(expect)
            }
            if shown { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTFail("\(expect) did not show in the pane at \(frame)")
    }

    /// The palette: a query, then ⌘1 runs the first match.
    private func palette(_ app: XCUIApplication, _ query: String) {
        app.buttons["open-palette"].firstMatch.tap()
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the palette opens")
        field.typeText(query)
        app.typeKey("1", modifierFlags: .command)
    }

    /// `pair` picks the tickets: pairing tickets are one-time, so each test that pairs has its own.
    private func launch(tickets: Bool, directory: String, pair: String = "") throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        let alpha = env["PAIR_TICKET_A\(pair)"] ?? "", beta = env["PAIR_TICKET_B\(pair)"] ?? ""
        try XCTSkipIf(alpha.isEmpty || beta.isEmpty, "no daemon tickets (run apple/scripts/mixed-ui-test.sh)")
        let app = XCUIApplication()
        if tickets {
            app.launchArguments += ["-testTickets", "\(alpha),\(beta)", "-testTicketNames", "alpha,beta"]
        }
        // Restore on: the first launch saves the window (open hosts, mixed tab, focus), the
        // second restores it (no tickets, so no launch hook takes over).
        app.launchArguments += [
            "-testRelay", "disabled", "-hostsDirectory", directory, "-restoreLastTarget", "YES",
            "-resetWindows", "YES", "-sidebarShown", "YES", "-keyBar.lineEditor", "<false/>",
        ]
        app.launch()
        return app
    }

    func testMixedSplitAcrossHostsRelaunchesAndSurvivesOneHostGoingDown() throws {
        let env = ProcessInfo.processInfo.environment
        let directory = NSTemporaryDirectory() + "mixed-\((env["PAIR_TICKET_A"] ?? "").suffix(12))"
        var app = try launch(tickets: true, directory: directory)

        let groupA = element(app, "host-group-alpha"), groupB = element(app, "host-group-beta")
        XCTAssertTrue(groupA.waitForExistence(timeout: 40) && groupB.waitForExistence(timeout: 40))
        waitFor(NSPredicate(format: "value == 'Connected'"), groupA, timeout: 40, "alpha connected")
        waitFor(NSPredicate(format: "value == 'Connected'"), groupB, timeout: 40, "beta connected")
        XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 30), "alpha's pane")
        // iPad simulator: the first hardware key after launch is dropped.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        type(in: panes(app).firstMatch, app, "echo alpha-$((1+1))", expect: "alpha-2")

        // Split with Host… → beta: a mixed tab, alpha's pane left, beta's right.
        palette(app, "split with host")
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the host picker")
        field.typeText("beta")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(element(app, "mixed-tab").waitForExistence(timeout: 20), "a mixed tab")
        XCTAssertTrue(element(app, "host-group-mixed").waitForExistence(timeout: 5), "the sidebar's Mixed group")
        waitFor(NSPredicate(format: "count == 2"), panes(app), timeout: 20, "two panes")
        var sides = panesByPosition(app)
        XCTAssertGreaterThan(sides[1].frame.minX, sides[0].frame.maxX - 2, "side by side")
        shot(app, "mixed-split")
        type(in: sides[1], app, "echo beta-$((2+2))", expect: "beta-4")
        type(in: sides[0], app, "echo left-again-$((3+3))", expect: "left-again-6")

        // ⌘D on beta's pane opens another beta pane in the tab; ⌘W closes it (on beta).
        sides[1].tap()
        app.typeKey("d", modifierFlags: .command)
        waitFor(NSPredicate(format: "count == 3"), panes(app), timeout: 20, "⌘D split on beta")
        shot(app, "mixed-three")
        app.typeKey("w", modifierFlags: .command)
        waitFor(NSPredicate(format: "count == 2"), panes(app), timeout: 20, "⌘W closed it")
        XCTAssertTrue(element(app, "mixed-tab").exists, "still mixed")

        // Relaunch: the mixed tab comes back with both panes, both live. To the background
        // first, as iOS does before it ends an app: the scene saves its state there.
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.terminate()
        app = try launch(tickets: false, directory: directory)
        XCTAssertTrue(element(app, "mixed-tab").waitForExistence(timeout: 40), "the mixed tab is restored")
        if !panes(app).element(boundBy: 1).waitForExistence(timeout: 20) { shot(app, "mixed-restoring") }
        waitFor(NSPredicate(format: "count == 2"), panes(app), timeout: 40, "both panes")
        waitFor(NSPredicate(format: "value == 'Connected'"), element(app, "host-group-beta"), timeout: 40, "beta reconnected")
        waitFor(NSPredicate(format: "value == 'Connected'"), element(app, "host-group-alpha"), timeout: 40, "alpha reconnected")
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        sides = panesByPosition(app)
        type(in: sides[1], app, "echo back-beta-$((4+4))", expect: "back-beta-8")
        type(in: sides[0], app, "echo back-alpha-$((5+5))", expect: "back-alpha-10")
        shot(app, "mixed-restored")

        // Alpha goes down: its pane shows it, beta's keeps taking input.
        signal("kill-alpha")
        waitFor(NSPredicate(format: "value BEGINSWITH 'Reconnecting' OR value BEGINSWITH 'Can'"), element(app, "host-group-alpha"), timeout: 90, "alpha down")
        let notice = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN {'connection-notice', 'connection-overlay'} OR identifier BEGINSWITH 'stale-'"))
        waitFor(NSPredicate(format: "count > 0"), notice, timeout: 30, "alpha's pane says its host is down")
        XCTAssertTrue(element(app, "mixed-tab").exists, "the tab stays mixed")
        sides = panesByPosition(app)
        XCTAssertEqual(sides.count, 2, "alpha's pane stays (stale)")
        type(in: sides[1], app, "echo beta-alive-$((6+6))", expect: "beta-alive-12")
        shot(app, "mixed-alpha-down")
    }

    /// A kitty graphics image printed in alpha's pane, dragged onto beta's pane in the same
    /// mixed tab, is uploaded to beta and placed there (another host gets the content, not a
    /// reference).
    func testDragAnImageToAnotherHostsPane() throws {
        let app = try launch(tickets: true, directory: NSTemporaryDirectory() + "mixed-drag-\(UUID().uuidString)", pair: "2")
        XCTAssertTrue(element(app, "host-group-beta").waitForExistence(timeout: 40))
        waitFor(NSPredicate(format: "value == 'Connected'"), element(app, "host-group-alpha"), timeout: 40, "alpha connected")
        waitFor(NSPredicate(format: "value == 'Connected'"), element(app, "host-group-beta"), timeout: 40, "beta connected")
        XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 30), "alpha's pane")
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        palette(app, "split with host")
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the host picker")
        field.typeText("beta")
        app.typeKey("1", modifierFlags: .command)
        waitFor(NSPredicate(format: "count == 2"), panes(app), timeout: 20, "alpha and beta side by side")
        let sides = panesByPosition(app)
        type(in: sides[1], app, "clear; echo beta-$((7*6))", expect: "beta-42")

        // A kitty graphics PNG printed in alpha's pane: Ghostty keeps it in the pane's VT.
        let png = "iVBORw0KGgoAAAANSUhEUgAAADAAAAAYCAIAAAAzn+mLAAAALElEQVR42u3OAQkAAAgDsMcxk/0xhzUEBwuwTNcpERISEhISEhISEhIS+hVa2hBUW4vlBT8AAAAASUVORK5CYII="
        type(in: sides[0], app, "clear; printf '\\033_Gf=100,a=T,c=24,r=5;\(png)\\033\\\\\\n\\n\\n\\n\\n\\n'; echo sho''wn", expect: "shown")
        let kittyImages = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'kitty-image-'"))
        waitFor(NSPredicate(format: "count == 1"), kittyImages, timeout: 20, "the image shows in alpha's pane")
        let image = kittyImages.firstMatch
        XCTAssertTrue(sides[0].frame.contains(image.frame), "in alpha's pane")
        let placements = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'placement-'"))
        XCTAssertEqual(placements.count, 0, "nothing placed yet")
        shot(app, "mixed-drag-before")

        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.2, thenDragTo: sides[1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        waitFor(NSPredicate(format: "count == 1"), placements, timeout: 30, "placed on beta")
        XCTAssertTrue(sides[1].frame.insetBy(dx: -2, dy: -2).contains(placements.firstMatch.frame), "the copy is in beta's pane")
        XCTAssertEqual(kittyImages.count, 1, "alpha keeps its image")
        shot(app, "mixed-drag-after")
    }

    /// View ▸ Two Columns: two tabs side by side, each taking typing; focus moves between the
    /// columns without moving them; off again, one tab. This iPad's own shell (no daemon).
    func testTwoColumnsShowTwoTabsSideBySide() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "Two Columns needs a regular width")
        let app = XCUIApplication()
        app.launchArguments += [
            "-localEcho", "YES", "-restoreLastTarget", "NO", "-sidebarShown", "YES", "-resetWindows", "YES",
            "-hostsDirectory", NSTemporaryDirectory() + "columns-\(UUID().uuidString)",
        ]
        app.launch()
        XCTAssertTrue(element(app, "pane-1").waitForExistence(timeout: 20))
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        element(app, "pane-1").tap()
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(element(app, "tab-row-2").waitForExistence(timeout: 10), "a second tab")
        waitFor(NSPredicate(format: "count == 1"), panes(app), timeout: 10, "one tab on screen")

        palette(app, "two columns")
        XCTAssertTrue(element(app, "column-left").waitForExistence(timeout: 10), "the left column")
        XCTAssertTrue(element(app, "column-right").exists, "the right column")
        waitFor(NSPredicate(format: "count == 2"), panes(app), timeout: 10, "both tabs' panes")
        let left = panesByPosition(app)[0], right = panesByPosition(app)[1]
        let leftId = left.identifier, rightId = right.identifier
        XCTAssertNotEqual(leftId, rightId)
        shot(app, "two-columns")
        type(in: right, app, "right-side", expect: "right-side")
        type(in: left, app, "left-side", expect: "left-side")
        // Focus moved between the columns; the tabs stayed where they were.
        let after = panesByPosition(app)
        XCTAssertEqual(after.map(\.identifier), [leftId, rightId], "the columns keep their tabs")

        palette(app, "one column")
        waitFor(NSPredicate(format: "count == 1"), panes(app), timeout: 10, "one tab again")
        XCTAssertFalse(element(app, "column-left").exists)
    }
}
#endif
