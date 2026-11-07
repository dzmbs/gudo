import HostKit
import XCTest
import os
@testable import App

@MainActor
final class ChatModelPoolTests: XCTestCase {
    func testOnlyTheLastLeaseStopsTheSharedModelObserver() throws {
        let pool = ChatModelPool(capacity: 1)
        let owner = UUID()
        let first = try XCTUnwrap(pool.acquire(owner, pane: 7))
        let second = try XCTUnwrap(pool.acquire(owner, pane: 7))
        let resolutions = OSAllocatedUnfairLock(initialState: 0)
        let hub = DaemonWorkspace(hostId: "fixture", events: WorkspaceEventHub(), resolve: {
            resolutions.withLock { $0 += 1 }
            return nil
        })
        first.model.start(in: hub)
        let initial = resolutions.withLock { $0 }
        first.close()
        hub.timelineChannel(pane: 7).requestSnapshot()
        let stillObserved = resolutions.withLock { $0 }
        XCTAssertGreaterThan(stillObserved, initial)
        second.close()
        hub.timelineChannel(pane: 7).requestSnapshot()
        XCTAssertEqual(resolutions.withLock { $0 }, stillObserved)
    }

    func testFinishingALongVisibleLeaseCountsAsTheMostRecentUse() throws {
        let pool = ChatModelPool(capacity: 2)
        let firstID = UUID()
        let first = try XCTUnwrap(pool.acquire(firstID, pane: 7))
        let firstModel = first.model
        let second = try XCTUnwrap(pool.acquire(UUID(), pane: 8))
        second.close()
        first.close()
        let third = try XCTUnwrap(pool.acquire(UUID(), pane: 9))
        third.close()
        XCTAssertTrue(try XCTUnwrap(pool.acquire(firstID, pane: 7)).model === firstModel)
    }

    func testOnlyInactiveModelsCanBeEvicted() throws {
        let pool = ChatModelPool(capacity: 2, valueByteLimit: 4_096)
        let first = try XCTUnwrap(pool.acquire(UUID(), pane: 7))
        let second = try XCTUnwrap(pool.acquire(UUID(), pane: 8))
        XCTAssertNil(pool.acquire(UUID(), pane: 9))
        XCTAssertEqual(first.model.valueByteLimit, 2_048)
        XCTAssertEqual(second.model.valueByteLimit, 2_048)
        first.close()
        XCTAssertNotNil(pool.acquire(UUID(), pane: 9))
    }

    func testRecentInactiveModelsStayWarmAndOlderOnesAreRecreated() throws {
        let pool = ChatModelPool(capacity: 2)
        let firstID = UUID()
        let secondID = UUID()
        let first = try XCTUnwrap(pool.acquire(firstID, pane: 7))
        let firstModel = first.model
        first.close()
        let second = try XCTUnwrap(pool.acquire(secondID, pane: 8))
        let secondModel = second.model
        second.close()
        let recent = try XCTUnwrap(pool.acquire(firstID, pane: 7))
        XCTAssertTrue(recent.model === firstModel)
        recent.close()
        let third = try XCTUnwrap(pool.acquire(UUID(), pane: 9))
        third.close()
        let recreated = try XCTUnwrap(pool.acquire(secondID, pane: 8))
        XCTAssertFalse(recreated.model === secondModel)
    }

    func testLeaseDeinitializationReleasesCapacityWithoutEvictingAnotherVisiblePane() throws {
        let pool = ChatModelPool(capacity: 1)
        var lease: ChatModelLease? = try XCTUnwrap(pool.acquire(UUID(), pane: 7))
        XCTAssertNotNil(lease)
        XCTAssertNil(pool.acquire(UUID(), pane: 8))
        lease = nil
        XCTAssertNotNil(pool.acquire(UUID(), pane: 8))
    }

    func testARepeatedOwnerCannotShowAnotherPanesValues() throws {
        let pool = ChatModelPool(capacity: 1)
        let owner = UUID()
        let lease = try XCTUnwrap(pool.acquire(owner, pane: 7))
        XCTAssertNil(pool.acquire(owner, pane: 8))
        XCTAssertTrue(try XCTUnwrap(pool.acquire(owner, pane: 7)).model === lease.model)
    }
}
