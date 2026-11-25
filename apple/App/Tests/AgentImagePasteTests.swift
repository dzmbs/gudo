import CoreGraphics
import DesignSystem
import GudoCore
import ImageIO
import Synchronization
import TerminalCore
@testable import TerminalRenderer
import UniformTypeIdentifiers
import XCTest
@testable import App
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A picture pasted or dropped on an agent pane goes to the agent on the pane's host, through
/// the pane image store where the helper has one; text and panes without an agent paste as before.
@MainActor
final class AgentImagePasteTests: XCTestCase {
    private nonisolated final class Host: AgentImageHost, @unchecked Sendable {
        let keepsPaneImages: Bool
        let failure: (any Error)?
        private let calls = Mutex<[(String, UInt64, Data)]>([])

        init(keepsPaneImages: Bool, failure: (any Error)? = nil) {
            self.keepsPaneImages = keepsPaneImages
            self.failure = failure
        }

        var received: [(String, UInt64, Data)] { calls.withLock { $0 } }

        func pastesImages() -> Bool { keepsPaneImages }

        func pasteImage(pane: UInt64, image: Data) async throws {
            if let failure { throw failure }
            calls.withLock { $0.append(("paste", pane, image)) }
        }

        func sendImage(pane: UInt64, image: Data) async throws {
            if let failure { throw failure }
            calls.withLock { $0.append(("send", pane, image)) }
        }
    }

    private nonisolated final class Sink: Sendable {
        let bytes = Mutex<[UInt8]>([])
    }

    private let claude = AgentDestination(hostId: "host", hostName: "studio", pane: 7, agent: .claude, title: "Claude Code", sameHost: false)

    private func screenshot(withLocation: Bool = false) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = withLocation
            ? [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N"]]
            : [:]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    private func metadata(_ data: Data) throws -> (type: String, all: [String: Any]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return (try XCTUnwrap(CGImageSourceGetType(source) as String?),
                try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]))
    }

    func testAHelperWithAPaneImageStoreGetsThePictureWithoutItsLocation() async throws {
        let host = Host(keepsPaneImages: true)
        let picture = try screenshot(withLocation: true)
        XCTAssertNotNil(try metadata(picture).all[kCGImagePropertyGPSDictionary as String])

        let toast = await AgentImageSender.deliver([picture], to: claude, through: host)
        XCTAssertEqual(toast.message, "Image sent to Claude Code")
        XCTAssertEqual(toast.style, .success)
        let sent = try XCTUnwrap(host.received.first)
        XCTAssertEqual(host.received.count, 1)
        XCTAssertEqual(sent.0, "paste")
        XCTAssertEqual(sent.1, 7)
        let written = try metadata(sent.2)
        XCTAssertEqual(written.type, UTType.png.identifier)
        XCTAssertNil(written.all[kCGImagePropertyGPSDictionary as String])
    }

    func testAnOlderHelperGetsItAsAnImageOfTheSession() async throws {
        let host = Host(keepsPaneImages: false)
        let toast = await AgentImageSender.deliver([try screenshot(), try screenshot()], to: claude, through: host)
        XCTAssertEqual(toast.message, "2 images sent to Claude Code")
        XCTAssertEqual(host.received.map(\.0), ["send", "send"])
    }

    func testTooManyPicturesOrARefusalSayWhy() async throws {
        let host = Host(keepsPaneImages: true)
        let many = Array(repeating: try screenshot(), count: AgentImageSender.maximumPerPaste + 1)
        let tooMany = await AgentImageSender.deliver(many, to: claude, through: host)
        XCTAssertEqual(tooMany.message, "Paste at most \(AgentImageSender.maximumPerPaste) images at once")
        XCTAssertEqual(tooMany.style, .failure)
        XCTAssertTrue(host.received.isEmpty)

        let busy = Host(keepsPaneImages: true, failure: WorkspaceError.Unavailable(message: "The agent is waiting for an answer. Answer it, then paste again."))
        let refused = await AgentImageSender.deliver([try screenshot()], to: claude, through: busy)
        XCTAssertEqual(refused.message, "Claude Code did not get it: The agent is waiting for an answer. Answer it, then paste again.")
        XCTAssertEqual(refused.style, .failure)

        let notAnImage = await AgentImageSender.deliver([Data("hello".utf8)], to: claude, through: host)
        XCTAssertEqual(notAnImage.message, "That file is not an image")
    }

    private func makeView(_ sink: Sink) throws -> TerminalView {
        let terminal = Terminal(cols: 40, rows: 5) { bytes in sink.bytes.withLock { $0 += Array(bytes) } }
        return TerminalView(surface: try TerminalSurface(terminal: terminal))
    }

    /// The routing the app installs on every terminal: pictures go to the agent while the pane
    /// has one, and paste as before once it has none.
    func testPastedPicturesFollowWhetherThePaneRunsAnAgent() throws {
        let sink = Sink(), view = try makeView(sink)
        var destination: AgentDestination? = claude
        var sent: [([PastedImage], AgentDestination)] = []
        AgentImageSender.install(on: view, destination: { destination }, send: { sent.append(($0, $1)) })
        let picture = try screenshot()

        #if canImport(UIKit)
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        board.setData(picture, forPasteboardType: UTType.png.identifier)
        view.paste(from: board)
        XCTAssertEqual(sent.map(\.0), [[.data(picture)]])
        XCTAssertEqual(sent.map(\.1), [claude])
        destination = nil
        view.paste(from: board)
        XCTAssertEqual(sent.count, 1)
        destination = claude
        board.string = "git status"
        view.paste(from: board)
        #else
        let board = NSPasteboard(name: .init("agent-picture-paste-\(UUID())"))
        defer { board.releaseGlobally() }
        board.setData(picture, forType: .png)
        view.paste(from: board)
        XCTAssertEqual(sent.map(\.0), [[.data(picture)]])
        XCTAssertEqual(sent.map(\.1), [claude])
        destination = nil
        view.paste(from: board)
        XCTAssertEqual(sent.count, 1)
        destination = claude
        board.clearContents()
        board.setString("git status", forType: .string)
        view.paste(from: board)
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/screen shot.png") as NSURL])
        XCTAssertTrue(view.drop(from: board, at: .zero, modifiers: []))
        XCTAssertEqual(sent.last?.0, [.file(URL(fileURLWithPath: "/tmp/screen shot.png"))])
        XCTAssertEqual(sent.count, 2)
        #endif
        XCTAssertEqual(String(decoding: sink.bytes.withLock { $0 }, as: UTF8.self), "git status", "text pastes as before")
    }
}
