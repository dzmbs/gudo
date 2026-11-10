import Foundation
import HostKit
import XCTest
import os
@testable import App

@MainActor
final class TimelineModelTests: XCTestCase {
    func testManyAdmittedMessagesCannotExpandBeyondTheRenderedPageRowBudget() async throws {
        var snapshot = try TimelineJSON.decode(TimelineSnapshot.self, from: TimelineFixtureJSON.snapshot(0..<100))
        let text = (0..<31).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        for index in snapshot.items.indices {
            guard case .assistant(var value) = snapshot.items[index].body else { return XCTFail("Missing assistant") }
            value.text = text
            snapshot.items[index].body = .assistant(value)
        }
        let worker = TimelineRenderWorker(pane: 7)
        let json = String(decoding: try TimelineJSON.encode(snapshot), as: UTF8.self)
        let result = try await worker.apply([.snapshot(json)], resetsSnapshot: true, protectsHistory: false)
        XCTAssertLessThanOrEqual(result.frame.rows.count, 3_000)
        XCTAssertEqual(result.frame.note, "This Chat page exceeds the rendering budget. Open Terminal.")
    }

    func testRenderedPageBytesAreBoundedSeparatelyFromSourceValuesAndCache() async throws {
        var snapshot = try TimelineJSON.decode(TimelineSnapshot.self, from: TimelineFixtureJSON.snapshot(0..<24))
        let text = "```\n" + String(repeating: "x", count: 100_000) + "\n```"
        for index in snapshot.items.indices {
            guard case .assistant(var value) = snapshot.items[index].body else { return XCTFail("Missing assistant") }
            value.text = text
            snapshot.items[index].body = .assistant(value)
        }
        let worker = TimelineRenderWorker(pane: 7)
        let json = String(decoding: try TimelineJSON.encode(snapshot), as: UTF8.self)
        let result = try await worker.apply([.snapshot(json)], resetsSnapshot: true, protectsHistory: false)
        XCTAssertEqual(result.frame.note, "This Chat page exceeds the rendering budget. Open Terminal.")
        XCTAssertTrue(result.frame.rows.isEmpty)
    }

    func testRenderOverflowPreservesReadersAndAdvancesTheRejectedLiveCursor() async throws {
        let worker = TimelineRenderWorker(pane: 7)
        let initial = try await worker.apply([.snapshot(TimelineFixtureJSON.snapshot(0..<3))],
                                             resetsSnapshot: true, protectsHistory: false)
        let expanded = try expandedPage(0..<103, sequence: 100)
        let rejected = try await worker.apply([.snapshot(expanded)], resetsSnapshot: false, protectsHistory: true)
        XCTAssertEqual(rejected.frame.rows, initial.frame.rows)
        XCTAssertEqual(rejected.frame.generation, initial.frame.generation)
        XCTAssertEqual(rejected.frame.cursor?.sequence, 100)
        XCTAssertTrue(rejected.frame.hasNewerGap)
        XCTAssertEqual(rejected.frame.note, ChatRenderLimits.pageNotice)
        XCTAssertFalse(rejected.needsHistoryCursor)
        let checkpoint = try await worker.apply([.update(TimelineFixtureJSON.checkpoint(101))],
                                                resetsSnapshot: false, protectsHistory: true)
        XCTAssertEqual(checkpoint.frame.cursor?.sequence, 101)
        XCTAssertEqual(checkpoint.frame.rows, initial.frame.rows)
        XCTAssertEqual(checkpoint.frame.note, ChatRenderLimits.pageNotice)
    }

    func testAnOverBudgetPageDoesNotPoisonAnExplicitReset() async throws {
        let worker = TimelineRenderWorker(pane: 7)
        let expanded = try expandedPage(0..<100, sequence: 100)
        let rejected = try await worker.apply([.snapshot(expanded)], resetsSnapshot: true, protectsHistory: false)
        XCTAssertTrue(rejected.frame.rows.isEmpty)
        XCTAssertEqual(rejected.frame.note, ChatRenderLimits.pageNotice)
        let checkpoint = try await worker.apply([.update(TimelineFixtureJSON.checkpoint(101))],
                                                resetsSnapshot: false, protectsHistory: false)
        XCTAssertEqual(checkpoint.frame.cursor?.sequence, 101)
        XCTAssertEqual(checkpoint.frame.note, ChatRenderLimits.pageNotice)
        let recovered = try await worker.apply([.snapshot(TimelineFixtureJSON.snapshot(200..<203, sequence: 102))],
                                               resetsSnapshot: true, protectsHistory: false)
        XCTAssertNil(recovered.frame.note)
        XCTAssertEqual(recovered.frame.rows.count, 3)
        XCTAssertEqual(recovered.frame.rows.first?.id.item, "m200")
        XCTAssertNotEqual(recovered.frame.generation, rejected.frame.generation)
    }

    func testRejectedRenderedHistoryDoesNotMoveItsBoundaryOrInventNewerContent() async throws {
        let worker = TimelineRenderWorker(pane: 7)
        let initial = try await worker.apply([.snapshot(TimelineFixtureJSON.snapshot(100..<103))],
                                             resetsSnapshot: true, protectsHistory: false)
        let page = try expandedPage(0..<100)
        let rejected = try await worker.apply([.older(page)], resetsSnapshot: false,
                                              protectsHistory: true, historyAnchor: "m100")
        XCTAssertEqual(rejected.frame.rows, initial.frame.rows)
        XCTAssertEqual(rejected.frame.before, initial.frame.before)
        XCTAssertEqual(rejected.frame.note, ChatRenderLimits.pageNotice)
        XCTAssertTrue(rejected.consumedHistory)
        XCTAssertFalse(rejected.hasLiveChanges)
        XCTAssertFalse(rejected.frame.hasNewerGap)
        XCTAssertFalse(rejected.needsHistoryCursor)
    }

    func testAutomaticHistoryRequestsStopAtTheRenderedBudgetFallback() async throws {
        let resolutions = OSAllocatedUnfairLock(initialState: 0)
        let hub = DaemonWorkspace(hostId: "render-budget", events: WorkspaceEventHub(), resolve: {
            resolutions.withLock { $0 += 1 }
            return nil
        })
        let model = TimelineModel(pane: 7)
        model.start(in: hub)
        defer { model.stop() }
        model.receive(.snapshot(try TimelineFixtureJSON.snapshot(0..<3)))
        try await wait { model.frame.rows.count == 3 }
        model.followsBottom = false
        model.receive(.snapshot(try expandedPage(0..<103, sequence: 100)))
        try await wait { model.error == ChatRenderLimits.pageNotice }
        let count = resolutions.withLock { $0 }
        model.requestOlder()
        XCTAssertFalse(model.isLoadingHistory)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(resolutions.withLock { $0 }, count)
        XCTAssertEqual(model.error, ChatRenderLimits.pageNotice)
    }

    func testReplacingRenderedRowsDoesNotAccumulateTheirPreviousCharge() async throws {
        let worker = TimelineRenderWorker(pane: 7)
        let text = "```\n" + String(repeating: "x", count: 100_000) + "\n```"
        for revision in 1...30 {
            var snapshot = try TimelineJSON.decode(TimelineSnapshot.self,
                from: TimelineFixtureJSON.snapshot(0..<1, sequence: UInt64(revision)))
            guard case .assistant(var value) = snapshot.items[0].body else { return XCTFail("Missing assistant") }
            value.text = text
            snapshot.items[0].body = .assistant(value)
            snapshot.items[0].revision = UInt32(revision)
            let json = String(decoding: try TimelineJSON.encode(snapshot), as: UTF8.self)
            let result = try await worker.apply([.snapshot(json)], resetsSnapshot: revision == 1, protectsHistory: false)
            XCTAssertNil(result.frame.note)
            XCTAssertEqual(result.frame.rows.count, 1)
        }
    }

    func testAConfiguredValueBudgetSurvivesConnectionResets() async throws {
        var snapshot = try TimelineJSON.decode(TimelineSnapshot.self, from: TimelineFixtureJSON.snapshot(0..<1))
        guard case .assistant(var assistant) = snapshot.items[0].body else { return XCTFail("Missing assistant") }
        assistant.text = String(repeating: "large text", count: 200)
        snapshot.items[0].body = .assistant(assistant)
        let json = String(decoding: try TimelineJSON.encode(snapshot), as: UTF8.self)
        let model = TimelineModel(pane: 7, valueByteLimit: 1_024)
        for attempt in 0..<2 {
            if attempt > 0 { model.receive(.reset) }
            model.receive(.snapshot(json))
            try await wait { model.frame.revision == 1 }
            XCTAssertTrue(model.frame.rows.isEmpty)
            XCTAssertEqual(model.error, "This Chat page exceeds the memory budget. Open Terminal.")
        }
    }

    func testDeinitializingTheScreenReleasesItsSharedWatchObserver() {
        let resolutions = OSAllocatedUnfairLock(initialState: 0)
        let hub = DaemonWorkspace(hostId: "fixture", events: WorkspaceEventHub(), resolve: {
            resolutions.withLock { $0 += 1 }
            return nil
        })
        var model: TimelineModel? = TimelineModel(pane: 7)
        weak let released = model
        model?.start(in: hub)
        let initial = resolutions.withLock { $0 }
        XCTAssertGreaterThan(initial, 0)
        model = nil
        XCTAssertNil(released)
        hub.timelineChannel(pane: 7).requestSnapshot()
        XCTAssertEqual(resolutions.withLock { $0 }, initial)
    }

    func testCapabilityRoundTripsInvalidateDeferredIntentEvenInOneWorkerBatch() async throws {
        let worker = TimelineRenderWorker(pane: 7)
        let full = try TimelineFixtureJSON.snapshot(0..<1)
        let readOnly = try TimelineFixtureJSON.snapshot(0..<1, capabilities: 1)
        let first = try await worker.apply([.snapshot(full)], resetsSnapshot: true, protectsHistory: false)
        let second = try await worker.apply([.snapshot(readOnly), .snapshot(full)], resetsSnapshot: false, protectsHistory: false)
        XCTAssertEqual(first.frame.capabilities, second.frame.capabilities)
        XCTAssertNotEqual(first.frame.capabilityGeneration, second.frame.capabilityGeneration)
        let unknown = try await worker.apply([.snapshot(try TimelineFixtureJSON.snapshot(0..<1, capabilities: 0x8001))], resetsSnapshot: false, protectsHistory: false)
        XCTAssertTrue(unknown.frame.capabilities.contains(.read))
        XCTAssertFalse(unknown.frame.capabilities.contains(.send))
        XCTAssertEqual(unknown.frame.capabilities.rawValue, 0x8001)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(full.utf8)) as? [String: Any])
        legacy.removeValue(forKey: "capabilities")
        let fallback = try await worker.apply([.snapshot(try TimelineFixtureJSON.json(legacy))], resetsSnapshot: false, protectsHistory: false)
        XCTAssertEqual(fallback.frame.capabilities, [.read])
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

    func testCodeHighlightingIsBoundedPerPageAndFinishesOnLaterRenders() async throws {
        let worker = TimelineRenderWorker(pane: 7)
        let json = try codePage(120)
        var result = try await worker.apply([.snapshot(json)], resetsSnapshot: true, protectsHistory: false)
        XCTAssertTrue(result.awaitsHighlights)
        XCTAssertTrue(result.frame.rows.contains { $0.awaitsHighlights })
        XCTAssertTrue(result.frame.rows.contains { !$0.awaitsHighlights })
        var passes = 0
        while result.awaitsHighlights, passes < 200 {
            result = try await worker.apply([.highlights], resetsSnapshot: false, protectsHistory: false)
            passes += 1
        }
        XCTAssertFalse(result.awaitsHighlights)
        for row in result.frame.rows {
            guard case .markdown(let block) = row.content else { return XCTFail("Missing code block") }
            XCTAssertFalse(block.code?.highlights.isEmpty ?? true)
        }
    }

    func testTheModelSchedulesDeferredHighlights() async throws {
        let model = TimelineModel(pane: 7)
        model.receive(.snapshot(try codePage(120, name: "item")))
        try await wait { model.frame.rows.count == 120 && !model.frame.rows.contains { $0.awaitsHighlights } }
        model.stop()
    }

    func testACancelledRenderStopsBeforeFinishing() async throws {
        let worker = TimelineRenderWorker(pane: 7)
        let json = try TimelineFixtureJSON.snapshot(0..<200)
        let render = Task { try await worker.apply([.snapshot(json)], resetsSnapshot: true, protectsHistory: false) }
        render.cancel()
        do {
            _ = try await render.value
            XCTFail("A cancelled render finished")
        } catch is CancellationError {}
        let next = try await worker.apply([.snapshot(json)], resetsSnapshot: true, protectsHistory: false)
        XCTAssertEqual(next.frame.rows.count, 200)
    }

    func testJumpingToLatestAbandonsAnOlderHistoryRequest() async throws {
        let hub = DaemonWorkspace(hostId: "fixture", events: WorkspaceEventHub(), resolve: { nil })
        let model = TimelineModel(pane: 7)
        model.start(in: hub)
        model.receive(.snapshot(try TimelineFixtureJSON.snapshot(0..<3)))
        try await wait { model.frame.rows.count == 3 }
        model.requestOlder()
        XCTAssertTrue(model.isLoadingHistory)
        model.jumpToLatest()
        XCTAssertFalse(model.isLoadingHistory)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.historyError)
        model.stop()
    }

    func testAFailedHistoryLoadKeepsChatAndItsCapabilities() async throws {
        let hub = DaemonWorkspace(hostId: "fixture", events: WorkspaceEventHub(), resolve: { nil })
        let model = TimelineModel(pane: 7)
        model.start(in: hub)
        model.receive(.snapshot(try TimelineFixtureJSON.snapshot(0..<3)))
        try await wait { model.frame.rows.count == 3 && model.error == nil }
        model.requestOlder()
        try await wait { model.historyError != nil }
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoadingHistory)
        XCTAssertFalse(model.frame.capabilities.isEmpty)
        model.stop()
    }

    private func codePage(_ count: Int, name: String = "block") throws -> String {
        let items: [[String: Any]] = (0..<count).map { index in
            let lines = (0..<30).map { "    let \(name)_\(index)_\($0) = compute(\"\($0)\", \(index));" }.joined(separator: "\n")
            var item = TimelineFixtureJSON.item(index)
            item["body"] = ["Assistant": ["text": "```rust\nfn \(name)_\(index)() {\n\(lines)\n}\n```\n", "streaming": false]]
            return item
        }
        var page = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TimelineFixtureJSON.snapshot(0..<0).utf8)) as? [String: Any])
        page["items"] = items
        return try TimelineFixtureJSON.json(page)
    }

    private func expandedPage(_ range: Range<Int>, sequence: UInt64 = 0) throws -> String {
        var page = try TimelineJSON.decode(TimelineSnapshot.self, from: TimelineFixtureJSON.snapshot(range, sequence: sequence))
        let text = (0..<31).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        for index in page.items.indices {
            guard case .assistant(var value) = page.items[index].body else { throw CancellationError() }
            value.text = text
            page.items[index].body = .assistant(value)
        }
        return String(decoding: try TimelineJSON.encode(page), as: UTF8.self)
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
    static func snapshot(_ range: Range<Int>, sequence: UInt64 = 0, epoch: UInt64 = 1, before: UInt64? = 100, capabilities: UInt16 = 447, agent: String = "Claude") throws -> String {
        try json(["capabilities": capabilities, "cursor": ["epoch": epoch, "sequence": sequence], "session": ["agent": agent, "native_session": "fixture", "title": "Review the change", "model": "fixture-model", "permission_mode": "default", "commands": []], "items": range.map { item($0) }, "before": before.map { $0 as Any } ?? NSNull()])
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
