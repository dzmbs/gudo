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
    private func launch(relaunch: Bool = false, _ extra: [String] = []) throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/w3-ui-test.sh)")
        app = XCUIApplication()
        app.launchArguments += ["-testRelay", "disabled", "-noAutoFocus", "YES", "-windowProbe", "YES", "-sidebarShown", "YES"]
            + (relaunch ? [] : ["-testTicket", ticket, "-resetWindows", "YES"]) + extra
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

    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// The bar's Panes menu on a phone, which shows one leaf of a tab at a time: picks the
    /// item whose label matches.
    private func pickPane(_ predicate: NSPredicate) {
        let menu = app.buttons["Panes"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the bar's pane switcher")
        menu.tap()
        let item = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the pane is in the switcher")
        item.tap()
    }

    /// The terminal in front, taking typing (a phone shows the page instead while it is open).
    private func showTerminal() {
        if isPhone, !panes.firstMatch.exists {
            pickPane(NSPredicate(format: "label BEGINSWITH 'Pane '"))
            XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 5), "the terminal is in front")
        }
        panes.firstMatch.tap()
    }

    /// The page in front (a phone shows the terminal instead after `showTerminal`).
    private func showPage() {
        guard isPhone, panes.firstMatch.exists else { return }
        pickPane(NSPredicate(format: "label == 'localhost'"))
        XCTAssertTrue(panes.firstMatch.waitForNonExistence(timeout: 5), "the page is in front")
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
        shot("browser-pane")
        if isPhone {
            showTerminal()
        } else {
            XCTAssertTrue(panes.firstMatch.exists, "the terminal stays beside it")
        }

        #if os(iOS)
        XCUIDevice.shared.press(.home)
        #endif
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.terminate()
        try launch(relaunch: true)
        if isPhone {
            // The window comes back on the tab it showed, its terminal in front.
            XCTAssertTrue(app.descendants(matching: .any)["mixed-tab"].waitForExistence(timeout: 40), "the tab with the page comes back")
            XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 20))
            showPage()
        } else {
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS ', mixed:'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 40), "the tab with the page comes back")
            row.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["browser-leaf"].firstMatch.waitForExistence(timeout: 20), "the pane comes back")
        XCTAssertTrue(result.waitForExistence(timeout: 30), "and its page")
        shot("browser-pane-restored")
        if isPhone {
            app.buttons["browser-more"].firstMatch.tap()
            app.buttons["Close Page"].firstMatch.tap()
        } else {
            app.descendants(matching: .any)["browser-close"].firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["browser-leaf"].firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 10), "the terminal tab is back")
    }

    /// A new browser tab starts on the start page: its field is focused, the host's dev server
    /// is a tile, typing suggests it, and a tap opens it through the host.
    func testNewBrowserTabShowsTheStartPage() throws {
        // A first tab: no pages visited yet (the suite's other tests visit many), so the dev
        // servers, which sit last, are on screen.
        try launch(["-browserHistory", "<>"])
        panes.firstMatch.tap()
        app.typeText("devserver 48316 localhost &\n")
        waitFor(screen, contains: "Local:", timeout: 20)
        app.buttons["open-palette"].firstMatch.tap()
        let palette = app.textFields.matching(identifier: "command-palette").firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.typeText("New Browser Tab\n")

        let start = app.descendants(matching: .any)["start-page"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 20), "a new tab shows the start page")
        let tile = app.buttons["start-dev-48316"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "the host's dev server is a tile")
        let field = app.textFields["start-address"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        shot("start-page")
        field.tap()
        // The whole port: the suite's other dev servers (4831x) are still up.
        field.typeText("48316")
        let suggestion = app.buttons["address-suggestion-0"].firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "typing suggests the dev server")
        XCTAssertTrue(suggestion.label.contains("localhost:48316"), suggestion.label)
        shot("start-page-suggestions")
        suggestion.tap()

        let result = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'ws=' OR value CONTAINS 'ws='")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "the dev server's page loads")
        let shown = result.label.isEmpty ? (result.value as? String ?? "") : result.label
        XCTAssertTrue(shown.contains("origin=http://localhost:48316 "), shown)
        XCTAssertTrue(start.waitForNonExistence(timeout: 5), "the start page gives way to the page")
        shot("start-page-opened")
    }

    /// Its trailing end: the dev server toast can sit over the leading part.
    private func tapAddress(_ field: XCUIElement) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// The address bar as in Chrome: after a page loads, a tap on the bar takes typing again,
    /// shows the full address selected, and Return goes to what was typed; back and forward
    /// walk between the sites; pages are asked for in English.
    func testAddressBarGoesFromSiteToSite() throws {
        try launch()
        panes.firstMatch.tap()
        app.typeText("devserver 48321 localhost & devserver 48322 localhost &\n")
        waitFor(screen, contains: "48322", timeout: 20)
        app.buttons["open-palette"].firstMatch.tap()
        let palette = app.textFields.matching(identifier: "command-palette").firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.typeText("New Browser Tab\n")
        let start = app.textFields["start-address"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        start.typeText("localhost:48321\n")
        let checked = { (port: Int) in
            self.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "localhost:\(port) cookie", "localhost:\(port) cookie")).firstMatch
        }
        XCTAssertTrue(checked(48321).waitForExistence(timeout: 30), "the first site loads")

        let address = app.textFields["browser-address"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5), "the address bar is a field")
        tapAddress(address)
        waitFor(address, contains: "http://localhost:48321/", timeout: 5)
        shot("address-focused")
        address.typeText("localhost:48322\n")
        XCTAssertTrue(checked(48322).waitForExistence(timeout: 30), "typing over the selected address goes to the second site")

        tapAddress(address)
        address.typeText("localhost:48321/lang\n")
        let lang = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'lang=' OR value BEGINSWITH 'lang='")).firstMatch
        XCTAssertTrue(lang.waitForExistence(timeout: 30))
        let sent = lang.label.isEmpty ? (lang.value as? String ?? "") : lang.label
        XCTAssertEqual(sent, "lang=en-US,en;q=0.9", "pages are asked for in English")
        let scheme = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'scheme=' OR value BEGINSWITH 'scheme='")).firstMatch
        XCTAssertTrue(scheme.waitForExistence(timeout: 10))
        XCTAssertTrue(scheme.label.contains("dark") || (scheme.value as? String ?? "").contains("dark"), "the page takes the dark theme's appearance")
        shot("language")

        app.buttons["browser-back"].firstMatch.tap()
        XCTAssertTrue(checked(48322).waitForExistence(timeout: 30), "back goes to the second site")
        app.buttons["browser-back"].firstMatch.tap()
        XCTAssertTrue(checked(48321).waitForExistence(timeout: 30), "and back again to the first")
        app.buttons["browser-forward"].firstMatch.tap()
        XCTAssertTrue(checked(48322).waitForExistence(timeout: 30), "forward returns")

        // The address bar keeps taking typing after the page itself was tapped.
        checked(48322).tap()
        tapAddress(address)
        address.typeText("localhost:48321\n")
        XCTAssertTrue(checked(48321).waitForExistence(timeout: 30), "the bar still takes typing after a tap on the page")
        shot("back-forward")
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
        showTerminal()
        waitFor(screen, contains: "Page: Shop", timeout: 30)
        waitFor(screen, contains: "button \"Pay now\" [ref_", timeout: 5)
        shot("agent-navigated")

        // A purchase waits for the user.
        app.typeText("clear; R=$($H browser find query=pay | sed -n 's/.*\\[\\(ref_[0-9]*\\)\\].*/\\1/p'); $H browser click ref=$R | head -3\n")
        let allow = app.buttons["agent-allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 20), "the device asks before paying")
        shot("agent-asks")
        allow.tap()
        showTerminal()
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
        showTerminal()
        waitFor(screen, contains: "Page: Shop", timeout: 60)
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

    /// A page with a frame, a file field and dialogs, driven from the terminal: the frame's
    /// controls show in the snapshot under their frame and take actions, an upload sends a file
    /// from the host, and a confirm waits for an answer, from the agent or from the user.
    func testAgentUploadsIntoAFrameAndAnswersDialogs() throws {
        try launch()
        panes.firstMatch.tap()
        app.typeText("H=$(sed -n 's/^exec \\(.*\\) open-url.*/\\1/p' \"$BROWSER\"); mkdir -p fr; clear\n")
        app.typeText("printf '<title>Outer</title><button onclick=\"document.title=\\x27c \\x27+confirm(\\x27Leave site?\\x27)\">Ask</button><iframe src=\"inner.html\"></iframe>' > fr/outer.html\n")
        app.typeText("printf '<input type=file onchange=\"parent.document.title=\\x27got \\x27+this.files[0].name\">' > fr/inner.html\n")
        app.typeText("python3 -m http.server 48319 --bind 127.0.0.1 --directory fr >/dev/null 2>&1 &\n")
        app.typeText("sleep 1; clear; $H browser navigate url=localhost:48319/outer.html | grep -c frame\n")
        XCTAssertTrue(app.descendants(matching: .any)["browser-leaf"].firstMatch.waitForExistence(timeout: 20))
        showTerminal()
        app.typeText("clear; $H browser snapshot full=true filter=all | grep -A3 'frame f'\n")
        waitFor(screen, contains: "[ref_f1_", timeout: 30)
        shot("frame-snapshot")

        app.typeText("clear; R=$($H browser snapshot full=true filter=all | sed -n 's/.*\\[\\(ref_f[0-9_]*\\)\\].*/\\1/p' | head -1); $H browser upload ref=$R path=fr/inner.html | head -2; $H browser get_text | head -1\n")
        waitFor(screen, contains: "Page: got inner.html", timeout: 30)
        shot("uploaded")

        // The agent answers a confirm.
        app.typeText("clear; A=$($H browser find query=ask | sed -n 's/.*\\[\\(ref_[0-9]*\\)\\].*/\\1/p'); $H browser click ref=$A | tail -1\n")
        waitFor(screen, contains: "Leave site?", timeout: 30)
        showPage()
        XCTAssertTrue(app.buttons["page-dialog-accept"].waitForExistence(timeout: 10), "the user sees it too")
        shot("dialog")
        showTerminal()
        app.typeText("clear; $H browser dialog accept=false | head -1; $H browser get_text | head -1\n")
        waitFor(screen, contains: "Page: c false", timeout: 30)

        // The user answers the next one on the device.
        app.typeText("clear; $H browser click ref=$A | tail -1\n")
        let accept = app.buttons["page-dialog-accept"]
        if isPhone { waitFor(screen, contains: "Leave site?", timeout: 30) }
        showPage()
        XCTAssertTrue(accept.waitForExistence(timeout: 30))
        accept.tap()
        XCTAssertTrue(accept.waitForNonExistence(timeout: 10))
        showTerminal()
        app.typeText("clear; $H browser get_text | head -1\n")
        waitFor(screen, contains: "Page: c true", timeout: 30)
        shot("answered-by-user")
    }
}
