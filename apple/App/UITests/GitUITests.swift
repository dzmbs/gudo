import XCTest

/// The git workspace on the iPad against a real `unnamed-hostd` with a git repository (an
/// origin, a second worktree) and a stand-in `gh` that answers from fixture JSON
/// (apple/scripts/git-ui-test.sh sets them up and passes `PAIR_TICKET` and `GIT_FIXTURES`).
/// Skipped without a ticket.
@MainActor
final class GitUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixtures = ""

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(_ extra: [String] = []) throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/git-ui-test.sh)")
        fixtures = ProcessInfo.processInfo.environment["GIT_FIXTURES"] ?? ""
        app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-noAutoFocus", "YES"] + extra
        app.launch()
        let pane = panes.firstMatch
        if !pane.waitForExistence(timeout: 30) {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
    }

    /// A phone has no sidebar: worktrees are acted on from the palette and the bar's PR button.
    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// Closes the checks popover (a sheet on a phone).
    private func closePRPopover() {
        let popover = element("pr-popover")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        if popover.exists { isPhone ? popover.swipeDown(velocity: .fast) : panes.firstMatch.tap() }
        XCTAssertTrue(popover.waitForNonExistence(timeout: 5), "the popover closes")
    }

    private var panes: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func text(containing needle: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", needle, needle)).firstMatch
    }

    private func palette(_ command: String) {
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        panes.firstMatch.tap()
        app.typeKey("k", modifierFlags: .command)
        if !field.waitForExistence(timeout: 3) {
            element("open-palette").tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the palette opens")
        field.typeText(command)
        // Let the results settle on the typed query before Return runs the first one.
        Thread.sleep(forTimeInterval: 0.4)
        field.typeText("\n")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func ghLog() -> String {
        (try? String(contentsOfFile: fixtures + "/fixtures/log", encoding: .utf8)) ?? ""
    }

    private func waitForGhLog(_ needle: String, timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ghLog().contains(needle) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("gh was not asked to \(needle); log:\n\(ghLog())")
    }

    /// New Agent through the palette: a shell in a new worktree named `name`.
    private func newTask(_ name: String) {
        palette("New Agent")
        let nameField = element("task-name")
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "the New Agent sheet opens with a name")
        // The runner first, while the top of the sheet is in view (a phone's sheet scrolls it
        // away once the keyboard is up).
        app.buttons["Shell"].firstMatch.tap()
        // Replace the generated name by deleting it from the end, not with ⌘A: even with the
        // field focused, ⌘A sometimes left nothing selected and the typed name was appended to
        // the generated one. A plain tap brings the field into view (on a phone it can be under
        // the keyboard); the tap at its trailing edge puts the caret at the end.
        nameField.tap()
        nameField.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: nameField)
        waitForExpectations(timeout: 5)
        let generated = nameField.value as? String ?? ""
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: generated.count) + name)
        XCTAssertEqual(nameField.value as? String, name, "the task is named \(name)")
        shot("new-task")
        element("launch-start").tap()
        // The repository's setup command runs only once the owner trusts it (asked once per
        // daemon and command).
        let trust = app.alerts["Run Setup Commands for proj?"]
        if trust.waitForExistence(timeout: 10) {
            XCTAssertTrue(trust.staticTexts.matching(NSPredicate(format: "label CONTAINS 'echo setup done'")).firstMatch.exists, "the alert names the command")
            trust.buttons["Run"].tap()
        }
    }

    // MARK: Tests

    /// New Agent makes a worktree on a branch named after the task, runs the repository's setup
    /// there, and opens a tab; the toolbar then shows its pull request (from `gh`), the popover
    /// lists the checks, and the palette re-runs failed checks and merges after a confirmation.
    func testNewTaskThenPullRequestPopoverAndMergeFromThePalette() throws {
        try launch()
        // The pane is in the repository once the toolbar shows its branch.
        XCTAssertTrue(element("pr-button").waitForExistence(timeout: 30), "the focused pane's worktree in the toolbar")
        newTask("quiet-otter")

        let pr = element("pr-button")
        XCTAssertTrue(pr.waitForExistence(timeout: 30), "the toolbar shows the new worktree's pull request")
        XCTAssertTrue(text(containing: "#42").waitForExistence(timeout: 30), "#42 from gh")
        let worktree = fixtures + "/work/.unnamed/worktrees/proj/quiet-otter"
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree), "the worktree exists at \(worktree)")
        let setup = worktree + "/.setup-done"
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: setup) && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: setup), "the repository's setup ran in the new tab")
        shot("toolbar-pr")

        pr.tap()
        XCTAssertTrue(element("pr-popover").waitForExistence(timeout: 5), "the checks popover opens")
        XCTAssertTrue(text(containing: "Fix the login redirect loop").exists)
        XCTAssertTrue(text(containing: "integration tests").exists, "one row per check")
        XCTAssertTrue(text(containing: "1 failed, 1 in progress, 3 successful").exists, "the ring's summary")
        shot("pr-popover")
        element("pr-rerun").tap()
        waitForGhLog("run rerun 9002 --failed")
        closePRPopover()

        palette("Merge PR")
        let confirm = app.buttons["Merge Commit"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Merge asks first, naming the strategy")
        shot("merge-confirm")
        confirm.tap()
        waitForGhLog("pr merge 42 --merge")
        XCTAssertTrue(text(containing: "Merged #42").waitForExistence(timeout: 10), "says so")
    }

    /// The sidebar groups the host's tabs by repository and worktree: the repository header,
    /// the main branch with its tab, the idle worktree with its diff counts and PR number.
    func testSidebarGroupsTabsByRepositoryAndWorktree() throws {
        try XCTSkipIf(isPhone, "the sidebar is the iPad and Mac layout")
        try launch()
        XCTAssertTrue(element("repo-header-proj").waitForExistence(timeout: 30), "the repository's header")
        let main = element("worktree-row-main")
        XCTAssertTrue(main.waitForExistence(timeout: 10), "the main worktree's row (the pane is in it)")
        let fix = element("worktree-row-fix-login")
        XCTAssertTrue(fix.waitForExistence(timeout: 10), "the other worktree, without a tab")
        XCTAssertTrue(fix.label.contains("+2"), "its diff count: \(fix.label)")
        XCTAssertTrue(text(containing: "pull request 41").waitForExistence(timeout: 30), "its pull request: \(fix.label)")
        shot("sidebar")
        // A click on the idle worktree opens a tab there.
        fix.tap()
        XCTAssertTrue(element("pr-button").waitForExistence(timeout: 20), "the new tab is in fix-login (#41 in the toolbar)")
        shot("sidebar-fix-login")
    }

    /// A new worktree's `PORT` (the daemon's, from `worktrees.json`) shows in its sidebar row
    /// and the toolbar popover; Open localhost:PORT reaches a server the tab started on `$PORT`.
    /// Then the sidebar's menu archives it (asking first: setup left an untracked file), the
    /// palette restores it, and the menu deletes it.
    func testWorktreePortThenArchiveRestoreAndDelete() throws {
        try launch()
        XCTAssertTrue(element("pr-button").waitForExistence(timeout: 30), "the focused pane's worktree in the toolbar")
        newTask("brave-heron")
        let worktree = fixtures + "/work/.unnamed/worktrees/proj/brave-heron"
        let port = try XCTUnwrap(waitForPort(of: "brave-heron"), "the daemon gave the worktree a PORT")

        // The sidebar row (iPad, Mac) and the toolbar popover show it.
        let row = element("worktree-row-brave-heron")
        if !isPhone {
            XCTAssertTrue(row.waitForExistence(timeout: 30), "the new worktree's row")
            let labelled = NSPredicate(format: "label CONTAINS %@", "PORT \(port)")
            expectation(for: labelled, evaluatedWith: row)
            waitForExpectations(timeout: 20)
            shot("sidebar-port")
        }

        // A server on $PORT in the worktree's tab (setup runs first; wait for its prompt).
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: worktree + "/.setup-done") && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        panes.firstMatch.tap()
        app.typeText("python3 -m http.server $PORT --bind 127.0.0.1\n")
        // The server being up brings the "localhost:PORT is up" offer, which slides in from
        // under the toolbar: a tap on the toolbar while it moves did not open the popover.
        // Dismiss it so the toolbar is still.
        let offer = element("port-offer")
        XCTAssertTrue(offer.waitForExistence(timeout: 15), "the server's port is offered")
        offer.buttons["Dismiss"].firstMatch.tap()
        XCTAssertTrue(offer.waitForNonExistence(timeout: 5), "the offer goes")

        element("pr-button").tap()
        XCTAssertTrue(element("pr-popover").waitForExistence(timeout: 5), "the popover opens")
        let shown = element("worktree-port")
        XCTAssertTrue(shown.waitForExistence(timeout: 5), "the popover shows the PORT")
        XCTAssertTrue(shown.label.contains("\(port)") || (shown.value as? String)?.contains("\(port)") == true, "PORT \(port): \(shown.label)")
        shot("popover-port")
        element("worktree-open-port").tap()
        XCTAssertTrue(text(containing: "Directory listing").waitForExistence(timeout: 30), "localhost:\(port) loads through the forward")
        shot("worktree-port-browser")
        // Close the page: its leaf beside the pane (regular width), else the browser sheet,
        // which goes back to the ports list. The ports list shows it.
        let closeLeaf = element("browser-close")
        if closeLeaf.exists {
            closeLeaf.tap()
            XCTAssertTrue(closeLeaf.waitForNonExistence(timeout: 5), "the page closes")
            palette("Dev Servers & Ports")
            XCTAssertTrue(element("port-\(port)").waitForExistence(timeout: 5), "the ports list shows it")
            app.buttons["tool-close"].firstMatch.tap()
        } else {
            element("browser-done").tap()
            XCTAssertTrue(element("port-\(port)").waitForExistence(timeout: 5), "the ports list shows it")
            app.buttons["Done"].firstMatch.tap()
        }

        // Archive from the sidebar (the palette on a phone): it has an untracked file, so it asks.
        if isPhone {
            palette("Archive Worktree")
        } else {
            row.press(forDuration: 1.2)
            let archive = app.buttons["Archive Worktree…"].firstMatch
            XCTAssertTrue(archive.waitForExistence(timeout: 5), "the row's menu offers Archive")
            archive.tap()
        }
        let confirmArchive = app.buttons["Archive with Changes"].firstMatch
        XCTAssertTrue(confirmArchive.waitForExistence(timeout: 5), "archiving with changes asks first")
        shot("archive-confirm")
        confirmArchive.tap()
        XCTAssertTrue(text(containing: "Archived brave-heron").waitForExistence(timeout: 15), "says so")
        if !isPhone { XCTAssertTrue(row.waitForNonExistence(timeout: 15), "the row goes") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree), "the directory is gone")

        // Restore from the palette: it comes back with its tab.
        if !isPhone { XCTAssertTrue(element("worktree-row-main").waitForExistence(timeout: 10)) }
        palette("Restore brave-heron")
        XCTAssertTrue(text(containing: "Restored brave-heron").waitForExistence(timeout: 20), "says so")
        if isPhone {
            expectation(for: NSPredicate(format: "label CONTAINS 'brave-heron'"), evaluatedWith: element("pr-button"))
            waitForExpectations(timeout: 20)
        } else {
            XCTAssertTrue(row.waitForExistence(timeout: 20), "the row is back")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/.setup-done"), "with its changes")
        shot("restored")

        // Delete from the sidebar (the palette on a phone): asks, then removes the directory.
        if isPhone {
            palette("Delete Worktree")
        } else {
            row.press(forDuration: 1.2)
            let delete = app.buttons["Delete Worktree…"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 5), "the row's menu offers Delete")
            delete.tap()
        }
        let confirmDelete = app.buttons["Delete Worktree"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5), "deleting asks first")
        shot("delete-confirm")
        confirmDelete.tap()
        XCTAssertTrue(text(containing: "Deleted brave-heron").waitForExistence(timeout: 15), "says so")
        if !isPhone { XCTAssertTrue(row.waitForNonExistence(timeout: 15), "the row goes") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree), "the directory is gone")
    }

    /// The `PORT` the daemon recorded for a worktree (`<state>/worktrees.json`).
    private func waitForPort(of name: String, timeout: TimeInterval = 30) -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = FileManager.default.contents(atPath: fixtures + "/worktrees.json"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ports = json["ports"] as? [String: Any],
               let port = ports.first(where: { $0.key.hasSuffix("/" + name) })?.value as? Int {
                return UInt16(port)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }
}
