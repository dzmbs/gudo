import HostKit
import XCTest
@testable import App

@MainActor
final class ChatDiffSnapshotTests: XCTestCase {
    func testHunkCoordinatesAndNewlineMarkersKeepTheCorrectLineNumbers() throws {
        let value = try file(lines: [["kind": "Context", "text": "same"],
                                     ["kind": "Removed", "text": "old"],
                                     ["kind": "Added", "text": "new"],
                                     ["kind": "NoNewline", "text": ""],
                                     ["kind": "Context", "text": "after"]])
        let snapshot = try ChatDiffSnapshot(groups: [ChatToolDiff(item: "tool", files: [value])])
        let hunk = try XCTUnwrap(snapshot.files.first?.hunks.first)
        XCTAssertEqual(hunk.header, "@@ -10,3 +20,3 @@")
        XCTAssertEqual(hunk.lines.map(\.oldNumber), [10, 11, nil, nil, 12])
        XCTAssertEqual(hunk.lines.map(\.newNumber), [20, nil, 21, nil, 22])
        XCTAssertEqual(hunk.lines[3].text, "\\ No newline at end of file")
        XCTAssertTrue(try XCTUnwrap(snapshot.files.first).hunksOmitted)
    }

    func testRepeatedDisplayPathsHaveIndependentStableSnapshotIdentities() throws {
        let value = try file()
        let groups = [ChatToolDiff(item: "first:tool", files: [value]), ChatToolDiff(item: "second", files: [value])]
        let snapshot = try ChatDiffSnapshot(groups: groups)
        XCTAssertEqual(snapshot.files.map(\.path), ["shared.swift", "shared.swift"])
        XCTAssertEqual(Set(snapshot.files.map(\.id)).count, 2)
        XCTAssertEqual(try ChatDiffSnapshot(groups: groups).files.map(\.id), snapshot.files.map(\.id))
        let input = DiffRenderInput(files: snapshot.files, collapsed: [], split: false, notes: [], width: 390)
        let document = DiffRenderDocument(input: input)
        XCTAssertEqual(Set(document.rows.map(\.id)).count, document.rows.count)
    }

    func testUnknownChangesAndLineKindsCannotBecomeFamiliarSemantics() throws {
        let unknownLine = try file(lines: [["kind": "FutureLine", "text": "text"]])
        XCTAssertThrowsError(try ChatDiffSnapshot(groups: [ChatToolDiff(item: "tool", files: [unknownLine])]))
        let unknownChange = try file(change: "FutureChange")
        XCTAssertThrowsError(try ChatDiffSnapshot(groups: [ChatToolDiff(item: "tool", files: [unknownChange])]))
    }

    func testTheFileLimitAdmitsItsBoundaryAndRejectsTheEntireLargerSelection() throws {
        let value = try file()
        let accepted = try ChatDiffSnapshot(groups: [
            ChatToolDiff(item: "tool", files: Array(repeating: value, count: 128))
        ])
        XCTAssertEqual(accepted.files.count, 128)
        XCTAssertThrowsError(try ChatDiffSnapshot(groups: [ChatToolDiff(item: "tool",
            files: Array(repeating: value, count: 129))]))
    }

    func testHunkAdmissionIsBoundedIndependentlyOfFileCount() throws {
        var value = try file()
        let hunk = try XCTUnwrap(value.hunks.first)
        value.hunks = Array(repeating: hunk, count: 512)
        XCTAssertEqual(try ChatDiffSnapshot(groups: [ChatToolDiff(item: "tool", files: [value])]).files.count, 1)
        value.hunks.append(hunk)
        XCTAssertThrowsError(try ChatDiffSnapshot(groups: [ChatToolDiff(item: "tool", files: [value])]))
    }

    func testLineByteAdmissionUsesUTF8RatherThanCharacterCount() throws {
        let accepted = try file(lines: [["kind": "Added", "text": String(repeating: "é", count: 4_096)]])
        XCTAssertEqual(try ChatDiffSnapshot(groups: [ChatToolDiff(item: "tool", files: [accepted])]).files.count, 1)
        let rejected = try file(lines: [["kind": "Added", "text": String(repeating: "é", count: 4_097)]])
        XCTAssertThrowsError(try ChatDiffSnapshot(groups: [ChatToolDiff(item: "tool", files: [rejected])]))
    }

    func testAggregateDerivedBytesAreBoundedEvenWhenIndividualLinesFit() throws {
        let lines = Array(repeating: ["kind": "Added", "text": String(repeating: "x", count: 8_192)], count: 200)
        let value = try file(lines: lines)
        XCTAssertThrowsError(try ChatDiffSnapshot(groups: [ChatToolDiff(item: "tool", files: [value])]))
    }

    func testIncrementalConversionMatchesTheOneShotSelection() throws {
        let groups = try ["first", "second"].map { ChatToolDiff(item: $0, files: [try file()]) }
        var builder = ChatDiffSnapshot.Builder()
        for group in groups { try builder.append(group) }
        let expected = try ChatDiffSnapshot(groups: groups)
        XCTAssertEqual(builder.snapshot.files.map(\.id), expected.files.map(\.id))
        XCTAssertEqual(builder.snapshot.files.map(\.hunks), expected.files.map(\.hunks))
    }

    func testStagedIncrementalConversionKeepsTheAggregateBudgetAndItsAdmittedPrefix() throws {
        let lines = Array(repeating: ["kind": "Added", "text": String(repeating: "x", count: 8_192)], count: 100)
        let value = try file(lines: lines)
        var builder = ChatDiffSnapshot.Builder()
        try builder.append(ChatToolDiff(item: "first", files: [value]))
        var staged = builder
        XCTAssertThrowsError(try staged.append(ChatToolDiff(item: "second", files: [value])))
        XCTAssertEqual(builder.snapshot.files.count, 1)
        XCTAssertEqual(builder.snapshot.files[0].hunks[0].lines.count, 100)
    }

    private func file(change: String = "Modified",
                      lines: [[String: String]] = [["kind": "Added", "text": "new"]]) throws -> TimelineFileDiff {
        let hunk: [String: Any] = ["old_start": 10, "old_lines": 3, "new_start": 20, "new_lines": 3,
                                    "header": "", "lines": lines]
        let json = try TimelineFixtureJSON.json([
            "path": "shared.swift", "change": change, "binary": false,
            "additions": 1, "deletions": 1, "hunks": [hunk], "hunks_omitted": true
        ])
        return try TimelineJSON.decode(TimelineFileDiff.self, from: json)
    }
}
