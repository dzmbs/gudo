import PaneLayout
import TerminalCore
import TerminalRenderer
import XCTest
import os
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
        let events = OSAllocatedUnfairLock<(@Sendable (PaneEvent) -> Void)?>(initialState: nil)
        let starts = OSAllocatedUnfairLock(initialState: 0)
        let terminations = OSAllocatedUnfairLock(initialState: 0)
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {
            self.events.withLock { $0 = events }
            starts.withLock { $0 += 1 }
        }
        func write(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}
        func terminate() { terminations.withLock { $0 += 1 } }
    }

    private let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func container(for pane: Pane) -> TerminalHost.Container {
        let container = TerminalHost.Container(frame: frame)
        container.pane = pane
        pane.hosts.add(container)
        return container
    }

    #if os(iOS)
    func testParkingPreservesTheViewAndBackendWithoutLayingOutTheHiddenTerminal() throws {
        let backend = Silent()
        let pane = try Pane(id: PaneId(1), backend: backend, onExit: {})
        let window = UIWindow(frame: frame)
        let root = PlatformView(frame: frame)
        window.addSubview(root)
        let host = container(for: pane)
        root.addSubview(host)
        pane.view.layoutIfNeeded()
        let terminalView = pane.view
        let previousFrame = terminalView.frame
        let previousResizes = pane.resizesSent
        host.isActive = false
        XCTAssertNil(terminalView.superview)
        XCTAssertNil(terminalView.window)
        host.frame.size = CGSize(width: 200, height: 180)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        terminalView.layoutIfNeeded()
        XCTAssertEqual(terminalView.frame, previousFrame)
        XCTAssertEqual(pane.resizesSent, previousResizes)
        backend.events.withLock { $0 }?(.output(Data("The live agent is still here".utf8)))
        XCTAssertTrue(terminalView.surface.terminal.visibleText().contains("The live agent is still here"))
        host.isActive = true
        XCTAssertTrue(pane.view === terminalView)
        XCTAssertTrue(terminalView.superview === host)
        XCTAssertEqual(backend.starts.withLock { $0 }, 1)
        XCTAssertEqual(backend.terminations.withLock { $0 }, 0)
        _ = window
    }

    func testAnInactiveNewContainerCannotStealTheLiveView() throws {
        let pane = try Pane(id: PaneId(1), backend: Silent(), onExit: {})
        let window = UIWindow(frame: frame)
        let root = PlatformView(frame: frame)
        window.addSubview(root)
        let active = container(for: pane)
        root.addSubview(active)
        let inactive = container(for: pane)
        inactive.isActive = false
        root.addSubview(inactive)
        XCTAssertTrue(pane.view.superview === active)
        XCTAssertNil(inactive.hitTest(CGPoint(x: 100, y: 100), with: nil))
        inactive.isActive = true
        XCTAssertTrue(pane.view.superview === inactive)
        active.isActive = false
        XCTAssertTrue(pane.view.superview === inactive)
        _ = window
    }
    #endif

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

/// Picture in picture shows a pane's frames twice a second: a picture is taken again only when
/// the terminal changed, since taking one waits for the GPU.
@MainActor
final class SurfaceFramesTests: XCTestCase {
    func testAPictureIsTakenOnlyWhenTheTerminalChanged() throws {
        let terminal = Terminal(cols: 40, rows: 10) { _ in }
        let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
        surface.layout(size: CGSize(width: 400, height: 200), scale: 2)
        terminal.write(Array("hello".utf8))
        surface.renderIfDirty(offscreen: true)
        let frames = SurfaceFrames()
        let first = try XCTUnwrap(frames.latest(of: surface))
        XCTAssertTrue(frames.latest(of: surface) === first, "unchanged: the same picture")
        terminal.write(Array(" world".utf8))
        surface.renderIfDirty(offscreen: true)
        XCTAssertFalse(frames.latest(of: surface) === first, "changed: a new picture")
    }
}
