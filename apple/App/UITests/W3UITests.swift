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
        if !pane.waitForExistence(timeout: 30) {
            // The first launch after an install sometimes misses the first dial; once more.
            app.terminate()
            app.launch()
        }
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
        // The palette container's identifier covers its field too (SwiftUI propagates it).
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        panes.firstMatch.tap()
        app.typeKey("k", modifierFlags: .command)
        if !field.waitForExistence(timeout: 3) {
            element("open-palette").firstMatch.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the palette opens")
        field.typeText(command + "\n")
    }

    /// The navigation back button of the pushed screen (not the sheet's Done).
    private func back() {
        let button = app.buttons["BackButton"].firstMatch
        if button.waitForExistence(timeout: 3) {
            button.tap()
        } else {
            app.navigationBars.buttons.matching(NSPredicate(format: "identifier != 'sheet-done' AND label != 'Done'")).firstMatch.tap()
        }
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
        back()

        element("file-logo.png").tap()
        XCTAssertTrue(element("file-image-preview").waitForExistence(timeout: 10), "image preview")
        back()

        // New folder.
        element("files-add").tap()
        app.buttons["New Folder"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
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

    // MARK: Agents the host lacks

    /// The fixtures have a `claude` on PATH and no `codex`: Codex shows as not installed, with
    /// OpenAI's installer for macOS, and can't be started.
    func testAgentNotInstalledOffersTheOfficialInstaller() throws {
        try launch()
        palette("New Agent")
        let runner = app.segmentedControls["task-runner"].firstMatch
        XCTAssertTrue(runner.waitForExistence(timeout: 5))
        runner.buttons.element(boundBy: 1).tap()
        let notice = element("task-agent-missing")
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "Codex shows as not installed")
        XCTAssertEqual(element("task-install-command").label, "curl -fsSL https://chatgpt.com/codex/install.sh | sh")
        XCTAssertTrue(element("task-install-run").exists)
        XCTAssertTrue(element("task-install-docs").exists)
        XCTAssertFalse(element("launch-start").isEnabled, "a missing agent can't be started")
        shot("task-agent-missing")

        runner.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5), "Claude Code is on the host")
        XCTAssertTrue(element("launch-start").isEnabled)
    }

    // MARK: Agents: launch, approve, reply, the turn's diff, review to the agent

    func testZAgentLaunchApproveReplyAndTurnReview() throws {
        try launch()
        palette("New Agent")
        let prompt = app.textViews.matching(identifier: "launch-prompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.tap()
        prompt.typeText("please ask permission")
        // In this checkout, beside the shell (a new worktree is the Git suite's case).
        let worktree = app.switches["task-worktree"].firstMatch
        XCTAssertTrue(worktree.waitForExistence(timeout: 5))
        if worktree.value as? String == "1" {
            worktree.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertEqual(worktree.value as? String, "0", "no worktree")
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
        XCTAssertTrue(approve.waitForNonExistence(timeout: 10), "answered at once")
        // The turn ends: the row offers Reply (the agent waits for its next prompt).
        let reply = element(prefix: "inbox-reply-")
        XCTAssertTrue(reply.waitForExistence(timeout: 30), "the turn finishes")
        shot("inbox-finished")

        // Reply to the agent inline.
        reply.tap()
        let composer = element("inbox-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        if (composer.value(forKey: "hasKeyboardFocus") as? Bool) != true { composer.tap() }
        composer.typeText("second turn")
        element("inbox-send").tap()
        XCTAssertTrue(text(containing: "Sent to Claude Code").waitForExistence(timeout: 15), "the reply went through")

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
        try launch(["-editorLicenceReset", "YES"])
        palette("Open in VS Code")
        // First use on this host: Microsoft's terms, accepted by the user's own tap.
        let accept = element("editor-licence-accept")
        XCTAssertTrue(accept.waitForExistence(timeout: 20), "the licence sheet comes first")
        XCTAssertTrue(element("editor-licence-vscode").exists, "the VS Code licence is linked")
        XCTAssertTrue(element("editor-licence-server").exists, "the Server licence is linked")
        XCTAssertTrue(element("editor-licence-privacy").exists, "the privacy statement is linked")
        shot("editor-licence")
        accept.tap()
        let web = element("editor-web")
        XCTAssertTrue(text(containing: "Fake VS Code workbench").waitForExistence(timeout: 40), "the workbench loads over the forward")
        XCTAssertTrue(web.exists)
        shot("editor")
        // ⌘P goes to the editor, not the app's palette.
        let field = app.webViews.textFields.firstMatch
        if field.waitForExistence(timeout: 5) { field.tap() } else { app.webViews.firstMatch.tap() }
        app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(text(containing: "cmd+p").waitForExistence(timeout: 5), "⌘P reached the web view")
        XCTAssertFalse(app.textFields.matching(identifier: "command-palette").firstMatch.exists, "the app's palette stayed closed")
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
        XCTAssertFalse(element("editor-licence-accept").exists, "accepted once per host, not asked again")
        element("editor-close").tap()
    }

    func testEditorLicenceCancelStartsNothing() throws {
        try launch(["-editorLicenceReset", "YES"])
        palette("Open in VS Code")
        let cancel = element("editor-licence-cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), "the licence sheet comes first")
        cancel.tap()
        XCTAssertTrue(element("editor-web").waitForNonExistence(timeout: 5), "Cancel leaves the editor")
        XCTAssertFalse(text(containing: "Fake VS Code workbench").exists, "nothing was started")
        // Not accepted, so asked again.
        palette("Open in VS Code")
        XCTAssertTrue(element("editor-licence-accept").waitForExistence(timeout: 20), "asked again after Cancel")
        element("editor-licence-cancel").tap()
    }

    /// The opt-in Remote Tunnel: the offer, the licence, the device code (the user signs in in
    /// their own browser; the stand-in `code` finishes by itself), then vscode.dev's stand-in with
    /// a sign-in popup that talks to its opener and closes itself.
    func testEditorTunnelShowsTheDeviceCodeAndHandlesPopups() throws {
        let web = ProcessInfo.processInfo.environment["TUNNEL_WEB"] ?? ""
        try XCTSkipIf(web.isEmpty, "no vscode.dev stand-in (run apple/scripts/w3-ui-test.sh)")
        try launch(["-editorLicenceReset", "YES", "-testTunnelWebBase", web])
        palette("Open VS Code Through a Remote Tunnel")
        let github = element("editor-tunnel-github")
        XCTAssertTrue(github.waitForExistence(timeout: 10), "the tunnel is offered with what it needs")
        shot("editor-tunnel-offer")
        github.tap()
        let accept = element("editor-licence-accept")
        XCTAssertTrue(accept.waitForExistence(timeout: 20), "Microsoft's terms first")
        accept.tap()

        XCTAssertTrue(text(containing: "FAKE-1234").waitForExistence(timeout: 20), "the device code is shown")
        XCTAssertTrue(element("editor-device-open").exists, "the page to enter it on can be opened")
        shot("editor-device-code")
        element("editor-device-copy").tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 3), "the code was copied")

        // The stand-in sign-in completes; the tunnel runs and vscode.dev (stand-in) loads.
        XCTAssertTrue(text(containing: "Fake vscode.dev workbench").waitForExistence(timeout: 40), "vscode.dev opens through the tunnel")
        XCTAssertFalse(element("editor-device-sheet").exists, "the code sheet went away")
        shot("editor-tunnel")
        let signIn = app.webViews.buttons["Sign In"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        signIn.tap()
        let finish = app.webViews.buttons["Finish Sign In"].firstMatch
        XCTAssertTrue(finish.waitForExistence(timeout: 10), "the popup opens in its own sheet")
        shot("editor-popup")
        // The popup sheet may still be settling; web elements report as not hittable meanwhile.
        finish.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(finish.waitForNonExistence(timeout: 10), "window.close() closes the popup")
        XCTAssertTrue(text(containing: "Popup said signed-in").waitForExistence(timeout: 10), "the popup kept its opener")

        element("editor-more").tap()
        let stop = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Stop Tunnel'")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(element("editor-web").waitForNonExistence(timeout: 10))
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

    /// S-BR1: a dev server opens at exactly the URL it printed (`http://web.localhost:48311`,
    /// `http://localhost:48312`), through the host's proxy: the page's `location.origin` is that
    /// URL's, its cookie reaches the server and a websocket (HMR) echoes. `browser-routed` counts
    /// the connections the app sent to the host, so a direct load (same Mac) cannot pass for it.
    func testDevServerKeepsItsOrigin() throws {
        try launch()
        for (port, name) in [(48311, "web.localhost"), (48312, "localhost")] {
            type(inPane: "devserver \(port) \(name)\n")
            let offer = element("port-offer-open")
            XCTAssertTrue(offer.waitForExistence(timeout: 30), "the new server is offered")
            offer.tap()
            let result = text(containing: "ws=")
            XCTAssertTrue(result.waitForExistence(timeout: 30), "the page ran its checks")
            let shown = result.label.isEmpty ? (result.value as? String ?? "") : result.label
            XCTAssertTrue(shown.contains("origin=http://\(name):\(port) "), "the printed origin: \(shown)")
            XCTAssertTrue(shown.contains("cookie=dev=yes"), "the page's cookie reaches the server: \(shown)")
            XCTAssertTrue(shown.contains("ws=echo:hello"), "the websocket goes through: \(shown)")
            let routed = element("browser-routed")
            XCTAssertTrue(routed.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(Int(routed.value as? String ?? "0") ?? 0, 0, "the page went through the host's proxy")
            XCTAssertTrue(element("browser-address").label.contains("\(name):\(port)"), element("browser-address").label)
            shot("browser-origin-\(name)")
            element("browser-done").tap()
            app.buttons["Done"].firstMatch.tap()
            type(inPane: "")
            app.typeKey("c", modifierFlags: .control)
        }
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
