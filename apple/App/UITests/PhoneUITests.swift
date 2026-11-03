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
        let project = projectRow(app, "New Project")
        XCTAssertTrue(project.waitForExistence(timeout: 5), "the project leads its section")
        project.tap()
        for item in ["Rename…", "New Terminal", "Ungroup", "Close All Tabs"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 5), item)
        }
        app.buttons["Rename…"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the rename prompt")
        field.clearAndType("web")
        app.alerts.buttons["Done"].tap()

        openSwitcher(app)
        XCTAssertTrue(projectRow(app, "web").waitForExistence(timeout: 5), "the section has the new name")
    }

    /// Show All opens every project, tab and agent on a page of its own; picking a tab there
    /// shows it and closes the page.
    func testShowAllOpensTheTabOverview() throws {
        let app = try launch(["-mock", "-screen", "projects"])
        openSwitcher(app)
        XCTAssertTrue(projectRow(app, "acme-app").waitForExistence(timeout: 10), "projects lead the menu")
        XCTAssertEqual(projectRow(app, "acme-app").label, "acme-app, 2 hosts · 3 tabs", "where its tabs are")
        XCTAssertTrue(app.buttons["web, hetzner"].exists, "a tab of a project across hosts names its host")
        XCTAssertTrue(projectRow(app, "infra").exists)
        shot(app, "switcher-menu")
        app.buttons["Show All"].tap()

        let overview = app.descendants(matching: .any)["tab-overview"].firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 5), "the tab overview")
        XCTAssertTrue(app.descendants(matching: .any)["project-acme-app"].waitForExistence(timeout: 5), "projects as in the sidebar")
        XCTAssertTrue(app.descendants(matching: .any)["host-group-studio"].exists, "hosts with their loose tabs")
        shot(app, "tab-overview")

        let row = app.descendants(matching: .any)["tab-row-2"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(overview.waitForNonExistence(timeout: 5), "showing a tab closes the overview")
        let switcher = app.descendants(matching: .any)["tab-switcher"].firstMatch
        XCTAssertTrue(switcher.label.contains("web"), "tab 2 is on screen: \(switcher.label)")
    }

    /// A project's first line in the switcher: its name, then where its tabs are.
    private func projectRow(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), ")).firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        let current = value as? String ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
#endif
