import XCTest

/// UI_TEST_CLASS=BrowserUITests): a program's sign-in through `BROWSER` opens the system's
/// sign-in sheet, the provider's callback reaches the program on the host, and the sheet goes
/// once the program stops waiting. Skipped without a ticket.
@MainActor
final class BrowserUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/w3-ui-test.sh)")
        app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-noAutoFocus", "YES", "-windowProbe", "YES"]
        app.launch()
        let pane = panes.firstMatch
        if !pane.waitForExistence(timeout: 30) {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
        waitFor(screen, contains: "proj", timeout: 20)
    }

    private var panes: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private var screen: XCUIElement {
        app.descendants(matching: .any)[panes.firstMatch.identifier + "-screen"]
    }

    private var probe: String {
        app.descendants(matching: .any)["window-probe"].value as? String ?? ""
    }

    private func waitFor(_ element: XCUIElement, contains needle: String, timeout: TimeInterval) {
        expectation(for: NSPredicate(format: "value CONTAINS %@", needle), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// `claude /login` over `BROWSER`: the URL reaches the app (the opener succeeds), the
    /// sign-in sheet opens on its own, the provider sends the browser to the program's callback
    /// on the host's `localhost`, and once the program is signed in the sheet closes.
    func testSignInThroughBrowserReachesTheHost() throws {
        try launch()
        panes.firstMatch.tap()
        app.typeText("fake-login\n")
        waitFor(screen, contains: "opener exit 0", timeout: 20)
        shot("after-opener")
        let probeElement = app.descendants(matching: .any)["window-probe"]
        XCTAssertTrue(probeElement.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "NOT (value CONTAINS '\"signIns\":\"\"')"), evaluatedWith: probeElement)
        waitForExpectations(timeout: 10)
        shot("sign-in-sheet")
        waitFor(screen, contains: "Login successful.", timeout: 60)
        expectation(for: NSPredicate(format: "value CONTAINS '\"signIns\":\"\"'"), evaluatedWith: probeElement)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(app.state, .runningForeground, "the sheet went and the app is back: \(probe)")
        shot("signed-in")
    }
}
