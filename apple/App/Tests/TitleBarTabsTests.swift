import DesignSystem
import SwiftUI
import XCTest
@testable import App
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// Counts the menu items AppKit makes, of every kind: the title bar builds one for each control
/// it mirrors from an item's SwiftUI content.
enum MenuItemsMade {
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let selector = #selector(NSMenuItem.init(title:action:keyEquivalent:))
        guard let method = class_getInstanceMethod(NSMenuItem.self, selector) else { return }
        typealias Initializer = @convention(c) (AnyObject, Selector, NSString, Selector?, NSString) -> AnyObject
        let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let counting: @convention(block) (AnyObject, NSString, Selector?, NSString) -> AnyObject = { item, title, action, key in
            count += 1
            return original(item, selector, title, action, key)
        }
        method_setImplementation(method, imp_implementationWithBlock(counting))
    }
}
#endif

/// The Mac window's chrome is one row: with the sidebar hidden the tabs sit in the title bar
/// beside the traffic lights and the window's controls, the terminal starts under that row, and
/// a narrow window folds its controls into one menu rather than losing any.
@MainActor
final class TitleBarTabsTests: XCTestCase {
    func testTheTitleGetsWhatTheControlsLeave() {
        let wide = TitleBarFit(window: 1180, contentStart: 264, controls: 290)
        XCTAssertFalse(wide.foldsControls)
        XCTAssertEqual(wide.room, 1180 - 264 - DS.Space.s - 290 - TitleBarFit.trailingMargin)
    }

    func testANarrowWindowFoldsTheControlsInsteadOfDroppingThem() {
        let narrow = TitleBarFit(window: 640, contentStart: 264, controls: 290)
        XCTAssertTrue(narrow.foldsControls)
        XCTAssertGreaterThanOrEqual(narrow.room, TitleBarFit.minimumRoom)
    }

    func testBeforeTheWindowIsMeasuredNothingFolds() {
        let unknown = TitleBarFit(window: 0, contentStart: 136, controls: 290)
        XCTAssertFalse(unknown.foldsControls)
        XCTAssertEqual(unknown.room, TitleBarFit.minimumRoom)
    }

    #if os(macOS)
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    private func sceneWindow(model: WindowModel, width: CGFloat) -> NSWindow {
        let window = OffscreenWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: width, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        let controller = NSHostingController(rootView: ThemedRoot { WindowContent(request: nil, model: model).environment(AppModel.shared) })
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(NSRect(x: -30000, y: -30000, width: width, height: 700), display: false)
        window.orderFrontRegardless()
        return window
    }

    private static func containsScrollView(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view is NSScrollView || view.subviews.contains { containsScrollView($0) }
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func startedModel() async throws -> WindowModel {
        try XCTSkipUnless(LaunchOptions.mock, "renders the mock workspace")
        let model = WindowModel(app: .shared)
        model.start()
        return model
    }

    func testWithTheSidebarHiddenTheTabsAreTheTitleBarsRow() async throws {
        let model = try await startedModel()
        defer { model.close() }
        let window = sceneWindow(model: model, width: 1100)
        defer { window.close() }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        let workspace = try XCTUnwrap(model.workspace)
        for _ in 0..<3 { workspace.apply(.newTab) }
        model.isSidebarShown = false
        await pump(1.5)

        let toolbar = try XCTUnwrap(window.toolbar)
        let strip = try XCTUnwrap(toolbar.items.first { Self.containsScrollView($0.view) }, "the strip is a title bar item")
        XCTAssertTrue(toolbar.visibleItems?.contains(strip) ?? false, "the strip shows in the bar")
        XCTAssertGreaterThanOrEqual(strip.view?.frame.width ?? 0, TitleBarFit.minimumRoom)
        let titleBar = window.frame.height - window.contentLayoutRect.height
        let shownPanes = workspace.panes.values.filter { $0.view.window != nil && !$0.view.isHiddenOrHasHiddenAncestor }
        let paneTop = try XCTUnwrap(shownPanes.map { window.frame.height - $0.view.convert($0.view.bounds, to: nil).maxY }.min())
        XCTAssertLessThan(paneTop, titleBar + DS.Size.tabStrip, "no second row of chrome over the terminal")

        model.isSidebarShown = true
        await pump(1.5)
        XCTAssertFalse(toolbar.items.contains { Self.containsScrollView($0.view) }, "with the sidebar shown the sidebar lists the tabs")
    }

    /// The strip is one view to the bar, not controls it mirrors as menu items: mirrored, every
    /// chip's close button and context menu (whose Merge Into Tab names every other tab) became
    /// items, rebuilt on each update, about 16,000 for 25 tabs as the sidebar hides.
    func testHidingTheSidebarDoesNotMirrorEveryChipAsMenuItems() async throws {
        let model = try await startedModel()
        defer { model.close() }
        let window = sceneWindow(model: model, width: 1100)
        defer { window.close() }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        let workspace = try XCTUnwrap(model.workspace)
        for _ in 0..<24 { workspace.apply(.newTab) }
        model.isSidebarShown = true
        await pump(1.0)
        let chips = model.groups.tabs.count
        MenuItemsMade.install()
        MenuItemsMade.count = 0
        model.isSidebarShown = false
        await pump(1.5)
        let toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertNotNil(toolbar.items.first { Self.containsScrollView($0.view) }, "the strip is a title bar item")
        XCTAssertLessThan(MenuItemsMade.count, 5 * chips)
    }

    /// A window too narrow for the title and every control: each item still shows, the controls
    /// as one menu.
    func testANarrowWindowKeepsEveryToolbarItem() async throws {
        let model = try await startedModel()
        defer { model.close() }
        let window = sceneWindow(model: model, width: 640)
        defer { window.close() }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        for shown in [true, false] {
            model.isSidebarShown = shown
            await pump(1.5)
            let toolbar = try XCTUnwrap(window.toolbar)
            let dropped = toolbar.items.filter { $0.itemIdentifier != .flexibleSpace && !(toolbar.visibleItems ?? []).contains($0) }
            XCTAssertEqual(dropped.map(\.label), [], "sidebar shown: \(shown)")
        }
    }
    #endif
}
