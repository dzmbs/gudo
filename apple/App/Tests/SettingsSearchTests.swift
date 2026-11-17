#if os(macOS)
import AppKit
import XCTest
@testable import App

/// Every row a search can land on is in the search's index, and every setting is found by its
/// own title.
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
}
#endif
