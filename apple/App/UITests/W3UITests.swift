import XCTest

/// The developer-workflow screens on the iPad against a real `unnamed-hostd` with a test
/// repository, a stand-in `claude` that drives the daemon's hooks, and a stand-in `code
/// serve-web` (apple/scripts/w3-ui-test.sh sets them up and passes `PAIR_TICKET` and
/// `W3_REPO`). Skipped without a ticket.
@MainActor
final class W3UITests: XCTestCase {
    private var app: XCUIApplication!
    private var repo = ""

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(_ extra: [String] = []) throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/w3-ui-test.sh)")
        repo = ProcessInfo.processInfo.environment["W3_REPO"] ?? ""
        app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-noAutoFocus", "YES"] + extra
        app.launch()
        let pane = panes.firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
        // The shell starts in the repository (the fixtures' .zshrc) and reports it (OSC 7).
        waitFor(screenText(pane.identifier), contains: "proj", timeout: 20)
    }

    private var panes: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func screenText(_ paneId: String) -> XCUIElement {
        app.descendants(matching: .any)[paneId + "-screen"]
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func element(prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    private func text(containing needle: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", needle, needle)).firstMatch
    }

    private func waitFor(_ element: XCUIElement, contains needle: String, timeout: TimeInterval) {
        let predicate = NSPredicate(format: "value CONTAINS %@", needle)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func type(inPane text: String) {
        panes.firstMatch.tap()
        app.typeText(text)
    }

    private func palette(_ command: String) {
        let field = element("palette-field")
        if !field.exists {
            panes.firstMatch.tap()
            app.typeKey("k", modifierFlags: .command)
        }
        if !field.waitForExistence(timeout: 3) {
            element("open-palette").firstMatch.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the palette opens")
        field.typeText(command + "\n")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Files

    func testFilesBrowsePreviewFolderTrashAndWatch() throws {
        try launch()
        palette("Browse Files")
        let readme = element("file-README.md")
        XCTAssertTrue(readme.waitForExistence(timeout: 15), "the repository's files are listed")
        XCTAssertTrue(element("file-src").exists)
        XCTAssertTrue(element("file-logo.png").exists)
        shot("files-list")

        readme.tap()
        XCTAssertTrue(text(containing: "A repository for the W3 screens, edited.").waitForExistence(timeout: 10), "text preview")
        shot("files-preview-text")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        element("file-logo.png").tap()
        XCTAssertTrue(element("file-image-preview").waitForExistence(timeout: 10), "image preview")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // New folder.
        element("files-add").tap()
        app.buttons["New Folder"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.buttons["Clear text"].firstMatch.tap()
        field.typeText("made-by-test")
        app.alerts.buttons["Create"].tap()
        let folder = element("file-made-by-test")
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "the new folder shows")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/made-by-test"), "and exists on the host")

        // Move to the host's trash.
        folder.press(forDuration: 1.0)
        app.buttons["Move to Trash"].firstMatch.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Move to Trash'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(folder.waitForNonExistence(timeout: 10), "trashed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/made-by-test"))

        // A file made on the host appears by itself (the directory is watched).
        if !repo.isEmpty {
            try Data("x".utf8).write(to: URL(fileURLWithPath: repo + "/watched.txt"))
            XCTAssertTrue(element("file-watched.txt").waitForExistence(timeout: 10), "watched change shows without a reload")
            try? FileManager.default.removeItem(atPath: repo + "/watched.txt")
        }
        shot("files-after")
    }

    // MARK: Diff

    func testDiffReviewListsChangesAndTakesNotes() throws {
        try launch()
        palette("Review Changes")
        let summary = element("diff-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "the review loads")
        XCTAssertTrue(element("diff-file-README.md").exists, "the edited file")
        XCTAssertTrue(element("diff-file-notes.txt").exists, "the untracked file")
        XCTAssertTrue(element("diff-file-src/main.rs").exists)
        shot("diff-working-tree")

        // A note on an added line (side by side on iPad: the new side).
        let line = element(prefix: "diff-line-src/main.rs-")
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        line.tap()
        let noteField = element("diff-note-field")
        XCTAssertTrue(noteField.waitForExistence(timeout: 5), "the note composer opens on the line")
        noteField.typeText("Say hello to everyone")
        element("diff-note-add").tap()
        XCTAssertTrue(element("diff-note").waitForExistence(timeout: 5), "the note shows under the line")
        XCTAssertTrue(text(containing: "1 note").exists)
        XCTAssertTrue(text(containing: "No agent runs in this repository").exists, "no agent: says so instead of failing")
        XCTAssertFalse(element("diff-send-review").isEnabled)
        shot("diff-note")
    }

    // MARK: Agents: launch, approve, reply, the turn's diff, review to the agent

    func testAgentLaunchApproveReplyAndTurnReview() throws {
        try launch()
        palette("New Agent")
        let prompt = element("launch-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.tap()
        prompt.typeText("please ask permission")
        element("launch-start").tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 20), "the sheet closes once the pane exists")
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: panes)
        waitForExpectations(timeout: 20)

        // The agent asks for permission (its PermissionRequest hook): Approve from the Inbox.
        panes.firstMatch.tap()
        app.typeKey("i", modifierFlags: [.command, .shift])
        let approve = element(prefix: "inbox-approve-")
        XCTAssertTrue(approve.waitForExistence(timeout: 45), "the request shows in the Inbox")
        shot("inbox-blocked")
        approve.tap()
        XCTAssertTrue(text(containing: "Done: please ask permission").waitForExistence(timeout: 30), "the turn finishes with its reply")
        shot("inbox-finished")

        // Reply to the agent inline.
        let reply = element(prefix: "inbox-reply-")
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        let composer = element("inbox-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.typeText("second turn\n")
        XCTAssertTrue(text(containing: "Done: second turn").waitForExistence(timeout: 30), "the reply reached the agent")

        // Jump to its pane: the hook decision and both prompts are there.
        element(prefix: "inbox-open-").tap()
        let agentScreen = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ENDSWITH '-screen' AND value CONTAINS 'decision: allowed'")).firstMatch
        XCTAssertTrue(agentScreen.waitForExistence(timeout: 15), "the approval reached the agent")
        XCTAssertTrue((agentScreen.value as? String)?.contains("prompt: second turn") == true)
        shot("agent-pane")

        // What the agent's turn changed, and a review note sent back to it.
        palette("Review Changes")
        XCTAssertTrue(element("diff-summary").waitForExistence(timeout: 15))
        element("diff-scope").tap()
        let turn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Claude Code · turn'")).firstMatch
        XCTAssertTrue(turn.waitForExistence(timeout: 10), "the agent's turns are listed")
        turn.tap()
        XCTAssertTrue(element("diff-file-agent-notes.txt").waitForExistence(timeout: 10), "the turn's own change")
        XCTAssertFalse(element("diff-file-README.md").exists, "not the rest of the working tree")
        element(prefix: "diff-line-agent-notes.txt-").tap()
        let note = element("diff-note-field")
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.typeText("review note from the app")
        element("diff-note-add").tap()
        shot("diff-turn-note")
        let send = element("diff-send-review")
        XCTAssertTrue(send.isEnabled, "the agent in the repository takes the review")
        send.tap()
        app.buttons["sheet-done"].firstMatch.tap()
        let reviewed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ENDSWITH '-screen' AND value CONTAINS 'review note from the app'")).firstMatch
        XCTAssertTrue(reviewed.waitForExistence(timeout: 20), "the review was typed into the agent")

        // Leave the session as it was: close the agent's pane.
        reviewed.tap()
        app.typeKey("w", modifierFlags: .command)
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: panes)
        waitForExpectations(timeout: 10)
    }

    // MARK: Editor

    func testEditorOpensAndTakesTheKeyboard() throws {
        try launch()
        palette("Open in VS Code")
        let web = element("editor-web")
        XCTAssertTrue(text(containing: "Fake VS Code workbench").waitForExistence(timeout: 40), "the workbench loads over the forward")
        XCTAssertTrue(web.exists)
        shot("editor")
        // ⌘P goes to the editor, not the app's palette.
        let field = app.webViews.textFields.firstMatch
        if field.waitForExistence(timeout: 5) { field.tap() } else { app.webViews.firstMatch.tap() }
        app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(text(containing: "cmd+p").waitForExistence(timeout: 5), "⌘P reached the web view")
        XCTAssertFalse(element("palette-field").exists, "the app's palette stayed closed")
        element("editor-close").tap()
        XCTAssertTrue(web.waitForNonExistence(timeout: 5))

        // A path in the pane opens at its line.
        type(inPane: "echo src/main.rs:2\n")
        panes.firstMatch.tap()
        app.typeKey("l", modifierFlags: [.command, .shift])
        let link = element("link-src/main.rs:2")
        XCTAssertTrue(link.waitForExistence(timeout: 10), "the daemon found the path")
        shot("links")
        link.tap()
        XCTAssertTrue(text(containing: "Fake VS Code workbench").waitForExistence(timeout: 20))
        XCTAssertTrue(text(containing: "main.rs").waitForExistence(timeout: 10), "opened at the file")
        element("editor-close").tap()
    }

    // MARK: Browser

    func testDevServerIsOfferedAndOpens() throws {
        try launch()
        type(inPane: "python3 -m http.server 18765 --bind 127.0.0.1\n")
        let offer = element("port-offer-open")
        XCTAssertTrue(offer.waitForExistence(timeout: 30), "a new server is offered")
        shot("port-offer")
        offer.tap()
        XCTAssertTrue(text(containing: "Directory listing").waitForExistence(timeout: 20), "the page loads through the forward")
        shot("browser")
        element("browser-done").tap()
        XCTAssertTrue(element("port-18765").waitForExistence(timeout: 5), "the ports list shows it")
        shot("ports")
        app.buttons["Done"].firstMatch.tap()
        type(inPane: "")
        app.typeKey("c", modifierFlags: .control)
    }

    // MARK: Links, command output

    func testCopyLastCommandOutput() throws {
        try launch()
        type(inPane: "printf 'first\\nsecond\\n'\n")
        waitFor(screenText(panes.firstMatch.identifier), contains: "second", timeout: 10)
        palette("Copy Last Command Output")
        XCTAssertTrue(text(containing: "Copied 2 lines").waitForExistence(timeout: 10), "the command's output, without the prompt")
    }
}
