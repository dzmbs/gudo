#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI
import XCTest
@testable import App

@MainActor
final class DiffLayoutTests: XCTestCase {
    func testSmallSplitDiffLayoutSettlesWithoutExpandingItsRows() {
        let file = DiffFile(path: "source.swift", status: .modified, additions: 1, deletions: 1,
            hunks: [DiffHunk(id: 0, header: "@@ -1 +1 @@", lines: [
                DiffLine(id: 0, kind: .removed, oldNumber: 1, newNumber: nil, text: String(repeating: "let value = anotherValue + ", count: 12)),
                DiffLine(id: 1, kind: .added, oldNumber: nil, newNumber: 1, text: "let value = 2")
            ])])
        let view = NSHostingView(rootView: FileDiffBody(file: file, split: true, notes: [], composing: nil,
            onTapLine: { _, _ in }, onSaveNote: { _ in }, onCancelNote: {}, onDeleteNote: { _ in }))
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        var heights: [CGFloat] = []
        for _ in 0..<4 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            heights.append(view.fittingSize.height)
        }
        XCTAssertTrue(heights.allSatisfy { $0.isFinite && $0 <= 48 }, "A two-line diff must not expand to fill its own proposal: \(heights)")
        XCTAssertEqual(heights.last, heights.dropLast().last)
    }
}
#endif
