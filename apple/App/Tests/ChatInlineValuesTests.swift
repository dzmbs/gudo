#if os(iOS)
import Foundation
import HostKit
import Markdown
import XCTest
@testable import App

final class ChatInlineValuesTests: XCTestCase {
    func testFlatValuesMatchFoundationCharactersAndAttributes() throws {
        let sources = [
            "Plain paragraph.",
            "A **strong** paragraph with *emphasis* and `code`.",
            "Paragraph 42: **finished 42** with a [safe link](https://example.com/42).",
            "Emoji 👩🏽‍💻 café e\u{301} &amp; \\*literal\\*.",
            "A [blocked](javascript:alert%281%29) link.",
            "A [relative](../file) link.",
            "A [mail](mailto:fixture@example.com) link.",
            "A [secure](HTTPS://example.com) link.",
            "Encoded &quot;quotes&quot; and &#39;apostrophes&#39;.",
            "A `space   preserving` code span.",
            "A [query](https://example.com/?a=1&amp;b=2) and [parens](https://example.com/a_(b)).",
            "Encoded hyphens &#45;&#45; and dots &#46;&#46;&#46;.",
        ]
        for source in sources {
            let document = Document(parsing: source)
            let markup = try XCTUnwrap(document.child(at: 0))
            let prepared = try XCTUnwrap(ChatInlineValues.flat(markup, source: source), source)
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
            var expected = try AttributedString(markdown: source, options: options)
            for run in Array(expected.runs) {
                if let link = run.link, !["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") { expected[run.range].link = nil }
            }
            XCTAssertEqual(prepared, expected, source)
        }
    }

    func testWorkerFallbackPreservesTitlesPunctuationAndNestedStyles() async throws {
        let builder = RowBuilder()
        for (index, source) in ["A [safe link](https://example.com \"Title\").", "Quotes 'remain' and ... punctuation -- unchanged.",
                                "A **nested *emphasis*** value.", "Line\nwrap."].enumerated() {
            var item = TimelineFixtureJSON.item(index)
            item["body"] = ["Assistant": ["text": source, "streaming": false]]
            let value = try TimelineJSON.decode(TimelineItem.self, from: TimelineFixtureJSON.json(item))
            let rows = builder.rows(for: value)
            guard case .markdown(let block) = try XCTUnwrap(rows.first).content else { return XCTFail("Expected Markdown") }
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
            XCTAssertEqual(block.text, try AttributedString(markdown: source, options: options))
        }
    }

    func testNestedWhitespaceHtmlAndReferenceLinksRetainTheFoundationPath() throws {
        for source in ["A **nested *emphasis*** value.", "Line\nwrap.", "<span>literal</span>", " padding ", "~~strike~~",
                       "A [safe link](https://example.com \"Title\").", "Quotes 'remain' and ... punctuation -- unchanged.",
                       "www.example.com and user@example.com", "WWW.example.com and https://example.com"] {
            let document = Document(parsing: source)
            XCTAssertNil(ChatInlineValues.flat(document.child(at: 0), source: source), source)
        }
        for destination in ["https://example.com/first", "https://example.com/second"] {
            let source = "[label][id]"
            let document = Document(parsing: source + "\n\n[id]: " + destination)
            XCTAssertNil(ChatInlineValues.flat(document.child(at: 0), source: source))
        }
    }
}
#endif
