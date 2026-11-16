#if os(iOS)
import XCTest

/// On iPad: the key bar over the software keyboard and the slim strip with a hardware keyboard
/// (44 pt targets, Esc reachable), the sidebar's rows as VoiceOver reads them, and the system's
/// accessibility audit over the main window. With `TEST_RUNNER_IPAD_SHOTS_DIR` set it writes
/// `<dir>/<prefix>-<shot>.png` (`TEST_RUNNER_IPAD_SHOTS_PREFIX`).
@MainActor
final class IPadKeyBarAndLabelsUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    override func setUp() async throws {
        continueAfterFailure = true
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad layout")
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"] + extra
        app.launch()
        return app
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        guard let directory = env["IPAD_SHOTS_DIR"] else { return }
        let prefix = env["IPAD_SHOTS_PREFIX"] ?? "shot"
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(prefix)-\(name).png"))
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testTheFullKeyBarHasRoomyTargetsAndEsc() {
        let app = launch(["-keyBar.fullWithHardwareKeyboard", "YES"])
        let pane = element(app, "pane-1")
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()
        let esc = app.buttons["keybar-esc"]
        XCTAssertTrue(esc.waitForExistence(timeout: 5))
        sleep(1)
        save(app, "keybar-full")
        for identifier in ["keybar-esc", "keybar-ctrl", "keybar-tab"] {
            let key = app.buttons[identifier]
            XCTAssertTrue(key.isHittable, "\(identifier) can be reached")
            XCTAssertGreaterThanOrEqual(key.frame.height, 40, "\(identifier): a key the keyboard's height: \(key.frame)")
            XCTAssertGreaterThanOrEqual(key.frame.width, 40, "\(identifier): \(key.frame)")
        }
        XCTAssertGreaterThanOrEqual(esc.frame.minX, app.windows.firstMatch.frame.minX + 8, "esc clears the window's edge")
    }

    func testTheHardwareStripKeepsEscWithin44PointTargets() throws {
        let app = launch(["-keyBar.fullWithHardwareKeyboard", "NO"])
        let pane = element(app, "pane-1")
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()
        let esc = app.buttons["keybar-esc"]
        XCTAssertTrue(esc.waitForExistence(timeout: 5))
        try XCTSkipIf(app.buttons["keybar-tilde"].exists, "no hardware keyboard: the full bar is shown")
        sleep(1)
        save(app, "keybar-hardware")
        for identifier in ["keybar-esc", "keybar-ctrl"] {
            let key = app.buttons[identifier]
            XCTAssertTrue(key.isHittable, "\(identifier) can be reached")
            XCTAssertLessThanOrEqual(key.frame.height, 34, "\(identifier): drawn slim: \(key.frame)")
            XCTAssertGreaterThanOrEqual(key.frame.width, 44, "\(identifier): a 44 pt target across: \(key.frame)")
        }
        // The slim key takes a touch up to 8 pt above what it draws: a 44 pt target.
        let ctrl = app.buttons["keybar-ctrl"]
        XCTAssertEqual(ctrl.value as? String, "off")
        ctrl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -7)).tap()
        XCTAssertNotEqual(ctrl.value as? String, "off", "a touch just above ctrl latches it")
    }

    func testSidebarRowsReadTheirTabProgramAndHost() {
        let app = launch(["-mock", "-screen", "splits", "-sidebarShown", "YES"])
        let row = element(app, "tab-row-1")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        sleep(1)
        save(app, "sidebar")
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tab-row-'"))
        XCTAssertGreaterThan(rows.count, 1)
        for row in rows.allElementsBoundByIndex {
            print("row label \(row.identifier): '\(row.label)'")
            XCTAssertFalse(row.label.hasPrefix("~"), "\(row.identifier) reads a symbol: '\(row.label)'")
            XCTAssertTrue(row.label.contains(", "), "\(row.identifier) names more than its title: '\(row.label)'")
        }
    }

    func testTheMainWindowPassesTheAccessibilityAudit() throws {
        let app = launch(["-mock", "-screen", "splits", "-sidebarShown", "YES"])
        XCTAssertTrue(element(app, "tab-row-1").waitForExistence(timeout: 10))
        sleep(2)
        if let directory = env["IPAD_SHOTS_DIR"] {
            try? app.debugDescription.write(toFile: directory + "/main-tree.txt", atomically: true, encoding: .utf8)
        }
        // The sidebar and the toolbar. The panes below are the terminal's own: their 24 pt
        // headers are a fixed band whose words are not controls (a tap anywhere on it focuses
        // the pane), audited for labels only.
        let panes = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
        let paneTop = panes.allElementsBoundByIndex.map(\.frame.minY).min() ?? app.frame.height
        let paneLeading = panes.allElementsBoundByIndex.map(\.frame.minX).min() ?? app.frame.width
        let headerBand = paneTop - 48
        // Contrast is held over every theme by the palette's own tests (`ChromeContrastTests`);
        // the system's sampling of whole rows flagged the same row in one run and not the next.
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion]) { issue in
            guard let element = issue.element else { return true }
            let inPanes = element.frame.minX >= paneLeading - 1 && element.frame.minY >= headerBand
            if inPanes && issue.auditType != .sufficientElementDescription { return true }
            if inPanes && element.elementType == .other && element.label.isEmpty && element.children(matching: .any).count <= 1 { return true }
            print("a11y main: \(issue.compactDescription) – \(element.elementType.rawValue) '\(element.identifier)' '\(element.label)' \(element.frame)")
            return false
        }
        for button in app.buttons.allElementsBoundByIndex where button.isHittable {
            XCTAssertFalse(button.label.isEmpty && button.identifier.isEmpty, "a control without a name at \(button.frame)")
        }
    }
}
#endif
