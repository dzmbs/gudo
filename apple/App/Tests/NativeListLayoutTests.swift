import XCTest
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import App

final class NativeListLayoutTests: XCTestCase {
    func testIdenticalGeometryKeepsItsRevisionAcrossContentUpdates() {
        let rows = [NativeListRow(id: "header", height: 36, isHeader: true), NativeListRow(id: "line", height: 18, sectionID: "header")]
        let first = NativeListLayout(rows: rows, contentWidth: 800)
        let second = NativeListLayout(rows: rows, contentWidth: 800)
        XCTAssertEqual(first.revision, second.revision)
        XCTAssertNotEqual(first.revision, NativeListLayout(rows: rows, contentWidth: 900).revision)
        XCTAssertNotEqual(first.revision, NativeListLayout(rows: Array(rows.dropLast()), contentWidth: 800).revision)
    }

    func testEmptyLayoutAndPinnedHeaderBoundaries() {
        let empty = NativeListLayout()
        XCTAssertNil(empty.row(at: 0))
        XCTAssertNil(empty.anchor(at: 0))
        XCTAssertEqual(empty.visibleRows(in: .zero), 0..<0)
        let rows = [NativeListRow(id: "summary", height: 88),
            NativeListRow(id: "first", height: 36, isHeader: true), NativeListRow(id: "line", height: 18),
            NativeListRow(id: "second", height: 36, isHeader: true)]
        let layout = NativeListLayout(rows: rows)
        XCTAssertNil(layout.header(at: 0))
        XCTAssertEqual(layout.header(at: 88), 1)
        XCTAssertEqual(layout.header(at: 141), 1)
        XCTAssertEqual(layout.header(at: 142), 3)
        XCTAssertEqual(layout.nextHeaderPosition(after: 1), 142)
        XCTAssertEqual(layout.nextHeaderPosition(after: 3), layout.height)
    }

    func testTwentyThousandTextLinesHaveFixedHeightsAndPrecomputedGutters() {
        let text = (0..<20_000).map { "line \($0)" }.joined(separator: "\n")
        let document = NativeTextDocument(input: .init(text: text, numbered: true, truncated: true, width: 800, lineHeight: 18, fontSize: 13))
        XCTAssertEqual(document.lines.count, 20_000)
        XCTAssertEqual(document.layout.rows.count, 20_001)
        XCTAssertTrue(document.layout.rows.dropLast().allSatisfy { $0.height == 18 })
        XCTAssertEqual(document.layout.positions[20_000], 360_000)
        XCTAssertEqual(document.layout.rows.last?.id, "truncated")
        XCTAssertGreaterThan(document.gutterWidth, 50)
        XCTAssertEqual(document.layout.row(at: 350_000), 19_444)
    }

    #if os(macOS)
    @MainActor
    func testCachedParagraphHeightDoesNotTruncateSwiftUIText() {
        let text = String(repeating: "Permission is hereby granted, free of charge, to any person obtaining a copy of this software. ", count: 12)
        let document = NativeTextDocument(input: .init(text: text, numbered: false, truncated: false, width: 600, lineHeight: 18, fontSize: 11))
        let host = NSHostingView(rootView: Text(verbatim: text)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 568, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4))
        XCTAssertGreaterThanOrEqual(document.layout.rows[0].height, host.fittingSize.height)
    }
    #endif

    func testLicenseParagraphsAreMeasuredBeforeRenderingAndReflowOnResize() {
        let text = String(repeating: "This paragraph must remain readable without clipping. ", count: 20) + "\n\nNext paragraph."
        let narrow = NativeTextDocument(input: .init(text: text, numbered: false, truncated: false, width: 300, lineHeight: 18, fontSize: 13))
        let wide = NativeTextDocument(input: .init(text: text, numbered: false, truncated: false, width: 900, lineHeight: 18, fontSize: 13))
        XCTAssertEqual(narrow.layout.rows.count, 2)
        XCTAssertGreaterThan(narrow.layout.rows[0].height, wide.layout.rows[0].height)
        XCTAssertEqual(narrow.layout.contentWidth, 300)
        XCTAssertEqual(narrow.gutterWidth, 0)
        XCTAssertFalse(narrow.layout.rows[0].scrollsHorizontally)
    }
}
