import Foundation
import XCTest
@testable import App

/// The keys the user keeps in the bar: defaults until changed, edits saved, pinned keys and
/// unknown ids never stored, and Reset going back to the defaults.
@MainActor
final class FavouriteKeysTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "FavouriteKeysTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testCatalogKnowsEveryDefaultAndIdsAreUniqueWithinAGroup() {
        for id in KeyCatalog.defaultFavourites {
            XCTAssertNotNil(KeyCatalog.key(id: id), id)
            XCTAssertFalse(KeyCatalog.pinnedIDs.contains(id), "\(id) is pinned already")
        }
        for group in KeyCatalog.groups {
            XCTAssertEqual(Set(group.keys.map(\.id)).count, group.keys.count, group.title)
        }
        for id in ["ctrl-c", "ctrl-d", "ctrl-r", "ctrl-z", "ctrl-l", "ctrl-a", "ctrl-e", "ctrl-u", "ctrl-w",
                   "shift-tab", "word-left", "word-right", "f1", "f12", "home", "end", "pgup", "pgdn",
                   "pipe", "tilde", "backtick", "backslash", "lbrace", "rbrace", "lbracket", "rbracket", "lt", "gt", "dollar"] {
            XCTAssertNotNil(KeyCatalog.key(id: id), "the panel offers \(id)")
        }
    }

    func testEditsAreSavedAndResetRestoresTheDefaults() {
        let favourites = FavouriteKeys(defaults: defaults)
        var changes = 0
        favourites.onChange = { changes += 1 }
        XCTAssertEqual(favourites.ids, KeyCatalog.defaultFavourites)
        XCTAssertTrue(favourites.isDefault)

        favourites.toggle("f5")
        favourites.toggle("tilde")
        XCTAssertEqual(favourites.ids.last, "f5")
        XCTAssertFalse(favourites.contains("tilde"))
        XCTAssertEqual(FavouriteKeys(defaults: defaults).ids, favourites.ids, "saved on the device")

        favourites.move(from: favourites.ids.count - 1, to: 0)
        XCTAssertEqual(favourites.ids.first, "f5")

        favourites.ids += ["ctrl-c", "esc", "no-such-key", "f5"]
        XCTAssertEqual(favourites.ids.filter { $0 == "f5" }.count, 1, "no duplicates")
        XCTAssertFalse(favourites.contains("ctrl-c"), "pinned keys are not favourites")
        XCTAssertFalse(favourites.contains("no-such-key"))

        favourites.reset()
        XCTAssertTrue(favourites.isDefault)
        XCTAssertGreaterThanOrEqual(changes, 4)
    }

    func testProfilesKeepTheirKeysAndAShellShowsOnlyFavourites() {
        XCTAssertTrue(KeyBarProfile.shell.keys.isEmpty)
        let claude = KeyBarProfile.claude.keys.map(\.id)
        XCTAssertEqual(claude.first, "mode", "Shift Tab leads Claude Code's keys")
        XCTAssertTrue(claude.contains("shift-enter"), "a new line in Claude's prompt")
    }
}
