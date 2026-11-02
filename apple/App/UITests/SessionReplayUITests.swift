import XCTest

/// Session Replay on the shared daemon fixtures (`UI_TEST_CLASS=SessionReplayUITests
/// apple/scripts/w3-ui-test.sh`): an agent's browser tools from its terminal (`gudo-hook
/// browser`) drive a page; the page's Replays then open the session, which steps action by
/// action and exports as a Playwright test. Skipped without a ticket.
@MainActor
final class SessionReplayUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/w3-ui-test.sh)")
        app = XCUIApplication()
        app.launchArguments += ["-testRelay", "disabled", "-noAutoFocus", "YES", "-sidebarShown", "YES",
                                "-testTicket", ticket, "-resetWindows", "YES"]
        app.launch()
        if !panes.firstMatch.waitForExistence(timeout: 30) {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 30), "a daemon pane appears")
        waitFor(screen, contains: "proj", timeout: 20)
    }

    private var panes: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private var screen: XCUIElement {
        app.descendants(matching: .any)[panes.firstMatch.identifier + "-screen"]
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
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

    func testAgentSessionReplaysStepByStepAndExports() throws {
        try launch()
        panes.firstMatch.tap()
        app.typeText("H=$(sed -n 's/^exec \\(.*\\) open-url.*/\\1/p' \"$BROWSER\"); clear\n")
        app.typeText("printf '<title>Signup</title><label>Name <input id=n></label><button onclick=\"document.title=\\x27Welcome \\x27+n.value; this.textContent=\\x27Sent\\x27\">Go</button>' > signup.html\n")
        app.typeText("python3 -m http.server 48318 --bind 127.0.0.1 >/dev/null 2>&1 &\n")
        app.typeText("sleep 1; $H browser navigate url=localhost:48318/signup.html | head -3\n")
        XCTAssertTrue(element("browser-leaf").waitForExistence(timeout: 20), "the page opens beside the agent's pane")
        waitFor(screen, contains: "ref_", timeout: 30)

        app.typeText("clear; ref() { $H browser find query=\"$1\" | sed -n 's/.*\\[\\(ref_[0-9]*\\)\\].*/\\1/p' | head -1; }\n")
        app.typeText("$H browser fill ref=$(ref name) value=Ada | head -1; $H browser click ref=$(ref go) | head -1; echo step-$((40+2))\n")
        waitFor(screen, contains: "step-42", timeout: 40)
        shot("agent-acted")

        // The page's Replays: its one session opens straight away.
        let replays = app.buttons["browser-replays"].firstMatch
        XCTAssertTrue(replays.waitForExistence(timeout: 20), "the page offers its replays")
        replays.tap()
        XCTAssertTrue(element("replay-action-0").waitForExistence(timeout: 20), "the session's steps")
        XCTAssertTrue(element("replay-action-2").exists, "navigate, fill, click: \(app.debugDescription)")
        XCTAssertTrue(element("replay-player").waitForExistence(timeout: 20), "the recorded page")
        shot("replay-opened")

        let transport = element("replay-transport")
        app.buttons["replay-step-back"].firstMatch.tap()
        app.buttons["replay-step-back"].firstMatch.tap()
        expectation(for: NSPredicate(format: "value == 'step 1'"), evaluatedWith: transport)
        waitForExpectations(timeout: 10)
        app.buttons["replay-step-forward"].firstMatch.tap()
        expectation(for: NSPredicate(format: "value == 'step 2'"), evaluatedWith: transport)
        waitForExpectations(timeout: 10)
        shot("replay-step-2")
        app.buttons["replay-step-forward"].firstMatch.tap()
        expectation(for: NSPredicate(format: "value == 'step 3'"), evaluatedWith: transport)
        waitForExpectations(timeout: 10)
        shot("replay-step-3")

        app.buttons["replay-more"].firstMatch.tap()
        app.buttons["replay-export-playwright"].firstMatch.tap()
        let code = element("playwright-test-text")
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        let text = code.label + (code.value as? String ?? "")
        XCTAssertTrue(text.contains("await page.goto('http://localhost:48318/signup.html');"), text)
        XCTAssertTrue(text.contains(".fill('Ada')"), text)
        XCTAssertTrue(text.contains(".click("), text)
        shot("playwright-test")
    }
}
