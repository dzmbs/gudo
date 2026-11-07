import HostKit
import XCTest
@testable import App

@MainActor
final class ChatOutputPageTests: XCTestCase {
    func testUnicodeOffsetsCountSourceBytesInsteadOfCharacters() throws {
        let response = try output("é🙂", total: 16, next: 10)
        let page = try ChatOutputPage(response, offset: 4)
        XCTAssertEqual(page.text, "é🙂")
        XCTAssertEqual(page.offset, 4)
        XCTAssertEqual(page.nextOffset, 10)
        XCTAssertEqual(page.totalBytes, 16)
    }

    func testAnExactByteBoundaryIsAdmittedButLargerResponsesAreRejected() throws {
        let text = String(repeating: "x", count: Int(ChatOutputLimits.pageBytes))
        let page = try ChatOutputPage(output(text), offset: 0)
        XCTAssertEqual(page.text, text)
        XCTAssertNil(page.nextOffset)
        XCTAssertThrowsError(try ChatOutputPage(output(text + "x"), offset: 0))
    }

    func testLineAdmissionContinuesAtTheExactUnconsumedByte() throws {
        let text = String(repeating: "line\n", count: 5_000)
        let page = try ChatOutputPage(output(text), offset: 0)
        XCTAssertEqual(page.text.components(separatedBy: "\n").count, ChatOutputLimits.pageLines)
        let next = try XCTUnwrap(page.nextOffset)
        XCTAssertEqual(next, UInt64(page.text.utf8.count))
        let suffix = String(decoding: text.utf8.dropFirst(Int(next)), as: UTF8.self)
        let remainder = try ChatOutputPage(output(suffix, total: UInt64(text.utf8.count)), offset: next)
        XCTAssertEqual(page.text + remainder.text, text)
        XCTAssertNil(remainder.nextOffset)
    }

    func testEmptyOutputAndAnExactEndOffsetAreValid() throws {
        XCTAssertNil(try ChatOutputPage(output(""), offset: 0).nextOffset)
        XCTAssertNil(try ChatOutputPage(output("", total: 100), offset: 100).nextOffset)
    }

    func testNonProgressingSkippedAndContradictoryCursorsAreRejected() throws {
        for next in [UInt64(0), 2, 4, 10] {
            XCTAssertThrowsError(try ChatOutputPage(output("abc", total: 10, next: next), offset: 0))
        }
        XCTAssertThrowsError(try ChatOutputPage(output("", total: 10, next: 0), offset: 0))
        XCTAssertThrowsError(try ChatOutputPage(output("abc", total: 10), offset: 0))
        XCTAssertThrowsError(try ChatOutputPage(output("abc", total: 2), offset: 0))
    }

    func testOffsetArithmeticCannotWrap() throws {
        XCTAssertThrowsError(try ChatOutputPage(output("abc", total: .max), offset: .max - 1))
    }

    private func output(_ text: String, total: UInt64? = nil, next: UInt64? = nil) throws -> TimelineToolOutput {
        let json = try TimelineFixtureJSON.json([
            "text": text, "total_bytes": total ?? UInt64(text.utf8.count),
            "next_offset": next.map { $0 as Any } ?? NSNull()
        ])
        return try TimelineJSON.decode(TimelineToolOutput.self, from: json)
    }
}
