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

    private func toolRow(_ identifier: String, turn: String, path: String) throws -> ChatRow {
        let file: [String: Any] = ["path": path, "change": "Modified", "binary": false,
                                    "additions": 1, "deletions": 0, "hunks": [], "hunks_omitted": false]
        let tool: [String: Any] = ["kind": "Edit", "name": "Edit", "title": "Edit file", "input": "",
                                    "status": "Done", "diff": [file]]
        let json = try TimelineFixtureJSON.json(["id": identifier, "revision": 1, "turn": turn,
                                                  "at": 0, "origin": "Agent", "body": ["Tool": tool]])
        let item = try TimelineJSON.decode(TimelineItem.self, from: json)
        return ChatRow(id: ChatRowID(item: identifier, part: 0), revision: 1, turn: turn, content: .item(item))
    }
}
