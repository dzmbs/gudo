import Foundation
import HostKit
import XCTest
@testable import App

@MainActor
final class ChatDiffReaderTests: XCTestCase {
    func testRecordedRepliesReplacePreviewsAndKeepToolIdentityForRepeatedPaths() async throws {
        let groups = try ["first", "second"].map { try group($0) }
        var handles: [String] = []
        let reader = ChatDiffReader(groups: groups) { handle in
            handles.append(handle)
            return try self.reply(text: handle, count: 20)
        }
        await reader.preview()
        let identities = try XCTUnwrap(reader.snapshot).files.map(\.id)
        await reader.loadRecorded()
        XCTAssertEqual(handles, ["7:0:first", "7:0:second"])
        XCTAssertEqual(reader.snapshot?.files.map(\.id), identities)
        XCTAssertEqual(reader.snapshot?.files.map { $0.hunks[0].lines.count }, [20, 20])
        XCTAssertEqual(reader.snapshot?.files.map { $0.hunks[0].lines[0].text }, handles)
        XCTAssertTrue(reader.isRecorded)
        XCTAssertFalse(reader.canLoadRecorded)
        XCTAssertNil(reader.error)
    }

    func testAMissingResultHandleCannotBeReplacedWithAnItemOrTurnID() async throws {
        let value = try group("tool")
        let uncorrelated = ChatToolDiff(item: value.item, files: value.files)
        var calls = 0
        let reader = ChatDiffReader(groups: [uncorrelated]) { _ in calls += 1; return "[]" }
        await reader.preview()
        await reader.loadRecorded()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(reader.error, ChatDiffReadError.unavailable.errorDescription)
        XCTAssertFalse(reader.isRecorded)
        XCTAssertFalse(reader.canLoadRecorded)
        XCTAssertEqual(reader.snapshot?.files.count, 1)
    }

    func testIncompleteChangedAndUnknownRepliesRetainTheAdmittedPreview() async throws {
        let replies = try [reply(omitted: true), reply(path: "different.swift"), reply(change: "FutureChange"),
                           reply(kind: "FutureLine"), "not JSON"]
        for json in replies {
            let reader = ChatDiffReader(groups: [try group("tool")]) { _ in json }
            await reader.preview()
            await reader.loadRecorded()
            XCTAssertEqual(reader.snapshot?.files[0].hunks[0].lines[0].text, "preview")
            XCTAssertFalse(reader.isRecorded)
            XCTAssertTrue(reader.canLoadRecorded)
            XCTAssertNotNil(reader.error)
        }
    }

    func testAFullReplyCannotBroadenTheSelectedFilePaths() throws {
        let selected = try group("tool")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: [
            file(text: "chosen"), file(path: "other.swift", text: "unselected")
        ]), as: UTF8.self)
        let decoded = try ChatDiffReadPage.decode(json, for: selected)
        XCTAssertEqual(decoded.files.map(\.path), ["shared.swift"])
        XCTAssertThrowsError(try ChatDiffReadPage.decode(try reply(count: 0), for: ChatToolDiff(
            item: selected.item, files: selected.files + selected.files)))
    }

    func testAggregateFailureIsAtomicAndStopsBeforeFetchingAnotherTool() async throws {
        let groups = try ["first", "second", "third"].map { try group($0) }
        var calls: [String] = []
        let large = try reply(text: String(repeating: "x", count: 8_192), count: 100)
        let reader = ChatDiffReader(groups: groups) { handle in calls.append(handle); return large }
        await reader.preview()
        await reader.loadRecorded()
        XCTAssertEqual(calls, ["7:0:first", "7:0:second"])
        XCTAssertEqual(reader.snapshot?.files.count, 3)
        XCTAssertEqual(reader.snapshot?.files.map { $0.hunks[0].lines[0].text }, Array(repeating: "preview", count: 3))
        XCTAssertEqual(reader.error, ChatDiffError.tooLarge.errorDescription)
        XCTAssertFalse(reader.isRecorded)
    }

    func testAnOlderReplyCannotPublishAnErrorOrEndTheNewerLoadingState() async throws {
        let probe = DiffProbe()
        let reader = ChatDiffReader(groups: [try group("tool")], source: probe.read)
        await reader.preview()
        let older = Task { await reader.loadRecorded() }
        try await wait { probe.pending[0] != nil }
        let newer = Task { await reader.loadRecorded() }
        try await wait { probe.pending[1] != nil }
        probe.finish(0, with: "malformed JSON")
        await older.value
        XCTAssertTrue(reader.isLoading)
        XCTAssertNil(reader.error)
        probe.finish(1, with: try reply(text: "fresh"))
        await newer.value
        XCTAssertEqual(reader.snapshot?.files[0].hunks[0].lines[0].text, "fresh")
        XCTAssertTrue(reader.isRecorded)
        XCTAssertFalse(reader.isLoading)
    }

    func testALateSuccessfulReplyCannotOverwriteAlreadyLoadedRecordedChanges() async throws {
        let probe = DiffProbe()
        let reader = ChatDiffReader(groups: [try group("tool")], source: probe.read)
        let older = Task { await reader.loadRecorded() }
        try await wait { probe.pending[0] != nil }
        let newer = Task { await reader.loadRecorded() }
        try await wait { probe.pending[1] != nil }
        probe.finish(1, with: try reply(text: "fresh"))
        await newer.value
        probe.finish(0, with: try reply(text: "stale"))
        await older.value
        XCTAssertEqual(reader.snapshot?.files[0].hunks[0].lines[0].text, "fresh")
        XCTAssertNil(reader.error)
        XCTAssertTrue(reader.isRecorded)
    }

    func testCancelledAndStoppedRequestsCannotReplaceThePreview() async throws {
        for stopReader in [false, true] {
            let probe = DiffProbe()
            let reader = ChatDiffReader(groups: [try group("tool")], source: probe.read)
            await reader.preview()
            let task = Task { await reader.loadRecorded() }
            try await wait { probe.pending[0] != nil }
            if stopReader { reader.cancel() } else { task.cancel() }
            probe.finish(0, with: try reply(text: "late"))
            await task.value
            XCTAssertEqual(reader.snapshot?.files[0].hunks[0].lines[0].text, "preview")
            XCTAssertNil(reader.error)
            XCTAssertFalse(reader.isLoading)
            XCTAssertFalse(reader.isRecorded)
        }
    }

    func testOversizedEnvelopesAreRejectedBeforeJSONDecoding() async throws {
        let json = String(repeating: " ", count: ChatDiffLimits.jsonBytes) + "[]"
        let reader = ChatDiffReader(groups: [try group("tool")]) { _ in json }
        await reader.loadRecorded()
        XCTAssertNil(reader.snapshot)
        XCTAssertEqual(reader.error, ChatDiffError.tooLarge.errorDescription)
    }

    func testWorstCaseJSONStringEscapesStillFitAnAdmittedSelection() async throws {
        let json = try reply(text: String(repeating: "\0", count: 8_192), count: 100)
        let reader = ChatDiffReader(groups: [try group("tool")]) { _ in json }
        await reader.loadRecorded()
        XCTAssertNil(reader.error)
        XCTAssertEqual(reader.snapshot?.files[0].hunks[0].lines.count, 100)
        XCTAssertTrue(reader.isRecorded)
    }

    private func group(_ item: String) throws -> ChatToolDiff {
        let value = try TimelineJSON.decode(TimelineFileDiff.self, from: TimelineFixtureJSON.json(
            file(text: "preview", omitted: true)))
        return ChatToolDiff(item: item, files: [value], resultHandle: "7:0:\(item)")
    }

    private func reply(path: String = "shared.swift", text: String = "complete", count: Int = 1,
                       omitted: Bool = false, change: String = "Modified", kind: String = "Added") throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [
            file(path: path, text: text, count: count, omitted: omitted, change: change, kind: kind)
        ]), as: UTF8.self)
    }

    private func file(path: String = "shared.swift", text: String, count: Int = 1,
                      omitted: Bool = false, change: String = "Modified", kind: String = "Added") -> [String: Any] {
        ["path": path, "change": change, "binary": false, "additions": count, "deletions": 0,
         "hunks_omitted": omitted, "hunks": [["old_start": 0, "old_lines": 0, "new_start": 1, "new_lines": count,
             "header": "", "lines": Array(repeating: ["kind": kind, "text": text], count: count)]]]
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Recorded diff request did not start")
        throw CancellationError()
    }
}

@MainActor
private final class DiffProbe {
    var pending: [Int: CheckedContinuation<String, any Error>] = [:]
    private var next = 0

    func read(_ handle: String) async throws -> String {
        let identifier = next
        next += 1
        return try await withCheckedThrowingContinuation { pending[identifier] = $0 }
    }

    func finish(_ identifier: Int, with json: String) { pending.removeValue(forKey: identifier)?.resume(returning: json) }
}
