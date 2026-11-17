#if os(iOS)
import XCTest

/// A phone window wide enough for the sidebar (a foldable's inner screen, an iPhone in
/// landscape): the system calls its width compact, the app lays it out regular. The sidebar's
/// own bar keeps Settings and + there.
@MainActor
final class PhoneRegularWidthUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testTheSidebarsBarKeepsSettingsAndNew() throws {
        try checkSidebarBar([])
    }

    /// Opened flat, the sidebar is the left page (a foldable's inner screen held tall).
    func testTheSidebarPageKeepsSettingsAndNew() throws {
        try checkSidebarBar(["-posture", "flat"])
    }

    private func checkSidebarBar(_ extra: [String]) throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "a phone's compact-width traits")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += [
            "-mock", "-screen", "splits", "-sidebarShown", "YES", "-restoreLastTarget", "NO", "-resetWindows", "YES",
        ] + extra
        app.launch()
        // Narrower than this, the sidebar gives way to the terminal by design (`SidebarWidthFit`).
        try XCTSkipIf(app.windows.firstMatch.frame.width < 900, "a phone too narrow in landscape for the sidebar")
        let settings = app.buttons["open-settings"].firstMatch
        let new = app.descendants(matching: .any)["new-tab"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "Settings in the sidebar's bar")
        XCTAssertTrue(new.waitForExistence(timeout: 5), "+ in the sidebar's bar")
        XCTAssertTrue(settings.isHittable && new.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "phone-regular-sidebar"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
