#if os(iOS)
import XCTest

/// The system's accessibility audit (labels, hit regions, clipped text and, where text is not
/// clamped by design, Dynamic Type) over the newer screens on the design fixtures (`-mock`), at
/// the largest accessibility text size: projects, tab history and multi-select in the sidebar,
/// a host's Devices, and App Lock. Each audits its own region; the pane headers and toolbar
/// around them are fixed-height bands that clamp their text by design (docs/DESIGN.md).
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = true
    }

    private func audit(
        _ screen: String, _ extra: [String] = [], types: XCUIAccessibilityAuditType,
        region: (XCUIApplication) -> CGRect
    ) throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-mock", "-screen", screen, "-restoreLastTarget", "NO",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ] + extra
        app.launch()
        Thread.sleep(forTimeInterval: 4)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "a11y-\(screen)"
        shot.lifetime = .keepAlways
        add(shot)
        let area = region(app)
        XCTAssertGreaterThan(area.width * area.height, 10_000, "\(screen): the region audited is on screen: \(area)")
        try app.performAccessibilityAudit(for: types) { issue in
            // Only what this screen draws; an issue no element is named for cannot be placed.
            guard let element = issue.element, area.intersects(element.frame) else { return true }
            print("a11y \(screen): \(issue.compactDescription) – \(element.elementType.rawValue) '\(element.identifier)' '\(element.label)' \(element.frame)")
            return false
        }
        app.terminate()
    }

    /// The sidebar: everything left of the panes. It clamps its text at accessibility 1 and
    /// widens with it (`SidebarWidth`), and its rows are one line that truncates like Finder's
    /// (VoiceOver reads the whole title), so Dynamic Type and clipping are not audited there.
    private func sidebar(_ app: XCUIApplication) -> CGRect {
        let panes = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
        let edge = panes.allElementsBoundByIndex.map(\.frame.minX).min() ?? app.frame.width
        return CGRect(x: 0, y: 0, width: edge - 1, height: app.frame.height)
    }

    private let sidebarAudit: XCUIAccessibilityAuditType = [.sufficientElementDescription, .hitRegion]

    func testProjects() throws {
        try audit("projects", ["-sidebarShown", "YES"], types: sidebarAudit, region: sidebar)
    }

    func testTabHistory() throws {
        try audit("tab-history", ["-sidebarShown", "YES"], types: sidebarAudit, region: sidebar)
    }

    func testTabSelection() throws {
        try audit("tab-selection", ["-sidebarShown", "YES"], types: sidebarAudit, region: sidebar)
    }

    func testDevices() throws {
        try audit("devices", types: .all) { app in
            app.descendants(matching: .any)["host-devices"].firstMatch.frame
        }
    }

    func testAppLock() throws {
        try audit("app-lock", types: .all) { $0.frame }
    }
}
#endif
