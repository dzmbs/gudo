import XCTest

/// The app against a real `unnamed-hostd` (apple/scripts/daemon-ui-test.sh starts one on the Mac,
/// passes its ticket as `TEST_RUNNER_PAIR_TICKET`, and restarts it while the test waits): pair,
/// type and see the echo, ⌘D splits on the daemon, and a dropped connection shows the stale
/// pane dimmed, then live again. Skipped without a ticket.
@MainActor
final class DaemonUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func screens(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'pane-' AND identifier ENDSWITH '-screen'"))
    }

    private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func waitFor(_ predicate: NSPredicate, _ element: Any, timeout: TimeInterval) {
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPairTypeSplitAndReconnect() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/daemon-ui-test.sh)")
        let app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled"]
        app.launch()

        // Paired and attached: the daemon's pane shows its shell.
        let firstPane = panes(app).firstMatch
        XCTAssertTrue(firstPane.waitForExistence(timeout: 30), "a daemon pane appears")
        let firstId = firstPane.identifier
        firstPane.tap()
        let screen = app.descendants(matching: .any)[firstId + "-screen"]
        app.typeText("echo hi-$((40+2))\n")
        waitFor(NSPredicate(format: "value CONTAINS 'hi-42'"), screen, timeout: 20)
        shot(app, "daemon-echo")

        // ⌘D: the daemon splits; a second pane appears and takes input.
        app.typeKey("d", modifierFlags: .command)
        waitFor(NSPredicate(format: "count == 2"), panes(app), timeout: 20)
        app.typeText("echo second-$((1+1))\n")
        let secondScreen = screens(app).matching(NSPredicate(format: "identifier != %@", firstId + "-screen")).firstMatch
        waitFor(NSPredicate(format: "value CONTAINS 'second-2'"), secondScreen, timeout: 20)
        shot(app, "daemon-split")

        // The driver script kills the daemon now: the panes go stale (dimmed, content kept)…
        let stale = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'stale-'")).firstMatch
        XCTAssertTrue(stale.waitForExistence(timeout: 90), "panes are dimmed while the daemon is gone")
        XCTAssertTrue(screen.exists, "never blank: the pane keeps its content")
        shot(app, "daemon-stale")
        // …and live again once it is back (the daemon restores the layout).
        XCTAssertTrue(stale.waitForNonExistence(timeout: 90), "panes go live again after reconnecting")
        waitFor(NSPredicate(format: "count == 2"), panes(app), timeout: 20)
        panes(app).firstMatch.tap()
        app.typeText("echo back-$((2+3))\n")
        waitFor(NSPredicate(format: "value CONTAINS 'back-5'"), screens(app).firstMatch, timeout: 30)
        shot(app, "daemon-live-again")
    }
}
