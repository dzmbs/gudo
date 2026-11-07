import Foundation
import XCTest
@testable import App

@MainActor
final class ChatOutputReaderTests: XCTestCase {
    func testNavigationReplacesPagesAndUsesTheAdmittedByteOffset() async throws {
        let text = String(repeating: "line\n", count: 5_000)
        var requested: [UInt64] = []
        let reader = ChatOutputReader { offset, length in
            requested.append(offset)
            XCTAssertEqual(length, ChatOutputLimits.pageBytes)
            let suffix = String(decoding: text.utf8.dropFirst(Int(offset)), as: UTF8.self)
            return try self.response(suffix, total: UInt64(text.utf8.count))
        }
        await reader.load()
        let first = try XCTUnwrap(reader.page)
        let next = try XCTUnwrap(first.nextOffset)
        await reader.load(offset: next)
        XCTAssertEqual(requested, [0, next])
        XCTAssertEqual(reader.previousOffset, 0)
        XCTAssertEqual(first.text + (reader.page?.text ?? ""), text)
        XCTAssertNotEqual(reader.page?.text, text)
        XCTAssertNil(reader.page?.nextOffset)
        await reader.load(offset: 0)
        XCTAssertEqual(reader.page?.text, first.text)
        XCTAssertNil(reader.previousOffset)
    }

    func testCancelledTransportCannotPublishAPageOrAnError() async throws {
        let probe = OutputProbe()
        let reader = ChatOutputReader(source: probe.read)
        let task = Task { await reader.load() }
        try await wait { probe.pending[0] != nil }
        task.cancel()
        probe.finish(0, with: "malformed JSON")
        await task.value
        XCTAssertNil(reader.page)
        XCTAssertNil(reader.error)
        XCTAssertFalse(reader.isLoading)
    }

    func testStoppingAReaderInvalidatesEvenAnUncancelledTransport() async throws {
        let probe = OutputProbe()
        let reader = ChatOutputReader(source: probe.read)
        let task = Task { await reader.load() }
        try await wait { probe.pending[0] != nil }
        reader.cancel()
        probe.finish(0, with: try response("old"))
        await task.value
        XCTAssertNil(reader.page)
        XCTAssertNil(reader.error)
        XCTAssertFalse(reader.isLoading)
    }

    func testAnOlderReplyCannotOverwriteANewerPageOrItsLoadingState() async throws {
        let probe = OutputProbe()
        let reader = ChatOutputReader(source: probe.read)
        let older = Task { await reader.load() }
        try await wait { probe.pending[0] != nil }
        let newer = Task { await reader.load(offset: 10) }
        try await wait { probe.pending[10] != nil }
        probe.finish(0, with: "malformed JSON")
        await older.value
        XCTAssertTrue(reader.isLoading)
        XCTAssertNil(reader.error)
        probe.finish(10, with: try response("fresh", total: 15))
        await newer.value
        XCTAssertEqual(reader.page?.text, "fresh")
        XCTAssertEqual(reader.page?.offset, 10)
        XCTAssertFalse(reader.isLoading)
    }

    func testALateSuccessfulReplyCannotReplaceTheAlreadyCompletedPage() async throws {
        let probe = OutputProbe()
        let reader = ChatOutputReader(source: probe.read)
        let older = Task { await reader.load() }
        try await wait { probe.pending[0] != nil }
        let newer = Task { await reader.load(offset: 10) }
        try await wait { probe.pending[10] != nil }
        probe.finish(10, with: try response("fresh", total: 15))
        await newer.value
        probe.finish(0, with: try response("old"))
        await older.value
        XCTAssertEqual(reader.page?.text, "fresh")
        XCTAssertEqual(reader.page?.offset, 10)
        XCTAssertNil(reader.error)
    }

    func testOversizedJSONIsRejectedBeforeDecodingAnOtherwiseValidPage() async throws {
        let json = String(repeating: " ", count: ChatOutputLimits.jsonBytes) + (try response("x"))
        let reader = ChatOutputReader { _, _ in json }
        await reader.load()
        XCTAssertNil(reader.page)
        XCTAssertEqual(reader.error, ChatOutputError.invalidPage.errorDescription)
    }

    func testWorstCaseJSONStringEscapesStillFitTheEnvelope() async throws {
        let text = String(repeating: "\0", count: Int(ChatOutputLimits.pageBytes))
        let json = try response(text)
        let reader = ChatOutputReader { _, _ in json }
        await reader.load()
        XCTAssertEqual(reader.page?.text, text)
        XCTAssertNil(reader.error)
    }

    func testInvalidPagesAndTransportErrorsPreserveTheLastValidPage() async throws {
        var attempts = 0
        let reader = ChatOutputReader { _, _ in
            attempts += 1
            switch attempts {
            case 1: return try self.response("abc", total: 10, next: 3)
            case 2: return try self.response("", total: 10, next: 3)
            default: throw URLError(.notConnectedToInternet)
            }
        }
        await reader.load()
        await reader.load(offset: 3)
        XCTAssertEqual(reader.error, ChatOutputError.invalidPage.errorDescription)
        XCTAssertEqual(reader.page?.text, "abc")
        XCTAssertNil(reader.previousOffset)
        await reader.load(offset: 3)
        XCTAssertEqual(reader.page?.text, "abc")
        XCTAssertEqual(reader.error, "Output could not load. Try again or open Terminal.")
        XCTAssertNil(reader.previousOffset)
        XCTAssertFalse(reader.isLoading)
    }

    func testChangedOutputsRequireRestartingInsteadOfSplicingDifferentVersions() async throws {
        var attempts = 0
        let reader = ChatOutputReader { offset, _ in
            attempts += 1
            if attempts == 1 { return try self.response("abc", total: 6, next: 3) }
            if offset == 3 { return try self.response("defg", total: 7) }
            return try self.response("replacement")
        }
        await reader.load()
        await reader.load(offset: 3)
        XCTAssertEqual(reader.error, ChatOutputError.changed.errorDescription)
        XCTAssertEqual(reader.page?.text, "abc")
        await reader.load()
        XCTAssertEqual(reader.page?.text, "replacement")
        XCTAssertNil(reader.error)
        XCTAssertNil(reader.previousOffset)
    }

    func testPreviousOffsetsAreBoundedAndBeginningRemainsReachable() async throws {
        let reader = ChatOutputReader { offset, _ in try self.response("x", total: 1_000, next: offset + 1) }
        for offset in 0..<100 { await reader.load(offset: UInt64(offset)) }
        for _ in 0..<ChatOutputLimits.previousPages {
            let previous = try XCTUnwrap(reader.previousOffset)
            await reader.load(offset: previous)
        }
        XCTAssertNil(reader.previousOffset)
        XCTAssertEqual(reader.page?.offset, 35)
        await reader.load()
        XCTAssertEqual(reader.page?.offset, 0)
        XCTAssertNil(reader.error)
    }

    private func response(_ text: String, total: UInt64? = nil, next: UInt64? = nil) throws -> String {
        try TimelineFixtureJSON.json(["text": text, "total_bytes": total ?? UInt64(text.utf8.count),
                                      "next_offset": next.map { $0 as Any } ?? NSNull()])
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Output request did not start")
        throw CancellationError()
    }
}

@MainActor
private final class OutputProbe {
    var pending: [UInt64: CheckedContinuation<String, any Error>] = [:]

    func read(_ offset: UInt64, length: UInt32) async throws -> String {
        try await withCheckedThrowingContinuation { pending[offset] = $0 }
    }

    func finish(_ offset: UInt64, with json: String) { pending.removeValue(forKey: offset)?.resume(returning: json) }
}
