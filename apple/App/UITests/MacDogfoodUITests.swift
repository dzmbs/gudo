#if os(macOS)
import AppKit
import XCTest

/// The Mac dogfood checklist, on a local tab and on a daemon pane: Ctrl-C and Ctrl-Z reach the
/// foreground job, vim enters and leaves the alternate screen, the pane survives a resize during
/// output, and closing a tab ends its processes (checked with pgrep). The daemon variant needs
/// `PAIR_TICKET` (apple/scripts/local-daemon.sh start; TEST_RUNNER_PAIR_TICKET=… xcodebuild test).
@MainActor
final class MacDogfoodUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    func testLocalTab() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO"]
        app.launch()
        try checklist(app)
    }

    func testDaemonPane() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket")
        let app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled"]
        app.launch()
        try checklist(app)
    }

    private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func checklist(_ app: XCUIApplication) throws {
        let pane = panes(app).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30))
        pane.click()
        expect(pane, "") // the shell is up
        type(app, "echo ready-$((1+1))")
        expect(pane, "ready-2")

        // Ctrl-C interrupts the foreground job.
        type(app, "sleep 100")
        sleep(1)
        app.typeKey("c", modifierFlags: .control)
        type(app, "echo after-int-$((2+2))")
        expect(pane, "after-int-4")

        // Ctrl-Z stops it; the shell takes over again.
        type(app, "sleep 101")
        sleep(1)
        app.typeKey("z", modifierFlags: .control)
        type(app, "kill %1; echo after-stop-$((3+3))")
        expect(pane, "after-stop-6")

        // vim: alternate screen in, :q out.
        type(app, "vim -u NONE -N")
        expect(pane, "~")
        snapshot(app, "vim")
        app.typeKey(.escape, modifierFlags: [])
        type(app, ":q")
        type(app, "clear; echo after-vim-$((4+4))")
        expect(pane, "after-vim-8")

        // Resize during output: split (the pane halves) while it prints.
        type(app, "seq 1 300000 | tail -c 0; for i in $(seq 1 3000); do echo line-$i; done")
        app.typeKey("d", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)
        pane.click()
        type(app, "clear; echo after-resize-$((5+5))")
        expect(pane, "after-resize-10")

        // Closing a tab ends its processes.
        app.typeKey("t", modifierFlags: .command)
        let marker = Int.random(in: 40000...49999)
        sleep(2)
        type(app, "sleep \(marker)")
        XCTAssertTrue(waitFor(timeout: 10) { self.pgrep("sleep \(marker)") }, "the job runs")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitFor(timeout: 10) { !self.pgrep("sleep \(marker)") }, "closing the tab killed it")
        snapshot(app, "after-checklist")
    }

    private func type(_ app: XCUIApplication, _ line: String) {
        app.typeText(line)
        app.typeKey(.return, modifierFlags: [])
    }

    private func expect(_ element: XCUIElement, _ text: String) {
        let predicate = NSPredicate { object, _ in
            guard let value = (object as? XCUIElement)?.value as? String else { return false }
            return text.isEmpty ? !value.isEmpty : value.contains(text)
        }
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: 20)
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func pgrep(_ pattern: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "^\(pattern)$"]
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
