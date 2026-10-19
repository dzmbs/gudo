import XCTest

/// Native password prompts against a real local `unnamed-hostd` (apple/scripts/askpass-ui-test.sh
/// starts one and passes its ticket as `TEST_RUNNER_PAIR_TICKET`): a script in the pane runs
/// `$SSH_ASKPASS` like ssh does, the secure card opens on the pane, the answer typed there
/// reaches the script; then a program that reads a password itself with echo off gets the
/// "Enter Password Securely" chip, and the secret is typed in without being shown. Skipped
/// without a ticket.
@MainActor
final class AskpassUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
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
    func testAskpassCardAndDetectedPrompt() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/askpass-ui-test.sh)")
        let app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled"]
        app.launch()

        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
        let screen = app.descendants(matching: .any)[pane.identifier + "-screen"]
        pane.tap()
        app.typeText("echo ready-$((40+2))\n")
        waitFor(NSPredicate(format: "value CONTAINS 'ready-42'"), screen, timeout: 20)

        // A script asks through $SSH_ASKPASS (its check splits the expected value with '', so
        // the command line on screen never contains the secret itself), as ssh does for a key passphrase.
        app.typeText("pw=$(\"$SSH_ASKPASS\" \"Enter passphrase for key 'ui-test':\"); [ \"$pw\" = hun''ter2 ] && echo ASKPASS-OK-$((40+2)) || echo ASKPASS-BAD\n")
        let card = app.descendants(matching: .any)["askpass-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the secure card opens on the pane")
        // Run from the shell here, so the asker is "a program" rather than ssh; the copy still
        // says what it wants.
        XCTAssertTrue(card.label.contains("needs a passphrase"), "it says what is asked for: \(card.label)")
        let field = app.secureTextFields["askpass-secret"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        shot(app, "askpass-card")
        if !field.hasFocus { field.tap() }
        field.typeText("hunter2")
        app.buttons["askpass-ok"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "the card closes once answered")
        waitFor(NSPredicate(format: "value CONTAINS 'ASKPASS-OK-42'"), screen, timeout: 20)
        XCTAssertFalse((screen.value as? String ?? "").contains("hunter2"), "the secret never shows")

        // Cancel: the helper fails, the script sees it.
        pane.tap()
        app.typeText("\"$SUDO_ASKPASS\" 'Password:' >/dev/null || echo CANCELLED-$((1+2))\n")
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        app.buttons["askpass-cancel"].tap()
        waitFor(NSPredicate(format: "value CONTAINS 'CANCELLED-3'"), screen, timeout: 20)

        // A program reads a password itself with echo off: the chip offers the secure field.
        pane.tap()
        app.typeText("stty -echo; printf 'Pass''word: '; read pw; stty echo; echo; [ \"$pw\" = s3''cret ] && echo DETECTED-OK-$((1+1))\n")
        let chip = app.buttons["askpass-chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "the chip appears at the hidden prompt")
        shot(app, "askpass-chip")
        chip.tap()
        let detectedField = app.secureTextFields["askpass-secret"]
        XCTAssertTrue(detectedField.waitForExistence(timeout: 5))
        if !detectedField.hasFocus { detectedField.tap() }
        detectedField.typeText("s3cret")
        app.buttons["askpass-ok"].tap()
        waitFor(NSPredicate(format: "value CONTAINS 'DETECTED-OK-2'"), screen, timeout: 20)
        XCTAssertTrue(chip.waitForNonExistence(timeout: 10), "the chip goes once echo is back")
        XCTAssertFalse((screen.value as? String ?? "").contains("s3cret"), "the secret never shows")
        shot(app, "askpass-done")
    }
}
