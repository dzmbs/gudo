#if os(macOS)
import AppKit
import Synchronization
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// The Mac paste path end to end, in process: Edit ▸ Paste / ⌘V send `paste:` down the responder
/// chain to the focused terminal view, which pastes through libghostty-vt into the PTY.
@MainActor
@Suite(.serialized) struct AppKitPasteTests {
    private func makeView() throws -> (TerminalView, NSWindow, Sink) {
        _ = NSApplication.shared
        let written = Sink()
        let terminal = Terminal(cols: 40, rows: 5) { bytes in written.bytes.withLock { $0 += Array(bytes) } }
        let view = TerminalView(surface: try TerminalSurface(terminal: terminal))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        return (view, window, written)
    }

    @Test func editMenuPasteReachesThePtyBracketed() throws {
        let (view, window, written) = try makeView()
        view.surface.terminal.write(Array("\u{1b}[?2004h".utf8))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo one\necho two", forType: .string)

        let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(view.validateMenuItem(item))
        // What the Edit menu and ⌘V do: send paste: to the first responder.
        #expect(window.firstResponder === view)
        #expect(window.firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: item) == true)
        #expect(String(decoding: written.bytes.withLock { $0 }, as: UTF8.self) == "\u{1b}[200~echo one\necho two\u{1b}[201~")
        withExtendedLifetime(window) {}
    }

    @Test func singleLinePasteWithoutBracketsIsWrittenAsIs() throws {
        let (view, window, written) = try makeView()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ls -la", forType: .string)
        window.firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: nil)
        #expect(String(decoding: written.bytes.withLock { $0 }, as: UTF8.self) == "ls -la")
        withExtendedLifetime(view) {}
    }

    @Test func copyPutsSelectionTextOnThePasteboard() throws {
        let (view, window, _) = try makeView()
        view.surface.terminal.write(Array("hello world".utf8))
        view.surface.terminal.selectWord(atViewport: GridPoint(x: 7, y: 0))
        window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil)
        #expect(NSPasteboard.general.string(forType: .string) == "world")
    }

    @Test func copyJoinsSoftWrapsTrimsBlanksKeepsNewlines() throws {
        let (view, window, _) = try makeView()
        // 50 columns wrap on a 40-column grid; a hard newline; trailing blanks.
        view.surface.terminal.write(Array((String(repeating: "a", count: 50) + "\r\nnext   \r\n").utf8))
        view.surface.terminal.selectAll()
        window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil)
        #expect(NSPasteboard.general.string(forType: .string) == String(repeating: "a", count: 50) + "\nnext")
    }

    @Test func doubleClickSelectsAWholeURL() throws {
        let (view, window, _) = try makeView()
        view.surface.terminal.write(Array("see https://example.com/a/b ok".utf8))
        let rect = view.surface.rect(for: GridPoint(x: 12, y: 0))
        #expect(rect != .zero)
        let point = view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        for clicks in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: Double(clicks) * 0.1, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
                if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            }
        }
        #expect(view.surface.terminal.selectionText() == "https://example.com/a/b")
    }

    @Test func droppedTextAndFilesPaste() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("terminal-drop-test"))
        board.clearContents()
        board.setString("git status", forType: .string)
        #expect(TerminalView.droppedText(board) == "git status")
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/a b/it's.txt") as NSURL, URL(fileURLWithPath: "/tmp/plain.txt") as NSURL])
        #expect(TerminalView.droppedText(board) == "'/tmp/a b/it'\\''s.txt' /tmp/plain.txt")
        board.releaseGlobally()
    }
}
#endif

#if os(macOS)
final class Sink: Sendable {
    let bytes = Mutex<[UInt8]>([])
}
#endif
