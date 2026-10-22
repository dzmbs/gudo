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

/// macOS `top`, byte for byte as captured from a PTY: it enters the alternate screen at once,
/// then writes its first frame only after sampling every process, which can take seconds. The
/// pane is legitimately blank in between; the frame must reach both the text and the renderer.
@Test func fullScreenAppFirstFrameAfterAlternateScreenSwitch() {
    let terminal = Terminal(cols: 40, rows: 6) { _ in }
    let state = RenderState()
    terminal.write(Array("% top -s 1\r\n".utf8))
    state.update(from: terminal)
    state.markClean()

    terminal.write(Array("\u{1b}[?1049h\u{1b}[1;6r\u{1b}(B\u{1b}[m\u{1b}[4l\u{1b}[?7h\u{1b}[?1h\u{1b}=".utf8))
    #expect(terminal.modes.altScreen)
    state.update(from: terminal)
    #expect(state.dirty == .full)
    #expect((0..<6).allSatisfy { text(state, row: $0).trimmingCharacters(in: .whitespaces).isEmpty })
    state.markClean()

    terminal.write(Array("\u{1b}[H\u{1b}[2JProcesses: 612 total, 3 running\r\nLoad Avg: 2.10".utf8))
    state.update(from: terminal)
    #expect(state.dirty != .clean)
    #expect(text(state, row: 0).hasPrefix("Processes: 612 total"))
    #expect(text(state, row: 1).hasPrefix("Load Avg: 2.10"))
    #expect(terminal.visibleText().contains("Processes:"))

    terminal.write(Array("\u{1b}[?1049l".utf8))
    #expect(!terminal.modes.altScreen)
    #expect(terminal.visibleText().hasPrefix("% top -s 1"))
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

/// A theme change reaches a running terminal: new default colors and a full redraw; a nil
/// palette goes back to the built-in one.
@Test func setDefaultsRecolorsARunningTerminal() {
    var themed = Terminal.Configuration()
    themed.palette = (0..<256).map { RGB(r: UInt8($0), g: 0, b: 0) }
    let terminal = Terminal(cols: 20, rows: 3, configuration: themed) { _ in }
    let state = RenderState()
    terminal.write(Array("text".utf8))
    state.update(from: terminal)
    state.markClean()
    let builtIn = RenderState()
    builtIn.update(from: Terminal(cols: 20, rows: 3) { _ in })

    var light = Terminal.Configuration()
    light.background = RGB(r: 0xFF, g: 0xFF, b: 0xFF)
    light.foreground = RGB(r: 0, g: 0, b: 0)
    terminal.setDefaults(light)
    state.update(from: terminal)
    #expect(state.dirty == .full)
    #expect(state.colors.background == light.background)
    #expect(state.colors.foreground == light.foreground)
    #expect(state.colors.palette == builtIn.colors.palette)
}
