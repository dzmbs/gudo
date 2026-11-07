#if os(macOS)
import Foundation
import XCTest
@testable import App

final class ChatDesignTokensTests: XCTestCase {
    func testChatRowsUseDesignTokensInsteadOfInlineFontsPaddingAndRadii() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: app.appending(path: "Sources/Chat/ChatRowView.swift"), encoding: .utf8)
        for pattern in [#"\.font\(\."#, #"cornerRadius:\s*[1-9][0-9]*"#, #"\.padding\([^)]*[1-9][0-9]*[^)]*\)"#] {
            let expression = try NSRegularExpression(pattern: pattern)
            let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
            XCTAssertTrue(matches.isEmpty, "Chat rows contain inline design values matching \(pattern)")
        }
    }
}
#endif
