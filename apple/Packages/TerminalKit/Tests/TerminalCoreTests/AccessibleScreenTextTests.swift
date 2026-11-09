import Foundation
import Testing
@testable import TerminalCore

/// The viewport as text for assistive technologies: lines, UTF-16 offsets and the cells they
/// map to.
@Suite struct AccessibleScreenTextTests {
    private func screen(cols: UInt16 = 10, rows: UInt16 = 4, _ output: String) -> (Terminal, AccessibleScreenText) {
        let terminal = Terminal(cols: cols, rows: rows) { _ in }
        terminal.write(Array(output.utf8))
        return (terminal, terminal.accessibleScreenText())
    }

    @Test func rowsAreLinesWithTrailingBlanksTrimmed() {
        let (_, text) = screen("ab  \r\ncd")
        #expect(text.string == "ab\ncd")
        #expect(text.length == 5)
        #expect(text.lineCount == 2)
        #expect(text.range(forLine: 0) == 0..<3)
        #expect(text.range(forLine: 1) == 3..<5)
        #expect(text.range(forLine: 2) == nil)
        #expect(text.line(forOffset: 0) == 0)
        #expect(text.line(forOffset: 2) == 0)
        #expect(text.line(forOffset: 3) == 1)
        #expect(text.line(forOffset: 5) == 1)
        #expect(text.substring(in: 1..<4) == "b\nc")
    }

    @Test func softWrappedRowsJoinWithoutALineBreak() {
        let (_, text) = screen(cols: 5, "abcdefg\r\nh")
        #expect(text.string == "abcdefg\nh")
        #expect(text.lineCount == 3)
        #expect(text.range(forLine: 0) == 0..<5)
        #expect(text.range(forLine: 1) == 5..<8)
        #expect(text.line(forOffset: 5) == 1)
        #expect(text.offset(of: GridPoint(x: 0, y: 1)) == 5)
        #expect(text.cell(atOffset: 5) == GridPoint(x: 0, y: 1))
    }

    @Test func wideCharactersTakeTwoCellsAndTheirUTF16Length() {
        let (_, text) = screen("你😀a")
        #expect(text.string == "你😀a")
        #expect(text.length == 4)
        #expect(text.offset(of: GridPoint(x: 1, y: 0)) == 0)
        #expect(text.offset(of: GridPoint(x: 2, y: 0)) == 1)
        #expect(text.offset(of: GridPoint(x: 3, y: 0)) == 1)
        #expect(text.offset(of: GridPoint(x: 4, y: 0)) == 3)
        #expect(text.cell(atOffset: 1) == GridPoint(x: 2, y: 0))
        #expect(text.cell(atOffset: 3) == GridPoint(x: 4, y: 0))
        #expect(text.spans(for: 1..<3) == [AccessibleScreenText.CellSpan(row: 0, columns: 2..<4)])
    }

    @Test func graphemeClusterIsOneCharacter() {
        let (_, text) = screen("👍🏽x")
        #expect(text.string == "👍🏽x")
        #expect(text.offset(of: GridPoint(x: 1, y: 0)) == 0)
        #expect(text.offset(of: GridPoint(x: 2, y: 0)) == 4)
        #expect(text.cell(atOffset: 2) == GridPoint(x: 0, y: 0))
    }

    @Test func wideCharacterThatWrapsLeavesNoGap() {
        let (_, text) = screen(cols: 5, "abcd你")
        #expect(text.string == "abcd你")
        #expect(text.line(forOffset: 4) == 1)
        #expect(text.cell(atOffset: 4) == GridPoint(x: 0, y: 1))
    }

    @Test func selectionSpanningRowsIsItsText() throws {
        let (terminal, text) = screen("one\r\ntwo\r\nthree")
        let selection = Selection(anchor: GridPoint(x: 1, y: 0), head: GridPoint(x: 2, y: 2))
        let range = try #require(text.range(of: selection, viewportTop: 0))
        terminal.setSelection(selection)
        #expect(text.substring(in: range) == terminal.selectionText())
        #expect(text.substring(in: range) == "ne\ntwo\nthr")
        #expect(text.selection(for: range, viewportTop: 0) == selection)
        #expect(text.spans(for: range).map(\.row) == [0, 1, 2])
    }

    @Test func selectionOutsideTheViewportIsClipped() throws {
        let (_, text) = screen("one\r\ntwo")
        let fromAbove = Selection(anchor: GridPoint(x: 2, y: 3), head: GridPoint(x: 1, y: 6))
        #expect(text.range(of: fromAbove, viewportTop: 5) == 0..<6)
        let above = Selection(anchor: GridPoint(x: 0, y: 0), head: GridPoint(x: 2, y: 1))
        #expect(text.range(of: above, viewportTop: 5) == nil)
        let below = Selection(anchor: GridPoint(x: 0, y: 1), head: GridPoint(x: 0, y: 9))
        #expect(text.range(of: below, viewportTop: 0) == 4..<7)
    }

    @Test func cursorAtTheEndOfALineKeepsTheBlanksBeforeIt() throws {
        let (terminal, text) = screen("$ ")
        let cursor = try #require(terminal.viewportPoint(fromActive: terminal.cursorPosition))
        #expect(text.string == "$ ")
        #expect(text.offset(of: cursor) == 2)
        #expect(text.line(forOffset: 2) == 0)
        #expect(text.spans(for: 2..<2) == [AccessibleScreenText.CellSpan(row: 0, columns: 2..<3)])
    }

    @Test func cursorOnALaterEmptyRowKeepsTheRowsUpToIt() {
        let (_, text) = screen("ls\r\n\r\n")
        #expect(text.string == "ls\n\n")
        #expect(text.lineCount == 3)
        #expect(text.offset(of: GridPoint(x: 0, y: 2)) == 4)
        #expect(text.line(forOffset: 4) == 2)
    }

    @Test func emptyScreenIsOneEmptyLine() {
        let (_, text) = screen("")
        #expect(text.string == "")
        #expect(text.lineCount == 1)
        #expect(text.range(forLine: 0) == 0..<0)
        #expect(text.line(forOffset: 0) == 0)
        #expect(text.offset(of: GridPoint(x: 5, y: 3)) == 0)
        #expect(text.cell(atOffset: 0) == GridPoint(x: 0, y: 0))
        #expect(text.substring(in: 0..<9) == "")
        #expect(text.selection(for: 0..<0, viewportTop: 0) == nil)
    }

    @Test func hyperlinksAreRangesWithTheirTarget() {
        let (_, text) = screen(cols: 20, "see \u{1b}]8;;https://example.com\u{1b}\\docs\u{1b}]8;;\u{1b}\\ now")
        #expect(text.string == "see docs now")
        #expect(text.links == [AccessibleScreenText.Link(range: 4..<8, url: "https://example.com")])
    }

    @Test func concealedTextReadsAsBlank() {
        let (_, text) = screen(cols: 20, "pw \u{1b}[8mhunter2\u{1b}[0m\r\nok")
        #expect(text.string == "pw\nok")
    }
}
