import Foundation
import Testing
import TerminalCore

/// A remote pane's VT: READY replaces the state, history pages are prepended later, live bytes
/// continue in between (docs/DAEMON.md "Scrollback history paging").
@Test func snapshotRestoreThenHistoryPages() throws {
    let daemon = Terminal(cols: 20, rows: 4) { _ in }
    for i in 0..<20000 { daemon.write(Array("line \(i)\r\n".utf8)) }
    daemon.write(Array("\u{1b}[?1h$ ".utf8))  // application cursor keys + a prompt
    let snapshot = try #require(daemon.encodeSnapshot())
    let (ready, history) = try #require(Terminal.splitSnapshot(snapshot))
    #expect(ready.count < snapshot.count)

    var replies: [UInt8] = []
    let client = Terminal(cols: 80, rows: 24) { _ in }
    client.write(Array("stale".utf8))
    try client.restore(snapshot: ready)
    let screen = client.plainText()
    #expect(!screen.contains("stale"))
    #expect(screen.contains("line 19999"))
    #expect(!screen.contains("line 0\n"))
    // Modes came across: the up arrow is encoded for application cursor mode.
    #expect(client.encode(.press(.arrowUp)) == Array("\u{1b}OA".utf8))
    _ = replies

    // Live output continues on the restored terminal, then history arrives in two pieces.
    client.write(Array("echo hi".utf8))
    let half = history.count / 2
    var cut = 0
    // Cut on a record boundary at or after half (records: tag u16, len u32, 4 more header bytes).
    var offset = history.startIndex
    while offset < history.endIndex {
        let length = Int(history[offset + 2]) | Int(history[offset + 3]) << 8
            | Int(history[offset + 4]) << 16 | Int(history[offset + 5]) << 24
        offset += 10 + length
        if offset - history.startIndex >= half, cut == 0 { cut = offset - history.startIndex }
    }
    let first = history.prefix(cut)
    let rest = history.dropFirst(cut)
    try client.appendHistory(Data(first))
    try client.appendHistory(Data(rest))
    let all = client.plainText()
    #expect(all.contains("line 0\n"))
    #expect(all.contains("echo hi"))
    #expect(client.scrollbar.total > 20000)
    replies = []
}

@Test func garbageSnapshotsAreRejectedAndKeepTheTerminal() {
    let client = Terminal(cols: 10, rows: 2) { _ in }
    client.write(Array("kept".utf8))
    #expect(throws: Terminal.SnapshotError.self) { try client.restore(snapshot: Data([1, 2, 3])) }
    #expect(client.plainText().contains("kept"))
}
