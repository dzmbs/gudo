#if os(iOS)
import XCTest

/// The context-aware key bar over the software keyboard: profile switching from
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
        let composer = element(app, "keybar-composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "agents default to the composer")
        XCTAssertEqual(app.buttons["keybar-composer-toggle"].value as? String, "on")

        composer.tap()
        composer.typeText("explain this repo\nin two lines")
        XCTAssertTrue(app.buttons["keybar-profile"].exists, "the bar stays while the composer types")
        app.buttons["keybar-composer-send"].tap()
        XCTAssertEqual(composer.value as? String ?? "", "", "Send clears the composer")
        add(XCTAttachment(screenshot: app.screenshot()))

        // Back to a shell: the composer goes away again.
        app.buttons["keybar-composer-toggle"].tap()
        XCTAssertTrue(composer.waitForNonExistence(timeout: 5))
        element(app, "pane-1").tap()
        app.typeText("title zsh ~/src\n")
        XCTAssertTrue(waitFor(profile, value: "Shell"))
        hold()
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

    /// Capsule A and the arrow circle sit in the same place in every profile, a
    /// key's second character is in its long-press menu, and tapping ✥ opens the arrow pad.
    @MainActor
    func testCapsuleAIsFixedLongPressSendsAlternateAndJoystickOpensPad() throws {
        let app = launch()
        let fixed = ["keybar-esc", "keybar-ctrl", "keybar-tab", "keybar-joystick"]
        XCTAssertTrue(element(app, "keybar-joystick").waitForExistence(timeout: 5))
        let shellFrames = fixed.map { element(app, $0).frame }

        app.typeText("title vim main.swift\n")
        XCTAssertTrue(waitFor(app.buttons["keybar-profile"], value: "Vim"))
        XCTAssertTrue(app.buttons["keybar-colon"].waitForExistence(timeout: 5))
        XCTAssertEqual(fixed.map { element(app, $0).frame }, shellFrames, "capsule A and ✥ never move between profiles")

        app.typeText("title zsh ~/src\n")
        XCTAssertTrue(waitFor(app.buttons["keybar-profile"], value: "Shell"))
        let pipe = app.buttons["keybar-pipe"]
        XCTAssertTrue(pipe.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(pipe.frame.height, 48, "a key in a slim capsule, not a slab: \(pipe.frame)")
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

        let joystick = element(app, "keybar-joystick")
        joystick.tap()
        XCTAssertTrue(app.buttons["keybar-pad-home"].waitForExistence(timeout: 5), "tap opens the arrow pad")
        joystick.tap()
        XCTAssertTrue(app.buttons["keybar-pad-home"].waitForNonExistence(timeout: 5), "tap again closes it")
        add(XCTAttachment(screenshot: app.screenshot()))
        hold()
    }

    /// Never fewer than four profile keys, whatever the width.
    @MainActor
    func testProfileCapsuleKeepsAtLeastFourKeys() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["keybar-tilde"].waitForExistence(timeout: 5))
        for id in ["keybar-tilde", "keybar-pipe", "keybar-slash", "keybar-dash"] {
            XCTAssertTrue(app.buttons[id].isHittable, "\(id) is on the bar")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "capsules"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Landscape: every capsule key is on screen, nothing overlaps, and alt joins capsule A.
    @MainActor
    func testLandscapeKeepsCapsulesApart() throws {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let alt = app.buttons["keybar-alt"]
        XCTAssertTrue(alt.waitForExistence(timeout: 5), "alt joins capsule A in landscape")
        let ids = ["keybar-esc", "keybar-ctrl", "keybar-alt", "keybar-tab", "keybar-tilde", "keybar-pipe", "keybar-slash", "keybar-dash", "keybar-joystick", "keybar-profile"]
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
        XCTAssertFalse(app.buttons["keybar-composer-toggle"].exists, "no composer toggle for a shell")
        app.typeText("title claude\n")
        let toggle = app.buttons["keybar-composer-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "agents keep the composer toggle")
        XCTAssertLessThan(toggle.frame.width, 80, "a key, not the whole row: \(toggle.frame)")
        XCTAssertFalse(element(app, "keybar-composer").exists, "no composer by default with a hardware keyboard")
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
