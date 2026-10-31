#if os(iOS)
import XCTest

/// iPhone-only chrome: the tab switcher's menus offer what a phone can do (no windows) and
/// everything a project's sidebar header offers elsewhere.
@MainActor
final class PhoneUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "iPhone only")
        let app = XCUIApplication()
        app.launchArguments += [
            "-localEcho", "YES", "-hostsDirectory", NSTemporaryDirectory() + "phone-\(UUID().uuidString)",
            "-resetWindows", "YES", "-restoreLastTarget", "NO", "-noAutoFocus", "YES",
        ] + extra
        app.launch()
        return app
    }

    private func openSwitcher(_ app: XCUIApplication) {
        let switcher = app.descendants(matching: .any)["tab-switcher"].firstMatch
        XCTAssertTrue(switcher.waitForExistence(timeout: 20))
        switcher.tap()
    }

    /// Open in New Window only where the system shows more than one window (not an iPhone; a
    /// foldable may).
    func testSwitcherOffersNewWindowOnlyWhereItCanOpen() throws {
        let app = try launch(["-windowProbe", "YES"])
        let probe = app.descendants(matching: .any).matching(identifier: "window-probe").firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 20))
        let fields = (probe.value as? String).flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        let multiWindow = try XCTUnwrap(fields?["multiWindow"])
        openSwitcher(app)
        XCTAssertTrue(app.buttons["Rename…"].waitForExistence(timeout: 5), "the tab's menu is there")
        XCTAssertEqual(app.buttons["Open in New Window"].exists, multiWindow == "true")
    }

    func testSwitcherRenamesAProject() throws {
        let app = try launch()
        openSwitcher(app)
        let newProject = app.buttons["New Project from Tab"]
        XCTAssertTrue(newProject.waitForExistence(timeout: 5))
        newProject.tap()

        openSwitcher(app)
        let project = app.buttons["Project"]
        XCTAssertTrue(project.waitForExistence(timeout: 5), "the project's menu is in its section")
        project.tap()
        for item in ["Rename…", "New Terminal", "Ungroup", "Close All Tabs"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 5), item)
        }
        app.buttons["Rename…"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the rename prompt")
        field.clearAndType("web")
        app.alerts.buttons["Rename"].tap()

        openSwitcher(app)
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'web · '")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "the section has the new name")
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        let current = value as? String ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
#endif
