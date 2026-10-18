import XCTest

/// "Just ssh" to a real host, then "Install helper" and work in the daemon pane. Needs
/// `TEST_RUNNER_SSH_TARGET=user@host[:port]` and `TEST_RUNNER_SSH_KEY=/path/to/private_key`
/// (read by the simulator app from the Mac's file system); skipped otherwise. Screenshots are
/// attached for each step.
@MainActor
final class RealHostUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func screen(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[panes(app).firstMatch.identifier + "-screen"]
    }

    private func expect(_ element: XCUIElement, _ format: String, _ args: CVarArg..., timeout: TimeInterval = 30) {
        expectation(for: NSPredicate(format: format, argumentArray: args), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func run(_ app: XCUIApplication, _ line: String) {
        app.typeText(line + "\n")
    }

    func testJustSSHThenInstallHelper() throws {
        let env = ProcessInfo.processInfo.environment
        let target = env["SSH_TARGET"] ?? ""
        let key = env["SSH_KEY"] ?? ""
        try XCTSkipIf(target.isEmpty || key.isEmpty, "set TEST_RUNNER_SSH_TARGET and TEST_RUNNER_SSH_KEY")
        let app = XCUIApplication()
        app.launchArguments += ["-testSSH", target, "-testSSHKey", key, "-testTrustHostKeys", "YES"]
        app.launch()

        // 1. Plain SSH pane.
        XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 30))
        panes(app).firstMatch.tap()
        expect(screen(app), "value CONTAINS '$'")
        run(app, "echo plain-$((20+1)) $SSH_CONNECTION | cut -c1-40")
        expect(screen(app), "value CONTAINS 'plain-21'")
        shot(app, "1-plain-ssh")

        // 2. Install helper → progress → daemon pane on the same host.
        let install = app.buttons["install-helper"]
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        install.tap()
        shot(app, "2-installing")
        XCTAssertTrue(install.waitForNonExistence(timeout: 120), "switched to the daemon")
        XCTAssertTrue(panes(app).firstMatch.waitForExistence(timeout: 30))
        sleep(2)
        panes(app).firstMatch.tap()
        run(app, "echo daemon-$((30+2))")
        expect(screen(app), "value CONTAINS 'daemon-32'")
        shot(app, "3-daemon-pane")

        // 3. ls.
        run(app, "clear; ls -la / | head -20")
        expect(screen(app), "value CONTAINS 'usr'")
        shot(app, "4-ls")

        // 4. vim, then :q.
        run(app, "vim -u NONE -N")
        expect(screen(app), "value CONTAINS '~'")
        shot(app, "5-vim")
        app.typeKey(.escape, modifierFlags: [])
        run(app, ":q")
        run(app, "clear; echo vim-quit-$((4+4))")
        expect(screen(app), "value CONTAINS 'vim-quit-8'")

        // 5. Ctrl-C a sleep.
        run(app, "sleep 100")
        sleep(2)
        app.typeKey("c", modifierFlags: .control)
        run(app, "echo interrupted-$?")
        expect(screen(app), "value CONTAINS 'interrupted-130'")
        shot(app, "6-ctrl-c")

        // 6. htop if present (else top), quit with q.
        run(app, "clear; (command -v htop >/dev/null && htop) || top")
        sleep(3)
        shot(app, "7-htop")
        app.typeKey("q", modifierFlags: [])
        run(app, "clear; echo top-quit-$((5+5))")
        expect(screen(app), "value CONTAINS 'top-quit-10'")
        shot(app, "8-done")
    }
}
