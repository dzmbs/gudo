#if os(iOS)
import XCTest

/// Design review shots that need a gesture (a row's swipe open, the host switcher), on the design
/// fixtures (`-mock`). Runs only with `TEST_RUNNER_DESIGN_SHOTS_DIR` set; writes
/// `<dir>/<prefix>-<shot>-<mode>.png` with `TEST_RUNNER_DESIGN_SHOTS_PREFIX` and
/// `TEST_RUNNER_DESIGN_SHOTS_MODE` (`dark` or `light`, which picks the theme).
@MainActor
final class DesignShotsUITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipIf(env["DESIGN_SHOTS_DIR"] == nil, "design shots run on request")
    }

    private var mode: String { env["DESIGN_SHOTS_MODE"] ?? "dark" }

    private func launch(screen: String, _ extra: [String] = []) {
        app = XCUIApplication()
        let theme = mode == "light" ? "Apple System Colors Light" : "Ghostty Default"
        app.launchArguments += ["-mock", "-screen", screen, "-restoreLastTarget", "NO", "-theme", theme] + extra
        app.launch()
    }

    private func save(_ name: String) throws {
        let directory = URL(fileURLWithPath: env["DESIGN_SHOTS_DIR"]!)
        let prefix = env["DESIGN_SHOTS_PREFIX"] ?? "shot"
        try app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(prefix)-\(name)-\(mode).png"))
    }

    private func drag(_ element: XCUIElement, by dx: CGFloat) {
        let from = element.coordinate(withNormalizedOffset: CGVector(dx: dx < 0 ? 0.8 : 0.2, dy: 0.5))
        let to = from.withOffset(CGVector(dx: dx, dy: 0))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    func testSwipeShots() throws {
        launch(screen: "splits")
        let row = app.descendants(matching: .any)["tab-row-2"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        drag(row, by: -110)
        sleep(1)
        try save("swipe-trailing")
        drag(row, by: 110)
        sleep(1)
        let other = app.descendants(matching: .any)["tab-row-3"].firstMatch
        drag(other, by: 80)
        sleep(1)
        try save("swipe-leading")
    }

    func testInboxSwipeShot() throws {
        launch(screen: "inbox")
        let row = app.descendants(matching: .any)["inbox-a4"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft(velocity: .slow)
        sleep(1)
        try save("inbox-swipe")
    }

    func testPeopleShot() throws {
        launch(screen: "splits", ["-mockPresence", "YES", "-mockFollow", "YES"])
        let button = app.descendants(matching: .any)["presence-button"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        sleep(1)
        try save("people")
    }

    func testHostSwitcherShot() throws {
        launch(screen: "splits")
        let button = app.descendants(matching: .any)["hosts-button"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        sleep(1)
        try save("host-switcher")
    }
}
#endif
