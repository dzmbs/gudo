import XCTest

/// Pairing the way people do it, against a real `unnamed-hostd --no-relay`
/// (apple/scripts/pairing-ui-test.sh starts it and passes one ticket per test): pasting a ticket
/// into Add Host, opening a `unnamed://pair/…` deep link, and pairing with Settings › Network on
/// "Direct and Local Network Only" with a private CA imported. Each ends on the host's shell,
/// typed into. Skipped without the tickets.
@MainActor
final class PairingUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func ticket(_ name: String) throws -> String {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET_\(name)"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/pairing-ui-test.sh)")
        return ticket
    }

    /// A fresh app: its own hosts folder (no hosts, a new device key), nothing restored.
    private func launch(_ extra: [String] = [], hosts: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-hostsDirectory", hosts ?? NSTemporaryDirectory() + "pairing-\(UUID().uuidString)",
            "-restoreLastTarget", "NO", "-resetWindows", "YES", "-sidebarShown", "YES",
            "-keyBar.lineEditor", "<false/>",
        ] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func waitFor(_ predicate: NSPredicate, _ object: Any, timeout: TimeInterval, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Scrolls the frontmost scroll view up until `element` can be tapped.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "\(element) on screen")
    }

    /// The paired host's pane is on screen and its shell answers.
    private func assertShellAnswers(_ app: XCUIApplication, _ tag: String) {
        let pane = panes(app).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 45), "the host's pane appears")
        let screen = element(app, pane.identifier + "-screen")
        pane.tap()
        app.typeText("echo \(tag)-$((40+2))\n")
        waitFor(NSPredicate(format: "value CONTAINS %@", "\(tag)-42"), screen, timeout: 30, "the shell ran the command")
        let group = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'host-group-'")).firstMatch
        if group.exists {
            waitFor(NSPredicate(format: "value == 'Connected'"), group, timeout: 20, "the sidebar shows the host connected")
        }
    }

    /// Add Host › Ticket: types the ticket (the paste field), checks the relay row, pairs.
    private func pairByTicketField(_ app: XCUIApplication, _ ticket: String, relay: String) {
        // The iPad simulator drops the first hardware key event after launch.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        let add = element(app, "hosts-add")
        XCTAssertTrue(add.waitForExistence(timeout: 20), "Add Host on the Hosts screen")
        add.tap()
        let ticketTab = app.buttons["Ticket"]
        XCTAssertTrue(ticketTab.waitForExistence(timeout: 10), "the Ticket method")
        ticketTab.tap()
        let field = app.textViews["pairing-ticket"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the ticket field")
        field.tap()
        field.typeText(ticket)
        waitFor(NSPredicate(format: "value CONTAINS %@", String(ticket.suffix(24))), field, timeout: 10, "the ticket is in the field")
        // The sheet says how the host will be reached before pairing.
        let row = element(app, "pairing-ticket-relay")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the ticket's relay")
        XCTAssertTrue(row.label.contains(relay), "relay row: \(row.label)")
        shot(app, "pairing-ticket-filled")
        let pair = element(app, "pairing-confirm")
        XCTAssertTrue(pair.isEnabled)
        pair.tap()
        XCTAssertTrue(pair.waitForNonExistence(timeout: 45), "the sheet closes once paired")
    }

    func testPairByPastingATicket() throws {
        let ticket = try ticket("PASTE")
        let app = launch(["-destination", "hosts"])
        pairByTicketField(app, ticket, relay: "None, direct only")
        assertShellAnswers(app, "pasted")
        shot(app, "pairing-pasted-connected")
    }

    func testPairByDeepLink() throws {
        let ticket = try ticket("LINK")
        XCTAssertTrue(ticket.contains("://pair/"), "a pairing link: \(ticket.prefix(20))")
        let app = launch()
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        app.open(URL(string: ticket)!)
        // The system may ask before handing its own link to the app.
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 4) { open.tap() }
        // A link never pairs by itself: Add Host shows the ticket's host to confirm.
        XCTAssertTrue(element(app, "pairing-ticket-host").waitForExistence(timeout: 10), "the link's host is shown")
        let pair = element(app, "pairing-confirm")
        XCTAssertTrue(pair.isEnabled)
        pair.tap()
        assertShellAnswers(app, "linked")
        shot(app, "pairing-deep-link-connected")
    }

    /// Settings › Network: "Direct and Local Network Only" and a private CA; the app still pairs
    /// with and drives a local daemon, and the settings survive a relaunch.
    func testDirectOnlyWithAPrivateCAStillConnects() throws {
        let ticket = try ticket("RELAY")
        let pem = NSTemporaryDirectory() + "homelab-relay-ca-\(UUID().uuidString).pem"
        try Self.homelabCA.write(toFile: pem, atomically: true, encoding: .utf8)
        let hosts = NSTemporaryDirectory() + "pairing-relay-\(UUID().uuidString)"
        var app = launch(["-destination", "hosts", "-testRelayCertificate", pem], hosts: hosts)

        openNetworkSettings(app)
        let direct = app.buttons["Direct and Local Network Only"]
        direct.tap()
        waitFor(NSPredicate(format: "selected == true"), direct, timeout: 5, "direct only is chosen")
        let importButton = element(app, "settings-relay-ca-import")
        scrollTo(importButton, in: app)
        importButton.tap()
        let certificate = element(app, "settings-relay-ca")
        XCTAssertTrue(certificate.waitForExistence(timeout: 5), "the imported CA is listed")
        XCTAssertTrue(certificate.label.contains("Homelab Relay CA"), certificate.label)
        XCTAssertTrue(certificate.label.contains("Expires"), certificate.label)
        XCTAssertFalse(element(app, "settings-relay-ca-error").exists)
        shot(app, "settings-network-direct-ca")
        app.buttons["Done"].firstMatch.tap()

        pairByTicketField(app, ticket, relay: "None, direct only")
        assertShellAnswers(app, "direct")
        shot(app, "pairing-direct-connected")

        // Relaunch: the choice and the CA are still there; the CA can be removed.
        app.terminate()
        app = launch(["-destination", "hosts"], hosts: hosts)
        openNetworkSettings(app)
        waitFor(NSPredicate(format: "selected == true"), app.buttons["Direct and Local Network Only"], timeout: 5, "still direct only")
        let kept = element(app, "settings-relay-ca")
        scrollTo(kept, in: app)
        XCTAssertTrue(kept.label.contains("Homelab Relay CA"), kept.label)
        element(app, "settings-relay-ca-remove").tap()
        XCTAssertTrue(kept.waitForNonExistence(timeout: 5), "the CA is removed")
    }

    private func openNetworkSettings(_ app: XCUIApplication) {
        let settings = app.buttons.matching(identifier: "open-settings").firstMatch
        if settings.waitForExistence(timeout: 15), settings.isHittable {
            settings.tap()
        } else {
            app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
            app.typeKey(",", modifierFlags: .command)
        }
        let direct = app.buttons["Direct and Local Network Only"]
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings is open")
        scrollTo(direct, in: app)
    }

    /// A private CA (P-256, CN "Homelab Relay CA", valid until 2036).
    static let homelabCA = """
        -----BEGIN CERTIFICATE-----
        MIIBjjCCATSgAwIBAgIUSoG9sFYaaEkWPSycjKU8bAoZRj4wCgYIKoZIzj0EAwIw
        LTEZMBcGA1UEAwwQSG9tZWxhYiBSZWxheSBDQTEQMA4GA1UECgwHSG9tZWxhYjAe
        Fw0yNjEwMjAyMTUyMjNaFw0zNjEwMTcyMTUyMjNaMC0xGTAXBgNVBAMMEEhvbWVs
        YWIgUmVsYXkgQ0ExEDAOBgNVBAoMB0hvbWVsYWIwWTATBgcqhkjOPQIBBggqhkjO
        PQMBBwNCAAQq4waIe2UN/pjLOo+U/H9nGl9Vm8a4RSKrSgBTPz8Uy8RFzotPsv0F
        key4Do2IH9pNxWnflm3DGqfPjrYJfJ7LozIwMDAdBgNVHQ4EFgQU7x9GPQB874JA
        eTMypSd6jyglmI0wDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEA
        wK2pAsrAs5VcFe04UQqd3icYpN0zltXDy+GsHNW0yjsCIBUnRBOu94Pog2SDAWTG
        R09HUVo4ApZPlQQ5SFv4T5FB
        -----END CERTIFICATE-----

        """
}
