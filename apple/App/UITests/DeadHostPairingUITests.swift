#if os(iOS)
import XCTest

/// Pairing a new host while the host used last is gone, the way consecutive UI suites (and a
/// user who replaced a machine) do it, against real local `gudo-hostd`s
/// (apple/scripts/dead-host-ui-test.sh): the first run pairs daemon 1 and leaves it as the
/// window's restored host; the script stops daemon 1 and starts daemon 2 on another port; the
/// second run pairs daemon 2 with daemon 1 dead in the saved hosts and window state. The new
/// host's pane must come up (and launching once more, still with daemon 1 dead, must too).
/// Uses the app's own hosts and window state on purpose: that stale state is the subject.
@MainActor
final class DeadHostPairingUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func ticket(_ name: String) throws -> String {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET_\(name)"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/dead-host-ui-test.sh)")
        return ticket
    }

    private func launch(_ ticket: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-noAutoFocus", "YES"]
        app.launch()
        return app
    }

    private func pane(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The pane shows up and its shell answers.
    private func assertShellAnswers(_ app: XCUIApplication, _ tag: String) {
        let pane = pane(app)
        let appeared = pane.waitForExistence(timeout: 30)
        if !appeared { shot(app, "\(tag)-no-pane") }
        XCTAssertTrue(appeared, "a daemon pane appears")
        let screen = app.descendants(matching: .any)[pane.identifier + "-screen"]
        pane.tap()
        // The simulator drops the first hardware key event after launch.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        app.typeText("echo \(tag)-$((40+2))\n")
        let ran = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\(tag)-42"), object: screen)
        XCTAssertEqual(XCTWaiter().wait(for: [ran], timeout: 30), .completed, "the shell ran the command")
    }

    /// Step 1 (daemon 1 up): pair it; it becomes the window's restored host.
    func test1PairFirstHost() throws {
        let app = launch(try ticket("FIRST"))
        assertShellAnswers(app, "first")
        app.terminate()
    }

    /// Step 2 (daemon 1 stopped, daemon 2 up): pair daemon 2; its pane comes up, also on a
    /// second launch.
    func test2PairSecondHostWhileFirstIsDead() throws {
        let ticket = try ticket("SECOND")
        let app = launch(ticket)
        assertShellAnswers(app, "second")
        app.terminate()
        let again = launch(ticket)
        assertShellAnswers(again, "again")
    }
}
#endif
