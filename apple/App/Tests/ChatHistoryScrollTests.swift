import HostKit
import XCTest
@testable import App

/// Reading back through a session far longer than the window keeps, as the helper pages it.
@MainActor
final class ChatHistoryScrollTests: XCTestCase {
    #if canImport(UIKit)
    static let platform = "iOS"
    #else
    static let platform = "Mac"
    #endif
    static let step: CGFloat = 400
    /// Pages to read back: past the window's 3,000 items, so the newest are dropped on the way.
    static let pages = 32

    func testOlderPagesLandWithoutMovingTheRowBeingRead() async throws {
        let fixture = try ChatPaneSwitchFixture(session: ChatScenes.session(turns: 200), latency: .milliseconds(150))
        defer { fixture.close() }
        try await fixture.wait { !fixture.visibleRows(0).isEmpty }
        let report = try await readBack(fixture, pages: 4, maximumSteps: 400, watching: .milliseconds(300))
        XCTAssertGreaterThanOrEqual(fixture.client.olderPageRequests, 4)
        XCTAssertGreaterThan(report.landings, 0)
        XCTAssertLessThanOrEqual(report.worstJump, 1, "the row being read stays where it is when a page lands")
    }

    /// A 10,500-item session read back 32 pages. Timing runs only on request (`TEST_RUNNER_GUDO_CHAT_PERF=1`).
    func testReadingBackThroughALongSessionIsWithinBudget() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GUDO_CHAT_PERF"] == nil, "timing runs on request")
        let fixture = try ChatPaneSwitchFixture(session: ChatScenes.session(turns: 1_500), latency: .milliseconds(20))
        defer { fixture.close() }
        try await fixture.wait { !fixture.visibleRows(0).isEmpty }
        let footprint = ProcessStats.footprintMB
        let watch = HangWatch()
        watch.start()
        let report = try await readBack(fixture, pages: Self.pages, maximumSteps: 1_200)
        let stalls = watch.stop()
        let added = ProcessStats.footprintMB - footprint
        let rows = fixture.state(0).model?.frame.rows.count ?? 0
        #if canImport(UIKit)
        let slowestApply = fixture.state(0).controller?.applyDurations.max() ?? 0
        #else
        let slowestApply = (fixture.state(0).controller?.applyDurations.max() ?? .zero) / .milliseconds(1)
        #endif
        print("chat-history \(Self.platform): slowest apply \(String(format: "%.1f", slowestApply)) ms")
        print("chat-history \(Self.platform): \(fixture.client.olderPageRequests) pages over \(report.steps) steps in"
              + " \(report.elapsed.milliseconds) ms; worst jump \(report.worstJump) pt over \(report.landings) pages seen landing; reached the top while loading"
              + " \(report.waitsAtTop) times; \(stalls); \(rows) rows kept; +\(Int(added)) MB")
        XCTAssertLessThanOrEqual(report.worstJump, 1, "\(Self.platform): jump when a page lands")
        XCTAssertLessThanOrEqual(stalls.worst, ChatPerformanceBudget.stall, "\(Self.platform): main-thread stall")
        // The footprint after reading back swings with the system's own caches; what Chat keeps
        // is the bounded window.
        XCTAssertNil(fixture.state(0).model?.error, "\(Self.platform): reading back never falls back to Terminal")
        XCTAssertLessThanOrEqual(rows, ChatRenderLimits.rowsPerPage, "\(Self.platform): rows kept")
        XCTAssertGreaterThanOrEqual(fixture.client.olderPageRequests, Self.pages, "\(Self.platform): pages read")
    }

    private struct Report {
        var steps = 0
        var worstJump: CGFloat = 0
        var landings = 0
        var waitsAtTop = 0
        var elapsed: Duration = .zero
    }

    /// Scrolls up a step at a time until `pages` older pages have loaded. Between steps nothing
    /// scrolls, so a move of the row being read while a page lands is that page moving it.
    private func readBack(_ fixture: ChatPaneSwitchFixture, pages: Int, maximumSteps: Int,
                          watching: Duration = .milliseconds(40)) async throws -> Report {
        var report = Report()
        let start = ContinuousClock.now
        while fixture.client.olderPageRequests < pages, report.steps < maximumSteps {
            await fixture.scrollUp(0, by: Self.step)
            report.steps += 1
            // The row at the top of the reading area, which a page landing above must not move.
            guard let row = fixture.state(0).controller?.readingRow, let settled = fixture.viewportPosition(0, of: row) else { continue }
            let rowsBefore = fixture.state(0).model?.frame.rows.count
            let watched = ContinuousClock.now
            while ContinuousClock.now - watched < watching {
                try await Task.sleep(for: .milliseconds(2))
                guard fixture.state(0).model?.frame.rows.count != rowsBefore else { continue }
                guard let position = fixture.viewportPosition(0, of: row) else { break }
                report.worstJump = max(report.worstJump, abs(position - settled))
                report.landings += 1
                break
            }
            if fixture.atTop(0), fixture.state(0).model?.isLoadingHistory == true { report.waitsAtTop += 1 }
        }
        report.elapsed = ContinuousClock.now - start
        return report
    }
}
