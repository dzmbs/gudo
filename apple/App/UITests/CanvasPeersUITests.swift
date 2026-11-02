#if os(iOS)
import XCTest

/// A canvas pane live with another device (apple/scripts/canvas-peers-ui-test.sh: a local
/// daemon, and `CanvasPeerTests` in HostKit paired as a second device). The app draws
/// a rectangle with Excalidraw's own tool; the peer waits for it, then adds an ellipse, which
/// appears here without a reload. Skipped without a ticket.
@MainActor
final class CanvasPeersUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scene(_ app: XCUIApplication, containing summary: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'drawing.canvas' AND value CONTAINS %@", summary)).firstMatch
    }

    func testAPeersEllipseAppearsBesideTheRectangle() throws {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (run apple/scripts/canvas-peers-ui-test.sh)")
        let app = XCUIApplication()
        app.launchArguments += [
            "-testTicket", ticket, "-testRelay", "disabled", "-drawingDebug", "YES", "-noAutoFocus", "YES",
            "-drawingHintSeen", "YES",
        ]
        app.launch()
        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
        pane.tap()
        sleep(2)

        // New Canvas Split, and a rectangle drawn with Excalidraw's own tool.
        app.typeKey("d", modifierFlags: [.command, .control, .shift])
        let canvas = app.descendants(matching: .any)["drawing.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "a canvas pane opens")
        let tool = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Rectangle' OR title BEGINSWITH 'Rectangle'")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 20), "Excalidraw's tools are in the canvas pane")
        tool.tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)))
        XCTAssertTrue(scene(app, containing: "rectangle:1").waitForExistence(timeout: 15), "the rectangle is in the scene")

        // The other device saw it and drew an ellipse: it shows up live, the rectangle kept.
        let both = scene(app, containing: "ellipse:1")
        XCTAssertTrue(both.waitForExistence(timeout: 90), "the peer's ellipse appears")
        XCTAssertTrue((both.value as? String ?? "").contains("rectangle:1"))
        sleep(1)
        shot(app, "canvas-peer-ellipse")
    }
}
#endif
