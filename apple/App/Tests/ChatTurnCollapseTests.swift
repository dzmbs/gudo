import HostKit
import XCTest
@testable import App

final class ChatTurnCollapseTests: XCTestCase {
    private typealias F = ChatFixtures
    private let replies = ["a1": "First, the plan.", "a2": "All **done**.", "b2": "Second answer."]

    private func fold(_ rows: [ChatRow], expanded: Set<ChatRowID> = [], collapses: Bool = true) -> [ChatRow] {
        ChatTurnCollapse.fold(rows, expanded: expanded, collapses: collapses, reply: { self.replies[$0] })
    }

    private var finishedTurn: [ChatRow] {
        [F.prompt("p", turn: "t"), F.shell("s1", turn: "t"), F.reply("a1", turn: "t"), F.shell("s2", turn: "t"),
         F.shell("s3", turn: "t", status: "Failed"), F.reply("a2", turn: "t"), F.turnEnd("end", turn: "t")]
    }

    func testAFinishedTurnFoldsItsWorkUnderThePromptAndKeepsTheReply() throws {
        let folded = fold(finishedTurn)
        XCTAssertEqual(folded.count, 4)
        XCTAssertEqual(folded[0].id.item, "p")
        guard case .turnSummary(let summary) = folded[1].content else { return XCTFail("no summary under the prompt") }
        XCTAssertEqual(summary.label, "Ran 3 commands, 1 message")
        XCTAssertEqual(summary.outcome, "1 failed")
        XCTAssertEqual(summary.tools.map(\.id), ["s1", "s2", "s3"])
        XCTAssertTrue(ChatTurnCollapse.isSummary(folded[1].id))
        XCTAssertEqual(ChatRowSpacing.role(of: folded[1]), .work)
        XCTAssertEqual(folded[2].id.item, "a2")
        guard case .turnFooter(let footer) = folded[3].content else { return XCTFail("the turn end became no footer") }
        XCTAssertEqual(footer.markdown, "All **done**.")
        XCTAssertEqual(footer.end?.durationMs, 94_000)
        XCTAssertEqual(footer.turn, "t")
        XCTAssertEqual(ChatRowSpacing.role(of: folded[3]), .turnEnd)
    }

    func testOpeningTheSummaryShowsEveryRowOfTheTurnAgain() {
        let summary = fold(finishedTurn)[1].id
        let open = fold(finishedTurn, expanded: [summary])
        XCTAssertEqual(open.map(\.id.item), ["p", summary.item, "s1", "a1", "s2", "s3", "a2", open[7].id.item])
        XCTAssertEqual(fold(finishedTurn, expanded: [summary])[1].revision, fold(finishedTurn)[1].revision)
    }

    func testATurnStillWorkingStaysOpen() {
        let rows = Array(finishedTurn.dropLast())
        XCTAssertEqual(fold(rows).map(\.id.item), rows.map(\.id.item))
    }

    func testALaterPromptClosesTheTurnBeforeIt() {
        let rows = Array(finishedTurn.dropLast()) + [F.prompt("q", turn: "u"), F.shell("b1", turn: "u"), F.reply("b2", turn: "u")]
        let folded = fold(rows)
        XCTAssertEqual(folded.map { ChatRowSpacing.role(of: $0) }, [.prompt, .work, .reply, .turnEnd, .prompt, .work, .reply])
        guard case .turnFooter(let footer) = folded[3].content else { return XCTFail("no footer under the closed turn") }
        XCTAssertNil(footer.end)
        XCTAssertEqual(folded[6].id.item, "b2", "the latest turn has not ended")
    }

    func testTurningFoldingOffKeepsEveryRowAndStillOffersCopy() {
        let folded = fold(finishedTurn, collapses: false)
        XCTAssertEqual(folded.map(\.id.item).dropLast(), ["p", "s1", "a1", "s2", "s3", "a2"])
        guard case .turnFooter = folded.last?.content else { return XCTFail("no footer") }
    }

    func testAPlanStaysInViewAndATurnWithOnlyAReplyDoesNotFold() {
        let plan = F.row("plan", turn: "t", body: ["Plan": ["entries": [["text": "Ship", "status": "Completed"]]]])
        let rows = [F.prompt("p", turn: "t"), plan, F.shell("s1", turn: "t"), F.reply("a2", turn: "t"), F.turnEnd("end", turn: "t")]
        XCTAssertEqual(fold(rows).map(\.id.item).prefix(3), ["p", fold(rows)[1].id.item, "plan"])
        let simple = [F.prompt("p", turn: "t"), F.reply("a2", turn: "t"), F.turnEnd("end", turn: "t")]
        XCTAssertEqual(fold(simple).count, 3)
        guard case .turnFooter = fold(simple)[2].content else { return XCTFail("a reply alone still gets its footer") }
    }

    func testTheContextMeterReadsTheLastFinishedTurn() throws {
        let rows = fold(finishedTurn)
        let session = try TimelineJSON.decode(TimelineSession.self, from: #"{"agent":"Claude","native_session":"s","title":null,"model":"claude-opus-4-5-20251101","permission_mode":null,"commands":[]}"#)
        let usage = try XCTUnwrap(ChatContextUsage(reported: nil, rows: rows, session: session))
        XCTAssertEqual(usage.used, 48_000)
        XCTAssertEqual(usage.limit, 200_000)
        XCTAssertEqual(usage.percent, 24)
        XCTAssertEqual(usage.amount, "48K of 200K")
        XCTAssertEqual(usage.lastOutput, 3_100)
        XCTAssertNil(ChatContextUsage(reported: nil, rows: [F.turnEnd("end", turn: "t", input: nil)], session: session))
        XCTAssertEqual(ChatContextUsage.window(model: "claude-sonnet-4-5[1m]"), 1_000_000)
        XCTAssertNil(ChatContextUsage.window(model: "gpt-5-codex"))
        XCTAssertNil(ChatContextUsage.window(model: "fixture-model"))
    }

    func testTheContextMeterPrefersWhatTheAgentReports() throws {
        let session = try TimelineJSON.decode(TimelineSession.self, from: #"{"agent":"Codex","native_session":"s","title":null,"model":"gpt-5-codex","permission_mode":null,"commands":[]}"#)
        XCTAssertNil(ChatContextUsage(reported: nil, rows: fold(finishedTurn), session: session))
        let usage = try XCTUnwrap(ChatContextUsage(reported: AgentContextUsage(used: 136_000, window: 272_000),
                                                   rows: fold(finishedTurn), session: session))
        XCTAssertEqual(usage.percent, 50)
        XCTAssertEqual(usage.source, .agent)
        XCTAssertNil(ChatContextUsage(reported: AgentContextUsage(used: 1, window: 0), rows: [], session: session))
    }

    #if os(iOS)
    @MainActor func testTheFooterRowCopiesTheReplyAsMarkdown() throws {
        let footer = try XCTUnwrap(fold(finishedTurn).last)
        let view = ChatRowView(row: footer, isExpanded: false, toggle: {}, actions: ChatRowActions())
        XCTAssertEqual(view.plainText, "All **done**.")
    }
    #endif
}
