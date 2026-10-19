import Testing
@testable import TerminalCore

private func lines(_ n: Int, from start: Int = 0) -> [UInt8] {
    Array((start..<start + n).map { "line \($0)\r\n" }.joined().utf8)
}

/// A pinned row follows its text as output scrolls it into scrollback.
@Test func pinFollowsRowThroughScrolling() throws {
    let terminal = Terminal(cols: 20, rows: 5) { _ in }
    terminal.write(lines(6))
    // The screen scrolls from here on: "line 3" is on viewport row 1.
    let pin = try #require(terminal.pinRow(viewportRow: 1))
    #expect(terminal.viewportRows(of: [pin]) == [1])
    let before = try #require(terminal.fromBottom(of: pin))

    terminal.write(lines(10, from: 6))
    // 10 more lines: the row is 10 further from the bottom and above the viewport.
    #expect(terminal.fromBottom(of: pin) == before + 10)
    let row = try #require(terminal.viewportRows(of: [pin]).first ?? nil)
    #expect(row < 0)
    // Scrolling the viewport up by -row brings it back to the top row.
    terminal.scrollViewport(by: row)
    #expect(terminal.viewportRows(of: [pin]) == [0])
    #expect(terminal.text(atViewport: 0).hasPrefix("line 3"))
}

/// `pinRow(fromBottom:)` names the same row the daemon's anchors do.
@Test func pinFromBottomMatchesAnchorConvention() throws {
    let terminal = Terminal(cols: 20, rows: 5) { _ in }
    terminal.write(lines(8))
    // Bottom row is the empty line after "line 7"; one above it is "line 7".
    let pin = try #require(terminal.pinRow(fromBottom: 1))
    #expect(terminal.fromBottom(of: pin) == 1)
    #expect(terminal.viewportRows(of: [pin]) == [3])
    #expect(terminal.text(atViewport: 3).hasPrefix("line 7"))
}

/// A row pruned from a full scrollback leaves its pin without a value.
@Test func pinLosesValueWhenRowIsPruned() throws {
    var config = Terminal.Configuration()
    config.scrollbackBytes = 1
    let terminal = Terminal(cols: 20, rows: 3, configuration: config) { _ in }
    terminal.write(lines(2))
    let pin = try #require(terminal.pinRow(viewportRow: 0))
    terminal.write(lines(5000, from: 2))
    #expect(terminal.screenRow(of: pin) == nil)
}

extension Terminal {
    fileprivate func text(atViewport row: Int) -> String {
        visibleText().split(separator: "\n", omittingEmptySubsequences: false).dropFirst(row).first.map(String.init) ?? ""
    }
}
