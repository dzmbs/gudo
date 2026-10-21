import PaneLayout
import XCTest
@testable import App
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// `TerminalHost` containers: SwiftUI can hold two for one pane in a window at once (a rebuilt
/// place goes in on top while the old one animates out). The terminal must follow the newcomer,
/// and an empty container must never take the pointer from it (wheel in less, clicks in vim).
@MainActor
final class TerminalHostTests: XCTestCase {
    private final class Silent: PaneBackend, @unchecked Sendable {
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {}
        func write(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}
        func terminate() {}
    }

    private let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func container(for pane: Pane) -> TerminalHost.Container {
        let container = TerminalHost.Container(frame: frame)
        container.pane = pane
        pane.hosts.add(container)
        return container
    }

    func testTheTerminalFollowsAContainerThatJoinsItsWindow() throws {
        let pane = try Pane(id: PaneId(1), backend: Silent(), onExit: {})
        #if os(macOS)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        let root = PlatformView(frame: frame)
        window.contentView = root
        #else
        let window = UIWindow(frame: frame)
        let root = PlatformView(frame: frame)
        window.addSubview(root)
        #endif

        let old = container(for: pane)
        root.addSubview(old)
        XCTAssertTrue(pane.view.superview === old)

        // The rebuilt place, while the old one is still in the window (here under it, so the
        // emptied old one is on top).
        let new = container(for: pane)
        #if os(macOS)
        root.addSubview(new, positioned: .below, relativeTo: old)
        #else
        root.insertSubview(new, belowSubview: old)
        #endif
        XCTAssertTrue(pane.view.superview === new, "the terminal stayed in the container on its way out")

        // The pointer reaches the terminal through the empty container.
        #if os(macOS)
        XCTAssertNil(old.hitTest(CGPoint(x: 200, y: 150)))
        let hit = root.hitTest(CGPoint(x: 200, y: 150))
        XCTAssertTrue(hit?.isDescendant(of: pane.view) == true, "hit \(hit.map { "\(type(of: $0))" } ?? "nil")")
        #else
        XCTAssertNil(old.hitTest(CGPoint(x: 200, y: 150), with: nil))
        let hit = root.hitTest(CGPoint(x: 200, y: 150), with: nil)
        XCTAssertTrue(hit?.isDescendant(of: pane.view) == true, "hit \(hit.map { "\(type(of: $0))" } ?? "nil")")
        #endif

        // The old one finally leaving changes nothing.
        old.removeFromSuperview()
        XCTAssertTrue(pane.view.superview === new)
        _ = window
    }
}
