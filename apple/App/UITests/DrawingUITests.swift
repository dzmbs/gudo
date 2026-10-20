#if os(iOS)
import XCTest

/// ⌃⌘D opens the draw overlay on the focused pane, a rectangle is added through the embedded
/// Excalidraw (the Debug "Rect" button runs the editor's own element factory), Done renders it on
/// device and places it in the pane (`placePng` → `Placed`), says so, it shows over the cells, and
/// it is still there after the app is relaunched (the daemon re-sends placements on attach).
/// Also: the toolbar never covers the first row, one finger draws with the chosen tool, one pane
/// draws at a time, and Write keeps handwriting (typed here: Scribble cannot be synthesised) at
/// the prompt until Send.
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

    private func launch(_ ticket: String, hint: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-testTicket", ticket, "-testRelay", "disabled", "-drawingDebug", "YES", "-noAutoFocus", "YES",
                                "-drawingHintSeen", hint ? "NO" : "YES"]
        app.launch()
        return app
    }

    private func ticket() throws -> String {
        let ticket = ProcessInfo.processInfo.environment["PAIR_TICKET"] ?? ""
        try XCTSkipIf(ticket.isEmpty, "no daemon ticket (TEST_RUNNER_PAIR_TICKET)")
        return ticket
    }

    private func placements(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'placement-'"))
    }

    private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// Coordinate taps: the toolbar lives inside the pane view, which XCUITest cannot "scroll to".
    private func tap(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// A focused daemon pane with some output to annotate (⌃⌘D anchors at the last line of
    /// output above the prompt).
    private func preparePane(_ app: XCUIApplication) -> XCUIElement {
        let pane = panes(app).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 30), "a daemon pane appears")
        pane.tap()
        sleep(2)  // the software keyboard resizes the pane
        app.typeText("clear; seq 1 12\n")
        sleep(2)
        return pane
    }

    /// Picks a tool from the strip, or from the tool menu on a narrow pane.
    private func choose(_ app: XCUIApplication, tool: String, title: String) {
        let button = app.buttons["drawing.tool.\(tool)"]
        if button.exists {
            tap(button)
        } else {
            let menu = app.buttons["drawing.tool"]
            XCTAssertTrue(menu.exists, "a tool strip or a tool menu")
            tap(menu)
            let item = app.buttons[title]
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            item.tap()
        }
        sleep(1)
    }

    /// The tool the toolbar shows as chosen.
    private func isChosen(_ app: XCUIApplication, tool: String, title: String) -> Bool {
        let button = app.buttons["drawing.tool.\(tool)"]
        if button.exists { return button.isSelected }
        return app.buttons["drawing.tool"].label == "Tool: \(title)"
    }

    private func openDrawMode(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey("d", modifierFlags: [.command, .control])
        let done = app.buttons["drawing.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the draw overlay opens")
        waitForScene(app)
        return done
    }

    func testDrawRectangleDonePlacesItAndItSurvivesRelaunch() throws {
        let ticket = try ticket()
        var app = launch(ticket)
        _ = preparePane(app)
        let before = placements(app).count

        let done = openDrawMode(app)
        XCTAssertTrue(app.buttons["drawing.cancel"].exists)

        // The toolbar is ours, at the bottom: never over the first row of text, and Excalidraw's
        // own tool island is gone.
        let toolbar = element(app, "drawing.toolbar")
        let firstRow = element(app, "drawing.firstRow")
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        XCTAssertTrue(firstRow.exists)
        XCTAssertFalse(toolbar.frame.intersects(firstRow.frame), "toolbar \(toolbar.frame) covers the first row \(firstRow.frame)")
        XCTAssertGreaterThan(toolbar.frame.minY, firstRow.frame.maxY)
        XCTAssertFalse(app.webViews.buttons["Rectangle — R or 2"].exists, "Excalidraw's tool island is hidden")
        XCTAssertEqual(app.webViews.descendants(matching: .radioButton).count, 0, "no Excalidraw tool radios")

        // A rectangle through the editor.
        let rect = app.buttons["drawing.debugRect"]
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        tap(rect)
        sleep(1)
        shot(app, "draw-mode-rectangle")

        // Done: rendered on device, placed in the pane's output, and it says so.
        tap(done)
        XCTAssertTrue(done.waitForNonExistence(timeout: 15), "the overlay closes")
        let notice = element(app, "drawing.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "Done says where the drawing went")
        XCTAssertTrue(app.staticTexts["Kept in terminal"].exists)
        XCTAssertTrue(app.staticTexts["tap it to send, copy or edit"].exists, "says what the drawing is for now")
        shot(app, "placed-notice")
        let placed = placements(app)
        expectation(for: NSPredicate(format: "count > %d", before), evaluatedWith: placed)
        waitForExpectations(timeout: 15)
        let frame = placed.element(boundBy: placed.count - 1).frame
        XCTAssertGreaterThan(frame.width, 20, "the placement covers cells")
        XCTAssertGreaterThan(frame.height, 10)
        XCTAssertTrue(notice.waitForNonExistence(timeout: 10), "the notice goes away by itself")
        shot(app, "placed")

        // Relaunch: the daemon re-sends placements on attach and the image downloads again.
        app.terminate()
        app = launch(ticket)
        let again = placements(app)
        expectation(for: NSPredicate(format: "count >= %d", before + 1), evaluatedWith: again)
        waitForExpectations(timeout: 40)
        shot(app, "after-relaunch")
    }

    /// Once a tool is picked, one finger draws with it (and keeps drawing with it); with Pen a
    /// finger inks through PencilKit, handed to the scene like the Pencil's strokes.
    func testFingerDrawsWithTheChosenTool() throws {
        let app = launch(try ticket())
        let pane = preparePane(app)
        let before = placements(app).count
        let done = openDrawMode(app)

        choose(app, tool: "rectangle", title: "Rectangle")
        XCTAssertTrue(isChosen(app, tool: "rectangle", title: "Rectangle"), "the toolbar shows the chosen tool")

        // Two rectangles with one finger: the tool stays picked after the first.
        let frame = pane.frame
        func drag(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
            let origin = pane.coordinate(withNormalizedOffset: .zero)
            let a = origin.withOffset(CGVector(dx: frame.width * x0, dy: frame.height * y0))
            let b = origin.withOffset(CGVector(dx: frame.width * x1, dy: frame.height * y1))
            a.press(forDuration: 0.1, thenDragTo: b)
        }
        drag(0.10, 0.15, 0.35, 0.30)
        sleep(1)
        XCTAssertTrue(isChosen(app, tool: "rectangle", title: "Rectangle"), "still the rectangle after drawing one")
        drag(0.45, 0.15, 0.70, 0.30)
        sleep(1)

        // Pen: a finger inks.
        choose(app, tool: "pen", title: "Pen")
        XCTAssertTrue(isChosen(app, tool: "pen", title: "Pen"))
        drag(0.10, 0.40, 0.60, 0.45)
        sleep(2)
        shot(app, "finger-shapes-and-ink")

        tap(done)
        XCTAssertTrue(done.waitForNonExistence(timeout: 15))
        let placed = placements(app)
        expectation(for: NSPredicate(format: "count > %d", before), evaluatedWith: placed)
        waitForExpectations(timeout: 15)
        // Two rectangles side by side and an ink line under them: the placement spans them.
        let image = placed.element(boundBy: placed.count - 1).frame
        XCTAssertGreaterThan(image.width, frame.width * 0.45, "both rectangles and the ink were drawn")
        shot(app, "finger-placed")
    }

    /// Draw mode in a second pane closes an empty overlay in the first, and asks about one with a
    /// drawing: never two panes drawing at once.
    func testOnlyOnePaneDrawsAtATime() throws {
        let app = launch(try ticket())
        _ = preparePane(app)
        app.typeKey("d", modifierFlags: .command)  // split right; the new pane has focus
        let split = panes(app)
        expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: split)
        waitForExpectations(timeout: 15)
        sleep(2)
        let overlays = app.buttons.matching(identifier: "drawing.done")

        // Right pane draws, nothing on it; the left pane takes over quietly.
        _ = openDrawMode(app)
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        sleep(1)
        app.typeKey("d", modifierFlags: [.command, .control])
        sleep(3)
        XCTAssertEqual(overlays.count, 1, "one pane draws")

        // Something drawn in the left pane: the right pane asks first.
        waitForScene(app)
        let rect = app.buttons["drawing.debugRect"]
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        tap(rect)
        sleep(1)
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        sleep(1)
        app.typeKey("d", modifierFlags: [.command, .control])
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "asked about the drawing in the other pane")
        shot(app, "one-pane-ask")
        XCTAssertEqual(overlays.count, 1)
        alert.buttons["Discard It and Draw Here"].tap()
        sleep(3)
        XCTAssertEqual(overlays.count, 1, "still one pane drawing, now the right one")
        tap(app.buttons["drawing.cancel"])
        XCTAssertTrue(overlays.firstMatch.waitForNonExistence(timeout: 10))
        app.typeKey("w", modifierFlags: .command)  // leave one pane for the next test
        sleep(2)
    }

    /// Mean luminance (0…255) of `frame` (points) in a screenshot.
    private func luminance(_ screenshot: XCUIScreenshot, in frame: CGRect, of app: XCUIApplication) -> Double {
        guard let image = screenshot.image.cgImage else { return 0 }
        let scale = CGFloat(image.width) / app.frame.width
        let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        guard let region = image.cropping(to: crop.integral) else { return 0 }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(region, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return 0 }
        var sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        return sum / Double(side * side)
    }

    /// Esc leaves draw mode and never reaches the shell. It used to: the overlay stayed open, the
    /// shell got the Esc (zsh rings the bell on the second one), and the bell flashed the whole
    /// pane white, fading back to black. Draw mode now holds the keyboard focus (the terminal's
    /// key bar, whose esc went to the shell, is gone while drawing), and the pane never flashes
    /// while it closes. Also: the first time, a one-line hint says what drawings are for.
    func testEscapeLeavesDrawModeWithoutAFlash() throws {
        let app = launch(try ticket(), hint: true)
        let pane = preparePane(app)
        XCTAssertTrue(element(app, "keybar-esc").waitForExistence(timeout: 5), "the key bar is up before drawing")

        let done = openDrawMode(app)
        let hint = element(app, "drawing.hint")
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "the first draw mode says what drawings are for")
        XCTAssertTrue(hint.label.contains("send it to an agent"), hint.label)
        XCTAssertFalse(element(app, "keybar-esc").exists && element(app, "keybar-esc").isHittable, "nothing typed while drawing reaches the shell: no key bar")
        let rect = app.buttons["drawing.debugRect"]
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        tap(rect)
        sleep(1)
        shot(app, "esc-before")
        // Keys are draw mode's: a tool letter picks the tool (it is not typed into the shell).
        let screen = element(app, pane.identifier + "-screen")
        let shellBefore = screen.value as? String ?? ""
        app.typeKey("r", modifierFlags: [])
        sleep(1)
        XCTAssertTrue(isChosen(app, tool: "rectangle", title: "Rectangle"), "R picks the rectangle while drawing")
        XCTAssertEqual(screen.value as? String ?? "", shellBefore, "nothing typed while drawing reached the shell")

        let area = pane.frame
        let before = luminance(app.screenshot(), in: area, of: app)
        // ⌘. is Esc on an iPad keyboard (the Magic Keyboard has none); the simulator does not hand
        // a synthesized Esc to the app at all, so the test presses ⌘. (both are the same command).
        app.typeKey(".", modifierFlags: .command)
        var samples: [Double] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 1.5 {
            samples.append(luminance(app.screenshot(), in: area, of: app))
        }
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Esc closes draw mode")
        let brightest = samples.max() ?? 0
        XCTAssertLessThan(brightest, before + 20, "the pane flashed while draw mode closed (\(before) → \(samples))")
        shot(app, "esc-after")

    }

    /// With no agent in the pane, the primary action is a Send To… menu: Start Claude Code or
    /// Codex with the drawing, Copy Image, Share…, Keep in Terminal. Copy places it too and
    /// says so. A drawing in the output then opens the same menu (plus Edit and Delete) when
    /// tapped.
    func testSendToMenuAndThePlacementMenu() throws {
        let app = launch(try ticket())
        _ = preparePane(app)
        let before = placements(app).count
        let done = openDrawMode(app)
        let rect = app.buttons["drawing.debugRect"]
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        tap(rect)
        sleep(1)

        let send = app.buttons["drawing.send"]
        XCTAssertTrue(send.exists, "a Send To… menu even without an agent")
        tap(send)
        let copy = app.buttons["Copy Image"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the menu opens")
        XCTAssertTrue(app.buttons["Keep in Terminal"].exists)
        XCTAssertTrue(app.buttons["Share…"].exists)
        XCTAssertTrue(app.buttons["Start Claude Code with This Drawing"].exists)
        XCTAssertTrue(app.buttons["Start Codex with This Drawing"].exists)
        shot(app, "send-to-menu")
        copy.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 15), "the overlay closes")
        XCTAssertTrue(app.staticTexts["Image copied"].waitForExistence(timeout: 10), "says the image was copied")
        let placed = placements(app)
        expectation(for: NSPredicate(format: "count > %d", before), evaluatedWith: placed)
        waitForExpectations(timeout: 15)
        shot(app, "copied")
        XCTAssertTrue(element(app, "drawing.notice").waitForNonExistence(timeout: 10))

        // Tap the drawing in the output: its menu.
        let drawing = placed.element(boundBy: placed.count - 1)
        tap(drawing)
        let edit = app.buttons["Edit Drawing"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "a tap on a drawing opens its menu")
        XCTAssertTrue(app.buttons["Copy Image"].exists)
        XCTAssertTrue(app.buttons["Start Claude Code with This Drawing"].exists)
        XCTAssertTrue(app.buttons["Delete Drawing"].exists)
        shot(app, "placement-menu")

        // Edit reopens it in place; Cancel leaves it as it was.
        edit.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Edit reopens the drawing")
        tap(app.buttons["drawing.cancel"])
        XCTAssertTrue(done.waitForNonExistence(timeout: 10))
        expectation(for: NSPredicate(format: "count > %d", before), evaluatedWith: placed)
        waitForExpectations(timeout: 10)

        // Delete removes it.
        sleep(1)
        tap(placed.element(boundBy: placed.count - 1))
        let delete = app.buttons["Delete Drawing"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        expectation(for: NSPredicate(format: "count == %d", before), evaluatedWith: placed)
        waitForExpectations(timeout: 10)
    }

    /// Waits until the editor holds the scene (a cold WebKit can take seconds; a rectangle
    /// added before that is lost).
    private func waitForScene(_ app: XCUIApplication) {
        let toolbar = element(app, "drawing.toolbar")
        expectation(for: NSPredicate(format: "value == 'ready'"), evaluatedWith: toolbar)
        waitForExpectations(timeout: 30)
    }

    /// Draws a rectangle and keeps it in the output; returns the new placement.
    private func keepARectangle(_ app: XCUIApplication) -> XCUIElement {
        let placed = placements(app)
        let before = placed.count
        let done = openDrawMode(app)
        let rect = app.buttons["drawing.debugRect"]
        XCTAssertTrue(rect.waitForExistence(timeout: 5))
        tap(rect)
        sleep(1)
        tap(done)
        XCTAssertTrue(done.waitForNonExistence(timeout: 15))
        expectation(for: NSPredicate(format: "count > %d", before), evaluatedWith: placed)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(element(app, "drawing.notice").waitForNonExistence(timeout: 10))
        return placed.element(boundBy: placed.count - 1)
    }

    /// A drawing's menu exports it (PNG, SVG, Excalidraw, ASCII under Export; Copy as Text) and
    /// lists its finished versions: edited and kept again, the first version is restored from
    /// Version History, as a new version on top.
    func testExportCopyTextAndVersionHistory() throws {
        let app = launch(try ticket())
        _ = preparePane(app)
        let drawing = keepARectangle(app)

        tap(drawing)
        let export = app.buttons["Export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5), "an Export submenu")
        XCTAssertTrue(app.buttons["Copy as Text"].exists)
        export.tap()
        for title in ["PNG Image…", "SVG…", "Excalidraw File…", "Text (ASCII)…"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3), "\(title) is offered")
        }
        shot(app, "export-menu")
        app.buttons["Excalidraw File…"].tap()
        // The share sheet with the scene file.
        let sheet = app.otherElements["ActivityListView"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "the share sheet opens with the file")
        shot(app, "export-share-sheet")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()  // outside the popover
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        tap(drawing)
        let copyText = app.buttons["Copy as Text"]
        XCTAssertTrue(copyText.waitForExistence(timeout: 5))
        copyText.tap()
        XCTAssertTrue(app.staticTexts["Text copied"].waitForExistence(timeout: 10), "the ASCII rendering is on the pasteboard")
        XCTAssertTrue(element(app, "drawing.notice").waitForNonExistence(timeout: 10))

        // One version so far.
        tap(drawing)
        let history = app.buttons["Version History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5), "a Version History submenu")
        history.tap()
        let versions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'drawing.history.'"))
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: versions)
        waitForExpectations(timeout: 10)
        shot(app, "history-one")
        panes(app).firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()  // close the menu
        sleep(1)

        // Edit: a second rectangle, kept again → two versions.
        tap(placements(app).element(boundBy: placements(app).count - 1))
        app.buttons["Edit Drawing"].tap()
        let done = app.buttons["drawing.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        waitForScene(app)
        tap(app.buttons["drawing.debugRect"])
        sleep(1)
        tap(done)
        XCTAssertTrue(done.waitForNonExistence(timeout: 15))
        XCTAssertTrue(element(app, "drawing.notice").waitForNonExistence(timeout: 10))
        tap(placements(app).element(boundBy: placements(app).count - 1))
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: versions)
        waitForExpectations(timeout: 10)
        shot(app, "history-two")

        // Restore the first: the drawing goes back, as a third version.
        versions.element(boundBy: 1).tap()
        sleep(3)  // the daemon writes it back and re-shows the placement with the old render
        tap(placements(app).element(boundBy: placements(app).count - 1))
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        expectation(for: NSPredicate(format: "count == 3"), evaluatedWith: versions)
        waitForExpectations(timeout: 10)
        shot(app, "history-restored")
    }

    /// A drawing dragged from one pane onto another is placed there too (the same drawing,
    /// with its own render), and the original stays.
    func testDragADrawingOntoAnotherPane() throws {
        let app = launch(try ticket())
        _ = preparePane(app)
        let drawing = keepARectangle(app)
        let before = placements(app).count
        app.typeKey("d", modifierFlags: .command)  // split right
        let split = panes(app)
        expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: split)
        waitForExpectations(timeout: 15)
        // Leave one pane for the next test, pass or fail (the daemon keeps the layout).
        addTeardownBlock { @MainActor in
            app.typeKey("w", modifierFlags: .command)
            sleep(2)
        }
        sleep(2)
        let target = split.element(boundBy: 1)
        drawing.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.2, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        let placed = placements(app)
        expectation(for: NSPredicate(format: "count > %d", before), evaluatedWith: placed)
        waitForExpectations(timeout: 20)
        shot(app, "dragged-to-other-pane")
    }

    /// Write: what is written shows at the prompt and reaches the shell only on Send (typed
    /// here; the same field takes Scribble's text on a device).
    func testWriteShowsAtThePromptUntilSent() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "Write is iPad only")
        let app = launch(try ticket())
        let pane = preparePane(app)
        _ = openDrawMode(app)
        let write = app.buttons["drawing.write"]
        if write.exists {
            tap(write)
        } else {
            tap(app.buttons["drawing.tool"])
            let item = app.buttons["Write at Prompt"]
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            item.tap()
        }
        let send = app.buttons["write.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Write mode opens")
        XCTAssertFalse(send.isEnabled, "nothing to send yet")

        app.typeText("echo drawn-$((6*7))")
        let preview = element(app, "write.preview")
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertEqual(preview.value as? String, "echo drawn-$((6*7))", "shown at the prompt")
        let screen = element(app, pane.identifier + "-screen")
        XCTAssertFalse((screen.value as? String ?? "").contains("drawn-42"), "nothing reached the shell")
        shot(app, "write-preview")

        tap(send)
        XCTAssertTrue(send.waitForNonExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value CONTAINS 'drawn-42'"), evaluatedWith: screen)
        waitForExpectations(timeout: 10)
        shot(app, "write-sent")
    }
}
#endif
