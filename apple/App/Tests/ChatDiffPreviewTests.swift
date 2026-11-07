import HostKit
import XCTest
@testable import App

@MainActor
final class ChatDiffPreviewTests: XCTestCase {
    func testPathPreviewRetainsOnlyTheMatchingFiles() throws {
        let rows = try [toolRow("first", turn: "turn-a", path: "a.swift"),
                        toolRow("second", turn: "turn-b", path: "b.swift")]
        XCTAssertEqual(ChatDiffPreview.files(matching: "a.swift", rows: rows).map(\.path), ["a.swift"])
    }

    func testLegacyUnfilteredPreviewRetainsAllVisibleToolFiles() throws {
        let rows = try [toolRow("first", turn: "turn-a", path: "a.swift"),
                        toolRow("second", turn: "turn-b", path: "b.swift")]
        XCTAssertEqual(ChatDiffPreview.files(matching: nil, rows: rows).map(\.path), ["a.swift", "b.swift"])
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
