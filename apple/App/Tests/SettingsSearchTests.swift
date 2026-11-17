#if os(macOS)
import AppKit
import DesignSystem
import XCTest
@testable import App

/// Every row a search can land on is in the search's index, every setting is found by its own
/// title, and a result clicked opens its pane scrolled to the row.
@MainActor
final class SettingsSearchTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")

    /// Rows only the iPhone and iPad have, indexed only there.
    private static let touchOnly: Set<String> = ["open-web-links", "ascii-keyboard", "hardware-key-bar", "key-bar-profiles"]

    /// Every `settingAnchor("…")` in the app's sources.
    private func anchoredRows() throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: #"settingAnchor\("([^"]+)"\)"#)
        var rows = Set<String>()
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let range = Range(match.range(at: 1), in: source) { rows.insert(String(source[range])) }
            }
        }
        return rows
    }

    func testEveryRowASearchCanLandOnIsInTheIndex() throws {
        let rows = try anchoredRows()
        XCTAssertFalse(rows.isEmpty, "read the sources")
        let indexed = Set(SettingsIndex.all.map(\.id))
        // Shown, and indexed, only in builds that update themselves.
        let updates: Set<String> = AppUpdater.shared.isAvailable ? [] : ["updates-check-automatically", "updates-download-automatically"]
        XCTAssertEqual(rows.subtracting(indexed).subtracting(Self.touchOnly).subtracting(updates), [], "rows no search finds")
        XCTAssertEqual(indexed.subtracting(rows), [], "index entries with no row to land on")
    }

    func testEverySettingIsFoundByItsTitle() {
        for entry in SettingsIndex.all {
            XCTAssertTrue(SettingsIndex.search(entry.title).contains(entry), "\(entry.title)")
            if let key = entry.key {
                XCTAssertTrue(SettingsIndex.search(key).contains(entry), "\(entry.title) by its Ghostty key \(key)")
            }
        }
    }

    /// Typed in the window's search and clicked: the result's pane opens with its row in sight,
    /// even a row far below the pane's top. Under Reduce Motion the form jumps there at once
    /// (a window off screen runs no scrolling animation, so the test takes that path).
    func testClickingAResultOpensItsPaneScrolledToTheRow() async throws {
        let settings = try await SettingsDriver.open(SettingsNavigation(pane: .about), accessibility: ChromeAccessibility(reduceMotion: true))
        defer { settings.close() }
        await settings.click(settings.searchField)
        await settings.type("opens with")
        await settings.expect("one result") { settings.sidebarItems.count == 1 }
        await settings.click(settings.sidebarItems.first)
        await settings.expect("Appearance opens") { settings.navigation.pane == .appearance }
        await settings.expect("scrolled down to Opens With, the last row") {
            guard let form = settings.form else { return false }
            return form.contentView.bounds.minY + form.contentInsets.top > 100
        }
    }
}
#endif
