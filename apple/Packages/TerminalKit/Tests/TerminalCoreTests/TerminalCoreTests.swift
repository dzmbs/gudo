import Synchronization
import Testing
@testable import TerminalCore

private func rows(_ state: RenderState) -> [(id: RowID, dirty: Bool)] {
    var out: [(RowID, Bool)] = []
    state.forEachRow { out.append(($0.id, $0.isDirty)) }
    return out
}

private func text(_ state: RenderState, row y: Int) -> String {
    var lines: [String] = []
    state.forEachRow { row in
        var line = ""
        row.forEachCell { cell in
            line.unicodeScalars.append(Unicode.Scalar(cell.codepoint).map { $0 == "\0" ? " " : $0 } ?? " ")
        }
        lines.append(line)
    }
    return lines[y]
}

@Test func typingDirtiesOnlyTheCursorRow() {
    let terminal = Terminal(cols: 20, rows: 5) { _ in }
    let state = RenderState()
    terminal.write(Array("a\r\nb\r\nc".utf8))
    state.update(from: terminal)
    #expect(state.dirty == .full)
    state.markClean()

    terminal.write(Array("d".utf8))
    state.update(from: terminal)
    #expect(state.dirty == .partial)
    #expect(rows(state).map(\.dirty) == [false, false, true, false, false])
    #expect(text(state, row: 2).hasPrefix("cd"))
}

/// Documents current libghostty-vt behaviour the renderer's cache has to live with: when output
/// scrolls the screen, row ids follow the rows, but every row is reported dirty.
@Test func scrollingKeepsRowIdsButMarksAllRowsDirty() {
    let terminal = Terminal(cols: 20, rows: 3) { _ in }
    let state = RenderState()
    terminal.write(Array("1\r\n2\r\n3".utf8))
    state.update(from: terminal)
    let before = rows(state).map(\.id)
    state.markClean()

    terminal.write(Array("\r\n4".utf8))
    state.update(from: terminal)
    let after = rows(state)
    #expect(after.map(\.id).prefix(2) == before.suffix(2))
    #expect(after.allSatisfy { $0.dirty })
}

@Test func encodesKeysWithTerminalModes() {
    let terminal = Terminal(cols: 80, rows: 24) { _ in }
    let ctrlC = KeyEvent(key: PhysicalKey(macKeyCode: 0x08)!, action: .press, mods: .control, text: "c", unshiftedCodepoint: 0x63)
    #expect(terminal.encode(ctrlC) == [0x03])

    let up = KeyEvent(key: PhysicalKey(hidUsage: 0x52)!, action: .press, mods: [], text: "", unshiftedCodepoint: 0)
    #expect(terminal.encode(up) == Array("\u{1b}[A".utf8))
    terminal.write(Array("\u{1b}[?1h".utf8))  // DECCKM: application cursor keys
    #expect(terminal.encode(up) == Array("\u{1b}OA".utf8))

    let a = KeyEvent(key: PhysicalKey(macKeyCode: 0x00)!, action: .press, mods: [], text: "a", unshiftedCodepoint: 0x61)
    #expect(terminal.encode(a) == Array("a".utf8))
}

@Test func encodesSoftKeyboardInputLikeHardwareChords() {
    let terminal = Terminal(cols: 80, rows: 24) { _ in }
    #expect(terminal.encode(.typing("c", mods: .control)) == [0x03])
    #expect(terminal.encode(.typing("~")) == Array("~".utf8))
    #expect(terminal.encode(.typing("|")) == Array("|".utf8))
    #expect(terminal.encode(.typing("é")) == Array("é".utf8))
    #expect(terminal.encode(.press(.escape)) == [0x1B])
    #expect(terminal.encode(.press(.enter)) == [0x0D])
    #expect(terminal.encode(.press(.arrowLeft, mods: .control)) == Array("\u{1b}[1;5D".utf8))
}

@Test func repliesToQueriesThroughWritePty() {
    let replies = Mutex<[UInt8]>([])
    let terminal = Terminal(cols: 80, rows: 24) { bytes in replies.withLock { $0 += bytes } }
    terminal.write(Array("\u{1b}[5n".utf8))  // DSR: device status
    #expect(replies.withLock { $0 } == Array("\u{1b}[0n".utf8))
}

@Test func graphemeClustersShareOneCell() {
    let terminal = Terminal(cols: 10, rows: 1) { _ in }
    let state = RenderState()
    terminal.write(Array("👍🏽x".utf8))
    state.update(from: terminal)
    var cells: [(count: Int, width: Cell.Width)] = []
    state.forEachRow { $0.forEachCell { cells.append(($0.graphemeCount, $0.width)) } }
    #expect(cells[0].count == 2 && cells[0].width == .wide)
    #expect(cells[1].width == .spacerTail)
    #expect(cells[2].count == 1)
}

@Test func visibleTextJoinsWideCharacters() {
    let terminal = Terminal(cols: 20, rows: 3) { _ in }
    terminal.write(Array("你好 😀🚀 ok".utf8))
    #expect(terminal.visibleText() == "你好 😀🚀 ok")
}
