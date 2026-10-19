import Testing
import TerminalCore
@testable import DrawingKit

/// Anchors (`atSeq`, `fromBottom`) ↔ pins in the app's own terminal.
@Suite struct RowTrackerTests {
    /// A terminal fed numbered lines, with the tracker observing every chunk like the pane does.
    final class Feed {
        let terminal = Terminal(cols: 30, rows: 6) { _ in }
        lazy var tracker = RowTracker(terminal: terminal)
        var seq: UInt64 = 0
        var next = 0

        func lines(_ n: Int, observe: Bool = true) {
            let bytes = Array((next..<next + n).map { "line \($0)\r\n" }.joined().utf8)
            next += n
            terminal.write(bytes)
            seq += UInt64(bytes.count)
            if observe { tracker.observe(seq: seq) }
        }

        func text(of pin: RowPin) -> String? {
            guard let row = terminal.viewportRows(of: [pin]).first ?? nil else { return nil }
            if row >= 0 { return terminal.visibleTextLines.dropFirst(row).first }
            terminal.scrollViewport(by: row)
            defer { terminal.scrollToBottom() }
            return terminal.visibleTextLines.first
        }
    }

    @Test func anchorRoundTripsThroughLaterOutput() throws {
        let feed = Feed()
        feed.lines(10)
        let pin = try #require(feed.terminal.pinRow(viewportRow: 2))
        let text = try #require(feed.text(of: pin))
        let anchor = try #require(feed.tracker.anchor(of: pin))
        #expect(anchor.atSeq == feed.seq)

        feed.lines(25)
        let again = try #require(feed.tracker.pin(atSeq: anchor.atSeq, fromBottom: anchor.fromBottom))
        #expect(feed.text(of: again) == text)
        #expect(feed.terminal.fromBottom(of: again) == feed.terminal.fromBottom(of: pin))
    }

    /// Output written but not yet observed (the connection thread between write and observe)
    /// does not skew an anchor taken meanwhile.
    @Test func anchorIsConsistentWhileOutputIsInFlight() throws {
        let feed = Feed()
        feed.lines(10)
        let pin = try #require(feed.terminal.pinRow(viewportRow: 3))
        let text = try #require(feed.text(of: pin))
        feed.lines(4, observe: false)
        let anchor = try #require(feed.tracker.anchor(of: pin))
        // Named as of the last observed offset…
        #expect(anchor.atSeq < feed.seq)
        feed.tracker.observe(seq: feed.seq)
        feed.lines(7)
        // …and still the same row.
        let again = try #require(feed.tracker.pin(atSeq: anchor.atSeq, fromBottom: anchor.fromBottom))
        #expect(feed.text(of: again) == text)
    }

    /// The daemon names a row at an offset this terminal has passed: the rows scrolled since are
    /// added. An offset not applied yet pins nothing.
    @Test func daemonAnchorAtAnEarlierOffset() throws {
        let feed = Feed()
        feed.lines(8)
        let then = feed.seq
        // At `then` the row 2 above the bottom is "line 6".
        feed.lines(5)
        let pin = try #require(feed.tracker.pin(atSeq: then, fromBottom: 2))
        #expect(feed.text(of: pin)?.hasPrefix("line 6") == true)
        #expect(feed.tracker.pin(atSeq: feed.seq + 10, fromBottom: 0) == nil)
    }

    /// A resize after the last output (the pane growing to its real size before any output)
    /// does not count as scrolling: the anchor names the row on the grid as it is now.
    @Test func resizeIsNotScrolling() throws {
        let feed = Feed()
        feed.lines(2)
        feed.terminal.resize(cols: 30, rows: 20, cellWidth: 8, cellHeight: 16)
        let pin = try #require(feed.terminal.pinRow(viewportRow: 0))
        let anchor = try #require(feed.tracker.anchor(of: pin))
        #expect(Int(anchor.fromBottom) == feed.terminal.fromBottom(of: pin))
        #expect(Int(anchor.fromBottom) < feed.terminal.totalRows)
    }

    @Test func referenceSurvivesLongOutput() throws {
        let feed = Feed()
        feed.lines(8)
        let anchorSeq = feed.seq
        for _ in 0..<30 { feed.lines(100) }
        // 3000 rows later the reference has been re-pinned; anchors from before still resolve.
        let pin = try #require(feed.tracker.pin(atSeq: anchorSeq, fromBottom: 2))
        #expect(feed.text(of: pin)?.hasPrefix("line 6") == true)
    }
}

extension Terminal {
    var visibleTextLines: [String] {
        visibleText().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
