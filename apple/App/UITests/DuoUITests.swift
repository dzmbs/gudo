#if os(iOS)
import XCTest

/// iPhone Duo (docs/APP-ARCHITECTURE.md "Foldable"), on a Duo simulator:
///
///   xcodebuild test -destination 'platform=iOS Simulator,name=<your Duo>' -only-testing:AppUITests/DuoUITests
///
/// The simulator starts closed and moves its hinge only by hand (Device Hub's slider), so the
/// first test reads the real hinge on the cover screen; the second folds through every posture
/// with the DEBUG posture notification and checks nothing on screen is lost or reflowed.
@MainActor
final class DuoUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func probe(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "window-probe").firstMatch
    }

    private func fields(_ element: XCUIElement) -> [String: String] {
        guard let text = element.value as? String, let data = text.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return fields
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-localEcho", "YES", "-hostsDirectory", NSTemporaryDirectory() + "duo-\(UUID().uuidString)",
            "-windowProbe", "YES", "-resetWindows", "YES", "-restoreLastTarget", "NO",
        ] + arguments
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(probe(app).waitForExistence(timeout: 20))
        return app
    }

    private func requireDuo(_ app: XCUIApplication) throws {
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try XCTSkipIf(fields(probe(app))["hinge"] == "none", "not an iPhone Duo (no hinge)")
    }

    /// The posture the app is told to draw, as `DebugPostures` hears it.
    private func fold(to posture: String) {
        let name = "dev.gudo.debug.posture.\(posture)" as CFString
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name), nil, nil, true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Closed, the Duo's own `UIHingeInteraction` says so: the cover screen, the phone layout.
    func testTheClosedDuoReadsItsHingeOnTheCoverScreen() throws {
        let app = launch()
        try requireDuo(app)
        let element = probe(app)
        waitFor("the hinge") { fields(element)["hinge"] == "closed" }
        let now = fields(element)
        XCTAssertEqual(now["posture"], "folded")
        XCTAssertEqual(now["fold"], "standard")
        XCTAssertEqual(now["bucket"], "compact")
        shot("duo-cover")
    }

    /// Every posture keeps the tab, the focused pane and what the shell printed. The cover is
    /// too narrow for pages or a deck, so none of them reshapes it: no resize reaches the pane.
    func testFoldingThroughEveryPostureKeepsThePane() throws {
        let app = launch()
        try requireDuo(app)
        let element = probe(app)
        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 20))
        pane.tap()
        app.typeText("duo-continuity\n")
        let printed = app.descendants(matching: .any).matching(NSPredicate(format: "identifier ENDSWITH '-screen' AND value CONTAINS 'duo-continuity'")).firstMatch
        XCTAssertTrue(printed.waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let before = fields(element)

        for posture in ["flat", "book", "tabletop", "folded"] {
            fold(to: posture)
            waitFor(posture) { fields(element)["posture"] == posture }
            let now = fields(element)
            XCTAssertEqual(now["fold"], "standard", "\(posture): a cover-sized window stays whole")
            XCTAssertEqual(now["tab"], before["tab"], posture)
            XCTAssertEqual(now["pane"], before["pane"], posture)
            XCTAssertEqual(now["resizes"], before["resizes"], "\(posture): no reflow")
            XCTAssertTrue(printed.exists, "\(posture): the scrollback is still there")
        }
        fold(to: "real")
        waitFor("the real hinge again") { fields(element)["hinge"] == "closed" }
    }
}
#endif
