#if os(macOS)
import AppKit
import HostKit
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// Chat on the Mac: the transcript follows the latest row, holds the row being read while older
/// pages arrive, sends and queues, folds finished turns, and switches with Terminal.
@MainActor
final class MacChatTests: XCTestCase {
    override func setUp() async throws {
        UserDefaults.standard.set(ChatPreferences.SendWhileWorking.queue.rawValue, forKey: ChatPreferences.Key.sendWhileWorking)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: ChatPreferences.Key.sendWhileWorking)
    }

    func testOpensAtTheLatestRowAndFollowsWhatStreamsIn() async throws {
        let fixture = try MacChatFixture(snapshot: TimelineFixtureJSON.snapshot(0..<60, before: nil))
        defer { fixture.close() }
        try await fixture.wait { fixture.model?.frame.rows.count == 60 }
        let last = try XCTUnwrap(fixture.model?.frame.rows.last?.id)
        try await fixture.wait { fixture.visibleRows.contains(last) }
        XCTAssertFalse(fixture.visibleRows.contains(try XCTUnwrap(fixture.model?.frame.rows.first?.id)))
        XCTAssertTrue(try XCTUnwrap(fixture.model).followsBottom)

        let paragraphs = (0..<30).map { "Line \($0) of what streams in." }.joined(separator: "\n\n")
        fixture.events.deliver(.timeline(paneId: 7, updateJson: try TimelineFixtureJSON.append("m59", text: "\n\n" + paragraphs, sequence: 1)))
        try await fixture.wait { fixture.model?.frame.cursor?.sequence == 1 }
        try await fixture.wait { fixture.model?.frame.rows.count ?? 0 > 60 }
        let latest = try XCTUnwrap(fixture.model?.frame.rows.last?.id)
        try await fixture.wait { fixture.visibleRows.contains(latest) }
        XCTAssertLessThan(try XCTUnwrap(fixture.controller).distanceFromBottom, ChatTranscriptController.followDistance)
        XCTAssertTrue(try XCTUnwrap(fixture.model).followsBottom)
    }

    func testTheRowBeingReadHoldsWhileAnOlderPageArrives() async throws {
        let fixture = try MacChatFixture(snapshot: TimelineFixtureJSON.snapshot(100..<160, before: 100))
        defer { fixture.close() }
        fixture.client.olderPage = try TimelineFixtureJSON.snapshot(0..<100, before: nil)
        fixture.client.holdsOlderPage = true
        try await fixture.wait { fixture.model?.frame.rows.count == 60 && !fixture.visibleRows.isEmpty }
        XCTAssertEqual(fixture.client.olderPageRequests, 0, "following the latest row asks for no history")
        for _ in 0..<4 where fixture.client.olderPageRequests == 0 { await fixture.scrollWheel(by: 300, steps: 8) }
        try await fixture.wait { fixture.client.olderPageRequests == 1 }
        XCTAssertFalse(try XCTUnwrap(fixture.model).followsBottom)
        let reading = fixture.visibleRows
        XCTAssertFalse(reading.isEmpty)
        fixture.client.holdsOlderPage = false
        try await fixture.wait { fixture.model?.frame.rows.count == 160 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fixture.visibleRows.first, reading.first, "the older page lands above, out of view")
        await fixture.scrollWheel(by: 2, steps: 1)
        let next = try XCTUnwrap(fixture.visibleRows.first)
        XCTAssertTrue([reading.first?.item, "m99"].contains(next.item), "and the next scroll starts where the reader was, not \(next.item)")
    }

    func testAnUpdateWhileReadingEarlierRowsOffersTheLatest() async throws {
        let fixture = try MacChatFixture(snapshot: TimelineFixtureJSON.snapshot(0..<60, before: nil))
        defer { fixture.close() }
        try await fixture.wait { fixture.model?.frame.rows.count == 60 && !fixture.visibleRows.isEmpty }
        await fixture.scrollWheel(by: 120)
        try await fixture.wait { fixture.model?.followsBottom == false }
        let reading = fixture.visibleRows
        XCTAssertFalse(reading.contains { $0.item == "m59" })
        fixture.events.deliver(.timeline(paneId: 7, updateJson: try TimelineFixtureJSON.append("m59", text: " more", sequence: 1)))
        try await fixture.wait { fixture.model?.hasNewItems == true }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.visibleRows, reading, "an update never moves the reader")
        await fixture.scrollWheel(by: -400)
        try await fixture.wait { fixture.model?.followsBottom == true && fixture.model?.hasNewItems == false }
        XCTAssertTrue(fixture.visibleRows.contains { $0.item == "m59" })
    }

    func testNewJumpsToTheLatestRow() async throws {
        let fixture = try MacChatFixture(snapshot: TimelineFixtureJSON.snapshot(0..<60, before: nil))
        defer { fixture.close() }
        try await fixture.wait { fixture.model?.frame.rows.count == 60 && !fixture.visibleRows.isEmpty }
        await fixture.scrollWheel(by: 200)
        try await fixture.wait { fixture.model?.followsBottom == false }
        try XCTUnwrap(fixture.controller).jumpToLatest()
        try await fixture.wait { fixture.visibleRows.contains { $0.item == "m59" } }
        try await fixture.wait { fixture.model?.followsBottom == true }
    }

    func testSendingWhileTheAgentWorksQueuesUntilTheTurnEnds() async throws {
        let fixture = try MacChatFixture(snapshot: TimelineFixtureJSON.snapshot(0..<3, before: nil), working: true)
        defer { fixture.close() }
        try await fixture.wait { fixture.model?.frame.rows.isEmpty == false }
        fixture.state.draft = "Then run the tests"
        fixture.view().send()
        XCTAssertEqual(fixture.state.queue.messages.map(\.text), ["Then run the tests"])
        XCTAssertEqual(fixture.state.draft, "")
        XCTAssertTrue(fixture.client.calls.filter { $0.hasPrefix("send ") }.isEmpty)
        fixture.agent.working = false
        try await fixture.wait { fixture.client.calls.contains("send 7 Then run the tests") }
        XCTAssertTrue(fixture.state.queue.messages.isEmpty)
        try await fixture.wait { fixture.state.composer.phase == .finished }

        fixture.state.draft = "Now the docs"
        fixture.view().send()
        try await fixture.wait { fixture.client.calls.contains("send 7 Now the docs") }
    }

    func testFinishedTurnsFoldAndOpenAndTheirReplyCopiesAsMarkdown() async throws {
        let fixture = try MacChatFixture(snapshot: ChatScenes.snapshot(ChatScenes.longTurn()))
        defer { fixture.close() }
        try await fixture.wait { fixture.model?.frame.rows.contains { ChatTurnCollapse.isSummary($0.id) } == true }
        let model = try XCTUnwrap(fixture.model)
        let folded = model.frame.rows.count
        XCTAssertFalse(model.frame.rows.contains { $0.id.item == "t3" }, "a folded turn hides its work")
        let summary = try XCTUnwrap(model.frame.rows.first { ChatTurnCollapse.isSummary($0.id) })
        model.toggle(summary.id)
        try await fixture.wait { fixture.model?.frame.rows.count ?? 0 > folded }
        XCTAssertTrue(model.frame.rows.contains { $0.id.item == "t3" || ChatToolGroups.isGroup($0.id) })

        let footer = try XCTUnwrap(model.frame.rows.first { if case .turnFooter = $0.content { true } else { false } })
        guard case .turnFooter(let content) = footer.content else { return XCTFail("no footer") }
        let row = ChatRowView(row: footer, isExpanded: false, toggle: {}, actions: ChatRowActions())
        XCTAssertEqual(row.plainText, content.markdown)
        XCTAssertTrue(content.markdown.contains("The starter page is close."))
    }

    func testAPastedOrChosenImageBecomesAnAttachment() async throws {
        let file = try ChatPhotoFile.prepare(data: ChatScenes.dashboardPNG(), name: "dashboard.png")
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        XCTAssertGreaterThan(file.bytes, 0)
        XCTAssertNotNil(file.thumbnail)
        let fixture = try MacChatFixture(snapshot: TimelineFixtureJSON.snapshot(0..<3, before: nil))
        defer { fixture.close() }
        try await fixture.wait { fixture.model?.frame.rows.count == 3 }
        fixture.state.photos.begin(in: fixture.state)
        fixture.state.photos.load(in: fixture.state, photo: { file }, source: { _ in "/work/uploads/dashboard.jpg" })
        try await fixture.wait { fixture.state.photos.attachments.count == 1 }
        fixture.state.draft = "What is wrong here?"
        XCTAssertTrue(fixture.view().outgoingMessage.contains("/work/uploads/dashboard.jpg"))
    }

    func testTheSwitchShowsChatOrTerminalAndRemembersTheChoice() async throws {
        XCTAssertEqual(Workspace.defaultChatPresentation(offersChat: true), .terminal, "the Mac opens agents in Terminal")
        let fixture = try MacChatFixture(snapshot: TimelineFixtureJSON.snapshot(0..<3, before: nil), presentation: .terminal)
        defer { fixture.close() }
        XCTAssertEqual(fixture.state.presentation, .terminal)
        fixture.state.activate(in: fixture.hub)
        fixture.state.draft = "Kept across the switch"
        XCTAssertTrue(fixture.state.show(.chat, terminal: fixture.pane))
        XCTAssertEqual(fixture.state.presentation, .chat)
        XCTAssertFalse(fixture.pane.inputPresentation.allowsTerminalInput)
        try await fixture.wait { fixture.model?.frame.rows.count == 3 && !fixture.visibleRows.isEmpty }

        let remembered = PaneChatState(member: HostPane(hostId: "fixture", pane: fixture.pane.id), defaultPresentation: .terminal,
                                       agent: .claude, preferences: fixture.preferences,
                                       pool: ChatModelPool(capacity: 1))
        XCTAssertEqual(remembered.presentation, .chat)

        XCTAssertTrue(fixture.state.show(.terminal, terminal: fixture.pane))
        XCTAssertEqual(fixture.state.presentation, .terminal)
        XCTAssertTrue(fixture.pane.inputPresentation.allowsTerminalInput)
        XCTAssertEqual(fixture.state.draft, "Kept across the switch")
        XCTAssertEqual(fixture.backend.state.withLock { $0.claims }, 1, "the terminal takes the size back")
    }

    /// A 2,100-item session, folded and unfolded: time to the first rows, scrolling, streaming
    /// and memory. Timing runs only on request (`TEST_RUNNER_GUDO_CHAT_PERF=1`), on a quiet machine.
    func testALongSessionOpensScrollsAndStreams() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GUDO_CHAT_PERF"] == nil, "timing runs on request")
        defer { UserDefaults.standard.removeObject(forKey: ChatPreferences.Key.collapsesTurns) }
        for folds in [true, false] {
            UserDefaults.standard.set(folds, forKey: ChatPreferences.Key.collapsesTurns)
            try await measureLongSession(folds: folds)
        }
    }

    /// Opening a long session as the daemon sends it, its latest page with history above; the first
    /// open in the process also pays for warming up.
    private func openLatestPage(of session: [[String: Any]]) async throws -> Duration {
        let page = Array(session.suffix(60))
        let opened = ContinuousClock.now
        let fixture = try MacChatFixture(snapshot: ChatScenes.snapshot(page, before: UInt64(session.count - page.count)))
        defer { fixture.close() }
        try await fixture.wait(timeout: .seconds(30)) {
            guard let last = fixture.model?.frame.rows.last?.id else { return false }
            return fixture.visibleRows.contains(last)
        }
        return ContinuousClock.now - opened
    }

    private func measureLongSession(folds: Bool) async throws {
        let session = ChatScenes.session(turns: 300)
        let latestPage = try await openLatestPage(of: session)
        let snapshot = try ChatScenes.snapshot(session)
        let footprint = ProcessStats.footprintMB
        let opened = ContinuousClock.now
        let fixture = try MacChatFixture(snapshot: snapshot)
        defer { fixture.close() }
        try await fixture.wait(timeout: .seconds(60)) { fixture.model?.frame.rows.isEmpty == false }
        let decoded = ContinuousClock.now - opened
        let summaries = { fixture.model?.frame.rows.contains { ChatTurnCollapse.isSummary($0.id) } == true }
        try await fixture.wait(timeout: .seconds(60)) { summaries() == folds }
        let last = try XCTUnwrap(fixture.model?.frame.rows.last?.id)
        try await fixture.wait(timeout: .seconds(60)) { fixture.visibleRows.contains(last) }
        let shown = ContinuousClock.now - opened
        let controller = try XCTUnwrap(fixture.controller)
        let rows = fixture.model?.frame.rows.count ?? 0
        try await Task.sleep(for: .milliseconds(500))
        let openFootprint = ProcessStats.footprintMB - footprint

        let watch = HangWatch()
        watch.start()
        let scrollStart = ContinuousClock.now
        let measuredBefore = controller.measuredRows
        for _ in 0..<40 { await fixture.scrollWheel(by: 200, steps: 4) }
        let scrolled = ContinuousClock.now - scrollStart
        let scrollReport = watch.stop()
        let measuredWhileScrolling = controller.measuredRows - measuredBefore

        controller.jumpToLatest()
        try await fixture.wait { fixture.model?.followsBottom == true }
        let reply = "s299-reply"
        let appliesBefore = controller.applyDurations.count
        watch.start()
        let streamStart = ContinuousClock.now
        for sequence in 1...100 {
            fixture.events.deliver(.timeline(paneId: 7, updateJson: try TimelineFixtureJSON.append(
                reply, text: " More words stream in, sentence \(sequence).", sequence: UInt64(sequence))))
            try await fixture.wait { fixture.model?.frame.cursor?.sequence == UInt64(sequence) }
        }
        try await Task.sleep(for: .milliseconds(100))
        let streamed = ContinuousClock.now - streamStart
        let streamReport = watch.stop()
        let applies = controller.applyDurations.dropFirst(appliesBefore).map(\.milliseconds)
        XCTAssertLessThan(controller.distanceFromBottom, ChatTranscriptController.followDistance, "streaming keeps the latest row in view")
        let label = folds ? "folded" : "unfolded"
        print("chat-perf \(label): \(rows) rows; decoded \(decoded.milliseconds) ms, first rows on screen \(shown.milliseconds) ms"
              + " (controller \(controller.firstContentLatency?.milliseconds ?? -1) ms); footprint +\(Int(openFootprint)) MB")
        print("chat-perf \(label): 40 wheel gestures in \(scrolled.milliseconds) ms, \(measuredWhileScrolling) rows measured; \(scrollReport)")
        print("chat-perf \(label): 100 streamed appends in \(streamed.milliseconds) ms; apply max \(applies.max() ?? 0) ms,"
              + " mean \(applies.isEmpty ? 0 : applies.reduce(0, +) / applies.count) ms over \(applies.count); \(streamReport)")
        print("chat-perf \(label): the latest page of the session on screen in \(latestPage.milliseconds) ms")
        ChatPerformanceBudget.check(label: "Mac \(label)", firstRows: shown, applies: controller.applyDurations.dropFirst(appliesBefore),
                                    stalls: [scrollReport.worst, streamReport.worst], addedMB: openFootprint)
    }
}
#endif
