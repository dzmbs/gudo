#if os(iOS)
import XCTest

/// Workflows on the iPad against a real `gudo-hostd` whose repository has workflow files
/// (apple/scripts/workflows-ui-test.sh sets them up and passes `PAIR_TICKET` and
/// `WORKFLOW_FIXTURES`): "/" in the palette lists them with their source, the argument form
/// fills defaults, ⇥ moves between fields and previews the command, ↩ types it at the prompt
/// without running it (Return in the terminal runs it), ⌘↩ runs it, and New Workflow from Last
/// Command writes a file the palette then lists. Skipped without a ticket.
@MainActor
final class WorkflowsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixtures = ""
    private var brand = "gudo"

    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/workflows-ui-test.sh)")
        fixtures = ProcessInfo.processInfo.environment["WORKFLOW_FIXTURES"] ?? ""
        brand = ProcessInfo.processInfo.environment["BRAND"] ?? "gudo"
        try? FileManager.default.removeItem(atPath: output)
        app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-noAutoFocus", "YES"]
        app.launch()
        if !pane.waitForExistence(timeout: 30) {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
        // The shell is in the repository once its prompt says so.
        waitFor(NSPredicate(format: "value CONTAINS 'proj %'"), screen, timeout: 30)
        pane.tap()
        // The simulator drops the first hardware key after launch: spend it on a no-op.
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
    }

    private var pane: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
    }

    private var screen: XCUIElement {
        app.descendants(matching: .any)[pane.identifier + "-screen"]
    }

    private var output: String { fixtures + "/work/proj/greet-out.txt" }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func text(containing needle: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", needle, needle)).firstMatch
    }

    private func waitFor(_ predicate: NSPredicate, _ object: Any, timeout: TimeInterval) {
        expectation(for: predicate, evaluatedWith: object)
        waitForExpectations(timeout: timeout)
    }

    private func waitForFile(_ path: String, containing needle: String, timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8), text.contains(needle) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("\(path) never held \(needle): \((try? String(contentsOfFile: path, encoding: .utf8)) ?? "missing")")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var paletteField: XCUIElement {
        app.textFields.matching(identifier: "command-palette").firstMatch
    }

    private func openPalette() {
        element("open-palette").tap()
        XCTAssertTrue(paletteField.waitForExistence(timeout: 5), "the palette opens")
    }

    /// "/" scopes the palette to workflows; then `query` and Return picks one.
    private func workflow(_ query: String) {
        openPalette()
        paletteField.typeText("/")
        let scoped = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Run a workflow…")).firstMatch
        XCTAssertTrue(scoped.waitForExistence(timeout: 5), "\"/\" switches the palette to workflows")
        XCTAssertTrue(text(containing: query).waitForExistence(timeout: 10), "the workflows arrive from the host")
        scoped.typeText(query)
        Thread.sleep(forTimeInterval: 0.4)
        scoped.typeText("\n")
    }

    /// Replaces the text of the focused argument field.
    private func replace(_ field: XCUIElement, with text: String) {
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    // MARK: Tests

    /// The "/" scope lists the repository's workflows first, then the global ones, with
    /// descriptions and their source.
    func testSlashListsRepositoryAndGlobalWorkflows() throws {
        try launch()
        openPalette()
        paletteField.typeText("/")
        XCTAssertTrue(text(containing: "Greet Someone").waitForExistence(timeout: 10), "the repository's workflow")
        XCTAssertTrue(text(containing: "Writes a greeting to greet-out.txt").exists, "with its description")
        XCTAssertTrue(text(containing: "Short Status").exists)
        XCTAssertTrue(text(containing: "Disk Usage").exists, "the global workflow")
        XCTAssertTrue(text(containing: "Repository · proj").exists, "grouped by source")
        XCTAssertTrue(app.staticTexts["Global"].firstMatch.exists, "the global ones are marked")
        shot("workflows-palette")
    }

    /// The form fills the defaults, ⇥ moves to the next argument, the preview quotes values;
    /// ↩ types the command at the prompt and nothing runs until Return in the terminal.
    func testArgumentFormInsertsWithoutRunning() throws {
        try launch()
        workflow("Greet")
        let form = element("workflow-form")
        XCTAssertTrue(form.waitForExistence(timeout: 5), "the argument form opens")
        let preview = element("workflow-preview")
        waitFor(NSPredicate(format: "value == %@", "echo Hello world > greet-out.txt"), preview, timeout: 5)
        shot("workflow-form-defaults")

        let greeting = element("workflow-arg-greeting")
        replace(greeting, with: "Hi there")
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
        let name = element("workflow-arg-name")
        replace(name, with: "Ada")
        waitFor(NSPredicate(format: "value == %@", "echo 'Hi there' Ada > greet-out.txt"), preview, timeout: 5)
        XCTAssertEqual(name.value as? String, "Ada", "⇥ moved to the second field")
        shot("workflow-form-filled")

        app.typeText("\n")
        XCTAssertTrue(form.waitForNonExistence(timeout: 5), "↩ closes the form")
        waitFor(NSPredicate(format: "value CONTAINS %@", "echo 'Hi there' Ada > greet-out.txt"), screen, timeout: 10)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output), "inserting never runs the command")
        shot("workflow-inserted")

        app.typeText("\n")
        waitForFile(output, containing: "Hi there Ada")
    }

    /// ⌘↩ in the form runs the filled command.
    func testCommandReturnRunsIt() throws {
        try launch()
        workflow("Greet")
        let name = element("workflow-arg-name")
        XCTAssertTrue(name.waitForExistence(timeout: 5), "the argument form opens")
        waitFor(NSPredicate(format: "hasKeyboardFocus == true"), element("workflow-arg-greeting"), timeout: 5)
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
        waitFor(NSPredicate(format: "hasKeyboardFocus == true"), name, timeout: 5)
        replace(name, with: "Grace")
        waitFor(NSPredicate(format: "value == %@", "echo Hello Grace > greet-out.txt"), element("workflow-preview"), timeout: 5)
        app.typeKey("\n", modifierFlags: .command)
        XCTAssertTrue(element("workflow-form").waitForNonExistence(timeout: 5), "⌘↩ closes the form")
        waitForFile(output, containing: "Hello Grace")
        shot("workflow-ran")
    }

    /// New Workflow from Last Command saves the last command as a repository workflow file,
    /// and the "/" scope lists it.
    func testNewWorkflowFromLastCommand() throws {
        try launch()
        app.typeText("echo saved-$((6*7))\n")
        waitFor(NSPredicate(format: "value CONTAINS 'saved-42'"), screen, timeout: 10)
        openPalette()
        paletteField.typeText("New Workflow from Last")
        Thread.sleep(forTimeInterval: 0.4)
        paletteField.typeText("\n")
        let form = element("new-workflow-form")
        XCTAssertTrue(form.waitForExistence(timeout: 10), "the New Workflow panel opens")
        let command = element("new-workflow-command")
        waitFor(NSPredicate(format: "value CONTAINS %@", "echo saved-$((6*7))"), command, timeout: 10)
        let nameField = element("new-workflow-name")
        nameField.tap()
        nameField.typeText("The Answer")
        shot("new-workflow")
        element("new-workflow-save").tap()
        XCTAssertTrue(form.waitForNonExistence(timeout: 10), "saved")
        let file = fixtures + "/work/proj/.\(brand)/workflows/the-answer.yaml"
        waitForFile(file, containing: "echo saved-$((6*7))")

        openPalette()
        paletteField.typeText("/")
        XCTAssertTrue(text(containing: "The Answer").waitForExistence(timeout: 10), "the palette lists the new workflow")
        shot("new-workflow-listed")
    }
}
#endif
