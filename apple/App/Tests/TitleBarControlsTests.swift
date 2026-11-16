#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI
import XCTest
@testable import App

/// The title bar's trailing controls answer a click wherever the window stands: sidebar shown or
/// hidden, wide or folded into one menu, and after the tabs have changed under them.
@MainActor
final class TitleBarControlsTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    /// The menus that began tracking, each closed again at once so no test waits on one.
    private final class OpenedMenus: @unchecked Sendable {
        var titles: [[String]] = []
        private var observer: NSObjectProtocol?

        init() {
            observer = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
            ) { [weak self] notification in
                nonisolated(unsafe) let menu = notification.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let menu, menu.supermenu == nil else { return }
                    self?.titles.append(menu.items.map(\.title))
                    // Cancelled from within its own tracking loop, once that loop runs.
                    RunLoop.main.perform(inModes: [.eventTracking, .default]) { menu.cancelTrackingWithoutAnimation() }
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    private func sceneWindow(model: WindowModel, width: CGFloat) -> NSWindow {
        let frame = NSRect(x: -30000, y: -30000, width: width, height: 700)
        let window = OffscreenWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        let controller = NSHostingController(rootView: ThemedRoot {
            WindowContent(request: nil, model: model).environment(AppModel.shared)
        })
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return window
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

    /// Sent to the window from the run loop, not from the test, so what an action raises is
    /// reported the way the app reports it. The window is never key in a test run: sent to the
    /// app, the press would only be taken to activate it. The release waits in the queue, where a
    /// control tracking the press reads it.
    private func click(_ label: String, in window: NSWindow, _ context: String) async throws {
        let item = try XCTUnwrap(window.toolbar?.items.first { $0.label == label }, "\(label), \(context)")
        let view = try XCTUnwrap(item.view, "\(label), \(context)")
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let hit = frameView.hitTest(frameView.convert(point, from: nil))
        XCTAssertTrue(hit?.isDescendant(of: view) ?? false, "\(label) takes its own clicks, \(context): \(String(describing: hit))")
        nonisolated(unsafe) let press = try mouseEvent(.leftMouseDown, at: point, in: window)
        nonisolated(unsafe) let release = try mouseEvent(.leftMouseUp, at: point, in: window)
        nonisolated(unsafe) let window = window
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                NSApp.postEvent(release, atStart: false)
                window.sendEvent(press)
            }
        }
        await pump(0.8)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func checkControls(of model: WindowModel, in window: NSWindow, _ context: String) async throws {
        let menus = OpenedMenus()
        let toolbar = try XCTUnwrap(window.toolbar)
        if toolbar.items.contains(where: { $0.label == "More" }) {
            try await click("More", in: window, context)
            XCTAssertTrue(menus.titles.last?.contains("Command Palette") ?? false, "More opens, \(context): \(menus.titles)")
            return
        }
        try await click("Command Palette", in: window, context)
        XCTAssertTrue(model.isPaletteShown, "the palette opens, \(context)")
        model.isPaletteShown = false
        await pump(0.5)
        try await click("Split", in: window, context)
        XCTAssertTrue(menus.titles.last?.contains("Two Columns") ?? false, "Split opens, \(context): \(menus.titles)")
        try await click("Command Palette", in: window, context)
        XCTAssertTrue(model.isPaletteShown, "the palette opens after Split, \(context)")
        model.isPaletteShown = false
        await pump(0.5)
    }

    func testTheTrailingControlsOpenWhatTheyName() async throws {
        for width: CGFloat in [1180, 640] {
            let model = try await startedModel()
            defer { model.close() }
            let window = sceneWindow(model: model, width: width)
            defer { window.close() }
            for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
            let workspace = try XCTUnwrap(model.workspace)
            for _ in 0..<2 { workspace.apply(.newTab) }
            for sidebarShown in [true, false] {
                model.isSidebarShown = sidebarShown
                await pump(1.5)
                try await checkControls(of: model, in: window, "width \(width), sidebar shown \(sidebarShown)")
                model.selectTab(offset: 1)
                await pump(0.5)
                try await checkControls(of: model, in: window, "width \(width), sidebar shown \(sidebarShown), after a tab switch")
            }
        }
    }
}
#endif
