#if os(macOS)
import AppKit
import DesignSystem
import HostKit
import SwiftUI
import XCTest
@testable import App

/// The Mac sidebar's rows stay below the title bar band: the band holds the traffic lights and
/// the sidebar toggle, and nothing of the list is drawn under them, however it was scrolled.
@MainActor
final class SidebarTitleBarTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func sidebarList(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTableView { return scroll }
        for subview in view.subviews {
            if let found = sidebarList(in: subview) { return found }
        }
        return nil
    }

    private func sceneWindow(model: WindowModel) -> NSWindow {
        let frame = NSRect(x: -30000, y: -30000, width: 1260, height: 760)
        let window = OffscreenWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        let controller = NSHostingController(rootView: ThemedRoot {
            WindowContent(request: nil, model: model).environment(AppModel.shared)
        })
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return window
    }

    /// `CGWindowListCreateImage`, looked up at run time: the SDK marks it unavailable, and it is
    /// the one capture of an app's own window that asks no permission.
    private static func windowImage(_ number: Int) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // .optionIncludingWindow; .boundsIgnoreFraming | .bestResolution
        return create(.null, 1 << 3, UInt32(number), (1 << 0) | (1 << 3))?.takeRetainedValue()
    }

    /// How far apart the most different two pixels of `rect` (window points) are: zero over a
    /// plain fill.
    private static func spread(of rect: CGRect, in image: CGImage, windowWidth: CGFloat) throws -> CGFloat {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let scale = CGFloat(bitmap.pixelsWide) / windowWidth
        var low: [CGFloat] = [1, 1, 1], high: [CGFloat] = [0, 0, 0]
        for y in stride(from: rect.minY, to: rect.maxY, by: 0.5) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 0.5) {
                let color = try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
                for (channel, value) in [color.redComponent, color.greenComponent, color.blueComponent].enumerated() {
                    low[channel] = min(low[channel], value)
                    high[channel] = max(high[channel], value)
                }
            }
        }
        return zip(low, high).map { $1 - $0 }.max() ?? 0
    }

    func testTheSidebarsRowsStayBelowTheTitleBar() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "renders the mock workspace")
        let model = WindowModel(app: .shared)
        model.start()
        defer { model.close() }
        let window = sceneWindow(model: model)
        defer { window.close() }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        let workspace = try XCTUnwrap(model.workspace)
        while workspace.session.tabs.count < 30 { workspace.apply(.newTab) }
        model.isSidebarShown = true
        await pump(1.5)
        let titleBar = window.frame.height - window.contentLayoutRect.height
        let list = try XCTUnwrap(Self.sidebarList(in: try XCTUnwrap(window.contentView?.superview)))
        let sidebarWidth = list.frame.width
        // Right of the sidebar toggle, inside the band, over the sidebar.
        let band = CGRect(x: 150, y: 6, width: sidebarWidth - 166, height: titleBar - 12)

        for ref in [model.groups.tabs.last, model.groups.tabs.first, model.groups.tabs.dropFirst(3).first].compactMap(\.self) {
            model.focus(ref)
            await pump(1)
            let image = try XCTUnwrap(Self.windowImage(window.windowNumber))
            XCTAssertLessThan(try Self.spread(of: band, in: image, windowWidth: window.frame.width), 0.05, "a row is drawn in the title bar band")
        }
        // Scrolled by hand to anywhere along the list.
        for offset in [37.0, 120.0, 301.0] {
            list.contentView.scroll(to: NSPoint(x: 0, y: offset))
            list.reflectScrolledClipView(list.contentView)
            await pump(0.4)
            let image = try XCTUnwrap(Self.windowImage(window.windowNumber))
            XCTAssertLessThan(try Self.spread(of: band, in: image, windowWidth: window.frame.width), 0.05, "scrolled to \(offset)")
        }

        list.contentView.scroll(to: NSPoint(x: 0, y: -list.contentInsets.top))
        list.reflectScrolledClipView(list.contentView)
        await pump(0.4)
        let table = try XCTUnwrap(list.documentView as? NSTableView)
        let listTop = window.frame.height - list.convert(list.bounds, to: nil).maxY
        let firstRowTop = listTop + table.rect(ofRow: 0).minY - list.contentView.bounds.minY
        XCTAssertEqual(firstRowTop, titleBar, accuracy: 0.5, "at the top the first row sits right under the band")
    }
}
#endif
