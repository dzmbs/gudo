import XCTest
@testable import App

@MainActor
final class BoundedLRUTests: XCTestCase {
    func testReadsPromoteButPeeksDoNot() {
        let cache = BoundedLRU<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.peek("a"), 1)
        cache.insert(3, for: "c")
        XCTAssertNil(cache.peek("a"))
        XCTAssertEqual(cache.value(for: "b"), 2)
        cache.insert(4, for: "d")
        XCTAssertNil(cache.peek("c"))
        XCTAssertEqual(cache.peek("b"), 2)
        XCTAssertEqual(cache.remove("b"), 2)
        XCTAssertEqual(cache.remove("d"), 4)
        cache.insert(5, for: "e")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(for: "e"), 5)
    }

    func testPromotingAndRemovingMiddleEntriesPreservesBothEnds() {
        let cache = BoundedLRU<Int, Int>(capacity: 3)
        for key in 0..<3 { cache.insert(key, for: key, cost: LRUCost(bytes: 1)) }
        XCTAssertEqual(cache.value(for: 1), 1)
        cache.insert(3, for: 3, cost: LRUCost(bytes: 1))
        XCTAssertNil(cache.peek(0))
        XCTAssertEqual(cache.remove(1), 1)
        cache.insert(4, for: 4, cost: LRUCost(bytes: 1))
        XCTAssertEqual(cache.value(for: 3), 3)
        cache.insert(5, for: 5, cost: LRUCost(bytes: 1))
        XCTAssertNil(cache.peek(2))
        XCTAssertEqual(cache.peek(3), 3)
        XCTAssertEqual(cache.peek(4), 4)
        XCTAssertEqual(cache.peek(5), 5)
        XCTAssertEqual(cache.cost, LRUCost(bytes: 3))
    }

    func testReplacementAndEvictionMaintainBothCostLedgers() {
        let cache = BoundedLRU<String, Int>(capacity: 4, byteLimit: 10, unitLimit: 3)
        cache.insert(1, for: "a", cost: LRUCost(bytes: 6, units: 2))
        cache.insert(2, for: "b", cost: LRUCost(bytes: 4, units: 1))
        XCTAssertEqual(cache.cost, LRUCost(bytes: 10, units: 3))
        cache.insert(3, for: "a", cost: LRUCost(bytes: 2, units: 1))
        XCTAssertEqual(cache.cost, LRUCost(bytes: 6, units: 2))
        cache.insert(4, for: "c", cost: LRUCost(bytes: 6, units: 2))
        XCTAssertNil(cache.peek("b"))
        XCTAssertEqual(cache.peek("a"), 3)
        XCTAssertEqual(cache.cost, LRUCost(bytes: 8, units: 3))
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.cost, LRUCost())
    }

    func testUncacheableValuesLeaveOtherEntriesAloneAndCannotKeepStaleReplacements() {
        let cache = BoundedLRU<String, Int>(capacity: 2, byteLimit: 10, unitLimit: 2)
        cache.insert(1, for: "a", cost: LRUCost(bytes: 2, units: 1))
        cache.insert(2, for: "b", cost: LRUCost(bytes: 2, units: 1))
        XCTAssertFalse(cache.insert(3, for: "large", cost: LRUCost(bytes: 11)))
        XCTAssertFalse(cache.insert(3, for: "many", cost: LRUCost(units: 3)))
        XCTAssertEqual(cache.count, 2)
        XCTAssertFalse(cache.insert(3, for: "a", cost: LRUCost(bytes: 11)))
        XCTAssertNil(cache.peek("a"))
        XCTAssertEqual(cache.peek("b"), 2)
        XCTAssertEqual(cache.cost, LRUCost(bytes: 2, units: 1))
    }

    func testZeroCapacityAndZeroCostEntriesStillRespectTheEntryCap() {
        let disabled = BoundedLRU<Int, Int>(capacity: 0)
        XCTAssertFalse(disabled.insert(0, for: 0))
        let cache = BoundedLRU<Int, Int>(capacity: 2, byteLimit: 0, unitLimit: 0)
        for key in 0..<3 { XCTAssertTrue(cache.insert(key, for: key)) }
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.peek(0))
        XCTAssertEqual(cache.cost, LRUCost())
        XCTAssertFalse(cache.insert(4, for: 4, cost: LRUCost(units: 1)))
        XCTAssertEqual(cache.count, 2)
    }

    func testMaximumAllowancesCannotOverflowDuringInsertion() {
        let cache = BoundedLRU<Int, Int>(capacity: 3)
        cache.insert(0, for: 0, cost: LRUCost(bytes: .max - 1, units: .max - 1))
        cache.insert(1, for: 1, cost: LRUCost(bytes: 1, units: 1))
        XCTAssertEqual(cache.cost, LRUCost(bytes: .max, units: .max))
        cache.insert(2, for: 2, cost: LRUCost(bytes: 1, units: 1))
        XCTAssertNil(cache.peek(0))
        XCTAssertEqual(cache.cost, LRUCost(bytes: 2, units: 2))
    }

    func testEvictionAndDestructionReleaseLinkedValues() {
        final class Value {}
        weak var first: Value?
        weak var second: Value?
        var cache: BoundedLRU<Int, Value>? = BoundedLRU(capacity: 2)
        do {
            let a = Value()
            let b = Value()
            first = a
            second = b
            cache?.insert(a, for: 1)
            cache?.insert(b, for: 2)
        }
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        cache?.insert(Value(), for: 3)
        XCTAssertNil(first)
        cache = nil
        XCTAssertNil(second)
    }
}
