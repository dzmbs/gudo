import Dispatch
import Synchronization
import TerminalCore
import Testing

@MainActor
struct MainActorCoalescerTests {
    /// Signals from other threads while the main actor is busy become one call, which sees the
    /// last of them; a signal after that call queues another.
    @Test func aBurstWhileTheMainActorIsBusyIsOneCall() async throws {
        let runs = Atomic<Int>(0)
        let seen = Atomic<Int>(0)
        let sent = Atomic<Int>(0)
        let coalescer = MainActorCoalescer {
            runs.add(1, ordering: .relaxed)
            seen.store(sent.load(ordering: .acquiring), ordering: .relaxed)
        }
        // Blocks the main actor until every signal is in.
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            for _ in 0..<50_000 {
                sent.add(1, ordering: .releasing)
                coalescer.signal()
            }
        }
        try await waitUntil { runs.load(ordering: .relaxed) >= 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(runs.load(ordering: .relaxed) == 1)
        #expect(seen.load(ordering: .relaxed) == 200_000)

        sent.add(1, ordering: .releasing)
        coalescer.signal()
        try await waitUntil { runs.load(ordering: .relaxed) == 2 }
        #expect(seen.load(ordering: .relaxed) == 200_001)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
