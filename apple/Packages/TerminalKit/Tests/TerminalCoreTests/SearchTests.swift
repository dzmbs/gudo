import Testing
@testable import TerminalCore

private func row(_ terminal: Terminal, _ y: Int) -> String {
    let rows = terminal.visibleText().split(separator: "\n", omittingEmptySubsequences: false)
    return rows.indices.contains(y) ? String(rows[y]) : ""
}

private func lines(_ texts: [String]) -> [UInt8] {
    Array(texts.map { $0 + "\r\n" }.joined().utf8)
}

/// libghostty-vt's scrollback search as `TerminalSearch` drives it: counts over scrollback,
/// newest-first selection that scrolls the viewport, viewport highlights, and exact case.
@Suite struct SearchTests {
    /// 40 lines in a 10-row terminal: "match" on lines 5, 20 and 35, so two are in scrollback.
    private func terminal() -> Terminal {
        let terminal = Terminal(cols: 30, rows: 10) { _ in }
        terminal.write(lines((0..<40).map { [5, 20, 35].contains($0) ? "line \($0) match" : "line \($0)" }))
        return terminal
    }

    @Test func countsMatchesInScrollback() {
        let search = TerminalSearch(terminal: terminal())
        search.setNeedle("match", caseSensitive: false)
        let status = search.run()
        #expect(status.total == 3)
        #expect(status.selected == nil)
        #expect(status.isComplete)
    }

    @Test func incrementalUpdateFinishes() {
        let search = TerminalSearch(terminal: terminal())
        search.setNeedle("line", caseSensitive: false)
        var status = search.update(budget: 0.0)
        for _ in 0..<1000 where !status.isComplete { status = search.update(budget: 0.001) }
        #expect(status.isComplete)
        #expect(status.total == 40)
    }

    @Test func nextGoesUpFromTheNewestAndScrollsToTheMatch() throws {
        let terminal = terminal()
        let search = TerminalSearch(terminal: terminal)
        search.setNeedle("match", caseSensitive: false)
        search.run()
        #expect(terminal.viewportAtBottom)

        // Newest first: line 35 is on screen, so no scroll.
        #expect(search.select(.next))
        #expect(search.status.selected == 0)
        #expect(terminal.viewportAtBottom)
        var highlights = search.viewportHighlights(rows: 10, cols: 30)
        let selected = try #require(highlights.first { $0.selected })
        #expect(row(terminal, selected.row).hasPrefix("line 35 match"))
        #expect(selected.columns == 8...12)

        // Line 20 is in scrollback: the viewport moves so it is in view.
        #expect(search.select(.next))
        #expect(search.status.selected == 1)
        #expect(!terminal.viewportAtBottom)
        highlights = search.viewportHighlights(rows: 10, cols: 30)
        let second = try #require(highlights.first { $0.selected })
        #expect(row(terminal, second.row).hasPrefix("line 20 match"))
        // Centered: about half a screen above and below.
        #expect((3...6).contains(second.row))

        // Previous comes back down; next past the oldest wraps to the newest.
        #expect(search.select(.previous))
        #expect(search.status.selected == 0)
        search.select(.next)
        search.select(.next)
        #expect(search.status.selected == 2)
        search.select(.next)
        #expect(search.status.selected == 0)
    }

    @Test func highlightsCoverEveryVisibleMatch() {
        let terminal = Terminal(cols: 20, rows: 4) { _ in }
        terminal.write(Array("ab ab\r\nxx ab".utf8))
        let search = TerminalSearch(terminal: terminal)
        search.setNeedle("ab", caseSensitive: false)
        search.run()
        let highlights = search.viewportHighlights(rows: 4, cols: 20)
        #expect(Set(highlights.map { "\($0.row):\($0.columns)" }) == ["0:0...1", "0:3...4", "1:3...4"])
        #expect(!highlights.contains { $0.selected })
    }

    @Test func wrappedMatchIsSplitAcrossRows() {
        let terminal = Terminal(cols: 10, rows: 4) { _ in }
        terminal.write(Array("12345678needle".utf8))
        let search = TerminalSearch(terminal: terminal)
        search.setNeedle("needle", caseSensitive: false)
        search.run()
        let highlights = search.viewportHighlights(rows: 4, cols: 10)
        #expect(highlights.map(\.row) == [0, 1])
        #expect(highlights.map(\.columns) == [8...9, 0...3])
    }

    @Test func caseSensitiveDropsOtherCases() {
        let terminal = Terminal(cols: 30, rows: 6) { _ in }
        terminal.write(lines(["Error one", "error two", "ERROR three", "Error four"]))
        let search = TerminalSearch(terminal: terminal)
        search.setNeedle("Error", caseSensitive: false)
        #expect(search.run().total == 4)

        search.setNeedle("Error", caseSensitive: true)
        #expect(search.run().total == 2)
        #expect(search.viewportHighlights(rows: 6, cols: 30).map(\.row).sorted() == [0, 3])
        // Next skips "ERROR" and "error": newest first is row 3, then row 0, then back.
        search.select(.next)
        #expect(search.status.selected == 0)
        #expect(search.selectedRange?.start.y == 3)
        search.select(.next)
        #expect(search.status.selected == 1)
        #expect(search.selectedRange?.start.y == 0)
        search.select(.next)
        #expect(search.selectedRange?.start.y == 3)
    }

    @Test func newOutputIsFound() {
        let terminal = terminal()
        let search = TerminalSearch(terminal: terminal)
        search.setNeedle("match", caseSensitive: false)
        #expect(search.run().total == 3)
        terminal.write(lines(["another match"]))
        #expect(search.run().total == 4)
    }

    @Test func clearingTheNeedleEndsTheSearch() {
        let search = TerminalSearch(terminal: terminal())
        search.setNeedle("match", caseSensitive: false)
        search.run()
        search.select(.next)
        search.setNeedle("", caseSensitive: false)
        #expect(search.status == .idle)
        #expect(search.viewportHighlights(rows: 10, cols: 30).isEmpty)
        #expect(!search.select(.next))
    }

    @Test func survivesASnapshotRestore() throws {
        let source = terminal()
        let snapshot = try #require(source.encodeSnapshot())
        let (ready, history) = try #require(Terminal.splitSnapshot(snapshot))
        let restored = Terminal(cols: 30, rows: 10) { _ in }
        let search = TerminalSearch(terminal: restored)
        search.setNeedle("match", caseSensitive: false)
        #expect(search.run().total == 0)
        try restored.restore(snapshot: ready)
        try restored.appendHistory(history)
        #expect(search.run().total == 3)
    }

    /// A daemon pane: history paged in above the screen keeps the selection on its match and
    /// adds the older matches after it.
    @Test func selectionSurvivesHistoryPagedIn() throws {
        // Enough scrollback that READY holds only the recent part.
        let source = Terminal(cols: 30, rows: 10) { _ in }
        source.write(lines((0..<20000).map { $0 % 2000 == 1995 ? "line \($0) match" : "line \($0)" }))
        let snapshot = try #require(source.encodeSnapshot())
        let (ready, history) = try #require(Terminal.splitSnapshot(snapshot))
        let restored = Terminal(cols: 30, rows: 10) { _ in }
        try restored.restore(snapshot: ready)
        let search = TerminalSearch(terminal: restored)
        search.setNeedle("match", caseSensitive: false)
        let before = search.run().total
        #expect(search.select(.next))
        #expect(search.status.selected == 0)
        try restored.appendHistory(history)
        search.update(budget: 0.05)
        #expect(search.run().total == 10)
        #expect(before < 10)
        #expect(search.status.selected == 0, "still on the newest match")
        search.select(.next)
        #expect(search.status.selected == 1)
    }

    /// The selection survives the feeds a render loop does after it, with the viewport scrolled.
    @Test func selectionSurvivesFeeds() {
        let search = TerminalSearch(terminal: terminal())
        search.setNeedle("match", caseSensitive: false)
        search.update(budget: 0.01)
        search.select(.next)
        #expect(search.status.selected == 0)
        for _ in 0..<3 { search.update(budget: 0.01, outputChanged: false) }
        #expect(search.status.selected == 0)
        search.select(.next)
        #expect(search.status.selected == 1)
        for _ in 0..<3 { search.update(budget: 0.01, outputChanged: false) }
        #expect(search.status.selected == 1)
        #expect(search.viewportHighlights(rows: 10, cols: 30).contains { $0.selected })
    }

    /// With a match selected, streaming output used to re-read and sort every match on every
    /// frame (375k matches for "e" over a full scrollback: tens of ms each); the selected index
    /// now refreshes at most every `recountInterval`, and is exact once output pauses.
    @Test func streamingOutputDoesNotRecountEveryFrame() async throws {
        let terminal = terminal()
        let search = TerminalSearch(terminal: terminal)
        search.setNeedle("match", caseSensitive: false)
        search.run()
        #expect(search.select(.next))
        let before = search.recounts
        for i in 0..<50 {
            terminal.write(lines(["streamed \(i)"]))
            search.update(outputChanged: true)
        }
        #expect(search.recounts - before <= 1)
        try await Task.sleep(for: TerminalSearch.recountInterval + .milliseconds(50))
        let status = search.update(outputChanged: false)
        #expect(status.isComplete)
        #expect(status.total == 3 && status.selected == 0)
    }
}

