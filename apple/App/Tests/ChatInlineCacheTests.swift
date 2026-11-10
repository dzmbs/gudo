import Foundation
import HostKit
import XCTest
@testable import App

@MainActor
final class ChatInlineCacheTests: XCTestCase {
    func testInlineReuseMatchesFoundationStylesAndLinkPolicy() async throws {
        let atoms = ["plain", "**strong**", "*emphasis*", "~~removed~~", "`a*b`", "**`code`**",
                     "[safe](https://example.com)", "[unsafe](javascript:alert)", "a &amp; b", "👩🏽‍💻 e\u{301}",
                     "\\*literal\\*", "<https://example.com>", "![alt](https://example.com/image.png)"]
        let builder = RowBuilder()
        for (index, source) in atoms.flatMap({ left in atoms.map { left + " and " + $0 } }).enumerated() {
            try await assertParity(source, id: "pair-\(index)", builder: builder)
            try await assertParity(source + "\n\nA second **paragraph**.", id: "batch-\(index)", builder: builder)
        }
        for (index, source) in ["line\n  next", "[ref][doc]\n\n[doc]: https://example.com", "www.example.com and user@example.com",
                                "[**nested** *label*](https://example.com/path \"title\")", "[relative](../file)",
                                "[anchor](#part)", "[mail](mailto:user@example.com)", "[file](file:///tmp/example)",
                                "[**bold** *label*](https://example.com)", "WWW.example.com and https://example.com"].enumerated() {
            try await assertParity(source, id: "fallback-\(index)", builder: builder)
            try await assertParity(source + "\n\nA second paragraph.", id: "fallback-batch-\(index)", builder: builder)
        }
    }

    private func assertParity(_ source: String, id: String, builder: RowBuilder,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let value: [String: Any] = ["id": id, "revision": 1, "at": 1, "origin": "Agent",
                                   "body": ["Assistant": ["text": source, "streaming": false]]]
        let item = try JSONDecoder().decode(TimelineItem.self, from: JSONSerialization.data(withJSONObject: value))
        let rows = builder.rows(for: item)
        for row in rows {
            guard case .markdown(let block) = row.content, block.kind == .paragraph else { continue }
            var expected = try AttributedString(markdown: block.source, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible))
            for run in Array(expected.runs) {
                if let url = run.link, !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    expected[run.range].link = nil
                }
            }
            XCTAssertEqual(block.text, expected, "Inline parity for \(source)", file: file, line: line)
        }
    }
}
