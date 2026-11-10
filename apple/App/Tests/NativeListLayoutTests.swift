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

    func testHeightUpdatesPreserveIndicesAndRecomputeOnlyGeometry() {
        let rows = [NativeListRow(id: "header", height: 36, isHeader: true),
                    NativeListRow(id: "first", height: 18, sectionID: "header"),
                    NativeListRow(id: "second", height: 18, sectionID: "header")]
        var layout = NativeListLayout(rows: rows, contentWidth: 400)
        let revision = layout.revision
        layout.setHeights([1: 52, 2: 30, 10: 80, -1: 80])
        XCTAssertEqual(layout.positions, [0, 36, 88, 118])
        XCTAssertEqual(layout.indices, ["header": 0, "first": 1, "second": 2])
        XCTAssertEqual(layout.headers, [0])
        XCTAssertEqual(layout.contentWidth, 400)
        XCTAssertNotEqual(layout.revision, revision)
        let unchanged = layout.revision
        layout.setHeights([1: 52, 2: -.infinity, 0: 0])
        XCTAssertEqual(layout.revision, unchanged)
        XCTAssertEqual(layout.positions, [0, 36, 88, 118])
    }

    func testReplacingTheTailMatchesBuildingTheWholeList() {
        let header = NativeListRow(id: "header", height: 36, isHeader: true)
        let first = NativeListRow(id: "first", height: 18, sectionID: "header")
        let streaming = NativeListRow(id: "streaming", height: 40, sectionID: "header")
        var layout = NativeListLayout(rows: [header, first, streaming], contentWidth: 400)
        let tail = [NativeListRow(id: "streaming", height: 64, sectionID: "header"),
                    NativeListRow(id: "next", height: 24, isHeader: true),
                    NativeListRow(id: "last", height: 18, sectionID: "next")]
        let revision = layout.revision
        layout.replaceRows(from: 2, with: tail)
        let whole = NativeListLayout(rows: [header, first] + tail, contentWidth: 400)
        XCTAssertEqual(layout.rows, whole.rows)
        XCTAssertEqual(layout.positions, whole.positions)
        XCTAssertEqual(layout.indices, whole.indices)
        XCTAssertEqual(layout.headers, whole.headers)
        XCTAssertNotEqual(layout.revision, revision)

        let unchanged = layout.revision
        layout.replaceRows(from: 3, with: Array(tail.dropFirst()))
        XCTAssertEqual(layout.revision, unchanged)

        layout.replaceRows(from: 1, with: [])
        XCTAssertEqual(layout.indices, ["header": 0])
        XCTAssertEqual(layout.headers, [0])
        XCTAssertEqual(layout.positions, [0, 36])
    }

    func testAnchorsKeepValidSubpointPositionsAtTheEndOfARow() throws {
        let rows = [NativeListRow(id: "first", height: 18), NativeListRow(id: "reading", height: 36),
                    NativeListRow(id: "next", height: 18)]
        let layout = NativeListLayout(rows: rows)
        let anchor = try XCTUnwrap(layout.anchor(at: 53.75))
        XCTAssertEqual(anchor.id, "reading")
        XCTAssertEqual(try XCTUnwrap(layout.position(of: anchor)), 53.75, accuracy: 0.000_001)
        let prepended = NativeListLayout(rows: [NativeListRow(id: "earlier", height: 100.5)] + rows)
        XCTAssertEqual(try XCTUnwrap(prepended.position(of: anchor)), 154.25, accuracy: 0.000_001)
        var shortened = layout
        shortened.setHeights([1: 12])
        XCTAssertEqual(shortened.position(of: anchor), 29, "Only offsets outside the resized row need its end fallback")
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
