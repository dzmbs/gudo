#if os(iOS)
import XCTest

/// fixtures: a local `unnamed-hostd` whose `code serve-web` is a stand-in page that counts its
/// loads and has a text field (nothing is downloaded). Run with
/// `UI_TEST_CLASS=EditorPanesUITests apple/scripts/w3-ui-test.sh <sim>`; skipped without a ticket.
///
/// Two editors on two folders in their own tabs, each keeping its page (and what was typed in
/// it) across tab switches; ⌘1–⌘9 leave an editor, other ⌘ keys stay in it; one beside the
/// terminal; ⌃⌘` back to the terminal; a relaunch brings the editor tabs back, each loading when
/// it is first shown; an editor off screen past its time is suspended and reloads when shown.
@MainActor
final class EditorPanesUITests: XCTestCase {
    private var app: XCUIApplication!

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    /// `pairing: false` (a relaunch): the saved host only, so the window restores what it had (a test
    /// ticket shows its host instead of restoring).
    private func launch(_ extra: [String] = [], pairing: Bool = true) throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/w3-ui-test.sh)")
        app = XCUIApplication()
        app.launchArguments += [
            "-testRelay", "disabled", "-noAutoFocus", "YES", "-sidebarShown", "YES", "-resetWindows", "YES",
        ] + (pairing ? ["-testTicket", ticket] : []) + extra
        app.launch()
        if !anyPane.waitForExistence(timeout: 30), !element(prefix: "editor-pane-").exists {
            // The first launch after an install sometimes misses the first dial; once more.
            app.terminate()
            app.launch()
        }
        // iPad simulator: the first hardware key after launch is dropped.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
    }

    private var panes: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private var anyPane: XCUIElement { panes.firstMatch }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func element(prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    private func text(containing needle: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", needle, needle)).firstMatch
    }

    /// A sidebar row by the start of its accessibility label ("proj, VS Code on …").
    private func row(_ label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-row-' AND label BEGINSWITH %@", label)).firstMatch
    }

    private func waitFor(_ predicate: NSPredicate, _ element: Any, timeout: TimeInterval, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message)
    }

    private func palette(_ command: String) {
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        app.typeKey("k", modifierFlags: .command)
        if !field.waitForExistence(timeout: 3) {
            element("open-palette").firstMatch.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the palette opens")
        field.typeText(command + "\n")
    }

    private func typeInPane(_ text: String) {
        anyPane.tap()
        app.typeText(text)
    }

    /// The stand-in workbench's load counter ("Page loads 3" → 3).
    private func pageLoads() -> Int? {
        let label = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Page loads '")).firstMatch
        guard label.waitForExistence(timeout: 10) else { return nil }
        return Int(label.label.replacingOccurrences(of: "Page loads ", with: ""))
    }

    /// The terminal's tab in the sidebar (a host's row, or its worktree's row under its repository).
    private var terminalRow: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(identifier BEGINSWITH 'tab-row-' OR identifier BEGINSWITH 'worktree-tab-' OR identifier BEGINSWITH 'worktree-row-') AND NOT (label CONTAINS 'VS Code on')")).firstMatch
    }

    private var webField: XCUIElement { app.webViews.textFields.firstMatch }

    /// Focuses the workbench's field from a tap on the page first: a tap on a field that already
    /// has focus opens its edit menu, which then takes the keys meant for the page.
    private func focusWebField() {
        text(containing: "Fake VS Code workbench").tap()
        webField.tap()
    }

    /// Waits for the workbench of `folder` (its name in the page's location line).
    private func waitForWorkbench(_ folder: String, timeout: TimeInterval = 40) {
        XCTAssertTrue(text(containing: "Fake VS Code workbench").waitForExistence(timeout: timeout), "the workbench loads")
        XCTAssertTrue(text(containing: "work/\(folder)").waitForExistence(timeout: 10), "on \(folder)")
        // The page's own requests carry only the server's cookie (as the real workbench's do):
        // another editor's token must not have replaced it.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertFalse(text(containing: "Forbidden").exists, "\(folder)'s server still lets the page in")
    }

    private func typeInWorkbench(_ text: String) {
        XCTAssertTrue(webField.waitForExistence(timeout: 10))
        focusWebField()
        app.typeText(text)
        waitFor(NSPredicate(format: "value CONTAINS %@", text), webField, timeout: 5, "typed in the workbench")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Closes every editor tab (leaves the next test the terminal it expects).
    private func closeEditors() {
        for _ in 0..<6 {
            let cancel = element("editor-licence-cancel")
            if cancel.waitForExistence(timeout: 1) {
                cancel.tap()
                continue
            }
            let close = element("editor-close")
            guard close.exists else {
                let editorRow = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-row-' AND label CONTAINS 'VS Code on'")).firstMatch
                guard editorRow.exists else { return }
                editorRow.tap()
                _ = element("editor-close").waitForExistence(timeout: 5)
                continue
            }
            close.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    // MARK: Tests

    func testTwoEditorsKeepTheirStateSplitBesideATerminalAndComeBackAfterARelaunch() throws {
        // No suspension during this test, however slow the machine is (that has its own test).
        try launch(["-editorLicenceReset", "YES", "-editorSuspendAfter", "36000"])
        closeEditors()  // what an earlier run left open
        XCTAssertTrue(anyPane.waitForExistence(timeout: 30), "a daemon pane")
        typeInPane("cd ~/proj\n")

        // One: the repository, in a tab of its own.
        palette("Open in VS Code")
        let accept = element("editor-licence-accept")
        XCTAssertTrue(accept.waitForExistence(timeout: 20), "the licence comes first, once per host")
        accept.tap()
        waitForWorkbench("proj")
        XCTAssertTrue(element("host-group-editors").waitForExistence(timeout: 5), "the sidebar's VS Code group")
        XCTAssertTrue(row("proj, VS Code on").exists, "the row names the folder")
        typeInWorkbench("alpha")
        let projLoads = try XCTUnwrap(pageLoads())

        // Two: another folder, from the terminal's tab.
        let terminalRow = self.terminalRow
        XCTAssertTrue(terminalRow.exists)
        terminalRow.tap()
        XCTAssertTrue(anyPane.waitForExistence(timeout: 10), "back on the terminal")
        typeInPane("cd ~/site\n")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        palette("Open in VS Code")
        XCTAssertFalse(accept.waitForExistence(timeout: 3), "the host's licence is not asked again")
        waitForWorkbench("site")
        XCTAssertTrue(row("site, VS Code on").exists)
        typeInWorkbench("beta")
        shot("editor-two-tabs")

        // Back to the first: its page was kept, with what was typed (no reload).
        row("proj, VS Code on").tap()
        waitForWorkbench("proj", timeout: 10)
        XCTAssertEqual(webField.value as? String, "alpha", "the first editor kept its page")
        XCTAssertEqual(pageLoads(), projLoads, "not loaded again")

        // From inside VS Code, ⌘2 is the app's (the second tab: site); ⌘P stays VS Code's.
        focusWebField()
        app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(text(containing: "cmd+p").waitForExistence(timeout: 5), "⌘P reached VS Code")
        XCTAssertFalse(app.textFields.matching(identifier: "command-palette").firstMatch.exists, "the app's palette stayed closed")
        app.typeKey("2", modifierFlags: .command)
        waitForWorkbench("site", timeout: 10)
        XCTAssertEqual(webField.value as? String, "beta", "the second editor kept its page too")

        // Beside the terminal: a third folder, split right of the shell in its own tab.
        terminalRow.tap()
        XCTAssertTrue(anyPane.waitForExistence(timeout: 10))
        typeInPane("cd ~/docs\n")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        palette("Open in VS Code Beside")
        waitForWorkbench("docs")
        XCTAssertTrue(anyPane.exists, "the terminal stays beside it")
        let editor = element(prefix: "editor-pane-docs")
        XCTAssertTrue(editor.exists)
        XCTAssertGreaterThan(editor.frame.minX, anyPane.frame.minX, "the editor is right of the terminal")
        XCTAssertTrue(element("host-group-mixed").exists, "the tab is listed under Mixed")
        shot("editor-beside-terminal")

        // ⌃⌘` leaves VS Code for the terminal: the app's ⌘K works again.
        focusWebField()
        app.typeKey("k", modifierFlags: .command)
        XCTAssertFalse(app.textFields.matching(identifier: "command-palette").firstMatch.waitForExistence(timeout: 2), "⌘K is VS Code's in the editor")
        app.typeKey("`", modifierFlags: [.command, .control])
        app.typeKey("k", modifierFlags: .command)
        let paletteField = app.textFields.matching(identifier: "command-palette").firstMatch
        XCTAssertTrue(paletteField.waitForExistence(timeout: 5), "back in the terminal, ⌘K is the app's")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        // Relaunch: the editor tabs come back; each loads when it is first shown.
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.terminate()
        try launch(["-editorSuspendAfter", "36000"], pairing: false)
        XCTAssertTrue(row("proj, VS Code on").waitForExistence(timeout: 40), "the proj editor tab is restored")
        XCTAssertTrue(row("site, VS Code on").exists, "the site editor tab is restored")
        XCTAssertTrue(element("host-group-mixed").exists, "the editor beside the terminal is restored")
        row("site, VS Code on").tap()
        waitForWorkbench("site", timeout: 60)
        row("proj, VS Code on").tap()
        waitForWorkbench("proj", timeout: 60)
        shot("editor-restored")

        // ⌘W in VS Code closes its pane, not the window (the system's Close Window is ⇧⌘W).
        focusWebField()
        // The simulator drops the first hardware key after a launch (here the relaunch).
        app.typeKey(XCUIKeyboardKey.shift, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(row("proj, VS Code on").waitForNonExistence(timeout: 10), "⌘W closed the editor pane")
        XCTAssertTrue(row("site, VS Code on").exists, "the window stayed open")
        closeEditors()
    }

    /// An editor off screen past its time (here 3 s) lets its web view go; shown again, it shows
    /// its last picture, then loads anew.
    func testAnEditorOffScreenIsSuspendedAndComesBack() throws {
        try launch(["-editorSuspendAfter", "3"])
        closeEditors()  // what an earlier run left open
        XCTAssertTrue(anyPane.waitForExistence(timeout: 30), "a daemon pane")
        typeInPane("cd ~/notes\n")
        palette("Open in VS Code")
        let accept = element("editor-licence-accept")
        if accept.waitForExistence(timeout: 5) { accept.tap() }
        waitForWorkbench("notes")
        typeInWorkbench("gone")
        let loads = try XCTUnwrap(pageLoads())
        // Wait long enough for a snapshot, then leave for the terminal well past the limit.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        terminalRow.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        row("notes, VS Code on").tap()
        waitForWorkbench("notes", timeout: 30)
        waitFor(NSPredicate(format: "label == %@", "Page loads \(loads + 1)"),
                app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Page loads '")).firstMatch,
                timeout: 20, "the suspended editor loaded again")
        closeEditors()
    }
}
#endif
