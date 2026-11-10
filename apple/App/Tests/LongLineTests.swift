import XCTest
@testable import App

/// A minified file is one line of up to a MiB; a row draws only its start.
final class LongLineTests: XCTestCase {
    private let minified = String(repeating: "var a=function(b){return b+1};", count: 35_000)

    func testShortLinesAreDrawnWhole() {
        XCTAssertEqual(DisplayLine.capped("let value = 1"), "let value = 1")
        let exact = String(repeating: "x", count: DisplayLine.maximumCharacters)
        XCTAssertEqual(DisplayLine.capped(exact), exact)
        let wide = String(repeating: "é", count: DisplayLine.maximumCharacters)
        XCTAssertEqual(DisplayLine.capped(wide), wide)
    }

    func testALongLineEndsInAnEllipsis() {
        let capped = DisplayLine.capped(minified)
        XCTAssertEqual(capped.count, DisplayLine.maximumCharacters + 1)
        XCTAssertTrue(minified.hasPrefix(capped.dropLast()))
        XCTAssertTrue(capped.hasSuffix("…"))
        let emoji = DisplayLine.capped(String(repeating: "👩‍👩‍👧", count: 10_000))
        XCTAssertEqual(emoji.count, DisplayLine.maximumCharacters + 1)
    }

    func testTextPreviewOfAMinifiedFileHasARowWideLayout() {
        let document = NativeTextDocument(input: .init(
            text: "first\n" + minified, numbered: true, truncated: false, width: 800, lineHeight: 18, fontSize: 11))
        XCTAssertEqual(document.lines.count, 2)
        XCTAssertEqual(document.lines[0], "first")
        XCTAssertEqual(document.lines[1], DisplayLine.capped(minified))
        XCTAssertLessThan(document.layout.contentWidth, CGFloat(DisplayLine.maximumCharacters + 1) * 18 + 200)
    }

    func testDiffOfAMinifiedFileHasARowWideLayout() {
        let file = DiffFile(path: "bundle.min.js", status: .modified, additions: 1, deletions: 1, hunks: [
            DiffHunk(id: 0, header: "@@ -1 +1 @@", lines: [
                DiffLine(id: 0, kind: .removed, oldNumber: 1, newNumber: nil, text: minified),
                DiffLine(id: 1, kind: .added, oldNumber: nil, newNumber: 1, text: minified + "x"),
            ]),
        ])
        for split in [false, true] {
            let document = DiffRenderDocument(input: DiffRenderInput(
                files: [file], collapsed: [], split: split, notes: [], width: 900))
            XCTAssertLessThan(document.contentWidth, CGFloat(DisplayLine.maximumCharacters + 1) * 8 + 1_200)
        }
    }
}
