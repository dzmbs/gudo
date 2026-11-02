import Testing

@testable import NotifyKit

/// A storm of attention items: one request in flight at a time, the newest note per pane, and
/// nothing lost at the end.
@MainActor
@Test func noteQueueCoalescesAStormPerPane() async throws {
    final class Log {
        var delivered: [Int] = []
        var inFlight = 0
        var maxInFlight = 0
    }
    let log = Log()
    let queue = NoteQueue<Int> { note in
        log.inFlight += 1
        log.maxInFlight = max(log.maxInFlight, log.inFlight)
        try? await Task.sleep(for: .milliseconds(2))
        log.delivered.append(note)
        log.inFlight -= 1
    }
    for note in 0..<10_000 { queue.enqueue(note, key: "pane-\(note % 20)") }
    #expect(queue.count <= 20)
    for _ in 0..<200 where queue.count > 0 || log.inFlight > 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(log.maxInFlight == 1)
    #expect(log.delivered.count <= 21, "the first note may leave before the burst, then one per pane")
    #expect(Set(log.delivered.suffix(20)) == Set(9_980..<10_000), "each pane's newest note is the one posted")
}
