import PaneLayout
import Synchronization
import TerminalRenderer
import XCTest
@testable import App
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A pane whose view resizes through an animated layout change (a split, a close, a zoom) tells
/// its backend once, at the size it lands at: the shell gets one SIGWINCH and redraws its
/// prompt once, and the terminal never reflows at the sizes in between.
@MainActor
final class PaneResizeTests: XCTestCase {
    private final class Counting: PaneBackend, @unchecked Sendable {
        let sizes = Mutex<[UInt16]>([])
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {}
        func write(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) { sizes.withLock { $0.append(cols) } }
        func terminate() {}
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func testASplitResizesThePaneOnce() throws {
        let backend = Counting()
        let pane = try Pane(id: PaneId(1), backend: backend, onExit: {})
        let frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        #if os(macOS)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: true)
        let root = PlatformView(frame: frame)
        window.contentView = root
        #else
        let window = UIWindow(frame: frame)
        let root = PlatformView(frame: frame)
        window.addSubview(root)
        #endif
        let container = TerminalHost.Container(frame: frame)
        container.pane = pane
        pane.hosts.add(container)
        root.addSubview(container)
        func setWidth(_ width: CGFloat) {
            container.frame.size.width = width
            pane.view.frame = container.bounds
            #if os(iOS)
            pane.view.layoutIfNeeded()
            #endif
        }
        setWidth(800)
        spin(0.2)
        let start = backend.sizes.withLock { $0 }
        let cols = try XCTUnwrap(start.last)
        let text = pane.view.surface.terminal.visibleText()

        // What `SplitTreeView` does as the tree changes shape, then the animation's frames.
        TerminalSurface.holdGrids(for: .milliseconds(280))
        for frame in 1...34 {
            let t = Double(frame) / 34
            setWidth(800 - 400 * (1 - pow(1 - t, 3)))
            spin(0.008)
            XCTAssertEqual(pane.view.surface.terminal.size.cols, Int(cols), "reflowed mid-animation")
            XCTAssertEqual(pane.view.surface.terminal.visibleText(), text)
        }
        spin(0.5)

        let sizes = backend.sizes.withLock { $0 }
        XCTAssertEqual(sizes.count, start.count + 1, "resizes: \(sizes)")
        XCTAssertLessThan(try XCTUnwrap(sizes.last), cols)
        XCTAssertEqual(pane.resizesSent, sizes.count)
        _ = window
    }
}
