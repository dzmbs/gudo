import XCTest

/// Windows (docs/APP-ARCHITECTURE.md "Windows"): two iPad windows on one host, each with its own
/// tab and its own terminal on the same stream; the Handoff activity a window advertises; a
/// continued activity for a host this device does not have; the layout following the window's
/// width (compact ↔ regular) without losing the focused pane or flashing the size overlay.
///
/// The two-window test needs a daemon (apple/scripts/windows-ui-test.sh starts one and turns on
/// Stage Manager in the simulator, so both windows are on screen); the others need nothing.
@MainActor
final class WindowsUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
        // Let the previous test's windows finish closing (a launch right after can be refused).
        Thread.sleep(forTimeInterval: 3)
    }

    // MARK: Helpers

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func probes(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "window-probe")
    }

    /// The probe's fields (`WindowProbe`).
    private func probe(_ element: XCUIElement) -> [String: String] {
        guard let text = element.value as? String, let data = text.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return fields
    }

    private func handoff(_ fields: [String: String]) -> [String: Any] {
        guard let text = fields["handoff"], let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func panes(_ scope: XCUIElement) -> XCUIElementQuery {
        scope.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func screens(_ scope: XCUIElement) -> XCUIElementQuery {
        scope.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'pane-' AND identifier ENDSWITH '-screen'"))
    }

    private func seeOnScreen(_ scope: XCUIElement, _ text: String, timeout: TimeInterval = 20) -> Bool {
        let matching = screens(scope).matching(NSPredicate(format: "value CONTAINS %@", text))
        return matching.firstMatch.waitForExistence(timeout: timeout)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps a probe control (`WindowProbe`) in the window in front.
    private func tapControl(_ app: XCUIApplication, _ id: String) {
        let controls = app.buttons.matching(identifier: id)
        XCTAssertTrue(controls.firstMatch.waitForExistence(timeout: 5), id)
        let front = (0..<controls.count).map { controls.element(boundBy: $0) }.first { $0.isHittable } ?? controls.firstMatch
        front.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    /// Opens one of the app's own links, answering the system's "Open in …?" confirmation.
    private func openLink(_ app: XCUIApplication, _ link: String) {
        app.open(URL(string: link)!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 4) { open.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    private var scratch: String { NSTemporaryDirectory() + "windows-\(UUID().uuidString)" }

    /// One folder per daemon ticket: a ticket pairs once, later launches dial with the grant.
    private func daemonHosts(_ ticket: String) -> String { NSTemporaryDirectory() + "windows-\(ticket.suffix(10))" }

    // MARK: Two windows on one host

    /// ⌘N opens a second window on the same host and tab; a new tab there leaves the first
    /// window on its own tab; each window types into its own terminal and sees only what its
    /// tab's shell printed; both windows' terminals of a shared pane show the same stream.
    func testTwoWindowsOnOneHostTypeIndependently() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPad windows")
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/windows-ui-test.sh)")
        let app = XCUIApplication()
        app.launchArguments += [
            "-testTickets", ticket, "-testTicketNames", "studio", "-testRelay", "disabled",
            "-hostsDirectory", daemonHosts(ticket), "-windowProbe", "YES", "-resetWindows", "YES", "-restoreLastTarget", "NO",
            "-tabStyle", "sidebar", "-sidebarShown", "YES", "-keyBar.lineEditor", "<false/>",
        ]
        app.launch()
        let firstPane = panes(app).firstMatch
        XCTAssertTrue(firstPane.waitForExistence(timeout: 40), "the daemon's pane")
        firstPane.tap()
        app.typeText("echo one-$((40+2))\n")
        XCTAssertTrue(seeOnScreen(app, "one-42"), "window 1 typed")
        let before = probe(probes(app).firstMatch)
        XCTAssertEqual(before["windows"], "1")

        // ⌘N: a second window on the same host, on the same tab.
        app.typeKey("n", modifierFlags: .command)
        waitFor("two windows") { probes(app).count == 2 && probe(probes(app).element(boundBy: 0))["windows"] == "2" }
        waitFor("the new window on the same tab") {
            let all = (0..<probes(app).count).map { probe(probes(app).element(boundBy: $0)) }
            return all.allSatisfy { $0["host"] == before["host"] && $0["tab"] == before["tab"] }
        }
        shot(app, "windows-two-on-one-tab")
        // The second window's terminal started from the first one's: it shows the same output.
        XCTAssertTrue(seeOnScreen(app, "one-42"), "the new window shows the pane's output")
        waitFor("both windows show the pane") {
            screens(app).matching(NSPredicate(format: "value CONTAINS %@", "one-42")).count >= 2
        }

        // A new tab in the focused (new) window: only that window moves to it.
        app.typeKey("t", modifierFlags: .command)
        waitFor("one window on a new tab") {
            let tabs = (0..<probes(app).count).map { probe(probes(app).element(boundBy: $0))["tab"] ?? "" }
            return Set(tabs).count == 2 && tabs.contains(before["tab"] ?? "")
        }
        let windows = (0..<probes(app).count).map { probe(probes(app).element(boundBy: $0)) }
        let newTab = windows.first { $0["tab"] != before["tab"] }?["tab"] ?? ""
        let newPane = windows.first { $0["tab"] != before["tab"] }?["pane"] ?? ""
        XCTAssertFalse(newPane.isEmpty)
        let secondPane = app.descendants(matching: .any)["pane-\(newPane)"]
        XCTAssertTrue(secondPane.waitForExistence(timeout: 20), "the new tab's pane")
        secondPane.tap()
        app.typeText("echo two-$((40+3))\n")
        XCTAssertTrue(seeOnScreen(app, "two-43"), "window 2 typed into its own tab")

        shot(app, "windows-second-window")
        let newScreen = app.descendants(matching: .any).matching(identifier: "pane-\(newPane)-screen").firstMatch

        // Back in the first window (brought to the front, as a click on it would): it is still
        // on its tab, and typing there goes to its own pane, which never saw window 2's command.
        tapControl(app, "debug-front-0")
        let oldPane = app.descendants(matching: .any).matching(identifier: "pane-\(before["pane"] ?? "")").firstMatch
        waitFor("the first window in front") { oldPane.exists && oldPane.isHittable }
        shot(app, "windows-first-window-again")
        oldPane.tap()
        let oldScreen = app.descendants(matching: .any).matching(identifier: "pane-\(before["pane"] ?? "")-screen").firstMatch
        XCTAssertTrue(oldScreen.waitForExistence(timeout: 10), "the first window's pane")
        app.typeText("echo three-$((40+4))\n")
        waitFor("window 1 typed into its own pane") { (oldScreen.value as? String ?? "").contains("three-44") }
        XCTAssertFalse((oldScreen.value as? String ?? "").contains("two-43"), "window 1's shell never saw window 2's command")
        XCTAssertFalse((newScreen.value as? String ?? "").contains("three-44"), "window 2's shell never saw window 1's command")
        let tabs = Set((0..<probes(app).count).map { probe(probes(app).element(boundBy: $0))["tab"] ?? "" })
        XCTAssertEqual(tabs, [before["tab"] ?? "", newTab], "each window kept its own tab")
        shot(app, "windows-two-tabs")
    }

    /// One window model per window (SwiftUI rebuilding the scene's root must not make spare
    /// ones), and the design fixtures land on the window on screen: `-mock -screen splits` shows
    /// the three-pane split.
    func testOneModelPerWindowAndFixturesOnIt() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "the split fixture is iPad")
        let app = XCUIApplication()
        app.launchArguments += ["-mock", "-screen", "splits", "-windowProbe", "YES", "-resetWindows", "YES", "-noAutoFocus", "YES"]
        app.launch()
        let element = probes(app).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20))
        waitFor("three panes") { panes(app).count == 3 }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let fields = probe(element)
        XCTAssertEqual(fields["windows"], "1")
        XCTAssertEqual(fields["models"], fields["windows"], "one window model per window")
        XCTAssertEqual(panes(app).count, 3)
        shot(app, "mock-splits")
    }

    // MARK: Handoff

    /// A window advertises its host, tab and pane: the daemon's id (another device's own record
    /// of the host matches it), the host's name, and the focused pane.
    func testHandoffActivityNamesTheHostTabAndPane() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/windows-ui-test.sh)")
        let app = XCUIApplication()
        app.launchArguments += [
            "-testTickets", ticket, "-testTicketNames", "studio", "-testRelay", "disabled",
            "-hostsDirectory", daemonHosts(ticket), "-windowProbe", "YES", "-resetWindows", "YES", "-restoreLastTarget", "NO", "-keyBar.lineEditor", "<false/>",
        ]
        app.launch()
        XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 40), "the daemon's pane")
        let element = probes(app).firstMatch
        waitFor("a payload") { !handoff(probe(element)).isEmpty }
        let fields = probe(element)
        let payload = handoff(fields)
        XCTAssertEqual(payload["kind"] as? String, "daemon")
        XCTAssertEqual(payload["hostName"] as? String, "studio")
        XCTAssertFalse((payload["daemonId"] as? String ?? "").isEmpty, "the daemon's id, the same on every device")
        XCTAssertEqual((payload["tab"] as? NSNumber)?.stringValue, fields["tab"])
        XCTAssertEqual((payload["pane"] as? NSNumber)?.stringValue, fields["pane"])
        XCTAssertFalse((payload["origin"] as? String ?? "").isEmpty)
    }

    /// Another device's window on a host this device has not paired: it says so and offers Add
    /// Host, with the SSH address filled in.
    func testContinuingAnUnpairedHostOffersToAddIt() throws {
        let payload = #"{"kind":"ssh","hostId":"X","hostName":"build-box","ssh":"me@build.example","tab":3,"pane":5,"origin":"another-device","device":"This Mac"}"#
        let app = XCUIApplication()
        app.launchArguments += [
            "-hostsDirectory", scratch, "-windowProbe", "YES", "-resetWindows", "YES", "-restoreLastTarget", "NO", "-continueActivity", Data(payload.utf8).base64EncodedString(),
        ]
        app.launch()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "the not-paired alert")
        XCTAssertTrue(alert.label.contains("build-box"), alert.label)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This Mac")).firstMatch.exists)
        shot(app, "handoff-not-paired")
        alert.buttons["Add Host…"].tap()
        let field = app.textFields.matching(NSPredicate(format: "value CONTAINS %@", "me@build.example")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Add Host opened with the address")
    }

    /// A continued activity for a host this device has (matched by its SSH address here) opens
    /// it in this window, without asking.
    func testContinuingAKnownHostNeedsNoQuestion() throws {
        let payload = #"{"kind":"local","hostName":"This Mac","tab":2,"pane":1,"origin":"another-device","device":"This Mac"}"#
        let app = XCUIApplication()
        app.launchArguments += [
            "-hostsDirectory", scratch, "-windowProbe", "YES", "-resetWindows", "YES", "-restoreLastTarget", "NO", "-continueActivity", Data(payload.utf8).base64EncodedString(),
        ]
        app.launch()
        // Another device's own shell cannot continue here: a toast says so, no alert.
        let element = probes(app).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        waitFor("the activity was continued") { probe(element)["continued"] == "elsewhere" }
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    // MARK: Width buckets

    /// The window narrows past the boundary (Split View, Slide Over, a narrow Stage Manager
    /// window; here a debug width) and widens again: compact then regular layout, the same tab
    /// and focused pane throughout, and no cols × rows overlay from the switch.
    func testCrossingTheWidthBoundaryKeepsThePaneWithoutTheOverlay() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPad widths")
        let app = XCUIApplication()
        app.launchArguments += [
            "-localEcho", "YES", "-hostsDirectory", scratch, "-windowProbe", "YES", "-resetWindows", "YES", "-restoreLastTarget", "NO",
            "-tabStyle", "sidebar", "-sidebarShown", "YES", "-resizeOverlay", "always",
        ]
        app.launch()
        let pane = panes(app).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 20))
        pane.tap()
        // Two panes, the second focused, and some output to keep.
        app.typeKey("d", modifierFlags: .command)
        waitFor("a split") { panes(app).count == 2 }
        let element = probes(app).firstMatch
        let focused = probe(element)["pane"] ?? ""
        let target = app.descendants(matching: .any)["pane-\(focused)"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        app.typeText("echo markerkept\n")
        XCTAssertTrue(seeOnScreen(app, "markerkept"))
        let regular = probe(element)
        XCTAssertEqual(regular["bucket"], "regular")
        XCTAssertTrue(self.element(app, "sidebar-inbox").exists, "the sidebar in regular width")

        tapControl(app, "debug-narrow")
        waitFor("compact") { probe(element)["bucket"] == "compact" }
        let compact = probe(element)
        XCTAssertEqual(compact["tab"], regular["tab"])
        XCTAssertEqual(compact["pane"], regular["pane"], "the focused pane stays focused")
        XCTAssertTrue(self.element(app, "tab-switcher").waitForExistence(timeout: 5), "the compact tab switcher")
        shot(app, "width-compact")
        XCTAssertTrue(seeOnScreen(app, "markerkept", timeout: 15), "the pane keeps its content")

        tapControl(app, "debug-wide")
        waitFor("regular again") { probe(element)["bucket"] == "regular" }
        XCTAssertTrue(self.element(app, "sidebar-inbox").waitForExistence(timeout: 5))
        let back = probe(element)
        XCTAssertEqual(back["pane"], regular["pane"])
        XCTAssertTrue(seeOnScreen(app, "markerkept", timeout: 5))
        // Let the overlay's window pass, then check none was shown by the switches.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(probe(element)["overlays"], regular["overlays"], "no cols × rows overlay from a layout switch")
        shot(app, "width-regular")
    }

    /// iPhone: rotating crosses the boundary too (portrait compact, landscape regular), and the
    /// focused pane and its content stay.
    func testRotatingAPhoneSwitchesLayoutsByWidth() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "iPhone")
        let app = XCUIApplication()
        app.launchArguments += [
            "-localEcho", "YES", "-hostsDirectory", scratch, "-windowProbe", "YES", "-resetWindows", "YES", "-restoreLastTarget", "NO",
            "-noAutoFocus", "YES",
        ]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let element = probes(app).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20))
        waitFor("compact") { probe(element)["bucket"] == "compact" }
        let pane = panes(app).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 20))
        let portrait = probe(element)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitFor("regular in landscape") { probe(element)["bucket"] == "regular" }
        XCTAssertEqual(probe(element)["pane"], portrait["pane"])
        shot(app, "phone-landscape-regular")
        XCUIDevice.shared.orientation = .portrait
        waitFor("compact again") { probe(element)["bucket"] == "compact" }
        XCTAssertEqual(probe(element)["pane"], portrait["pane"])
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(probe(element)["overlays"], portrait["overlays"], "no overlay from the layout switches")
    }
}
