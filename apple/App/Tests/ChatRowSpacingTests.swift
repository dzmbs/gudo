import DesignSystem
import Foundation
import HostKit
import XCTest
@testable import App

final class ChatRowSpacingTests: XCTestCase {
    func testOneReplyIsTighterThanTheGapBetweenTurns() throws {
        let prompt = try row("prompt", body: ["User": ["text": "Fix it", "attachments": [], "queued": false]])
        let first = markdown("reply", part: 0)
        let second = markdown("reply", part: 1)
        let nextPrompt = try row("next", body: ["User": ["text": "Thanks", "attachments": [], "queued": false]])
        let insideReply = ChatRowSpacing.top(of: second, below: first)
        let afterPrompt = ChatRowSpacing.top(of: first, below: prompt)
        let betweenTurns = ChatRowSpacing.top(of: nextPrompt, below: second)
        XCTAssertLessThan(insideReply, afterPrompt)
        XCTAssertLessThan(afterPrompt, betweenTurns)
        XCTAssertEqual(ChatRowSpacing.top(of: prompt, below: nil), 0)
    }

    func testConsecutiveToolCallsSitTogether() throws {
        let tool: [String: Any] = ["Tool": [
            "kind": "Shell", "name": "Bash", "title": "ls", "input": "ls", "status": "Done", "output": NSNull(),
            "diff": [], "exit": NSNull(), "duration_ms": NSNull(), "command_mark": NSNull(),
        ]]
        let first = try row("first", body: tool)
        let second = try row("second", body: tool)
        XCTAssertEqual(ChatRowSpacing.role(of: first), .work)
        XCTAssertEqual(ChatRowSpacing.top(of: second, below: first), 0)
        XCTAssertEqual(ChatRowSpacing.top(of: first, below: markdown("reply", part: 0)), DS.Space.s)
    }

    func testEverySpacingIsAToken() throws {
        let tokens: Set<CGFloat> = [0, DS.Space.xxs, DS.Space.xs, DS.Space.s, DS.Space.m, DS.Space.l, DS.Space.xl,
                                    DS.Space.xxl, DS.Space.xxxl]
        let prompt = try row("prompt", body: ["User": ["text": "Fix it", "attachments": [], "queued": false]])
        let rows = [prompt, markdown("reply", part: 0), markdown("reply", part: 1), markdown("other", part: 0), prompt]
        for (previous, row) in zip(rows, rows.dropFirst()) {
            XCTAssertTrue(tokens.contains(ChatRowSpacing.top(of: row, below: previous)))
        }
    }

    private func markdown(_ item: String, part: Int) -> ChatRow {
        let block = ChatMarkdownBlock(kind: .paragraph, source: "text", text: AttributedString("text"))
        return ChatRow(id: ChatRowID(item: item, part: part), revision: 1, turn: "turn", content: .markdown(block))
    }

    private func row(_ id: String, body: [String: Any]) throws -> ChatRow {
        let value: [String: Any] = ["id": id, "revision": 1, "turn": "turn", "parent": NSNull(), "at": 0,
                                    "origin": "Agent", "body": body]
        let encoded = try JSONSerialization.data(withJSONObject: value)
        let item = try TimelineJSON.decode(TimelineItem.self, from: String(decoding: encoded, as: UTF8.self))
        return ChatRow(id: ChatRowID(item: id, part: 0), revision: 1, turn: "turn", content: .item(item))
    }
}
