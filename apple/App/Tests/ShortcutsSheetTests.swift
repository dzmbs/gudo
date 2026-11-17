import XCTest
@testable import App

/// Keyboard Shortcuts lists each action once, with every key that runs it.
@MainActor
final class ShortcutsSheetTests: XCTestCase {
    func testEachActionIsListedOnceWithAllItsKeys() throws {
        let rows = ShortcutsSheet.rows(WorkspaceAction.windowActions.map(ShortcutsSheet.Entry.init))
        let titles = rows.map(\.title)
        XCTAssertEqual(titles.count, Set(titles).count, "a name listed twice: \(titles)")
        let palette = try XCTUnwrap(rows.first { $0.title == "Command Palette" })
        XCTAssertEqual(palette.keys.count, 2, "⌘K and ⇧⌘P on one row")
    }
}
