#if os(iOS)
import XCTest

/// zsh: at the prompt typing goes into the native editor, the smart row offers host completions,
/// Return runs the line in one atomic submit, and esc hands the draft back to the shell.
/// Needs `PAIR_TICKET` (run with `TEST_RUNNER_PAIR_TICKET=$(apple/scripts/local-daemon.sh start)`).
@MainActor
final class LineEditorUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func wait(_ format: String, _ argument: String, _ element: XCUIElement, timeout: TimeInterval = 15) {
        expectation(for: NSPredicate(format: format, argument), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// By default the terminal takes the typing at a prompt, like any terminal: no editor row.
    func testTypingGoesToTheTerminalByDefault() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (TEST_RUNNER_PAIR_TICKET)")
        let app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-keyBar.fullWithHardwareKeyboard", "YES"]
        app.launch()

        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
        let screen = element(app, pane.identifier + "-screen")
        pane.tap()
        app.typeText("echo plain-$((6*7))")
        wait("value CONTAINS %@", "echo plain-$((6*7))", screen)
        XCTAssertFalse(element(app, "keybar-line").exists, "no line editor unless turned on")
        XCTAssertFalse(element(app, "keybar-composer").exists, "no composer for a shell")
        app.typeText("\n")
        wait("value CONTAINS %@", "plain-42", screen, timeout: 20)
    }

    func testPromptTypingGoesToTheLineEditorAndRunsAtomically() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (TEST_RUNNER_PAIR_TICKET)")
        let app = XCUIApplication()
        // The line editor is opt-in (the terminal takes typing by default).
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-keyBar.fullWithHardwareKeyboard", "YES", "-keyBar.lineEditor", "YES"]
        app.launch()

        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
        let screen = element(app, pane.identifier + "-screen")
        pane.tap()

        // At the prompt the native line editor takes over typing.
        let line = element(app, "keybar-line")
        XCTAssertTrue(line.waitForExistence(timeout: 20), "the line editor shows at the prompt")
        app.typeText("echo line-ed")
        wait("value == %@", "echo line-ed", line)

        // Wing keys insert into the draft, not the terminal.
        app.buttons["keybar-dash"].tap()
        app.typeText("$((40+2))")
        wait("value == %@", "echo line-ed-$((40+2))", line)
        shot(app, "line-editor-draft")

        // Return: one atomic submit; the shell runs it and the editor starts empty at the next prompt.
        app.buttons["keybar-line-run"].tap()
        wait("value CONTAINS %@", "line-ed-42", screen, timeout: 20)
        wait("value == %@", "", line)

        // The smart row offers history for a prefix of the last command.
        app.typeText("echo li")
        let chip = element(app, "keybar-chip-0")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "host completions show")
        shot(app, "line-editor-smart-row")

        // esc: the draft goes to the shell's own line and typing drops to the terminal.
        app.buttons["keybar-esc"].tap()
        XCTAssertTrue(line.waitForNonExistence(timeout: 10), "esc leaves the editor")
        wait("value CONTAINS %@", "echo li", screen)
        app.typeText("ne-esc\n")
        wait("value CONTAINS %@", "line-esc", screen, timeout: 20)
    }
}
#endif
