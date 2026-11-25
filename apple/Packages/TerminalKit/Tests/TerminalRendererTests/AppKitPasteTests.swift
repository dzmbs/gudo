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

    @Test func imageOnlyClipboardDoesNotPlaceOrWriteAnything() throws {
        let (view, window, written) = try makeView()
        let board = NSPasteboard(name: .init("terminal-image-paste-\(UUID())"))
        defer { board.releaseGlobally() }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jAj0AAAAASUVORK5CYII=")!
        board.setData(png, forType: .png)
        #expect(TerminalView.hasAttachment(board))
        var placements = 0
        view.onPasteAttachment = { _ in placements += 1; return true }
        view.paste(from: board)
        #expect(placements == 0)
        #expect(written.bytes.withLock { $0 }.isEmpty)
        withExtendedLifetime(window) {}
    }

    /// A pane that takes pictures (an agent's) gets an image alone, or image files, instead of a
    /// paste; text, other files and panes that take none paste as before.
    @Test func picturesGoToAPaneThatTakesThemAndTextStillPastes() throws {
        let (view, window, written) = try makeView()
        let board = NSPasteboard(name: .init("terminal-picture-paste-\(UUID())"))
        defer { board.releaseGlobally() }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jAj0AAAAASUVORK5CYII=")!
        var takes = false
        var received: [[PastedImage]] = []
        view.acceptsImages = { takes }
        view.onImages = { received.append($0) }

        board.setData(png, forType: .png)
        view.paste(from: board)
        #expect(received.isEmpty, "a shell takes no pictures")
        takes = true
        view.paste(from: board)
        #expect(received == [[.data(png)]])

        board.clearContents()
        board.setString("echo one", forType: .string)
        board.setData(png, forType: .png)
        view.paste(from: board)
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/notes.txt") as NSURL, URL(fileURLWithPath: "/tmp/shot.png") as NSURL])
        view.paste(from: board)
        #expect(received.count == 1)
        #expect(String(decoding: written.bytes.withLock { $0 }, as: UTF8.self) == "echo one/tmp/notes.txt /tmp/shot.png")

        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/a b/shot.png") as NSURL, URL(fileURLWithPath: "/tmp/photo.HEIC") as NSURL])
        #expect(view.drop(from: board, at: .zero, modifiers: []))
        #expect(received.last == [.file(URL(fileURLWithPath: "/tmp/a b/shot.png")), .file(URL(fileURLWithPath: "/tmp/photo.HEIC"))])
        withExtendedLifetime(window) {}
    }

    @Test func pasteIsOfferedForAnImageAloneOnlyWhereItIsTaken() throws {
        let (view, window, _) = try makeView()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(Data([0x89, 0x50, 0x4e, 0x47]), forType: .png)
        let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(!view.validateMenuItem(item))
        view.acceptsImages = { true }
        #expect(view.validateMenuItem(item))
        let drag = FakeDrag(NSPasteboard.general)
        #expect(view.draggingEntered(drag) == .copy)
        view.acceptsImages = { false }
        #expect(view.draggingEntered(drag) == [])
        withExtendedLifetime(window) {}
    }

    @Test func fileClipboardPastesTheEscapedPathNotTheFinderNameOrAnImage() throws {
        let (view, window, written) = try makeView()
        let board = NSPasteboard(name: .init("terminal-file-paste-\(UUID())"))
        defer { board.releaseGlobally() }
        board.writeObjects([URL(fileURLWithPath: "/tmp/a b/it's.png") as NSURL])
        board.setString("it's.png", forType: .string)
        var placements = 0
        view.onPasteAttachment = { _ in placements += 1; return true }
        view.paste(from: board)
        #expect(placements == 0)
        #expect(String(decoding: written.bytes.withLock { $0 }, as: UTF8.self) == "'/tmp/a b/it'\\''s.png'")
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

    private func commandKey(_ type: NSEvent.EventType, _ characters: String, keyCode: UInt16, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: .command, timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// Ghostty: Copy is enabled only with a selection; otherwise ⌘C is the program's key, which
    /// the legacy encoding drops and the kitty protocol reports. It never reaches the window,
    /// which would beep.
    @Test func commandCWithoutSelectionGoesToTheProgramNotTheWindow() throws {
        let (view, window, written) = try makeView()
        view.onInput = { bytes in written.bytes.withLock { $0 += bytes } }
        let beyond = KeyRecorder()
        view.nextResponder = beyond
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        #expect(!view.validateMenuItem(copyItem))

        view.keyDown(with: try commandKey(.keyDown, "c", keyCode: 8, window: window))
        view.keyUp(with: try commandKey(.keyUp, "c", keyCode: 8, window: window))
        #expect(written.bytes.withLock { $0 }.isEmpty)
        #expect(beyond.keyDowns == 0)

        view.surface.terminal.write(Array("\u{1b}[>3u".utf8))
        view.keyDown(with: try commandKey(.keyDown, "c", keyCode: 8, window: window))
        view.keyUp(with: try commandKey(.keyUp, "c", keyCode: 8, window: window))
        #expect(String(decoding: written.bytes.withLock { $0 }, as: UTF8.self) == "\u{1b}[99;9u\u{1b}[99;9:3u")
        #expect(beyond.keyDowns == 0)
    }

    @Test func commandCWithSelectionCopiesAndSendsNothing() throws {
        let (view, window, written) = try makeView()
        view.onInput = { bytes in written.bytes.withLock { $0 += bytes } }
        view.surface.terminal.write(Array("\u{1b}[>3uhello".utf8))
        view.surface.terminal.selectWord(atViewport: GridPoint(x: 1, y: 0))
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        #expect(view.validateMenuItem(copyItem))
        NSPasteboard.general.clearContents()
        window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: copyItem)
        // The menu took the key down; only its key up reaches the view.
        view.keyUp(with: try commandKey(.keyUp, "c", keyCode: 8, window: window))
        #expect(NSPasteboard.general.string(forType: .string) == "hello")
        #expect(written.bytes.withLock { $0 }.isEmpty)
    }

    @Test func selectAllThenCopyTakesTheScrollbackToo() throws {
        let (view, window, _) = try makeView()
        view.surface.terminal.write(Array((0..<12).map { "line \($0)\r\n" }.joined().utf8))
        let selectAll = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        #expect(view.validateMenuItem(selectAll))
        window.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: selectAll)
        window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil)
        #expect(NSPasteboard.general.string(forType: .string) == (0..<12).map { "line \($0)" }.joined(separator: "\n"))
    }

    @Test func rightClickMenuOffersCopyOnlyWithASelectionAndAlwaysPaste() throws {
        let (view, window, _) = try makeView()
        view.surface.terminal.write(Array("hello".utf8))
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 10, y: 190), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let plain = try #require(view.menu(for: click))
        #expect(plain.items.map(\.title) == ["Paste", "Select All"])
        view.surface.terminal.selectWord(atViewport: GridPoint(x: 1, y: 0))
        let selected = try #require(view.menu(for: click))
        #expect(selected.items.map(\.title) == ["Copy", "Paste", "Select All"])
        #expect(selected.items.allSatisfy { $0.target === view })
    }

    /// Shift takes the mouse back from a program that tracks it, as in Ghostty: the drag selects.
    @Test func shiftDragSelectsWhileTheProgramTracksTheMouse() throws {
        let (view, window, written) = try makeView()
        view.surface.terminal.write(Array("\u{1b}[?1000h\u{1b}[?1006hhello world".utf8))
        let first = view.surface.rect(for: GridPoint(x: 0, y: 0)), fifth = view.surface.rect(for: GridPoint(x: 4, y: 0))
        // A drag takes in the cell it ends on once it passes the cell's middle, as in Ghostty.
        let from = CGPoint(x: first.minX + 1, y: first.midY), to = CGPoint(x: fifth.maxX - 1, y: fifth.midY)
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        var reported: [UInt8] = []
        view.onInput = { reported += $0 }
        view.mouseDown(with: try mouse(.leftMouseDown, from, []))
        view.mouseUp(with: try mouse(.leftMouseUp, from, []))
        #expect(!reported.isEmpty, "a plain click is the program's")
        #expect(view.surface.terminal.selection == nil)
        reported = []

        view.mouseDown(with: try mouse(.leftMouseDown, from, .shift))
        view.mouseDragged(with: try mouse(.leftMouseDragged, to, .shift))
        view.mouseUp(with: try mouse(.leftMouseUp, to, .shift))
        #expect(reported.isEmpty)
        #expect(written.bytes.withLock { $0 }.isEmpty)
        #expect(view.surface.terminal.selectionText() == "hello")
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

    @Test func ordinaryDropsPastePathsAndOnlyExplicitOptionDropsImportImages() throws {
        let (view, window, written) = try makeView()
        let board = NSPasteboard(name: .init("terminal-explicit-drop-\(UUID())"))
        defer { board.releaseGlobally() }
        var placements = 0
        view.onDropAttachment = { _, _ in placements += 1; return true }
        board.writeObjects([URL(fileURLWithPath: "/tmp/a b/it's.png") as NSURL])
        #expect(view.drop(from: board, at: .zero, modifiers: []))
        #expect(placements == 0)
        #expect(String(decoding: written.bytes.withLock { $0 }, as: UTF8.self) == "'/tmp/a b/it'\\''s.png'")
        board.clearContents()
        board.setData(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jAj0AAAAASUVORK5CYII=")!, forType: .png)
        #expect(!view.drop(from: board, at: .zero, modifiers: []))
        #expect(placements == 0)
        #expect(view.drop(from: board, at: .zero, modifiers: .option))
        #expect(placements == 1)
        board.clearContents()
        view.attachmentDragTypes = ["test.internal-drawing"]
        board.setData(Data(), forType: .init("test.internal-drawing"))
        #expect(view.drop(from: board, at: .zero, modifiers: []))
        #expect(placements == 2)
        withExtendedLifetime(window) {}
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

    /// A drag of a huge text is asked about on every pointer move: the answer looks at the
    /// pasteboard's types and never reads the text (reading 64 MB on each move froze the window
    /// for the whole drag). The drop itself is refused calmly, with nothing written.
    @Test func dragOfHugeTextStaysResponsive() throws {
        let (view, window, written) = try makeView()
        let board = NSPasteboard(name: NSPasteboard.Name("terminal-huge-drop-test"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString(String(repeating: "0123456789abcde\n", count: 4 << 20), forType: .string)
        let drag = FakeDrag(board)
        let start = ContinuousClock.now
        #expect(view.draggingEntered(drag) == .copy)
        for _ in 0..<60 { _ = view.draggingUpdated(drag) }
        #expect(ContinuousClock.now - start < .milliseconds(100))
        // No window: the refusal would be a modal alert, so only the paste itself is checked.
        #expect(view.surface.paste(TerminalView.droppedText(board)!) == .tooLarge)
        #expect(written.bytes.withLock { $0 }.isEmpty)
        withExtendedLifetime(window) {}
    }

    /// Dropped text pastes; a drag of an unpasted type (a tab carries its reference as text too)
    /// goes to the view around the terminal instead.
    @Test func unpastedDragsGoToTheViewAround() throws {
        let (view, window, written) = try makeView()
        let around = DropRecorder(frame: view.frame)
        around.registerForDraggedTypes([NSPasteboard.PasteboardType("dev.gudo.tab")])
        window.contentView = around
        around.addSubview(view)
        view.unpastedDragTypes = ["dev.gudo.tab"]
        let board = NSPasteboard(name: NSPasteboard.Name("terminal-unpasted-drop-test"))
        defer { board.releaseGlobally() }

        board.clearContents()
        board.setString("ls", forType: .string)
        let text = FakeDrag(board)
        #expect(view.draggingEntered(text) == .copy)
        #expect(view.performDragOperation(text))
        #expect(String(decoding: written.bytes.withLock { $0 }, as: UTF8.self) == "ls")
        #expect(around.events.isEmpty)

        board.clearContents()
        board.setString("host/1", forType: .string)
        board.setData(Data("host/1".utf8), forType: NSPasteboard.PasteboardType("dev.gudo.tab"))
        let tab = FakeDrag(board)
        #expect(view.draggingEntered(tab) == .move)
        #expect(view.draggingUpdated(tab) == .move)
        view.draggingExited(tab)
        #expect(view.performDragOperation(tab))
        #expect(around.events == ["entered", "updated", "exited", "perform"])
        #expect(String(decoding: written.bytes.withLock { $0 }, as: UTF8.self) == "ls", "the tab was not pasted")
    }
}

/// The responder after the terminal: a key reaching it would beep.
private final class KeyRecorder: NSResponder {
    var keyDowns = 0
    override func keyDown(with event: NSEvent) { keyDowns += 1 }
}

/// A view that takes drops and records what reached it.
private final class DropRecorder: NSView {
    var events: [String] = []
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { events.append("entered"); return .move }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { events.append("updated"); return .move }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { events.append("exited") }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { events.append("perform"); return true }
}

/// A drag over a pasteboard, for driving a view's drop methods in process.
@MainActor
private final class FakeDrag: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ board: NSPasteboard) { draggingPasteboard = board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
#endif

#if os(macOS)
final class Sink: Sendable {
    let bytes = Mutex<[UInt8]>([])
}
#endif
