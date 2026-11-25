import XCTest
@testable import App

final class ChatItemUpdateTests: XCTestCase {
    private func rows(_ names: [String]) -> [ChatRow] {
        names.map { name in
            let block = ChatMarkdownBlock(kind: .paragraph, source: name, text: AttributedString(name))
            return ChatRow(id: ChatRowID(item: name, part: 0), revision: 1, turn: "turn", content: .markdown(block))
        }
    }

    private func update(_ old: [String], _ new: [String], keptOrder: Int, keptTail: Int) -> ChatItemUpdate {
        ChatItemUpdate(old: rows(old).map(\.id), new: rows(new), keptOrder: keptOrder, keptTail: keptTail)
    }

    func testAStreamedRowReplacesOnlyItself() {
        XCTAssertEqual(update(["a", "b", "c"], ["a", "b", "c2"], keptOrder: 2, keptTail: 0),
                       ChatItemUpdate(removed: [2], inserted: [2]))
    }

    func testOlderHistoryArrivingAboveInsertsOnlyItsRows() {
        XCTAssertEqual(update(["c", "d"], ["a", "b", "c", "d"], keptOrder: 0, keptTail: 2),
                       ChatItemUpdate(removed: [], inserted: [0, 1]))
    }

    func testOlderHistoryAboveWithTheNewestLeavingBelowKeepsTheRowsBetween() {
        XCTAssertEqual(update(["c", "d", "e", "f"], ["a", "b", "c", "d"], keptOrder: 0, keptTail: 0),
                       ChatItemUpdate(removed: [2, 3], inserted: [0, 1]))
    }

    func testUnrelatedRowsReplaceEverything() {
        XCTAssertEqual(update(["a", "b"], ["x", "y", "z"], keptOrder: 0, keptTail: 0),
                       ChatItemUpdate(removed: [0, 1], inserted: [0, 1, 2]))
    }
}
