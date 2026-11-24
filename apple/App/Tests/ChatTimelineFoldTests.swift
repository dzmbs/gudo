import HostKit
import XCTest
@testable import App

final class ChatTimelineFoldTests: XCTestCase {
    private typealias F = ChatFixtures

    private struct Timeline {
        var order: [String] = []
        var rows: [String: [ChatRow]] = [:]
        var revisions: [String: UInt32] = [:]

        mutating func append(_ row: ChatRow) {
            order.append(row.id.item)
            rows[row.id.item] = [row]
        }

        mutating func revise(_ identifier: String) {
            guard let row = rows[identifier]?.first else { return }
            let revision = row.revision + 1
            rows[identifier] = [ChatRow(id: row.id, revision: revision, turn: row.turn, content: row.content)]
        }
    }

    private func turn(_ index: Int, finished: Bool = true) -> [ChatRow] {
        let turn = "t\(index)"
        var rows = [F.prompt("p\(index)", turn: turn), F.shell("s\(index)a", turn: turn), F.shell("s\(index)b", turn: turn),
                    F.reply("a\(index)", turn: turn)]
        if finished { rows.append(F.turnEnd("e\(index)", turn: turn)) }
        return rows
    }

    private func fullFold(_ timeline: Timeline, expanded: Set<ChatRowID> = [], previous: [ChatRowID: ChatRow]) -> [ChatRow] {
        ChatTimelineFold.fold(timeline.order.flatMap { timeline.rows[$0] ?? [] }, expanded: expanded, collapses: true,
                              reply: { "Reply \($0)" }, previous: previous)
    }

    private func update(_ fold: inout ChatTimelineFold, _ timeline: Timeline, changed: Set<String>,
                        removed: Set<String> = [], expanded: Set<ChatRowID> = [],
                        previous: [ChatRowID: ChatRow]) -> ChatTimelineFold.Change {
        fold.update(order: timeline.order, rowsOf: { timeline.rows[$0] ?? [] }, changed: changed, removed: removed,
                    resets: false, expanded: expanded, collapses: true, reply: { "Reply \($0)" }, previous: previous)
    }

    private func groups(_ rows: [ChatRow]) -> [ChatRowID: ChatRow] {
        Dictionary(uniqueKeysWithValues: rows.filter(\.content.isDerived).map { ($0.id, $0) })
    }

    func testStreamingRefoldsOnlyTheLastTurnAndMatchesAFullFold() {
        let checks = ChatTimelineFold.checksAgainstFullFold
        ChatTimelineFold.checksAgainstFullFold = false
        defer { ChatTimelineFold.checksAgainstFullFold = checks }
        var timeline = Timeline()
        for index in 0..<200 { turn(index).forEach { timeline.append($0) } }
        var fold = ChatTimelineFold()
        _ = update(&fold, timeline, changed: Set(timeline.order), previous: [:])
        XCTAssertEqual(fold.rows, fullFold(timeline, previous: [:]))
        let opened = fold.rows.count

        for (index, row) in turn(200, finished: false).enumerated() {
            let previous = groups(fold.rows)
            timeline.append(row)
            let change = update(&fold, timeline, changed: [row.id.item], previous: previous)
            XCTAssertEqual(fold.rows, fullFold(timeline, previous: previous), "after row \(index)")
            XCTAssertGreaterThanOrEqual(change.from, opened - 4, "row \(index) refolded more than the last turns")
        }
        let previous = groups(fold.rows)
        timeline.revise("a200")
        let change = update(&fold, timeline, changed: ["a200"], previous: previous)
        XCTAssertEqual(fold.rows, fullFold(timeline, previous: previous))
        XCTAssertGreaterThanOrEqual(change.from, opened - 4)

        let closing = F.turnEnd("e200", turn: "t200")
        timeline.append(closing)
        _ = update(&fold, timeline, changed: [closing.id.item], previous: groups(fold.rows))
        XCTAssertTrue(fold.rows.suffix(4).contains { ChatTurnCollapse.isSummary($0.id) }, "the finished turn folds")
    }

    func testAChangeInAnOlderTurnExpandingOrRemovingRefoldsFromWhereItIs() throws {
        var timeline = Timeline()
        for index in 0..<20 { turn(index).forEach { timeline.append($0) } }
        var fold = ChatTimelineFold()
        _ = update(&fold, timeline, changed: Set(timeline.order), previous: [:])

        var previous = groups(fold.rows)
        timeline.revise("a3")
        let change = update(&fold, timeline, changed: ["a3"], previous: previous)
        XCTAssertEqual(fold.rows, fullFold(timeline, previous: previous))
        XCTAssertGreaterThan(change.from, 0)
        XCTAssertLessThan(change.from, fold.rows.count / 2)

        previous = groups(fold.rows)
        let summary = try XCTUnwrap(fold.rows.first { ChatTurnCollapse.isSummary($0.id) }).id
        _ = update(&fold, timeline, changed: [], expanded: [summary], previous: previous)
        XCTAssertEqual(fold.rows, fullFold(timeline, expanded: [summary], previous: previous))

        previous = groups(fold.rows)
        timeline.order.removeAll { $0 == "s5a" }
        timeline.rows["s5a"] = nil
        let removal = update(&fold, timeline, changed: [], removed: ["s5a"], expanded: [summary], previous: previous)
        XCTAssertEqual(removal.from, 0)
        XCTAssertEqual(fold.rows, fullFold(timeline, expanded: [summary], previous: previous))
    }

    func testOlderHistoryArrivingAboveRefoldsEverything() {
        var timeline = Timeline()
        for index in 10..<20 { turn(index).forEach { timeline.append($0) } }
        var fold = ChatTimelineFold()
        _ = update(&fold, timeline, changed: Set(timeline.order), previous: [:])
        var older = Timeline()
        for index in 0..<10 { turn(index).forEach { older.append($0) } }
        older.order += timeline.order
        older.rows.merge(timeline.rows) { $1 }
        let previous = groups(fold.rows)
        let change = update(&fold, older, changed: Set(older.order.prefix(50)), previous: previous)
        XCTAssertEqual(change.from, 0)
        XCTAssertEqual(fold.rows, fullFold(older, previous: previous))
    }
}
