#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import App

@MainActor
final class ChatInlineCodeTests: XCTestCase {
    private static let command = "nvidia-smi --query-gpu=clocks.sm,clocks.mem --format=csv"

    private func prose(_ code: String) throws -> AttributedString {
        try AttributedString(markdown: "Readings come from `\(code)` on each box, and `a/b` too, under `2,400 MHz` for a minute.")
    }

    func testCodeBreaksOnlyBetweenItsWordsWhereThoseFitALine() throws {
        let styled = ChatInlineCode.styled(try prose(Self.command), background: .gray)
        let font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        let longestWord = Self.command.split(separator: " ").map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        for width in stride(from: longestWord + 4, through: longestWord + 220, by: 7) {
            let lines = Self.lines(of: String(styled.characters), font: font, width: width)
            for line in lines.dropLast() {
                let breakAfter = line.last.map { $0.isWhitespace } ?? true
                XCTAssertTrue(breakAfter, "at \(width) pt a line ends inside a word of code: \(line.debugDescription)")
            }
            XCTAssertTrue(lines.contains { Self.visible($0).contains("2,400 MHz") }, "at \(width) pt a short span breaks")
        }
    }

    func testCodeReadsTheSameAndOnlyItsSpansChange() throws {
        let source = try prose(Self.command)
        let styled = ChatInlineCode.styled(source, background: .gray)
        XCTAssertEqual(Self.visible(String(styled.characters)), String(source.characters))
        XCTAssertTrue(String(styled.characters).hasPrefix("Readings come from "))
        let codeRuns = styled.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertFalse(codeRuns.isEmpty)
        XCTAssertTrue(codeRuns.allSatisfy { styled[$0.range].backgroundColor != nil })
    }

    private static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func lines(of text: String, font: UIFont, width: CGFloat) -> [String] {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var lines: [String] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append((text as NSString).substring(with: characters))
        }
        return lines
    }
}
#endif
