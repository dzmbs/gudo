#if os(iOS)
import XCTest

/// The key bar over the software keyboard: profile switching from
/// the pane title, the agent composer, and snippets. Titles are set through the iOS echo backend's
/// `title <text>` command, which emits OSC 2 like a program would.
final class KeyBarUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testProfileFollowsTitleAndComposerSends() throws {
        let app = launch()
        let profile = app.buttons["keybar-profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertEqual(profile.value as? String, "Shell")
        XCTAssertTrue(app.buttons["keybar-pipe"].exists)

        app.typeText("title vim main.swift\n")
        XCTAssertTrue(waitFor(profile, value: "Vim"))
        XCTAssertTrue(app.buttons["keybar-colon"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["keybar-ctrl"].exists)
        XCTAssertFalse(app.buttons["keybar-pipe"].exists)
        XCTAssertFalse(element(app, "keybar-composer").exists, "no composer for vim")

        app.buttons["keybar-esc"].tap()
        app.typeText("title claude\n")
        XCTAssertTrue(waitFor(profile, value: "Claude Code"))
        XCTAssertTrue(app.buttons["keybar-at"].waitForExistence(timeout: 5), "Claude's keys replace the shell's")
        XCTAssertTrue(app.buttons["keybar-mode"].exists, "Shift Tab cycles Claude's modes")
        let composer = element(app, "keybar-composer")
        XCTAssertFalse(composer.exists, "the terminal takes the typing until the composer is turned on")

        toggleComposer(app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(composer.frame.width, app.buttons["keybar-composer-send"].frame.width * 3, "the field, not Send, takes the row")
        composer.tap()
        composer.typeText("explain this repo\nin two lines")
        XCTAssertTrue(app.buttons["keybar-profile"].exists, "the bar stays while the composer types")
        app.buttons["keybar-composer-send"].tap()
        XCTAssertEqual(composer.value as? String ?? "", "", "Send clears the composer")
        add(XCTAttachment(screenshot: app.screenshot()))

        toggleComposer(app)
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5))
        element(app, "pane-1").tap()
        app.typeText("title zsh ~/src\n")
        XCTAssertTrue(waitFor(profile, value: "Shell"))
        hold()
    }

    @MainActor
    private func toggleComposer(_ app: XCUIApplication) {
        app.buttons["keybar-profile"].tap()
        // The composer's own text view is labelled Composer too.
        let item = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == 'Composer' AND elementType != %d", XCUIElement.ElementType.textView.rawValue)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    @MainActor
    func testManualProfileFromChip() throws {
        let app = launch()
        let profile = app.buttons["keybar-profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        let keySet = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Key Set'")).firstMatch
        // A submenu on iPhone, inline on iPad.
        if keySet.waitForExistence(timeout: 2) { keySet.tap() }
        // The submenu animates open; wait until its item can take the tap.
        let pager = app.buttons.matching(NSPredicate(format: "label == 'Pager'")).firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(5)
        while !pager.isHittable, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        pager.tap()
        XCTAssertTrue(waitFor(profile, value: "Pager"))
        XCTAssertTrue(app.buttons["keybar-q"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSnippetsRow() throws {
        let app = launch()
        // Inline on iPad; in the profile menu on iPhone.
        let toggle = app.buttons["keybar-snippets"]
        func toggleSnippets() {
            if toggle.exists, toggle.isHittable {
                toggle.tap()
            } else {
                app.buttons["keybar-profile"].tap()
                let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Snippets'")).firstMatch
                if !item.waitForExistence(timeout: 5) {
                    let tree = XCTAttachment(string: app.debugDescription)
                    tree.lifetime = .keepAlways
                    add(tree)
                    XCTFail("Snippets in the profile menu")
                }
                item.tap()
            }
        }
        XCTAssertTrue(app.buttons["keybar-profile"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["keybar-snippet-0"].exists)
        toggleSnippets()
        let first = app.buttons["keybar-snippet-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()  // runs "git status" in the echo pane
        add(XCTAttachment(screenshot: app.screenshot()))
        toggleSnippets()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        hold()
    }

    /// esc, ctrl and tab are pinned in the same place in every profile, the arrows lead the
    /// scrolling keys, a key's second character is in its long-press menu, and ctrl locks on a
    /// double tap.
    @MainActor
    func testPinnedKeysStayLongPressSendsAlternateAndCtrlLocks() throws {
        let app = launch()
        let pinned = ["keybar-esc", "keybar-ctrl", "keybar-tab"]
        XCTAssertTrue(element(app, "keybar-tab").waitForExistence(timeout: 5))
        let shellFrames = pinned.map { element(app, $0).frame }
        for id in ["keybar-left", "keybar-down", "keybar-up", "keybar-right", "keybar-tilde"] {
            XCTAssertTrue(app.buttons[id].isHittable, "\(id) is on the bar")
        }

        app.typeText("title vim main.swift\n")
        XCTAssertTrue(waitFor(app.buttons["keybar-profile"], value: "Vim"))
        XCTAssertTrue(app.buttons["keybar-colon"].waitForExistence(timeout: 5))
        XCTAssertEqual(pinned.map { element(app, $0).frame }, shellFrames, "the pinned keys never move between profiles")

        app.typeText("title zsh ~/src\n")
        XCTAssertTrue(waitFor(app.buttons["keybar-profile"], value: "Shell"))
        let pipe = app.buttons["keybar-pipe"]
        XCTAssertTrue(pipe.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(pipe.frame.height, 48, "a key in a slim row, not a slab: \(pipe.frame)")
        // Long-press: the alternate (&) in a menu; tap: the key itself (|).
        pipe.press(forDuration: 0.8)
        let alternate = app.buttons["&"].firstMatch
        XCTAssertTrue(alternate.waitForExistence(timeout: 5), "the long-press menu offers &")
        alternate.tap()
        pipe.tap()
        let pane = element(app, "pane-1-screen")
        let predicate = NSPredicate(format: "value CONTAINS %@", "&|")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: pane)], timeout: 5), .completed,
                       "menu sent the alternate (&), tap the key (|); pane: \(String(describing: pane.value))")

        let ctrl = app.buttons["keybar-ctrl"]
        ctrl.doubleTap()
        XCTAssertEqual(ctrl.value as? String, "Locked")
        app.typeText("a")
        XCTAssertEqual(ctrl.value as? String, "Locked", "a locked ctrl stays for the next key")
        ctrl.tap()
        XCTAssertEqual(ctrl.value as? String, "off")
        add(XCTAttachment(screenshot: app.screenshot()))
        hold()
    }

    /// The keys past the edge are a swipe away: the strip scrolls to the paging keys.
    @MainActor
    func testStripScrollsToTheRest() throws {
        let app = launch()
        let pageDown = app.buttons["keybar-pgdn"]
        XCTAssertTrue(pageDown.waitForExistence(timeout: 5))
        let strip = element(app, "keybar-strip")
        for _ in 0..<4 where !pageDown.isHittable { strip.swipeLeft() }
        XCTAssertTrue(pageDown.isHittable, "the last key is reachable")
        XCTAssertTrue(app.buttons["keybar-esc"].isHittable, "esc stays while the rest scrolls")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "strip"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Landscape: the row's leading keys are on screen, nothing overlaps, and alt is pinned.
    @MainActor
    func testLandscapeKeepsCapsulesApart() throws {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let alt = app.buttons["keybar-alt"]
        XCTAssertTrue(alt.waitForExistence(timeout: 5), "alt is pinned in landscape")
        let ids = ["keybar-esc", "keybar-ctrl", "keybar-alt", "keybar-tab", "keybar-left", "keybar-down", "keybar-up", "keybar-right", "keybar-tilde", "keybar-pipe", "keybar-profile"]
        let frames = ids.map { element(app, $0).frame }
        let screen = app.windows.firstMatch.frame
        for (id, frame) in zip(ids, frames) {
            XCTAssertTrue(screen.contains(frame), "\(id) on screen: \(frame) in \(screen)")
        }
        for i in frames.indices {
            for j in frames.indices where j > i {
                XCTAssertFalse(frames[i].insetBy(dx: 1, dy: 1).intersects(frames[j].insetBy(dx: 1, dy: 1)), "\(ids[i]) overlaps \(ids[j])")
            }
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "landscape"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// With a hardware keyboard (the Magic Keyboard has no Esc) only a slim `esc ⌃ ⋯` pill stays,
    /// and it stays small.
    @MainActor
    func testHardwareKeyboardPillIsSmall() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-keyBar.fullWithHardwareKeyboard", "NO", "-restoreLastTarget", "NO", "-localEcho", "YES"]
        app.launch()
        let pane1 = element(app, "pane-1")
        XCTAssertTrue(pane1.waitForExistence(timeout: 10))
        pane1.tap()
        let esc = app.buttons["keybar-esc"]
        XCTAssertTrue(esc.waitForExistence(timeout: 5))
        // The simulator reports the Mac's keyboard; without one the full bar shows instead.
        try XCTSkipIf(app.buttons["keybar-tilde"].exists, "no hardware keyboard: the full bar is shown")
        XCTAssertTrue(app.buttons["keybar-ctrl"].exists)
        XCTAssertLessThanOrEqual(esc.frame.height, 34, "a slim pill: \(esc.frame)")
        app.typeText("title claude\n")
        XCTAssertFalse(element(app, "keybar-composer").exists, "no composer by default")
        XCTAssertFalse(app.buttons["keybar-left"].exists, "only the pill with a hardware keyboard")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "hardware-pill"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // The simulator may report a hardware keyboard; these tests are about the full bar.
        app.launchArguments += ["-keyBar.fullWithHardwareKeyboard", "YES"]
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES"]
        app.launch()
        let pane1 = element(app, "pane-1")
        XCTAssertTrue(pane1.waitForExistence(timeout: 10))
        pane1.tap()
        return app
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, value: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func hold() {
        guard let seconds = ProcessInfo.processInfo.environment["HOLD_SECONDS"].flatMap(Double.init) else { return }
        Thread.sleep(forTimeInterval: seconds)
    }
}
#endif
