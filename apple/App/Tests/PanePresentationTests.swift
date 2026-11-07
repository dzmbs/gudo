#if os(iOS)
import HostKit
import PaneLayout
import UIKit
import XCTest
import os
@testable import App

@MainActor
final class PanePresentationTests: XCTestCase {
    private final class Backend: DeferredPaneSizing, SharedPaneTap, @unchecked Sendable {
        struct State {
            var isDeferred = false
            var resizes = 0
            var cachedSizes = 0
            var claims = 0
            var input = Data()
        }
        let state = OSAllocatedUnfairLock(initialState: State())
        var isSizeDeferred: Bool { state.withLock { $0.isDeferred } }
        func deferSize() { state.withLock { $0.isDeferred = true } }
        func cancelSizeDeferral() { state.withLock { $0.isDeferred = false } }
        func layoutViewport(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) -> Bool {
            state.withLock {
                if $0.isDeferred { $0.cachedSizes += 1 } else { $0.resizes += 1 }
                return !$0.isDeferred
            }
        }
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {}
        func start(events: @escaping @Sendable (PaneEvent) -> Void, seed: (@Sendable () -> [PaneEvent])?) {}
        func write(_ bytes: UnsafeRawBufferPointer) {
            let input = Data(bytes)
            state.withLock { $0.isDeferred = false; $0.input.append(input) }
        }
        func writeGenerated(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
            state.withLock { $0.resizes += 1 }
        }
        func claimSize() { state.withLock { $0.claims += 1 } }
        func useSize() { state.withLock { $0.isDeferred = false; $0.claims += 1 } }
        func terminate() {}
    }

    func testPreparingChatDefersTheFirstViewportWithoutResizingOrClaiming() throws {
        let backend = Backend()
        let pane = try Pane(id: PaneId(1), backend: backend, onExit: {})
        XCTAssertTrue(pane.prepareToParkTerminal())
        pane.view.surface.layout(size: CGSize(width: 390, height: 600), scale: 2)
        pane.claimSize()
        XCTAssertTrue(backend.isSizeDeferred)
        XCTAssertEqual(backend.state.withLock { $0.cachedSizes }, 1)
        XCTAssertEqual(backend.state.withLock { $0.resizes }, 0)
        XCTAssertEqual(backend.state.withLock { $0.claims }, 0)
        XCTAssertEqual(pane.resizesSent, 0)
    }

    func testParkingRefusesMarkedTextWithoutCommittingOrDiscardingIt() throws {
        let backend = Backend()
        let pane = try Pane(id: PaneId(1), backend: backend, onExit: {})
        pane.view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(pane.view.markedTextRange)
        XCTAssertFalse(pane.prepareToParkTerminal())
        XCTAssertNotNil(pane.view.markedTextRange)
        XCTAssertFalse(backend.isSizeDeferred)
        XCTAssertTrue(backend.state.withLock { $0.input.isEmpty })
    }

    func testUserInputAdmitsTheViewportAndLaterGeometryResizesNormally() throws {
        let backend = Backend()
        let pane = try Pane(id: PaneId(1), backend: backend, onExit: {})
        XCTAssertTrue(pane.prepareToParkTerminal())
        pane.view.surface.layout(size: CGSize(width: 390, height: 600), scale: 2)
        pane.view.onInput?(Array("typed".utf8))
        XCTAssertFalse(backend.isSizeDeferred)
        pane.view.surface.layout(size: CGSize(width: 390, height: 500), scale: 3)
        XCTAssertEqual(backend.state.withLock { $0.resizes }, 1)
        XCTAssertEqual(pane.resizesSent, 1)
    }
}
#endif
