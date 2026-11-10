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

        favourites.ids += ["enter", "esc", "no-such-key", "f5"]
        XCTAssertEqual(favourites.ids.filter { $0 == "f5" }.count, 1, "no duplicates")
        XCTAssertFalse(favourites.contains("enter"), "pinned keys are not favourites")
        XCTAssertFalse(favourites.contains("no-such-key"))

        favourites.reset()
        XCTAssertTrue(favourites.isDefault)
        XCTAssertGreaterThanOrEqual(changes, 4)
    }

    func testProfilesKeepTheirKeysAndAShellShowsOnlyFavourites() {
        XCTAssertTrue(KeyBarProfile.shell.keys.isEmpty)
        let claude = KeyBarProfile.claude.keys.map(\.id)
        XCTAssertEqual(Array(claude.prefix(3)), ["up", "down", "mode"], "the arrows for Claude Code's menus, then Shift Tab")
        XCTAssertTrue(claude.contains("shift-enter"), "a new line in Claude's prompt")
        XCTAssertEqual(Array(KeyBarProfile.codex.keys.map(\.id).prefix(2)), ["up", "down"])
    }

    func testTheBarLeadsWithWhatAShellAndAgentsUseMost() {
        XCTAssertEqual(KeyCatalog.pinnedIDs, ["esc", "tab", "enter"])
        XCTAssertEqual(Array(KeyCatalog.defaultFavourites.prefix(5)), ["up", "down", "left", "right", "ctrl-c"])
        XCTAssertTrue(KeyCatalog.defaultFavourites.contains("paste"))
    }

    func testEnterAndTabReadAsWords() {
        XCTAssertEqual(KeySpec.enter.title, "enter")
        XCTAssertNil(KeySpec.enter.symbol)
        XCTAssertEqual(KeySpec.enter.accessibilityLabel, "Enter")
        XCTAssertEqual(KeySpec.tab.title, "tab")
        XCTAssertNil(KeySpec.tab.symbol)
        XCTAssertEqual(KeySpec.newline.title, "⇧enter")
    }

    func testTheOldDefaultsGiveWayToTheNewOnes() {
        defaults.set(FavouriteKeys.previousDefaults, forKey: FavouriteKeys.previousStorageKey)
        let favourites = FavouriteKeys(defaults: defaults)
        XCTAssertEqual(favourites.ids, KeyCatalog.defaultFavourites)
        XCTAssertTrue(favourites.isDefault)
    }

    func testAListTheUserMadeIsKeptWithInterruptFirst() {
        defaults.set(["f5", "tilde", "enter", "pipe"], forKey: FavouriteKeys.previousStorageKey)
        let favourites = FavouriteKeys(defaults: defaults)
        XCTAssertEqual(favourites.ids, ["ctrl-c", "f5", "tilde", "pipe"], "^C stays where it was pinned; Enter is pinned now")

        favourites.toggle("ctrl-c")
        XCTAssertEqual(FavouriteKeys(defaults: defaults).ids, ["f5", "tilde", "pipe"], "the move happens once")

        favourites.reset()
        XCTAssertEqual(FavouriteKeys(defaults: defaults).ids, KeyCatalog.defaultFavourites, "Reset forgets the old list too")
    }
}
