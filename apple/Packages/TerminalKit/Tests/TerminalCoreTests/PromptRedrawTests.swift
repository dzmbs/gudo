import Testing
import TerminalCore

private let esc = "\u{1b}"

/// zsh's prompt with a right prompt, as the integration draws it at `cols` columns.
private func prompt(cols: Int) -> [UInt8] {
    let rightPrompt = "ok 19:42"
    let gap = cols - 3 - rightPrompt.count - 1
    return Array("\r\(esc)[J\(esc)]133;A;cl=line\u{07}P> \(esc)]133;B\u{07}\(esc)[K\(esc)[\(gap)C\(rightPrompt)\(esc)[\(gap + rightPrompt.count)D".utf8)
}

private func promptLine(cols: Int) -> String {
    "P>" + String(repeating: " ", count: cols - 2 - 8 - 1) + "ok 19:42"
}

private func lines(_ terminal: Terminal) -> [String] {
    terminal.visibleText()
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// Ghostty's zsh integration marks prompts with OSC 133 and relies on the terminal clearing the
/// prompt on resize, because zsh redraws it at the new size (a split resizes the pane).
@Test func resizeLeavesOnlyThePromptTheShellRedraws() {
    let terminal = Terminal(cols: 100, rows: 10) { _ in }
    terminal.write(prompt(cols: 100))
    terminal.resize(cols: 50, rows: 10, cellWidth: 8, cellHeight: 16)
    #expect(lines(terminal).isEmpty)
    terminal.write(prompt(cols: 50))
    #expect(lines(terminal) == [promptLine(cols: 50)])
}

@Test func restoredTerminalKeepsTheShellsOwnRedrawSetting() throws {
    let daemon = Terminal(cols: 40, rows: 4) { _ in }
    daemon.write(Array("\(esc)]133;A;redraw=0\u{07}P> \(esc)]133;B\u{07}".utf8))
    let snapshot = try #require(daemon.encodeSnapshot())
    let client = Terminal(cols: 40, rows: 4) { _ in }
    try client.restore(snapshot: snapshot)
    client.resize(cols: 30, rows: 4, cellWidth: 8, cellHeight: 16)
    #expect(lines(client) == ["P>"])
}
