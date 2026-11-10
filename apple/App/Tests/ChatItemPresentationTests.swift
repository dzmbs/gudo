#if os(iOS)
import Foundation
import HostKit
import XCTest
@testable import App

@MainActor
final class ChatItemPresentationTests: XCTestCase {
    func testAllToolStatusesStayDistinctAndUnknownStatusDoesNotAcquireSuccess() throws {
        for (status, label) in [("Running", "Running"), ("Done", "Completed"), ("Failed", "Failed"),
                                ("Denied", "Denied"), ("Interrupted", "Interrupted"), ("FutureStatus", "Status unavailable")] {
            let tool = try tool(status: status)
            XCTAssertEqual(ChatItemPresentation.toolStatus(tool), label)
        }
    }

    func testToolKindsAndTitlesAreLiteralAndBounded() throws {
        for (kind, label) in [("Shell", "Command"), ("Read", "Read"), ("Search", "Search"), ("Edit", "Edit"),
                              ("Write", "Write"), ("Fetch", "Fetch"), ("WebSearch", "Web search"),
                              ("Mcp", "MCP tool"), ("Task", "Subagent"), ("Other", "Tool"), ("FutureKind", "Tool")] {
            var tool = try tool(kind: kind)
            XCTAssertEqual(ChatItemPresentation.toolKind(tool), label)
            tool.title = String(repeating: "漢", count: 1_000)
            let title = ChatItemPresentation.toolTitle(tool)
            XCTAssertEqual(title.unicodeScalars.count, 513)
            XCTAssertTrue(title.hasSuffix("…"))
            XCTAssertEqual(tool.title.count, 1_000)
        }
    }

    func testEmptyAndRedactedThinkingHaveNoExpansionAndDoNotInventDuration() throws {
        for text in [nil, ""] as [String?] {
            let thinking = try thinking(text: text)
            XCTAssertFalse(ChatItemPresentation.hasThinkingText(thinking))
            XCTAssertEqual(ChatItemPresentation.thinkingTitle(thinking), "Thinking text unavailable")
        }
        let timed = try thinking(text: "Literal **thought**", duration: 12_345)
        XCTAssertTrue(ChatItemPresentation.hasThinkingText(timed))
        XCTAssertEqual(ChatItemPresentation.thinkingTitle(timed), "Thought for 12s")
        XCTAssertEqual(ChatItemPresentation.duration(UInt64.max), "307445734561825m 51s")
    }

    func testInlineDiffIsPreparedOffMainWithSixBoundedLinesAndChargedToTheRenderCache() async throws {
        var tool = try tool(kind: "Edit")
        let lines = (0..<12).map { _ in ["kind": "Added", "text": String(repeating: "漢", count: 1_000)] }
        let value: [String: Any] = ["path": "Sources/Chat.swift", "change": "Modified", "binary": false,
            "additions": 12, "deletions": 0, "hunks_omitted": false,
            "hunks": [["old_start": 1, "old_lines": 0, "new_start": 1, "new_lines": 12, "header": "@@ -1,0 +1,12 @@", "lines": lines]]]
        tool.diff = try JSONDecoder().decode([TimelineFileDiff].self, from: JSONSerialization.data(withJSONObject: [value]))
        let item = try item(tool)
        let builder = RowBuilder()
        let rendered = builder.render(item)
        let preview = try XCTUnwrap(rendered.rows.first?.inlineDiff)
        XCTAssertEqual(preview.file.hunks.first?.lines.count, 6)
        XCTAssertTrue(preview.file.hunksOmitted)
        XCTAssertEqual(preview.file.hunks.first?.lines.first?.text.unicodeScalars.count, 513)
        XCTAssertGreaterThanOrEqual(rendered.cost.bytes - TimelineValueWeight.of(item), preview.bytes)
        XCTAssertEqual(tool.diff.first?.hunks.first?.lines.first?.text.count, 1_000)
        let cached = builder.render(item)
        XCTAssertEqual(cached.rows, rendered.rows)
        XCTAssertEqual(cached.cost, rendered.cost)
        tool.diff[0].change = .unknown("FutureChange")
        XCTAssertNil(ChatInlineDiff(tool: tool, item: "unknown"))
    }

    func testToolSelectionLabelsNeverClaimAnOutputPreviewIsComplete() async throws {
        var tool = try tool()
        let value: [String: Any] = ["handle": "fixture", "preview": "Only a tail", "bytes": 10_000]
        tool.output = try JSONDecoder().decode(TimelineOutputReference.self, from: JSONSerialization.data(withJSONObject: value))
        let rows = RowBuilder().rows(for: try item(tool))
        let row = try XCTUnwrap(rows.first)
        let view = ChatRowView(row: row, isExpanded: true, toggle: {}, actions: ChatRowActions())
        XCTAssertEqual(view.copyTitle, "Copy input and output preview")
        XCTAssertEqual(view.selectionTitle, "Select input and output preview")
        XCTAssertEqual(view.plainText, "input\nOnly a tail")
    }

    private func tool(kind: String = "Shell", status: String = "Done") throws -> TimelineTool {
        let value: [String: Any] = ["kind": kind, "name": "Example", "title": "Literal **title**", "input": "input",
                                   "status": status, "diff": []]
        return try JSONDecoder().decode(TimelineTool.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func thinking(text: String?, duration: UInt64? = nil) throws -> TimelineThinking {
        var value: [String: Any] = [:]
        value["text"] = text
        value["duration_ms"] = duration
        return try JSONDecoder().decode(TimelineThinking.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func item(_ tool: TimelineTool) throws -> TimelineItem {
        let tool = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool))
        let value: [String: Any] = ["id": "tool", "revision": 1, "at": 1, "origin": "Agent", "body": ["Tool": tool]]
        return try JSONDecoder().decode(TimelineItem.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
#endif
