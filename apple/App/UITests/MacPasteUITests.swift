#if os(macOS)
import AppKit
import XCTest

/// ⌘V and Edit ▸ Paste reach the terminal on the Mac (the login shell echoes what was pasted).
final class MacPasteUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCommandVAndEditMenuPaste() throws {
        let app = XCUIApplication()
        app.launch()
        let pane = app.descendants(matching: .any)["pane-1"].firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        pane.click()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo pasted-by-cmd-v", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])
        expectValue(of: pane, containing: "pasted-by-cmd-v\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo pasted-by-menu", forType: .string)
        app.menuBars.menuBarItems["Edit"].click()
        app.menuBars.menuItems["Paste"].click()
        app.typeKey(.return, modifierFlags: [])
        expectValue(of: pane, containing: "pasted-by-menu\n")
    }

    private func expectValue(of element: XCUIElement, containing text: String) {
        let predicate = NSPredicate { object, _ in
            ((object as? XCUIElement)?.value as? String)?.contains(text) == true
        }
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: 10)
    }
}
#endif
