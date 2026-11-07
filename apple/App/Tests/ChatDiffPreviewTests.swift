import HostKit
import XCTest
@testable import App

@MainActor
final class ChatDiffPreviewTests: XCTestCase {
    func testPathPreviewRetainsOnlyTheMatchingFiles() throws {
        let rows = try [toolRow("first", turn: "turn-a", path: "a.swift"),
                        toolRow("second", turn: "turn-b", path: "b.swift")]
        let target = ChatDiffTarget.tool(item: "first", path: "a.swift")
        XCTAssertEqual(ChatDiffPreview.files(for: target, rows: rows).map(\.path), ["a.swift"])
    }

    func testAnUnfilteredToolSelectionStillExcludesOtherTools() throws {
        let rows = try [toolRow("first", turn: "turn-a", path: "a.swift"),
                        toolRow("second", turn: "turn-b", path: "b.swift")]
        let target = ChatDiffTarget.tool(item: "first", path: nil)
        XCTAssertEqual(ChatDiffPreview.files(for: target, rows: rows).map(\.path), ["a.swift"])
    }

    func testATurnSummarySelectsOnlyItsCorrelatedTurnInsteadOfMatchingAFilePath() throws {
        let rows = try [toolRow("first", turn: "turn-a", path: "a.swift"),
                        toolRow("second", turn: "turn-b", path: "b.swift")]
        XCTAssertEqual(ChatDiffPreview.files(for: .turn("turn-a"), rows: rows).map(\.path), ["a.swift"])
    }

    func testAMissingTurnCorrelationDoesNotSelectEveryVisibleTurn() throws {
        let rows = try [toolRow("first", turn: "turn-a", path: "a.swift"),
                        toolRow("second", turn: "turn-b", path: "b.swift")]
        XCTAssertTrue(ChatDiffPreview.files(for: .turn(nil), rows: rows).isEmpty)
    }

    func testMatchingPathsDoNotCrossTheRequestedToolBoundary() throws {
        let rows = try [toolRow("first", turn: "turn-a", path: "a.swift"),
                        toolRow("second", turn: "turn-b", path: "a.swift")]
        XCTAssertEqual(ChatDiffPreview.files(for: .tool(item: "first", path: "a.swift"), rows: rows).count, 1)
        XCTAssertTrue(ChatDiffPreview.files(for: .tool(item: "missing", path: nil), rows: rows).isEmpty)
    }

    func testAnEmptyTurnIdentifierDoesNotInventCorrelation() throws {
        let rows = try [toolRow("first", turn: "", path: "a.swift")]
        XCTAssertTrue(ChatDiffPreview.files(for: .turn(""), rows: rows).isEmpty)
    }

    func testSelectedGroupsKeepTheirOwnOpaqueResultHandleRatherThanInventingOne() throws {
        let rows = try [toolRow("first", turn: "turn", path: "a.swift", handle: "7:19:tool:part"),
                        toolRow("second", turn: "turn", path: "a.swift", handle: "7:99:other")]
        let groups = ChatDiffPreview.groups(for: .tool(item: "first", path: "a.swift"), rows: rows)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].resultHandle, "7:19:tool:part")
        let missing = try toolRow("missing", turn: "turn", path: "a.swift")
        XCTAssertNil(ChatDiffPreview.groups(for: .tool(item: "missing", path: nil), rows: [missing])[0].resultHandle)
    }

    private func toolRow(_ identifier: String, turn: String, path: String, handle: String? = nil) throws -> ChatRow {
        let file: [String: Any] = ["path": path, "change": "Modified", "binary": false,
                                    "additions": 1, "deletions": 0, "hunks": [], "hunks_omitted": false]
        var tool: [String: Any] = ["kind": "Edit", "name": "Edit", "title": "Edit file", "input": "",
                                    "status": "Done", "diff": [file]]
        if let handle { tool["output"] = ["handle": handle, "bytes": 0, "preview": ""] }
        let json = try TimelineFixtureJSON.json(["id": identifier, "revision": 1, "turn": turn,
                                                  "at": 0, "origin": "Agent", "body": ["Tool": tool]])
        let item = try TimelineJSON.decode(TimelineItem.self, from: json)
        return ChatRow(id: ChatRowID(item: identifier, part: 0), revision: 1, turn: turn, content: .item(item))
    }
}
