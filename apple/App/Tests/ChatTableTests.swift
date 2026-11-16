#if os(iOS)
import DesignSystem
import SwiftUI
import UIKit
import XCTest
@testable import App

@MainActor
final class ChatTableTests: XCTestCase {
    private let narrowest = DS.Size.proseTableColumn
    private let spacing = DS.Space.l

    func testColumnsKeepTheirMeasuredWidthWhileTheReadingColumnHasRoom() {
        let natural: [CGFloat] = [152, 163, 108]
        XCTAssertEqual(ChatTableColumns.widths(natural: natural, narrowest: narrowest, limit: 680, spacing: spacing, available: 680),
                       natural)
        let wide: [CGFloat] = [320, 90]
        XCTAssertEqual(ChatTableColumns.widths(natural: wide, narrowest: narrowest, limit: 680, spacing: spacing, available: 680),
                       [320, 90], "a long cell uses the room the reading column has before it wraps")
        XCTAssertEqual(ChatTableColumns.widths(natural: [20, 900], narrowest: narrowest, limit: 240),
                       [narrowest, 240], "with no room known a cell wraps past the limit")
    }

    func testTheWidestColumnsGiveWayFirstOnAPhone() {
        let natural: [CGFloat] = [60, 330, 250]
        let fitted = ChatTableColumns.widths(natural: natural, narrowest: narrowest, limit: 353, spacing: spacing, available: 353)
        XCTAssertEqual(ChatTableColumns.width(of: fitted, spacing: spacing), 353, accuracy: 0.5)
        XCTAssertEqual(fitted[0], narrowest, "a column narrower than the others keeps its width")
        XCTAssertEqual(fitted[1], fitted[2], accuracy: 0.5)
        let crowded = ChatTableColumns.widths(natural: Array(repeating: 400, count: 6), narrowest: narrowest, limit: 353,
                                              spacing: spacing, available: 353)
        XCTAssertEqual(crowded, Array(repeating: narrowest, count: 6), "past the narrowest columns it scrolls")
    }

    func testCellsDoNotWrapWhenTheReadingColumnHasRoom() {
        let rows = Self.clockRows
        let measured = height(of: ChatTableFixture.table(rows, available: DS.Size.proseReadingWidth), width: DS.Size.proseReadingWidth)
        let unwrapped = height(of: ChatTableFixture.table(rows, available: .infinity, wraps: false), width: DS.Size.proseReadingWidth)
        XCTAssertEqual(measured.height, unwrapped.height, accuracy: 0.5, "no cell wraps on an iPad-wide column")
        XCTAssertLessThan(measured.width, DS.Size.proseReadingWidth)
        let phone = height(of: ChatTableFixture.table(rows, available: 300), width: 300)
        XCTAssertLessThanOrEqual(phone.width, 300.5)
        XCTAssertGreaterThan(phone.height, unwrapped.height, "a narrow screen wraps the widest cells")
    }

    private static let clockRows: [[AttributedString]] = {
        var bold = AttributedString("2,570 to 2,595 MHz")
        bold.inlinePresentationIntent = .stronglyEmphasized
        return [
            [AttributedString(""), AttributedString("Now"), AttributedString("Card maximum")],
            [AttributedString("GPU core (SM) clock"), bold, AttributedString("3,090 MHz")],
            [AttributedString("Memory clock"), AttributedString("13,801 MHz"), AttributedString("14,001 MHz")],
            [AttributedString("Power draw under load"), AttributedString("545 to 575 W"), AttributedString("575 W")],
        ]
    }()

    private func height(of view: some View, width: CGFloat) -> CGSize {
        let host = UIHostingController(rootView: view.font(DS.Font.proseSecondary))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

@MainActor
private enum ChatTableFixture {
    static func table(_ rows: [[AttributedString]], available: CGFloat, wraps: Bool = true) -> some View {
        ChatTableGrid(narrowest: DS.Size.proseTableColumn, limit: available.isFinite ? available : .greatestFiniteMagnitude,
                      spacing: DS.Space.l, available: available) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                if index > 0 { Hairline().chatTableRule() }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    Text(cell).fixedSize(horizontal: !wraps, vertical: true).padding(.vertical, DS.Space.s)
                }
            }
        }
    }
}
#endif
