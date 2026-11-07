import Foundation
import HostKit
import XCTest
@testable import App

@MainActor
final class TimelineWindowTests: XCTestCase {
    func testSnapshotsHaveStableUniqueOrderAndRevisions() throws {
        var window = TimelineWindow()
        let snapshot = try snapshot(0..<60)
        let changes = window.replace(snapshot)
        XCTAssertTrue(changes.didReset)
        XCTAssertEqual(window.order.count, 60)
        XCTAssertEqual(Set(window.order).count, 60)
        XCTAssertEqual(window.before, 100)
        let changed = try window.apply(update([upsert(59, revision: 2, sequence: 1)]))
        XCTAssertEqual(window.order, snapshot.items.map(\.id))
        XCTAssertEqual(window.items["m59"]?.revision, 2)
        XCTAssertEqual(changed.changed, ["m59"])
    }

    func testDuplicateAndStaleOperationsDoNotChangeValuesOrOrder() throws {
        var window = TimelineWindow()
        _ = window.replace(try snapshot(0..<60))
        _ = try window.apply(update([upsert(59, revision: 2, sequence: 1)]))
        let duplicate = try window.apply(update([upsert(59, revision: 3, sequence: 1)]))
        XCTAssertTrue(duplicate.changed.isEmpty)
        XCTAssertEqual(window.items["m59"]?.revision, 2)
        let staleRevision = try window.apply(update([upsert(59, revision: 1, sequence: 2)]))
        XCTAssertTrue(staleRevision.changed.isEmpty)
        XCTAssertEqual(window.cursor?.sequence, 2)
    }

    func testGapsAreRejectedAtomically() throws {
        var window = TimelineWindow()
        _ = window.replace(try snapshot(0..<60))
        XCTAssertThrowsError(try window.apply(update([upsert(60, sequence: 1), upsert(61, sequence: 3)])))
        XCTAssertEqual(window.cursor?.sequence, 0)
        XCTAssertNil(window.items["m60"])
        XCTAssertEqual(window.order.count, 60)
    }

    func testAnEpochChangeRequiresASnapshotAndThenDropsPriorItems() throws {
        var window = TimelineWindow()
        _ = window.replace(try snapshot(0..<60))
        XCTAssertThrowsError(try window.apply(update([upsert(60, sequence: 1, epoch: 2)])))
        let replacement = try snapshot(100..<160, epoch: 2)
        let changes = try window.apply(update([snapshotOperation(replacement)]))
        XCTAssertTrue(changes.didReset)
        XCTAssertEqual(window.order, replacement.items.map(\.id))
        XCTAssertNil(window.items["m0"])
        XCTAssertEqual(changes.removed.count, 60)
    }

    func testARefreshKeepsPagedHistoryButReplacesItsAuthoritativeTail() throws {
        var window = TimelineWindow()
        _ = window.replace(try snapshot(100..<160))
        _ = try window.prepend(snapshot(0..<100, before: nil))
        var refreshed = try snapshot(110..<171, sequence: 10)
        refreshed.items.removeAll { $0.id == "m150" }
        let changes = try window.apply(update([snapshotOperation(refreshed)]))
        XCTAssertEqual(window.order.first, "m0")
        XCTAssertEqual(window.order.last, "m170")
        XCTAssertEqual(window.order.count, 170)
        XCTAssertNil(window.items["m150"])
        XCTAssertTrue(changes.removed.contains("m150"))
        XCTAssertNil(window.before)
        XCTAssertEqual(Set(window.order).count, window.order.count)
    }

    func testAnEmptyAuthoritativeSnapshotClearsTheWindow() throws {
        var window = TimelineWindow()
        _ = window.replace(try snapshot(0..<60))
        let changes = try window.apply(update([snapshotOperation(snapshot(0..<0, sequence: 10, before: nil))]))
        XCTAssertTrue(window.order.isEmpty)
        XCTAssertTrue(window.items.isEmpty)
        XCTAssertEqual(changes.removed.count, 60)
    }

    func testAStaleSnapshotCannotRewindTheCursor() throws {
        var window = TimelineWindow()
        _ = window.replace(try snapshot(0..<60, sequence: 10))
        _ = try window.apply(update([snapshotOperation(snapshot(0..<20, sequence: 9))]))
        XCTAssertEqual(window.cursor?.sequence, 10)
        XCTAssertEqual(window.order.count, 60)
    }

    func testHistoryDoesNotAdvanceTheLiveCursorOrOverwriteNewerValues() throws {
        var window = TimelineWindow()
        _ = window.replace(try snapshot(100..<160))
        _ = try window.apply(update([upsert(100, revision: 2, sequence: 1)]))
        _ = try window.prepend(snapshot(0..<110, sequence: 20, before: nil))
        XCTAssertEqual(window.cursor?.sequence, 1)
        XCTAssertEqual(window.items["m100"]?.revision, 2)
        XCTAssertEqual(window.order.count, 160)
        XCTAssertEqual(Set(window.order).count, 160)
        XCTAssertThrowsError(try window.prepend(snapshot(0..<100, epoch: 2)))
    }

    func testCheckpointsAdvanceWithoutAddingContent() throws {
        var window = TimelineWindow()
        _ = window.replace(try snapshot(0..<60))
        _ = try window.apply(update([["Checkpoint": ["cursor": ["epoch": 1, "sequence": 1]]], upsert(60, sequence: 2)]))
        XCTAssertEqual(window.cursor?.sequence, 2)
        XCTAssertEqual(window.order.count, 61)
    }

    func testStreamingAppendsKeepIdentityAndRejectMissingTargets() throws {
        var window = TimelineWindow()
        _ = window.replace(try snapshot(0..<60))
        _ = try window.apply(update([append("m59", text: " tail 🦀", sequence: 1)]))
        guard case .assistant(let value) = window.items["m59"]?.body else { return XCTFail("Missing assistant") }
        XCTAssertEqual(value.text, "Message 59 tail 🦀")
        XCTAssertEqual(window.items["m59"]?.revision, 2)
        XCTAssertEqual(window.order.last, "m59")
        XCTAssertThrowsError(try window.apply(update([append("missing", text: "bad", sequence: 2)])))
        XCTAssertEqual(window.cursor?.sequence, 1)
    }

    func testAnUnknownAppendFieldRejectsTheWholeBatchWithoutChangingTheWindow() throws {
        var window = TimelineWindow()
        _ = window.replace(try snapshot(0..<60))
        let original = window.items
        let bytes = window.retainedBytes
        XCTAssertThrowsError(try window.apply(update([
            append("m59", text: "uncommitted", sequence: 1),
            append("m59", text: "future data", sequence: 2, field: "FutureField")
        ])))
        XCTAssertEqual(window.items, original)
        XCTAssertEqual(window.retainedBytes, bytes)
        XCTAssertEqual(window.cursor?.sequence, 0)
    }

    func testStreamingTextHasABoundedValueSize() throws {
        var window = TimelineWindow()
        _ = window.replace(try snapshot(0..<60))
        XCTAssertThrowsError(try window.apply(update([append("m59", text: String(repeating: "x", count: 256 * 1_024), sequence: 1)])))
        XCTAssertEqual(window.cursor?.sequence, 0)
    }

    func testOutputTailsKeepUTF8BoundariesAndSaturateTheirByteCount() throws {
        var snapshot = try snapshot(0..<1)
        let tool: [String: Any] = ["kind": "Shell", "name": "Bash", "title": "Tests", "input": "cargo test", "status": "Running", "output": ["handle": "opaque", "preview": "", "bytes": UInt64.max], "diff": [], "exit": NSNull(), "duration_ms": NSNull(), "command_mark": NSNull()]
        var object = item(0)
        object["body"] = ["Tool": tool]
        snapshot.items = [try decode(TimelineItem.self, object)]
        var window = TimelineWindow()
        _ = window.replace(snapshot)
        _ = try window.apply(update([append("m0", text: "a" + String(repeating: "🦀", count: 1_100) + "z", sequence: 1, field: "Output")]))
        guard case .tool(let value) = window.items["m0"]?.body else { return XCTFail("Missing tool") }
        XCTAssertLessThanOrEqual(value.output?.preview.utf8.count ?? 0, 4_096)
        XCTAssertFalse(value.output?.preview.contains("�") ?? true)
        XCTAssertEqual(value.output?.bytes, UInt64.max)
    }

    func testPagingBeyondTheLimitKeepsTheOlderViewportAndMarksTheLatestGap() throws {
        var window = TimelineWindow(limit: 160)
        _ = window.replace(try snapshot(200..<260))
        _ = try window.prepend(snapshot(100..<200, before: 50))
        _ = try window.prepend(snapshot(0..<100, before: nil))
        XCTAssertEqual(window.order, (0..<160).map { "m\($0)" })
        XCTAssertEqual(window.items.count, 160)
        XCTAssertTrue(window.hasNewerGap)
        _ = try window.apply(update([upsert(260, sequence: 1)]))
        XCTAssertNil(window.items["m260"])
        _ = try window.apply(update([append("m259", text: "not loaded", sequence: 2)]))
        XCTAssertEqual(window.cursor?.sequence, 2)
        XCTAssertEqual(window.items.count, 160)
    }

    func testLiveEvictionUsesKnownPageBoundariesForTheHistoryCursor() throws {
        var window = TimelineWindow(limit: 160)
        _ = window.replace(try snapshot(100..<160, before: 100))
        _ = try window.prepend(snapshot(0..<100, before: 50))
        let changes = try window.apply(update([upsert(160, sequence: 1)]))
        XCTAssertEqual(window.order.first, "m100")
        XCTAssertEqual(window.before, 100)
        XCTAssertEqual(changes.removed.count, 100)
        XCTAssertFalse(changes.needsHistoryCursor)
    }

    func testLiveOnlyEvictionRequestsAFreshHistoryBoundary() throws {
        var window = TimelineWindow(limit: 60)
        _ = window.replace(try snapshot(0..<60))
        let changes = try window.apply(update([upsert(60, sequence: 1)]))
        XCTAssertTrue(changes.needsHistoryCursor)
        XCTAssertLessThanOrEqual(window.items.count, 60)
        _ = try window.apply(update([snapshotOperation(snapshot(1..<61, sequence: 1, before: 101))]))
        XCTAssertFalse(window.needsHistoryCursor)
        XCTAssertEqual(window.before, 101)
    }

    func testAProtectedHistoryWindowDoesNotEvictTheReadingPosition() throws {
        var window = TimelineWindow(limit: 60)
        _ = window.replace(try snapshot(0..<60))
        _ = try window.apply(update([upsert(60, sequence: 1)]), protectsHistory: true)
        XCTAssertEqual(window.order.first, "m0")
        XCTAssertEqual(window.order.last, "m59")
        XCTAssertTrue(window.hasNewerGap)
        let changes = try window.apply(update([snapshotOperation(snapshot(100..<160, sequence: 10))]), resetSnapshot: true)
        XCTAssertTrue(changes.didReset)
        XCTAssertFalse(window.hasNewerGap)
        XCTAssertEqual(window.order.first, "m100")
    }

    func testRemoveThenUpsertInOneBatchHasNoStaleRemoval() throws {
        var window = TimelineWindow()
        _ = window.replace(try snapshot(0..<60))
        let changes = try window.apply(update([["Remove": ["cursor": ["epoch": 1, "sequence": 1], "id": "m59"]], upsert(59, revision: 2, sequence: 2)]))
        XCTAssertTrue(changes.removed.isEmpty)
        XCTAssertEqual(changes.changed, ["m59"])
        XCTAssertEqual(Set(window.order).count, window.order.count)
    }

    func testByteBudgetKeepsTheLatestValuesAndRequestsAMissingHistoryBoundary() throws {
        var window = TimelineWindow(byteLimit: 16_384)
        _ = window.replace(try largeSnapshot(0..<2, textBytes: 1_024))
        for number in 2..<60 {
            let item = try largeSnapshot(number..<(number + 1), textBytes: 1_024).items[0]
            let value = try JSONSerialization.jsonObject(with: TimelineJSON.encode(item))
            _ = try window.apply(update([["Upsert": ["cursor": ["epoch": 1, "sequence": number - 1], "item": value]]]))
        }
        XCTAssertLessThanOrEqual(window.retainedBytes, window.byteLimit)
        XCTAssertLessThan(window.order.count, 60)
        XCTAssertEqual(window.order.last, "m59")
        XCTAssertTrue(window.needsHistoryCursor)
    }

    func testByteEvictionUsesKnownHistoryBoundaries() throws {
        var window = TimelineWindow(byteLimit: 128 * 1_024)
        _ = window.replace(try largeSnapshot(100..<160, textBytes: 128))
        _ = try window.prepend(largeSnapshot(0..<100, textBytes: 128))
        var large = try largeSnapshot(159..<160, textBytes: 30_000).items[0]
        large.revision = 2
        let value = try JSONSerialization.jsonObject(with: TimelineJSON.encode(large))
        _ = try window.apply(update([["Upsert": ["cursor": ["epoch": 1, "sequence": 1], "item": value]]]))
        XCTAssertEqual(window.order.first, "m100")
        XCTAssertEqual(window.before, 100)
        XCTAssertLessThanOrEqual(window.retainedBytes, window.byteLimit)
    }

    func testProtectedHistoryRejectsGrowthWithoutApplyingLaterDeltasToAnOldValue() throws {
        var window = TimelineWindow(byteLimit: 4_096)
        _ = window.replace(try largeSnapshot(0..<2, textBytes: 500))
        let original = window.items["m0"]
        _ = try window.apply(update([append("m0", text: String(repeating: "x", count: 1_000), sequence: 1)]), protectsHistory: true)
        XCTAssertEqual(window.items["m0"], original)
        XCTAssertTrue(window.hasNewerGap)
        _ = try window.apply(update([append("m0", text: "must not append to stale prefix", sequence: 2)]), protectsHistory: true)
        XCTAssertEqual(window.items["m0"], original)
        XCTAssertEqual(window.cursor?.sequence, 2)
        XCTAssertLessThanOrEqual(window.retainedBytes, window.byteLimit)
    }

    func testAnOversizedHistoryPageDoesNotEvictTheReadingAnchor() throws {
        var window = TimelineWindow(byteLimit: 8_192)
        _ = window.replace(try largeSnapshot(100..<104, textBytes: 256))
        let order = window.order
        XCTAssertThrowsError(try window.prepend(largeSnapshot(0..<100, textBytes: 256)))
        XCTAssertEqual(window.order, order)
        XCTAssertLessThanOrEqual(window.retainedBytes, window.byteLimit)
    }

    func testAnOversizedSnapshotFallsBackWithoutRequestingItForever() throws {
        var window = TimelineWindow(byteLimit: 4_096)
        _ = window.replace(try largeSnapshot(0..<1, textBytes: 10_000))
        XCTAssertTrue(window.items.isEmpty)
        XCTAssertNotNil(window.note)
        XCTAssertFalse(window.needsHistoryCursor)
        XCTAssertLessThanOrEqual(window.retainedBytes, window.byteLimit)
    }

    func testAnOversizedRefreshRetainsProtectedHistoryInsteadOfClearingTheReader() throws {
        var window = TimelineWindow(byteLimit: 4_096)
        _ = window.replace(try largeSnapshot(0..<2, textBytes: 500))
        let original = window.items
        var refreshed = try largeSnapshot(0..<2, textBytes: 1_500)
        refreshed.cursor.sequence = 10
        for index in refreshed.items.indices { refreshed.items[index].revision = 2 }
        _ = window.reconcile(refreshed, protectsHistory: true)
        XCTAssertEqual(window.items, original)
        XCTAssertTrue(window.hasNewerGap)
        XCTAssertFalse(window.needsHistoryCursor)
        XCTAssertNotNil(window.note)
    }

    func testHistoryTrimmingNeverRemovesTheExplicitReadingItem() throws {
        var window = TimelineWindow(limit: 160)
        _ = window.replace(try snapshot(200..<360))
        let original = window.order
        XCTAssertThrowsError(try window.prepend(snapshot(100..<200), protecting: "m330"))
        XCTAssertEqual(window.order, original)
    }

    func testRefreshingAMissingBoundaryDoesNotEvictAReaderWhoStoppedFollowing() throws {
        var window = TimelineWindow(limit: 60)
        _ = window.replace(try snapshot(0..<60))
        _ = try window.apply(update([upsert(60, revision: 1, sequence: 1)]))
        XCTAssertTrue(window.needsHistoryCursor)
        XCTAssertEqual(window.order.first, "m1")
        _ = window.reconcile(try snapshot(20..<80, sequence: 2), protectsHistory: true)
        XCTAssertEqual(window.order.first, "m1")
        XCTAssertTrue(window.hasNewerGap)
        XCTAssertFalse(window.needsHistoryCursor)
        XCTAssertNotNil(window.note)
    }

    func testByteAccountingTracksChangesHistoryAndResets() throws {
        var window = TimelineWindow()
        _ = window.replace(try largeSnapshot(100..<160, textBytes: 128))
        _ = try window.prepend(largeSnapshot(0..<100, textBytes: 256))
        XCTAssertEqual(window.retainedBytes, window.items.values.reduce(0) { $0 + TimelineValueWeight.of($1) })
        _ = try window.apply(update([append("m159", text: " unicode 🦀", sequence: 1), ["Remove": ["cursor": ["epoch": 1, "sequence": 2], "id": "m0"]]]))
        XCTAssertEqual(window.retainedBytes, window.items.values.reduce(0) { $0 + TimelineValueWeight.of($1) })
        _ = window.replace(try snapshot(100..<160, epoch: 2))
        XCTAssertEqual(window.retainedBytes, window.items.values.reduce(0) { $0 + TimelineValueWeight.of($1) })
        _ = window.replace(try snapshot(0..<0, epoch: 3))
        XCTAssertEqual(window.retainedBytes, 0)
    }

    func testASingleOversizedLiveValueRollsBackItsWholeBatch() throws {
        var window = TimelineWindow(byteLimit: 4_096)
        _ = window.replace(try largeSnapshot(0..<2, textBytes: 500))
        let original = window.items, bytes = window.retainedBytes
        let item = try largeSnapshot(2..<3, textBytes: 10_000).items[0]
        let value = try JSONSerialization.jsonObject(with: TimelineJSON.encode(item))
        XCTAssertThrowsError(try window.apply(update([append("m0", text: "uncommitted", sequence: 1), ["Upsert": ["cursor": ["epoch": 1, "sequence": 2], "item": value]]])))
        XCTAssertEqual(window.items, original)
        XCTAssertEqual(window.retainedBytes, bytes)
        XCTAssertEqual(window.cursor?.sequence, 0)
    }

    private func largeSnapshot(_ range: Range<Int>, textBytes: Int) throws -> TimelineSnapshot {
        var result = try snapshot(range)
        result.items = try range.map { number in
            var object = item(number)
            object["body"] = ["Assistant": ["text": String(repeating: "x", count: textBytes), "streaming": true]]
            return try decode(TimelineItem.self, object)
        }
        return result
    }

    private func snapshot(_ range: Range<Int>, sequence: UInt64 = 0, epoch: UInt64 = 1, before: UInt64? = 100) throws -> TimelineSnapshot {
        try decode(TimelineSnapshot.self, ["cursor": ["epoch": epoch, "sequence": sequence], "session": ["agent": "Claude", "native_session": "fixture", "title": NSNull(), "model": NSNull(), "permission_mode": NSNull(), "commands": []], "items": range.map { item($0) }, "before": before.map { $0 as Any } ?? NSNull()])
    }

    private func item(_ number: Int, revision: UInt32 = 1) -> [String: Any] {
        ["id": "m\(number)", "revision": revision, "turn": "turn", "parent": NSNull(), "at": number, "origin": "Agent", "body": ["Assistant": ["text": "Message \(number)", "streaming": true]]]
    }

    private func upsert(_ number: Int, revision: UInt32 = 1, sequence: UInt64, epoch: UInt64 = 1) -> [String: Any] {
        ["Upsert": ["cursor": ["epoch": epoch, "sequence": sequence], "item": item(number, revision: revision)]]
    }

    private func append(_ id: String, text: String, sequence: UInt64, field: String = "Text") -> [String: Any] {
        ["Append": ["cursor": ["epoch": 1, "sequence": sequence], "id": id, "field": field, "text": text]]
    }

    private func snapshotOperation(_ snapshot: TimelineSnapshot) throws -> [String: Any] {
        ["Snapshot": try JSONSerialization.jsonObject(with: TimelineJSON.encode(snapshot))]
    }

    private func update(_ operations: [[String: Any]]) throws -> TimelineUpdate {
        try decode(TimelineUpdate.self, ["pane_id": 7, "operations": operations])
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ object: [String: Any]) throws -> Value {
        let encoded = try JSONSerialization.data(withJSONObject: object)
        return try TimelineJSON.decode(type, from: String(decoding: encoded, as: UTF8.self))
    }
}
