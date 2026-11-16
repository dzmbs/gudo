import Foundation
import HostKit
import XCTest
@testable import App

final class ChatToolGroupsTests: XCTestCase {
    func testConsecutiveToolCallsFoldIntoOneSummaryLine() throws {
        let rows = try [
            reply("before"), tool("a", kind: "Shell"), tool("b", kind: "Shell"), tool("c", kind: "Read"),
            tool("d", kind: "Shell", status: "Failed"), tool("e", kind: "Read"), reply("after"),
        ]
        let folded = ChatToolGroups.fold(rows, expanded: [])
        XCTAssertEqual(folded.count, 3)
        guard case .toolGroup(let group) = folded[1].content else { return XCTFail("Missing group") }
        XCTAssertEqual(group.summary, "Ran 3 commands, read 2 files (1 failed)")
        XCTAssertEqual(group.tools.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertTrue(ChatToolGroups.isGroup(folded[1].id))
        XCTAssertEqual(ChatRowSpacing.role(of: folded[1]), .work)
    }

    func testTheOutcomeIsSeparateSoTheLineCanColourIt() throws {
        let rows = try [tool("a", kind: "Shell"), tool("b", kind: "Shell", status: "Failed"), tool("c", kind: "Read", status: "Denied")]
        let tools = rows.compactMap { row -> TimelineTool? in
            guard case .item(let item) = row.content, case .tool(let tool) = item.body else { return nil }
            return tool
        }
        XCTAssertEqual(ChatToolGroups.actions(tools), "Ran 2 commands, read a file")
        XCTAssertEqual(ChatToolGroups.outcome(tools), "1 failed, 1 denied")
        XCTAssertEqual(ChatToolGroups.summary(tools), "Ran 2 commands, read a file (1 failed, 1 denied)")
        XCTAssertNil(ChatToolGroups.outcome(Array(tools.prefix(1))))
    }

    func testExpandingAGroupShowsEveryCallUnderItsLine() throws {
        let rows = try [tool("a", kind: "Shell"), tool("b", kind: "Search")]
        let identifier = try XCTUnwrap(ChatToolGroups.fold(rows, expanded: []).first?.id)
        let expanded = ChatToolGroups.fold(rows, expanded: [identifier])
        XCTAssertEqual(expanded.map(\.id.item), [identifier.item, "a", "b"])
    }

    func testARunningGroupKeepsItsLiveCallVisible() throws {
        let rows = try [tool("a", kind: "Shell"), tool("b", kind: "Read"), tool("c", kind: "Shell", status: "Running")]
        let folded = ChatToolGroups.fold(rows, expanded: [])
        XCTAssertEqual(folded.count, 2)
        guard case .toolGroup(let group) = folded[0].content else { return XCTFail("Missing group") }
        XCTAssertEqual(group.summary, "Ran a command, read a file")
        XCTAssertEqual(folded[1].id.item, "c")
        let alone = try [tool("a", kind: "Shell", status: "Running"), tool("b", kind: "Shell", status: "Running")]
        XCTAssertEqual(ChatToolGroups.fold(alone, expanded: []).map(\.id.item), ["a", "b"])
    }

    func testASingleCallAndAnImageReadStayTheirOwnRows() throws {
        let single = try [reply("before"), tool("a", kind: "Shell"), reply("after")]
        XCTAssertEqual(ChatToolGroups.fold(single, expanded: []).map(\.id.item), ["before", "a", "after"])
        var image = try tool("image", kind: "Read", input: #"{"file_path":"/tmp/shot.png"}"#)
        image.imagePath = "/tmp/shot.png"
        let rows = try [tool("a", kind: "Shell"), image, tool("b", kind: "Shell")]
        XCTAssertEqual(ChatToolGroups.fold(rows, expanded: []).map(\.id.item), ["a", "image", "b"])
    }

    func testAGroupLineChangesRevisionOnlyWhenItsSummaryChanges() throws {
        let rows = try [tool("a", kind: "Shell"), tool("b", kind: "Shell")]
        let first = try XCTUnwrap(ChatToolGroups.fold(rows, expanded: []).first)
        let previous = [first.id: first]
        XCTAssertEqual(ChatToolGroups.fold(rows, expanded: [], previous: previous).first?.revision, first.revision)
        let grown = try rows + [tool("c", kind: "Edit")]
        let next = try XCTUnwrap(ChatToolGroups.fold(grown, expanded: [], previous: previous).first)
        XCTAssertEqual(next.id, first.id)
        XCTAssertGreaterThan(next.revision, first.revision)
    }

    func testSummariesNameEachKindInPlainWords() throws {
        let tools = try ["Edit", "Edit", "Write", "WebSearch", "Fetch", "Task", "Mcp", "Other", "FutureKind"].enumerated()
            .map { index, kind in try toolBody(tool("\(index)", kind: kind)) }
        XCTAssertEqual(ChatToolGroups.summary(tools),
                       "Made 2 edits, wrote a file, searched the web, fetched a page, ran a subagent, used 3 tools")
        let outcomes = try [tool("a", kind: "Shell", status: "Denied"), tool("b", kind: "Shell", status: "Interrupted")]
            .map(toolBody)
        XCTAssertEqual(ChatToolGroups.summary(outcomes), "Ran 2 commands (1 denied, 1 interrupted)")
    }

    func testTheWorkerFoldsAndExpandsGroupsAndListsTheRowsItUncovers() async throws {
        let worker = TimelineRenderWorker(pane: 7)
        let snapshot = try snapshotJSON([
            item("a", body: toolValue(kind: "Shell")), item("b", body: toolValue(kind: "Read")),
            item("reply", body: ["Assistant": ["text": "Done.", "streaming": false]]),
        ])
        let folded = try await worker.apply([.snapshot(snapshot)], resetsSnapshot: true, protectsHistory: false)
        XCTAssertEqual(folded.frame.rows.count, 2)
        let group = try XCTUnwrap(folded.frame.rows.first?.id)
        let expanded = try await worker.apply([.regroup], resetsSnapshot: false, protectsHistory: false, expanded: [group])
        XCTAssertEqual(expanded.frame.rows.map(\.id.item), [group.item, "a", "b", "reply"])
        XCTAssertEqual(Set(expanded.frame.changedRows?.map(\.id.item) ?? []), ["a", "b"])
        XCTAssertNotEqual(expanded.frame.orderRevision, folded.frame.orderRevision)
        let diffs = ChatDiffPreview.groups(for: .turn("turn"), rows: expanded.frame.rows)
        XCTAssertEqual(diffs.map(\.item), ["a", "b"])
    }

    private func reply(_ id: String) throws -> ChatRow {
        try row(item(id, body: ["Assistant": ["text": "text", "streaming": false]]))
    }

    private func tool(_ id: String, kind: String, status: String = "Done", input: String = "{}") throws -> ChatRow {
        try row(item(id, body: toolValue(kind: kind, status: status, input: input)))
    }

    private func toolBody(_ row: ChatRow) throws -> TimelineTool {
        guard case .item(let item) = row.content, case .tool(let tool) = item.body else { throw CancellationError() }
        return tool
    }

    private func toolValue(kind: String, status: String = "Done", input: String = "{}") -> [String: Any] {
        ["Tool": ["kind": kind, "name": kind, "title": kind, "input": input, "status": status, "output": NSNull(),
                  "diff": [], "exit": NSNull(), "duration_ms": NSNull(), "command_mark": NSNull()]]
    }

    private func item(_ id: String, body: [String: Any]) -> [String: Any] {
        ["id": id, "revision": 1, "turn": "turn", "parent": NSNull(), "at": 0, "origin": "Agent", "body": body]
    }

    private func row(_ value: [String: Any]) throws -> ChatRow {
        let encoded = try JSONSerialization.data(withJSONObject: value)
        let item = try TimelineJSON.decode(TimelineItem.self, from: String(decoding: encoded, as: UTF8.self))
        return ChatRow(id: ChatRowID(item: item.id, part: 0), revision: 1, turn: item.turn, content: .item(item))
    }

    private func snapshotJSON(_ items: [[String: Any]]) throws -> String {
        let value: [String: Any] = [
            "cursor": ["epoch": 1, "sequence": 1],
            "session": ["agent": "Claude", "native_session": "session", "title": NSNull(), "model": NSNull(),
                        "permission_mode": NSNull(), "commands": []],
            "items": items, "before": NSNull(),
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
