#if os(iOS)
import XCTest

/// ⌃⌘D opens the draw overlay on the focused pane, a rectangle is added through the embedded
/// Excalidraw (the Debug "Rect" button runs the editor's own element factory), Done renders it on
/// device and places it in the pane (`placePng` → `Placed`), it shows over the cells, and it is
/// still there after the app is relaunched (the daemon re-sends placements on attach).
/// Needs `PAIR_TICKET` (run with `TEST_RUNNER_PAIR_TICKET=$(apple/scripts/local-daemon.sh start)`).
@MainActor
final class DrawingUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ ticket: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-drawingDebug", "YES", "-noAutoFocus", "YES"]
        app.launch()
        return app
    }

    private func placements(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'placement-'"))
    }

    func testDrawRectangleDonePlacesItAndItSurvivesRelaunch() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (TEST_RUNNER_PAIR_TICKET)")
        var app = launch(ticket)

        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
        pane.tap()
        sleep(2)  // the software keyboard resizes the pane
        // Some output to annotate (⌃⌘D anchors at the last line of output above the prompt).
        app.typeText("seq 1 12\n")
        sleep(2)
        let before = placements(app).count

        // ⌃⌘D: draw mode at the cursor row.
        app.typeKey("d", modifierFlags: [.command, .control])
        let done = app.buttons["drawing.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the draw overlay opens")
        XCTAssertTrue(app.buttons["drawing.cancel"].exists)

        // A rectangle through the editor (wait for the page to load its scene).
        let rect = app.buttons["drawing.debugRect"]
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        sleep(2)
        rect.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        shot(app, "draw-mode-rectangle")

        // Done: rendered on device, placed in the pane's output.
        // Coordinate taps: the toolbar lives inside the pane view, which XCUITest cannot "scroll to".
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 15), "the overlay closes")
        let placed = placements(app)
        expectation(for: NSPredicate(format: "count > %d", before), evaluatedWith: placed)
        waitForExpectations(timeout: 15)
        let frame = placed.element(boundBy: placed.count - 1).frame
        XCTAssertGreaterThan(frame.width, 20, "the placement covers cells")
        XCTAssertGreaterThan(frame.height, 10)
        shot(app, "placed")

        // Relaunch: the daemon re-sends placements on attach and the image downloads again.
        app.terminate()
        app = launch(ticket)
        let again = placements(app)
        expectation(for: NSPredicate(format: "count >= %d", before + 1), evaluatedWith: again)
        waitForExpectations(timeout: 40)
        shot(app, "after-relaunch")
    }
}
#endif
