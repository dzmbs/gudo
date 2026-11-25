import GudoCore
import TerminalCore
import TerminalRenderer
import XCTest
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import App

@MainActor
final class WindowSizingTests: XCTestCase {
    func testSizingSourceUsesTheConnectionNotItsSharedPrincipal() {
        let mine = PaneSizing(paneId: 1, peer: 7)
        let other = PaneSizing(paneId: 1, peer: 8)
        XCTAssertNil(PaneSizingSource.resolve(mine, myPeer: 7, policy: .lastActive, isLocalDriver: true, othersConnected: true))
        XCTAssertEqual(PaneSizingSource.resolve(other, myPeer: 7, policy: .lastActive, isLocalDriver: true, othersConnected: true), .peer(8))
        XCTAssertEqual(PaneSizingSource.resolve(mine, myPeer: 7, policy: .lastActive, isLocalDriver: false, othersConnected: true), .anotherWindow)
        let composite = PaneSizing(paneId: 1, peer: nil)
        XCTAssertEqual(
            PaneSizingSource.resolve(composite, myPeer: 7, policy: .fixed(cols: 80, rows: 24), isLocalDriver: true, othersConnected: true), .fixed)
        XCTAssertEqual(PaneSizingSource.resolve(composite, myPeer: 7, policy: .smallest, isLocalDriver: true, othersConnected: true), .shared)
    }

    /// Another client sizing the pane to the grid this view would choose changes nothing here:
    /// no strip offers its size.
    func testAnotherClientAtThisViewsGridIsNotShown() {
        let other = PaneSizing(paneId: 1, peer: 8)
        let mine = PaneSizing(paneId: 1, peer: 7)
        XCTAssertNil(PaneSizingSource.resolve(other, myPeer: 7, policy: .lastActive, isLocalDriver: true,
                                              othersConnected: true, matchesOwnGrid: true))
        XCTAssertNil(PaneSizingSource.resolve(mine, myPeer: 7, policy: .lastActive, isLocalDriver: false,
                                              othersConnected: true, matchesOwnGrid: true))
        XCTAssertEqual(PaneSizingSource.resolve(other, myPeer: 7, policy: .lastActive, isLocalDriver: true,
                                                othersConnected: true, matchesOwnGrid: false), .peer(8))
    }

    /// The strip names the other device as it introduced itself; two Macs are told apart.
    func testThePeerSizingThePaneIsNamed() {
        XCTAssertEqual(PaneSizingSource.peerLabel(name: "Studio", device: .desktop, myDevice: .desktop), "Sized for Studio")
        XCTAssertEqual(PaneSizingSource.peerLabel(name: "", device: .desktop, myDevice: .desktop), "Sized for another Mac")
        XCTAssertEqual(PaneSizingSource.peerLabel(name: "", device: .phone, myDevice: .desktop), "Sized for iPhone")
        XCTAssertEqual(PaneSizingSource.peerLabel(name: "  ", device: .tablet, myDevice: nil), "Sized for iPad")
        XCTAssertEqual(PaneSizingSource.peerLabel(name: "", device: .unknown, myDevice: .desktop), "Sized for another device")
    }

    /// Nobody claiming the size yet (this client's own size on its way, or every window in the
    /// background) is not someone else deciding it; nor is a lone client's smallest grid.
    func testOnlyAnotherClientDecidingTheSizeIsShown() {
        let unclaimed = PaneSizing(paneId: 1, peer: nil)
        for policy in [SizePolicy.lastActive, .lastInput, .followLease, .smallest] {
            XCTAssertNil(PaneSizingSource.resolve(unclaimed, myPeer: 7, policy: policy, isLocalDriver: true, othersConnected: false), "\(policy)")
        }
        for policy in [SizePolicy.lastActive, .lastInput, .followLease] {
            XCTAssertNil(PaneSizingSource.resolve(unclaimed, myPeer: 7, policy: policy, isLocalDriver: true, othersConnected: true), "\(policy)")
        }
        XCTAssertEqual(
            PaneSizingSource.resolve(unclaimed, myPeer: 7, policy: .fixed(cols: 80, rows: 24), isLocalDriver: true, othersConnected: false), .fixed)
        let mine = PaneSizing(paneId: 1, peer: 7)
        XCTAssertNil(PaneSizingSource.resolve(mine, myPeer: nil, policy: .lastActive, isLocalDriver: true, othersConnected: false))
    }

    func testNativeViewFitsAndCentersSharedGridsWithoutReflow() throws {
        for (columns, rows, width, height) in [(20, 5, 600, 400), (160, 50, 220, 300)] {
            let terminal = Terminal(cols: UInt16(columns), rows: UInt16(rows)) { _ in }
            let surface = try TerminalSurface(terminal: terminal, fontSize: 12)
            surface.sizeFollowsStream = true
            let view = TerminalView(surface: surface)
            view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            surface.layout(size: view.bounds.size, scale: 2)
            let first = surface.rect(for: GridPoint(x: 0, y: 0))
            let last = surface.rect(for: GridPoint(x: columns - 1, y: rows - 1))
            XCTAssertGreaterThanOrEqual(first.minX, 0)
            XCTAssertGreaterThanOrEqual(first.minY, 0)
            XCTAssertLessThanOrEqual(last.maxX, view.bounds.width + 0.01)
            XCTAssertLessThanOrEqual(last.maxY, view.bounds.height + 0.01)
            XCTAssertEqual(first.minX, view.bounds.width - last.maxX, accuracy: 0.01)
            XCTAssertEqual(first.minY, view.bounds.height - last.maxY, accuracy: 0.01)
            XCTAssertEqual(surface.cell(at: CGPoint(x: last.midX, y: last.midY)), GridPoint(x: columns - 1, y: rows - 1))
            XCTAssertEqual(terminal.size.cols, columns)
            XCTAssertEqual(terminal.size.rows, rows)
        }
    }

    func testVisibilityAndActivityRemainSeparate() throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        let model = WindowModel(app: .shared)
        defer { model.close() }
        XCTAssertTrue(model.isOnScreen)
        XCTAssertEqual(model.reportedSizingActivity, .inactive)
        model.sizingActivity = .active
        XCTAssertEqual(model.reportedSizingActivity, .active)
        model.isOnScreen = false
        XCTAssertEqual(model.reportedSizingActivity, .inactive)
        model.isOnScreen = true
        XCTAssertEqual(model.reportedSizingActivity, .active)
        model.destination = .inbox
        XCTAssertEqual(model.reportedSizingActivity, .inactive)
        model.destination = .terminal
        XCTAssertEqual(model.reportedSizingActivity, .active)
        model.close()
        XCTAssertEqual(model.reportedSizingActivity, .inactive)
    }
}
