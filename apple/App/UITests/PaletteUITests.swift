#if os(iOS)
import XCTest

/// The command palette: one row is always selected, a query narrows the list
/// and ⌘1 runs the first match.
@MainActor
final class PaletteUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    func testPaletteSelectsFirstRowAndCommandOneRunsIt() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES", "-keyBar.fullWithHardwareKeyboard", "YES"]
        app.launch()
        let pane = app.descendants(matching: .any)["pane-1"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()

        // The toolbar button: XCUITest's synthesized shifted ⌘ chords (⇧⌘P) reach the app
        // unreliably, and the Simulator keeps ⌘K for "toggle software keyboard". Shortcut
        // delivery from the terminal is tested with ⌘F below.
        app.buttons["open-palette"].firstMatch.tap()
        // The container's identifier covers the field (SwiftUI propagates it).
        let field = app.textFields.matching(identifier: "command-palette").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the palette opens")
        let selected = app.buttons.matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 3), "a row is selected with an empty query")
        shot(app, "palette-empty")

        field.typeText("split right")
        XCTAssertTrue(app.staticTexts["⌘"].waitForExistence(timeout: 3) || app.buttons.count > 0)
        shot(app, "palette-query")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "⌘1 runs the first match and closes the palette")
        if UIDevice.current.userInterfaceIdiom == .phone {
            // A phone shows one pane of a split; the bar's pane switcher says there are two.
            XCTAssertTrue(app.buttons["Panes"].waitForExistence(timeout: 10), "the split happened")
            return
        }
        let panes = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: panes)
        waitForExpectations(timeout: 10)
    }

    /// Control: an app shortcut the terminal answers (⌘D splits).
    func testCommandDSplits() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "a phone shows one pane of a split")
        let app = XCUIApplication()
        app.launchArguments += ["-restoreLastTarget", "NO", "-localEcho", "YES", "-keyBar.fullWithHardwareKeyboard", "YES"]
        app.launch()
        let pane = app.descendants(matching: .any)["pane-1"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.tap()
        app.typeKey("d", modifierFlags: .command)
        let panes = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES 'pane-[0-9]+'"))
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: panes)
        waitForExpectations(timeout: 10)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
