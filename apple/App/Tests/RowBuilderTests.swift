import Foundation
import HostKit
import XCTest
@testable import App

@MainActor
final class RowBuilderTests: XCTestCase {
    func testMarkdownBlocksAreIndependentRowsWithStableIdentifiers() async throws {
        let builder = RowBuilder()
        let markdown = """
        # Heading

        A **strong** paragraph with [a link](https://example.com).

        - First
          - Nested
        - [x] Finished

        > A quote

        ```rust
        fn main() {}
        ```

        | Name | State |
        | --- | --- |
        | Tests | Passed |

        ---

        <div>Literal HTML</div>
        """
        let item = try assistant(markdown)
        let rows = await builder.rows(for: item)
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(Set(rows.map(\.id)).count, 8)
        let blocks = rows.compactMap { row -> ChatMarkdownBlock? in
            guard case .markdown(let block) = row.content else { return nil }
            return block
        }
        XCTAssertEqual(blocks.map(\.kind), [.heading(1), .paragraph, .list, .quote, .code("rust"), .table, .separator, .plain])
        XCTAssertEqual(blocks[2].list.map(\.depth), [0, 1, 0])
        XCTAssertEqual(blocks[2].list.last?.marker, "☑")
        XCTAssertEqual(String(blocks[4].text.characters), "fn main() {}\n")
        XCTAssertEqual(blocks[5].table.count, 2)
        XCTAssertEqual(String(blocks[5].table[1][1].characters).trimmingCharacters(in: .whitespacesAndNewlines), "Passed")
        XCTAssertTrue(String(blocks[7].text.characters).contains("<div>"))
        let cached = await builder.rows(for: item)
        XCTAssertEqual(cached, rows)
        let parseCount = await builder.parseCount
        XCTAssertEqual(parseCount, 1)
    }

    func testOnlyAChangedRevisionIsRebuilt() async throws {
        let builder = RowBuilder()
        let first = try assistant("First paragraph.\n\nSecond paragraph.")
        let original = await builder.rows(for: first)
        let changed = await builder.rows(for: try assistant("First paragraph.\n\nChanged paragraph.", revision: 2))
        XCTAssertEqual(original.map(\.id), changed.map(\.id))
        XCTAssertEqual(original.first?.content, changed.first?.content)
        XCTAssertNotEqual(original.last?.content, changed.last?.content)
        let parseCount = await builder.parseCount
        XCTAssertEqual(parseCount, 2)
    }

    func testUntrustedLinkSchemesAreNeverInteractive() async throws {
        let builder = RowBuilder()
        let rows = await builder.rows(for: try assistant("[web](https://example.com) [file](file:///private/file) [script](javascript:alert) [relative](../secret)"))
        guard case .markdown(let block) = rows.first?.content else { return XCTFail("Missing paragraph") }
        let links = block.text.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.scheme), ["https"])
    }

    func testRenderCachesStayBoundedAndCanBePurged() async throws {
        let builder = RowBuilder()
        for index in 0..<600 {
            _ = await builder.rows(for: try assistant("Paragraph \(index).", id: "message-\(index)"))
        }
        let size = await builder.cacheSize
        let bytes = await builder.cacheBytes
        XCTAssertLessThanOrEqual(size, 500)
        XCTAssertLessThanOrEqual(bytes, 4 * 1_024 * 1_024)
        await builder.remove(["message-599"])
        let reduced = await builder.cacheSize
        XCTAssertEqual(reduced, size - 1)
        await builder.clear()
        let empty = await builder.cacheSize
        XCTAssertEqual(empty, 0)
    }

    func testTheCacheLimitCountsBlocksRatherThanOnlyMessages() async throws {
        let builder = RowBuilder()
        let text = (0..<100).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        for index in 0..<10 {
            _ = await builder.rows(for: try assistant(text, id: "message-\(index)"))
        }
        let count = await builder.cacheRowCount
        XCTAssertLessThanOrEqual(count, 500)
        XCTAssertEqual(count, 500)
    }

    func testEmptyMessagesStillConsumeTheEntryBudget() async throws {
        let builder = RowBuilder()
        for index in 0..<600 {
            _ = await builder.rows(for: try assistant("", id: "empty-\(index)"))
        }
        let count = await builder.cacheSize
        XCTAssertLessThanOrEqual(count, 500)
    }

    func testIdentifierComponentsCannotCollide() {
        XCTAssertNotEqual(ChatRowID(item: "a:1", part: 2).storageKey, ChatRowID(item: "a", part: 12).storageKey)
    }

    private func assistant(_ text: String, id: String = "message", revision: UInt32 = 1) throws -> TimelineItem {
        let value: [String: Any] = [
            "id": id, "revision": revision, "turn": "turn", "parent": NSNull(), "at": 0, "origin": "Agent",
            "body": ["Assistant": ["text": text, "streaming": false]]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: value)
        return try TimelineJSON.decode(TimelineItem.self, from: String(decoding: encoded, as: UTF8.self))
    }
}
