import Synchronization
import Testing
@testable import TerminalCore

/// Collects what the terminal writes back to the PTY.
private final class PtySink: Sendable {
    let bytes = Mutex<[UInt8]>([])
    var string: String { String(decoding: bytes.withLock { $0 }, as: UTF8.self) }
    func take() -> String {
        let out = string
        bytes.withLock { $0.removeAll() }
        return out
    }
}

private func makeTerminal(cols: UInt16 = 20, rows: UInt16 = 5) -> (Terminal, PtySink) {
    let sink = PtySink()
    let terminal = Terminal(cols: cols, rows: rows) { data in sink.bytes.withLock { $0 += Array(data) } }
    return (terminal, sink)
}

private let geometry = MouseGeometry(screenWidth: 200, screenHeight: 100, cellWidth: 10, cellHeight: 20)

// MARK: Events, title, pwd

@Test func reportsTitlePwdBellAndPromptMarks() {
    let (terminal, _) = makeTerminal()
    let log = Mutex<[String]>([])
    var events = Terminal.Events()
    events.titleChanged = { log.withLock { $0.append("title") } }
    events.pwdChanged = { log.withLock { $0.append("pwd") } }
    events.bell = { log.withLock { $0.append("bell") } }
    events.semanticPrompt = { step in log.withLock { $0.append("\(step)") } }
    terminal.setEvents(events)

    terminal.write(Array("\u{1b}]2;vim main.swift\u{07}".utf8))
    terminal.write(Array("\u{1b}]7;file://host/Users/me/src\u{1b}\\".utf8))
    terminal.write([0x07])
    terminal.write(Array("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ls\r\n\u{1b}]133;C\u{07}out\r\n\u{1b}]133;D;0\u{07}".utf8))

    #expect(terminal.title == "vim main.swift")
    #expect(terminal.pwd.hasSuffix("/Users/me/src"))
    let entries = log.withLock { $0 }
    #expect(entries.prefix(3) == ["title", "pwd", "bell"])
    #expect(entries.contains("promptStart"))
    #expect(entries.contains("inputStart"))
    #expect(entries.contains("outputStart"))
    #expect(entries.contains("commandEnd(exitCode: Optional(0))"))
}

@Test func cursorAtPromptFollowsOsc133() {
    let (terminal, _) = makeTerminal()
    #expect(!terminal.cursorAtPrompt)
    terminal.write(Array("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}".utf8))
    #expect(terminal.cursorAtPrompt)
    terminal.write(Array("ls\r\n\u{1b}]133;C\u{07}".utf8))
    #expect(!terminal.cursorAtPrompt)
}

@Test func readsModesAndCells() {
    let (terminal, _) = makeTerminal()
    let defaults = terminal.modes
    #expect(!defaults.altScreen && !defaults.mouseTracking && !defaults.bracketedPaste && !defaults.focusEvents)
    #expect(defaults.alternateScroll)  // on by default, as in Ghostty
    terminal.write(Array("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?1004h\u{1b}[?1007h".utf8))
    let modes = terminal.modes
    #expect(modes.altScreen && modes.mouseTracking && modes.bracketedPaste && modes.focusEvents && modes.alternateScroll)
    #expect(!AlternateScroll.applies(modes))  // mouse tracking wins
    terminal.write(Array("\u{1b}[?1000l".utf8))
    #expect(AlternateScroll.applies(terminal.modes))

    terminal.write(Array("ab界".utf8))
    #expect(terminal.text(atActive: GridPoint(x: 1, y: 0)) == "b")
    #expect(terminal.text(atActive: GridPoint(x: 2, y: 0)) == "界")
    #expect(terminal.cursorPosition == GridPoint(x: 4, y: 0))
}

// MARK: Mouse

@Test func mouseEncodesNothingWithoutTracking() {
    let (terminal, _) = makeTerminal()
    let bytes = terminal.encodeMouse(.init(action: .press, button: .left, x: 5, y: 5), geometry: geometry, anyButtonPressed: true)
    #expect(bytes.isEmpty)
}

@Test func mouseEncodesSgrPressDragReleaseAndWheel() {
    let (terminal, _) = makeTerminal()
    terminal.write(Array("\u{1b}[?1002h\u{1b}[?1006h".utf8))
    func encode(_ e: MouseEvent, pressed: Bool) -> String {
        String(decoding: terminal.encodeMouse(e, geometry: geometry, anyButtonPressed: pressed), as: UTF8.self)
    }
    // Cell (3, 1): x in 30..<40, y in 20..<40. SGR is 1-based.
    #expect(encode(.init(action: .press, button: .left, x: 35, y: 25), pressed: true) == "\u{1b}[<0;4;2M")
    #expect(encode(.init(action: .motion, button: .left, x: 55, y: 25), pressed: true) == "\u{1b}[<32;6;2M")
    // Same cell again: deduplicated.
    #expect(encode(.init(action: .motion, button: .left, x: 56, y: 26), pressed: true) == "")
    #expect(encode(.init(action: .release, button: .left, x: 55, y: 25), pressed: false) == "\u{1b}[<0;6;2m")
    #expect(encode(.init(action: .press, button: .wheelUp, x: 5, y: 5), pressed: false) == "\u{1b}[<64;1;1M")
    #expect(encode(.init(action: .press, button: .wheelDown, x: 5, y: 5), pressed: false) == "\u{1b}[<65;1;1M")
    // Shift is reported in the button byte (+4) when the app gets the event.
    #expect(encode(.init(action: .press, button: .right, mods: .control, x: 5, y: 5), pressed: true) == "\u{1b}[<18;1;1M")
}

@Test func mouseMotionWithoutButtonOnlyInAnyEventMode() {
    let (terminal, _) = makeTerminal()
    terminal.write(Array("\u{1b}[?1002h\u{1b}[?1006h".utf8))
    #expect(terminal.encodeMouse(.init(action: .motion, button: nil, x: 15, y: 5), geometry: geometry, anyButtonPressed: false).isEmpty)
    terminal.write(Array("\u{1b}[?1003h".utf8))
    let hover = terminal.encodeMouse(.init(action: .motion, button: nil, x: 15, y: 5), geometry: geometry, anyButtonPressed: false)
    #expect(String(decoding: hover, as: UTF8.self) == "\u{1b}[<35;2;1M")
}

// MARK: Focus

@Test func focusReportsOnlyWhenRequested() {
    let (terminal, _) = makeTerminal()
    #expect(terminal.encodeFocus(true).isEmpty)
    terminal.write(Array("\u{1b}[?1004h".utf8))
    #expect(terminal.encodeFocus(true) == Array("\u{1b}[I".utf8))
    #expect(terminal.encodeFocus(false) == Array("\u{1b}[O".utf8))
}

// MARK: Paste

@Test func pasteIsBracketedWhenTheAppAsks() {
    let (terminal, sink) = makeTerminal()
    terminal.write(Array("\u{1b}[?2004h".utf8))
    #expect(terminal.paste("echo a\necho b") == .written)
    #expect(sink.take() == "\u{1b}[200~echo a\necho b\u{1b}[201~")
}

@Test func unbracketedMultilinePasteNeedsConfirmation() {
    let (terminal, sink) = makeTerminal()
    #expect(terminal.paste("rm -rf build\n") == .needsConfirmation)
    #expect(sink.take() == "")
    #expect(terminal.paste("rm -rf build\n", allowUnsafe: true) == .written)
    #expect(sink.take() == "rm -rf build\r")
    #expect(terminal.paste("one line") == .written)
    #expect(sink.take() == "one line")
    #expect(terminal.paste("") == .empty)
}

/// A paste the size of a log file is refused before anything is copied or framed: framing
/// 200 MB took over a second on the caller's (main) thread and doubled its memory.
@Test func pasteOverTheLimitIsRefusedAtOnce() {
    let (terminal, sink) = makeTerminal()
    terminal.write(Array("\u{1b}[?2004h".utf8))
    let line = String(repeating: "x", count: 1023) + "\n"
    let atLimit = String(repeating: line, count: Terminal.maxPasteBytes / 1024)
    #expect(terminal.paste(atLimit) == .written)
    #expect(sink.take().utf8.count == Terminal.maxPasteBytes + 12, "the limit itself still pastes, bracketed")

    let huge = String(repeating: line, count: 8 * Terminal.maxPasteBytes / 1024)
    let start = ContinuousClock.now
    #expect(terminal.paste(huge) == .tooLarge)
    #expect(terminal.paste(huge, source: .text, allowUnsafe: true) == .tooLarge)
    #expect(ContinuousClock.now - start < .milliseconds(50))
    #expect(sink.take().isEmpty)
}

/// The confirmation's line count: one pass, no array of lines (splitting 50 MB took seconds).
@Test func pasteLineCount() {
    #expect(Terminal.pasteLineCount("") == 0)
    #expect(Terminal.pasteLineCount("one") == 1)
    #expect(Terminal.pasteLineCount("one\n") == 1)
    #expect(Terminal.pasteLineCount("one\ntwo") == 2)
    #expect(Terminal.pasteLineCount("one\r\ntwo\r\n") == 2)
    #expect(Terminal.pasteLineCount("a\rb\n\nc") == 4)
    let big = String(repeating: "echo hi\n", count: 2_000_000)
    let start = ContinuousClock.now
    #expect(Terminal.pasteLineCount(big) == 2_000_000)
    #expect(ContinuousClock.now - start < .milliseconds(500))
}

@Test func pasteStripsControlBytesAndRefusesTerminatorInjection() {
    let (terminal, sink) = makeTerminal()
    terminal.write(Array("\u{1b}[?2004h".utf8))
    #expect(terminal.paste("a\u{1b}[201~b") == .needsConfirmation)
    #expect(terminal.paste("x\u{1b}y") == .written)
    #expect(sink.take() == "\u{1b}[200~x y\u{1b}[201~")
    #expect(Terminal.isSafePaste("plain"))
    #expect(!Terminal.isSafePaste("two\nlines"))
}

// MARK: Selection

@Test func selectsWordAndLineAndCopiesText() {
    let (terminal, _) = makeTerminal(cols: 20, rows: 4)
    terminal.write(Array("hello world\r\nsecond line".utf8))
    let word = terminal.selectWord(atViewport: GridPoint(x: 7, y: 0))
    #expect(word?.start == GridPoint(x: 6, y: 0))
    #expect(word?.end == GridPoint(x: 10, y: 0))
    #expect(terminal.selectionText() == "world")

    terminal.selectLine(atViewport: GridPoint(x: 2, y: 1))
    #expect(terminal.selectionText() == "second line")

    terminal.clearSelection()
    #expect(terminal.selection == nil)
    #expect(terminal.selectionText() == nil)
}

@Test func copyJoinsSoftWrappedRows() {
    let (terminal, _) = makeTerminal(cols: 10, rows: 4)
    terminal.write(Array("0123456789abcdef\r\nnext".utf8))  // wraps after 10 columns
    terminal.setSelection(Selection(anchor: GridPoint(x: 0, y: 0), head: GridPoint(x: 3, y: 2)))
    #expect(terminal.selectionText() == "0123456789abcdef\nnext")
}

@Test func rectangleSelectionCopiesColumns() {
    let (terminal, _) = makeTerminal(cols: 10, rows: 4)
    terminal.write(Array("abcdef\r\nghijkl\r\nmnopqr".utf8))
    terminal.setSelection(Selection(anchor: GridPoint(x: 1, y: 0), head: GridPoint(x: 3, y: 2), rectangle: true))
    #expect(terminal.selectionText() == "bcd\nhij\nnop")
}

@Test func selectionSurvivesScrollingAndOutput() throws {
    let (terminal, _) = makeTerminal(cols: 10, rows: 3)
    terminal.write(Array("keep\r\n".utf8))
    let word = try #require(terminal.selectWord(atViewport: GridPoint(x: 1, y: 0)))
    // Push "keep" into scrollback.
    for i in 0..<5 { terminal.write(Array("line\(i)\r\n".utf8)) }
    let moved = try #require(terminal.selection)
    #expect(moved == word)  // screen coordinates do not move with output
    #expect(terminal.selectionText() == "keep")
    #expect(terminal.viewportPoint(fromScreen: moved.start) == nil)  // scrolled out of view
    terminal.scrollViewport(by: -10)
    #expect(terminal.viewportPoint(fromScreen: moved.start) == GridPoint(x: 0, y: 0))
    #expect(terminal.screenPoint(fromViewport: GridPoint(x: 0, y: 0)) == moved.start)
}

@Test func handleDragKeepsTheOtherEnd() {
    let (terminal, _) = makeTerminal(cols: 20, rows: 3)
    terminal.write(Array("one two three four".utf8))
    let word = terminal.selectWord(atViewport: GridPoint(x: 5, y: 0))!  // "two"
    // Drag the end handle to "three"'s last cell.
    terminal.setSelection(Selection(anchor: word.start, head: GridPoint(x: 12, y: 0)))
    #expect(terminal.selectionText() == "two three")
    // Drag the start handle past the end: ends swap in reading order.
    terminal.setSelection(Selection(anchor: GridPoint(x: 17, y: 0), head: GridPoint(x: 12, y: 0)))
    #expect(terminal.selectionText() == "e four")
}

@Test func gestureDoubleAndTripleClickSelectWordAndLine() {
    let (terminal, _) = makeTerminal(cols: 20, rows: 3)
    terminal.write(Array("alpha beta gamma".utf8))
    let gesture = SelectionGesture(terminal: terminal)
    let cell = GridPoint(x: 7, y: 0)
    #expect(gesture.press(cell: cell, x: 75, y: 5, time: 1.0) == nil)
    gesture.release(cell: cell)
    _ = gesture.press(cell: cell, x: 75, y: 5, time: 1.1)
    #expect(terminal.selectionText() == "beta")
    gesture.release(cell: cell)
    _ = gesture.press(cell: cell, x: 75, y: 5, time: 1.2)
    #expect(terminal.selectionText() == "alpha beta gamma")
    #expect(gesture.clickCount == 3)
}

@Test func gestureDragSelectsCellsAndSlowClicksDoNotRepeat() {
    let (terminal, _) = makeTerminal(cols: 20, rows: 3)
    terminal.write(Array("alpha beta gamma".utf8))
    let gesture = SelectionGesture(terminal: terminal)
    let geo = SelectionGesture.Geometry(columns: 20, cellWidth: 10, paddingLeft: 0, screenHeight: 60)
    _ = gesture.press(cell: GridPoint(x: 0, y: 0), x: 1, y: 5, time: 1)
    _ = gesture.drag(cell: GridPoint(x: 4, y: 0), x: 46, y: 5, rectangle: false, geometry: geo)
    #expect(terminal.selectionText() == "alpha")
    #expect(gesture.dragged)
    gesture.release(cell: GridPoint(x: 4, y: 0))
    // Far apart in time: a new single click, not a double click.
    _ = gesture.press(cell: GridPoint(x: 7, y: 0), x: 75, y: 5, time: 5)
    #expect(gesture.clickCount == 1)
}

@Test func gestureDragWithPaddingSelectsTheCellsUnderThePointer() {
    let (terminal, _) = makeTerminal(cols: 20, rows: 3)
    terminal.write(Array("    alpha beta".utf8))
    let gesture = SelectionGesture(terminal: terminal)
    // 8 px of left padding: cell n spans 8 + 16n ..< 8 + 16(n + 1).
    let geo = SelectionGesture.Geometry(columns: 20, cellWidth: 16, paddingLeft: 8, screenHeight: 60)
    _ = gesture.press(cell: GridPoint(x: 4, y: 0), x: 8 + 4 * 16 + 1, y: 5, time: 1)
    _ = gesture.drag(cell: GridPoint(x: 8, y: 0), x: 8 + 9 * 16 - 1, y: 5, rectangle: false, geometry: geo)
    #expect(terminal.selectionText() == "alpha")
}

@Test func gestureAutoscrollRequestedWhenDraggingAboveTheView() {
    let (terminal, _) = makeTerminal(cols: 10, rows: 3)
    for i in 0..<10 { terminal.write(Array("row\(i)\r\n".utf8)) }
    let gesture = SelectionGesture(terminal: terminal)
    let geo = SelectionGesture.Geometry(columns: 10, cellWidth: 10, paddingLeft: 0, screenHeight: 60)
    _ = gesture.press(cell: GridPoint(x: 0, y: 1), x: 1, y: 25, time: 1)
    _ = gesture.drag(cell: GridPoint(x: 0, y: 0), x: 1, y: -10, rectangle: false, geometry: geo)
    #expect(gesture.autoscroll == .up)
    terminal.scrollViewport(by: -1)
    let extended = gesture.autoscrollTick(cell: GridPoint(x: 0, y: 0), x: 1, y: -10, rectangle: false, geometry: geo)
    #expect(extended != nil)
    #expect(terminal.selectionText()?.hasPrefix("row") == true)
}

@Test func hyperlinkUnderCell() {
    let (terminal, _) = makeTerminal()
    terminal.write(Array("\u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\ plain".utf8))
    #expect(terminal.hyperlink(atViewport: GridPoint(x: 1, y: 0)) == "https://example.com")
    #expect(terminal.hyperlink(atViewport: GridPoint(x: 6, y: 0)) == nil)
}
