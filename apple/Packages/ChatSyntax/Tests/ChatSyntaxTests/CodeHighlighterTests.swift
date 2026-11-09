import Foundation
import XCTest
@testable import ChatSyntax

final class CodeHighlighterTests: XCTestCase {
    private let samples: [CodeLanguage: String] = [
        .rust: "// comment\nfn main() { let text = \"hello\"; }\n",
        .swift: "// comment\nfunc greet() { let text = \"hello\" }\n",
        .javascript: "// comment\nfunction greet() { return \"hello\"; }\n",
        .typescript: "// comment\nfunction greet(value: string): string { return \"hello\"; }\n",
        .tsx: "const view = <div title=\"hello\">Hello</div>;\n",
        .python: "# comment\ndef greet():\n    return \"hello\"\n",
        .go: "package main\nfunc main() { println(\"hello\") }\n",
        .bash: "#!/bin/sh\n# comment\necho \"hello\"\n",
        .json: "{\"text\": \"hello\", \"count\": 42, \"ok\": true}\n",
        .yaml: "# comment\ntext: hello\ncount: 42\n",
        .toml: "# comment\ntext = \"hello\"\ncount = 42\n",
        .markdown: "# Heading\n\n**Hello** and `code`.\n",
        .c: "// comment\nint main(void) { return 42; }\n",
        .cpp: "// comment\nclass Hello { public: int count = 42; };\n",
        .html: "<!-- comment -->\n<div title=\"hello\">Hello</div>\n",
        .css: "/* comment */\nbody { color: red; margin: 42px; }\n",
        .diff: "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-before\n+after\n",
    ]

    func testEveryBundledGrammarAndQueryProducesValidRanges() {
        let highlighter = CodeHighlighter()
        for language in CodeLanguage.allCases {
            let source = samples[language]!
            let tokens = highlighter.highlights(source, language: language)
            XCTAssertFalse(highlighter.unavailableLanguages.contains(language), "Unavailable grammar/query: \(language)")
            XCTAssertFalse(tokens.isEmpty, "No highlights: \(language)")
            for token in tokens {
                XCTAssertNotNil(Range(token.range, in: source), "Invalid UTF-16 range: \(language)")
                XCTAssertTrue((0..<16).contains(token.role.ansiSlot))
            }
        }
    }

    func testDerivedGrammarsInheritBaseKeywordsAndStrings() {
        let highlighter = CodeHighlighter()
        for language in [CodeLanguage.typescript, .tsx, .cpp] {
            let tokens = highlighter.highlights(samples[language]!, language: language)
            XCTAssertTrue(tokens.contains { $0.role == .keyword }, "Missing inherited keywords: \(language)")
        }
        let tokens = highlighter.highlights(samples[.typescript]!, language: .typescript)
        XCTAssertTrue(tokens.contains { $0.role == .string })
    }

    func testUnicodeOffsetsAndSameContentCache() {
        let highlighter = CodeHighlighter()
        let source = "let greeting = \"Hello 👩🏽‍💻 café e\u{301}\"; // 日本語\n"
        let first = highlighter.highlights(source, language: .rust)
        XCTAssertFalse(first.isEmpty)
        for token in first { XCTAssertNotNil(Range(token.range, in: source)) }
        XCTAssertTrue(first.contains { $0.role == .string && (source as NSString).substring(with: $0.range).contains("👩🏽‍💻") })
        XCTAssertEqual(first, highlighter.highlights(source, language: .rust))
        XCTAssertEqual(highlighter.parseCount, 1)
        _ = highlighter.highlights(source, language: .javascript)
        XCTAssertEqual(highlighter.parseCount, 2)
    }

    func testUnknownAndOversizedContentRemainPlainWithoutParsing() {
        let highlighter = CodeHighlighter()
        XCTAssertNil(CodeLanguage(fence: "unknown"))
        XCTAssertNil(CodeLanguage(fence: String(repeating: "x", count: 129)))
        XCTAssertEqual(CodeLanguage(fence: "TS"), .typescript)
        XCTAssertEqual(CodeLanguage(fence: "shell linenos"), .bash)
        XCTAssertEqual(CodeLanguage(fence: "c++"), .cpp)
        XCTAssertTrue(highlighter.highlights("text", language: nil).isEmpty)
        XCTAssertTrue(highlighter.highlights(String(repeating: "x", count: CodeHighlighter.maximumBytes + 1), language: .rust).isEmpty)
        XCTAssertTrue(highlighter.highlights(String(repeating: "\n", count: 2_000), language: .rust).isEmpty)
        XCTAssertEqual(highlighter.parseCount, 0)
    }

    func testCacheIsBoundedByBothBytesAndEntries() {
        let highlighter = CodeHighlighter()
        for index in 0..<300 {
            let source = "{\"index\": \(index), \"text\": \"\(String(repeating: "x", count: 2_000))\"}"
            _ = highlighter.highlights(source, language: .json)
            XCTAssertLessThanOrEqual(highlighter.cacheBytes, CodeHighlighter.cacheByteLimit)
            XCTAssertLessThanOrEqual(highlighter.cacheEntryCount, CodeHighlighter.cacheEntryLimit)
        }
        XCTAssertGreaterThan(highlighter.cacheEntryCount, 0)
        XCTAssertEqual(highlighter.parseCount, 300)
    }

    func testMalformedStreamingCodeIsDisplayOnlyAndBounded() {
        let highlighter = CodeHighlighter()
        let source = "func greet( { let text = \"unfinished 👋\n"
        let tokens = highlighter.highlights(source, language: .swift)
        XCTAssertLessThanOrEqual(tokens.count, CodeHighlighter.maximumTokens)
        for token in tokens { XCTAssertNotNil(Range(token.range, in: source)) }
    }
}
