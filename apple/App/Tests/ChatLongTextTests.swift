import Foundation
import HostKit
import XCTest
@testable import App

@MainActor
final class ChatLongTextTests: XCTestCase {
    func testALongReplyRendersItsPreviewAsMarkdownFollowedByShowAll() throws {
        let item = try longText(role: "Assistant", preview: "# Start\n\nThe first **part** of the reply.")
        let rows = RowBuilder().rows(for: item)
        XCTAssertEqual(rows.count, 3)
        let blocks = rows.dropLast().compactMap { row -> ChatMarkdownBlock.Kind? in
            guard case .markdown(let block) = row.content else { return nil }
            return block.kind
        }
        XCTAssertEqual(blocks, [.heading(1), .paragraph])
        guard case .showAll(let longText) = rows.last?.content else { return XCTFail("Missing Show all") }
        XCTAssertEqual(rows.last?.id, ChatRowID(item: item.id, part: 2))
        XCTAssertEqual(longText.content.handle, "1:2:item:reply")
        let size = ByteCountFormatter.string(fromByteCount: 2_097_152, countStyle: .file)
        XCTAssertEqual(ChatLongText.showAllTitle(longText.content), "Show all " + size)
        XCTAssertEqual(ChatLongText.title(longText.role), "Reply")
    }

    func testUserAndThinkingTextKeepTheirRowAndUnknownRolesReadAsReplies() throws {
        let user = RowBuilder().rows(for: try longText(role: "User", preview: "# Not a heading"))
        XCTAssertEqual(user.count, 2)
        guard case .item(let item) = user.first?.content, case .longText(let message) = item.body else {
            return XCTFail("Missing message preview")
        }
        XCTAssertEqual(ChatLongText.title(message.role), "Message")
        guard case .showAll = user.last?.content else { return XCTFail("Missing Show all") }

        let thinking = RowBuilder().rows(for: try longText(role: "Thinking", preview: "Reasoning"))
        XCTAssertEqual(thinking.count, 2)
        guard case .item = thinking.first?.content else { return XCTFail("Missing thinking preview") }

        let future = RowBuilder().rows(for: try longText(role: "Summary", preview: "Plain words"))
        guard case .markdown = future.first?.content, case .showAll(let summary) = future.last?.content else {
            return XCTFail("Unknown roles should read as replies")
        }
        XCTAssertEqual(ChatLongText.title(summary.role), "Reply")
    }

    func testTheWholeTextLoadsInPagesThroughItsHandle() async throws {
        let whole = String(repeating: "word ", count: 30_000)
        let item = try longText(role: "Assistant", preview: "word word", bytes: UInt64(whole.utf8.count))
        guard case .showAll(let longText) = RowBuilder().rows(for: item).last?.content else {
            return XCTFail("Missing Show all")
        }
        var requests: [(handle: String, offset: UInt64)] = []
        let reader = ChatOutputReader { offset, length in
            requests.append((longText.content.handle, offset))
            let end = min(whole.utf8.count, Int(offset) + Int(length))
            let text = String(decoding: Array(whole.utf8)[Int(offset)..<end], as: UTF8.self)
            return try TimelineFixtureJSON.json([
                "text": text, "total_bytes": whole.utf8.count,
                "next_offset": end < whole.utf8.count ? end as Any : NSNull()
            ])
        }
        var loaded = ""
        var offset: UInt64? = 0
        while let next = offset {
            await reader.load(offset: next)
            let page = try XCTUnwrap(reader.page)
            XCTAssertEqual(page.offset, next)
            XCTAssertEqual(page.totalBytes, longText.content.bytes)
            loaded += page.text
            offset = page.nextOffset
        }
        XCTAssertEqual(loaded, whole)
        XCTAssertEqual(requests.map(\.offset), [0, 65_536, 131_072])
        XCTAssertTrue(requests.allSatisfy { $0.handle == "1:2:item:reply" })
        XCTAssertEqual(reader.previousOffset, 65_536)
    }

    private func longText(role: String, preview: String, bytes: UInt64 = 2_097_152) throws -> TimelineItem {
        try TimelineJSON.decode(TimelineItem.self, from: TimelineFixtureJSON.json([
            "id": "reply", "revision": 1, "turn": "turn", "parent": NSNull(), "at": 0, "origin": "Agent",
            "body": ["LongText": ["role": role, "content": ["handle": "1:2:item:reply", "preview": preview, "bytes": bytes]]]
        ]))
    }
}
