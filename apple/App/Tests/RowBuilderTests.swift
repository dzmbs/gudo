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
        XCTAssertEqual(String(blocks[3].text.characters).trimmingCharacters(in: .whitespacesAndNewlines), "A quote")
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
        XCTAssertEqual(original.first, changed.first)
        XCTAssertNotEqual(original.last?.content, changed.last?.content)
        let parseCount = await builder.parseCount
        XCTAssertEqual(parseCount, 2)
    }

    func testAppendOnlyUpdatesParseOnlyTheLastTopLevelBlock() async throws {
        let builder = RowBuilder()
        let source = (0..<200).map { "Finished paragraph \($0)." }.joined(separator: "\n\n") + "\n\nMutable tail"
        let original = await builder.rows(for: try assistant(source))
        let before = await builder.parsedBytes
        let updated = await builder.rows(for: try assistant(source + " grows", revision: 2))
        let parsed = await builder.parsedBytes - before
        XCTAssertLessThan(parsed, 128, "Appending a tail must not parse the completed 200-block prefix")
        XCTAssertEqual(original.first, updated.first)
        XCTAssertEqual(original.dropLast(), updated.dropLast())
    }

    func testTailPartitionPreservesUnicodeCRLFAndIndentedCode() async throws {
        let builder = RowBuilder()
        let source = "🙂 first\r\n\r\n    let value = 1\r\n"
        _ = await builder.rows(for: try assistant(source))
        let updatedSource = source + "    let next = 2\r\n"
        let updated = await builder.rows(for: try assistant(updatedSource, revision: 2))
        let fresh = RowBuilder()
        let canonical = await fresh.rows(for: try assistant(updatedSource, revision: 2))
        XCTAssertEqual(updated.map(\.content), canonical.map(\.content))
        XCTAssertEqual(updated.map(\.id), canonical.map(\.id))
    }

    func testIncrementalPartitionsMatchCanonicalParsingAcrossChunkBoundaries() async throws {
        let sources = [
            "🙂 title\n---\n\nFirst *paragraph*.\n\n- Parent\n  - Nested\n\n  More parent text.\n\n```swift\nlet value = 1\n```\n\n| Name | State |\n| --- | --- |\n| A | Done |\n\nAfter table.\n",
            "Before.\r\n\r\n<div>\r\nLiteral HTML.\r\n</div>\r\n\r\nAfter.\r\n\r\n    indented code\r\n    more code\r\n",
            "\u{feff}第一段。\n\n> Quoted\n> continuation\n\nFinal **paragraph**.\n"
        ]
        for (sourceIndex, source) in sources.enumerated() {
            let builder = RowBuilder()
            let characters = Array(source)
            let boundaries = Array(stride(from: 1, through: characters.count, by: 3)) + [characters.count]
            for end in boundaries {
                let item = try assistant(String(characters.prefix(end)), id: "replay-\(sourceIndex)", revision: UInt32(end))
                let incremental = await builder.rows(for: item)
                let canonical = await RowBuilder().rows(for: item)
                XCTAssertEqual(incremental.map(\.content), canonical.map(\.content), "Source \(sourceIndex), character \(end)")
                XCTAssertEqual(incremental.map(\.id), canonical.map(\.id))
            }
        }
    }

    func testAnAuthoritativeRewriteDiscardsTheFrozenPrefix() async throws {
        let builder = RowBuilder()
        _ = await builder.rows(for: try assistant("Original prefix.\n\nMutable tail."))
        let rewritten = "Different prefix.\n\nDifferent tail."
        let before = await builder.parsedBytes
        let rows = await builder.rows(for: try assistant(rewritten, revision: 2))
        let parsed = await builder.parsedBytes - before
        XCTAssertEqual(parsed, rewritten.utf8.count)
        guard case .markdown(let block) = rows.first?.content else { return XCTFail("Missing rewritten paragraph") }
        XCTAssertEqual(block.source, "Different prefix.")
    }

    func testReferenceDefinitionsRetainTheSourceWideParserFallback() async throws {
        let builder = RowBuilder()
        let source = "Read [the guide][guide].\n\nAnother paragraph."
        _ = await builder.rows(for: try assistant(source))
        let updated = source + "\n\n[guide]: https://example.com\n"
        let before = await builder.parsedBytes
        _ = await builder.rows(for: try assistant(updated, revision: 2))
        let parsed = await builder.parsedBytes - before
        XCTAssertEqual(parsed, updated.utf8.count)
    }

    func testLongListsAndParagraphsBecomeBoundedNativeRows() async throws {
        let builder = RowBuilder()
        let list = (0..<1_001).map { "- Entry \($0)" }.joined(separator: "\n")
        let rows = await builder.rows(for: try assistant(list))
        let blocks = rows.compactMap { row -> ChatMarkdownBlock? in
            if case .markdown(let block) = row.content { return block }
            return nil
        }
        XCTAssertEqual(blocks.count, 51)
        XCTAssertTrue(blocks.allSatisfy { $0.list.count <= 20 })
        XCTAssertEqual(blocks.flatMap(\.list).count, 1_001)
        let paragraph = String(repeating: "bounded ", count: 2_000)
        let paragraphs = await builder.rows(for: try assistant(paragraph, id: "long-paragraph"))
        let texts = paragraphs.compactMap { row -> AttributedString? in
            if case .markdown(let block) = row.content { return block.text }
            return nil
        }
        XCTAssertTrue(texts.allSatisfy { $0.characters.count <= 2_048 })
        XCTAssertEqual(texts.map { String($0.characters) }.joined().trimmingCharacters(in: .whitespacesAndNewlines), paragraph.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testCodePreviewsArePreparedOffMainAndKeepTheFullSource() async throws {
        let builder = RowBuilder()
        let code = (0..<100).map { "print(\($0))" }.joined(separator: "\n")
        let rows = await builder.rows(for: try assistant("```swift\n\(code)\n```"))
        guard case .markdown(let block) = rows.first?.content else { return XCTFail("Missing code") }
        XCTAssertEqual(block.code?.text, code + "\n")
        XCTAssertEqual(block.code?.lineCount, 101)
        XCTAssertEqual(block.code?.preview.split(separator: "\n").count, 30)
    }

    func testLongSingleLineCodeHasAByteBoundedUTF8Preview() async throws {
        let builder = RowBuilder()
        let code = "x" + String(repeating: "🙂", count: 3_000)
        let rows = await builder.rows(for: try assistant("```text\n\(code)\n```"))
        guard case .markdown(let block) = rows.first?.content else { return XCTFail("Missing code") }
        XCTAssertEqual(block.code?.preview.utf8.count, 8_189)
        XCTAssertEqual(block.code?.visibleLineCount, 1)
        XCTAssertEqual(block.code?.isTruncated, true)
        XCTAssertFalse(block.code?.preview.contains("�") ?? true)
        XCTAssertEqual(block.code?.text, code + "\n")
    }

    func testLargeTextValuesKeepFullTextOutsideTheInlinePreview() async throws {
        let builder = RowBuilder()
        let text = "x" + String(repeating: "🙂", count: 3_000)
        let bodies: [[String: Any]] = [
            ["User": ["text": text, "attachments": [], "queued": false]],
            ["Thinking": ["text": text]],
            ["Notice": ["kind": "Error", "text": text]]
        ]
        for (index, body) in bodies.enumerated() {
            var item = try assistant("", id: "large-\(index)")
            let data = try JSONSerialization.data(withJSONObject: body)
            item.body = try TimelineJSON.decode(TimelineBody.self, from: String(decoding: data, as: UTF8.self))
            let rows = await builder.rows(for: item)
            XCTAssertEqual(rows.first?.preview?.utf8.count, 4_093)
            XCTAssertFalse(rows.first?.preview?.contains("�") ?? true)
            XCTAssertEqual(rows.first?.content, .item(item))
        }
    }

    func testLargePlansKeepBoundedEntriesWithoutLosingTheirFullValue() async throws {
        let builder = RowBuilder()
        let text = "x" + String(repeating: "🙂", count: 300)
        let entries = (0..<100).map { _ in ["text": text, "status": "Pending"] }
        let data = try JSONSerialization.data(withJSONObject: ["Plan": ["entries": entries]])
        var item = try assistant("")
        item.body = try TimelineJSON.decode(TimelineBody.self, from: String(decoding: data, as: UTF8.self))
        let rows = await builder.rows(for: item)
        XCTAssertEqual(rows.first?.content, .item(item))
        let preview = try XCTUnwrap(rows.first?.planPreview)
        XCTAssertEqual(preview.entries.count, 20)
        XCTAssertTrue(preview.entries.allSatisfy { $0.text.utf8.count <= 512 && !$0.text.contains("�") })
    }

    func testSparseTablesKeepTheirOriginalSourceWithoutColumnPadding() async throws {
        let builder = RowBuilder()
        let longCell = String(repeating: "x", count: 2_000)
        let source = "| Value |\n| --- |\n| \(longCell) |\n" + (0..<80).map { "| Value \($0) |" }.joined(separator: "\n")
        let rows = await builder.rows(for: try assistant(source))
        guard case .markdown(let block) = rows.first?.content else { return XCTFail("Missing table") }
        XCTAssertEqual(block.source, source)
        XCTAssertEqual(block.table.count, 9)
        XCTAssertTrue(block.hasOmittedContent)
        XCTAssertTrue(block.table.flatMap { $0 }.allSatisfy { String($0.characters).utf8.count <= 512 })
    }

    func testNestedSparseTablesCannotExpandIntoPaddedInlineText() async throws {
        let builder = RowBuilder()
        let table = "| Value |\n| --- |\n| \(String(repeating: "x", count: 2_000)) |\n" + (0..<80).map { "| Value \($0) |" }.joined(separator: "\n")
        let lines = table.split(separator: "\n")
        let sources = [lines.map { "> \($0)" }.joined(separator: "\n"),
                       "- Item\n\n" + lines.map { "  \($0)" }.joined(separator: "\n")]
        for (index, source) in sources.enumerated() {
            let rows = await builder.rows(for: try assistant(source, id: "nested-\(index)"))
            let characters = rows.reduce(0) { count, row in
                guard case .markdown(let block) = row.content else { return count }
                return count + block.text.characters.count + block.list.reduce(0) { $0 + $1.text.characters.count }
            }
            XCTAssertLessThanOrEqual(characters, source.utf8.count * 2)
        }
    }

    func testSourceRangesPreserveUnicodeAndCRLF() async throws {
        let builder = RowBuilder()
        let sources = ["🙂 αβ", "first\r\n第二段", "\u{feff}abcdef", "\u{feff}🙂 abcdef"]
        for (index, source) in sources.enumerated() {
            let rows = await builder.rows(for: try assistant(source, id: "source-\(index)"))
            guard case .markdown(let block) = rows.first?.content else { return XCTFail("Missing paragraph") }
            let markers = CharacterSet(charactersIn: "\u{feff}")
            XCTAssertEqual(block.source.trimmingCharacters(in: markers), source.trimmingCharacters(in: markers))
        }
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
