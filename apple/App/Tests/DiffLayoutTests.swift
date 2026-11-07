import CoreText
import DesignSystem
import SwiftUI
import XCTest
@testable import App
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class DiffLayoutTests: XCTestCase {
    private func file(path: String = "source.swift", count: Int = 2) -> DiffFile {
        DiffFile(path: path, status: .modified, additions: count, deletions: 0,
            hunks: [DiffHunk(id: 0, header: "@@ -0,0 +1,\(count) @@", lines: (0..<count).map {
                DiffLine(id: $0, kind: .added, oldNumber: nil, newNumber: $0 + 1, text: "let value\($0) = \($0)")
            })])
    }

    private func input(_ files: [DiffFile], split: Bool = false) -> DiffRenderInput {
        DiffRenderInput(files: files, collapsed: [], split: split, notes: [], width: 900)
    }

    func testSharedDiffLinesAreReadOnlyWithoutAnExplicitNoteCapability() throws {
        let sample = file()
        let line = try XCTUnwrap(sample.hunks.first?.lines.first)
        let preview = DiffLineContent(file: sample, left: line, right: nil, split: false)
        XCTAssertNil(preview.onTapLine)
        var captured: [(Int, Bool)] = []
        let review = DiffLineContent(file: sample, left: line, right: nil, split: false,
                                     onTapLine: { captured.append(($0.id, $1)) })
        review.onTapLine?(line, false)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.0, line.id)
        XCTAssertEqual(captured.first?.1, false)
    }

    func testRepeatedPathsKeepTheirDistinctSnapshotIdentitiesAndCollapseState() {
        var first = file(path: "shared.swift")
        var second = first
        first.renderIdentity = "tool:first"
        second.renderIdentity = "tool:second"
        var configuration = input([first, second])
        let expanded = DiffRenderDocument(input: configuration)
        XCTAssertEqual(Set(expanded.rows.map(\.id)).count, expanded.rows.count)
        configuration.collapsed = [first.id]
        let collapsed = DiffRenderDocument(input: configuration)
        let lines = collapsed.rows.filter { if case .line = $0.content { return true }; return false }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.fileIndex == 1 })
        XCTAssertEqual(collapsed.input.files.map(\.path), ["shared.swift", "shared.swift"])
        XCTAssertEqual(file().id, file().path)
    }

    func testMissingSystemFontUsesASizedMeasurableFallback() throws {
        for size in [CGFloat(13), 22] {
            let font = try XCTUnwrap(DiffRenderDocument.noteFont(nil, size: size))
            XCTAssertEqual(CTFontGetSize(font), size)
            let text = NSAttributedString(string: "A review note", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ])
            let line = CTLineCreateWithAttributedString(text)
            XCTAssertGreaterThan(CTLineGetTypographicBounds(line, nil, nil, nil), 0)
        }
    }

    func testAvailableSystemFontIsPreserved() throws {
        let preferred = CTFontCreateWithName("Helvetica" as CFString, 19, nil)
        let actual = try XCTUnwrap(DiffRenderDocument.noteFont(preferred, size: 19))
        XCTAssertTrue(CFEqual(actual, preferred))
    }

    func testPositionIndexFindsEveryBoundaryAndLargeJump() {
        let document = DiffRenderDocument(input: input([file(count: 20_000)]))
        XCTAssertEqual(document.rows.count, 20_003)
        XCTAssertEqual(document.indices.count, document.rows.count)
        for index in [0, 1, 2, 3, 1_000, 19_999, 20_002] {
            XCTAssertEqual(document.row(at: document.positions[index]), index)
            XCTAssertEqual(document.row(at: document.positions[index + 1] - 0.5), index)
        }
        XCTAssertEqual(document.row(at: -100), 0)
        XCTAssertEqual(document.row(at: document.height + 100), document.rows.count - 1)
        let range = document.visibleRows(in: CGRect(x: 0, y: document.height - 600, width: 900, height: 600))
        XCTAssertLessThanOrEqual(range.count, 35)
        XCTAssertEqual(range.upperBound, document.rows.count)
    }

    func testAnchoringSurvivesNotesAndCollapsingFilesAboveTheViewport() throws {
        let files = [file(path: "first.swift", count: 20), file(path: "second.swift", count: 20)]
        var value = input(files)
        let original = DiffRenderDocument(input: value)
        let index = try XCTUnwrap(original.indices["file:second.swift/hunk:0/line:8"])
        let anchor = try XCTUnwrap(original.anchor(at: original.positions[index] + 7))
        value.collapsed = ["first.swift"]
        value.notes = [ReviewNote(path: "second.swift", startLine: 1, endLine: 1, oldSide: false, note: "Please explain this change.")]
        let changed = DiffRenderDocument(input: value)
        let position = try XCTUnwrap(changed.position(of: anchor))
        XCTAssertEqual(changed.anchor(at: position), anchor)
        value.collapsed.insert("second.swift")
        let collapsed = DiffRenderDocument(input: value)
        XCTAssertNotNil(collapsed.position(of: anchor))
    }

    func testHunkIdentitiesAreNamespacedAndBothSidesKeepTheirNotes() {
        var sample = file()
        sample.hunks[0].lines = [
            DiffLine(id: 0, kind: .removed, oldNumber: 1, newNumber: nil, text: "old"),
            DiffLine(id: 1, kind: .added, oldNumber: nil, newNumber: 1, text: "new")
        ]
        sample.hunks.append(DiffHunk(id: 1, header: "@@ -2 +2 @@", lines: [DiffLine(id: 0, kind: .context, oldNumber: 2, newNumber: 2, text: "context")]))
        var value = input([sample], split: true)
        value.notes = [
            ReviewNote(path: sample.path, startLine: 1, endLine: 1, oldSide: true, note: "Old side"),
            ReviewNote(path: sample.path, startLine: 1, endLine: 1, oldSide: false, note: "New side")
        ]
        value.composing = NoteAnchor(path: sample.path, lineId: 1, number: 1, oldSide: false, quote: "new")
        let document = DiffRenderDocument(input: value)
        XCTAssertEqual(document.indices.count, document.rows.count)
        XCTAssertNotNil(document.indices["file:source.swift/hunk:0/line:0/composer:false"])
        for note in value.notes { XCTAssertNotNil(document.indices["note:\(note.id)"]) }
        XCTAssertEqual(document.rows.filter { if case .line = $0.content { return true }; return false }.count, 2)
    }

    func testLongLinesOnlyChangeHorizontalExtentAndNeverRowHeight() {
        var sample = file()
        sample.hunks[0].lines[0].text = String(repeating: "a very long line ", count: 1_000)
        for split in [false, true] {
            let document = DiffRenderDocument(input: input([sample], split: split))
            XCTAssertGreaterThan(document.contentWidth, 900)
            for (index, row) in document.rows.enumerated() {
                if case .line = row.content {
                    XCTAssertEqual(row.height, 18)
                    XCTAssertEqual(document.layout.rows[index].scrollsHorizontally, !split, "Split columns stay in the viewport while their code scrolls")
                }
            }
        }
    }

    func testTwentyThousandLinePositionLookupPerformance() {
        let document = DiffRenderDocument(input: input([file(count: 20_000)]))
        measure {
            for jump in 0..<20_000 {
                _ = document.visibleRows(in: CGRect(x: 0, y: CGFloat((jump * 997) % 360_000), width: 900, height: 600))
            }
        }
    }

    #if os(macOS)
    func testSmallSplitDiffLayoutSettlesWithoutExpandingItsRows() {
        var sample = file()
        sample.hunks[0].lines = [
            DiffLine(id: 0, kind: .removed, oldNumber: 1, newNumber: nil, text: String(repeating: "let value = anotherValue + ", count: 12)),
            DiffLine(id: 1, kind: .added, oldNumber: nil, newNumber: 1, text: "let value = 2")
        ]
        let view = NSHostingView(rootView: DiffLineContent(file: sample, left: sample.hunks[0].lines[0], right: sample.hunks[0].lines[1], split: true, onTapLine: { _, _ in }))
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        var heights: [CGFloat] = []
        for width in [900.0, 720, 700, 900, 900] {
            view.frame.size.width = width
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            heights.append(view.fittingSize.height)
        }
        XCTAssertTrue(heights.allSatisfy { $0.isFinite && $0 <= 18 }, "Rows must not expand to fill their own proposals: \(heights)")
        XCTAssertEqual(heights.last, heights.dropLast().last)
    }

    func testNativeListReusesOnlyVisibleRowsWhenJumpingTwentyThousandLines() throws {
        let sample = file(count: 20_000)
        let document = DiffRenderDocument(input: input([sample]))
        var rendered: Set<String> = []
        let list = NativeDiffList(document: document) { row in
            rendered.insert(row.id)
            if case let .line(left, right) = row.content {
                return AnyView(DiffLineContent(file: sample, left: left, right: right, split: false, onTapLine: { _, _ in }))
            }
            return AnyView(Text(row.id))
        }
        let host = NSHostingView(rootView: list)
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func collection(in view: NSView) -> NSCollectionView? {
            if let value = view as? NSCollectionView { return value }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        let native = try XCTUnwrap(collection(in: host))
        let scroll = try XCTUnwrap(native.enclosingScrollView)
        for row in [10_000, 19_999, 2, 20_002] {
            let path = IndexPath(item: row, section: 0)
            let started = ContinuousClock.now
            native.scrollToItems(at: [path], scrollPosition: .top)
            scroll.layoutSubtreeIfNeeded()
            native.layoutSubtreeIfNeeded()
            let elapsed = started.duration(to: .now)
            print("native diff main-thread jump to \(row): \(elapsed)")
            XCTAssertLessThan(elapsed, .milliseconds(250))
            XCTAssertNotNil(native.item(at: path))
        }
        XCTAssertEqual(native.numberOfItems(inSection: 0), 20_003)
        for row in [0, 2, 3, 19_999, 20_002] {
            let attributes = try XCTUnwrap(native.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: row, section: 0)))
            XCTAssertEqual(attributes.frame.minY, document.positions[row], accuracy: 0.5)
            XCTAssertEqual(attributes.frame.height, document.rows[row].height, accuracy: 0.5)
        }
        XCTAssertLessThan(rendered.count, 250, "Offscreen rows must not build SwiftUI content")
    }
    #else
    func testTouchNativeListReusesRowsForTwentyThousandLineJumps() throws {
        let sample = file(count: 20_000)
        let document = DiffRenderDocument(input: input([sample]))
        var rendered: Set<String> = []
        let list = NativeDiffList(document: document) { row in
            rendered.insert(row.id)
            if case let .line(left, right) = row.content {
                return AnyView(DiffLineContent(file: sample, left: left, right: right, split: false, onTapLine: { _, _ in }))
            }
            return AnyView(Text(row.id))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let host = UIHostingController(rootView: list)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        func collection(in view: UIView) -> UICollectionView? {
            if let value = view as? UICollectionView { return value }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        let native = try XCTUnwrap(collection(in: host.view))
        for row in [10_000, 19_999, 2, 20_002] {
            let path = IndexPath(item: row, section: 0)
            let started = ContinuousClock.now
            native.scrollToItem(at: path, at: .top, animated: false)
            native.layoutIfNeeded()
            let elapsed = started.duration(to: .now)
            print("native diff main-thread jump to \(row): \(elapsed)")
            XCTAssertLessThan(elapsed, .milliseconds(250))
            XCTAssertNotNil(native.cellForItem(at: path))
        }
        XCTAssertEqual(native.numberOfItems(inSection: 0), 20_003)
        XCTAssertLessThan(rendered.count, 300)
        let attributes = try XCTUnwrap(native.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 20_002, section: 0)))
        XCTAssertEqual(attributes.frame.minY, document.positions[20_002])
        XCTAssertEqual(attributes.frame.height, 18)
    }
    #endif
}
