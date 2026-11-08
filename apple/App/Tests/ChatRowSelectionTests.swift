#if os(iOS)
import Foundation
import XCTest
@testable import App

@MainActor
final class ChatRowSelectionTests: XCTestCase {
    func testCopyAndSelectionUseRenderedTextWhileMarkdownKeepsItsExactSource() {
        for (kind, source, visible) in [
            (ChatMarkdownBlock.Kind.paragraph, "**bold** and [site](https://example.invalid)", "bold and site"),
            (.heading(2), "## A **heading**", "A heading"),
            (.quote, "> A _quote_", "A quote"),
            (.code("swift"), "```swift\nlet value = 1\n```", "let value = 1\n"),
        ] {
            let block = ChatMarkdownBlock(kind: kind, source: source, text: AttributedString(visible))
            XCTAssertEqual(view(block).plainText, visible, "\(kind) must not copy Markdown delimiters")
            XCTAssertEqual(block.source, source)
            XCTAssertEqual(view(block).copyTitle, "Copy")
            XCTAssertEqual(view(block).selectionTitle, "Select Text")
        }
    }

    func testListsAndCompleteTablesCopyTheirRenderedContentRatherThanMarkup() {
        let list = ChatMarkdownBlock(kind: .list, source: "1. **One**\n   - _Two_", text: AttributedString(), list: [
            ChatListLine(depth: 0, marker: "1.", text: AttributedString("One")),
            ChatListLine(depth: 1, marker: "•", text: AttributedString("Two")),
        ])
        XCTAssertEqual(view(list).plainText, "1. One\n  • Two")
        let table = ChatMarkdownBlock(kind: .table, source: "| Name | Value |\n| - | - |\n| café | 漢字 |",
                                      text: AttributedString(), table: [
            [AttributedString("Name"), AttributedString("Value")],
            [AttributedString("café"), AttributedString("漢字")],
        ])
        XCTAssertEqual(view(table).plainText, "Name\tValue\ncafé\t漢字")
    }

    func testAnOmittedPreviewOffersTheFullRawSourceWithExplicitMenuLabels() {
        let source = "| **Name** | Value |\n| - | - |\n| café | Hidden row |"
        let block = ChatMarkdownBlock(kind: .table, source: source, text: AttributedString(),
                                      table: [[AttributedString("Name")]], hasOmittedContent: true)
        XCTAssertEqual(view(block).plainText, source)
        XCTAssertEqual(view(block).copyTitle, "Copy raw Markdown")
        XCTAssertEqual(view(block).selectionTitle, "Select raw Markdown")
    }

    private func view(_ block: ChatMarkdownBlock) -> ChatRowView {
        ChatRowView(row: ChatRow(id: ChatRowID(item: "fixture", part: 0), revision: 1, turn: nil, content: .markdown(block)),
                    isExpanded: false, toggle: {}, actions: ChatRowActions())
    }
}
#endif
