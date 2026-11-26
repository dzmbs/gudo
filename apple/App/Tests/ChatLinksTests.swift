import Foundation
import HostKit
import TerminalCore
import XCTest
@testable import App

/// Links in an agent's reply open straight away only when their label is their address; a
/// label over another address, or a `user@` host, asks first as terminal links do.
final class ChatLinksTests: XCTestCase {
    private func block(_ source: String) throws -> ChatMarkdownBlock {
        var item = TimelineFixtureJSON.item(1)
        item["body"] = ["Assistant": ["text": source, "streaming": false]]
        let value = try TimelineJSON.decode(TimelineItem.self, from: TimelineFixtureJSON.json(item))
        guard case .markdown(let block) = try XCTUnwrap(RowBuilder().rows(for: value).first).content else {
            XCTFail("not Markdown: \(source)")
            throw CancellationError()
        }
        return block
    }

    private func action(_ source: String, _ address: String) throws -> LinkSafety.Action {
        try block(source).linkAction(for: try XCTUnwrap(URL(string: address)))
    }

    func testALabelOverAnotherAddressAsksFirst() throws {
        XCTAssertEqual(try action("See [the fix](https://evil.example/?k=secret).", "https://evil.example/?k=secret"), .confirm)
        XCTAssertEqual(try action("A **[bold label](https://evil.example/a)** here.", "https://evil.example/a"), .confirm)
    }

    func testAUserPartThatReadsAsAnotherHostAsksFirst() throws {
        let address = "https://github.com@evil.example/fix"
        XCTAssertEqual(try action("Open [\(address)](\(address)).", address), .confirm)
    }

    func testAnAddressShownAsItselfOpens() throws {
        let address = "https://example.com/docs"
        XCTAssertEqual(try action("Read [\(address)](\(address)) first.", address), .open)
    }

    func testTheSameAddressHiddenAnywhereInTheBlockAsksFirst() throws {
        let address = "https://example.com/docs"
        XCTAssertEqual(try action("Read [\(address)](\(address)) or [this](\(address)).", address), .confirm)
        XCTAssertEqual(try action("- [\(address)](\(address))\n- [this](\(address))", address), .confirm)
    }

    func testAnAddressTheBlockDoesNotLinkAsksFirst() throws {
        XCTAssertEqual(try action("Nothing linked here.", "https://example.com/"), .confirm)
    }
}
