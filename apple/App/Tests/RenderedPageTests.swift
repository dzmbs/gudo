import XCTest
@testable import App

@MainActor
final class RenderedPageTests: XCTestCase {
    // Synthetic charges exercise the ledger without allocating corresponding payloads.
    private func charged(_ units: Int, bytes: Int) -> RenderedChatRows {
        RenderedChatRows(rows: [], cost: LRUCost(bytes: bytes, units: units))
    }

    func testExactBoundariesReplacementAndRemoval() {
        var page = RenderedPage()
        XCTAssertTrue(page.store(charged(3_000, bytes: 8 * 1_024 * 1_024), for: "full"))
        XCTAssertEqual(page.cost, LRUCost(bytes: ChatRenderLimits.bytesPerPage, units: 3_000))
        XCTAssertFalse(page.store(charged(1, bytes: 1), for: "extra"))
        XCTAssertTrue(page.store(charged(1, bytes: 100), for: "full"))
        XCTAssertEqual(page.cost, LRUCost(bytes: 100, units: 1))
        page.remove("full")
        page.remove("full")
        XCTAssertEqual(page.cost, LRUCost())
        XCTAssertTrue(page.items.isEmpty)
    }

    func testRejectedRevisionsCannotMutateEitherLedger() {
        var page = RenderedPage()
        for id in ["a", "b", "c"] { XCTAssertTrue(page.store(charged(1_000, bytes: 2_000_000), for: id)) }
        let original = page.cost
        XCTAssertFalse(page.store(charged(1_001, bytes: 1), for: "b"))
        XCTAssertFalse(page.store(charged(1, bytes: .max), for: "b"))
        XCTAssertEqual(page.cost, original)
        XCTAssertEqual(page.items["b"]?.cost.units, 1_000)
        XCTAssertTrue(page.store(charged(1, bytes: 100), for: "b"))
        XCTAssertEqual(page.cost, LRUCost(bytes: 4_000_100, units: 2_001))
        page.remove("a")
        XCTAssertEqual(page.cost, LRUCost(bytes: 2_000_100, units: 1_001))
    }

    func testAStagedPageCannotMutateTheCommittedPage() {
        var committed = RenderedPage()
        XCTAssertTrue(committed.store(charged(1, bytes: 100), for: "a"))
        var staged = committed
        XCTAssertTrue(staged.store(charged(3_000, bytes: 1_000), for: "a"))
        XCTAssertFalse(staged.store(charged(1, bytes: 1), for: "b"))
        XCTAssertEqual(committed.cost, LRUCost(bytes: 100, units: 1))
        XCTAssertEqual(committed.items["a"]?.cost.units, 1)
    }
}
