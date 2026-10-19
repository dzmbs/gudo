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

    /// New Task through the palette: a shell in a new worktree named `name`.
    private func newTask(_ name: String) {
        palette("New Task")
        let nameField = element("task-name")
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "the New Task sheet opens with a name")
        nameField.tap()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(name)
        app.buttons["Shell"].firstMatch.tap()
        shot("new-task")
        element("launch-start").tap()
    }

    // MARK: Tests

    /// New Task makes a worktree on a branch named after the task, runs the repository's setup
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
        // Close the popover.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        if element("pr-popover").exists { panes.firstMatch.tap() }

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
}
