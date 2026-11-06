import Foundation
import Testing
@testable import HostKit

@MainActor
struct TimelineChannelTests {
    @Test func viewersShareAWatchAndReceiveSnapshotBeforeQueuedUpdates() async throws {
        let client = TimelineTestClient()
        let channel = TimelineChannel(pane: 7) { client }
        var first: [TimelineChannel.Packet] = []
        var second: [TimelineChannel.Packet] = []
        let firstToken = channel.observe { first.append($0) }
        let secondToken = channel.observe { second.append($0) }
        try await wait { await client.watchCalls == 1 }
        channel.receive("update")
        #expect(first.isEmpty && second.isEmpty)
        await client.finishWatch("snapshot")
        try await wait { first.count == 2 && second.count == 2 }
        #expect(first == [.snapshot("snapshot"), .update("update")])
        #expect(second == first)
        channel.removeObserver(firstToken)
        #expect(await client.stopCalls == 0)
        channel.removeObserver(secondToken)
        try await wait { await client.stopCalls == 1 }
    }

    @Test func leavingDuringAWatchStillUnwatchesAfterTheReply() async throws {
        let client = TimelineTestClient()
        let channel = TimelineChannel(pane: 7) { client }
        var packets: [TimelineChannel.Packet] = []
        let token = channel.observe { packets.append($0) }
        try await wait { await client.watchCalls == 1 }
        channel.removeObserver(token)
        #expect(await client.stopCalls == 0)
        await client.finishWatch("snapshot")
        try await wait { await client.stopCalls == 1 }
        #expect(packets.isEmpty)
    }

    @Test func aViewerJoiningDuringUnwatchWaitsBeforeWatchingAgain() async throws {
        let client = TimelineTestClient()
        await client.holdStops()
        let channel = TimelineChannel(pane: 7) { client }
        var hasSnapshot = false
        let first = channel.observe { packet in
            if case .snapshot = packet { hasSnapshot = true }
        }
        try await wait { await client.watchCalls == 1 }
        await client.finishWatch("first")
        try await wait { hasSnapshot }
        channel.removeObserver(first)
        try await wait { await client.stopCalls == 1 }
        var packets: [TimelineChannel.Packet] = []
        let second = channel.observe { packets.append($0) }
        #expect(await client.watchCalls == 1)
        await client.finishStop()
        try await wait { await client.watchCalls == 2 }
        await client.finishWatch("second")
        try await wait { packets == [.snapshot("second")] }
        channel.removeObserver(second)
        try await wait { await client.stopCalls == 2 }
        await client.finishStop()
    }

    @Test func anOverflowRequestsAFreshSnapshotInsteadOfAccumulatingUpdates() async throws {
        let client = TimelineTestClient()
        let channel = TimelineChannel(pane: 7) { client }
        var packets: [TimelineChannel.Packet] = []
        let token = channel.observe { packets.append($0) }
        try await wait { await client.watchCalls == 1 }
        for index in 0..<65 { channel.receive("old update \(index)") }
        await client.finishWatch("initial")
        try await wait { await client.watchCalls == 2 }
        channel.receive("current update")
        await client.finishWatch("current")
        try await wait { packets.count == 3 }
        #expect(packets == [.snapshot("initial"), .snapshot("current"), .update("current update")])
        channel.removeObserver(token)
        try await wait { await client.stopCalls == 1 }
    }

    @Test func thePendingByteBudgetAlsoForcesASnapshot() async throws {
        let client = TimelineTestClient()
        let channel = TimelineChannel(pane: 7) { client }
        let token = channel.observe { _ in }
        try await wait { await client.watchCalls == 1 }
        channel.receive(String(repeating: "x", count: 1_024 * 1_024))
        channel.receive(String(repeating: "y", count: 1_024 * 1_024))
        channel.receive("over budget")
        await client.finishWatch("initial")
        try await wait { await client.watchCalls == 2 }
        await client.finishWatch("current")
        channel.removeObserver(token)
        try await wait { await client.stopCalls == 1 }
    }

    @Test func anOldConnectionCannotReplaceAReconnectedWatch() async throws {
        let client = TimelineTestClient()
        let channel = TimelineChannel(pane: 7) { client }
        var packets: [TimelineChannel.Packet] = []
        let token = channel.observe { packets.append($0) }
        try await wait { await client.watchCalls == 1 }
        channel.disconnected()
        channel.receive("old connection")
        channel.reconnect()
        try await wait { await client.watchCalls == 2 }
        await client.finishWatch("stale snapshot")
        channel.receive("current update")
        await client.finishWatch("current snapshot")
        try await wait { packets.count == 2 }
        #expect(packets == [.snapshot("current snapshot"), .update("current update")])
        channel.removeObserver(token)
        try await wait { await client.stopCalls == 1 }
    }

    @Test func closingDuringAWatchDoesNotResurrectThePane() async throws {
        let client = TimelineTestClient()
        let channel = TimelineChannel(pane: 7) { client }
        var packets: [TimelineChannel.Packet] = []
        _ = channel.observe { packets.append($0) }
        try await wait { await client.watchCalls == 1 }
        channel.close()
        await client.finishWatch("late snapshot")
        try await wait { await client.stopCalls == 1 }
        #expect(packets.count == 1)
        guard case .unavailable = packets.first else { Issue.record("Missing close note"); return }
        _ = channel.observe { packets.append($0) }
        #expect(packets.count == 2)
        #expect(await client.watchCalls == 1)
    }

    @Test func aLaterViewerGetsAFreshSnapshotSharedWithExistingViewers() async throws {
        let client = TimelineTestClient()
        let channel = TimelineChannel(pane: 7) { client }
        var first: [TimelineChannel.Packet] = []
        var second: [TimelineChannel.Packet] = []
        let firstToken = channel.observe { first.append($0) }
        try await wait { await client.watchCalls == 1 }
        await client.finishWatch("initial")
        try await wait { first.count == 1 }
        channel.receive("first update")
        let secondToken = channel.observe { second.append($0) }
        try await wait { await client.watchCalls == 2 }
        channel.receive("second update")
        await client.finishWatch("current")
        try await wait { second.count == 2 }
        #expect(first == [.snapshot("initial"), .update("first update"), .snapshot("current"), .update("second update")])
        #expect(second == [.snapshot("current"), .update("second update")])
        channel.removeObserver(firstToken)
        channel.removeObserver(secondToken)
        try await wait { await client.stopCalls == 1 }
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for timeline transport")
        throw CancellationError()
    }
}

private actor TimelineTestClient: DaemonTimelineAPI {
    var watchCalls = 0
    var stopCalls = 0
    private var watches: [CheckedContinuation<String, any Error>] = []
    private var stops: [CheckedContinuation<Void, any Error>] = []
    private var shouldHoldStops = false

    func timelineWatch(paneId: UInt64) async throws -> String {
        watchCalls += 1
        return try await withCheckedThrowingContinuation { watches.append($0) }
    }

    func timelineUnwatch(paneId: UInt64) async throws {
        stopCalls += 1
        if shouldHoldStops { try await withCheckedThrowingContinuation { stops.append($0) } }
    }

    func timelineItemsBefore(paneId: UInt64, before: UInt64, limit: UInt16) async throws -> String { "{}" }
    func timelineToolOutput(paneId: UInt64, handle: String, offset: UInt64, len: UInt32) async throws -> String { "{}" }
    func holdStops() { shouldHoldStops = true }
    func finishWatch(_ json: String) { watches.removeFirst().resume(returning: json) }
    func finishStop() { stops.removeFirst().resume() }
}
