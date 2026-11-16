#if os(iOS)
import DesignSystem
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
        let joined = ChatInlineCode.joined(try prose(Self.command))
        let font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        let longestWord = Self.command.split(separator: " ").map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        for width in stride(from: longestWord + 4, through: longestWord + 220, by: 7) {
            let lines = Self.lines(of: String(joined.characters), font: font, width: width)
            for line in lines.dropLast() {
                let breakAfter = line.last.map { $0.isWhitespace } ?? true
                XCTAssertTrue(breakAfter, "at \(width) pt a line ends inside a word of code: \(line.debugDescription)")
            }
            XCTAssertTrue(lines.contains { Self.visible($0).contains("2,400 MHz") }, "at \(width) pt a short span breaks")
        }
    }

    func testCodeReadsTheSameAsItsSource() throws {
        let source = try prose(Self.command)
        XCTAssertEqual(Self.visible(String(ChatInlineCode.joined(source).characters)), String(source.characters))
    }

    func testCodeRendersAsWideAsItsSourceText() throws {
        for code in ["2,400 MHz", Self.command, "a/b"] {
            let source = try AttributedString(markdown: "`\(code)`")
            var reference = source
            reference.font = DS.Font.literal
            XCTAssertEqual(Self.renderedWidth(ChatInlineCode.text(source)), Self.renderedWidth(Text(reference)),
                           accuracy: 0.01, "\(code) gains no advance")
        }
        let paragraph = try prose(Self.command)
        var reference = paragraph
        for run in paragraph.runs where run.inlinePresentationIntent?.contains(.code) == true {
            reference[run.range].font = DS.Font.literal
        }
        XCTAssertEqual(Self.renderedWidth(ChatInlineCode.text(paragraph)), Self.renderedWidth(Text(reference)), accuracy: 0.01)
    }

    func testEachLineOfASpanGetsOneBoxTrimmedToItsWords() throws {
        let paragraph = try AttributedString(markdown: "Readings come from `\(Self.command)` on each box.")
        let longestWord = Self.renderedWidth(Text("--query-gpu=clocks.sm,clocks.mem").font(DS.Font.literal))
        for width in [longestWord + 10, longestWord + 60, longestWord + 200, 2_000] {
            let drawn = Self.draw(ChatInlineCode.text(paragraph), width: width)
            let codeLines = drawn.lines.filter { $0.contains { !$0.isSpace } }
            XCTAssertEqual(drawn.boxes.count, codeLines.count, "one box per line the span reaches at \(width) pt")
            for (box, line) in zip(drawn.boxes, codeLines) {
                let words = line.filter { !$0.isSpace }.map(\.rect)
                let start = try XCTUnwrap(words.map(\.minX).min())
                let end = try XCTUnwrap(words.map(\.maxX).max())
                XCTAssertEqual(box.minX, start - ChatInlineCode.boxOutset, accuracy: 0.01, "starts at its first word")
                XCTAssertEqual(box.maxX, end + ChatInlineCode.boxOutset, accuracy: 0.01, "ends at its last word")
                if let last = line.last, last.isSpace {
                    XCTAssertGreaterThanOrEqual(last.rect.minX, end - 0.01, "a space ending a line stays unfilled")
                }
            }
        }
        let short = Self.draw(ChatInlineCode.text(try AttributedString(markdown: "under `2,400 MHz` for a minute")), width: 2_000)
        XCTAssertEqual(short.boxes.count, 1)
        XCTAssertEqual(Self.draw(Text("no code here"), width: 2_000).boxes, [])
    }

    private struct DrawnPiece {
        let rect: CGRect
        let isSpace: Bool
    }

    private final class Drawing: @unchecked Sendable {
        var boxes: [CGRect] = []
        var lines: [[DrawnPiece]] = []
    }

    private struct Recorder: TextRenderer {
        let drawing: Drawing

        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            drawing.boxes = ChatInlineCode.boxes(in: layout)
            drawing.lines = layout.map { line in
                line.compactMap { run in
                    run[ChatCodeSpan.self].map { DrawnPiece(rect: run.typographicBounds.rect, isSpace: $0.isSpace) }
                }
            }
            for line in layout { context.draw(line) }
        }
    }

    private static func draw(_ text: Text, width: CGFloat) -> Drawing {
        let drawing = Drawing()
        let renderer = ImageRenderer(content: text.font(DS.Font.prose).textRenderer(Recorder(drawing: drawing))
            .frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        _ = renderer.uiImage
        return drawing
    }

    private static func renderedWidth(_ text: Text) -> CGFloat {
        UIHostingController(rootView: text.fixedSize()).sizeThatFits(in: CGSize(width: 10_000, height: 10_000)).width
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
