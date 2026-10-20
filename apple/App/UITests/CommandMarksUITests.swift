#if os(iOS)
import XCTest

/// Shell command marks (OSC 133 from the daemon's shell integration) against a real local
/// `unnamed-hostd`: a failed and a successful command get their gutter stripes (accessibility
/// elements `command-mark-<id>` with the outcome as value); a long-press on a command's rows
/// offers Copy Output, Copy Command, Re-run and Ask Agent, and each does its job; ⌘↑ / ⌘↓ jump
/// between prompts; the sidebar shows a running command; and the marks are back after the app
/// is relaunched (resume from the daemon's snapshot).
/// Needs `PAIR_TICKET` (run with `TEST_RUNNER_PAIR_TICKET=$(apple/scripts/local-daemon.sh start)`).
@MainActor
final class CommandMarksUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (TEST_RUNNER_PAIR_TICKET)")
        app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-noAutoFocus", "YES"]
        app.launch()
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
    }

    private var pane: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
    }

    private var screen: XCUIElement {
        app.descendants(matching: .any)[pane.identifier + "-screen"]
    }

    private func marks(_ value: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'command-mark-' AND value == %@", value))
    }

    private func mark(command: String, _ value: String) -> XCUIElement {
        marks(value).matching(NSPredicate(format: "label == %@", "Command: \(command)")).firstMatch
    }

    private func text(containing needle: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", needle, needle)).firstMatch
    }

    private func waitFor(_ predicate: NSPredicate, _ object: Any, timeout: TimeInterval) {
        expectation(for: predicate, evaluatedWith: object)
        waitForExpectations(timeout: timeout)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Long-presses the command's rows (beside its stripe, on the text) and picks a menu item.
    private func menu(on mark: XCUIElement, _ item: String) {
        let origin = pane.coordinate(withNormalizedOffset: .zero)
        let y = mark.frame.minY + min(mark.frame.height, 20) / 2 - pane.frame.minY
        origin.withOffset(CGVector(dx: pane.frame.width * 0.6, dy: y)).press(forDuration: 1.0)
        let entry = app.menuItems[item].firstMatch
        // The touch edit menu pages: look on the next pages too.
        let next = app.buttons["Next Page"].firstMatch
        var pages = 0
        while !entry.waitForExistence(timeout: 2), next.exists, pages < 3 {
            shot("menu-page-\(pages)")
            next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            pages += 1
        }
        XCTAssertTrue(entry.exists, "the menu offers \(item)")
        shot("menu-\(item)")
        entry.tap()
    }

    /// ⌘↑ / ⌘↓; when the synthesized key does not reach the app (XCUITest on the iPad
    /// simulator delivers ⌘-letters but not always ⌘-arrows), the same action from the palette.
    private func jump(_ title: String, key: XCUIKeyboardKey) {
        let before = screen.value as? String
        app.typeKey(key, modifierFlags: .command)
        let moved = NSPredicate { _, _ in self.screen.value as? String != before }
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 3) == .completed { return }
        XCTContext.runActivity(named: "⌘\(key == .upArrow ? "↑" : "↓") did not reach the app; using the palette") { _ in }
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        app.typeKey("k", modifierFlags: .command)
        if !field.waitForExistence(timeout: 3) {
            app.descendants(matching: .any)["open-palette"].firstMatch.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the palette opens")
        field.typeText(title + "\n")
    }

    // MARK: Tests

    func testMarksMenuPromptJumpsAndResume() throws {
        try launch()
        pane.tap()
        sleep(2)  // the software keyboard resizes the pane
        app.typeText("clear\n")
        app.typeText("printf 'alpha\\nbeta\\n'; false\n")
        app.typeText("true\n")

        // A red stripe for the failure, a faint one for the success.
        let failed = mark(command: "printf 'alpha\\nbeta\\n'; false", "Failed, exit 1")
        XCTAssertTrue(failed.waitForExistence(timeout: 20), "the failed command is marked")
        let succeeded = mark(command: "true", "Succeeded")
        XCTAssertTrue(succeeded.waitForExistence(timeout: 20), "the successful command is marked")
        XCTAssertLessThan(failed.frame.maxY, succeeded.frame.minY + 1, "marks follow their rows in order")
        XCTAssertGreaterThan(failed.frame.height, succeeded.frame.height, "the failed command's block holds its output rows")
        shot("marks")

        // Copy Output: the command's output only.
        menu(on: failed, "Copy Output")
        XCTAssertTrue(text(containing: "Copied 2 lines").waitForExistence(timeout: 10), "its two output lines are copied")

        // Copy Command.
        menu(on: succeeded, "Copy Command")
        XCTAssertTrue(text(containing: "Copied `true`").waitForExistence(timeout: 10), "the command line is copied")

        // Re-run types it again: a second successful `true`.
        menu(on: succeeded, "Re-run")
        waitFor(NSPredicate(format: "count >= 2"), marks("Succeeded").matching(NSPredicate(format: "label == 'Command: true'")), timeout: 20)

        // Ask Agent with no agent in the window: New Task with the command and output as prompt.
        menu(on: failed, "Ask Agent")
        let prompt = app.descendants(matching: .any)["launch-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "New Task opens")
        waitFor(NSPredicate(format: "value CONTAINS 'failed with exit status 1' AND value CONTAINS 'beta'"), prompt, timeout: 5)
        shot("ask-agent-new-task")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))

        // ⌘↑ / ⌘↓: scroll back to a prompt above the viewport and down again.
        pane.tap()
        app.typeText("seq 1 300\n")
        waitFor(NSPredicate(format: "value CONTAINS '300'"), screen, timeout: 20)
        XCTAssertFalse((screen.value as? String ?? "").contains("seq 1 300"), "its prompt scrolled out of view")
        jump("Jump to Previous Prompt", key: .upArrow)
        waitFor(NSPredicate(format: "value CONTAINS 'seq 1 300'"), screen, timeout: 5)
        XCTAssertFalse((screen.value as? String ?? "").contains("\n300\n"), "its prompt is at the top; the end of its output is out of view")
        shot("jump-previous-prompt")
        jump("Jump to Next Prompt", key: .downArrow)
        waitFor(NSPredicate(format: "value CONTAINS %@", "\n300\n"), screen, timeout: 5)

        // A running command shows in the sidebar (when the sidebar is up).
        pane.tap()
        app.typeText("sleep 12\n")
        let row = app.descendants(matching: .any)["tab-row-1"]
        if row.waitForExistence(timeout: 3) {
            waitFor(NSPredicate(format: "value CONTAINS 'Running: sleep 12'"), row, timeout: 10)
            sleep(5)
            shot("sidebar-running")
        }
        let slept = mark(command: "sleep 12", "Succeeded")
        XCTAssertTrue(slept.waitForExistence(timeout: 25), "it is marked once it ends")

        // Relaunched: the pane resumes from the daemon's snapshot and the marks are back.
        app.terminate()
        app.launch()
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "the daemon pane is back")
        XCTAssertTrue(mark(command: "sleep 12", "Succeeded").waitForExistence(timeout: 20), "marks survive a relaunch")
        shot("marks-after-relaunch")
    }
}
#endif
