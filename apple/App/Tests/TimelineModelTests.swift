import Foundation
import HostKit
import XCTest
import os
@testable import App

@MainActor
final class TimelineModelTests: XCTestCase {
    func testDeinitializingTheScreenReleasesItsSharedWatchObserver() {
        let resolutions = OSAllocatedUnfairLock(initialState: 0)
        let hub = DaemonWorkspace(hostId: "fixture", events: WorkspaceEventHub(), resolve: {
            resolutions.withLock { $0 += 1 }
            return nil
        })
        var model: TimelineModel? = TimelineModel(pane: 7)
        weak var released = model
        model?.start(in: hub)
        let initial = resolutions.withLock { $0 }
        XCTAssertGreaterThan(initial, 0)
        model = nil
        XCTAssertNil(released)
        hub.timelineChannel(pane: 7).requestSnapshot()
        XCTAssertEqual(resolutions.withLock { $0 }, initial)
    }

    func testSnapshotAndStreamingUpdatesRenderThroughTheWorker() async throws {
        let model = TimelineModel(pane: 7)
        model.receive(.snapshot(try TimelineFixtureJSON.snapshot(0..<60)))
        try await wait { model.frame.rows.count == 60 }
        let original = model.frame.rows.last?.id
        let first = model.frame
        model.receive(.update(try TimelineFixtureJSON.append("m59", text: " tail", sequence: 1)))
        try await wait { model.frame.cursor?.sequence == 1 }
        XCTAssertEqual(model.frame.rows.last?.id, original)
        guard case .markdown(let block) = model.frame.rows.last?.content else { return XCTFail("Missing paragraph") }
        XCTAssertEqual(String(block.text.characters), "Message 59 tail")
        XCTAssertNil(model.error)
        XCTAssertEqual(model.frame.parentRevision, first.revision)
        XCTAssertEqual(model.frame.orderRevision, first.orderRevision)
        XCTAssertEqual(model.frame.changedRows?.map(\.id), [original].compactMap { $0 })
        XCTAssertEqual(model.frame.generation, first.generation)
        let second = model.frame
        model.receive(.update(try TimelineFixtureJSON.append("m59", text: "\n\nNew paragraph.", sequence: 2)))
        try await wait { model.frame.cursor?.sequence == 2 }
        XCTAssertEqual(model.frame.parentRevision, second.revision)
        XCTAssertGreaterThan(model.frame.orderRevision ?? 0, second.orderRevision ?? 0)
        XCTAssertEqual(model.frame.rows.count, 61)
        XCTAssertEqual(model.frame.rows[59], second.rows[59])
        model.stop()
    }

    func testOnlyUnfollowedVisibleChangesOfferNewContent() async throws {
        let model = TimelineModel(pane: 7)
        model.receive(.snapshot(try TimelineFixtureJSON.snapshot(0..<60)))
        try await wait { model.frame.rows.count == 60 }
        model.followsBottom = false
        model.receive(.update(try TimelineFixtureJSON.checkpoint(1)))
        try await wait { model.frame.cursor?.sequence == 1 }
        XCTAssertFalse(model.hasNewItems)
        model.receive(.update(try TimelineFixtureJSON.append("m59", text: " tail", sequence: 2)))
        try await wait { model.frame.cursor?.sequence == 2 }
        XCTAssertTrue(model.hasNewItems)
        model.reachedBottom()
        XCTAssertFalse(model.hasNewItems)
        model.stop()
    }

    func testExpansionSurvivesUpdatesButNotRemoval() async throws {
        let model = TimelineModel(pane: 7)
        model.receive(.snapshot(try TimelineFixtureJSON.snapshot(0..<60)))
        try await wait { model.frame.rows.count == 60 }
        let identifier = ChatRowID(item: "m59", part: 0)
        model.toggle(identifier)
        model.receive(.update(try TimelineFixtureJSON.append("m59", text: " tail", sequence: 1)))
        try await wait { model.frame.cursor?.sequence == 1 }
        XCTAssertTrue(model.expanded.contains(identifier))
        model.receive(.update(try TimelineFixtureJSON.update([["Remove": ["cursor": ["epoch": 1, "sequence": 2], "id": "m59"]]])))
        try await wait { model.frame.cursor?.sequence == 2 }
        XCTAssertFalse(model.expanded.contains(identifier))
        model.stop()
    }

    func testMalformedDataKeepsTheLastValidFrameAndOffersTerminal() async throws {
        let model = TimelineModel(pane: 7)
        model.receive(.snapshot(try TimelineFixtureJSON.snapshot(0..<60)))
        try await wait { model.frame.rows.count == 60 }
        let original = model.frame.rows
        model.receive(.update("not JSON"))
        try await wait { model.error != nil }
        XCTAssertEqual(model.frame.rows, original)
        XCTAssertTrue(model.error?.contains("Terminal") ?? false)
        model.stop()
    }

    func testOtherPaneUpdatesAreIgnored() async throws {
        let model = TimelineModel(pane: 7)
        model.receive(.snapshot(try TimelineFixtureJSON.snapshot(0..<60)))
        try await wait { model.frame.rows.count == 60 }
        let json = try TimelineFixtureJSON.append("m59", text: " foreign", sequence: 1, pane: 8)
        model.receive(.update(json))
        try await wait { model.frame.revision == 2 }
        XCTAssertEqual(model.frame.cursor?.sequence, 0)
        guard case .markdown(let block) = model.frame.rows.last?.content else { return XCTFail("Missing paragraph") }
        XCTAssertEqual(String(block.text.characters), "Message 59")
        model.stop()
    }

    func testResetClearsRowsBeforeAnotherConnectionCanPublish() async throws {
        let model = TimelineModel(pane: 7)
        model.receive(.snapshot(try TimelineFixtureJSON.snapshot(0..<60)))
        try await wait { model.frame.rows.count == 60 }
        model.toggle(ChatRowID(item: "m0", part: 0))
        model.receive(.reset)
        XCTAssertTrue(model.frame.rows.isEmpty)
        XCTAssertTrue(model.expanded.isEmpty)
        model.receive(.snapshot(try TimelineFixtureJSON.snapshot(100..<160, epoch: 2)))
        try await wait { model.frame.rows.count == 60 }
        XCTAssertEqual(model.frame.rows.first?.id.item, "m100")
        XCTAssertEqual(model.frame.cursor?.epoch, 2)
        model.stop()
    }

    func testAStoppedScreenCannotReuseAnotherConnectionGenerationsRows() async throws {
        let events = WorkspaceEventHub()
        let hub = DaemonWorkspace(hostId: "fixture", events: events, resolve: { nil })
        let model = TimelineModel(pane: 7)
        model.start(in: hub)
        model.receive(.snapshot(try TimelineFixtureJSON.snapshot(0..<60)))
        try await wait { model.frame.rows.count == 60 }
        model.stop()
        hub.receive(client: .connected(epoch: 2, resumed: true))
        model.start(in: hub)
        XCTAssertTrue(model.frame.rows.isEmpty)
        model.stop()
    }

    func testStartingOnAnotherHostNeverReusesItsRepeatedPaneID() async throws {
        let first = DaemonWorkspace(hostId: "first", events: WorkspaceEventHub(), resolve: { nil })
        let second = DaemonWorkspace(hostId: "second", events: WorkspaceEventHub(), resolve: { nil })
        let model = TimelineModel(pane: 7)
        model.start(in: first)
        model.receive(.snapshot(try TimelineFixtureJSON.snapshot(0..<60)))
        try await wait { model.frame.rows.count == 60 }
        model.start(in: second)
        XCTAssertTrue(model.frame.rows.isEmpty)
        model.stop()
    }

    func testARejectedBatchCannotLeaveUnrenderableWorkerValues() async throws {
        let worker = TimelineRenderWorker(pane: 7)
        _ = try await worker.apply([.snapshot(TimelineFixtureJSON.snapshot(0..<60))], resetsSnapshot: false, protectsHistory: false)
        do {
            _ = try await worker.apply([.update(TimelineFixtureJSON.append("m59", text: " rejected", sequence: 1)), .update("invalid JSON")], resetsSnapshot: false, protectsHistory: false)
            XCTFail("Malformed batch was accepted")
        } catch {}
        let result = try await worker.apply([.update(TimelineFixtureJSON.append("m59", text: " accepted", sequence: 1))], resetsSnapshot: false, protectsHistory: false)
        guard case .markdown(let block) = result.frame.rows.last?.content else { return XCTFail("Missing paragraph") }
        XCTAssertEqual(String(block.text.characters), "Message 59 accepted")
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for the timeline renderer")
        throw CancellationError()
    }
}

nonisolated enum TimelineFixtureJSON {
    static func snapshot(_ range: Range<Int>, sequence: UInt64 = 0, epoch: UInt64 = 1, before: UInt64? = 100) throws -> String {
        try json(["cursor": ["epoch": epoch, "sequence": sequence], "session": ["agent": "Claude", "native_session": "fixture", "title": "Review the change", "model": "fixture-model", "permission_mode": "default", "commands": []], "items": range.map { item($0) }, "before": before.map { $0 as Any } ?? NSNull()])
    }

    static func item(_ number: Int) -> [String: Any] {
        ["id": "m\(number)", "revision": 1, "turn": "turn", "parent": NSNull(), "at": number, "origin": "Agent", "body": ["Assistant": ["text": "Message \(number)", "streaming": true]]]
    }

    static func append(_ id: String, text: String, sequence: UInt64, pane: UInt64 = 7) throws -> String {
        try update([["Append": ["cursor": ["epoch": 1, "sequence": sequence], "id": id, "field": "Text", "text": text]]], pane: pane)
    }

    static func checkpoint(_ sequence: UInt64) throws -> String {
        try update([["Checkpoint": ["cursor": ["epoch": 1, "sequence": sequence]]]])
    }

    static func update(_ operations: [[String: Any]], pane: UInt64 = 7) throws -> String {
        try json(["pane_id": pane, "operations": operations])
    }

    static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
