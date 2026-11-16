#if os(macOS)
import AppKit
import Synchronization
import Testing
@testable import TerminalCore
@testable import TerminalRenderer

/// The Mac terminal driven the way a person drives it: key events through the window, mouse
/// presses and drags with their click counts, and the scroll wheel. Each test checks what the
/// program receives or what the screen shows.
@MainActor
@Suite(.serialized) struct AppKitUserInputTests {
    private final class Written: Sendable {
        let bytes = Mutex<[UInt8]>([])
        var text: String { String(decoding: bytes.withLock { $0 }, as: UTF8.self) }
        func reset() { bytes.withLock { $0 = [] } }
    }

    /// Event time: clicks a gesture apart are a second apart, its own clicks a tenth.
    private final class Clock {
        var now: TimeInterval = 1000
    }

    @MainActor private struct Fixture {
        let view: TerminalView
        let window: NSWindow
        let written: Written
        let clock = Clock()
        var terminal: Terminal { view.surface.terminal }
    }

    private func makeTerminal(cols: UInt16 = 40, rows: UInt16 = 5) throws -> Fixture {
        _ = NSApplication.shared
        let written = Written()
        let terminal = Terminal(cols: cols, rows: rows) { bytes in written.bytes.withLock { $0 += Array(bytes) } }
        let view = TerminalView(surface: try TerminalSurface(terminal: terminal))
        view.onInput = { bytes in written.bytes.withLock { $0 += bytes } }
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        return Fixture(view: view, window: window, written: written)
    }

    // MARK: Keys

    private enum Key: UInt16 {
        case a = 0, s = 1, l = 37, c = 8, u = 32, returnKey = 36, delete = 51, escape = 53
        case home = 115, pageUp = 116, end = 119, pageDown = 121
        case left = 123, right = 124, down = 125, up = 126
    }

    private static func functionCharacter(_ key: Key) -> String? {
        let scalar: Int? = switch key {
        case .up: NSUpArrowFunctionKey
        case .down: NSDownArrowFunctionKey
        case .left: NSLeftArrowFunctionKey
        case .right: NSRightArrowFunctionKey
        case .home: NSHomeFunctionKey
        case .end: NSEndFunctionKey
        case .pageUp: NSPageUpFunctionKey
        case .pageDown: NSPageDownFunctionKey
        default: nil
        }
        return scalar.flatMap(UnicodeScalar.init).map { String(Character($0)) }
    }

    /// A key press and release as the window delivers them: key equivalents first (the menus and
    /// the terminal's own chords), then the first responder.
    private func press(
        _ key: Key, _ characters: String = "", modifiers: NSEvent.ModifierFlags = [], in fixture: Fixture
    ) throws {
        let functionKey = Self.functionCharacter(key)
        let shown = functionKey ?? characters
        var flags = modifiers
        if functionKey != nil { flags.formUnion([.function, .numericPad]) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: fixture.window.windowNumber, context: nil, characters: shown,
                charactersIgnoringModifiers: functionKey ?? characters.lowercased(), isARepeat: false, keyCode: key.rawValue))
            if type == .keyDown, fixture.view.performKeyEquivalent(with: event) { continue }
            fixture.window.sendEvent(event)
        }
    }

    private func type(_ text: String, in fixture: Fixture) throws {
        let keys: [Character: Key] = ["a": .a, "s": .s, "l": .l, "c": .c, "u": .u]
        for character in text {
            try press(try #require(keys[character]), String(character), in: fixture)
        }
    }

    @Test func typedLettersAndReturnReachTheProgram() throws {
        let fixture = try makeTerminal()
        try type("ls", in: fixture)
        try press(.returnKey, "\r", in: fixture)
        #expect(fixture.written.text == "ls\r")
    }

    @Test func controlCSendsInterrupt() throws {
        let fixture = try makeTerminal()
        try press(.c, "\u{03}", modifiers: .control, in: fixture)
        #expect(fixture.written.bytes.withLock { $0 } == [0x03])
    }

    @Test func optionAndCommandArrowsMoveByWordAndLine() throws {
        let fixture = try makeTerminal()
        try press(.left, modifiers: .option, in: fixture)
        #expect(fixture.written.bytes.withLock { $0 } == [0x1B, 0x62])
        fixture.written.reset()
        try press(.right, modifiers: .option, in: fixture)
        #expect(fixture.written.bytes.withLock { $0 } == [0x1B, 0x66])
        fixture.written.reset()
        try press(.left, modifiers: .command, in: fixture)
        #expect(fixture.written.bytes.withLock { $0 } == [0x01])
        fixture.written.reset()
        try press(.right, modifiers: .command, in: fixture)
        #expect(fixture.written.bytes.withLock { $0 } == [0x05])
        fixture.written.reset()
        try press(.delete, "\u{7f}", modifiers: .command, in: fixture)
        #expect(fixture.written.bytes.withLock { $0 } == [0x15])
    }

    @Test func arrowsFollowTheCursorKeyMode() throws {
        let fixture = try makeTerminal()
        try press(.up, in: fixture)
        #expect(fixture.written.text == "\u{1b}[A")
        fixture.written.reset()
        fixture.terminal.write(Array("\u{1b}[?1h".utf8))
        try press(.up, in: fixture)
        #expect(fixture.written.text == "\u{1b}OA")
    }

    /// An input method's composition is drawn at the cursor and sends nothing; the committed
    /// text is what reaches the program.
    @Test func composedInputSendsOnlyTheCommittedText() throws {
        let fixture = try makeTerminal()
        fixture.view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(fixture.view.hasMarkedText())
        #expect(fixture.view.surface.preedit?.text == "ni")
        #expect(fixture.written.bytes.withLock { $0 }.isEmpty)
        fixture.view.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!fixture.view.hasMarkedText())
        #expect(fixture.view.surface.preedit == nil)
        #expect(fixture.written.text == "你")
    }

    @Test func typingAfterScrollingBackReturnsToTheBottom() throws {
        let fixture = try makeTerminal()
        fixture.terminal.write(Array((0..<30).map { "line \($0)\r\n" }.joined().utf8))
        fixture.view.surface.scroll(rows: -10)
        #expect(!fixture.terminal.viewportAtBottom)
        try type("a", in: fixture)
        #expect(fixture.terminal.viewportAtBottom)
    }

    // MARK: Scrollback keys

    private func rowsAboveViewport(_ terminal: Terminal) -> Int { terminal.scrollbar.offset }

    /// ⌘Page Up/Down page through the scrollback and ⌘Home/End go to its top and bottom, as in
    /// Ghostty on the Mac; none of them reaches the program.
    @Test func commandPageKeysScrollTheScrollback() throws {
        let fixture = try makeTerminal()
        fixture.terminal.write(Array((0..<60).map { "line \($0)\r\n" }.joined().utf8))
        let bottom = rowsAboveViewport(fixture.terminal)
        let page = fixture.terminal.scrollbar.visible
        #expect(bottom > page * 2)

        try press(.pageUp, modifiers: .command, in: fixture)
        #expect(rowsAboveViewport(fixture.terminal) == bottom - page)
        try press(.pageUp, modifiers: .command, in: fixture)
        #expect(rowsAboveViewport(fixture.terminal) == bottom - 2 * page)
        try press(.pageDown, modifiers: .command, in: fixture)
        #expect(rowsAboveViewport(fixture.terminal) == bottom - page)
        try press(.home, modifiers: .command, in: fixture)
        #expect(rowsAboveViewport(fixture.terminal) == 0)
        try press(.end, modifiers: .command, in: fixture)
        #expect(fixture.terminal.viewportAtBottom)
        #expect(fixture.written.bytes.withLock { $0 }.isEmpty)
    }

    /// Without ⌘ the page keys are the program's (a pager, an editor), as in Ghostty on the Mac.
    @Test func pageKeysWithoutCommandReachTheProgram() throws {
        let fixture = try makeTerminal()
        fixture.terminal.write(Array((0..<60).map { "line \($0)\r\n" }.joined().utf8))
        try press(.pageUp, in: fixture)
        #expect(fixture.written.text == "\u{1b}[5~")
        #expect(fixture.terminal.viewportAtBottom)
    }

    // MARK: Mouse

    private func mouse(
        _ type: NSEvent.EventType, at cell: GridPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = [],
        edge: CGFloat = 0.5, in fixture: Fixture
    ) throws -> NSEvent {
        let rect = fixture.view.surface.rect(for: cell)
        let point = CGPoint(x: rect.minX + rect.width * edge, y: rect.midY)
        return try #require(NSEvent.mouseEvent(
            with: type, location: fixture.view.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: fixture.clock.now, windowNumber: fixture.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    private func click(_ cell: GridPoint, count: Int, modifiers: NSEvent.ModifierFlags = [], in fixture: Fixture) throws {
        fixture.clock.now += 1
        for clicks in 1...count {
            fixture.clock.now += 0.1
            fixture.view.mouseDown(with: try mouse(.leftMouseDown, at: cell, clicks: clicks, modifiers: modifiers, in: fixture))
            fixture.view.mouseUp(with: try mouse(.leftMouseUp, at: cell, clicks: clicks, modifiers: modifiers, in: fixture))
        }
    }

    private func drag(from start: GridPoint, to end: GridPoint, in fixture: Fixture) throws {
        fixture.clock.now += 1
        fixture.view.mouseDown(with: try mouse(.leftMouseDown, at: start, edge: 0.1, in: fixture))
        fixture.view.mouseDragged(with: try mouse(.leftMouseDragged, at: end, edge: 0.9, in: fixture))
        fixture.view.mouseUp(with: try mouse(.leftMouseUp, at: end, edge: 0.9, in: fixture))
    }

    private func copied(_ fixture: Fixture) -> String? {
        let board = NSPasteboard(name: .init("terminal-user-copy-\(UUID())"))
        defer { board.releaseGlobally() }
        guard let text = fixture.terminal.selectionText() else { return nil }
        board.setString(text, forType: .string)
        return board.string(forType: .string)
    }

    @Test func dragAcrossAWrappedRowSelectsOneLine() throws {
        let fixture = try makeTerminal()
        let cols = Int(fixture.terminal.size.cols)
        let long = (0..<(cols + 10)).map { String(UnicodeScalar(UInt8(97 + $0 % 26))) }.joined()
        fixture.terminal.write(Array((long + "\r\nnext").utf8))
        try drag(from: GridPoint(x: 0, y: 0), to: GridPoint(x: 9, y: 1), in: fixture)
        #expect(copied(fixture) == long)
    }

    @Test func doubleClickSelectsAWordAndTripleClickTheLine() throws {
        let fixture = try makeTerminal()
        fixture.terminal.write(Array("git commit --amend\r\n".utf8))
        try click(GridPoint(x: 6, y: 0), count: 2, in: fixture)
        #expect(copied(fixture) == "commit")
        try click(GridPoint(x: 30, y: 2), count: 1, in: fixture)
        try click(GridPoint(x: 6, y: 0), count: 3, in: fixture)
        #expect(copied(fixture) == "git commit --amend")
    }

    /// Clicks on a selection count like any others: a double click on a selected word selects
    /// it again, a triple click selects its line.
    @Test func repeatedClicksOnASelectionKeepCounting() throws {
        let fixture = try makeTerminal()
        fixture.terminal.write(Array("git commit --amend\r\n".utf8))
        try click(GridPoint(x: 6, y: 0), count: 2, in: fixture)
        #expect(copied(fixture) == "commit")
        try click(GridPoint(x: 6, y: 0), count: 2, in: fixture)
        #expect(copied(fixture) == "commit")
        try click(GridPoint(x: 6, y: 0), count: 3, in: fixture)
        #expect(copied(fixture) == "git commit --amend")
    }

    /// A press on the selection keeps it, so a drag can carry its text out.
    @Test func aPressOnTheSelectionKeepsItUntilRelease() throws {
        let fixture = try makeTerminal()
        fixture.terminal.write(Array("one two".utf8))
        try click(GridPoint(x: 0, y: 0), count: 2, in: fixture)
        fixture.clock.now += 1
        fixture.view.mouseDown(with: try mouse(.leftMouseDown, at: GridPoint(x: 1, y: 0), in: fixture))
        #expect(fixture.terminal.selectionText() == "one")
        fixture.view.mouseUp(with: try mouse(.leftMouseUp, at: GridPoint(x: 1, y: 0), in: fixture))
        #expect(fixture.terminal.selection == nil)
    }

    @Test func shiftClickExtendsTheSelection() throws {
        let fixture = try makeTerminal()
        fixture.terminal.write(Array("one two three".utf8))
        try click(GridPoint(x: 0, y: 0), count: 2, in: fixture)
        #expect(copied(fixture) == "one")
        try click(GridPoint(x: 8, y: 0), count: 1, modifiers: .shift, in: fixture)
        #expect(copied(fixture)?.hasPrefix("one two t") == true)
    }

    @Test func aClickClearsTheSelection() throws {
        let fixture = try makeTerminal()
        fixture.terminal.write(Array("one two".utf8))
        try click(GridPoint(x: 0, y: 0), count: 2, in: fixture)
        #expect(fixture.terminal.selection != nil)
        try click(GridPoint(x: 1, y: 0), count: 1, in: fixture)
        #expect(fixture.terminal.selection == nil)
    }

    /// A drag that starts in the scrollback and ends on the screen copies every row between.
    @Test func dragFromScrollbackIntoTheScreenCopiesEveryRow() throws {
        let fixture = try makeTerminal()
        fixture.terminal.write(Array((0..<20).map { "row \($0)" }.joined(separator: "\r\n").utf8))
        let rows = fixture.terminal.scrollbar.visible
        fixture.view.surface.scroll(rows: -3)
        fixture.view.mouseDown(with: try mouse(.leftMouseDown, at: GridPoint(x: 0, y: 0), edge: 0.1, in: fixture))
        fixture.view.surface.scroll(rows: 3)
        fixture.view.mouseDragged(with: try mouse(.leftMouseDragged, at: GridPoint(x: 5, y: rows - 1), edge: 0.9, in: fixture))
        fixture.view.mouseUp(with: try mouse(.leftMouseUp, at: GridPoint(x: 5, y: rows - 1), edge: 0.9, in: fixture))
        let first = 20 - rows - 3
        #expect(copied(fixture) == (first..<20).map { "row \($0)" }.joined(separator: "\n"))
    }

    @Test func typingClearsTheSelection() throws {
        let fixture = try makeTerminal()
        fixture.terminal.write(Array("one two".utf8))
        try click(GridPoint(x: 0, y: 0), count: 2, in: fixture)
        #expect(fixture.terminal.selection != nil)
        try type("a", in: fixture)
        #expect(fixture.terminal.selection == nil)
        #expect(fixture.written.text == "a")
    }

    // MARK: Wheel

    private func wheel(lines: Int32, in fixture: Fixture) throws {
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        fixture.view.scrollWheel(with: event)
    }

    @Test func theWheelScrollsTheScrollbackThreeRowsALine() throws {
        let fixture = try makeTerminal()
        fixture.terminal.write(Array((0..<60).map { "line \($0)\r\n" }.joined().utf8))
        let bottom = rowsAboveViewport(fixture.terminal)
        try wheel(lines: 1, in: fixture)
        #expect(rowsAboveViewport(fixture.terminal) == bottom - 3)
        try wheel(lines: -1, in: fixture)
        #expect(fixture.terminal.viewportAtBottom)
        #expect(fixture.written.bytes.withLock { $0 }.isEmpty)
    }

    @Test func theWheelOnAFullScreenProgramSendsArrows() throws {
        let fixture = try makeTerminal()
        fixture.terminal.write(Array("\u{1b}[?1049h".utf8))
        try wheel(lines: 1, in: fixture)
        #expect(fixture.written.text == "\u{1b}[A\u{1b}[A\u{1b}[A")
    }
}
#endif
