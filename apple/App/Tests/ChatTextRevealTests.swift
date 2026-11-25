import XCTest
@testable import App

/// The paced reveal of a streaming reply: rate from the backlog, convergence, flattened bursts.
final class ChatTextRevealTests: XCTestCase {
    private let frame = Duration.milliseconds(16)

    func testNothingIsRevealedWithoutABacklogOrTime() {
        XCTAssertEqual(ChatTextReveal.step(backlog: 0, elapsed: frame), 0)
        XCTAssertEqual(ChatTextReveal.step(backlog: -5, elapsed: frame), 0)
        XCTAssertEqual(ChatTextReveal.step(backlog: 100, elapsed: .zero), 0)
        XCTAssertEqual(ChatTextReveal.step(backlog: 100, elapsed: .milliseconds(-16)), 0)
    }

    func testTheBacklogDrainsOverTheHorizon() {
        XCTAssertEqual(ChatTextReveal.step(backlog: 300, elapsed: ChatTextReveal.horizon / 2), 150)
        XCTAssertEqual(ChatTextReveal.step(backlog: 42, elapsed: ChatTextReveal.horizon), 42)
        XCTAssertEqual(ChatTextReveal.step(backlog: 42, elapsed: ChatTextReveal.horizon * 10), 42)
    }

    func testALargerBacklogRevealsFasterAndAlwaysAtLeastOneCharacter() {
        XCTAssertGreaterThan(ChatTextReveal.step(backlog: 200, elapsed: frame), ChatTextReveal.step(backlog: 20, elapsed: frame))
        XCTAssertEqual(ChatTextReveal.step(backlog: 1, elapsed: .milliseconds(1)), 1)
        XCTAssertEqual(ChatTextReveal.step(backlog: 2, elapsed: .microseconds(10)), 1)
        for backlog in [1, 3, 7, 50] {
            XCTAssertLessThanOrEqual(ChatTextReveal.step(backlog: backlog, elapsed: .milliseconds(120)), backlog)
        }
    }

    func testTheRevealConvergesWithinABoundedNumberOfFrames() {
        var reveal = ChatTextReveal(showing: 0)
        reveal.retarget(500)
        var frames = 0
        while !reveal.isSettled {
            reveal.advance(by: frame)
            frames += 1
            XCTAssertLessThan(frames, 120)
        }
        XCTAssertEqual(reveal.revealed, 500)
    }

    func testBurstyArrivalPaintsEvenSteps() {
        let arrivals = [4, 180, 6, 240, 2, 90, 300, 8]
        var steps: [Int] = []
        var backlog = 0
        for arrival in arrivals {
            backlog += arrival
            for _ in 0..<4 {
                let step = ChatTextReveal.step(backlog: backlog, elapsed: frame)
                backlog -= step
                steps.append(step)
            }
        }
        XCTAssertLessThan(steps.max() ?? 0, (arrivals.max() ?? 0) / 2, "no frame paints a whole burst")
        XCTAssertGreaterThan(steps.min() ?? 0, 0, "every frame moves")
    }

    func testFirstSightIsWholeAndGrowthIsPaced() {
        var reveal = ChatTextReveal(showing: 12)
        XCTAssertTrue(reveal.isSettled)
        XCTAssertEqual(reveal.revealed, 12)
        reveal.retarget(312)
        XCTAssertEqual(reveal.revealed, 12)
        reveal.advance(by: frame)
        XCTAssertGreaterThan(reveal.revealed, 12)
        XCTAssertLessThan(reveal.revealed, 312)
        reveal.complete()
        XCTAssertEqual(reveal.revealed, 312)
    }

    func testAShorterTextPullsTheRevealBack() {
        var reveal = ChatTextReveal(showing: 100)
        reveal.retarget(40)
        XCTAssertEqual(reveal.revealed, 40)
        XCTAssertTrue(reveal.isSettled)
    }

    func testAFastDisplayRevealsAtSixtyHertz() throws {
        let start = ContinuousClock.now
        let first = try XCTUnwrap(ChatTextReveal.frame(after: nil, at: start))
        XCTAssertEqual(first.elapsed, ChatTextReveal.frameInterval)
        XCTAssertNil(ChatTextReveal.frame(after: start, at: start + .milliseconds(8)))
        let next = try XCTUnwrap(ChatTextReveal.frame(after: start, at: start + .milliseconds(17)))
        XCTAssertEqual(next.elapsed, .milliseconds(17))
        XCTAssertLessThan(abs((start.duration(to: next.frameTime) - ChatTextReveal.frameInterval) / .milliseconds(1)), 0.01)
    }
}

/// The streaming reply's rows: shown whole at first sight, paced as they grow, whole once done.
@MainActor
final class ChatReplyRevealTests: XCTestCase {
    private func frame(_ paragraphs: [String], streaming: Bool = true, revision: UInt32 = 1) -> TimelineFrame {
        let prompt = ChatRow(id: ChatRowID(item: "prompt", part: 0), revision: 1, turn: "turn",
                             content: .markdown(ChatMarkdownBlock(kind: .paragraph, source: "Go", text: AttributedString("Go"))))
        let reply = paragraphs.enumerated().map { index, text in
            ChatRow(id: ChatRowID(item: "reply", part: index), revision: revision, turn: "turn",
                    content: .markdown(ChatMarkdownBlock(kind: .paragraph, source: text, text: AttributedString(text))))
        }
        let rows = [prompt] + reply
        return TimelineFrame(rows: rows, rowIDs: Set(rows.map(\.id)), revision: Int(revision), streamingReply: streaming ? "reply" : nil)
    }

    private func shownText(_ reveal: ChatReplyReveal, _ row: ChatRow) -> String? {
        guard let shown = reveal.display(row), case .markdown(let block) = shown.content else { return nil }
        return String(block.shownText.characters)
    }

    func testAReplySeenForTheFirstTimeShowsWhole() {
        let reveal = ChatReplyReveal()
        let first = frame(["Already written."])
        XCTAssertTrue(reveal.update(first, paces: true).isEmpty)
        XCTAssertEqual(shownText(reveal, first.rows[1]), "Already written.")
        XCTAssertTrue(reveal.isSettled)
    }

    func testGrowthIsPacedAndNewRowsWaitAtNoHeight() {
        let reveal = ChatReplyReveal()
        _ = reveal.update(frame(["Start."]), paces: true)
        let grown = frame(["Start. " + String(repeating: "more ", count: 40), "A second paragraph."], revision: 2)
        let changed = reveal.update(grown, paces: true)
        XCTAssertEqual(changed, [grown.rows[1].id, grown.rows[2].id])
        XCTAssertEqual(shownText(reveal, grown.rows[1]), "Start.", "arrival does not jump")
        XCTAssertEqual(reveal.shown(grown.rows[2].id), .waiting)
        XCTAssertNil(reveal.display(grown.rows[2]))
        let start = ContinuousClock.now
        _ = reveal.advance(at: start)
        _ = reveal.advance(at: start + .milliseconds(17))
        let partial = shownText(reveal, grown.rows[1]) ?? ""
        XCTAssertGreaterThan(partial.count, "Start.".count)
        XCTAssertLessThan(partial.count, 206)
        var now = start + .milliseconds(17)
        for _ in 0..<120 where !reveal.isSettled {
            now += .milliseconds(17)
            _ = reveal.advance(at: now)
        }
        XCTAssertTrue(reveal.isSettled)
        XCTAssertEqual(reveal.shown(grown.rows[2].id), .whole)
    }

    func testAReplyThatStopsStreamingShowsWholeAtOnce() {
        let reveal = ChatReplyReveal()
        _ = reveal.update(frame(["Start."]), paces: true)
        let grown = frame(["Start. " + String(repeating: "more ", count: 40)], revision: 2)
        _ = reveal.update(grown, paces: true)
        XCTAssertNotEqual(reveal.shown(grown.rows[1].id), .whole)
        let done = frame(["Start. " + String(repeating: "more ", count: 40)], streaming: false, revision: 3)
        XCTAssertEqual(reveal.update(done, paces: true), [done.rows[1].id])
        XCTAssertEqual(reveal.shown(done.rows[1].id), .whole)
        XCTAssertTrue(reveal.isSettled)
    }

    func testWithoutPaintingTheReplyShowsWhole() {
        let reveal = ChatReplyReveal()
        _ = reveal.update(frame(["Start."]), paces: true)
        let grown = frame(["Start. " + String(repeating: "more ", count: 40)], revision: 2)
        _ = reveal.update(grown, paces: false)
        XCTAssertEqual(reveal.shown(grown.rows[1].id), .whole)
    }

    func testCopyingAPartlyShownRowReadsAllOfIt() throws {
        let reveal = ChatReplyReveal()
        _ = reveal.update(frame(["Start."]), paces: true)
        let full = "Start. " + String(repeating: "more ", count: 40)
        let grown = frame([full], revision: 2)
        _ = reveal.update(grown, paces: true)
        let shown = try XCTUnwrap(reveal.display(grown.rows[1]))
        XCTAssertEqual(ChatRowView(row: shown, isExpanded: false, toggle: {}, actions: ChatRowActions()).plainText, full)
    }
}
