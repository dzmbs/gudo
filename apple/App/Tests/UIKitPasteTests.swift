#if os(iOS)
import Synchronization
import TerminalCore
@testable import TerminalRenderer
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import App

nonisolated private final class PasteSink: Sendable {
    let bytes = Mutex<[UInt8]>([])
}

@MainActor
final class UIKitPasteTests: XCTestCase {
    private func makeView(_ sink: PasteSink) throws -> TerminalView {
        let terminal = Terminal(cols: 40, rows: 5) { bytes in sink.bytes.withLock { $0 += Array(bytes) } }
        return TerminalView(surface: try TerminalSurface(terminal: terminal))
    }

    func testImageOnlyDropDoesNotOfferPlacement() {
        let provider = NSItemProvider(object: UIImage())
        XCTAssertEqual(PaneDrawing.terminalDropKind([provider]), .ignore)
    }

    func testFileDropTakesPrecedenceOverImageRepresentations() {
        let provider = NSItemProvider(object: URL(fileURLWithPath: "/tmp/a b/it's.png") as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }
        XCTAssertEqual(PaneDrawing.terminalDropKind([provider]), .files)
    }

    func testTextDropRemainsText() {
        XCTAssertEqual(PaneDrawing.terminalDropKind([NSItemProvider(object: "git status" as NSString)]), .text)
    }

    func testImageOnlyPasteDoesNotPlaceOrWriteAnything() throws {
        let sink = PasteSink(), view = try makeView(sink)
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        board.image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        XCTAssertTrue(board.hasImages)
        var placements = 0
        view.onPasteAttachment = { _ in placements += 1; return true }
        view.paste(from: board)
        XCTAssertEqual(placements, 0)
        XCTAssertTrue(sink.bytes.withLock { $0 }.isEmpty)
    }

    func testFileURLTakesPrecedenceOverItsDisplayNameAndUsesShellQuoting() throws {
        let sink = PasteSink(), view = try makeView(sink)
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        board.urls = [URL(fileURLWithPath: "/tmp/a b/it's.png")]
        board.addItems([[UTType.utf8PlainText.identifier: "it's.png"]])
        view.paste(from: board)
        XCTAssertEqual(String(decoding: sink.bytes.withLock { $0 }, as: UTF8.self), "'/tmp/a b/it'\\''s.png'")
        sink.bytes.withLock { $0 = [] }
        view.pasteURLs([URL(fileURLWithPath: "/tmp/a b/it's.png")])
        XCTAssertEqual(String(decoding: sink.bytes.withLock { $0 }, as: UTF8.self), "'/tmp/a b/it'\\''s.png'")
    }
}
#endif
