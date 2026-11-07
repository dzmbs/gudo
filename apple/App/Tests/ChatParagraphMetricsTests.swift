#if os(iOS)
import DesignSystem
import SwiftUI
import UIKit
import XCTest
@testable import App

@MainActor
final class ChatParagraphMetricsTests: XCTestCase {
    private func row(_ text: String) -> ChatRow {
        ChatRow(id: ChatRowID(item: "paragraph", part: 0), revision: 1, turn: "turn",
                content: .markdown(ChatMarkdownBlock(kind: .paragraph, source: text, text: AttributedString(text))))
    }

    private func nativeHeight(_ row: ChatRow, width: CGFloat, environment: EnvironmentValues,
                              host: UIHostingController<AnyView>) -> CGFloat {
        host.rootView = AnyView(ChatRowView(row: row, isExpanded: false, toggle: {}, actions: ChatRowActions())
            .environment(\.self, environment).dynamicTypeSize(environment.dynamicTypeSize).ignoresSafeArea())
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    func testShortPlainFastPathMatchesNativeRowsAcrossWidthsAndFontEnvironments() {
        let metrics = ChatParagraphMetrics()
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        let samples = [
            "Short message.", "Entry 1999. Native rows keep finished text in place while the next response arrives.",
            "WWWWW iiiii fjpq 0123456789", String(repeating: "W", count: 35),
        ]
        var comparisons = 0
        for size in [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility3] {
            for bold in [false, true] {
                for rightToLeft in [false, true] {
                    var environment = EnvironmentValues()
                    environment.dynamicTypeSize = size
                    environment.legibilityWeight = bold ? .bold : .regular
                    environment.layoutDirection = rightToLeft ? .rightToLeft : .leftToRight
                    environment.displayScale = rightToLeft ? 3 : 2
                    for width in stride(from: CGFloat(200), through: 1_200, by: 37) {
                        for text in samples {
                            let row = row(text)
                            let fast = metrics.height(for: row, width: width, environment: environment) {
                                self.nativeHeight($0, width: width, environment: environment, host: host)
                            }
                            guard let fast else { continue }
                            let actual = nativeHeight(row, width: width, environment: environment, host: host)
                            XCTAssertEqual(ceil(fast), ceil(actual), accuracy: 0.5,
                                           "width=\(width), size=\(size), bold=\(bold), rtl=\(rightToLeft): \(text)")
                            comparisons += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(comparisons, 100)
    }

    func testLongWrappingUnicodeControlCharactersAndStyledTextKeepTheNativeFallback() {
        let metrics = ChatParagraphMetrics()
        var calls = 0
        let measure: (ChatRow) -> CGFloat? = { _ in calls += 1; return 40 }
        for text in ["", "a\nb", "a\tb", "Cafe\u{301}", "مرحبا", "🙂", String(repeating: "W", count: 100)] {
            XCTAssertNil(metrics.height(for: row(text), width: 300, environment: EnvironmentValues(), measure: measure))
        }
        var styled = AttributedString("Bold")
        styled.inlinePresentationIntent = .stronglyEmphasized
        let item = ChatRow(id: ChatRowID(item: "styled", part: 0), revision: 1, turn: "turn",
                           content: .markdown(ChatMarkdownBlock(kind: .paragraph, source: "**Bold**", text: styled)))
        XCTAssertNil(metrics.height(for: item, width: 300, environment: EnvironmentValues(), measure: measure))
        var uppercased = EnvironmentValues()
        uppercased.textCase = .uppercase
        XCTAssertNil(metrics.height(for: row("small"), width: 300, environment: uppercased, measure: measure))
        XCTAssertEqual(calls, 0)
    }

    func testOneAndTwoLinesKeepSeparateNativeCalibrations() {
        let metrics = ChatParagraphMetrics()
        var samples: [String] = []
        let measure: (ChatRow) -> CGFloat? = { row in
            guard case .markdown(let block) = row.content else { return nil }
            samples.append(block.source)
            return block.source == "M" ? 40 : 60
        }
        let environment = EnvironmentValues()
        XCTAssertEqual(metrics.height(for: row("Short"), width: 400, environment: environment, measure: measure), 40)
        let wrapped = row(String(repeating: "W", count: 35))
        XCTAssertEqual(metrics.height(for: wrapped, width: 400, environment: environment, measure: measure), 60)
        XCTAssertEqual(metrics.height(for: wrapped, width: 400, environment: environment, measure: measure), 60)
        XCTAssertEqual(samples, ["M", "M\nM"])
    }

    func testCalibrationsAreReusedAndPurged() {
        let metrics = ChatParagraphMetrics()
        var calls = 0
        let measure: (ChatRow) -> CGFloat? = { _ in calls += 1; return 40 }
        for text in ["First", "Second"] {
            let height = metrics.height(for: row(text), width: 600, environment: EnvironmentValues(), measure: measure)
            XCTAssertEqual(height, 40)
        }
        XCTAssertEqual(calls, 1)
        metrics.clear()
        _ = metrics.height(for: row("Third"), width: 600, environment: EnvironmentValues(), measure: measure)
        XCTAssertEqual(calls, 2)
    }
}
#endif
