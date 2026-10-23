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

    /// `relaunch`: the saved host only, so the window restores what it had.
    private func launch(relaunch: Bool = false) throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/w3-ui-test.sh)")
        app = XCUIApplication()
        app.launchArguments += ["-testRelay", "disabled", "-noAutoFocus", "YES", "-windowProbe", "YES", "-sidebarShown", "YES"]
            + (relaunch ? [] : ["-testTicket", ticket, "-resetWindows", "YES"])
        app.launch()
        if relaunch { return }
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

    /// A page a program opens through `BROWSER` opens in a browser pane beside it, reaching the
    /// host's `localhost` (the host's own dev server, through its proxy); it comes back after a
    /// relaunch, and closes from its bar.
    func testHostPageOpensInABrowserPaneBesideItsPane() throws {
        try launch()
        panes.firstMatch.tap()
        app.typeText("devserver 48315 localhost &\n")
        waitFor(screen, contains: "Local:", timeout: 20)
        app.typeText("\"$BROWSER\" http://localhost:48315/\n")
        let leaf = app.descendants(matching: .any)["browser-leaf"].firstMatch
        XCTAssertTrue(leaf.waitForExistence(timeout: 20), "a browser pane opens beside the pane")
        let result = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'ws=' OR value CONTAINS 'ws='")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "the page ran its checks")
        let shown = result.label.isEmpty ? (result.value as? String ?? "") : result.label
        XCTAssertTrue(shown.contains("origin=http://localhost:48315 "), shown)
        XCTAssertTrue(shown.contains("ws=echo:hello"), shown)
        let routed = app.descendants(matching: .any)["browser-routed"]
        XCTAssertTrue(routed.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(Int(routed.value as? String ?? "0") ?? 0, 0, "the page went through the host")
        XCTAssertTrue(panes.firstMatch.exists, "the terminal stays beside it")
        shot("browser-pane")

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.terminate()
        try launch(relaunch: true)
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS ', mixed:'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "the tab with the page comes back")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["browser-leaf"].firstMatch.waitForExistence(timeout: 20), "the pane comes back")
        XCTAssertTrue(result.waitForExistence(timeout: 30), "and its page")
        shot("browser-pane-restored")
        app.descendants(matching: .any)["browser-close"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["browser-leaf"].firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 10), "the terminal tab is back")
    }

    /// An agent's browser tools from its terminal (`un-hook browser`, as Codex would use them):
    /// navigate opens a page beside the pane and answers with a snapshot, refs act on it, a
    /// purchase waits for the user's Allow on the device, and a screenshot comes back.
    func testAgentDrivesThePageBesideItsPane() throws {
        try launch()
        panes.firstMatch.tap()
        app.typeText("H=$(sed -n 's/^exec \\(.*\\) open-url.*/\\1/p' \"$BROWSER\"); clear\n")
        app.typeText("printf '<title>Shop</title><button onclick=\"document.title=\\x27paid\\x27\">Pay now</button><a href=\"README.md\">Read me</a>' > shop.html\n")
        app.typeText("python3 -m http.server 48317 --bind 127.0.0.1 >/dev/null 2>&1 &\n")
        app.typeText("sleep 1; $H browser navigate url=localhost:48317/shop.html | head -5\n")
        let leaf = app.descendants(matching: .any)["browser-leaf"].firstMatch
        XCTAssertTrue(leaf.waitForExistence(timeout: 20), "the page opens beside the agent's pane")
        waitFor(screen, contains: "Page: Shop", timeout: 30)
        waitFor(screen, contains: "button \"Pay now\" [ref_", timeout: 5)
        shot("agent-navigated")

        // A purchase waits for the user.
        app.typeText("clear; R=$($H browser find query=pay | sed -n 's/.*\\[\\(ref_[0-9]*\\)\\].*/\\1/p'); $H browser click ref=$R | head -3\n")
        let allow = app.buttons["agent-allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 20), "the device asks before paying")
        shot("agent-asks")
        allow.tap()
        waitFor(screen, contains: "Done.", timeout: 20)
        app.typeText("clear; $H browser get_text | head -1; $H browser screenshot annotate=true\n")
        waitFor(screen, contains: "Page: paid", timeout: 20)
        waitFor(screen, contains: "Image saved to", timeout: 20)
        shot("agent-done")
    }

    /// What an agent learns from its actions: a button under a cookie banner is not clicked and
    /// the banner is named; once it is gone the click goes through and says what changed; a
    /// button that does nothing says so, with what to try instead.
    func testAgentLearnsWhatCoversAButtonAndWhatHadNoEffect() throws {
        try launch()
        panes.firstMatch.tap()
        app.typeText("H=$(sed -n 's/^exec \\(.*\\) open-url.*/\\1/p' \"$BROWSER\"); clear\n")
        app.typeText("printf '<title>Shop</title><div style=\"position:relative\"><button onclick=\"document.title=\\x27ordered\\x27\">Order</button>"
            + "<div id=\"consent\" style=\"position:absolute;inset:0;background:#fff\" onclick=\"this.remove()\">Accept cookies</div></div>"
            + "<button>Nothing</button>' > cover.html\n")
        app.typeText("python3 -m http.server 48318 --bind 127.0.0.1 >/dev/null 2>&1 &\n")
        app.typeText("sleep 1; $H browser navigate url=localhost:48318/cover.html | head -3\n")
        XCTAssertTrue(app.descendants(matching: .any)["browser-leaf"].firstMatch.waitForExistence(timeout: 20))
        waitFor(screen, contains: "Page: Shop", timeout: 30)
        let ref = { (query: String) in "$($H browser find query=\(query) | sed -n '1s/.*\\[\\(ref_[0-9]*\\)\\].*/\\1/p')" }

        app.typeText("clear; $H browser click ref=\(ref("order")) | head -2\n")
        waitFor(screen, contains: "is covered by", timeout: 20)
        waitFor(screen, contains: "consent", timeout: 5)
        shot("agent-covered")

        app.typeText("clear; $H browser click ref=\(ref("cookies")) | head -1; $H browser click ref=\(ref("order")) | head -1\n")
        waitFor(screen, contains: "title changed", timeout: 30)
        shot("agent-clicked")

        app.typeText("clear; $H browser click ref=\(ref("nothing")) | head -1\n")
        waitFor(screen, contains: "No observable effect", timeout: 30)
        shot("agent-no-effect")
    }
}
