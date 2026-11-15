import SwiftUI
import XCTest
@testable import App
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Copying from the file viewer, the file browser and the diff review.
@MainActor
final class FileCopyTests: XCTestCase {
    // MARK: Paths and menus

    func testRelativePathIsThePathInsideTheRepository() {
        XCTAssertEqual(RepositoryPath.relative("/home/me/gudo/src/main.rs", root: "/home/me/gudo"), "src/main.rs")
        XCTAssertEqual(RepositoryPath.relative("/home/me/gudo/src/main.rs", root: "/home/me/gudo/"), "src/main.rs")
        XCTAssertEqual(RepositoryPath.relative("/private/tmp/repo/a.txt", root: "/tmp/repo"), "a.txt")
        XCTAssertNil(RepositoryPath.relative("/home/me/gudo-other/a.rs", root: "/home/me/gudo"))
        XCTAssertNil(RepositoryPath.relative("/home/me/gudo", root: "/home/me/gudo"))
    }

    func testMenuOffersContentsPathAndRelativePathInThatOrder() {
        let inRepository = FileCopyAction.actions(
            path: "~/gudo/src/main.rs", resolvedPath: "/home/me/gudo/src/main.rs", line: 12, column: 3,
            contents: "fn main() {}", repositoryRoot: "/home/me/gudo")
        XCTAssertEqual(inRepository.map(\.title), ["Copy File Contents", "Copy Path", "Copy Relative Path", "Copy Path and Line"])
        XCTAssertEqual(inRepository.map(\.text), ["fn main() {}", "~/gudo/src/main.rs", "src/main.rs", "~/gudo/src/main.rs:12:3"])

        let outside = FileCopyAction.actions(path: "/etc/hosts", contents: nil, repositoryRoot: nil)
        XCTAssertEqual(outside.map(\.title), ["Copy Path"])
    }

    func testTheViewerCopiesTheWholeFileAndItsRelativePath() async {
        let model = FileViewerModel(target: FileTarget(hostId: "studio", path: "~/projects/gudo/src/main.rs", line: 20), reader: MockFileReader())
        await model.load()
        let actions = Dictionary(uniqueKeysWithValues: model.copyActions.map { ($0.kind, $0.text) })
        XCTAssertEqual(actions[.contents], MockFileReader.files["~/projects/gudo/src/main.rs"])
        XCTAssertEqual(actions[.path], "~/projects/gudo/src/main.rs")
        XCTAssertEqual(actions[.relativePath], "src/main.rs")
        XCTAssertEqual(actions[.pathWithLine], "~/projects/gudo/src/main.rs:20")
    }

    func testAPartlyShownFileOffersNoContentsToCopy() async {
        let text = (1...200_000).map { "line \($0) of a long log" }.joined(separator: "\n")
        let model = FileViewerModel(target: FileTarget(hostId: nil, path: "/log.txt", line: 150_000), reader: LogReader(text: text))
        await model.load()
        XCTAssertFalse(model.copyActions.contains { $0.kind == .contents })
    }

    func testTheBrowserKnowsTheRepositoryOfAMockFolder() async {
        let source = MockFileSource()
        let root = await source.repositoryRoot(of: "~/projects/gudo/crates")
        XCTAssertEqual(root, "~/projects/gudo")
        XCTAssertEqual(
            FileCopyAction.actions(path: "~/projects/gudo/crates/daemon", contents: nil, repositoryRoot: root).map(\.text),
            ["~/projects/gudo/crates/daemon", "crates/daemon"])
    }

    // MARK: Line numbers

    func testLineStartsFindTheLineOfEveryCharacter() {
        let starts = LineStarts("ab\n\nc日\n")
        XCTAssertEqual(starts.offsets, [0, 3, 4, 7])
        XCTAssertEqual(starts.line(at: 0), 0)
        XCTAssertEqual(starts.line(at: 2), 0)
        XCTAssertEqual(starts.line(at: 3), 1)
        XCTAssertEqual(starts.line(at: 5), 2)
        XCTAssertTrue(starts.isLineStart(4))
        XCTAssertFalse(starts.isLineStart(5))
        XCTAssertEqual(starts.range(ofLine: 2, textLength: 7), NSRange(location: 4, length: 2))
        XCTAssertEqual(starts.range(ofLine: 3, textLength: 7), NSRange(location: 7, length: 0))
    }

    func testTheGutterNumbersFromTheFirstLineShown() {
        let gutter = CodeGutterLayout()
        gutter.update(CodeTextContent(text: "one\ntwo\nthree", firstLine: 41, markedLine: 42))
        XCTAssertEqual(gutter.number(atCharacter: 0), 41)
        XCTAssertEqual(gutter.number(atCharacter: 4), 42)
        XCTAssertNil(gutter.number(atCharacter: 5), "a wrapped row has no number")
        XCTAssertEqual(gutter.markedRange, NSRange(location: 4, length: 3))
        XCTAssertEqual(gutter.lastNumber, 43)
    }

    // MARK: The text view

    #if os(macOS)
    private func hostedTextView(_ text: String, markedLine: Int? = nil) async throws -> (NSTextView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CodeTextView(text, firstLine: 1, markedLine: markedLine))
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<50 where Self.textView(in: window.contentView) == nil { try await Task.sleep(for: .milliseconds(20)) }
        return (try XCTUnwrap(Self.textView(in: window.contentView)), window)
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    func testSelectAllThenCopyTakesTheFileWithoutLineNumbers() async throws {
        let text = (1...300).map { "let value_\($0) = compute(\($0));  " }.joined(separator: "\n")
        let (textView, window) = try await hostedTextView(text)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.selectAll(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: (text as NSString).length))
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        XCTAssertTrue(textView.validateMenuItem(copy))
        NSPasteboard.general.clearContents()
        XCTAssertTrue(window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: copy) == true)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
        XCTAssertNil(NSPasteboard.general.data(forType: .rtf), "plain text only")
        XCTAssertNotNil(textView.enclosingScrollView?.verticalRulerView, "numbers are in a gutter beside the text")
        window.close()
    }

    /// The gutter paints only its own strip: a fill past its bounds once hid every line.
    func testTheTextIsDrawnBesideTheGutter() async throws {
        let (textView, window) = try await hostedTextView((1...5).map { _ in String(repeating: "█", count: 30) }.joined(separator: "\n"))
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let gutter = try XCTUnwrap(textView.enclosingScrollView?.verticalRulerView).frame.width
        let point = textView.convert(NSPoint(x: 0, y: textView.textContainerInset.height + 6), to: view)
        let fromTop = view.isFlipped ? point.y : view.bounds.height - point.y
        let inked = stride(from: Int(gutter) + 10, to: Int(gutter) + 150, by: 5).filter { x in
            let color = bitmap.colorAt(x: x * bitmap.pixelsWide / Int(view.bounds.width), y: Int(fromTop) * bitmap.pixelsHigh / Int(view.bounds.height))
            return (color?.brightnessComponent ?? 0) > 0.8
        }
        XCTAssertFalse(inked.isEmpty, "the first line's blocks are drawn")
        window.close()
    }

    func testAPartSelectedWithThePointerCopiesJustThatPart() async throws {
        let (textView, window) = try await hostedTextView("alpha\nbeta gamma\ndelta")
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 8, length: 13))
        NSPasteboard.general.clearContents()
        textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ta gamma\ndelt")
        window.close()
    }

    func testTheMarkedLineIsScrolledIntoView() async throws {
        let text = (1...400).map { "line \($0)" }.joined(separator: "\n")
        let (textView, window) = try await hostedTextView(text, markedLine: 300)
        for _ in 0..<50 where textView.visibleRect.minY == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let range = (text as NSString).range(of: "line 300")
        let layout = try XCTUnwrap(textView.layoutManager)
        let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: try XCTUnwrap(textView.textContainer))
        XCTAssertTrue(textView.visibleRect.intersects(rect.offsetBy(dx: 0, dy: textView.textContainerInset.height)))
        window.close()
    }
    #else
    func testTheTouchTextViewSelectsAndCopiesPlainText() async throws {
        let text = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let host = UIHostingController(rootView: CodeTextView(text))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        func find(_ view: UIView) -> UITextView? {
            if let textView = view as? UITextView { return textView }
            return view.subviews.lazy.compactMap(find).first
        }
        for _ in 0..<50 where find(host.view) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let textView = try XCTUnwrap(find(host.view))
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertEqual(textView.text, text)
        textView.selectAll(nil)
        XCTAssertTrue(textView.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        let board = UIPasteboard.general
        textView.copy(nil)
        XCTAssertEqual(board.string, text)
        XCTAssertGreaterThan(textView.textContainerInset.left, 0, "numbers sit in the inset, not in the text")
        window.isHidden = true
    }
    #endif
}

private struct LogReader: FileReading {
    let text: String

    func stat(_ path: String) async throws -> FileFacts {
        FileFacts(isDirectory: false, size: UInt64(text.utf8.count))
    }

    func read(_ path: String, offset: UInt64, length: UInt32) async throws -> FileBytes {
        let all = Data(text.utf8)
        let start = min(all.count, Int(offset))
        let end = min(all.count, start + Int(length))
        return FileBytes(data: all.subdata(in: start..<end), isEnd: end == all.count)
    }
}
