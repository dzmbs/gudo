#if os(iOS)
import XCTest

/// Drawings in the window's Handoff activity and canvas panes in the app, against a real local
/// `gudo-hostd` (docs/APP-ARCHITECTURE.md "Windows", docs/DAEMON.md §7.2):
///
/// - draw mode puts the drawing (artifact, and the placement once one is reopened) into the
///   activity, on the drawing's pane; continuing that activity on "another device" (a fresh
///   launch with `-continueActivity`) opens the same host and pane in draw mode on it;
/// - New Canvas Split (⌃⇧⌘D) opens a canvas pane; a rectangle drawn with Excalidraw's own
///   tool is stored on the daemon and is there again after the app is relaunched; a focused
///   canvas pane is in the activity, and continuing it focuses that canvas pane.
///
/// Needs `PAIR_TICKET` from a fresh daemon (`TEST_RUNNER_PAIR_TICKET=$(apple/scripts/local-daemon.sh start
/// <new state dir>)`): the canvas test expects the only canvas pane in the session to be its own.
@MainActor
final class DrawingHandoffUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func ticket() throws -> String {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (TEST_RUNNER_PAIR_TICKET)")
        return ticket
    }

    private func launch(_ ticket: String, continuing payload: [String: Any]? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-testTicket", ticket, "-testRelay", "disabled", "-drawingDebug", "YES", "-noAutoFocus", "YES",
            "-drawingHintSeen", "YES", "-windowProbe", "YES",
        ]
        if let payload, let data = try? JSONSerialization.data(withJSONObject: payload) {
            app.launchArguments += ["-restoreLastTarget", "NO", "-continueActivity", data.base64EncodedString()]
        }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func placements(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'placement-'"))
    }

    private func tap(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The window probe's fields (`WindowProbe`).
    private func probe(_ app: XCUIApplication) -> [String: String] {
        let element = app.descendants(matching: .any).matching(identifier: "window-probe").firstMatch
        guard let text = element.value as? String, let data = text.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return fields
    }

    /// The Handoff payload the window advertises.
    private func handoff(_ app: XCUIApplication) -> [String: Any] {
        guard let text = probe(app)["handoff"], let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func drawing(_ app: XCUIApplication) -> [String: Any]? {
        handoff(app)["drawing"] as? [String: Any]
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func preparePane(_ app: XCUIApplication) -> XCUIElement {
        let pane = panes(app).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
        pane.tap()
        sleep(2)
        app.typeText("clear; seq 1 12\n")
        sleep(2)
        return pane
    }

    private func waitForScene(_ app: XCUIApplication) {
        let toolbar = element(app, "drawing.toolbar")
        expectation(for: NSPredicate(format: "value == 'ready'"), evaluatedWith: toolbar)
        waitForExpectations(timeout: 30)
    }

    /// What another device's activity looks like: this payload's host, tab and pane, made
    /// elsewhere (so the host is matched by its daemon id, not this device's host id).
    private func fromAnotherDevice(_ payload: [String: Any], drawing: [String: Any]) -> [String: Any] {
        var other = payload
        other["hostId"] = "host-on-the-other-device"
        other["origin"] = "another-device"
        other["device"] = "This Mac"
        other["drawing"] = drawing
        return other
    }

    private func number(_ value: Any?) -> UInt64? { (value as? NSNumber)?.uint64Value }

    /// A canvas pane whose scene holds one rectangle (`CanvasPaneView`'s accessibility value).
    private func canvasWithARectangle(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'drawing.canvas' AND value CONTAINS 'rectangle:1'")).firstMatch
    }

    // MARK: Draw mode

    func testDrawModeIsInTheActivityAndContinuesInDrawMode() throws {
        let ticket = try ticket()
        var app = launch(ticket)
        _ = preparePane(app)
        let before = placements(app).count

        // Draw mode: the activity names the drawing (new: no placement yet) on its pane.
        app.typeKey("d", modifierFlags: [.command, .control])
        let done = app.buttons["drawing.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the draw overlay opens")
        waitForScene(app)
        waitFor("the drawing in the activity") { drawing(app)?["artifact"] != nil }
        let open = try XCTUnwrap(drawing(app))
        XCTAssertEqual(open["canvas"] as? Bool, false)
        XCTAssertNil(open["placement"], "a new drawing has no placement yet")
        XCTAssertEqual(number(handoff(app)["pane"]).map(String.init), probe(app)["pane"], "on the drawing's pane")
        let artifact = try XCTUnwrap(number(open["artifact"]))
        let rect = app.buttons["drawing.debugRect"]
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        tap(rect)
        sleep(1)

        // Done: placed, and the activity is back to the terminal alone.
        tap(done)
        XCTAssertTrue(done.waitForNonExistence(timeout: 15))
        expectation(for: NSPredicate(format: "count > %d", before), evaluatedWith: placements(app))
        waitForExpectations(timeout: 15)
        waitFor("no drawing in the activity") { drawing(app) == nil && !handoff(app).isEmpty }
        let payload = handoff(app)
        XCTAssertEqual(payload["kind"] as? String, "daemon")
        app.terminate()

        // "Another device" continues it: the same pane, in draw mode on that drawing (its
        // placement reopened).
        app = launch(ticket, continuing: fromAnotherDevice(payload, drawing: ["artifact": artifact, "canvas": false]))
        XCTAssertTrue(app.buttons["drawing.done"].waitForExistence(timeout: 45), "continued in draw mode")
        waitForScene(app)
        waitFor("the probe says the drawing continued") { probe(app)["continuedDrawing"] == "draw:\(artifact)" }
        XCTAssertEqual(probe(app)["continued"]?.hasPrefix("host("), true, probe(app)["continued"] ?? "")
        XCTAssertEqual(probe(app)["pane"], number(payload["pane"]).map(String.init))
        waitFor("the reopened placement in the activity") { self.number(drawing(app)?["placement"]) != nil }
        XCTAssertEqual(number(drawing(app)?["artifact"]), artifact)
        shot(app, "handoff-draw-mode-continued")
        tap(app.buttons["drawing.cancel"])
        XCTAssertTrue(app.buttons["drawing.done"].waitForNonExistence(timeout: 15))
    }

    // MARK: Canvas panes

    func testCanvasSplitDrawsARectangleReopensAndContinues() throws {
        let ticket = try ticket()
        var app = launch(ticket)
        _ = preparePane(app)
        let panesBefore = panes(app).count

        // New Canvas Split.
        app.typeKey("d", modifierFlags: [.command, .control, .shift])
        let canvas = element(app, "drawing.canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "a canvas pane opens")
        XCTAssertGreaterThan(panes(app).count, panesBefore)

        // Excalidraw's own rectangle tool, then a drag on the canvas.
        let tool = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Rectangle' OR title BEGINSWITH 'Rectangle'")).firstMatch
        if !tool.waitForExistence(timeout: 20) {
            shot(app, "canvas-no-tools")
            print("canvas tree:\n\(app.webViews.firstMatch.debugDescription)")
            XCTFail("Excalidraw's tools are in the canvas pane")
        }
        tool.tap()
        let origin = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35))
        origin.press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.7)))
        XCTAssertTrue(canvasWithARectangle(app).waitForExistence(timeout: 15), "the rectangle is in the scene")
        shot(app, "canvas-rectangle")

        // The focused canvas pane is in the activity.
        waitFor("the canvas in the activity") { drawing(app)?["canvas"] as? Bool == true }
        let artifact = try XCTUnwrap(number(drawing(app)?["artifact"]))
        let payload = handoff(app)
        let canvasPane = try XCTUnwrap(number(payload["pane"]))
        sleep(2)  // the put reaches the daemon
        app.terminate()

        // Reopened: the canvas pane is still in the split, with the rectangle from the daemon.
        app = launch(ticket)
        XCTAssertTrue(element(app, "drawing.canvas").firstMatch.waitForExistence(timeout: 40), "the canvas pane is back")
        XCTAssertTrue(canvasWithARectangle(app).waitForExistence(timeout: 20), "with the rectangle, from the daemon")
        shot(app, "canvas-reopened")
        app.terminate()

        // Continued from "another device": that canvas pane is focused.
        app = launch(ticket, continuing: fromAnotherDevice(payload, drawing: ["artifact": artifact, "canvas": true]))
        waitFor("the canvas continued", timeout: 45) { probe(app)["continuedDrawing"] == "canvas:\(artifact)" }
        XCTAssertEqual(probe(app)["pane"], String(canvasPane), "the canvas pane is focused")
    }
}
#endif
