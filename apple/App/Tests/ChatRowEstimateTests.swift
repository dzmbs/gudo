import DesignSystem
import Foundation
import HostKit
import XCTest
@testable import App

final class ChatRowEstimateTests: XCTestCase {
    func testALongPromptIsEstimatedTallEnoughToShowInFull() throws {
        let prompt = String(repeating: "Explain why the tests fail on the phone. ", count: 50)
        let row = ChatRow(id: ChatRowID(item: "prompt", part: 0), revision: 1, turn: "turn", content: .item(try user(prompt)))
        let lines = ChatRowEstimate.lineCount(prompt, width: 390 - 40 - 32 - 32, scale: 1)
        XCTAssertGreaterThan(lines, 20)
        XCTAssertGreaterThanOrEqual(ChatRowEstimate.height(for: row, rowWidth: 390, scale: 1),
                                    CGFloat(lines) * ChatRowEstimate.lineHeight)
    }

    func testALongParagraphIsEstimatedByItsLength() {
        let text = String(repeating: "word ", count: 400)
        let block = ChatMarkdownBlock(kind: .paragraph, source: text, text: AttributedString(text))
        let row = ChatRow(id: ChatRowID(item: "reply", part: 0), revision: 1, turn: "turn", content: .markdown(block))
        XCTAssertGreaterThan(ChatRowEstimate.height(for: row, rowWidth: 390, scale: 1), 400)
    }

    func testAShortPromptIsOneBubbleLineAndItsFooter() throws {
        let row = ChatRow(id: ChatRowID(item: "prompt", part: 0), revision: 1, turn: "turn", content: .item(try user("Hi")))
        XCTAssertEqual(ChatRowEstimate.height(for: row, rowWidth: 390, scale: 1),
                       ChatRowEstimate.lineHeight + 2 * DS.Space.m + 2 * DS.Space.s + DS.Size.touchTarget)
    }

    func testHardLineBreaksCountAsLines() {
        XCTAssertEqual(ChatRowEstimate.lineCount("one\ntwo\n\nfour", width: 300, scale: 1), 4)
    }

    private func user(_ text: String) throws -> TimelineItem {
        let value: [String: Any] = [
            "id": "prompt", "revision": 1, "turn": "turn", "parent": NSNull(), "at": 0, "origin": "Terminal",
            "body": ["User": ["text": text, "attachments": [], "queued": false]],
        ]
        let encoded = try JSONSerialization.data(withJSONObject: value)
        return try TimelineJSON.decode(TimelineItem.self, from: String(decoding: encoded, as: UTF8.self))
    }
}
