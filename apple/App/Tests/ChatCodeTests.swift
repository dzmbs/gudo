#if os(iOS)
import ChatSyntax
import DesignSystem
import HostKit
import SwiftUI
import XCTest
@testable import App

@MainActor final class ChatCodeTests: XCTestCase {
    func testBothAgentMessagesUseWorkerPreparedColoursWithoutChangingCopyText() async throws {
        let builder = RowBuilder()
        let source = "// Native colours\nfn greet() { let text = \"Hello 👋\"; }\n"
        for agent in ["claude", "codex"] {
            let rendered = await builder.render(try assistant("```rust\n" + source + "```", id: agent))
            let row = try XCTUnwrap(rendered.rows.first)
            guard case .markdown(let block) = row.content else { return XCTFail("Expected code") }
            let code = try XCTUnwrap(block.code)
            XCTAssertEqual(code.text, source)
            XCTAssertEqual(code.preview, source)
            XCTAssertFalse(code.highlights.isEmpty, "Grammar/query bundle must be present in the actual app")
            XCTAssertTrue(code.highlights.contains { $0.role == .keyword })
            XCTAssertTrue(code.highlights.contains { $0.role == .string })
            XCTAssertGreaterThanOrEqual(rendered.cost.bytes, code.highlights.count * 32)
            for themeName in ["Dracula", "Apple System Colors Light"] {
                let styled = ChatCodeStyler.text(code, theme: ThemeCatalog.theme(named: themeName), increasedContrast: false)
                XCTAssertEqual(String(styled.characters), source)
                XCTAssertTrue(styled.runs.allSatisfy { $0.link == nil })
                XCTAssertGreaterThan(Set(styled.runs.compactMap(\.foregroundColor)).count, 2)
            }
        }
    }

    func testProjectionCacheIncludesThemeAndContrastButNeverChangesGeometry() async throws {
        let rows = await RowBuilder().rows(for: try assistant("```swift\nlet projection_test = 42\n```", id: "style-cache"))
        let row = try XCTUnwrap(rows.first)
        guard case .markdown(let block) = row.content else { return XCTFail("Expected code") }
        let code = try XCTUnwrap(block.code)
        let theme = TerminalTheme.ghosttyDefault
        let first = ChatCodeStyler.text(code, theme: theme, increasedContrast: false)
        let count = ChatCodeStyler.projectionCount
        XCTAssertEqual(first, ChatCodeStyler.text(code, theme: theme, increasedContrast: false))
        XCTAssertEqual(ChatCodeStyler.projectionCount, count)
        let increased = ChatCodeStyler.text(code, theme: theme, increasedContrast: true)
        XCTAssertEqual(ChatCodeStyler.projectionCount, count + 1)
        var changed = theme
        changed.palette[5] = "#ffffff"
        _ = ChatCodeStyler.text(code, theme: changed, increasedContrast: false)
        XCTAssertEqual(ChatCodeStyler.projectionCount, count + 2)
        XCTAssertEqual(String(first.characters), String(increased.characters))
        XCTAssertLessThanOrEqual(ChatCodeStyler.cacheBytes, 512 * 1_024)
    }

    func testUnknownFenceStaysPlainAndTruncatedCodeHighlightsOnlyItsPreview() async throws {
        let builder = RowBuilder()
        for language in ["unknown", "rust"] {
            let source = String(repeating: "let greeting = \"hello 👋\";\n", count: 100)
            let rows = await builder.rows(for: try assistant("```\(language)\n" + source + "```", id: language))
            guard case .markdown(let block) = try XCTUnwrap(rows.first).content else { return XCTFail("Expected code") }
            let code = try XCTUnwrap(block.code)
            XCTAssertEqual(code.text, source)
            XCTAssertTrue(code.isTruncated)
            XCTAssertLessThanOrEqual(code.preview.utf8.count, 8_192)
            if language == "unknown" { XCTAssertTrue(code.highlights.isEmpty) }
            else { XCTAssertFalse(code.highlights.isEmpty) }
            for token in code.highlights { XCTAssertNotNil(Range(token.range, in: code.preview)) }
        }
    }

    private func assistant(_ text: String, id: String) throws -> TimelineItem {
        let value: [String: Any] = ["id": id, "revision": 1, "turn": "turn", "parent": NSNull(), "at": 0, "origin": "Agent",
            "body": ["Assistant": ["text": text, "streaming": false]]]
        let data = try JSONSerialization.data(withJSONObject: value)
        return try TimelineJSON.decode(TimelineItem.self, from: String(decoding: data, as: UTF8.self))
    }
}
#endif
