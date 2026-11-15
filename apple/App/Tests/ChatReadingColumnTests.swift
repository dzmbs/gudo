import DesignSystem
import XCTest
@testable import App

final class ChatReadingColumnTests: XCTestCase {
    func testAPhoneReadsAtFullWidth() {
        XCTAssertEqual(ChatReadingColumn.rowWidth(in: 390), 390)
        XCTAssertEqual(ChatReadingColumn.textWidth(in: 390), 390 - 2 * DS.Space.xl)
    }

    func testWideScreensReadInAComfortableColumn() {
        for width: CGFloat in [820, 1024, 1366] {
            XCTAssertEqual(ChatReadingColumn.textWidth(in: width), DS.Size.proseReadingWidth)
        }
        XCTAssertGreaterThanOrEqual(DS.Size.proseReadingWidth, 640)
        XCTAssertLessThanOrEqual(DS.Size.proseReadingWidth, 700)
    }

    func testEstimatesUseTheColumnWidth() {
        let text = String(repeating: "word ", count: 400)
        let block = ChatMarkdownBlock(kind: .paragraph, source: text, text: AttributedString(text))
        let row = ChatRow(id: ChatRowID(item: "reply", part: 0), revision: 1, turn: "turn", content: .markdown(block))
        XCTAssertEqual(ChatRowEstimate.height(for: row, rowWidth: ChatReadingColumn.rowWidth(in: 1366), scale: 1),
                       ChatRowEstimate.height(for: row, rowWidth: ChatReadingColumn.maximumWidth, scale: 1))
    }
}
